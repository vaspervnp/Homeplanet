"""The Phase 4 fleet demo: views, tiers, sorting, residue and frame rate.

Split out of test_phase3.py when the demo moved from a fixed ship table to
real entity records. The blitter tests stayed there; these are about what the
running game does with it.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

TIER_C_W_BYTES = 7
TIER_C_H = 16


class TestFleet(unittest.TestCase):
    """The running demo: views, tiers, sorting, and no residue."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=250)
        cls.sym = h.symbols()

    def _visible(self):
        #  Sync first: mid-frame, phase3_visible and phase3_vis disagree.
        h.run_to_stable_point(self.c, self.sym)
        n = self.c.read_ram(self.sym["PHASE4_VISIBLE"], 1)[0]
        raw = self.c.read_ram(self.sym["PHASE4_VIS"], n * 6)
        return [
            {
                "sx": raw[i * 6] | (raw[i * 6 + 1] << 8),
                "sy": raw[i * 6 + 2],
                "z": raw[i * 6 + 3],
                "view": raw[i * 6 + 4],
                #  Byte 5 packs the class into the top bits and the tier into the
                #  bottom two -- the record is six bytes and both are needed.
                "tier": raw[i * 6 + 5] & 3,
                "ship_class": raw[i * 6 + 5] >> 2,
            }
            for i in range(n)
        ]

    def test_ships_are_on_screen(self):
        vis = self._visible()
        self.assertGreaterEqual(len(vis), 8, "hardly any of the squadron survived")
        for v in vis:
            self.assertTrue(0 <= v["sx"] < 320, v)
            self.assertTrue(0 <= v["sy"] < 200, v)

    def test_every_yaw_view_gets_used(self):
        """Phase 3: '8 όψεις' -- six of them, after section 14's mitigation.

        The count comes out of the BUILD rather than being written down here,
        so this tracks PHASE4_VIEWS instead of having to be remembered
        alongside it. src/main.asm separately asserts that PHASE4_VIEWS is what
        the art actually holds.
        """
        views = self.sym["PHASE4_VIEWS"]
        seen = set()
        for _ in range(40):
            self.c.run_frames(4)
            seen.update(v["view"] for v in self._visible())
            if len(seen) == views:
                break
        self.assertEqual(seen, set(range(views)),
                         f"only views {sorted(seen)} of {views} appeared")

    def test_all_three_size_tiers_get_used(self):
        """Phase 3: '3 βαθμίδες'.

        Two things have to be arranged before this means anything.

        First, split the fleet. It starts as ONE squadron sitting at one
        place, which is the specified starting state but gives every ship
        almost the same depth -- a single squadron legitimately only ever
        needs one tier, and that is what it reports.

        Second, drive the camera round rather than waiting for it. The demo
        orbits one step of 256 per game frame, so waiting for a full turn at
        ~8 fps would take half a minute of emulated time. Poking cam_yaw walks
        the same circle in a fraction of it, and it makes the test
        deterministic instead of dependent on how long it happened to run.
        """
        for key in "dd":
            self.c.key_down(key)
            self.c.run_frames(25)
            self.c.key_up(key)
            self.c.run_frames(25)
        self.c.run_frames(250)              # let them fly to their formations

        seen = set()
        for yaw in range(0, 256, 16):
            self.c.write_ram(self.sym["CAM_YAW"], bytes([yaw]))
            self.c.run_frames(30)
            seen.update(v["tier"] for v in self._visible())
            if len(seen) == 3:
                break
        self.assertEqual(seen, {0, 1, 2}, f"only tiers {sorted(seen)} appeared")

    def test_draw_order_is_back_to_front(self):
        """Homeplanet.md 5.3: near ships are drawn last, so they end up on top."""
        for _ in range(5):
            self.c.run_frames(4)
            vis = self._visible()          # leaves us parked at a stable point
            order = list(self.c.read_ram(self.sym["PHASE4_ORDER"], len(vis)))
            depths = [vis[i]["z"] for i in order]
            self.assertEqual(depths, sorted(depths, reverse=True),
                             f"draw order is not back to front: {depths}")

    def test_no_residue(self):
        """Phase 2: 'χωρίς σκιές/υπολείμματα'.

        Every lit byte must belong to a sprite the demo believes it drew. The
        bound is generous -- sprites overlap -- but a failed erase grows the
        count without limit, which is the failure this catches.
        """
        max_bytes = 16 * TIER_C_W_BYTES * TIER_C_H
        for _ in range(10):
            self.c.run_frames(4)
            front = h.front_buffer(self.c)
            ram = self.c.read_ram(front, 0x4000)
            lit = sum(1 for y in range(200) for x in range(80)
                      if ram[h.screen_offset(y, x)])
            self.assertLessEqual(lit, max_bytes,
                                 f"buffer #{front:04X} holds {lit} lit bytes, "
                                 f"more than the whole squadron could cover")

    def test_the_fleet_redraws_as_the_camera_moves(self):
        """Phase 5 handed the camera to the player, so drive it.

        This used to rely on the demo orbiting by itself. It does not any
        more, and that is the point of Phase 5 rather than a regression.
        """
        import cpc

        shots = []
        for _ in range(3):
            self.c.key_down(cpc.KEY_RIGHT)
            self.c.run_frames(40)
            self.c.key_up(cpc.KEY_RIGHT)
            self.c.run_frames(10)
            shots.append(bytes(self.c.read_ram(h.front_buffer(self.c), 0x4000)))
        self.assertNotEqual(shots[0], shots[1], "orbiting did not redraw anything")
        self.assertNotEqual(shots[1], shots[2])

    #  MEASURED at 5.8-6.5 fps for the 24 entities section 6 budgets a frame
    #  for, against its 12.5 fps target. Roughly: blitting 182k T-states,
    #  projection 118k, erasing 75k, z-sort 73k, formation flight 52k, combat
    #  28k. CLAUDE.md has the breakdown and where the headroom is.
    #
    #  A floor, not the goal. If it drops, something got slower.
    MEASURED_FPS_FLOOR = 5.0

    def test_frame_rate_does_not_regress(self):
        #  SETTLE FIRST, and measure a longer window than the boot transient.
        #
        #  demo_wait_frame holds the loop to a whole number of 50 Hz ticks, so
        #  a frame that overruns by one T-state costs a whole tick -- and the
        #  frames immediately after the briefing is dismissed are the heaviest
        #  the game ever runs: mis_wipe clears all 16,000 bytes of the back
        #  buffer twice, the HUD repaints into both buffers, and the context
        #  bar does the same for its own strip. Two of those frames cross a
        #  tick boundary, which costs two ticks out of the 200 this window used
        #  to be -- and demo_frames is an integer, so 19.8 game frames counted
        #  as 19 and the figure read 4.75 for a game running at exactly the
        #  same 5.0 fps as before.
        #
        #  Measured over 1000 frames the two builds are identical: 4.95, 5.0,
        #  5.0, 5.05 -- one frame lost at the start and one made up later. So
        #  this now skips the transient and averages over twice as long, which
        #  is a better measurement of the thing the floor is about rather than
        #  a weaker one.
        self.c.run_frames(100)
        before = self.c.read_ram(self.sym["DEMO_FRAMES"], 1)[0]
        pal_frames = 400
        self.c.run_frames(pal_frames)
        after = self.c.read_ram(self.sym["DEMO_FRAMES"], 1)[0]

        fps = ((after - before) % 256) / (pal_frames / 50)
        self.assertGreaterEqual(
            fps, self.MEASURED_FPS_FLOOR,
            f"{fps:.1f} fps for 24 entities, was {self.MEASURED_FPS_FLOOR}+",
        )


def view_table(c, sym):
    """Drive phase4_cache once per heading and collect the view byte it wrote.

    The 256 answers go into phase4_vis -- the game's own visible list, which is
    288 bytes, is rebuilt from scratch every frame, and is not going to be
    rebuilt again because the stub ends in `jr $`. The test scratch is 0x60
    bytes in total and this needs 256 of them.
    """
    ent = sym["ENTITIES"] + sym["ENT_YAW"]
    out = sym["PHASE4_VIS"]

    def w(addr):
        return bytes([addr & 0xFF, addr >> 8])

    head = (b"\xF3"                                  # di
            + b"\xAF" + b"\x32" + w(sym["CAM_YAW"])  # xor a : ld (cam_yaw),a
            + b"\x0E\x00")                           # ld c,0
    body = (b"\x79" + b"\x32" + w(ent)               # ld a,c : ld (ent_yaw),a
            + b"\x21" + w(sym["ENTITIES"])
            + b"\x22" + w(sym["PHASE4_ENT"])
            + b"\x21" + w(h.DATA)
            + b"\x22" + w(sym["PHASE4_VIS_PTR"])
            + b"\xC5"                                # push bc
            + b"\xCD" + w(sym["PHASE4_CACHE"])
            + b"\xC1"                                # pop bc
            + b"\x3A" + w(h.DATA + 4)                # the view byte it wrote
            + b"\x21" + w(out) + b"\x06\x00\x09"     # ld hl,out : ld b,0 : +bc
            + b"\x77" + b"\x0C")                     # ld (hl),a : inc c
    tail = (b"\x20" + bytes([-(len(body) + 2) & 0xFF])   # jr nz,body
            + b"\x3E\xFF" + b"\x32" + w(h.RESULT)        # ld a,#FF : ld (done),a
            + b"\x18\xFE")                               # jr $
    stub = head + body + tail
    if len(stub) > h.RESULT - h.STUB:
        raise RuntimeError(f"the view stub outgrew the scratch ({len(stub)} bytes)")

    c.write_ram(h.RESULT, b"\x00")
    c.write_ram(h.STUB, stub)
    c.set_pc(h.STUB)
    for _ in range(40):
        c.run_frames(1)
        if c.read_ram(h.RESULT, 1)[0] == 0xFF:
            break
    else:
        raise RuntimeError("the view stub never finished")
    return list(c.read_ram(out, 256))


class TestViewIndex(unittest.TestCase):
    """Which of the six yaw views a heading picks -- all 256 of them.

    Six views is section 14's mitigation and six is not a power of two, so
    phase4_cache cannot shift and mask any more; it multiplies by six and
    rounds. That is twelve instructions of arithmetic whose edges are exactly
    where a bug would hide, and there are only 256 inputs -- so check every
    one against the model, the way test_phase1 checks the projection.

    Rounding is the half of this worth pinning down. The eight-view code
    truncated, which drew every ship in the pose it had last passed rather
    than the nearest one; at six views that error grows to a whole step and
    the fleet reads as flying crabwise.
    """

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=250)
        cls.sym = h.symbols()
        cls.views = cls.sym["PHASE4_VIEWS"]
        cls.table = view_table(cls.c, cls.sym)

    @classmethod
    def tearDownClass(cls):
        h.close(cls.c)

    def expected(self, heading):
        """round(heading * views / 256), wrapping a whole turn back to view 0."""
        return ((heading * self.views + 128) >> 8) % self.views

    def test_every_heading_picks_the_nearest_view(self):
        wrong = [(a, self.table[a], self.expected(a))
                 for a in range(256) if self.table[a] != self.expected(a)]
        self.assertEqual(wrong, [], f"{len(wrong)} headings picked the wrong view")

    def test_the_view_is_never_off_the_end_of_the_library(self):
        """A view of 6 would index a seventh frame that is not there, and the
        blitter would draw whatever follows the tier."""
        self.assertEqual(max(self.table), self.views - 1)
        self.assertEqual(min(self.table), 0)

    def test_the_error_is_never_more_than_half_a_step(self):
        """What rounding buys, stated as the thing the player sees.

        Truncation would make this a whole step, and always in the same
        direction -- every ship in the fleet drawn up to 60 degrees behind its
        heading at once, which does not look like a coarse turn, it looks like
        the fleet is flying sideways.
        """
        step = 256 / self.views
        worst = max(min(abs(a - self.table[a] * step),
                        abs(a - (self.table[a] + self.views) * step))
                    for a in range(256))
        self.assertLessEqual(worst, step / 2,
                             f"worst heading error {worst:.1f} of 256ths")

    def test_each_view_owns_about_a_sixth_of_the_circle(self):
        """A multiply that dropped a bit would still produce 0..5 and still
        look plausible in a screenshot; the histogram is what catches it."""
        counts = [self.table.count(v) for v in range(self.views)]
        self.assertLessEqual(max(counts) - min(counts), 1, counts)


if __name__ == "__main__":
    unittest.main()
