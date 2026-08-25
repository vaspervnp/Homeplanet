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

    def test_all_eight_yaw_views_get_used(self):
        """Phase 3: '8 όψεις'. One orbit must exercise every view."""
        seen = set()
        for _ in range(40):
            self.c.run_frames(4)
            seen.update(v["view"] for v in self._visible())
            if len(seen) == 8:
                break
        self.assertEqual(seen, set(range(8)), f"only views {sorted(seen)} appeared")

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

    #  MEASURED at 7.3-8.3 fps for 20 ships, depending on how far the fleet is
    #  spread (spread ships sit closer to the camera and draw at a bigger tier), against the design's 12.5 fps target.
    #  The frame breaks down roughly as: blitting 168k T-states, projection
    #  113k, erasing 72k, z-sort 54k, formation flight 55k. See CLAUDE.md for
    #  what that means for section 6's budget.
    #
    #  A floor, not the goal. If it drops, something got slower.
    MEASURED_FPS_FLOOR = 7.0

    def test_frame_rate_does_not_regress(self):
        before = self.c.read_ram(self.sym["DEMO_FRAMES"], 1)[0]
        pal_frames = 200
        self.c.run_frames(pal_frames)
        after = self.c.read_ram(self.sym["DEMO_FRAMES"], 1)[0]

        fps = ((after - before) % 256) / (pal_frames / 50)
        self.assertGreaterEqual(
            fps, self.MEASURED_FPS_FLOOR,
            f"{fps:.1f} fps for 20 ships, was {self.MEASURED_FPS_FLOOR}+",
        )


if __name__ == "__main__":
    unittest.main()
