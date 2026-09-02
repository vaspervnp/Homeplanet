"""`T` on the title screen: the tutorial stage.

Three kinds of test here, and the middle one is the point.

**The campaign must survive it.** The tutorial is reached from the title
screen, which is exactly where somebody with a saved game arrives, so anything
that touched mis_index, the fleet or FLEET.DAT would destroy a game in
progress. TestTheCampaignIsNotTouched boots from a disc that already has a
mission-5 save on it, plays the tutorial, leaves, and reads the campaign back
-- and reading it back IS reading the disc, because leaving the tutorial
re-runs demo_init's own fleet_disc_load rather than restoring a snapshot.

**Every gate wants two tests.** "The tutorial advanced" is exactly the
assertion that passes when a step advanced for the wrong reason, which is the
failure mode a gated tutorial has -- the same blind spot as the squadron tests
that counted ships and the combat tests that counted kills. So each gate is
driven twice: do the WRONG thing and assert it does not move, then the right
thing and assert it does. Cancelling the move disc with ESC is not confirming
it with ENTER; pressing `0` without having panned first is not centring the
view; killing the hostile without ever giving an attack order is not attacking.

**And it has to be finishable.** TestTheWholeThing walks all sixteen steps with
real key presses and nothing poked at all. The gate tests poke tut_step to get
to the step under test, which is honest -- the gate is real Z80 code reacting
to real keys either way -- but only that one test says the sequence joins up.
"""

from __future__ import annotations

import os
import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

sys.path.insert(0, os.path.join(h.ROOT, "tools"))
import discbanks  # noqa: E402

FIRST_CHAR = 32
LAST_CHAR = 90
CHAR_H = 8
CHAR_W_BYTES = 2

#  READ, NOT MIRRORED. A copy of this number fails the day a step is added,
#  in the vocabulary of whatever the test was really about -- which is the
#  lesson tests/test_waves.py already learned about WAVE_FIRST_FRAMES.
TUT_STEPS = h.symbols()["TUT_STEPS"]
TUT_TEXT_CHARS = 32

ENT_SIZE = 20
ENT_X, ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_ORDER = 0, 9, 10, 11, 12, 13
F_ACTIVE, F_ENEMY = 1, 2
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER = 0, 1, 2
CLASS_SALVAGE = 6
ENT_ORDER_ATTACK = 2

#  Step indices, 0-based, mirrored from tut_table in src/game/tutorialrun.asm.
S_LOOK, S_ZOOM, S_PAN, S_VIEW = 0, 1, 2, 3
S_SQUAD, S_INFO, S_MOVE, S_FORM, S_SPLIT, S_DOCK = 4, 5, 6, 7, 8, 9
S_MINE, S_BUILD = 10, 11
S_TARGET, S_FIGHT, S_PAUSE, S_SALVAGE = 12, 13, 14, 15
S_LEAVE = 16


# ---------------------------------------------------------------------------
#  Reading text back off the screen
# ---------------------------------------------------------------------------
#  The same decoder tests/test_ctxbar.py uses, and it works for the same
#  reason: txt_pen_map draws one pixel pattern in the high nibble (ink 1), the
#  low one (ink 2) or both (ink 3), so folding the low nibble up recovers the
#  glyph whichever ink a line was drawn in. That is what lets one routine read
#  a white instruction and a blue step counter without being told which.
# ---------------------------------------------------------------------------
def _to_pen1(b: int) -> int:
    return (b | (b << 4)) & 0xF0


class TextReader:

    def __init__(self, font: bytes):
        self.font = font

    def glyph(self, ch: str) -> list[int]:
        i = (ord(ch) - FIRST_CHAR) * CHAR_H
        return list(self.font[i:i + CHAR_H])

    def _match(self, want) -> str:
        for code in range(FIRST_CHAR, LAST_CHAR + 1):
            g = self.glyph(chr(code))
            if all((g[r] & 0xF0, (g[r] << 4) & 0xF0) == want[r]
                   for r in range(CHAR_H)):
                return chr(code)
        return "?"

    def row(self, c: cpc.CPC, base: int, y: int, cells: int = 40) -> str:
        ram = c.read_ram(base, 0x4000)
        raw = [[ram[h.screen_offset(y + r, x)] for x in range(80)]
               for r in range(CHAR_H)]
        out = []
        for cell in range(cells):
            x = cell * CHAR_W_BYTES
            if x + 1 >= 80:
                break
            out.append(self._match(
                [(_to_pen1(raw[r][x]), _to_pen1(raw[r][x + 1]))
                 for r in range(CHAR_H)]))
        return "".join(out).rstrip()


# ---------------------------------------------------------------------------
#  A disc with a campaign already on it
# ---------------------------------------------------------------------------
def disc_with_save(mission: int, fleet: list[dict], unlocks: int) -> bytes:
    """build/homeplanet.dsk with a FLEET.DAT written onto it by hand.

    The layout is src/sys/fdc.asm's and the symbols are read out of the build
    rather than copied, so a save block that moved would fail here rather than
    quietly write rubbish. What makes this honest is that the GAME's own loader
    is what reads it: if a byte of this were in the wrong place,
    fleet_disc_load would reject the magic or the count and the first assertion
    in the test -- that the machine came up on the saved mission -- would fail.

    There is no way to get the emulator's own disc image back out again, which
    is why the save is written rather than played.
    """
    sym = h.symbols()
    block = bytearray(sym["FLEET_BLOCK_SIZE"])

    #  THE MAGIC COMES OUT OF THE BUILD. It was written here as "HP" and the
    #  record as the whole twenty-byte entity record, which was the format
    #  right up until the fleet's ceiling doubled -- 56 ships of twenty bytes
    #  do not fit two sectors, so the record is thirteen and the magic moved
    #  with it. A save that still said "HP" would be rejected outright and
    #  every test here would fail on "the machine did not come up on the saved
    #  mission", which says nothing at all about the tutorial.
    hdr = sym["FLEET_HDR_SIZE"]
    rec_size = sym["FLEET_REC_SIZE"]
    block[0] = sym["FLEET_MAGIC_0"]
    block[1] = sym["FLEET_MAGIC_1"]
    block[2] = mission
    block[3] = len(fleet)
    for i, ship in enumerate(fleet):
        #  x, y, z, yaw | class, hull, flags, squad, order | load.
        #  Three runs, as game/entity.asm lays it out.
        rec = bytearray(rec_size)
        for axis, off in enumerate((0, 2, 4)):
            v = ship["pos"][axis] & 0xFFFF
            rec[off] = v & 0xFF
            rec[off + 1] = v >> 8
        a = sym["FLEET_REC_A_LEN"]
        rec[a + 0] = ship["cls"]
        rec[a + 1] = ship["hull"]
        rec[a + 2] = F_ACTIVE
        rec[a + 3] = ship["squad"]
        block[hdr + i * rec_size:hdr + (i + 1) * rec_size] = rec

    off = sym["FLEET_UNLOCKS"] - sym["FLEET_BLOCK"]
    block[off] = sym["FLEET_UNLOCK_TAG"]
    block[off + 1] = unlocks

    disc = discbanks.Disc(h.DSK)
    size = sym["FDC_SECTOR_SIZE"]
    for s in range(sym["FLEET_BLOCK_SIZE"] // size):
        disc.write_sector(sym["FLEET_TRACK"], sym["FLEET_SECTOR"] + s,
                          bytes(block[s * size:(s + 1) * size]))
    return bytes(disc.data)


def boot_with(image: bytes) -> cpc.CPC:
    """boot_quick's path, with a disc of our own and the title left up."""
    c = cpc.CPC()
    c.run_frames(h.BOOT_FRAMES)
    if not c.insert_disc(image):
        raise RuntimeError("insert_disc failed")
    with open(h.DISC_RAW, "rb") as f:
        c.write_ram(h.LOADER_ORG, f.read())
    c.set_pc(h.symbols(h.DISC_SYM)["DISC_STUB"])
    c.run_frames(40)
    if not h.wait_for_title(c):
        raise RuntimeError("the game never reached its title screen")
    return c


# ---------------------------------------------------------------------------
class TutFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- pressing things ----------------------------------------------------
    def hold(self, key, frames=30, release=30):
        """Long enough for key_scan to see the press AND the release.

        Every command in the game is edge-triggered, and CLAUDE.md records a
        keyboard test that passed for a long time on a fifteen-frame release
        landing right by luck.
        """
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def word(self, name):
        return int.from_bytes(self.c.read_ram(self.sym[name], 2), "little")

    def banked(self, name):
        return h.read_bank4(self.c, self.sym[name], 1)[0]

    def step(self):
        return self.byte("TUT_STEP")

    def enter_tutorial(self):
        self.hold("t")
        self.c.run_frames(60)
        self.assertEqual(self.byte("TUT_ACTIVE"), 1,
                         "T on the title screen did not enter the tutorial")

    def entities(self, first=0, count=None):
        if count is None:
            count = self.sym["ENT_MAX"]
        raw = self.c.read_ram(self.sym["ENTITIES"] + first * ENT_SIZE,
                              count * ENT_SIZE)
        return [raw[i * ENT_SIZE:(i + 1) * ENT_SIZE] for i in range(count)]

    def live_fleet(self):
        """The player's region, as (class, squadron, x, y, z) for live slots."""
        out = []
        for i, r in enumerate(self.entities(0, self.sym["ENT_PLAYER_MAX"])):
            if r[ENT_FLAGS] & F_ACTIVE and not r[ENT_FLAGS] & F_ENEMY:
                out.append((i, r[ENT_CLASS], r[ENT_SQUAD], r[ENT_HULL],
                            bytes(r[0:6])))
        return out


# ---------------------------------------------------------------------------
class TestTheWords(unittest.TestCase):
    """Sixteen lines, and every one of them has to fit the row.

    src/main.asm can only check the SUM -- there is no way to ask RASM for the
    longest of sixteen strings -- and a line one character too long is not a
    build error, it is a line silently written across the step counter beside
    it. This is the exact check, taken out of the image the build produced.
    """

    def setUp(self):
        self.sym = h.symbols()
        with open(os.path.join(h.BUILD, "sprites.raw"), "rb") as f:
            self.image = f.read()

    def lines(self):
        start = self.sym["TUT_TEXT"] - 0x4000
        end = self.sym["TUT_TEXT_END"] - 0x4000
        return self.image[start:end].split(b"\0")[:-1]

    def test_there_is_a_line_for_every_step(self):
        self.assertEqual(len(self.lines()), TUT_STEPS)

    def test_no_line_runs_into_the_step_counter(self):
        for i, line in enumerate(self.lines()):
            self.assertLessEqual(
                len(line), TUT_TEXT_CHARS,
                f"step {i + 1}'s line is {len(line)} characters: {line!r}")

    def test_every_line_is_printable_by_the_font(self):
        for line in self.lines():
            for ch in line:
                self.assertTrue(FIRST_CHAR <= ch <= LAST_CHAR,
                                f"{chr(ch)!r} is not in the game's font")


# ---------------------------------------------------------------------------
class TestTheTitleScreen(TutFixture):
    """`T` has to be as findable as SPACE, and it is one letter with two
    meanings -- it is TOW once a mission is running. There is no clash on this
    screen, but the context bar exists because exactly that was invisible for
    `,` and `.`, so the screen has to SAY it."""

    def setUp(self):
        self.c = h.boot_quick(frames=250, briefing=True)
        h.wait_for_title(self.c)
        self.r = TextReader(bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H)))

    def test_the_title_names_T_beside_space(self):
        #  The SPACE prompt blinks and the tutorial line does not, so both
        #  buffers are sampled over several frames: a line drawn into one
        #  buffer and not the other is on screen every OTHER frame, which is
        #  the bug the context bar shipped with.
        #
        #  SAMPLED UNTIL IT HAS SEEN ENOUGH, NOT FOR A FIXED NUMBER OF FRAMES.
        #  The blink is counted in GAME frames -- TITLE_BLINK_BIT of them each
        #  way -- and run_frames counts 50 Hz ones, and the ratio is not a
        #  constant: the planet took this screen from 3.45 fps to 2.30, so the
        #  56 emulator frames this used to watch stopped covering even one
        #  blink period and the prompt was simply never caught alight. That is
        #  the same trap four tests fell into when the frame rate went the
        #  other way; CLAUDE.md calls it "a test whose setup is a fixed number
        #  of emulator frames is asserting on the frame rate".
        #  THE KEY, not the wording. The line read "T FOR THE TUTORIAL" -- one
        #  sentence mirroring the one above it -- until the title screen's
        #  music needed naming too and there was nowhere to put a fourth line.
        #  It is "T TUTORIAL  M MUSIC" now. What this test is about is that T
        #  is on the screen at all, beside SPACE, which is still true.
        want = ("T TUTORIAL", "PRESS SPACE TO START")
        seen = {0x8000: set(), 0xC000: set()}
        for _ in range(120):
            for base in (0x8000, 0xC000):
                seen[base].add(self.r.row(self.c, base, self.sym["TITLE_TUT_Y"]))
                seen[base].add(
                    self.r.row(self.c, base, self.sym["TITLE_PROMPT_Y"]))
            if all(w in "".join(rows)
                   for rows in seen.values() for w in want):
                break
            self.c.run_frames(4)
        for base, rows in seen.items():
            self.assertIn("T TUTORIAL", "".join(rows),
                          f"buffer #{base:04X} never says how to reach the "
                          f"tutorial; it says {sorted(rows)}")
            self.assertIn("PRESS SPACE TO START", "".join(rows),
                          f"buffer #{base:04X} lost the start prompt")

    def test_T_enters_the_tutorial(self):
        self.assertEqual(self.byte("TUT_ACTIVE"), 0)
        self.enter_tutorial()
        self.assertEqual(self.step(), 0)
        self.assertEqual(h.read_bank4(self.c, self.sym["TITLE_SHOWN"], 1)[0], 0)
        self.assertEqual(self.byte("MIS_BRIEFING"), 0,
                         "the tutorial came up behind the first mission's briefing")

    def test_space_still_starts_the_campaign(self):
        self.hold(cpc.KEY_SPACE)
        self.c.run_frames(40)
        self.assertEqual(self.byte("TUT_ACTIVE"), 0,
                         "SPACE entered the tutorial")
        self.assertEqual(self.byte("MIS_BRIEFING"), 1,
                         "SPACE did not reach the first mission's briefing")


# ---------------------------------------------------------------------------
class TestTheLineOnTheScreen(TutFixture):
    """A tutorial nobody can read is a worse failure than one that does not
    compile, so these read the instruction back off the screen through the
    machine's own font table rather than asserting on a flag."""

    def setUp(self):
        self.c = h.boot_quick(frames=250, briefing=True)
        h.wait_for_title(self.c)
        self.r = TextReader(bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H)))
        self.enter_tutorial()
        self.c.run_frames(60)

    def rows(self, samples=12):
        out = {0x8000: set(), 0xC000: set()}
        for _ in range(samples):
            for base in (0x8000, 0xC000):
                out[base].add(self.r.row(self.c, base, self.sym["HUD_ROW_C_Y"]))
            self.c.run_frames(4)
        return out

    def test_the_first_instruction_is_on_the_screen_in_both_buffers(self):
        for base, rows in self.rows().items():
            joined = "".join(rows)
            self.assertIn("ARROW KEYS TURN THE VIEW", joined,
                          f"buffer #{base:04X} does not carry the instruction; "
                          f"it reads {sorted(rows)}")
            self.assertIn(f"1/{TUT_STEPS}", joined,
                          f"buffer #{base:04X} has no step counter")

    def test_the_hull_readout_has_given_the_row_up(self):
        #  Row C is forty characters and HULL nnn% plus INCOMING take the first
        #  twenty. The tutorial owns the row while it runs, and a HULL left
        #  standing there would be written over by the instruction.
        for base, rows in self.rows(6).items():
            self.assertNotIn("HULL", "".join(rows),
                             f"buffer #{base:04X} still carries the hull readout")

    def test_the_line_changes_when_a_step_is_satisfied(self):
        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(150)
        self.c.key_up(cpc.KEY_LEFT)
        self.c.run_frames(60)
        self.assertEqual(self.step(), S_ZOOM, "turning the camera did nothing")
        joined = "".join("".join(v) for v in self.rows(8).values())
        self.assertIn("Z AND X ZOOM IN AND OUT", joined)
        self.assertIn(f"2/{TUT_STEPS}", joined)


# ---------------------------------------------------------------------------
class TestTheCampaignIsNotTouched(TutFixture):
    """The single most likely way to ship this broken.

    A disc with a mission-5 save on it, a whole tutorial played from the title
    screen, and the campaign read back afterwards -- and reading it back IS
    reading the disc, because tut_exit re-runs demo_init's fleet_disc_load
    rather than putting a snapshot back. If the tutorial had written FLEET.DAT
    the reload would hand back the tutorial's own six ships on mission 1.
    """

    SAVED = [
        dict(cls=CLASS_MOTHERSHIP, hull=255, squad=0, pos=(0, 0, 0)),
        dict(cls=CLASS_INTERCEPTOR, hull=201, squad=1, pos=(1111, 222, 3333)),
        dict(cls=CLASS_INTERCEPTOR, hull=202, squad=1, pos=(-1111, -222, 3333)),
        dict(cls=CLASS_HARVESTER, hull=203, squad=3, pos=(2222, 0, -1000)),
        dict(cls=CLASS_INTERCEPTOR, hull=204, squad=3, pos=(-2222, 0, -1000)),
    ]
    MISSION = 4                             # 0-based: the fifth
    UNLOCKS = 1                             # CAMP_UNLOCK_FRIGATE

    def setUp(self):
        self.c = boot_with(disc_with_save(self.MISSION, self.SAVED, self.UNLOCKS))

    def assert_campaign_is_the_saved_one(self, when):
        self.assertEqual(self.byte("MIS_INDEX"), self.MISSION,
                         f"{when}: the campaign is on the wrong mission")
        self.assertEqual(self.byte("MIS_SAVED"), 1,
                         f"{when}: the game has forgotten there is a save")
        self.assertEqual(self.byte("CAMPAIGN_UNLOCKS"), self.UNLOCKS,
                         f"{when}: what the campaign had unlocked is gone")
        got = [(cls, squad, hull) for _, cls, squad, hull, _ in self.live_fleet()]
        want = [(s["cls"], s["squad"], s["hull"]) for s in self.SAVED]
        self.assertEqual(got, want, f"{when}: the fleet is not the saved one")

    def test_the_save_is_read_at_boot(self):
        #  Also the check that disc_with_save writes what fleet_disc_load
        #  reads: a byte out of place here and the magic or the count is
        #  rejected, so everything else in this class would be measuring a
        #  fresh mission 1 instead.
        self.assert_campaign_is_the_saved_one("at boot")

    def test_the_tutorial_leaves_the_campaign_alone_while_it_runs(self):
        self.assert_campaign_is_the_saved_one("at boot")
        self.enter_tutorial()
        self.c.run_frames(120)
        #  The entity table IS the tutorial's now -- that is the whole point of
        #  a separate stage -- but nothing the campaign is rebuilt from moved.
        self.assertEqual(len(self.live_fleet()), 1 + self.sym["TUT_SHIPS"],
                         "the tutorial did not lay out its own fleet")
        self.assertEqual(self.byte("MIS_INDEX"), self.MISSION,
                         "the tutorial moved the campaign's mission index")
        self.assertEqual(self.byte("CAMPAIGN_UNLOCKS"), self.UNLOCKS)

    def test_the_campaign_comes_back_when_the_tutorial_is_left(self):
        self.enter_tutorial()
        self.c.run_frames(60)
        #  Straight to the last step: getting there legitimately is
        #  TestTheWholeThing's job, and what this class is about is the exit.
        self.c.write_ram(self.sym["TUT_STEP"], bytes([S_LEAVE]))
        self.c.write_ram(self.sym["TUT_FRESH"], bytes([1]))
        self.c.run_frames(20)
        self.hold("j")
        #  fleet_disc_load spins the drive up: about a third of a second.
        self.c.run_frames(200)

        self.assertEqual(self.byte("TUT_ACTIVE"), 0, "J did not leave the tutorial")
        self.assertEqual(h.read_bank4(self.c, self.sym["TITLE_SHOWN"], 1)[0], 1,
                         "leaving the tutorial did not come back to the title")
        self.assert_campaign_is_the_saved_one("after the tutorial")

    def test_the_tutorial_has_no_clock_and_no_waves(self):
        """It is not a mission, so mis_update and wave_update do not run.

        Both would be silent and both would be wrong. mis_update reads whichever
        row of mission_table the CAMPAIGN is on -- mission 5's objective is
        CLEAR -- so the tutorial's own hostile would count towards it and the
        HUD would offer JUMP three acts early; and wave_update runs off
        mis_timer, so a player still being told what the arrow keys do would
        start receiving Vekhar two minutes in.
        """
        self.enter_tutorial()
        self.c.run_frames(600)
        self.assertEqual(self.word("MIS_TIMER"), 0,
                         "the mission clock is running inside the tutorial")
        self.assertEqual(self.byte("WAVE_COUNT"), 0,
                         "an attack wave was scheduled inside the tutorial")
        self.assertEqual(self.byte("MIS_COMPLETE"), 0,
                         "the tutorial is offering the jump before its last step")

    def test_no_hostile_exists_before_the_fight(self):
        """Act 4 brings the hostile; the three before it have nothing to fight.

        improvements.md's first act is "no enemies, nothing can go wrong", and
        a hostile spawned at tut_enter would spend all of Act 1 flying at a
        player who has not been told what `A` does.
        """
        self.enter_tutorial()
        self.c.run_frames(300)
        hostiles = [i for i, r in enumerate(self.entities())
                    if r[ENT_FLAGS] & F_ACTIVE and r[ENT_FLAGS] & F_ENEMY]
        self.assertEqual(hostiles, [],
                         "the tutorial opened with something hostile on the board")

    def test_J_before_the_last_step_is_refused(self):
        self.enter_tutorial()
        self.c.write_ram(self.sym["TUT_STEP"], bytes([S_VIEW]))
        self.c.write_ram(self.sym["TUT_FRESH"], bytes([1]))
        self.c.run_frames(20)
        self.hold("j")
        self.c.run_frames(60)
        self.assertEqual(self.byte("TUT_ACTIVE"), 1,
                         "J left the tutorial from the middle of it")
        self.assertEqual(self.step(), S_VIEW, "J advanced a step it is not for")
        self.assertEqual(self.byte("MIS_INDEX"), self.MISSION,
                         "J in the tutorial moved the campaign on a mission")


# ---------------------------------------------------------------------------
class GateFixture(TutFixture):
    """One machine per act, and a helper that puts the tutorial on a step.

    Poking tut_step is short-circuiting how the player GOT there, not what the
    gate does: the gate is real Z80 code reacting to real key presses either
    way, and tut_fresh is set so the step's entry act runs exactly as it would
    have. TestTheWholeThing is what says the sequence joins up.

    The inputs a previous test in the same class may have left set are put back
    as well -- these classes share a machine, and a pan left half-done would be
    the next test's starting state.
    """

    STEP = 0

    def setUp(self):
        self.c = h.boot_quick(frames=250, briefing=True)
        h.wait_for_title(self.c)
        self.enter_tutorial()
        self.c.run_frames(40)

    def at_step(self, n):
        w = self.c.write_ram
        w(self.sym["TUT_FLAGS"], bytes([0]))
        w(self.sym["PAN_ACTIVE"], bytes([0]))
        w(self.sym["SEL_MOTHERSHIP"], bytes([0]))
        w(self.sym["CAM_PAN"], bytes(6))
        w(self.sym["VIEW_SENSORS"], bytes([0]))
        w(self.sym["ORDER_PAUSED"], bytes([0]))
        w(self.sym["DISC_ACTIVE"], bytes([0]))
        w(self.sym["ECO_BUILD_OPEN"], bytes([0]))
        w(self.sym["ORDER_TARGET"], bytes([0xFF]))
        w(self.sym["TUT_STEP"], bytes([n]))
        w(self.sym["TUT_FRESH"], bytes([1]))
        self.c.run_frames(20)               # the act runs; the gate arms
        self.assertEqual(self.step(), n, "the gate fired on its arming frame")

    def assert_stuck(self, n, what):
        self.assertEqual(self.step(), n, f"{what} advanced the tutorial")

    def assert_moved(self, n, what):
        self.assertEqual(self.step(), n + 1, f"{what} did not advance the tutorial")


# ---------------------------------------------------------------------------
class TestTheSalvageStep(GateFixture):
    """`T` sends the corvette after the hull the fight left behind.

    The gate watches the ORDER and not the key, which is the rule the head of
    tutorialrun.asm sets for every gate and which the fight one step above it
    cannot keep -- an attack order is spent in the frame it is given once the
    last hostile is dead, and a tow is a flight of several seconds.
    """

    def a_wreck_and_a_corvette(self):
        """Put a hull in the hostile region, the way a kill would."""
        slot = self.sym["ENT_PLAYER_MAX"]
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 3000))
        self.c.write_ram(base + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | 4]))
        self.c.write_ram(base + ENT_HULL, b"\x00")
        self.c.write_ram(base + ENT_CLASS, bytes([CLASS_INTERCEPTOR]))
        self.c.run_frames(20)

    def corvettes(self):
        return [s for s in range(self.sym["ENT_PLAYER_MAX"])
                if self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE
                                   + ENT_CLASS, 1)[0] == CLASS_SALVAGE
                and self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE
                                    + ENT_FLAGS, 1)[0] & F_ACTIVE]

    def test_the_stage_fields_a_corvette_in_each_squadron(self):
        """Step 9 divides a squadron and combines it again, so which half
        squadron 1 keeps is squad_split's business. With one corvette the
        stage stalled here, on a key the player had pressed correctly."""
        squads = {self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE
                                  + ENT_SQUAD, 1)[0] for s in self.corvettes()}
        self.assertEqual(squads, {1, 2},
                         "the tutorial does not field a corvette per squadron")

    def test_another_key_does_not_satisfy_it(self):
        self.at_step(S_SALVAGE)
        self.a_wreck_and_a_corvette()
        for key in ("h", "g", "b"):
            self.c.key_down(key)
            self.c.run_frames(30)
            self.c.key_up(key)
            self.c.run_frames(30)
        self.assert_stuck(S_SALVAGE, "pressing keys that are not T")

    def test_the_tow_order_is_what_satisfies_it(self):
        self.at_step(S_SALVAGE)
        self.a_wreck_and_a_corvette()
        self.c.key_down("t")
        self.c.run_frames(30)
        self.c.key_up("t")
        self.c.run_frames(40)
        self.assert_moved(S_SALVAGE, "towing the wreck")


# ---------------------------------------------------------------------------
class TestActOneLooking(GateFixture):

    def test_the_camera_has_to_turn_a_quarter_of_a_turn(self):
        self.at_step(S_LOOK)
        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(20)               # about two game frames: 16/256
        self.c.key_up(cpc.KEY_LEFT)
        self.c.run_frames(30)
        self.assert_stuck(S_LOOK, "a nudge of the camera")

        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(150)
        self.c.key_up(cpc.KEY_LEFT)
        self.c.run_frames(40)
        self.assert_moved(S_LOOK, "turning the camera a quarter turn")

    def test_the_zoom_has_to_move_both_ways(self):
        self.at_step(S_ZOOM)
        for _ in range(3):
            self.hold("z")
        self.assert_stuck(S_ZOOM, "zooming in only")
        for _ in range(4):
            self.hold("x")
        self.assert_moved(S_ZOOM, "zooming in and then out")

    def test_centring_means_nothing_until_the_view_has_been_panned(self):
        self.at_step(S_PAN)
        self.hold("0")
        self.assert_stuck(S_PAN, "pressing 0 without having panned")

        self.hold("p")
        self.c.key_down(cpc.KEY_RIGHT)
        self.c.run_frames(60)
        self.c.key_up(cpc.KEY_RIGHT)
        self.c.run_frames(30)
        self.assert_stuck(S_PAN, "panning away")
        self.hold("0")
        self.assert_moved(S_PAN, "panning away and then centring")

    def test_the_sensor_view_has_to_come_back(self):
        self.at_step(S_VIEW)
        self.hold("s")
        self.assertEqual(self.byte("VIEW_SENSORS"), 1)
        self.assert_stuck(S_VIEW, "switching to sensors")
        self.hold("s")
        self.assert_moved(S_VIEW, "switching to sensors and back")


# ---------------------------------------------------------------------------
class TestActTwoTheFleet(GateFixture):

    def test_an_empty_squadron_is_not_a_selection(self):
        self.at_step(S_SQUAD)
        self.assertEqual(self.byte("SQUAD_SEL"), 1)
        self.hold("5")
        self.assertEqual(self.byte("SQUAD_SEL"), 1,
                         "squad_select took a squadron with no ships in it")
        self.assert_stuck(S_SQUAD, "pressing a number with no squadron behind it")
        self.hold("2")
        self.assertEqual(self.byte("SQUAD_SEL"), 2,
                         "the tutorial's fleet is not two squadrons")
        self.assert_moved(S_SQUAD, "selecting the other squadron")

    def test_the_breakdown_has_to_be_closed_again(self):
        self.at_step(S_INFO)
        self.hold("i")
        self.assertEqual(self.banked("INFO_SHOWN"), 1)
        self.assert_stuck(S_INFO, "opening the squadron breakdown")
        self.hold(cpc.KEY_ESC)
        self.assert_moved(S_INFO, "opening the breakdown and closing it")

    def test_cancelling_the_move_disc_is_not_confirming_it(self):
        self.at_step(S_MOVE)
        before = self.c.read_ram(self.sym["SQUAD_DEST"], 6)

        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1, "ENTER did not open the disc")
        self.c.key_down(cpc.KEY_RIGHT)
        self.c.run_frames(60)
        self.c.key_up(cpc.KEY_RIGHT)
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.byte("DISC_ACTIVE"), 0)
        self.assertEqual(self.c.read_ram(self.sym["SQUAD_DEST"], 6), before,
                         "ESC moved the squadron's station")
        self.assert_stuck(S_MOVE, "opening the disc and cancelling it")

        self.hold(cpc.KEY_ENTER)
        self.c.key_down(cpc.KEY_RIGHT)
        self.c.run_frames(60)
        self.c.key_up(cpc.KEY_RIGHT)
        self.hold(cpc.KEY_ENTER)
        self.assertNotEqual(self.c.read_ram(self.sym["SQUAD_DEST"], 6), before,
                            "ENTER did not move the squadron's station")
        self.assert_moved(S_MOVE, "issuing a move order")

    def test_the_formation_has_to_change(self):
        self.at_step(S_FORM)
        self.hold("g")
        self.assert_stuck(S_FORM, "pressing another order key")
        self.hold("f")
        self.assert_moved(S_FORM, "cycling the formation")

    def test_dividing_is_only_half_of_it(self):
        self.at_step(S_SPLIT)
        self.hold("d")
        self.assert_stuck(S_SPLIT, "dividing a squadron")
        self.hold("c")
        self.assert_moved(S_SPLIT, "dividing a squadron and combining it again")

    def test_the_station_has_to_land_on_the_mothership(self):
        self.at_step(S_DOCK)
        self.hold("g")
        self.assert_stuck(S_DOCK, "pressing another order key")
        self.hold("r")
        self.assert_moved(S_DOCK, "stationing the squadron on the Mothership")


# ---------------------------------------------------------------------------
class TestActThreeTheEconomy(GateFixture):

    def test_the_harvesters_have_to_be_sent_and_come_back(self):
        self.at_step(S_MINE)
        before = self.word("ECO_RU")
        self.c.run_frames(400)
        self.assertEqual(self.word("ECO_RU"), before,
                         "RU arrived with nobody sent to fetch it")
        self.assert_stuck(S_MINE, "waiting without pressing H")

        self.hold("h")
        for _ in range(60):
            if self.step() != S_MINE:
                break
            self.c.run_frames(20)
        self.assertGreater(self.word("ECO_RU"), before,
                           "the harvesters never delivered anything")
        self.assert_moved(S_MINE, "sending the harvesters out")

    def test_opening_the_yard_is_not_ordering_a_ship(self):
        self.at_step(S_BUILD)
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1)
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 0)
        self.assert_stuck(S_BUILD, "opening the yard and shutting it again")

        self.hold("b")
        self.hold(cpc.KEY_ENTER)
        self.assertLess(self.byte("ECO_BUILD_CLASS"), self.sym["CLASS_COUNT"],
                        "ENTER did not put anything on the slipway")
        self.assert_stuck(S_BUILD, "ordering a ship with the panel still open")
        self.hold(cpc.KEY_ESC)
        self.assert_moved(S_BUILD, "ordering a ship and shutting the panel")


# ---------------------------------------------------------------------------
class TestActFourTheFight(GateFixture):

    def with_enemy(self, n):
        """Step 13's entry act is what puts the hostile on the board, so a test
        about step 14 has to come through it."""
        self.at_step(S_TARGET)
        self.assertTrue(self.hostiles(), "the fight's hostile was never spawned")
        if n != S_TARGET:
            self.c.write_ram(self.sym["TUT_STEP"], bytes([n]))
            self.c.write_ram(self.sym["TUT_FLAGS"], bytes([0]))
            self.c.write_ram(self.sym["TUT_FRESH"], bytes([1]))
            self.c.run_frames(20)

    def hostiles(self):
        return [i for i, r in enumerate(self.entities())
                if r[ENT_FLAGS] & F_ACTIVE and r[ENT_FLAGS] & F_ENEMY]

    def test_the_hostile_lands_in_the_enemys_own_region(self):
        self.with_enemy(S_TARGET)
        for i in self.hostiles():
            self.assertGreaterEqual(
                i, self.sym["ENT_PLAYER_MAX"],
                "the tutorial spawned a hostile into the fleet's own slots")

    def test_picking_a_class_is_not_picking_a_target(self):
        self.with_enemy(S_TARGET)
        #  With the build panel open, `,` and `.` walk the price list instead.
        #  That is the confusion the context bar exists to end, and it is the
        #  reason this step is taught the way it is.
        self.c.write_ram(self.sym["ECO_BUILD_OPEN"], bytes([1]))
        self.hold(".")
        self.assert_stuck(S_TARGET, "stepping the build list")
        self.c.write_ram(self.sym["ECO_BUILD_OPEN"], bytes([0]))
        self.hold(".")
        self.assertNotEqual(self.byte("ORDER_TARGET"), 0xFF,
                            "nothing was targeted")
        self.assert_moved(S_TARGET, "stepping the target")

    def test_the_hostile_dying_on_its_own_is_not_an_attack(self):
        self.with_enemy(S_FIGHT)
        for i in self.hostiles():
            addr = self.sym["ENTITIES"] + i * ENT_SIZE + ENT_FLAGS
            self.c.write_ram(addr, bytes([0]))
        self.c.run_frames(40)
        self.assertEqual(self.hostiles(), [])
        self.assert_stuck(S_FIGHT, "the hostile going away by itself")

        self.hold("a")
        self.c.run_frames(40)
        self.assert_moved(S_FIGHT, "giving an attack order")

    def test_an_attack_order_alone_is_not_enough(self):
        self.with_enemy(S_FIGHT)
        self.hold("a")
        self.c.run_frames(40)
        self.assertTrue(any(r[ENT_ORDER] == ENT_ORDER_ATTACK
                            for r in self.entities(0, self.sym["ENT_PLAYER_MAX"])
                            if r[ENT_FLAGS] & F_ACTIVE),
                        "A did not put the squadron under an attack order")
        self.assert_stuck(S_FIGHT, "attacking a hostile that is still alive")

    def test_the_pause_has_to_be_lifted(self):
        self.at_step(S_PAUSE)
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        self.assert_stuck(S_PAUSE, "pausing the battle")
        self.hold(cpc.KEY_SPACE)
        self.assert_moved(S_PAUSE, "pausing and resuming")


# ---------------------------------------------------------------------------
class TestTheWholeThing(TutFixture):
    """Sixteen steps with real key presses and nothing poked at all.

    Every other test here starts the tutorial where it wants it. This one is
    the only thing that says the sequence joins up -- that each step is
    reachable from the one before it with the keys its own line names, and that
    a player can actually finish it.
    """

    def setUp(self):
        self.c = h.boot_quick(frames=250, briefing=True)
        h.wait_for_title(self.c)
        self.enter_tutorial()
        self.c.run_frames(40)

    def expect(self, n, what):
        self.assertEqual(self.step(), n,
                         f"after {what} the tutorial is on step {self.step() + 1}, "
                         f"not {n + 1}")

    def test_a_player_can_get_all_the_way_through_it(self):
        c = self.c
        #  1 -- the camera
        c.key_down(cpc.KEY_LEFT)
        c.run_frames(150)
        c.key_up(cpc.KEY_LEFT)
        c.run_frames(40)
        self.expect(S_ZOOM, "turning the camera")

        #  2 -- the zoom, both ways
        for _ in range(2):
            self.hold("z")
        for _ in range(3):
            self.hold("x")
        self.expect(S_PAN, "zooming")

        #  3 -- pan, then centre
        self.hold("p")
        c.key_down(cpc.KEY_RIGHT)
        c.run_frames(60)
        c.key_up(cpc.KEY_RIGHT)
        c.run_frames(30)
        self.hold("0")
        self.expect(S_VIEW, "panning and centring")

        #  4 -- sensors, and back
        self.hold("s")
        self.hold("s")
        self.expect(S_SQUAD, "the sensor view")

        #  5 -- the other squadron
        self.hold("2")
        self.expect(S_INFO, "selecting a squadron")

        #  6 -- the breakdown
        self.hold("i")
        self.hold(cpc.KEY_ESC)
        self.expect(S_MOVE, "the squadron breakdown")

        #  7 -- a move order
        self.hold(cpc.KEY_ENTER)
        c.key_down(cpc.KEY_RIGHT)
        c.run_frames(60)
        c.key_up(cpc.KEY_RIGHT)
        self.hold(cpc.KEY_ENTER)
        self.expect(S_FORM, "the move disc")

        #  8 -- the formation
        self.hold("f")
        self.expect(S_SPLIT, "cycling the formation")

        #  9 -- divide, then combine
        self.hold("d")
        self.hold("c")
        self.expect(S_DOCK, "dividing and combining")

        #  10 -- home to the Mothership
        self.hold("r")
        self.expect(S_MINE, "stationing on the Mothership")

        #  11 -- the harvesters, which have to fly out and come back
        self.hold("h")
        for _ in range(80):
            if self.step() != S_MINE:
                break
            c.run_frames(20)
        self.expect(S_BUILD, "sending the harvesters out")

        #  12 -- the yard
        self.hold("b")
        self.hold(cpc.KEY_ENTER)
        self.hold(cpc.KEY_ESC)
        self.expect(S_TARGET, "ordering a ship")

        #  13 -- a target
        self.hold(".")
        self.expect(S_FIGHT, "stepping the target")

        #  14 -- the fight
        self.hold("a")
        for _ in range(120):
            if self.step() != S_FIGHT:
                break
            c.run_frames(20)
        self.expect(S_PAUSE, "the fight")

        #  15 -- the pause
        self.hold(cpc.KEY_SPACE)
        self.hold(cpc.KEY_SPACE)
        self.expect(S_SALVAGE, "the tactical pause")

        #  16 -- the corvette fetches what the fight left behind
        self.hold("t")
        for _ in range(80):
            if self.step() != S_SALVAGE:
                break
            c.run_frames(20)
        self.expect(S_LEAVE, "towing the wreck")

        #  ...and the HUD offers the jump, exactly as a real mission does.
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "the last step did not put JUMP up in the HUD")

        #  16 -- out
        self.hold("j")
        c.run_frames(200)
        self.assertEqual(self.byte("TUT_ACTIVE"), 0, "J did not leave")
        self.assertEqual(h.read_bank4(self.c, self.sym["TITLE_SHOWN"], 1)[0], 1,
                         "leaving did not come back to the title screen")


if __name__ == "__main__":
    unittest.main()
