"""Phase 5: the control layer -- camera, zoom, pause and the move disc.

Everything here presses real keys in the emulator. The point of Phase 5 is
that a person can fly the camera and give an order, so testing the routines
directly would skip the half that matters.

Key assignment note: section 9 of the design puts the move order on `M` and
docking on `D`, but those keys belong to the squadron commands, so the move
disc opens and confirms with ENTER and cancels with ESC.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Mirrored from src/game/order.asm
CAM_YAW_STEP = 8
CAM_PITCH_STEP = 4
CAM_PITCH_MAX = 53
DISC_STEP = 1600
ZOOM_DISTANCES = [110, 150, 200, 250]


class ControlFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=250)

    # -- reading the machine ------------------------------------------------
    def byte(self, name, offset=0, signed=False):
        v = self.c.read_ram(self.sym[name] + offset, 1)[0]
        return v - 256 if signed and v >= 128 else v

    def word(self, name, offset=0, signed=False):
        lo, hi = self.c.read_ram(self.sym[name] + offset, 2)
        v = lo | (hi << 8)
        return v - 65536 if signed and v >= 32768 else v

    def disc(self):
        return tuple(self.word("DISC_POS", i * 2, signed=True) for i in range(3))

    def dest_of(self, squadron):
        base = (squadron - 1) * 6
        return tuple(self.word("SQUAD_DEST", base + i * 2, signed=True) for i in range(3))

    # -- pressing things ----------------------------------------------------
    def hold(self, key, frames=40):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(15)

    def hold_shifted(self, key, frames=60):
        """Hold SHIFT and a cursor key together.

        The emulator registers SHIFT as a modifier rather than a key, so it
        cannot be pressed on its own -- but holding an uppercase character
        asserts it, and 'Q' is not bound to anything.
        """
        self.c.key_down("Q")
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.key_up("Q")
        self.c.run_frames(15)

    def open_disc(self):
        self.hold(cpc.KEY_ENTER, frames=8)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1, "the move disc did not open")


class TestCamera(ControlFixture):

    def test_cursor_keys_orbit_the_camera(self):
        before = self.byte("CAM_YAW")
        self.hold(cpc.KEY_RIGHT)
        after = self.byte("CAM_YAW")
        self.assertNotEqual(after, before, "the camera did not yaw")
        self.assertEqual((after - before) % CAM_YAW_STEP, 0,
                         f"yaw moved by {(after - before) % 256}, not a multiple of {CAM_YAW_STEP}")

        #  Left must yaw the other way, i.e. the difference wraps downwards.
        self.hold(cpc.KEY_LEFT)
        self.assertGreaterEqual((self.byte("CAM_YAW") - after) % 256, 128,
                                "left and right yaw the same way")

    def test_pitch_is_clamped_to_the_design_limit(self):
        """Section 4.3: pitch is limited to +/-75 degrees."""
        self.hold(cpc.KEY_UP, frames=250)
        self.assertEqual(self.byte("CAM_PITCH", signed=True), CAM_PITCH_MAX,
                         "pitch did not clamp going up")

        self.hold(cpc.KEY_DOWN, frames=400)
        self.assertEqual(self.byte("CAM_PITCH", signed=True), -CAM_PITCH_MAX,
                         "pitch did not clamp going down")

    def test_the_view_actually_changes_when_the_camera_moves(self):
        before = bytes(self.c.read_ram(h.front_buffer(self.c), 0x4000))
        self.hold(cpc.KEY_RIGHT, frames=60)
        after = bytes(self.c.read_ram(h.front_buffer(self.c), 0x4000))
        self.assertNotEqual(before, after, "orbiting did not redraw anything")


class TestZoom(ControlFixture):

    def test_z_and_x_step_through_the_four_distances(self):
        self.assertEqual(self.byte("CAM_ZOOM"), 1)
        self.assertEqual(self.word("CAM_DIST"), ZOOM_DISTANCES[1])

        self.hold("x", frames=8)
        self.assertEqual(self.byte("CAM_ZOOM"), 2)
        self.assertEqual(self.word("CAM_DIST"), ZOOM_DISTANCES[2])

        self.hold("z", frames=8)
        self.hold("z", frames=8)
        self.assertEqual(self.byte("CAM_ZOOM"), 0)
        self.assertEqual(self.word("CAM_DIST"), ZOOM_DISTANCES[0])

    def test_zoom_clamps_at_both_ends(self):
        for _ in range(6):
            self.hold("z", frames=8)
        self.assertEqual(self.byte("CAM_ZOOM"), 0)
        self.assertEqual(self.word("CAM_DIST"), ZOOM_DISTANCES[0])

        for _ in range(8):
            self.hold("x", frames=8)
        self.assertEqual(self.byte("CAM_ZOOM"), len(ZOOM_DISTANCES) - 1)
        self.assertEqual(self.word("CAM_DIST"), ZOOM_DISTANCES[-1])

    def test_zoom_is_edge_triggered(self):
        """Holding X must step one notch, not run to the far end."""
        self.hold("x", frames=200)
        self.assertEqual(self.byte("CAM_ZOOM"), 2, "holding X ran the zoom out")


class TestPause(ControlFixture):

    def test_space_freezes_the_ships(self):
        ship_x = lambda: self.word("ENTITIES", 0, signed=True)

        #  Give the fleet somewhere to be that it is not, so it is definitely
        #  in motion when we pause it.
        self.open_disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        self.hold(cpc.KEY_ENTER, frames=8)

        self.c.run_frames(20)
        moving_before = ship_x()
        self.c.run_frames(30)
        self.assertNotEqual(ship_x(), moving_before, "the fleet was not moving to begin with")

        self.hold(cpc.KEY_SPACE, frames=8)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        frozen = ship_x()
        self.c.run_frames(60)
        self.assertEqual(ship_x(), frozen, "SPACE did not freeze the fleet")

        self.hold(cpc.KEY_SPACE, frames=8)
        self.assertEqual(self.byte("ORDER_PAUSED"), 0)
        self.c.run_frames(40)
        self.assertNotEqual(ship_x(), frozen, "SPACE did not unfreeze the fleet")

    def test_the_camera_still_works_while_paused(self):
        """'Η μάχη παγώνει, οι εντολές συνεχίζουν.'"""
        self.hold(cpc.KEY_SPACE, frames=8)
        before = self.byte("CAM_YAW")
        self.hold(cpc.KEY_RIGHT)
        self.assertNotEqual(self.byte("CAM_YAW"), before,
                            "pausing froze the camera too")


class TestMoveDisc(ControlFixture):

    def test_enter_opens_the_disc_at_the_squadron_station(self):
        self.assertEqual(self.byte("DISC_ACTIVE"), 0)
        self.open_disc()
        self.assertEqual(self.disc(), self.dest_of(1),
                         "the disc did not start where the squadron is stationed")

    def test_cursor_keys_move_the_disc_on_the_reference_plane(self):
        self.open_disc()
        before = self.disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        after = self.disc()
        self.assertNotEqual((after[0], after[2]), (before[0], before[2]),
                            "the disc did not move across the plane")
        self.assertEqual(after[1], before[1], "moving across the plane changed the height")

    def test_shift_and_the_cursor_change_height(self):
        """Section 9: SHIFT swaps the cursor from the plane to the vertical."""
        self.open_disc()
        before = self.disc()
        self.hold_shifted(cpc.KEY_UP)
        after = self.disc()
        self.assertGreater(after[1], before[1], "SHIFT+UP did not raise the disc")
        self.assertEqual((after[0], after[2]), (before[0], before[2]),
                         "changing height moved it across the plane too")

        self.hold_shifted(cpc.KEY_DOWN)
        self.assertLess(self.disc()[1], after[1], "SHIFT+DOWN did not lower it")

    def test_the_disc_moves_relative_to_the_camera(self):
        """'Right' has to mean right on screen, whatever the camera is doing."""
        self.open_disc()
        start = self.disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        moved_at_zero_yaw = tuple(a - b for a, b in zip(self.disc(), start))

        #  Turn a quarter circle and push it the same way again.
        self.hold(cpc.KEY_ESC, frames=8)
        self.c.write_ram(self.sym["CAM_YAW"], bytes([64]))
        self.c.run_frames(20)
        self.open_disc()
        start = self.disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        moved_at_quarter = tuple(a - b for a, b in zip(self.disc(), start))

        self.assertNotEqual(moved_at_zero_yaw, moved_at_quarter,
                            "the disc moves along world axes, not camera-relative ones")

    def test_enter_confirms_and_the_squadron_is_re_stationed(self):
        self.open_disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        target = self.disc()

        self.hold(cpc.KEY_ENTER, frames=8)
        self.assertEqual(self.byte("DISC_ACTIVE"), 0, "the disc stayed open")
        self.assertEqual(self.dest_of(1), target,
                         "the squadron was not given the order")

    def test_esc_cancels_without_giving_the_order(self):
        before = self.dest_of(1)
        self.open_disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        self.hold(cpc.KEY_ESC, frames=8)
        self.assertEqual(self.byte("DISC_ACTIVE"), 0, "the disc stayed open")
        self.assertEqual(self.dest_of(1), before, "ESC gave the order anyway")

    def test_the_order_only_moves_the_selected_squadron(self):
        self.hold("d", frames=30)                 # split into 1 and 2
        before_two = self.dest_of(2)

        self.open_disc()
        self.hold(cpc.KEY_RIGHT, frames=60)
        self.hold(cpc.KEY_ENTER, frames=8)

        self.assertEqual(self.dest_of(2), before_two,
                         "the order moved a squadron that was not selected")

    def test_the_fleet_flies_to_the_new_station(self):
        ship_x = lambda: self.word("ENTITIES", 0, signed=True)
        self.c.run_frames(150)                    # settle into formation first
        settled = ship_x()

        self.open_disc()
        self.hold(cpc.KEY_RIGHT, frames=70)
        target_x = self.disc()[0]
        self.hold(cpc.KEY_ENTER, frames=8)

        self.c.run_frames(300)
        moved = ship_x()
        self.assertNotEqual(moved, settled, "the fleet ignored the order")
        self.assertLess(abs(moved - target_x), 12000,
                        f"the fleet is at {moved}, nowhere near the order at {target_x}")

    def test_the_disc_leaves_no_trail(self):
        """It moves every frame, so a wrong dirty rectangle draws a comb."""
        self.open_disc()
        self.c.key_down(cpc.KEY_RIGHT)
        for _ in range(8):
            self.c.run_frames(12)
            front = h.front_buffer(self.c)
            ram = self.c.read_ram(front, 0x4000)
            #  The stem is pen 2, which the interceptor sprites also use, so
            #  count whole columns that are lit top to bottom instead: a
            #  trail shows up as several of them, a live stem as at most one.
            tall = 0
            for x in range(80):
                lit = sum(1 for y in range(0, 168) if ram[h.screen_offset(y, x)])
                if lit > 60:
                    tall += 1
            self.assertLessEqual(tall, 1, f"{tall} full-height columns: the disc is trailing")
        self.c.key_up(cpc.KEY_RIGHT)


if __name__ == "__main__":
    unittest.main()
