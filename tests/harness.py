"""Test harness: drive HOMEPLANET inside the headless CPC emulator.

The emulator (CPCTools/cpcemu) gives us the machine's whole state -- RAM, the
CRTC registers, the framebuffer -- so tests here assert on what the hardware
actually did, not on what the source looks like. That is the only way to test
Z80 code honestly.

Two ways in:

    boot_quick()   quickload the AMSDOS .bin straight into RAM and jump to it.
                   Fast (no FDC emulation); use this for everything.

    boot_disc()    insert the real .dsk and RUN"HOME from BASIC. Slow, but it
                   is the only thing that proves the disc image is bootable.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CPCEMU = os.path.join(os.path.dirname(ROOT), "CPCTools", "cpcemu")

if CPCEMU not in sys.path:
    sys.path.insert(0, CPCEMU)

import cpc  # noqa: E402  (path has to be set up first)

BUILD = os.path.join(ROOT, "build")
DISC_RAW = os.path.join(BUILD, "disc.raw")
DSK = os.path.join(BUILD, "homeplanet.dsk")
SYM = os.path.join(BUILD, "homeplanet.sym")

LOADER_ORG = 0x4000

#  How long to let the firmware run before we take over. The game programs
#  CRTC R12/R13 and nothing else -- it inherits the standard 40x25 display the
#  firmware sets up, exactly as it would on a real machine loaded from BASIC.
#  Start it on a cold machine and the CRTC has never been initialised.
BOOT_FRAMES = 150

# Mode 1 solid-pen bytes, mirrored from src/sys/screen.asm
SOLID_INK = (0x00, 0xF0, 0x0F, 0xFF)

SCREEN_A = 0xC000
SCREEN_B = 0x8000

# CRTC R12 values for each buffer, mirrored from src/equ/hardware.asm
R12_C000 = 0x30
R12_8000 = 0x20


def build() -> None:
    """Assemble the project, failing loudly if RASM complains."""
    subprocess.run(["make", "-s"], cwd=ROOT, check=True)


_SYM_LINE = re.compile(r"^(\S+)\s+#([0-9A-Fa-f]+)\s")


def symbols() -> dict[str, int]:
    """Parse RASM's symbol file into {NAME: address}.

    Format is `NAME #ADDR B<bank> <kind>`, one per line. RASM upper-cases
    every label, so look symbols up in upper case.
    """
    out: dict[str, int] = {}
    with open(SYM, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _SYM_LINE.match(line)
            if m:
                out[m.group(1).upper()] = int(m.group(2), 16)
    if not out:
        raise RuntimeError(f"no symbols parsed from {SYM}")
    return out


def boot_quick(frames: int = 40) -> cpc.CPC:
    """Let the firmware boot, then drop DISC.BIN in at #4000 and jump to it.

    This is exactly what `RUN"DISC` ends up doing, minus the disc emulation --
    the same relocating stub runs, so the code under test is identical. Use
    boot_disc() when the thing being tested IS the disc image.
    """
    c = cpc.CPC()
    c.run_frames(BOOT_FRAMES)
    with open(DISC_RAW, "rb") as f:
        c.write_ram(LOADER_ORG, f.read())
    c.set_pc(LOADER_ORG)
    if frames:
        c.run_frames(frames)
    return c


def boot_disc(frames: int = 400) -> cpc.CPC:
    """Boot the way a real user does: insert the disc and RUN it.

    The `|DISC` is this emulator's quirk -- it comes up with the cassette as
    the default filing system, where a real 6128 with a drive comes up on
    disc. Harmless, and it keeps the rest of the path honest.
    """
    c = cpc.CPC()
    c.run_frames(BOOT_FRAMES)
    if not c.insert_disc(DSK):
        raise RuntimeError(f"insert_disc failed for {DSK}")
    c.type_text("|DISC\n")
    c.run_frames(60)
    c.type_text('RUN"DISC\n')
    c.run_frames(frames)
    return c


def front_buffer(c: cpc.CPC) -> int:
    """Base address of the buffer currently on screen.

    Always read finished frames from here: the back buffer is mid-draw.
    """
    return crtc_page(c)


def crtc_page(c: cpc.CPC) -> int:
    """Which 16K buffer the CRTC is currently displaying, as its base address."""
    r12 = (c.crtc_screen_addr >> 8) & 0xFF
    return {R12_C000: SCREEN_A, R12_8000: SCREEN_B}.get(r12 & 0x30, -1)


def screen_offset(y: int, x_byte: int) -> int:
    """Byte offset of (x_byte, y) from a buffer base -- the CPC interleave."""
    return ((y & 7) * 0x800) + ((y >> 3) * 80) + x_byte


def peek_pixel_byte(c: cpc.CPC, base: int, y: int, x_byte: int) -> int:
    return c.read_ram(base + screen_offset(y, x_byte), 1)[0]


def read_rect(c: cpc.CPC, base: int, x_byte: int, y: int, w: int, h: int) -> list[list[int]]:
    """Read a byte-aligned rectangle out of a screen buffer, row by row."""
    return [
        list(c.read_ram(base + screen_offset(y + row, x_byte), w))
        for row in range(h)
    ]


def count_byte(c: cpc.CPC, base: int, value: int) -> int:
    """How many bytes of the visible 320x200 area hold exactly `value`.

    This is the residue check: a block of known size should account for
    exactly w*h bytes. Anything more is a dirty rectangle that did not get
    cleaned up, i.e. a trail.
    """
    ram = c.read_ram(base, 0x4000)
    return sum(
        1
        for y in range(200)
        for x in range(80)
        if ram[screen_offset(y, x)] == value
    )


def find_block(c: cpc.CPC, base: int, fill: int):
    """Find the top-left corner and extent of the run of `fill` bytes.

    Returns (x, y, w, h) of the bounding box, or None if nothing matches.
    """
    ram = c.read_ram(base, 0x4000)
    hits = [
        (x, y)
        for y in range(200)
        for x in range(80)
        if ram[screen_offset(y, x)] == fill
    ]
    if not hits:
        return None
    xs = [p[0] for p in hits]
    ys = [p[1] for p in hits]
    return min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
