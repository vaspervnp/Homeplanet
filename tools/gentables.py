#!/usr/bin/env python3
"""Generate HOMEPLANET's lookup tables as a RASM include file.

This module is the *specification* for every table the engine reads. The tests
import it and re-derive the same numbers, then compare them against what is
actually sitting in the emulator's RAM -- so a table that silently changes
shape here fails the build's tests rather than corrupting the projection.

Usage:  python3 tools/gentables.py [--out src/gen/tables.asm]
"""

from __future__ import annotations

import argparse
import math
import os
import sys

# --- geometry, mirrored from src/equ/memmap.asm -----------------------------
SCR_WIDTH_PX = 320
SCR_HEIGHT_PX = 200
SCR_BYTES_PER_LINE = 80
SCR_CENTRE_X = 160
SCR_CENTRE_Y = 100

# --- fixed point ------------------------------------------------------------
#  Trig is 8.8: 1.0 is stored as 256. Values therefore span -256..+256, which
#  needs 16 bits, which is why sin is split into two byte planes.
TRIG_ONE = 256
TRIG_STEPS = 256                     # a full turn in 256 brads
TRIG_QUARTER = TRIG_STEPS // 4       # cos(a) == sin(a + quarter)

# ---------------------------------------------------------------------------
#  The projection pipeline.
#
#  Everything below is the specification for src/math/*.asm. The Python here
#  and the Z80 there must agree BIT FOR BIT -- every shift is written the way
#  the Z80 actually does it, including where it truncates. tests/test_phase1.py
#  runs the real routines in the emulator and compares against project().
# ---------------------------------------------------------------------------

#  Rotation matrix entries are signed bytes with 127 == 1.0.
#
#  Why 127 and not 128: 128 does not fit in a signed byte. The cost is a
#  uniform 127/128 scale on the whole matrix -- a 0.8% zoom, invisible, and
#  absorbed into PROJ_K below. The benefit is that the accumulator cannot
#  overflow: |m.v| <= 127 * 128*sqrt(3) = 28156, comfortably inside 16 bits.
MAT_ONE = 127

#  Camera-space coordinates are signed bytes obtained by taking the HIGH BYTE
#  of the rotation accumulator, so the whole 16-bit world maps to +/-128.
WORLD_SHIFT = 8

#  sx = 160 + ((x * recip[z]) >> PROJ_SHIFT), and recip[z] = PROJ_K / z.
#
#  PROJ_K is set so that x == z (45 degrees off axis) lands exactly on the
#  screen edge, i.e. a 90 degree horizontal field of view:
#      (z * (PROJ_K/z)) >> PROJ_SHIFT == 160   =>   PROJ_K = 160 << PROJ_SHIFT
#
#  PROJ_SHIFT is 7 rather than 8 because recip must stay inside a byte: at
#  shift 8 the near plane would have to sit at z=161, leaving a depth range of
#  only 1.6:1 and a picture with almost no perspective in it. Shift 7 buys a
#  3:1 range instead. It is also cheap on the Z80 -- see proj_shr7.
PROJ_SHIFT = 7
PROJ_K = 160 << PROJ_SHIFT           # 20480

#  Z_NEAR is the smallest z where recip still fits in a byte (20480/84 = 244).
Z_NEAR = 84
Z_FAR = 255


def screen_line_offsets() -> list[int]:
    """Byte offset of each pixel line from the base of a screen buffer.

    The CPC interleaves: line L of character row R lives L*0x800 bytes into
    the buffer plus R*80. Stored as an offset rather than an address so the
    same table serves both buffers -- see scr_line_addr.
    """
    return [
        ((y & 7) * 0x800) + ((y >> 3) * SCR_BYTES_PER_LINE)
        for y in range(SCR_HEIGHT_PX)
    ]


def quarter_squares() -> list[int]:
    """f(n) = floor(n^2 / 4), for n in 0..511.

    The Z80 has no multiplier. The identity

        a * b = f(a + b) - f(a - b)

    turns an 8x8 multiply into two table reads and a subtraction, roughly 70
    T-states against ~200 for shift-and-add (Homeplanet.md section 4.2).

    One table covers both terms: a+b reaches 510, and |a-b| never exceeds 255,
    so the difference term indexes the same array. 512 entries, split into a
    low and a high byte plane, each page-aligned.
    """
    return [(n * n) // 4 for n in range(512)]


def sine_table() -> list[int]:
    """sin(angle) in 8.8 fixed point, 256 angles to the turn.

    Cosine is the same table read at (angle + 64) & 255, so nothing separate
    is stored for it.
    """
    return [
        round(TRIG_ONE * math.sin(2.0 * math.pi * i / TRIG_STEPS))
        for i in range(TRIG_STEPS)
    ]


def signed_quarter_squares() -> list[int]:
    """f(s) = floor(s^2 / 4), indexed by s as a 9-bit TWO'S COMPLEMENT number.

    This is the table that makes the rotation loop branchless.

    f is even, so the quarter-square identity works on signed operands
    unchanged -- a*b = f(a+b) - f(a-b) -- and it stays exact under floor
    division because a+b and a-b always have the same parity, so their
    remainders cancel.

    The only awkward part is the index: for signed bytes, a+b spans -255..254
    and a-b spans -255..255, so it needs nine bits. Storing f of the SIGNED
    index rather than f of the magnitude means the Z80 never has to work out
    an absolute value: the 16-bit sum it already has in HL is the index, with
    bit 8 being `H AND 1` (H is #00 or #FF and nothing else in this range).

    Entries 256..511 therefore hold f of the negative values.
    """
    return [((i if i < 256 else i - 512) ** 2) // 4 for i in range(512)]


def sin7_table() -> list[int]:
    """sin(angle) * 127, one signed byte per angle.

    The matrix build wants single-byte trig, not the 8.8 pair: it multiplies
    these together with the ordinary signed 8x8 routine and shifts back by 7.
    """
    return [
        round(MAT_ONE * math.sin(2.0 * math.pi * i / TRIG_STEPS))
        for i in range(TRIG_STEPS)
    ]


def recip_table() -> list[int]:
    """recip[z] = PROJ_K / z, one unsigned byte per depth.

    Entry 0 is never read -- anything nearer than Z_NEAR is clipped first --
    but it has to hold something, so it holds the clamp value.
    """
    out = [255]
    for z in range(1, 256):
        out.append(min(255, (PROJ_K + z // 2) // z))
    return out


# ---------------------------------------------------------------------------
#  Reference model. Mirrors src/math/ instruction for instruction.
# ---------------------------------------------------------------------------

def _i8(v: int) -> int:
    """Take the low byte and read it as signed -- what `ld a,l` gives you."""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def _i16(v: int) -> int:
    v &= 0xFFFF
    return v - 65536 if v >= 32768 else v


def mul7(a: int, b: int) -> int:
    """(a * b) >> 7 on a signed 16-bit product, as the Z80 does it.

    Python's >> on negative integers floors, and so does an arithmetic shift,
    so these agree without any special casing.
    """
    return (a * b) >> 7


def camera_matrix(yaw: int, pitch: int) -> list[int]:
    """The 3x3 world-to-camera rotation as nine signed bytes at MAT_ONE scale.

    Orbit camera: yaw about Y, then pitch about X, so M = Rx(pitch).Ry(yaw).
    Row 0 has a structural zero in the middle -- cam_build_matrix stores it
    anyway so the projection loop can stay a flat nine-multiply run.
    """
    s = sin7_table()
    sy, cy = s[yaw & 255], s[(yaw + TRIG_QUARTER) & 255]
    sp, cp = s[pitch & 255], s[(pitch + TRIG_QUARTER) & 255]
    return [
        cy,             0,   sy,
        mul7(sp, sy),   cp,  -mul7(sp, cy),
        -mul7(cp, sy),  sp,  mul7(cp, cy),
    ]


def project(point, focus, matrix, cam_dist):
    """One entity through the whole pipeline.

    Returns (sx, sy, z) or None if it was clipped. `z` is the camera-space
    depth the size tier is chosen from.
    """
    # v = (P - focus) >> 8, i.e. the high byte of the 16-bit difference.
    v = [_i8(_i16(point[i] - focus[i]) >> WORLD_SHIFT) for i in range(3)]

    rotated = []
    for row in range(3):
        acc = sum(matrix[row * 3 + col] * v[col] for col in range(3))
        rotated.append(_i16(acc))

    x = rotated[0] >> 8                      # ld a,h
    y = rotated[1] >> 8
    z = (rotated[2] >> 8) + cam_dist

    if z < Z_NEAR or z > Z_FAR:
        return None

    r = recip_table()[z]
    sx = SCR_CENTRE_X + ((x * r) >> PROJ_SHIFT)
    sy = SCR_CENTRE_Y - ((y * r) >> PROJ_SHIFT)

    if not (0 <= sx < SCR_WIDTH_PX and 0 <= sy < SCR_HEIGHT_PX):
        return None
    return sx, sy, z


# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

def _split_planes(values: list[int]) -> tuple[list[int], list[int]]:
    """Split signed/unsigned 16-bit values into low and high byte planes."""
    lo, hi = [], []
    for v in values:
        w = v & 0xFFFF
        lo.append(w & 0xFF)
        hi.append(w >> 8)
    return lo, hi


def _defb_block(name: str, data: list[int], per_line: int = 16) -> str:
    """Emit bytes. Signed values are masked to two's complement first --
    RASM will not parse `#-19`."""
    out = [f"{name}:"]
    for i in range(0, len(data), per_line):
        chunk = ",".join("#%02X" % (b & 0xFF) for b in data[i:i + per_line])
        out.append(f"    defb {chunk}")
    return "\n".join(out)


def _defw_block(name: str, data: list[int], per_line: int = 8) -> str:
    out = [f"{name}:"]
    for i in range(0, len(data), per_line):
        chunk = ",".join("#%04X" % (w & 0xFFFF) for w in data[i:i + per_line])
        out.append(f"    defw {chunk}")
    return "\n".join(out)


def render() -> str:
    lines = [
        "; " + "=" * 74,
        ";  gen/tables.asm -- GENERATED by tools/gentables.py, do not edit",
        ";",
        ";  Regenerate with `make tables`. The generator is the readable",
        ";  specification; this file is just its output.",
        "; " + "=" * 74,
        "",
    ]

    # --- screen line offsets ------------------------------------------------
    offsets = screen_line_offsets()
    line_lo, line_hi = _split_planes(offsets)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  scr_line_lo / scr_line_hi -- byte offset of pixel line y from a buffer base.",
        ";",
        ";  Two byte planes on CONSECUTIVE pages, not one word table. That lets",
        ";  scr_line_addr index them with `ld h,page : ld l,y` and step between the",
        ";  planes with `inc h`, so it never needs a 16-bit register pair for the base",
        ";  -- which means it never clobbers DE, which callers hold their parameters in.",
        ";",
        ";  The offset never reaches #4000, so the buffer's high byte can be OR'd on",
        ";  rather than added.",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("scr_line_lo", line_lo),
        "    align 256",
        _defb_block("scr_line_hi", line_hi),
        "",
        f"SCR_LINE_TABLE_ENTRIES equ {len(offsets)}",
        "",
    ]

    # --- quarter squares ----------------------------------------------------
    qsq = quarter_squares()
    qsq_lo, qsq_hi = _split_planes(qsq)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  qsq_lo / qsq_hi -- f(n) = n*n/4, n = 0..511, as two byte planes.",
        ";  a*b = f(a+b) - f(a-b). Both planes are page-aligned, so a 9-bit index is",
        ";      ld h,HIGH(qsq_lo) : ld l,a : jr nc,$+3 : inc h",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("qsq_lo", qsq_lo),
        "    align 256",
        _defb_block("qsq_hi", qsq_hi),
        "",
    ]

    # --- sine ---------------------------------------------------------------
    sin = sine_table()
    sin_lo, sin_hi = _split_planes(sin)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  sin_lo / sin_hi -- sin(a) * 256, 256 angles to the turn, two's complement.",
        ";  cos(a) = sin((a + 64) & 255). Page-aligned: ld h,HIGH(sin_lo) : ld l,angle",
        "; ---------------------------------------------------------------------------",
        f"TRIG_ONE     equ {TRIG_ONE}",
        f"TRIG_STEPS   equ {TRIG_STEPS}",
        f"TRIG_QUARTER equ {TRIG_QUARTER}",
        "",
        "    align 256",
        _defb_block("sin_lo", sin_lo),
        "    align 256",
        _defb_block("sin_hi", sin_hi),
        "",
    ]

    # --- signed quarter squares --------------------------------------------
    f9 = signed_quarter_squares()
    f9_lo, f9_hi = _split_planes(f9)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  f9_lo / f9_hi -- f(s) for s as a 9-bit two's complement index.",
        ";  What the rotation loop uses: m*v = f9[(m+v) & 1FF] - f9[(m-v) & 1FF],",
        ";  with no absolute values, no sign tracking and no branches at all.",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("f9_lo", f9_lo),
        "    align 256",
        _defb_block("f9_hi", f9_hi),
        "",
    ]

    # --- single-byte trig for the matrix build ------------------------------
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  sin7 -- sin(a) * 127, one signed byte per angle.",
        ";  What cam_build_matrix reads: ld h,HIGH(sin7) : ld l,angle : ld a,(hl)",
        "; ---------------------------------------------------------------------------",
        f"MAT_ONE equ {MAT_ONE}",
        "",
        "    align 256",
        _defb_block("sin7", sin7_table()),
        "",
    ]

    # --- perspective --------------------------------------------------------
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  recip -- PROJ_K / z, one unsigned byte per depth.",
        f";  sx = 160 + ((x * recip[z]) >> {PROJ_SHIFT}),  sy = 100 - (likewise)",
        f";  Valid for z in {Z_NEAR}..{Z_FAR}; nearer than that and the byte would clamp,",
        ";  so proj_point clips first.",
        "; ---------------------------------------------------------------------------",
        f"PROJ_SHIFT equ {PROJ_SHIFT}",
        f"PROJ_K     equ {PROJ_K}",
        f"Z_NEAR     equ {Z_NEAR}",
        f"Z_FAR      equ {Z_FAR}",
        "",
        "    align 256",
        _defb_block("recip", recip_table()),
        "",
    ]

    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.path.join(here, "src", "gen", "tables.asm"))
    args = ap.parse_args(argv)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    text = render()
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {args.out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
