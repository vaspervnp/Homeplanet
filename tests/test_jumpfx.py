"""The jump wipe: a line that sweeps the ships away, and back.

"Θέλω εφέ για το jump των πλοίων. Θα εμφανίζεται μια γραμμή στην μια πλευρά
τους που θα μετακινείται μέχρι την άλλη, σβήνοντάς τα. Στην επόμενη πίστα θα
συμβαίνει το ανάποδο για να εμφανιστούν."

EVERY TEST HERE READS BOTH SCREEN BUFFERS, and that is the point of the file
rather than a habit. The display page-flips, so an effect painted into one
buffer and not the other is on screen every OTHER frame -- flicker on the
machine and nothing at all in a test that reads front_buffer(c). The context
bar, the briefing and the title screen's credit line have each shipped that
bug; a transition is the likeliest thing yet to have it, because it looks
perfect in a single screenshot.

The other trap this file is built around: A SCREENSHOT OF A SWEEP LIES. The
emulator's framebuffer is composed as the beam scans, so grabbing it mid-frame
gives the top of one step and the bottom of the one before -- which reads
exactly like a torn line. These tests read screen RAM instead, and always the
buffer on SHOW: the other one is the one being drawn into.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

import cpc

#  Mirrored from src/game/jumpfx.asm and src/demo/phase4.asm.
JFX_NONE, JFX_OUT, JFX_IN = 0, 1, 2
CTX_BAR_H, HUD_TOP = 10, 168
SOLID_INK_1 = 0xF0
WIDTH = 80


class WipeFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- state ---------------------------------------------------------------
    def mode(self):
        return self.c.read_ram(self.sym["JFX_MODE"], 1)[0]

    def col(self):
        return self.c.read_ram(self.sym["JFX_COL"], 1)[0]

    def briefing(self):
        return self.c.read_ram(self.sym["MIS_BRIEFING"], 1)[0]

    # -- the screen ----------------------------------------------------------
    def buffer(self, base):
        return self.c.read_ram(base, 0x4000)

    @staticmethod
    def line_at(ram):
        """Which byte columns are a full-height run of ink 1, i.e. the line.

        The whole playfield and nothing less: a partial column is a fill caught
        halfway, which happens in the buffer being drawn into and never in the
        one on show.
        """
        return [x for x in range(WIDTH)
                if all(ram[h.screen_offset(y, x)] == SOLID_INK_1
                       for y in range(CTX_BAR_H, HUD_TOP))]

    @staticmethod
    def lit_columns(ram):
        return {x for x in range(WIDTH)
                if any(ram[h.screen_offset(y, x)]
                       for y in range(CTX_BAR_H, HUD_TOP))}

    @staticmethod
    def strip_lit(ram):
        """Lit bytes in the two strips the sweep must never reach."""
        bar = sum(1 for y in range(0, CTX_BAR_H) for x in range(WIDTH)
                  if ram[h.screen_offset(y, x)])
        hud = sum(1 for y in range(HUD_TOP, 200) for x in range(WIDTH)
                  if ram[h.screen_offset(y, x)])
        return bar, hud

    @staticmethod
    def bar_bytes(ram):
        """Every byte of the context bar's strip, to compare against itself.

        Bytes rather than a count, because the interesting failure is a row of
        it being scrubbed out and the bar is only repainted when its WORDS
        change -- so a hole in it is permanent and a count could hide one
        behind an unrelated repaint.
        """
        return bytes(ram[h.screen_offset(y, x)]
                     for y in range(0, CTX_BAR_H) for x in range(WIDTH))

    def front(self):
        return self.buffer(h.front_buffer(self.c))

    # -- driving -------------------------------------------------------------
    def sample_sweep(self, want, limit=400):
        """Follow a sweep, one emulator frame at a time.

        Returns a list of (col, front_base, line_columns, lit_columns) and a
        dict of {buffer base: the line positions that buffer was seen holding}.
        Reading the buffer on SHOW is what makes "the line is one unbroken
        column" a safe assertion -- the back buffer is mid-fill about half the
        time, by construction.
        """
        seen = []
        per_buffer: dict[int, list[int]] = {h.SCREEN_A: [], h.SCREEN_B: []}
        for _ in range(limit):
            if self.mode() != want:
                if seen:
                    break
            else:
                base = h.front_buffer(self.c)
                ram = self.buffer(base)
                line = self.line_at(ram)
                seen.append((self.col(), base, line, self.lit_columns(ram)))
                if len(line) == 1:
                    per_buffer[base].append(line[0])
            self.c.run_frames(1)
        return seen, per_buffer


class TestTheVanish(WipeFixture):
    """`J`: the line crosses the mission and the mission is not there after it."""

    def press_jump(self):
        #  Mission 1's objective is ARRIVE, so it is complete from the first
        #  frame and `J` is live immediately.
        self.assertEqual(self.c.read_ram(self.sym["MIS_COMPLETE"], 1)[0], 1)
        self.c.key_down("j")

    def test_the_line_crosses_the_playfield_left_to_right(self):
        self.press_jump()
        seen, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        self.assertGreater(len(seen), 8, "the sweep was over before it was seen")
        positions = [line[0] for _, _, line, _ in seen if len(line) == 1]
        self.assertGreater(len(positions), 5,
                           f"no full-height line on show during the sweep: {seen[:3]}")
        self.assertEqual(positions, sorted(positions),
                         f"the line does not travel one way: {positions}")
        self.assertLess(min(positions), 12, "the line does not start at the left")
        self.assertGreater(max(positions), WIDTH - 12,
                           "the line never reaches the right-hand side")

    def test_it_erases_what_it_passes(self):
        """The whole content of the effect: nothing survives behind the line."""
        self.press_jump()
        seen, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        checked = 0
        for _, _, line, lit in seen:
            if len(line) != 1:
                continue
            behind = {x for x in lit if x < line[0]}
            self.assertFalse(behind,
                             f"the line is at {line[0]} and columns {sorted(behind)} "
                             "are still lit behind it")
            checked += 1
        self.assertGreater(checked, 5)

    def test_the_line_is_ink_1(self):
        """Section 2's ink for the fleet itself. Not 3, which is the alarm ink.

        Read WHILE the sweep is running, and off the screen: every other test
        here finds the line by looking for a column of SOLID_INK_1, so this is
        the one that says what that byte means. #F0 is pen 1, #0F is pen 2 and
        #FF is pen 3, and the three are the same pixels in different planes.
        """
        self.press_jump()
        inks = set()
        for _ in range(200):
            if self.mode() != JFX_OUT:
                if inks:
                    break
            else:
                ram = self.buffer(h.front_buffer(self.c))
                for x in self.line_at(ram):
                    inks |= {ram[h.screen_offset(y, x)]
                             for y in range(CTX_BAR_H, HUD_TOP)}
            self.c.run_frames(1)
        self.c.key_up("j")
        self.assertEqual(inks, {SOLID_INK_1},
                         f"the line is not drawn in ink 1: {sorted(inks)}")

    def test_both_buffers_carry_the_sweep(self):
        """The page-flip guard, and the reason this file exists.

        The vanish runs inside ONE game frame, so the frame loop's own flip
        never happens during it: if it painted only the buffer on show, the
        flip at the end of that frame would put the mission the player just
        watched being erased straight back on the screen.
        """
        self.press_jump()
        _, per_buffer = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")
        for base, seen in per_buffer.items():
            self.assertGreater(len(seen), 2,
                               f"buffer #{base:04X} never carried the line: "
                               f"{ {k: v for k, v in per_buffer.items()} }")

    def test_it_leaves_both_buffers_black(self):
        self.press_jump()
        self.sample_sweep(JFX_OUT)
        self.c.key_up("j")
        #  The sweep is over; the disc write is not, and the briefing is not up
        #  yet. This is the moment the screen has to be empty in both buffers.
        self.assertEqual(self.mode(), JFX_NONE)
        for base in (h.SCREEN_A, h.SCREEN_B):
            lit = self.lit_columns(self.buffer(base))
            self.assertFalse(lit,
                             f"buffer #{base:04X} still holds columns {sorted(lit)} "
                             "of the mission that was swept away")

    def test_it_stays_out_of_the_two_strips(self):
        """The HUD and the context bar are the instruments, not the view.

        They are also repainted only when what they say changes, so a sweep one
        line too far would scrub a row out of the bar and nothing would ever put
        it back -- the same trap spr_clip_top was threaded through mark_store
        to close.
        """
        #  Settle first: the bar and the HUD are painted into a buffer only
        #  when what they say changes, so a baseline taken at boot can be a
        #  buffer that has not had them yet.
        self.c.run_frames(60)
        before = {base: (self.bar_bytes(self.buffer(base)),
                         self.strip_lit(self.buffer(base)))
                  for base in (h.SCREEN_A, h.SCREEN_B)}
        for base in (h.SCREEN_A, h.SCREEN_B):
            self.assertGreater(before[base][1][0], 100,
                               f"buffer #{base:04X} has no context bar to protect")

        self.press_jump()
        seen, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")
        self.assertGreater(len(seen), 8)
        #  Nothing else is running -- the sweep stops the world -- so both
        #  strips have to come out of it byte for byte.
        for base in (h.SCREEN_A, h.SCREEN_B):
            ram = self.buffer(base)
            self.assertEqual(self.bar_bytes(ram), before[base][0],
                             f"the sweep changed the context bar in #{base:04X}")
            self.assertEqual(self.strip_lit(ram), before[base][1],
                             f"the sweep changed the strips in buffer #{base:04X}")

    def test_nothing_of_the_next_mission_shows_before_the_briefing(self):
        """The one-frame flash the wipe would otherwise have exposed.

        mis_jump lays the next mission out and opens its briefing, and the rest
        of that same frame used to go on and DRAW it -- so the flip showed the
        new mission for a frame before the briefing covered it again. Harmless
        while nobody cared what was on the screen at that instant; it undoes
        the whole sweep now.

        The briefing is told apart from the tactical view by the CONTEXT BAR:
        static_wipe clears from line 0, so a buffer that still has the bar in
        it has not been painted by the briefing yet, and its playfield must
        therefore still be the black the sweep left.
        """
        self.press_jump()
        self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        for _ in range(120):
            for base in (h.SCREEN_A, h.SCREEN_B):
                ram = self.buffer(base)
                bar, _ = self.strip_lit(ram)
                if not bar:
                    continue                # the briefing owns this buffer now
                lit = self.lit_columns(ram)
                self.assertFalse(
                    lit, f"buffer #{base:04X} drew columns {sorted(lit)} of the next "
                         "mission between the sweep and the briefing")
            if self.briefing() and not self.strip_lit(self.buffer(h.SCREEN_A))[0] \
                    and not self.strip_lit(self.buffer(h.SCREEN_B))[0]:
                return
            self.c.run_frames(1)


class TestTheReveal(WipeFixture):
    """The mission comes out from behind the same line, the same way round."""

    def setUp(self):
        #  Get past mission 1's own briefing -- which does NOT reveal, because
        #  no jump brought the player to it -- and then jump, so the briefing
        #  this fixture is holding is the one a sweep belongs to.
        self.c = h.boot_quick(frames=300)
        self.c.key_down("j")
        self.c.run_frames(25)
        self.c.key_up("j")
        if not h.wait_for_briefing(self.c, frames=200):
            self.fail("the jump never put a briefing up")

    def dismiss(self):
        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)

    def test_dismissing_a_jumps_briefing_starts_it(self):
        self.assertEqual(self.mode(), JFX_NONE)
        self.dismiss()
        #  Polled, not read once: ENTER is consumed by the next GAME frame, and
        #  a briefing frame is several emulator frames long. Reading the flag
        #  immediately after a keypress is the mistake wait_for_briefing exists
        #  to stop people making one level up.
        for _ in range(60):
            if self.mode() == JFX_IN:
                return
            self.c.run_frames(1)
        self.fail("dismissing a jump's briefing did not start the reveal")

    def test_the_line_crosses_the_playfield_left_to_right(self):
        self.dismiss()
        seen, _ = self.sample_sweep(JFX_IN)
        positions = [line[0] for _, _, line, _ in seen if len(line) == 1]
        self.assertGreater(len(positions), 4,
                           "no full-height line on show during the reveal")
        self.assertEqual(positions, sorted(positions),
                         f"the line does not travel one way: {positions}")
        self.assertLess(min(positions), 12)
        self.assertGreater(max(positions), WIDTH - 20)

    def test_nothing_shows_ahead_of_it(self):
        """The mission is drawn in full every frame; the line is what hides it."""
        self.dismiss()
        seen, _ = self.sample_sweep(JFX_IN)
        checked = 0
        for _, _, line, lit in seen:
            if len(line) != 1:
                continue
            ahead = {x for x in lit if x > line[0]}
            self.assertFalse(ahead,
                             f"the line is at {line[0]} and columns {sorted(ahead)} "
                             "are already showing ahead of it")
            checked += 1
        self.assertGreater(checked, 4)

    def test_the_mission_comes_out_behind_it(self):
        """...and it is a REVEAL rather than a line crossing an empty screen."""
        self.dismiss()
        seen, _ = self.sample_sweep(JFX_IN)
        behind = [len({x for x in lit if x < line[0]})
                  for _, _, line, lit in seen if len(line) == 1]
        self.assertTrue(behind)
        self.assertGreater(max(behind), 3,
                           "the line swept an empty screen and the mission "
                           f"appeared all at once at the end: {behind}")
        self.assertEqual(behind, sorted(behind),
                         f"the mission un-appeared behind the line: {behind}")

    def test_both_buffers_carry_the_sweep(self):
        self.dismiss()
        _, per_buffer = self.sample_sweep(JFX_IN)
        for base, seen in per_buffer.items():
            self.assertGreater(len(seen), 1,
                               f"buffer #{base:04X} never carried the line: "
                               f"{ {k: v for k, v in per_buffer.items()} }")

    def test_the_line_leaves_no_trail(self):
        """It moves by being erased, and the eraser is the ordinary dirty list.

        The line records a rectangle of its own precisely so that the next pass
        through that buffer rubs it out. Miss that and every step it takes
        stays on the screen for the rest of the mission.
        """
        self.dismiss()
        self.sample_sweep(JFX_IN)
        self.c.run_frames(60)
        self.assertEqual(self.mode(), JFX_NONE)
        for base in (h.SCREEN_A, h.SCREEN_B):
            self.assertEqual(self.line_at(self.buffer(base)), [],
                             f"buffer #{base:04X} still holds a full-height line")

    def test_it_stays_out_of_the_two_strips(self):
        """The bar by its BYTES; the HUD only by still being there.

        The simulation is frozen under this sweep -- a transition must not cost
        game time -- so nothing should move either strip at all. The HUD is
        held to the weaker check anyway because it is repainted lazily and a
        buffer can receive it in the middle of the window this watches; the
        context bar cannot move, because the context is "playing" throughout.
        """
        self.dismiss()

        #  Wait for the bar rather than counting frames. It is repainted once
        #  per buffer when the context changes, and the two frames that happens
        #  on are the mis_wipe frames -- the two slowest the game runs, a fifth
        #  of a second each -- so a fixed thirty emulator frames lands before
        #  the second buffer has ever had one.
        #  ...and wait for the two to AGREE, not merely to be non-empty: the
        #  bar is drawn a word at a time, so "has more than a hundred lit
        #  bytes" catches it halfway and the baseline is then a half-drawn bar.
        for _ in range(200):
            a, b = (self.bar_bytes(self.buffer(x))
                    for x in (h.SCREEN_A, h.SCREEN_B))
            if a == b and sum(1 for v in a if v) > 100:
                break
            self.c.run_frames(1)
        else:
            self.fail("the context bar never reached both buffers")
        before = {base: self.bar_bytes(self.buffer(base))
                  for base in (h.SCREEN_A, h.SCREEN_B)}

        seen, _ = self.sample_sweep(JFX_IN)
        self.assertTrue(seen, "the reveal was over before it was watched")
        for base in (h.SCREEN_A, h.SCREEN_B):
            ram = self.buffer(base)
            self.assertEqual(self.bar_bytes(ram), before[base],
                             f"the sweep changed the context bar in #{base:04X}")
            self.assertGreater(self.strip_lit(ram)[1], 50,
                               f"the sweep scrubbed the HUD in buffer #{base:04X}")


class TestOnlyAJumpSweeps(WipeFixture):
    """The reveal is the second half of a jump, so it belongs to jumps.

    Mission 1 is reached from the title screen and a restored campaign from the
    disc, and neither has had a line take anything away for this one to give
    back. It is also what keeps the effect out of every other test in the
    project -- every boot_quick dismisses the opening briefing, so arming this
    on every briefing gave all five hundred of them two seconds of half-masked
    playfield to start life with, and seven that read pixels failed.

    One machine per test and no second one inside a test: two CPCs in one
    process interfere, which is why this is its own class rather than two lines
    inside the reveal's.
    """

    def test_mission_one_opens_without_one(self):
        #  boot_quick has already dismissed the opening briefing.
        self.assertEqual(self.mode(), JFX_NONE,
                         "mission 1 opened with a reveal nothing led to")
        self.c.run_frames(60)
        self.assertEqual(self.mode(), JFX_NONE)
        #  ...and the playfield is whole from the first frame a test looks at.
        lit = self.lit_columns(self.front())
        self.assertGreater(max(lit) - min(lit), 30,
                           f"something is masking the playfield at boot: {sorted(lit)}")


class TestTheJumpIsStillOneAct(WipeFixture):
    """The vanish runs to completion inside mis_jump, and that is deliberate.

    A dozen tests and both measuring tools press `J` and read mis_index
    immediately afterwards. Driving the sweep from the frame loop instead would
    have meant a jump that is half done for a second and a half, and a
    "pending" state for every one of them to learn about.
    """

    def test_pressing_j_still_moves_the_mission_on(self):
        self.assertEqual(self.c.read_ram(self.sym["MIS_INDEX"], 1)[0], 0)
        h.jump_mission(self.c)
        self.assertEqual(self.c.read_ram(self.sym["MIS_INDEX"], 1)[0], 1)

    def test_a_refused_jump_sweeps_nothing(self):
        """Mission 3 has a picket, so `J` is refused until it is dead."""
        h.jump_mission(self.c)              # mission 2
        self.c.run_frames(120)
        h.jump_mission(self.c)              # mission 3
        self.assertEqual(self.c.read_ram(self.sym["MIS_INDEX"], 1)[0], 2)
        self.assertEqual(self.c.read_ram(self.sym["MIS_COMPLETE"], 1)[0], 0)

        self.c.run_frames(40)
        lit_before = self.lit_columns(self.front())
        self.c.key_down("j")
        for _ in range(30):
            self.assertNotEqual(self.mode(), JFX_OUT,
                                "a refused jump swept the screen anyway")
            self.c.run_frames(1)
        self.c.key_up("j")
        self.assertEqual(self.c.read_ram(self.sym["MIS_INDEX"], 1)[0], 2)
        self.assertTrue(lit_before, "there was nothing on the screen to keep")


if __name__ == "__main__":
    unittest.main()
