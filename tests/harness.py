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
DISC_SYM = os.path.join(BUILD, "disc.sym")

LOADER_ORG = 0x4000


def _scratch_base() -> int:
    """Somewhere the tests can poke stubs and results without hitting the game.

    Tests used to hard-code #3000 and #2F00. That was free space once; the
    code and its tables have since grown past it, and sin7 now LIVES at
    #3000 -- so every test that called a routine was quietly overwriting the
    sine table first, and the failures showed up somewhere else entirely, in
    whichever test happened to build a camera matrix next.

    So take it from the build: everything above code_end is free by
    construction, and main.asm already asserts that the stack (growing down
    from #4000) never reaches it.
    """
    base = (symbols()["CODE_END"] + 0x0F) & ~0x0F
    limit = 0x4000 - 256 - SCRATCH_SIZE
    if base > limit:
        raise RuntimeError(
            f"no room for test scratch: code_end is #{base:04X}, limit #{limit:04X}"
        )
    return base


SCRATCH_SIZE = 0x60

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


def symbols(path: str = SYM) -> dict[str, int]:
    """Parse RASM's symbol file into {NAME: address}.

    Format is `NAME #ADDR B<bank> <kind>`, one per line. RASM upper-cases
    every label, so look symbols up in upper case.
    """
    out: dict[str, int] = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _SYM_LINE.match(line)
            if m:
                out[m.group(1).upper()] = int(m.group(2), 16)
    if not out:
        raise RuntimeError(f"no symbols parsed from {SYM}")
    return out


#  Laid out as: the stub, then a word of result, then a data block.
SCRATCH = _scratch_base()
STUB = SCRATCH
RESULT = SCRATCH + 0x40
DATA = SCRATCH + 0x50


def wait_for_title(c: cpc.CPC, frames: int = 400) -> bool:
    """Run until the game has reached its title screen.

    Needed because `frames` is not a reliable way to say "the game is up". The
    loader decompresses the sprite library and demo_init probes the drive for
    a saved fleet, and that probe alone spins the motor for a third of a
    second -- so boot_quick(frames=30) used to return while the game was still
    initialising. dismiss_title then found no title (it had not opened yet),
    dismiss_briefing found no briefing, and the caller got a machine that put
    the title up a moment later and ignored everything it was sent.
    """
    sym = symbols()
    if "TITLE_SHOWN" not in sym:
        return False
    for _ in range(frames // 10):
        if read_cpu(c, sym["TITLE_SHOWN"], 1)[0]:
            return True
        c.run_frames(10)
    return False


def dismiss_title(c: cpc.CPC) -> None:
    """Press SPACE past the title screen, if it is up.

    It sits in FRONT of the first mission's briefing, so anything that wants
    the game actually running has to get past both. `title_shown` lives in
    bank 4 with the rest of the title, so it is read through peek -- read_ram
    would hand back bank 1 and report whatever the sprite library has there.
    """
    sym = symbols()
    if "TITLE_SHOWN" not in sym:
        return
    for _ in range(6):
        if not read_cpu(c, sym["TITLE_SHOWN"], 1)[0]:
            return
        c.key_down(cpc.KEY_SPACE)
        c.run_frames(25)
        c.key_up(cpc.KEY_SPACE)
        c.run_frames(20)
    raise RuntimeError("could not get past the title screen")


def wait_for_briefing(c: cpc.CPC, frames: int = 80) -> bool:
    """Give a briefing that is on its way a chance to appear.

    A jump is not instant. mis_jump increments mis_index, writes the fleet to
    the DISC -- a kilobyte, with the drive spinning up, so about a third of a
    second -- and only then opens the briefing. For that whole stretch
    mis_index already says the new mission and mis_briefing still says zero.

    dismiss_briefing used to read the flag once and return when it was clear,
    so a test that pressed J and looked immediately found no briefing, decided
    there was nothing to do, and then sent the NEXT command into a briefing
    screen that had appeared in the meantime -- where nothing runs. Two
    campaign tests failed with "1 != 2" and neither of them was about discs.

    Bounded, because a refused jump never puts a briefing up at all and that
    is a legitimate thing for a test to check.
    """
    sym = symbols()
    if "MIS_BRIEFING" not in sym:
        return False
    for _ in range(frames // 5):
        if c.read_ram(sym["MIS_BRIEFING"], 1)[0]:
            return True
        c.run_frames(5)
    return False


def dismiss_briefing(c: cpc.CPC) -> None:
    """Press ENTER past a mission briefing, if one is up.

    Every mission opens on a static briefing screen and nothing else runs
    while it is showing -- no orders, no simulation. Almost every test wants
    the game actually playing, so this is done for them; pass
    `briefing=True` to boot_quick to keep it.
    """
    dismiss_title(c)                    # it sits in front of the briefing
    sym = symbols()
    if "MIS_BRIEFING" not in sym:
        return
    wait_for_briefing(c)
    for _ in range(6):
        if not c.read_ram(sym["MIS_BRIEFING"], 1)[0]:
            return
        c.key_down(cpc.KEY_ENTER)
        c.run_frames(25)
        c.key_up(cpc.KEY_ENTER)
        c.run_frames(20)
    raise RuntimeError("could not get past the mission briefing")


def boot_quick(frames: int = 40, briefing: bool = False,
               disc: bool = True) -> cpc.CPC:
    """Let the firmware boot, then drop DISC.BIN in at #4000 and jump to it.

    This is exactly what `RUN"DISC` ends up doing, minus AMSDOS loading the
    file -- the same relocating stub runs, so the code under test is
    identical. Use boot_disc() when the thing being tested IS the loading.

    THE DISC IS IN THE DRIVE, and it has to be. Six of the eight sprite
    libraries do not fit inside DISC.BIN and live on the disc as raw sectors;
    lib_load reads them into banks 5-7 during demo_init. Boot without one and
    the game runs perfectly well but wears stand-in art, which is what
    `disc=False` is for -- and what the fallback tests use.

    The image is handed to the emulator as BYTES, and cpcemu keeps its own
    copy, so a test that saves the fleet writes into that copy and not into
    build/homeplanet.dsk. One test cannot leave a campaign half-played for the
    next one.

    The opening briefing is dismissed unless `briefing` is set: it stops the
    whole game, so a test that left it up would be testing a static screen.
    """
    c = cpc.CPC()
    c.run_frames(BOOT_FRAMES)
    if disc:
        with open(DSK, "rb") as f:
            if not c.insert_disc(f.read()):
                raise RuntimeError(f"insert_disc failed for {DSK}")
    with open(DISC_RAW, "rb") as f:
        c.write_ram(LOADER_ORG, f.read())
    #  Not LOADER_ORG: the stub lives at the TOP of the image, above #8000,
    #  because it has to page bank 4 into #4000 and would otherwise page
    #  itself out mid-instruction. See src/disc.asm.
    c.set_pc(symbols(DISC_SYM)["DISC_STUB"])
    if frames:
        c.run_frames(frames)
    if not briefing:
        #  Wait for the game rather than trusting `frames` -- see wait_for_title.
        wait_for_title(c)
        dismiss_briefing(c)
    return c


def close(c) -> None:
    """Free an emulator as soon as the test that owns it is done with it.

    unittest keeps test instances alive for the whole run, so a fixture that
    builds a machine per test leaves dozens of them live at once -- and they
    interfere: keystrokes stop registering in some of them, and the symptom
    surfaces in whichever test happens to run next rather than in the one
    that leaked. Fixtures with a per-test setUp should call this in tearDown.
    """
    if c is not None:
        c.__del__()


def jump_mission(c: cpc.CPC, frames: int = 25) -> None:
    """Press J and clear the briefing the next mission opens on.

    A bare J leaves the game on a static screen where nothing runs, so a test
    that then called run_frames would sit watching a briefing and conclude
    that nothing works.
    """
    c.key_down("j")
    c.run_frames(frames)
    c.key_up("j")
    c.run_frames(20)
    dismiss_briefing(c)


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


def run_until_pc_in(c: cpc.CPC, lo: int, hi: int, max_us: int = 400_000) -> bool:
    """Step until the CPU is executing inside [lo, hi), or give up.

    Needed because the game's own data structures are only consistent at
    certain points in the frame. Reading `phase3_visible` while
    `phase3_project` is halfway through rebuilding it gives a count that does
    not match the array beside it -- a race in the TEST, not in the game.

    Steps in 100 microsecond slices, which is fine enough to land inside a
    short spin loop like scr_wait_vsync.
    """
    for _ in range(max_us // 100):
        if lo <= c.pc < hi:
            return True
        c.run_us(100)
    return False


def run_to_stable_point(c: cpc.CPC, sym: dict[str, int]) -> None:
    """Park the machine in scr_wait_vsync, where a frame has just finished.

    Everything the frame computed -- the visible list, the draw order, the
    dirty rectangles -- is complete and not yet being overwritten.
    """
    lo = sym["SCR_WAIT_VSYNC"]
    if not run_until_pc_in(c, lo, lo + 12):
        raise RuntimeError("never caught the frame loop at scr_wait_vsync")


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


def read_cpu(c: cpc.CPC, addr: int, size: int) -> bytes:
    """Read the way the CPU sees memory, honouring the bank paging.

    read_ram() indexes the base 64K by address, so #4000 always gives it
    bank 1 -- but the game runs with extended bank 4 in that window, holding
    the sprite library. Anything reading #4000-#7FFF must come through here.
    """
    return bytes(c.peek((addr + i) & 0xFFFF) for i in range(size))


def write_cpu(c: cpc.CPC, addr: int, data: bytes) -> None:
    """Write the way the CPU sees memory, honouring the bank paging.

    The mirror of read_cpu, and needed for the same reason: write_ram() would
    put the bytes in bank 1 where nothing will ever look at them.
    """
    for i, byte in enumerate(data):
        c.poke((addr + i) & 0xFFFF, byte)


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
