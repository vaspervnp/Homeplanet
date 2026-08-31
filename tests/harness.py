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
        if read_bank4(c, sym["TITLE_SHOWN"], 1)[0]:
            return True
        c.run_frames(10)
    return False


def dismiss_title(c: cpc.CPC) -> None:
    """Press SPACE past the title screen, if it is up.

    It sits in FRONT of the first mission's briefing, so anything that wants
    the game actually running has to get past both.

    `title_shown` lives in bank 4, and it is read through read_bank4 rather
    than read_cpu -- which is not tidiness, it is a bug this had. THE TITLE
    SCREEN ITSELF PAGES BANKS 5 AND 6 IN, because title_draw_ships blits real
    ship libraries through spr_blit_banked; so a peek at an arbitrary
    emulator-frame boundary has a real chance of reading SPRITE DATA at
    title_shown's address. Whether that byte happens to be zero decides
    whether this routine thinks the title is up.

    It read as luck for a long time and the luck was per-address: adding 136
    bytes to bank 4 moved title_shown from #4AA3 to #4AD8, the sprite byte
    underneath changed, and dismiss_title started returning while the title
    was still on the screen. The ENTER that followed went into the title,
    which ignores it, and boot_quick raised "could not get past the mission
    briefing" -- a message about a screen this had never reached. Same shape
    as the three failures the 3+3+2 repack shook loose.
    """
    sym = symbols()
    if "TITLE_SHOWN" not in sym:
        return
    for _ in range(6):
        if not read_bank4(c, sym["TITLE_SHOWN"], 1)[0]:
            return
        c.key_down(cpc.KEY_SPACE)
        c.run_frames(25)
        c.key_up(cpc.KEY_SPACE)
        c.run_frames(20)
    raise RuntimeError("could not get past the title screen")


def wait_for_briefing(c: cpc.CPC, frames: int = 600) -> bool:
    """Give a briefing that is on its way a chance to appear.

    A jump is not instant, and it is now a long way from it. mis_jump runs the
    VANISH to completion first -- 359 emulator frames measured since the wipe
    was slowed by ten, and never fewer than 324 whatever is on the screen -- then
    increments mis_index, writes the fleet to the DISC (a kilobyte, with the
    drive spinning up, so about a third of a second), and only then opens the
    briefing. For that whole stretch mis_index already says the new mission and
    mis_briefing still says zero.

    THE DEFAULT IS SIZED ON THE VANISH and has to be. It was 80 frames, which
    was generous against the old 35-frame sweep and is less than a quarter of
    the new one -- so every test that jumped would have found no briefing,
    fallen through to pressing ENTER at a screen that was not up yet, and
    reported something that had nothing to do with what it was testing.

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
            #  ...and out through the wipe, if this briefing was a jump's.
            wait_for_jump_wipe(c)
            return
        c.key_down(cpc.KEY_ENTER)
        c.run_frames(25)
        c.key_up(cpc.KEY_ENTER)
        c.run_frames(20)
    raise RuntimeError("could not get past the mission briefing")


def wait_for_jump_wipe(c: cpc.CPC, frames: int = 1400) -> bool:
    """Let the jump's reveal finish before handing the machine back.

    Dismissing a briefing that a JUMP put up starts the second half of the
    wipe: a bar crosses each ship and the mission appears behind it, and
    everything ahead of a bar is black while it does. The world is stopped
    under it, so a test that ran frames here would be watching a still
    picture -- and one that read PIXELS would read a masked one, which is what
    test_enemies_draw_in_the_enemy_colour did: it placed a picket, ran forty
    frames and found one pen-3 pixel, because the bars had not reached them.

    THE REVEAL IS SEVENTEEN SECONDS NOW, not one and three quarters -- 857
    emulator frames measured -- so the BOUND is 1400 rather than 300. That is
    the single largest thing the slowdown costs the suite: about forty tests
    jump, and each of them now waits out roughly 1200 frames of transition it
    is not interested in.

    THE STEP STAYS AT FIVE, and that is worth a line because coarsening it to
    ten is the obvious economy and it is not free. It decides how many LIVE
    frames run before the machine is handed back, and tools/balance.py comes
    out with a different campaign at 5 and at 10 -- the same size of swing as
    the whole ten-times-slower wipe produces. Two hundred and eighty read_ram
    calls a jump is nothing; a measuring tool that moves when the harness's
    poll interval moves is not.

    Same shape as wait_for_briefing one level up, and bounded for the same
    reason: most briefings are not a jump's and never start a sweep at all --
    which is why the bound is not simply raised until nothing can hit it.
    """
    sym = symbols()
    if "JFX_MODE" not in sym:
        return False
    for _ in range(frames // 5):
        if not c.read_ram(sym["JFX_MODE"], 1)[0]:
            return True
        c.run_frames(5)
    return False


def boot_quick(frames: int = 40, briefing: bool = False,
               disc: bool = True) -> cpc.CPC:
    """Let the firmware boot, then drop DISC.BIN in at #4000 and jump to it.

    This is exactly what `RUN"DISC` ends up doing, minus AMSDOS loading the
    file -- the same relocating stub runs, so the code under test is
    identical. Use boot_disc() when the thing being tested IS the loading.

    THE DISC IS IN THE DRIVE, and it has to be. ALL EIGHT sprite libraries are
    on the disc as raw sectors -- bank 4 carries none of them since the 3+3+2
    repack -- and lib_load reads them into banks 5-7 during demo_init. Boot
    without one and the game runs perfectly well but draws every ship as a
    painted block, which is what `disc=False` is for and what the fallback
    tests use.

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


def pin_rng(c: cpc.CPC, seed: int = 0x1234) -> None:
    """Pin the game's random sequence, so a test that spawns a wave is not flaky.

    src/sys/rand.asm seeds itself from sys_tick_50hz at the moment of the FIRST
    keypress and never again -- and every boot_quick presses SPACE past the
    title and ENTER past the briefing, so that stir is already spent by the time
    a test is handed the machine. Writing the state here therefore owns the
    sequence for the rest of the run.

    Anything but zero will do; the recurrence has zero as a fixed point and
    would hand back the same byte forever.
    """
    if seed == 0:
        raise ValueError("zero is a fixed point of the xorshift")
    sym = symbols()
    c.write_ram(sym["SYS_RNG"], bytes([seed & 0xFF, (seed >> 8) & 0xFF]))


def force_wave(c: cpc.CPC, sym: dict[str, int], within: int = 2) -> None:
    """Bring the next attack wave forward to (almost) now.

    The clock is three minutes of GAME frames -- 900 of them -- which is a long
    time to emulate and is not what most of these tests are about. Writing
    wave_next moves the arrival without touching the arithmetic that decides
    what arrives, and tests/test_waves.TestTheClock is what checks the clock
    itself.
    """
    now = int.from_bytes(c.read_ram(sym["MIS_TIMER"], 2), "little")
    target = min(now + within, 0xFFFF)
    c.write_ram(sym["WAVE_NEXT"], bytes([target & 0xFF, target >> 8]))


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


#  Two seconds of emulated time, which is ten GAME frames at the rate this
#  actually runs. It was 400,000 -- and 400 ms is TWO game frames, which is not
#  a budget, it is a coin toss.
#
#  The frames right after a briefing is dismissed are the heaviest the game
#  ever runs: mis_wipe clears all 16,000 bytes of the back buffer twice, the
#  HUD repaints into both buffers, the context bar does the same for its strip
#  and so does the hull row. run_to_stable_point is called immediately after
#  boot_quick, which is exactly when those frames happen -- so the old budget
#  could be spent inside ONE demo_update without the frame loop ever reaching
#  scr_wait_vsync at all. Adding half a per cent to the frame tipped it over,
#  and six tests about bank paging and size tiers failed with "never caught the
#  frame loop", which says nothing whatever about what was wrong.
#
#  It costs nothing to raise: the search returns the moment it lands.
STABLE_POINT_US = 2_000_000


def run_until_pc_in(c: cpc.CPC, lo: int, hi: int,
                    max_us: int = STABLE_POINT_US) -> bool:
    """Step until the CPU is executing inside [lo, hi), or give up.

    Needed because the game's own data structures are only consistent at
    certain points in the frame. Reading `phase3_visible` while
    `phase3_project` is halfway through rebuilding it gives a count that does
    not match the array beside it -- a race in the TEST, not in the game.

    Steps in 100 microsecond slices, which is fine enough to land inside a
    short spin loop like scr_wait_vsync. `max_us` has to cover several GAME
    frames, not several emulator frames -- see STABLE_POINT_US.
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


def playfield_lit(c: cpc.CPC, sym: dict[str, int], bottom: int = 168) -> int:
    """Count the non-empty bytes of the TACTICAL VIEW in the buffer on show.

    From spr_clip_top down, and both edges matter. The screen has permanent
    chrome at each end -- the context bar's forty characters are about 330 lit
    bytes and the HUD's two rows about a hundred -- and a test that counts
    either is measuring furniture that never moves. It swamps whatever the
    test was actually asking about: three of them started failing the day the
    bar arrived, and every one of them was counting the same 330 bytes on both
    sides of its own comparison.
    """
    ram = c.read_ram(front_buffer(c), 0x4000)
    return sum(1 for y in range(sym["CTX_BAR_H"], bottom) for x in range(80)
               if ram[screen_offset(y, x)])


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


BANK_WINDOW = 0x4000
SPRITE_RAW = os.path.join(BUILD, "sprites.raw")

_BANK4_SENTINEL: tuple[int, bytes] | None = None


def _bank4_sentinel() -> tuple[int, bytes]:
    """An address in bank 4, and the bytes the build put there.

    class_tag is eight three-letter ship tags back to back -- "INT\\0MTH\\0..."
    -- so it is TEXT, and text of that shape does not occur in a sprite
    library. Comparing sixteen bytes of it against build/sprites.raw is a
    reliable answer to "is bank 4 under the window at this instant".
    """
    global _BANK4_SENTINEL
    if _BANK4_SENTINEL is None:
        addr = symbols()["CLASS_TAG"]
        with open(SPRITE_RAW, "rb") as f:
            image = f.read()
        off = addr - BANK_WINDOW
        _BANK4_SENTINEL = (addr, image[off:off + 16])
    return _BANK4_SENTINEL


def read_bank4(c: cpc.CPC, addr: int, size: int, tries: int = 60) -> bytes:
    """Read bank 4 through the CPU's view, waiting for it to be under the window.

    BANK 4 IS THE RESTING STATE, NOT THE ONLY STATE. class_tier_addr pages a
    sprite library in for every ship it draws, and blitting is about a third of
    the frame -- so `peek` at an arbitrary emulator-frame boundary has a real
    chance of reading a sprite library instead of the mission table, the class
    data or the context bar's flags.

    That chance used to be small because the interceptor's library WAS in bank
    4 and the fleet is nearly all interceptors, so the window sat still for
    most of the draw. The 3+3+2 repack moved every library out, and the same
    reads started coming back as #FF and #00: a mission descriptor claiming
    eight enemies where the table says none, a hull table giving a percentage
    four points out, ctx_dirty reading 255. Measured on mission 1, four samples
    in forty landed with a sprite bank up.

    None of that is a fault in the game -- class_blit_done always puts bank 4
    back. It is a fault in reading a moving machine, and this is the fix:
    check a sentinel that only bank 4 has, and run a frame and look again if it
    is not there. Costs sixteen peeks when the window is already at rest, which
    is the usual case and always the case while a static screen is up.

    Use read_cpu instead when the test has deliberately paged another bank in.
    """
    sentinel, want = _bank4_sentinel()
    for _ in range(tries):
        if read_cpu(c, sentinel, len(want)) == want:
            return read_cpu(c, addr, size)
        c.run_frames(1)
    raise RuntimeError(
        "bank 4 never came back under the window -- either the machine is not "
        "running the game, or something pages it out and does not put it back")


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
