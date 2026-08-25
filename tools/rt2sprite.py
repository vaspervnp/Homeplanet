#!/usr/bin/env python3
"""Convert a RetroTools project export into HOMEPLANET sprite data for RASM.

    python3 tools/rt2sprite.py ships.retrotools.json --out src/gen/spr_ships.asm

Why not use RetroTools' own `.asm` exporter
-------------------------------------------
Two reasons, both about masks.

RetroTools packs its transparency mask at 1 bit per pixel, MSB-first, whatever
the graphics mode is. Mode 1 data is 2 bits per pixel in the interleaved
layout `A0 B0 C0 D0 A1 B1 C1 D1`. So for a 16-pixel-wide sprite the data row is
4 bytes and the mask row is 2, and the bits do not line up -- you cannot AND
one against the other. A blitter would have to expand every mask bit into its
pixel's bit pair at runtime, every frame, forever.

And the `.asm` exporter emits one label for the whole blob with a fixed eight
bytes per `defb` line, which tells us nothing about where a frame starts.

So we read the project JSON instead -- `pixels` is a plain indexed buffer, one
byte per pixel -- and emit exactly the layout the blitter wants.

Output layout
-------------
Per sprite, blocks indexed `(frame * shifts + shift)`, each `h` rows of
`w_bytes` MASK/DATA pairs:

    mask0, data0, mask1, data1, ...        row 0
    mask0, data0, ...                      row 1

which is what the inner loop eats without any rearranging:

    ld a,(de) : and (hl) : inc hl : or (hl) : inc hl : ld (de),a : inc de

The mask is an AND-mask in Mode 1 bit order -- bits set where the background
must survive -- and the data has already been zeroed under transparent pixels,
so OR is safe.

Pre-shifting
------------
A Mode 1 byte is 4 pixels, so a sprite can only be placed on a 4-pixel
boundary without shifting. We store the sprite twice, at 0 and 2 pixels, and
restrict X to even positions (Homeplanet.md section 5.1). Shifting is done
here on the pixel grid and re-encoded, which is obviously correct, rather than
by trying to rotate the interleaved bit planes.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys

MODE1_PIXELS_PER_BYTE = 4
MODE1_MAX_PEN = 3

#  Firmware colour (0-26) -> the byte you send to the gate array. Where a
#  colour has two gate array inks, RetroTools reports the lower one, so we do
#  too. Matches src/equ/hardware.asm.
FIRMWARE_TO_HARDWARE = [
    0x54, 0x44, 0x55, 0x5C, 0x58, 0x5D, 0x4C, 0x45, 0x4D,
    0x56, 0x46, 0x57, 0x5E, 0x40, 0x5F, 0x4E, 0x47, 0x4F,
    0x52, 0x42, 0x53, 0x5A, 0x59, 0x5B, 0x4A, 0x43, 0x4B,
]

FIRMWARE_NAMES = [
    "Black", "Blue", "Bright Blue", "Red", "Magenta", "Mauve", "Bright Red",
    "Purple", "Bright Magenta", "Green", "Cyan", "Sky Blue", "Yellow", "White",
    "Pastel Blue", "Orange", "Pink", "Pastel Magenta", "Bright Green",
    "Sea Green", "Bright Cyan", "Lime", "Pastel Green", "Pastel Cyan",
    "Bright Yellow", "Pastel Yellow", "Bright White",
]

#  The game's palette is semantic and fixed (Homeplanet.md section 2). A sprite
#  project drawn against different inks would still convert, but pen 2 would
#  quietly stop meaning "shading" -- so we check.
GAME_PALETTE = [0, 26, 11, 6]     # space, friendly, neutral/shading, enemy
GAME_PALETTE_NAMES = ["space", "friend/HUD", "neutral/shading", "enemy"]

DEFAULT_SHIFTS = (0, 2)


class ConversionError(Exception):
    pass


# ---------------------------------------------------------------------------
#  Mode 1 encoding
# ---------------------------------------------------------------------------

def encode_mode1_byte(pens: list[int]) -> int:
    """Pack four pens, left to right, into one Mode 1 byte.

    Bit layout for pixels A B C D, subscript = pen bit index:

        bit:  7  6  5  4  3  2  1  0
             A0 B0 C0 D0 A1 B1 C1 D1
    """
    a, b, c, d = pens
    return (
        ((a & 1) << 7) | ((b & 1) << 6) | ((c & 1) << 5) | ((d & 1) << 4)
        | ((a & 2) << 2) | ((b & 2) << 1) | (c & 2) | ((d & 2) >> 1)
    )


def mask_bits(position: int) -> int:
    """The two bits a pixel occupies in a Mode 1 byte. Position 0 is leftmost."""
    return 0x88 >> position


def encode_mask_byte(opaque: list[bool]) -> int:
    """AND-mask for four pixels: bits set where the BACKGROUND shows through."""
    m = 0
    for p, is_opaque in enumerate(opaque):
        if not is_opaque:
            m |= mask_bits(p)
    return m


# ---------------------------------------------------------------------------
#  Project reading
# ---------------------------------------------------------------------------

def load_project(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)

    if doc.get("format") != "retrotools-project":
        raise ConversionError(f"{path} is not a RetroTools project export")
    if doc.get("modeCode") != "cpc.mode1":
        raise ConversionError(
            f"{path} is {doc.get('modeCode')!r}; HOMEPLANET is Mode 1 only"
        )
    return doc


def check_palette(doc: dict, strict: bool) -> list[str]:
    """Compare the project's inks against the game's fixed four."""
    slots = {p["slot"]: p["color"] for p in doc.get("palette", [])}
    problems = []
    for slot, want in enumerate(GAME_PALETTE):
        got = slots.get(slot)
        if got is None:
            problems.append(f"pen {slot} is missing from the project palette")
        elif got != want:
            problems.append(
                f"pen {slot} is {FIRMWARE_NAMES[got]} ({got}), "
                f"the game uses {FIRMWARE_NAMES[want]} ({want}) for {GAME_PALETTE_NAMES[slot]}"
            )
    if problems and strict:
        raise ConversionError("palette mismatch:\n  " + "\n  ".join(problems))
    return problems


def frame_grids(sprite: dict, frame: dict) -> tuple[list[list[int]], list[list[bool]]]:
    """Decode one frame into a pen grid and an opacity grid, both [y][x]."""
    w, hgt = sprite["width"], sprite["height"]

    pixels = base64.b64decode(frame["pixels"])
    if len(pixels) != w * hgt:
        raise ConversionError(
            f"{sprite['name']} frame {frame['index']}: "
            f"{len(pixels)} pixel bytes, expected {w * hgt}"
        )
    bad = [p for p in pixels if p > MODE1_MAX_PEN]
    if bad:
        raise ConversionError(
            f"{sprite['name']} frame {frame['index']}: pen {max(bad)} is out of range for Mode 1"
        )

    raw_mask = frame.get("mask")
    if raw_mask:
        mask = base64.b64decode(raw_mask)
        if len(mask) != w * hgt:
            raise ConversionError(
                f"{sprite['name']} frame {frame['index']}: mask is {len(mask)} bytes, expected {w * hgt}"
            )
        opaque = [bool(m) for m in mask]
    else:
        # No mask drawn: pen 0 is empty space in this game's palette, so
        # treating it as transparent is the right default rather than an error.
        opaque = [p != 0 for p in pixels]

    pens = [list(pixels[y * w:(y + 1) * w]) for y in range(hgt)]
    opa = [opaque[y * w:(y + 1) * w] for y in range(hgt)]
    return pens, opa


def shift_grid(pens, opaque, shift: int, out_width: int):
    """Shift a frame right by `shift` pixels into a grid `out_width` wide."""
    hgt = len(pens)
    src_w = len(pens[0])
    out_pens = [[0] * out_width for _ in range(hgt)]
    out_opa = [[False] * out_width for _ in range(hgt)]
    for y in range(hgt):
        for x in range(src_w):
            out_pens[y][x + shift] = pens[y][x]
            out_opa[y][x + shift] = opaque[y][x]
    return out_pens, out_opa


def encode_block(pens, opaque) -> list[int]:
    """One shifted frame -> mask/data pairs, row by row."""
    out: list[int] = []
    for y in range(len(pens)):
        row_pens, row_opa = pens[y], opaque[y]
        for bx in range(0, len(row_pens), MODE1_PIXELS_PER_BYTE):
            quad_pens = row_pens[bx:bx + MODE1_PIXELS_PER_BYTE]
            quad_opa = row_opa[bx:bx + MODE1_PIXELS_PER_BYTE]
            # Zero the data under transparent pixels so OR is safe.
            data_pens = [p if o else 0 for p, o in zip(quad_pens, quad_opa)]
            out.append(encode_mask_byte(quad_opa))
            out.append(encode_mode1_byte(data_pens))
    return out


# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

def identifier(name: str) -> str:
    out = "".join(ch if ch.isascii() and ch.isalnum() else "_" for ch in name).strip("_").lower()
    if not out:
        out = "sprite"
    if out[0].isdigit():
        out = "spr_" + out
    return out


def _defb_lines(data: list[int], per_line: int = 16) -> list[str]:
    return [
        "    defb " + ",".join("#%02X" % b for b in data[i:i + per_line])
        for i in range(0, len(data), per_line)
    ]


def convert(doc: dict, shifts: tuple[int, ...], palette_warnings: list[str]) -> str:
    lines = [
        "; " + "=" * 74,
        f";  GENERATED by tools/rt2sprite.py from {doc.get('name', '?')!r} -- do not edit",
        ";",
        ";  Mode 1, mask/data pairs, rows top to bottom. Block index is",
        ";  (frame * <name>_shifts + shift); each block is <name>_block_sz bytes.",
        ";  The mask is an AND-mask: 1 where the background must show through.",
        "; " + "=" * 74,
        "",
    ]

    slots = {p["slot"]: p["color"] for p in doc.get("palette", [])}
    lines.append(";  Project palette:")
    for slot in range(4):
        colour = slots.get(slot)
        if colour is None:
            lines.append(f";    pen {slot}: (unset)")
        else:
            lines.append(
                f";    pen {slot}: {FIRMWARE_NAMES[colour]} "
                f"(firmware {colour}, hardware #{FIRMWARE_TO_HARDWARE[colour]:02X})"
                f"  -- {GAME_PALETTE_NAMES[slot]}"
            )
    if palette_warnings:
        lines.append(";")
        lines.append(";  WARNING: does not match the game's semantic palette:")
        lines += [f";    {w}" for w in palette_warnings]
    lines.append("")

    for sprite in sorted(doc.get("sprites", []), key=lambda s: (s.get("sortOrder", 0), s["id"])):
        name = identifier(sprite["name"])
        w, hgt = sprite["width"], sprite["height"]
        if w % MODE1_PIXELS_PER_BYTE:
            raise ConversionError(
                f"{sprite['name']}: width {w} is not a multiple of 4, which Mode 1 requires"
            )

        frames = sorted(sprite.get("frames", []), key=lambda f: f["index"])
        if not frames:
            continue

        # One spare byte of width so a 2-pixel shift has somewhere to land.
        out_width = w + MODE1_PIXELS_PER_BYTE
        w_bytes = out_width // MODE1_PIXELS_PER_BYTE
        block_sz = w_bytes * 2 * hgt

        lines += [
            "; " + "-" * 74,
            f";  {sprite['name']} -- {w}x{hgt} px, {len(frames)} frame(s), {len(shifts)} pre-shift(s)",
            f";  {len(frames) * len(shifts) * block_sz} bytes total",
            "; " + "-" * 74,
            f"{name}_w_px      equ {w}",
            f"{name}_h         equ {hgt}",
            f"{name}_w_bytes   equ {w_bytes}      ; includes the pre-shift spill byte",
            f"{name}_frames    equ {len(frames)}",
            f"{name}_shifts    equ {len(shifts)}",
            f"{name}_block_sz  equ {block_sz}",
            "",
            f"{name}:",
        ]

        for frame in frames:
            pens, opaque = frame_grids(sprite, frame)
            for shift in shifts:
                sp, so = shift_grid(pens, opaque, shift, out_width)
                lines.append(f"    ; frame {frame['index']}, shift {shift} px")
                lines += _defb_lines(encode_block(sp, so))
        lines.append("")

    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", help="a .retrotools.json export")
    ap.add_argument("--out", help="output .asm (default: src/gen/spr_<project>.asm)")
    ap.add_argument("--shifts", default=",".join(str(s) for s in DEFAULT_SHIFTS),
                    help="comma-separated pre-shift offsets in pixels")
    ap.add_argument("--strict-palette", action="store_true",
                    help="fail instead of warning when the inks differ from the game's")
    args = ap.parse_args(argv)

    shifts = tuple(int(s) for s in args.shifts.split(","))
    for s in shifts:
        if not 0 <= s < MODE1_PIXELS_PER_BYTE:
            raise SystemExit(f"pre-shift {s} must be 0..3 pixels")

    try:
        doc = load_project(args.project)
        warnings = check_palette(doc, args.strict_palette)
        text = convert(doc, shifts, warnings)
    except ConversionError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)

    out = args.out
    if not out:
        stem = os.path.basename(args.project).split(".")[0]
        out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "src", "gen", f"spr_{identifier(stem)}.asm")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
