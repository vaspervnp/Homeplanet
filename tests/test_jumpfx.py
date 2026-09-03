"""The jump wipe: one short bar per ship takes it away, and gives it back.

"Θέλω εφέ για το jump των πλοίων. Θα εμφανίζεται μια γραμμή στην μια πλευρά
τους που θα μετακινείται μέχρι την άλλη, σβήνοντάς τα. Στην επόμενη πίστα θα
συμβαίνει το ανάποδο για να εμφανιστούν."

...and then: "θέλω η γραμμή του jump να μην είναι μία για όλα. Να είναι μία ανά
σκάφος. μικρή και να ξεκινάει πριν το σκάφος και να τελειώνει μετά το σκάφος."

THE GEOMETRY IS READ OUT OF THE MACHINE, NOT MIRRORED HERE. class_geom, the
JFX_* equates and phase4_vis all come off the build, so a test that says "the
bar is inside its own ship's run" is comparing the screen against the same
three numbers the Z80 used. The one thing mirrored is the arithmetic --
(sx - halfwidth) >> 2, floor -- which is phase4_blit_body's placement, and if
that ever drifts these tests are what says so.

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
import struct
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

import cpc

#  Mirrored from src/demo/phase4.asm; everything else comes off the build.
JFX_NONE, JFX_OUT, JFX_IN = 0, 1, 2
CTX_BAR_H, HUD_TOP = 10, 168
SOLID_INK_1 = 0xF0
#  A pixel's two bit planes, for the LEFTMOST pixel of a Mode 1 byte: plane 0
#  is bit 7 and plane 1 is bit 3. Mirrored from gfx_pen_mask in gfx/line.asm.
PEN_AT_PIXEL_0 = {0: 0x00, 1: 0x80, 2: 0x08, 3: 0x88}
WIDTH = 80

#  A bar is the sprite's height with JFX_VMARGIN proud at each end, so the
#  shortest one there is -- tier A -- is six lines and six margins. Anything
#  this tall and solid in one byte column is a bar and not a ship: the sprites
#  are shaded, so a column of theirs is broken up by pen 2.
BAR_MIN_RUN = 10


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

    # -- the geometry, off the machine ---------------------------------------
    def runs(self):
        """Every drawn ship's (x0, reach, left, width, top, height, band).

        phase4_vis is the list phase4_project builds and phase4_draw draws
        from; phase4_gcount is 0 for the entries phase4_group consolidated
        away, which are drawn by nothing and get no bar. class_geom is the
        blitter's own placement table.

        IT PARKS AT scr_wait_vsync FIRST, and that is not caution. phase4_project
        zeroes phase4_visible and counts it back up, so a read taken at an
        arbitrary emulator-frame boundary catches the list half built -- and
        the answer it gives is ONE ENTITY, which is a perfectly plausible
        looking fleet. test_the_bars_leave_no_trail found exactly that: it read
        a one-ship list, built one box out of it, and reported the other
        fifteen ships as a trail the bars had left. Both halves of the wipe
        reach scr_wait_vsync every frame -- the vanish has its own -- so this
        lands inside one of them either way.
        """
        h.run_to_stable_point(self.c, self.sym)
        s = self.sym
        margin = s["JFX_MARGIN"]
        vmargin = s["JFX_VMARGIN"]
        n = self.c.read_ram(s["PHASE4_VISIBLE"], 1)[0]
        vis = self.c.read_ram(s["PHASE4_VIS"], n * 6)
        gcount = self.c.read_ram(s["PHASE4_GCOUNT"], n)
        geom = self.c.read_ram(s["CLASS_GEOM"], 18)
        out = []
        for i in range(n):
            if not gcount[i]:
                continue
            e = vis[i * 6:i * 6 + 6]
            #  ...and the OTHER SIDE gets no bar: "τα εχθρικά δεν πηδάνε".
            #  Bit 7 of the class/tier byte is the side. This model has to know
            #  it or every test in this file that measures a bar against its
            #  ship's placement would go on expecting one over the picket.
            if e[5] & 0x80:
                continue
            sx = e[0] | (e[1] << 8)
            row = geom[(e[5] & 3) * 6:]
            w, sprite_h, halfw, halfh = row[0], row[1], row[2], row[3]
            left = (sx - halfw) >> 2            # arithmetic, as `sra h : rr l`
            top = e[2] - halfh
            out.append({
                "x0": left - margin,
                "reach": w + 2 * margin,
                "left": left, "w": w,
                "top": top, "h": sprite_h,
                "band_top": top - vmargin, "band_h": sprite_h + 2 * vmargin,
            })
        return out

    # -- the screen ----------------------------------------------------------
    def buffer(self, base):
        return self.c.read_ram(base, 0x4000)

    def front(self):
        return self.buffer(h.front_buffer(self.c))

    @staticmethod
    def bar_columns(ram, pen=1):
        """Byte columns holding a run of BAR_MIN_RUN rows of bar: the bars.

        A BAR IS ONE PIXEL WIDE, so this asks about the LEFTMOST PIXEL of the
        byte and not about the byte. It used to compare the whole byte against
        #F0, which was right while the bar was a four-pixel fill and finds
        nothing at all now -- every test here goes through this, so the whole
        file reported "no bars on screen" for a bar that was on the screen.

        Mode 1 packs a pixel's two planes into bit 7 and bit 3 of its byte, so
        `b & 0x88` is the leftmost pixel's PEN and nothing else: #80 is pen 1,
        #08 is pen 2, #88 is pen 3. That makes this SHARPER than the byte
        compare it replaces rather than looser -- during the vanish the bar's
        own byte still carries three pixels of the ship it has not reached
        yet, which a whole-byte compare could never have matched.
        """
        want = PEN_AT_PIXEL_0[pen]
        found = []
        for x in range(WIDTH):
            run = 0
            for y in range(CTX_BAR_H, HUD_TOP):
                run = run + 1 if ram[h.screen_offset(y, x)] & 0x88 == want else 0
                if run >= BAR_MIN_RUN:
                    found.append(x)
                    break
        return found

    @staticmethod
    def full_height_columns(ram):
        """Columns barred from the context bar to the HUD -- the OLD effect."""
        want = PEN_AT_PIXEL_0[1]
        return [x for x in range(WIDTH)
                if all(ram[h.screen_offset(y, x)] & 0x88 == want
                       for y in range(CTX_BAR_H, HUD_TOP))]

    @staticmethod
    def lit_columns(ram):
        return {x for x in range(WIDTH)
                if any(ram[h.screen_offset(y, x)]
                       for y in range(CTX_BAR_H, HUD_TOP))}

    @staticmethod
    def lit_count(ram):
        return sum(1 for y in range(CTX_BAR_H, HUD_TOP) for x in range(WIDTH)
                   if ram[h.screen_offset(y, x)])

    @staticmethod
    def strip_lit(ram):
        """Lit bytes in the two strips the effect must never reach."""
        bar = sum(1 for y in range(0, CTX_BAR_H) for x in range(WIDTH)
                  if ram[h.screen_offset(y, x)])
        hud = sum(1 for y in range(HUD_TOP, 200) for x in range(WIDTH)
                  if ram[h.screen_offset(y, x)])
        return bar, hud

    @staticmethod
    def bar_bytes(ram):
        """Every byte of the context bar's strip, to compare against itself."""
        return bytes(ram[h.screen_offset(y, x)]
                     for y in range(0, CTX_BAR_H) for x in range(WIDTH))

    # -- driving -------------------------------------------------------------
    def offsets_that_explain(self, cols, runs, reveal=False):
        """How far along their runs every bar on screen would have to be.

        All the bars share one counter, so at any instant they stand at the
        SAME offset into their own ship's run -- which is the whole difference
        between this effect and the one it replaced, and is exactly what a set
        of columns can be asked about without having to decide which column
        belongs to which ship.

        THE TWO HALVES RUN DIFFERENT DISTANCES FROM DIFFERENT PLACES, and that
        is the point of `reveal` rather than a convenience. The vanish's bar
        starts JFX_MARGIN before the ship and crosses the whole band; the
        reveal's starts on the sprite's own left edge and stops on its right
        one, because a reveal may not blacken a byte outside its own sprite --
        see JFX_REVEAL_TRAVEL in game/jumpfx.asm.
        """
        if reveal:
            base, travel = self.sym["JFX_MARGIN"], self.sym["JFX_REVEAL_TRAVEL"]
            far = lambda r: r["w"]
        else:
            base, travel = 0, self.sym["JFX_TRAVEL"]
            far = lambda r: r["reach"]
        return {k for k in range(travel + 1)
                if all(any(r["x0"] + base + k == x and k < far(r) for r in runs)
                       for x in cols)}

    #  How often a running sweep is looked at, in emulator frames.
    #
    #  ONE WAS RIGHT AND IS NOT ANY MORE. The vanish was 35 emulator frames and
    #  is 359; the reveal was 88 and is 857. Sampling every frame is therefore
    #  ten times the work for no more information at all -- the bars only move
    #  once every JFX_VANISH_DWELL blanks and once every JFX_REVEAL_DWELL game
    #  frames, so the frames in between are copies of their neighbours by
    #  construction, and each sample decodes two 16 KB buffers in Python.
    #
    #  Five rather than a whole dwell, so a sweep is still seen at four or five
    #  moments per position and every test below still has more samples than it
    #  had before the slowdown.
    SAMPLE_EVERY = 5

    def sample_sweep(self, want, limit=1600, every=None):
        """Follow a sweep, every SAMPLE_EVERY emulator frames.

        Returns [(col, front base, bar columns, lit columns, lit bytes)], the
        RUNS as they stood while it happened, and {buffer base: how often it
        was seen carrying bars}. Reading the buffer on SHOW is what makes "a
        bar is one unbroken column" safe -- the back buffer is mid-fill about
        half the time, by construction.

        THE RUNS ARE READ INSIDE THE SWEEP AND NOT BEFORE IT. Both halves stop
        the world, so phase4_vis holds still for exactly as long as the sweep
        lasts and not one frame longer -- read it before pressing `J` and the
        fleet flies several pixels between the reading and the sweep, which is
        enough to put a bar outside the run the test computed for it.

        `limit` is in EMULATOR FRAMES and has to cover the whole of the longer
        half plus the wait for it to start: the reveal is seventeen and a half
        seconds now.
        """
        every = every or self.SAMPLE_EVERY
        seen, runs = [], None
        per_buffer = {h.SCREEN_A: 0, h.SCREEN_B: 0}
        for _ in range(limit // every):
            if self.mode() != want:
                if seen:
                    break
            else:
                if runs is None:
                    runs = self.runs()
                base = h.front_buffer(self.c)
                ram = self.buffer(base)
                bars = self.bar_columns(ram)
                seen.append((self.col(), base, bars,
                             self.lit_columns(ram), self.lit_count(ram)))
                if bars:
                    per_buffer[base] += 1
            self.c.run_frames(every)
        return seen, runs or [], per_buffer


class TestTheVanish(WipeFixture):
    """`J`: a bar crosses each ship and the ship is not there after it."""

    def setUp(self):
        super().setUp()
        #  Let the fleet fly out of the clump it spawns in. Every ship starts
        #  on squadron 1's station, so at boot fifteen of them share three byte
        #  columns and "one bar per ship" is not a thing the screen can show.
        self.c.run_frames(400)

    def press_jump(self, skip=True):
        #  Mission 1's objective is ARRIVE, so it is complete from the first
        #  frame -- but the objective is only the first of the three things
        #  mis_gate asks, and a mission may not be left before its third wave.
        #  This file is about the WIPE, so the way out is arranged rather than
        #  fought for; the gate is tests/test_campaign.TestTheWayOut.
        self.assertEqual(self.c.read_ram(self.sym["MIS_COMPLETE"], 1)[0], 1)
        h.clear_the_way_out(self.c)
        self.c.key_down("j")
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if skip:
            h.skip_the_countdown(self.c)

    def test_one_bar_per_ship_and_none_of_them_crosses_the_screen(self):
        """The change itself: not one line for the fleet, but one each.

        The old effect drew a single column lit from the context bar to the
        HUD. Nothing here may ever do that -- a bar is its own ship's height
        and a few lines -- and there have to be several of them at once.

        Several rather than one per ship: at the default zoom a formation is
        tight enough that two ships three byte columns apart put their bars in
        adjoining columns, and the screen cannot tell those from one wide one.
        """
        self.press_jump()
        seen, runs, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        self.assertGreater(len(runs), 4, "no fleet on the screen to sweep")
        self.assertGreater(len(seen), 5, "the sweep was over before it was seen")
        most = max(len(bars) for _, _, bars, _, _ in seen)
        self.assertGreater(most, 2,
                           f"never more than {most} bar(s) on screen at once")
        for _, base, _, _, _ in seen:
            full = self.full_height_columns(self.buffer(base))
            self.assertFalse(full, f"column(s) {full} run the whole playfield: "
                                   "that is one bar for the whole fleet")

    def test_every_bar_is_inside_its_own_ships_run(self):
        """...and they all stand at the same point of it, and only advance.

        The runs are stable throughout: mis_jump stops the world before it
        sweeps, so phase4_vis is the frame that was last drawn and does not
        move under the test.
        """
        self.press_jump()
        seen, runs, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        offsets = []
        for col, _, bars, _, _ in seen:
            if not bars:
                continue
            ks = self.offsets_that_explain(bars, runs)
            self.assertTrue(ks, f"at col {col} the bars are at {bars}, and no "
                                f"one offset into a ship's run explains them: "
                                f"runs start at {sorted(r['x0'] for r in runs)}")
            offsets.append(max(ks))
        self.assertGreater(len(offsets), 4)
        self.assertEqual(offsets, sorted(offsets),
                         f"the bars do not travel one way: {offsets}")

    def test_a_bar_starts_before_its_ship_and_ends_after_it(self):
        """The owner's words. Read off the run the machine's own numbers give.

        It is a statement about JFX_MARGIN rather than about the screen, so it
        is checked against the geometry: a run begins MARGIN columns before the
        sprite's left edge and ends MARGIN past its right one. The screen half
        of it is the test above -- the bars are seen at offset 0, which is
        before the ship, and at offsets past the sprite's width.
        """
        margin = self.sym["JFX_MARGIN"]
        for r in self.runs():
            self.assertEqual(r["x0"], r["left"] - margin)
            self.assertEqual(r["x0"] + r["reach"], r["left"] + r["w"] + margin)
            self.assertGreater(margin, 0, "there is no run-up at all")

    def test_it_erases_what_it_passes(self):
        """The content of the effect: a ship goes as its own bar crosses it.

        Behind the bar -- the columns of a ship the bar has already been
        through -- nothing of that ship may be left.
        """
        self.press_jump()
        seen, runs, _ = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")

        checked = 0
        for col, base, bars, _, _ in seen:
            if not bars:
                continue
            ks = self.offsets_that_explain(bars, runs)
            if not ks:
                continue
            k = max(ks)
            ram = self.buffer(base)
            for r in runs:
                for x in range(max(0, r["x0"]), min(WIDTH, r["x0"] + k)):
                    lit = [y for y in range(max(CTX_BAR_H, r["band_top"]),
                                            min(HUD_TOP, r["band_top"] + r["band_h"]))
                           if ram[h.screen_offset(y, x)]]
                    self.assertFalse(
                        lit, f"the bar of the ship at {r['left']} is {k} columns "
                             f"along its run and column {x} behind it is still lit")
                    checked += 1
        self.assertGreater(checked, 20)

    def test_the_bars_are_ink_1(self):
        """Section 2's ink for the fleet itself. Not 3, which is the alarm ink.

        Read WHILE the sweep is running and off the screen: every other test
        here finds a bar by asking bar_columns, which is told which pen to look
        for, so this is the one that says the answer is 1. The three pens are
        the same pixel in different bit planes -- #80, #08 and #88 at the
        leftmost pixel of a byte -- so a bar in the wrong ink would be found
        here and nowhere else.
        """
        self.press_jump()
        found = {1: 0, 2: 0, 3: 0}
        for _ in range(1600 // self.SAMPLE_EVERY):
            if self.mode() != JFX_OUT:
                if sum(found.values()):
                    break
            else:
                ram = self.front()
                for pen in (1, 2, 3):
                    found[pen] += len(self.bar_columns(ram, pen))
            self.c.run_frames(self.SAMPLE_EVERY)
        self.c.key_up("j")
        self.assertGreater(found[1], 0, "no ink 1 bars were ever on the screen")
        self.assertEqual((found[2], found[3]), (0, 0),
                         f"bars were drawn in another ink: {found}")

    def test_both_buffers_carry_the_sweep(self):
        """The page-flip guard, and the reason this file exists.

        The vanish runs inside ONE game frame, so the frame loop's own flip
        never happens during it: if it painted only the buffer on show, the
        flip at the end of that frame would put the fleet the player just
        watched being erased straight back on the screen.
        """
        self.press_jump()
        _, _, per_buffer = self.sample_sweep(JFX_OUT)
        self.c.key_up("j")
        for base, n in per_buffer.items():
            self.assertGreater(n, 1, f"buffer #{base:04X} never carried a bar: "
                                     f"{per_buffer}")

    def test_it_leaves_both_buffers_black(self):
        """The bars own the ships; the two dark passes own everything else.

        The reference plane, the resource fields and the Mothership indicator
        get no bar -- they are the place and not the fleet -- so the vanish
        ends with one pass of black over the playfield per buffer. This is the
        only thing that says those passes happen at all.
        """
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

        They are also repainted only when what they say changes, so a bar one
        line too tall would scrub a row out of the bar and nothing would ever
        put it back. scr_fill_rect honours no clip of its own -- jfx_band is
        the only thing standing between the bars and the strips.
        """
        #  Arrange the way out BEFORE the baseline, not inside press_jump.
        #  mis_leave_ok is what the HUD reads to put JUMP up in ink 3, so
        #  opening the way out repaints the strip -- and a baseline taken
        #  before that would see the repaint and call it "the sweep changed
        #  the strips".
        h.clear_the_way_out(self.c)

        #  Settle first: the bar and the HUD are painted into a buffer only
        #  when what they say changes, so a baseline taken at boot can be a
        #  buffer that has not had them yet.
        self.c.run_frames(60)

        #  THE BASELINE COMES AFTER `J`, not before it. The bar repaints to
        #  JUMPING while the drive spools, which is a legitimate change and
        #  not the sweep's -- taken before the keypress it read as "the sweep
        #  changed the context bar".
        self.press_jump(skip=False)
        self.c.run_frames(40)
        h.skip_the_countdown(self.c)
        before = None

        #  ...AND THE STRIPS ARE READ WHILE THE SWEEP IS STILL RUNNING. They
        #  used to be read after it, which worked only while the jump ENDED
        #  with the sweep. It does not: mis_jump_now runs on from there into
        #  mis_setup and the briefing, and a briefing's static_wipe clears
        #  from line 0 -- so a reading taken afterwards catches the BRIEFING
        #  having removed the bar and blames the sweep for it.
        seen = []
        for _ in range(400):
            if h.read_bank4(self.c, self.sym["JFX_MODE"], 1)[0] != JFX_OUT:
                if seen:
                    break                   # the sweep is over
                self.c.run_frames(2)
                continue
            seen.append(self.c.read_ram(self.sym["JFX_COL"], 1)[0])

            #  THE BASELINE IS THE SWEEP'S OWN FIRST FRAME. It cannot be taken
            #  before `J`: the bar repaints to JUMPING while the drive spools
            #  and then AGAIN every second as the number counts down, so any
            #  earlier reading is of a different, legitimate picture. What this
            #  test claims is that the SWEEP changes nothing, and that claim is
            #  exactly "every frame of it looks like its first".
            if before is None:
                before = {b2: (self.bar_bytes(self.buffer(b2)),
                               self.strip_lit(self.buffer(b2)))
                          for b2 in (h.SCREEN_A, h.SCREEN_B)}
                for b2 in (h.SCREEN_A, h.SCREEN_B):
                    self.assertGreater(
                        before[b2][1][0], 100,
                        f"buffer #{b2:04X} has no context bar to protect")
            for base in (h.SCREEN_A, h.SCREEN_B):
                ram = self.buffer(base)
                self.assertEqual(self.bar_bytes(ram), before[base][0],
                                 f"the sweep changed the context bar in #{base:04X}")
                self.assertEqual(self.strip_lit(ram), before[base][1],
                                 f"the sweep changed the strips in buffer #{base:04X}")
            self.c.run_frames(2)
        self.c.key_up("j")
        self.assertGreater(len(seen), 5, "the sweep was never caught running")

    def test_nothing_of_the_next_mission_shows_before_the_briefing(self):
        """The one-frame flash the wipe would otherwise have exposed.

        mis_jump lays the next mission out and opens its briefing, and the rest
        of that same frame used to go on and DRAW it -- so the flip showed the
        new mission for a frame before the briefing covered it again.

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
    """Each ship comes out from behind its own bar, the same way round."""

    def setUp(self):
        #  Get past mission 1's own briefing -- which does NOT reveal, because
        #  no jump brought the player to it -- and then jump, so the briefing
        #  this fixture is holding is the one a sweep belongs to.
        self.c = h.boot_quick(frames=300)
        h.clear_the_way_out(self.c)     # ...mis_gate's other two conditions
        self.c.key_down("j")
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if True:
            h.skip_the_countdown(self.c)
        self.c.run_frames(25)
        self.c.key_up("j")
        #  The vanish alone is 359 emulator frames now and the disc write is
        #  behind it, so this is a long wait and it has to be a bounded one:
        #  "the jump was refused" and "the jump is still sweeping" look the
        #  same from here for the first seven seconds.
        if not h.wait_for_briefing(self.c, frames=800):
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

    def test_the_mission_comes_out_from_behind_the_bars(self):
        """Several bars at once, none of them crossing the playfield, and more
        of the mission on the screen at the end than at the beginning."""
        self.dismiss()
        seen, _, _ = self.sample_sweep(JFX_IN)
        self.assertGreater(len(seen), 5, "the reveal was over before it was seen")

        most = max(len(bars) for _, _, bars, _, _ in seen)
        self.assertGreater(most, 2, f"never more than {most} bar(s) at once")
        for _, base, _, _, _ in seen:
            full = self.full_height_columns(self.buffer(base))
            self.assertFalse(full, f"column(s) {full} run the whole playfield")

        #  Only the frames that HAVE bars: the first sample of all is the
        #  briefing, still standing in the buffer the wipe has not reached.
        lit = [n for _, _, bars, _, n in seen if bars]
        self.assertGreater(len(lit), 2)
        self.assertGreater(lit[-1], lit[0],
                           f"nothing came out from behind the bars: {lit}")

    def test_no_ship_is_waiting_for_the_effect_to_be_over(self):
        """The last frame of the reveal is already the picture, near enough.

        THE BUG THIS IS FOR, reported as "δεν εμφανίζει σωστά αμέσως τα sprite --
        εμφανίζονται μετά με το που τελειώσει το effect". Every ship used to
        blacken three lines above and below its sprite ACROSS ITS WHOLE RUN, so
        in a formation seen from the side each ship's mask landed on the
        neighbour beside it and blacked out a ship the bars had already
        uncovered. The masks all come off together when JFX_IN ends, and only
        then was the fleet whole -- which is precisely what the player saw.

        Measured on mission 3 against the build that had it: 80 lit bytes on the
        last pass of the reveal against 112 one frame later, seven interceptors
        in a row and one of them drawn. The fix is that a ship may only blacken
        its own sprite rectangle; see JFX_REVEAL_TRAVEL.

        A few bytes of slack, not none: the world runs underneath the reveal --
        that is what makes it a reveal and not a freeze -- so the fleet has
        moved a pixel or two between the two readings.
        """
        self.dismiss()
        for _ in range(120):
            if self.mode() == JFX_IN:
                break
            self.c.run_frames(1)
        else:
            self.fail("the reveal never started")

        last = {}
        for _ in range(1400):
            if self.mode() != JFX_IN:
                break
            base = h.front_buffer(self.c)
            last[base] = self.lit_bytes(self.buffer(base))
            self.c.run_frames(1)
        else:
            self.fail("the reveal never ended")
        self.assertEqual(len(last), 2, "only one buffer was ever seen in front")

        #  ...and the same two buffers once the masks are gone for good.
        after, frames = {}, 0
        while len(after) < 2 and frames < 200:
            after[h.front_buffer(self.c)] = self.lit_bytes(
                self.buffer(h.front_buffer(self.c)))
            self.c.run_frames(1)
            frames += 1
        self.assertEqual(len(after), 2, "the reveal ended into one buffer only")

        for base in last:
            self.assertGreater(
                last[base] * 1.15 + 4, after[base],
                f"buffer {base:#06x} was carrying {last[base]} lit bytes on the "
                f"last frame of the reveal and {after[base]} once it was over: "
                "ships were being held back by their neighbours' masks")

    @staticmethod
    def lit_bytes(ram):
        return sum(1 for y in range(CTX_BAR_H, HUD_TOP) for x in range(WIDTH)
                   if ram[h.screen_offset(y, x)])

    def test_a_ship_is_hidden_until_its_own_bar_has_gone_by(self):
        """Ahead of a ship's bar, that ship is not on the screen.

        The frame loop draws the whole mission every frame; the masking is what
        hides it. Per ship this time, so "ahead of the line" is ahead of ITS
        line -- a ship whose bar has passed is showing while its neighbour four
        columns further right is not.
        """
        self.dismiss()
        seen, runs, _ = self.sample_sweep(JFX_IN)

        #  THE MARKERS ARE NOT SHIPS AND GET NO BAR. The reference plane, the
        #  resource fields and the Mothership indicator are the PLACE rather
        #  than the fleet, so they arrive with the first drawn frame and are
        #  never masked -- and the Y=0 lattice sits at PROJ_CENTRE_Y, which is
        #  the middle of the band of half the fleet. The frame where the bars
        #  are at offset 0 has every ship hidden by construction, so whatever
        #  is lit THERE is the place, and it is what this has to ignore.
        #  ONE SNAPSHOT PER BUFFER, and that is not caution. The display
        #  page-flips and the reveal masks the DIRTY RECTANGLES, so which
        #  ships a buffer is carrying at a given step depends on which buffer
        #  it is -- a snapshot taken from A and compared against a sample from
        #  B reports every ship the two disagree about as "showing ahead of its
        #  own bar". It read as a real defect and was the test comparing two
        #  different pictures.
        #
        #  It only started failing when the frame rate went up: the sweep is
        #  counted in GAME frames and the sampling in emulator frames, so
        #  which buffer happens to be in front at k == 0 moved.
        scenery, checked = {}, 0
        for col, base, bars, _, _ in seen:
            if not bars:
                continue
            ks = self.offsets_that_explain(bars, runs, reveal=True)
            if not ks:
                continue
            k = min(ks)
            ram = self.buffer(base)
            if k == 0 and base not in scenery:
                scenery[base] = {(x, y)
                                 for y in range(CTX_BAR_H, HUD_TOP)
                                 for x in range(WIDTH)
                                 if ram[h.screen_offset(y, x)]}
                continue
            if base not in scenery:
                continue
            #  The sprite's own rows and columns, because that is now the whole
            #  of what the reveal touches: left is x0 + MARGIN and the run ends
            #  on the sprite's right edge.
            for r in runs:
                start = max(0, r["left"] + k + 1)
                for x in range(start, min(WIDTH, r["left"] + r["w"])):
                    lit = [y for y in range(max(CTX_BAR_H, r["top"]),
                                            min(HUD_TOP, r["top"] + r["h"]))
                           if ram[h.screen_offset(y, x)]
                           and (x, y) not in scenery[base]]
                    self.assertFalse(
                        lit, f"at col {col} the bars are {k} along their runs and "
                             f"column {x} of the ship at {r['left']} is already "
                             "showing ahead of its own bar")
                    checked += 1
        self.assertIsNotNone(scenery, "the bars were never seen at the start of a run")
        self.assertGreater(checked, 10)

    def test_the_bars_leave_no_trail(self):
        """Nothing white survives the reveal that is not a ship.

        This is the bug the change had and no arithmetic would have found. A
        bar stands JFX_VMARGIN lines proud of its ship, and what rubs a bar out
        in the columns it has already passed is the SPRITE's dirty rectangle --
        which is the sprite and not the band. So every ship in the fleet was
        left with a little white block above it and one below, for the rest of
        the mission, and only a picture showed it.

        The world is stopped first, so both buffers are drawn from the same
        positions and "inside a sprite" is a fair question to ask of either.
        """
        self.dismiss()
        #  Wait for it to START before waiting for it to stop. ENTER is not
        #  consumed until the next GAME frame, so the mode is still NONE for
        #  several emulator frames after dismiss() returns -- read it once and
        #  the wait is over before the sweep has begun.
        for _ in range(120):
            if self.mode() == JFX_IN:
                break
            self.c.run_frames(1)
        else:
            self.fail("the reveal never started")
        #  Seventeen and a half seconds of it, so 1400 frames rather than 400.
        for _ in range(140):
            if self.mode() == JFX_NONE:
                break
            self.c.run_frames(10)
        else:
            self.fail("the reveal never finished")

        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(25)
        self.c.key_up(cpc.KEY_SPACE)
        self.c.run_frames(60)
        self.assertEqual(self.c.read_ram(self.sym["ORDER_PAUSED"], 1)[0], 1)

        runs = self.runs()
        self.assertTrue(runs, "no ships arrived to check")
        boxes = [(max(0, r["left"]), min(WIDTH, r["left"] + r["w"]),
                  max(CTX_BAR_H, r["top"]), min(HUD_TOP, r["top"] + r["h"]))
                 for r in runs]
        for base in (h.SCREEN_A, h.SCREEN_B):
            ram = self.buffer(base)
            stray = [(x, y)
                     for y in range(CTX_BAR_H, HUD_TOP) for x in range(WIDTH)
                     if ram[h.screen_offset(y, x)] & 0x88 == PEN_AT_PIXEL_0[1]
                     and not any(x0 <= x < x1 and y0 <= y < y1
                                 for x0, x1, y0, y1 in boxes)]
            self.assertFalse(
                stray, f"buffer #{base:04X} holds a bar pixel at {stray[:8]}, "
                       "outside every sprite: the bars left a trail")

    def test_both_buffers_carry_the_sweep(self):
        self.dismiss()
        _, _, per_buffer = self.sample_sweep(JFX_IN)
        for base, n in per_buffer.items():
            self.assertGreater(n, 0, f"buffer #{base:04X} never carried a bar: "
                                     f"{per_buffer}")

    def test_it_costs_no_game_time_at_all(self):
        """Seventeen seconds of it, and not one of them reaches the mission.

        This was worth a paragraph when the reveal was 1.76 s -- an overlay
        with the battle live behind it cost tools/balance.py two ships in
        mission 4 -- and it is worth a test now that it is several. Seven jumps
        times five seconds of unattended battle would not be a cosmetic change,
        it would be a slice of a campaign.

        mis_timer is the clock the attack waves are on and mis_setup zeroes it,
        so "the mission has not started yet" is the literal reading of a zero
        here. The second half of the test is what stops it being vacuous: the
        same counter has to move once the reveal is over.
        """
        self.dismiss()
        for _ in range(120):
            if self.mode() == JFX_IN:
                break
            self.c.run_frames(1)
        else:
            self.fail("the reveal never started")

        def timer():
            return int.from_bytes(self.c.read_ram(self.sym["MIS_TIMER"], 2),
                                  "little")

        samples, frames = [], 0
        while self.mode() == JFX_IN and frames < 1400:
            samples.append(timer())
            self.c.run_frames(10)
            frames += 10
        self.assertGreater(len(samples), 15,
                           "the reveal was over before it was watched")
        self.assertEqual(set(samples), {0},
                         f"the mission clock ran during the reveal: {samples}")

        #  ...and it is not simply broken: it moves the moment the wipe lets go.
        self.c.run_frames(120)
        self.assertGreater(timer(), 0,
                           "the mission clock never starts, so the assertion "
                           "above says nothing")

    def test_it_stays_out_of_the_two_strips(self):
        """The bar by its BYTES; the HUD only by still being there.

        The simulation is frozen under this sweep -- a transition must not cost
        game time -- so nothing should move either strip at all. The HUD is
        held to the weaker check anyway because it is repainted lazily and a
        buffer can receive it in the middle of the window this watches; the
        context bar cannot move, because the context is "playing" throughout.
        """
        self.dismiss()

        #  Wait for the bar rather than counting frames, and wait for the two
        #  buffers to AGREE: it is drawn a word at a time, so "has more than a
        #  hundred lit bytes" catches it halfway.
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

        seen, _, _ = self.sample_sweep(JFX_IN)
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
    disc, and neither has had anything take a fleet away for this one to give
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
    have meant a jump that is half done for a second, and a "pending" state for
    every one of them to learn about.
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
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if True:
            h.skip_the_countdown(self.c)
        for _ in range(30):
            self.assertNotEqual(self.mode(), JFX_OUT,
                                "a refused jump swept the screen anyway")
            self.c.run_frames(1)
        self.c.key_up("j")
        self.assertEqual(self.c.read_ram(self.sym["MIS_INDEX"], 1)[0], 2)
        self.assertTrue(lit_before, "there was nothing on the screen to keep")


#  --------------------------------------------------------------------------
#  The sound of it
#  --------------------------------------------------------------------------
#  tests/test_sound.py drives snd_jump_out and snd_jump_in from a stub and
#  states everything about their shape -- the channel, the two sweeps, the
#  levels, the lengths -- exactly, one tick at a time. What it cannot say is
#  that either one is ever REACHED by pressing `J`, which is what this is for.
#
#  READING THE PSG COSTS A WHOLE MACHINE. The stub takes the CPU away from the
#  game and the game does not come back: putting the PC where it was is not
#  enough, and test_music.py records the same finding at more length. So each
#  test here is one reading at one moment, and the fixture's per-test boot is
#  what pays for it.

R_PERIOD_C, R_PERIOD_C_HI, R_MIXER, R_AMP_C = 4, 5, 7, 10
MIX_TONE_C, MIX_NOISE_C = 1 << 2, 1 << 5


def _w(a):
    return [a & 0xFF, a >> 8]


def read_psg(c, sym):
    """Registers 0..13 back out of the AY, the way test_sound.py does it.

    Scratch comes from CODE_END rather than a fixed address, for the reason
    test_sound.py gives: src/gen is `align 256`, so an address that is free
    today is inside a lookup table after the next thing anyone adds.
    """
    buf = sym["CODE_END"] + 0x10
    stub = sym["CODE_END"] + 0xA0
    code = [0xF3] + [0x21] + _w(buf) + [0x16, 0x00] + [0x0E, 0x00]
    body = []
    body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]    # PPI: port A = output
    body += [0x06, 0xF4, 0x7A, 0xED, 0x79]          # register number out
    body += [0x06, 0xF6, 0x3E, 0xC0, 0xED, 0x79]    # PSG_SELECT: latch it
    body += [0xAF, 0xED, 0x79]                      # PSG_INACTIVE
    body += [0x06, 0xF7, 0x3E, 0x92, 0xED, 0x79]    # PPI: port A = INPUT
    body += [0x06, 0xF6, 0x3E, 0x40, 0xED, 0x79]    # PSG_READ
    body += [0x06, 0xF4, 0xED, 0x78]                # in a,(#F4xx)
    body += [0x77, 0x23]                            # ld (hl),a : inc hl
    body += [0x06, 0xF6, 0xAF, 0xED, 0x79]          # PSG_INACTIVE
    body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]    # PPI: port A = output
    body += [0x14, 0x7A, 0xFE, 0x0E]                # inc d : ld a,d : cp 14
    body += [0x38, (-(len(body) + 2)) & 0xFF]       # jr c,-> next register
    c.write_ram(stub, bytes(code + body + [0x18, 0xFE]))
    c.set_pc(stub)
    c.run_frames(4)
    return list(c.read_ram(buf, 14))


class TestTheJumpIsHeard(WipeFixture):
    """`J` makes a sound, the arrival makes its mirror, and nothing else does.

    Every assertion is on the AY's own registers and every expectation is
    derived from the descriptor bytes in the build -- not from numbers copied
    into this file, which would only say that Python can read a constant twice.

    THE MUSIC IS MUTED FIRST, and that is not sweeping anything under a rug.
    The game's tune plays on channel C, which is exactly the voice the jump
    uses -- section 12 keeps C for alerts and the jump is the only thing that
    had ever used it. These four tests are about the JUMP's own sound, and with
    a drone underneath it "channel C is sounding" stops distinguishing
    anything. The interaction between the two has its own test below, and it
    fails on the build where mus_write_block walked over a live effect.
    """

    def setUp(self):
        super().setUp()
        self.c.key_down("m")
        self.c.run_frames(30)
        self.c.key_up("m")
        self.c.run_frames(30)
        self.assertEqual(self.c.read_ram(self.sym["SND_MUSIC_ON"], 1)[0], 0,
                         "M did not silence the music for these tests")

    def descriptor(self, name):
        """(timer, pri, vol, dvol, period, dstep, slow) out of the low 16K.

        dstep is SIGNED -- it is what makes the two halves opposite -- so it is
        widened here rather than left as the sixteen bits it is stored in.

        THE TIMER IS IN STEPS AND `slow` IS HOW MANY TICKS ONE IS. A jump is
        300 and 880 ticks now and neither fits a byte, so the length of a sound
        is the product; anything here that wants to run the machine for part of
        a sound has to multiply, and the two that do say so.
        """
        b = self.c.read_ram(self.sym[name], self.sym["SND_VOICE_SIZE"])
        dstep = b[6] | (b[7] << 8)
        if dstep >= 0x8000:
            dstep -= 0x10000
        return (b[0], b[1], b[2], b[3], b[4] | (b[5] << 8), dstep,
                b[self.sym["SND_V_SLOW"]])

    def ticks(self, name):
        """How long a descriptor sounds for, in 50 Hz ticks."""
        d = self.descriptor(name)
        return d[0] * d[6]

    def sweep_bounds(self, name):
        """(period at step 0, period the descriptor's own arithmetic ends at).

        Bounding a reading BETWEEN these two is what makes it an observation of
        the sweep rather than of any old number: a period outside them cannot
        have come from this descriptor, and in particular a sweep run backwards
        far enough to WRAP through zero lands nowhere near them. That case is
        not hypothetical -- it is what a reversed dstep does, and a test that
        only asked "is the period bigger than it started" was happy with it.
        """
        timer, _, _, _, start, dstep, _ = self.descriptor(name)
        return start, start + timer * dstep

    def tone_c(self, why):
        """(period, amplitude) on channel C, having checked it is a live tone."""
        r = read_psg(self.c, self.sym)
        self.assertGreater(r[R_AMP_C], 0, f"{why}: channel C is silent")
        self.assertEqual(r[R_MIXER] & MIX_TONE_C, 0,
                         f"{why}: tone C is muted, mixer #{r[R_MIXER]:02X}")
        self.assertEqual(
            r[R_MIXER] & MIX_NOISE_C, MIX_NOISE_C,
            f"{why}: the noise generator is open on C, so this is an "
            f"explosion and not a drive -- mixer #{r[R_MIXER]:02X}")
        return r[R_PERIOD_C] | (r[R_PERIOD_C_HI] << 8), r[R_AMP_C]

    def press_jump(self, skip=True):
        self.assertEqual(self.c.read_ram(self.sym["MIS_COMPLETE"], 1)[0], 1,
                         "mission 1's ARRIVE objective is not met")
        h.clear_the_way_out(self.c)     # ...and the other two of mis_gate's
        self.c.key_down("j")
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if skip:
            h.skip_the_countdown(self.c)
        for _ in range(60):
            if self.mode() == JFX_OUT:
                return
            self.c.run_frames(1)
        self.fail("`J` never started the vanish")

    #  --- the control, and it comes first ------------------------------------

    def test_an_ordinary_frame_makes_no_sound_on_channel_c(self):
        """Without this the three tests below prove nothing.

        Channel C is idle for the whole of a mission -- the guns are on A and
        B -- so anything found on it during a jump is the jump. If something
        else ever starts using C, this is the test that says so, and the three
        below become readings of whatever that is.
        """
        self.c.run_frames(200)
        r = read_psg(self.c, self.sym)
        self.assertEqual(r[R_AMP_C], 0,
                         f"channel C is already sounding at amplitude "
                         f"{r[R_AMP_C]} with no jump anywhere near")
        self.assertEqual(r[R_MIXER] & MIX_TONE_C, MIX_TONE_C,
                         f"tone C is open in an ordinary frame: "
                         f"mixer #{r[R_MIXER]:02X}")

    #  --- the departure ------------------------------------------------------

    def test_pressing_j_is_heard_at_the_bottom_of_its_sweep(self):
        """One reading, early in the vanish, and it has to be the low end.

        The out starts at the descriptor's own period and climbs from there, so
        a reading three ticks in must still be within a few steps of where it
        began. That is a much sharper statement than "something is playing":
        it fails if the sweep runs the wrong way, if the wrong descriptor was
        copied, or if the arrival's sound was started by mistake.
        """
        start, end = self.sweep_bounds("SND_FX_JUMP_OUT")
        self.assertLess(end, start, "the out descriptor does not sweep upward")
        self.press_jump()
        self.c.run_frames(3)
        period, amp = self.tone_c("three ticks into the vanish")
        self.assertTrue(
            end <= period < start,
            f"the period is {period}, outside the {end}..{start} the out's own "
            f"descriptor can reach -- this is not that sweep")
        self.assertGreater(
            period, start * 2 // 3,
            f"the period is already {period} against a start of {start} -- "
            f"this reading is not the beginning of the out sweep")
        self.assertGreater(amp, 8, f"the out starts quiet, at {amp}/15")

    def test_the_departure_has_climbed_by_the_end_of_the_vanish(self):
        """The same sound, read near the end, and the pitch has to be up.

        Period DOWN is pitch UP. Read against the descriptor's start, so this
        is the sweep's DIRECTION on the real path and not a number copied here.
        """
        start, end = self.sweep_bounds("SND_FX_JUMP_OUT")
        #  TICKS, not the descriptor's timer -- the timer counts prescaled
        #  steps now, and reading the machine 94 frames into a 300-frame sound
        #  would find it a third of the way up its sweep and call that "the
        #  end of the vanish".
        ticks = self.ticks("SND_FX_JUMP_OUT")
        self.press_jump()
        #  Fifty ticks off the end rather than six. The out is DESIGNED to be
        #  silent for its last twenty-odd ticks -- the level reaches zero
        #  before the timer does, so that a tail caught by the disc write's DI
        #  is frozen at silence -- and tone_c insists on hearing something.
        self.c.run_frames(ticks - 50)
        period, _ = self.tone_c(f"{ticks - 50} ticks into the vanish")
        self.assertTrue(
            end <= period < start,
            f"the period is {period}, outside the {end}..{start} this "
            f"descriptor can reach")
        self.assertLess(
            period, start // 3,
            f"the out is at period {period} near the end of a sweep that "
            f"began at {start} -- it has not climbed anything like an octave")

    #  --- the arrival --------------------------------------------------------

    def test_the_arrival_is_heard_falling_back_down(self):
        """The mirror, on the real path: jump, dismiss the briefing, listen.

        The in starts high and falls, so a reading well into the reveal must be
        at a period ABOVE where the descriptor put it -- the opposite direction
        to the test above, which is the whole of the pair.
        """
        start, end = self.sweep_bounds("SND_FX_JUMP_IN")
        self.assertGreater(end, start,
                           "the in descriptor does not sweep downward")

        #  A jump, and out through the briefing by hand: harness.jump_mission
        #  waits the whole reveal out, which is exactly the thing to be inside.
        h.clear_the_way_out(self.c)     # ...mis_gate's other two conditions
        self.c.key_down("j")
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if True:
            h.skip_the_countdown(self.c)
        self.c.run_frames(25)
        self.c.key_up("j")
        self.assertTrue(h.wait_for_briefing(self.c), "no briefing after `J`")
        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(25)
        self.c.key_up(cpc.KEY_ENTER)
        self.assertEqual(self.mode(), JFX_IN,
                         "dismissing the jump's briefing started no reveal")

        #  A THIRD OF THE WAY IN, and that is what "well into" has to mean now.
        #  The in is 880 ticks and its pitch falls by one part in 220 a step,
        #  so a reading taken the instant the reveal opens is at the top of the
        #  sweep and indistinguishable from the departure's own last note. It
        #  was read immediately when the sound was 88 ticks long, and that was
        #  a quarter of the way down it.
        #  A THIRD OF THE SOUND, computed from the descriptor rather than
        #  written down. 300 was a third when the arrival was 880 ticks; the
        #  reveal was then made twice as fast and the sound with it, and 300
        #  became two thirds of the way down a decay that reaches zero at the
        #  end -- the amplitude read 3/15 and the test called it inaudible.
        #  A sample point is a fraction of a length, not a number of frames.
        desc = self.c.read_ram(self.sym["SND_FX_JUMP_IN"], 10)
        third = desc[0] * desc[8] // 3          # timer x prescaler
        self.c.run_frames(third)
        self.assertEqual(self.mode(), JFX_IN,
                         f"the reveal was over {third} ticks in, so the sound "
                         "and the picture are no longer the same length")
        period, amp = self.tone_c("a third of the way into the reveal")
        self.assertTrue(
            start < period <= end,
            f"the period is {period}, outside the {start}..{end} the in's own "
            f"descriptor can reach -- it is the out's sound, or a sweep that "
            f"ran the wrong way and wrapped through zero")
        self.assertGreater(
            period, start * 3,
            f"the in is at period {period} against a start of {start}, so it "
            f"has barely fallen in pitch at all")
        self.assertGreater(amp, 4,
                           f"the arrival is nearly inaudible at {amp}/15 while "
                           f"the reveal is still running")


class TestTheMusicGetsOutOfTheJumpsWay(WipeFixture):
    """The tune and the jump share channel C, and the jump wins.

    Section 12 keeps C for alerts, the jump was the only thing that ever used
    it, and the game's music is on it now because A and B belong to the shots
    and the explosions. So the two meet, and the first build that put music in
    the game had the tune walk straight over the arrival: mus_write_block wrote
    its block unconditionally, and the jump-in is 4.6 seconds -- longer than a
    note.

    It fails on that build with the BASS's period where the sweep should be.
    """

    def test_the_arrival_is_the_jumps_sound_and_not_a_note(self):
        from tests.test_music import read_psg

        self.assertEqual(self.c.read_ram(self.sym["SND_MUSIC_ON"], 1)[0], 1,
                         "this test needs the music playing")
        h.clear_the_way_out(self.c)
        self.c.key_down("j")
        #  `J` announces; the drive spools for ten seconds first. This file
        #  is about the WIPE, so the spool is arranged away rather than sat
        #  through -- and SKIPPED rather than waited out, because the vanish
        #  starts the instant the count reaches zero and polling for that
        #  lands mid-sweep.
        #
        #  The twenty frames are not padding: the context bar repaints to
        #  JUMPING while the drive spools, and a test that took its baseline
        #  before that would blame the SWEEP for the change.
        self.c.run_frames(20)
        if True:
            h.skip_the_countdown(self.c)
        self.c.run_frames(25)
        self.c.key_up("j")
        self.assertTrue(h.wait_for_briefing(self.c, frames=800),
                        "the jump never put a briefing up")
        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)

        #  Well inside the arrival: JFX_IN is a few hundred frames and the
        #  sound is longer than a note, which is the whole hazard.
        for _ in range(120):
            if self.mode() == JFX_IN:
                break
            self.c.run_frames(1)
        else:
            self.fail("the reveal never started")
        self.c.run_frames(80)

        #  read_psg last: it leaves interrupts off.
        r = read_psg(self.c)
        period = r[4] | (r[5] << 8)
        lo, hi = 55, 715                # what snd_fx_jump_in's own sweep spans
        self.assertTrue(
            lo <= period <= hi,
            f"channel C reads period {period}, outside the {lo}..{hi} the "
            "arrival's descriptor can reach -- the music wrote over it")


if __name__ == "__main__":
    unittest.main()
