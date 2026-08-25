"""Phase 5: the control layer -- camera, zoom, pause and the move disc.

Everything here presses real keys in the emulator. The point of Phase 5 is
that a person can fly the camera and give an order, so testing the routines
directly would skip the half that matters.

Key assignment note: section 9 of the design puts the move order on `M` and
docking on `D`, but those keys belong to the squadron commands, so the move
disc opens and confirms with ENTER and cancels with ESC.
"""

from __future__ import annotations

import random
import struct
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


class TestSelectionAndCamera(ControlFixture):
    """Section 4.3: the camera orbits the Mothership or the selected squadron."""

    def focus(self):
        return tuple(self.word("CAM_FOCUS_X", i * 2, signed=True) for i in range(3))

    def test_the_camera_follows_the_selected_squadron(self):
        self.assertEqual(self.focus(), self.dest_of(1),
                         "the camera does not start on the selection")
        self.hold("d", frames=30)
        self.hold("2", frames=25)
        self.assertEqual(self.byte("SQUAD_SEL"), 2)
        self.assertEqual(self.focus(), self.dest_of(2),
                         "selecting a squadron did not move the camera to it")

    def test_zero_selects_the_mothership(self):
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 0)
        self.hold("0", frames=25)
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 1, "'0' did not select the Mothership")

        slot = self.byte("MOTH_SLOT")
        base = self.sym["ENTITIES"] + slot * 20
        pos = []
        for i in range(3):
            lo, hi = self.c.read_ram(base + i * 2, 2)
            v = lo | (hi << 8)
            pos.append(v - 65536 if v >= 32768 else v)
        self.assertEqual(self.focus(), tuple(pos),
                         "the camera did not move to the Mothership")

    def test_picking_a_squadron_takes_the_camera_off_the_mothership(self):
        self.hold("0", frames=25)
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 1)
        self.hold("1", frames=25)
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 0)
        self.assertEqual(self.focus(), self.dest_of(1))

    def test_the_mothership_is_not_in_a_squadron(self):
        """It is the fleet's base, not part of the fleet."""
        slot = self.byte("MOTH_SLOT")
        base = self.sym["ENTITIES"] + slot * 20
        self.assertEqual(self.c.read_ram(base + 12, 1)[0], 0, "the Mothership joined a squadron")
        self.assertEqual(self.c.read_ram(base + 9, 1)[0], 1, "the Mothership is not its own class")

    def test_the_mothership_draws_a_tier_larger_than_a_fighter(self):
        """Otherwise a capital ship reads as one more speck in the swarm."""
        h.run_to_stable_point(self.c, self.sym)
        n = self.byte("PHASE4_VISIBLE")
        raw = self.c.read_ram(self.sym["PHASE4_VIS"], n * 6)
        tiers = {}
        for i in range(n):
            packed = raw[i * 6 + 5]
            tiers.setdefault(packed >> 2, []).append(packed & 3)
        self.assertIn(1, tiers, "the Mothership was not drawn at all")
        self.assertGreater(max(tiers[1]), min(tiers[0]),
                           "the Mothership draws no larger than a fighter")


class TestFormations(ControlFixture):
    """Section 9: F cycles Loose / Wedge / Sphere / Wall."""

    def formation(self):
        return self.c.read_ram(self.sym["SQUAD_FORM"], 10)[1]

    def test_f_cycles_all_four_and_wraps(self):
        seen = []
        for _ in range(5):
            seen.append(self.formation())
            self.hold("f", frames=20)
        self.assertEqual(seen, [0, 1, 2, 3, 0], f"F cycled {seen}")

    def test_changing_formation_moves_the_ships(self):
        self.c.run_frames(250)                  # settle into Loose
        settled = [self.word("ENTITIES", i * 20, signed=True) for i in range(6)]

        self.hold("f", frames=20)               # -> Wedge
        self.c.run_frames(250)
        reshaped = [self.word("ENTITIES", i * 20, signed=True) for i in range(6)]

        self.assertNotEqual(settled, reshaped, "the squadron did not reshape")

    def test_each_squadron_keeps_its_own_shape(self):
        self.hold("d", frames=30)               # split into 1 and 2
        self.hold("f", frames=20)               # reshape only squadron 1
        forms = self.c.read_ram(self.sym["SQUAD_FORM"], 10)
        self.assertEqual(forms[1], 1, "squadron 1 did not change shape")
        self.assertEqual(forms[2], 0, "the change leaked into squadron 2")


class TestSensorView(ControlFixture):
    """Section 9: a stripped-back view of dots, and time at triple speed."""

    def test_s_toggles_the_view(self):
        #  TAB is what the design asks for and is bound, but the emulator's
        #  keymap has no TAB entry so it cannot be pressed here. `S` does the
        #  same thing and is testable.
        self.assertEqual(self.byte("VIEW_SENSORS"), 0)
        self.hold("s", frames=20)
        self.assertEqual(self.byte("VIEW_SENSORS"), 1)
        self.hold("s", frames=20)
        self.assertEqual(self.byte("VIEW_SENSORS"), 0)

    def test_sensors_draw_far_less_than_the_tactical_view(self):
        def lit():
            ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
            return sum(1 for y in range(168) for x in range(80) if ram[h.screen_offset(y, x)])

        self.c.run_frames(120)
        tactical = lit()
        self.hold("s", frames=20)
        self.c.run_frames(120)
        sensors = lit()

        self.assertGreater(tactical, 0)
        self.assertLess(sensors, tactical // 3,
                        f"sensors lit {sensors} bytes against the tactical view's {tactical}")

    def test_time_runs_faster_in_the_sensor_view(self):
        """The cheap drawing is what pays for the fast-forward.

        Measured per GAME FRAME, not per wall-clock second. Sensors also run
        at a different frame rate, and comparing raw distance covered would
        just conflate the two -- and the fleet would arrive somewhere in the
        middle of the second window anyway.
        """
        def travel_per_frame(pal_frames):
            #  Put the ship back at the far end before each window, so both
            #  are measured with the same distance left to run. Without this
            #  whichever window goes second finds the fleet has arrived and
            #  measures nothing.
            self.c.write_ram(self.sym["ENTITIES"], struct.pack("<h", -30000))
            self.c.run_frames(4)
            x0 = self.word("ENTITIES", 0, signed=True)
            f0 = self.byte("DEMO_FRAMES")
            self.c.run_frames(pal_frames)
            x1 = self.word("ENTITIES", 0, signed=True)
            f1 = self.byte("DEMO_FRAMES")
            frames = (f1 - f0) % 256
            self.assertGreater(frames, 2, "the game barely advanced")
            return abs(x1 - x0) / frames

        #  Station the squadron a very long way off, so it is still in transit
        #  through both windows.
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 30000, 0, 0))
        self.c.run_frames(20)

        tactical = travel_per_frame(80)
        self.hold("s", frames=20)
        sensors = travel_per_frame(80)

        self.assertGreater(tactical, 0, "the fleet was not moving to begin with")
        ratio = sensors / tactical
        self.assertGreater(ratio, 2.0,
                           f"sensors advance {ratio:.1f}x per frame, not the ~3x of section 9")

    def test_no_residue_in_the_sensor_view(self):
        self.hold("s", frames=20)
        self.open_disc()
        self.c.key_down(cpc.KEY_RIGHT)
        for _ in range(6):
            self.c.run_frames(15)
            ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
            lit = sum(1 for y in range(168) for x in range(80) if ram[h.screen_offset(y, x)])
            self.assertLess(lit, 200, f"{lit} lit bytes: the dots are trailing")
        self.c.key_up(cpc.KEY_RIGHT)


class TestOrders(ControlFixture):
    """The rest of section 9's command set."""

    ENT_ORDER = 13
    ENT_TARGET = 14
    ORDER_ATTACK = 2
    ORDER_GUARD = 3

    def ent_field(self, slot, offset):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * 20 + offset, 1)[0]

    def test_r_stations_the_squadron_on_the_mothership(self):
        self.hold("d", frames=30)
        self.hold("2", frames=25)
        self.assertNotEqual(self.dest_of(2), (0, 0, 0))
        self.hold("r", frames=25)
        self.assertEqual(self.dest_of(2), (0, 0, 0),
                         "R did not send the squadron to the Mothership")

    def test_comma_and_period_walk_the_target(self):
        self.assertEqual(self.byte("ORDER_TARGET"), 0xFF, "something is targeted at boot")
        self.hold(".", frames=20)
        first = self.byte("ORDER_TARGET")
        self.hold(".", frames=20)
        second = self.byte("ORDER_TARGET")
        self.assertNotEqual(first, second, "'.' did not advance the target")
        self.hold(",", frames=20)
        self.assertEqual(self.byte("ORDER_TARGET"), first, "',' did not go back")

    def test_the_target_is_always_a_live_entity(self):
        for _ in range(12):
            self.hold(".", frames=15)
            target = self.byte("ORDER_TARGET")
            self.assertLess(target, 48, "the target walked off the entity table")
            self.assertTrue(self.ent_field(target, 11) & 1,
                            f"slot {target} is targeted but not active")

    def test_a_and_g_write_orders_into_the_selected_squadron_only(self):
        """The records carry the order; nothing acts on it until phase 6."""
        self.hold("d", frames=30)                 # 1 and 2 both have ships
        self.hold(".", frames=20)
        target = self.byte("ORDER_TARGET")

        self.hold("a", frames=25)
        selected = self.byte("SQUAD_SEL")

        touched = untouched = 0
        for slot in range(20):
            squadron = self.ent_field(slot, 12)
            order = self.ent_field(slot, self.ENT_ORDER)
            if squadron == selected:
                self.assertEqual(order, self.ORDER_ATTACK, f"slot {slot} did not get the order")
                self.assertEqual(self.ent_field(slot, self.ENT_TARGET), target)
                touched += 1
            else:
                self.assertEqual(order, 0, f"slot {slot} is in squadron {squadron} and got the order")
                untouched += 1
        self.assertGreater(touched, 0)
        self.assertGreater(untouched, 0, "the split did not leave anyone out")

        self.hold("g", frames=25)
        for slot in range(20):
            if self.ent_field(slot, 12) == selected:
                self.assertEqual(self.ent_field(slot, self.ENT_ORDER), self.ORDER_GUARD)


class TestApproach(ControlFixture):
    """phase4_approach, the one-axis step a ship takes towards its slot.

    Tested directly and over the whole 16-bit range, because the interesting
    case is one the fleet almost never reaches on its own: a ship and its
    target more than 32767 apart. `target - current` does not fit in sixteen
    bits there, SBC overflows, and the sign bit comes out backwards -- so the
    ship flies AWAY from where it was sent, forever. It took poking a ship to
    one end of the world to find it.
    """

    STEP = 600

    def approach(self, current, target):
        addr = self.sym["PHASE4_APPROACH"]
        self.c.write_ram(self.sym["PHASE4_CUR"], struct.pack("<h", current))
        self.c.write_ram(self.sym["PHASE4_TGT"], struct.pack("<h", target))
        self.c.write_ram(0x3000, bytes([
            0xF3,
            0xCD, addr & 0xFF, addr >> 8,
            0x22, 0x00, 0x2F,                   # ld (#2F00),hl
            0x18, 0xFE,
        ]))
        self.c.set_pc(0x3000)
        self.c.run_frames(2)
        lo, hi = self.c.read_ram(0x2F00, 2)
        v = lo | (hi << 8)
        return v - 65536 if v >= 32768 else v

    def expected(self, current, target):
        delta = target - current
        if abs(delta) <= self.STEP:
            return target
        return current + (self.STEP if delta > 0 else -self.STEP)

    def _check(self, current, target):
        got = self.approach(current, target)
        want = self.expected(current, target)
        self.assertEqual(got, want, f"from {current} towards {target}")

    def test_steps_and_snaps_near_the_origin(self):
        for current, target in ((0, 5000), (0, -5000), (0, 100), (0, -100), (0, 0),
                                (-600, 0), (600, 0), (20000, 20300), (20000, 19700)):
            self._check(current, target)

    def test_survives_targets_more_than_32767_away(self):
        for current, target in ((-30000, 23400), (30000, -23400),
                                (-32000, 32000), (32000, -32000),
                                (-32768, 32767), (32767, -32768)):
            self._check(current, target)

    def test_random_pairs_across_the_whole_world(self):
        rng = random.Random(4)
        for _ in range(60):
            self._check(rng.randrange(-32768, 32768), rng.randrange(-32768, 32768))
