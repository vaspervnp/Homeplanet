"""V: fly one ship yourself (game/pilot.asm, future.md item 1).

Every claim here is about a SLOT -- which ship, where it is, what it is aiming
at -- and never a count. The mode is invisible to a count: the right ships die
in the right numbers whether or not the player's hands were on one of them.
"""

import struct
import unittest

from tests import harness as h
from tests.harness import cpc

ENT_SIZE = 20
ENT_X, ENT_Y, ENT_Z, ENT_YAW = 0, 2, 4, 6
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_TIMER = 9, 10, 11, 12, 13, 14, 19
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4


class PilotFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.ENT_MAX = cls.sym["ENT_MAX"]
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.NONE = cls.sym["ENT_NO_TARGET"]
        cls.PILOT = cls.sym["ENT_ORDER_PILOT"]
        cls.IDLE = cls.sym["ENT_ORDER_IDLE"]

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.let_the_game_draw(self.c, self.sym)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading the machine --------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def word(self, name, offset=0):
        lo, hi = self.c.read_ram(self.sym[name] + offset, 2)
        v = lo | (hi << 8)
        return v - 65536 if v >= 32768 else v

    def rec(self, slot):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE, ENT_SIZE)

    def field(self, slot, off):
        return self.rec(slot)[off]

    def pos(self, slot):
        return struct.unpack("<hhh", self.rec(slot)[:6])

    def poke(self, slot, off, data):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, data)

    def pilot(self):
        return self.byte("PILOT_SLOT")

    def focus(self):
        return tuple(self.word("CAM_FOCUS_X", i * 2) for i in range(3))

    def game_frames(self):
        return self.byte("DEMO_FRAMES")

    # -- pressing things --------------------------------------------------------
    def hold(self, key, frames=30, release=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def take_the_stick(self):
        self.hold("v")
        p = self.pilot()
        self.assertLess(p, self.PLAYER_MAX, "V did not take a ship")
        return p


class TestVTakesAShipAndGivesItBack(PilotFixture):

    def test_v_takes_the_lead_ship_of_the_selection(self):
        sel = self.byte("SQUAD_SEL")
        self.assertNotEqual(sel, 0)
        p = self.take_the_stick()
        self.assertEqual(self.field(p, ENT_ORDER), self.PILOT)
        self.assertEqual(self.field(p, ENT_SQUAD), sel, "the ship is not in the selected squadron")
        self.assertEqual(self.field(p, ENT_FLAGS) & (F_ACTIVE | F_DISABLED), F_ACTIVE)
        #  ...and the LEAD ship: nothing flying in that squadron sits below it.
        for s in range(p):
            r = self.rec(s)
            if r[ENT_FLAGS] & F_ACTIVE and not r[ENT_FLAGS] & F_DISABLED:
                self.assertNotEqual(r[ENT_SQUAD], sel, f"slot {s} is a lower-numbered ship of the squadron")

    def test_v_again_hands_it_back_idle(self):
        p = self.take_the_stick()
        self.hold("v")
        self.assertEqual(self.pilot(), self.NONE, "V did not hand the ship back")
        self.assertEqual(self.field(p, ENT_ORDER), self.IDLE, "the ship came back under an order")

    def test_the_mothership_is_not_flown(self):
        self.hold("0")
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 1)
        self.hold("v")
        self.assertEqual(self.pilot(), self.NONE, "V flew the Mothership")

    def test_the_other_ships_of_the_squadron_stay_under_the_ai(self):
        p = self.take_the_stick()
        others = [s for s in range(self.PLAYER_MAX)
                  if s != p and self.field(s, ENT_FLAGS) & F_ACTIVE and self.field(s, ENT_SQUAD) == self.field(p, ENT_SQUAD)]
        self.assertGreater(len(others), 1)
        for s in others:
            self.assertNotEqual(self.field(s, ENT_ORDER), self.PILOT, f"slot {s} is also being flown")


class TestFlying(PilotFixture):

    def test_it_flies_straight_along_its_heading(self):
        """Forward is world (sin y, -cos y): at yaw 0 the ship goes to -Z and
        X does not move, at yaw 64 it goes to +X. Two hundred a frame, which
        is PILOT_STEP_HALF doubled; one frame of slack for the read landing
        mid-frame."""
        p = self.take_the_stick()
        self.poke(p, ENT_YAW, bytes([0]))
        self.c.run_frames(10)
        x0, y0, z0 = self.pos(p)
        f0 = self.game_frames()
        self.c.run_frames(100)
        x1, y1, z1 = self.pos(p)
        frames = (self.game_frames() - f0) & 255
        self.assertGreater(frames, 3)
        step = 2 * self.sym["PILOT_STEP_HALF"]
        self.assertEqual(x1, x0, "a ship at yaw 0 drifted in X")
        self.assertEqual(y1, y0, "a ship with no UP or DOWN changed height")
        self.assertLess(z1, z0, "yaw 0 did not fly towards -Z")
        self.assertLessEqual(abs((z0 - z1) - frames * step), step,
                             f"{z0 - z1} in {frames} frames is not {step} a frame")

        self.poke(p, ENT_YAW, bytes([64]))
        self.c.run_frames(10)
        x0, y0, z0 = self.pos(p)
        self.c.run_frames(60)
        x1, y1, z1 = self.pos(p)
        self.assertGreater(x1, x0, "yaw 64 did not fly towards +X")
        self.assertEqual(z1, z0, "a ship at yaw 64 drifted in Z")

    def test_it_is_not_dragged_back_to_its_formation_slot(self):
        """phase4_fly steps over the order: a flown ship keeps going where it
        is pointed, and the distance from its station only grows."""
        p = self.take_the_stick()
        self.poke(p, ENT_YAW, bytes([0]))
        dest = tuple(self.word("SQUAD_DEST", i * 2) for i in range(3))
        far = []
        for _ in range(6):
            self.c.run_frames(40)
            far.append(sum(abs(a - b) for a, b in zip(self.pos(p), dest)))
        self.assertEqual(far, sorted(far), f"the ship came back towards its station: {far}")
        self.assertGreater(far[-1], far[0] + 2000)

    def test_left_turns_it_one_way_and_right_the_other(self):
        """LEFT is yaw INCREASING -- see the header of game/pilot.asm for why
        that is the direction the nose swings left in the tail-on view."""
        p = self.take_the_stick()
        y0 = self.field(p, ENT_YAW)
        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(40)
        self.c.key_up(cpc.KEY_LEFT)
        y1 = self.field(p, ENT_YAW)
        turned = (y1 - y0) & 255
        self.assertTrue(0 < turned < 128, f"LEFT turned the yaw by {turned}")
        self.c.run_frames(20)
        y1 = self.field(p, ENT_YAW)
        self.c.key_down(cpc.KEY_RIGHT)
        self.c.run_frames(40)
        self.c.key_up(cpc.KEY_RIGHT)
        y2 = self.field(p, ENT_YAW)
        turned = (y1 - y2) & 255
        self.assertTrue(0 < turned < 128, f"RIGHT turned the yaw by {-turned & 255}")

    def test_up_climbs_and_down_dives(self):
        p = self.take_the_stick()
        y0 = self.pos(p)[1]
        self.c.key_down(cpc.KEY_UP)
        self.c.run_frames(40)
        self.c.key_up(cpc.KEY_UP)
        y1 = self.pos(p)[1]
        self.assertGreater(y1, y0, "UP did not climb")
        self.c.key_down(cpc.KEY_DOWN)
        self.c.run_frames(80)
        self.c.key_up(cpc.KEY_DOWN)
        y2 = self.pos(p)[1]
        self.assertLess(y2, y1, "DOWN did not dive")

    def test_the_arrows_no_longer_orbit_the_camera(self):
        """The camera is the ship's now: LEFT turns the ship and the camera
        follows it, rather than orbiting the station."""
        p = self.take_the_stick()
        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(40)
        self.c.key_up(cpc.KEY_LEFT)
        self.c.run_frames(10)
        self.assertEqual(self.byte("CAM_YAW"), (self.field(p, ENT_YAW) + 128) & 255)


class TestTheCameraRidesBehindIt(PilotFixture):

    def test_the_focus_is_the_ship_and_the_yaw_is_its_own_plus_a_half_turn(self):
        """Paused first, so the ship holds still and a read cannot land between
        the move and the focus. SPACE before V is the pause; after V it would
        be the gun."""
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        p = self.take_the_stick()
        self.c.run_frames(30)
        self.assertEqual(self.focus(), self.pos(p), "the camera is not on the ship")
        self.assertEqual(self.byte("CAM_YAW"), (self.field(p, ENT_YAW) + 128) & 255,
                         "the camera is not behind the ship")

    def test_the_eye_is_inside_the_ship_and_the_ship_is_not_drawn(self):
        """cam_dist one unit inside the near plane, pitch level with the nose,
        and the flown ship itself clipped: its per-slot projection cache is
        never stamped with the current frame while it is being flown."""
        zoom_dist = self.word("CAM_DIST")
        pitch0 = self.byte("CAM_PITCH")
        self.c.key_down(cpc.KEY_UP)                          # an orbit pitch to come back to
        self.c.run_frames(30)
        self.c.key_up(cpc.KEY_UP)
        self.c.run_frames(20)
        pitch1 = self.byte("CAM_PITCH")
        self.assertNotEqual(pitch1, 0)
        p = self.take_the_stick()
        self.c.run_frames(30)
        self.assertEqual(self.word("CAM_DIST"), self.sym["Z_NEAR"] - 1, "the eye is not inside the ship")
        self.assertEqual(self.byte("CAM_PITCH"), 0, "the view is not level with the nose")
        stamped = h.read_bank4(self.c, self.sym["SHOT_POS"] + p * 4 + 3, 1)[0]
        self.assertNotEqual(stamped, self.game_frames(), "the flown ship was projected: it is being drawn")
        #  ...and something ahead of it IS: the Mothership, after a turn towards it.
        self.hold("v")
        self.c.run_frames(20)
        self.assertEqual(self.word("CAM_DIST"), zoom_dist, "the zoom's cam_dist did not come back")
        self.assertEqual(self.byte("CAM_PITCH"), pitch1, "the orbit's pitch did not come back")

    def test_the_fight_ending_hands_it_back(self):
        """"Όταν τελειώνει η μάχη να βγαίνω από το V αυτόματα": a hostile
        flying while the ship is flown, then none, and the stick goes back
        by itself -- the ship IDLE again, the slot released."""
        e = self.PLAYER_MAX
        self.poke(e, 0, struct.pack("<hhh", 0, 0, 9000))
        self.poke(e, ENT_CLASS, b"\x00")
        self.poke(e, ENT_HULL, b"\xff")
        self.poke(e, ENT_SQUAD, b"\xff")
        self.poke(e, ENT_ORDER, b"\x00")
        self.poke(e, ENT_TARGET, b"\xff")
        self.poke(e, ENT_TIMER, b"\xff")
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        p = self.take_the_stick()
        self.c.run_frames(40)
        self.assertEqual(self.pilot(), p, "the ship was handed back with the hostile still flying")
        #  ...and the fight ends: the hostile is a wreck, which is not flying.
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | F_DISABLED]))
        for _ in range(20):
            self.c.run_frames(10)
            if self.pilot() >= self.ENT_MAX:
                break
        else:
            self.fail("the fight ended and the ship was not handed back")
        self.assertEqual(self.field(p, ENT_ORDER), self.IDLE)

    def test_a_quiet_board_does_not_hand_it_back(self):
        """Mission 1 has nothing hostile until the first wave. Ending V the
        frame it began would make it a key that does nothing there."""
        p = self.take_the_stick()
        self.c.run_frames(100)
        self.assertEqual(self.pilot(), p, "V ended on a board with no fight on it")

    def test_its_death_hands_the_camera_back_to_the_station(self):
        p = self.take_the_stick()
        self.c.run_frames(20)
        self.assertNotEqual(self.focus(), tuple(self.word("SQUAD_DEST", i * 2) for i in range(3)))
        self.poke(p, ENT_FLAGS, bytes([0]))                 # shot down
        self.c.run_frames(40)
        self.assertEqual(self.pilot(), self.NONE, "a dead ship is still being flown")
        self.hold(cpc.KEY_SPACE)                             # ...and SPACE is the pause again
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        self.c.run_frames(20)
        #  ...to the squadron: the middle of the box round its flying ships,
        #  which the dead one is no longer in.
        base = self.sym["ENTITIES"]
        pts = [struct.unpack("<hhh", self.rec(s)[:6]) for s in range(self.PLAYER_MAX)
               if (self.field(s, ENT_FLAGS) & 5) == 1 and self.field(s, ENT_SQUAD) == self.byte("SQUAD_SEL")]
        want = tuple((min(q[i] for q in pts) + max(q[i] for q in pts)) >> 1 for i in range(3))
        self.assertEqual(self.focus(), want, "the camera did not go back to the squadron")


class TestSpaceIsTheTrigger(PilotFixture):
    """The gun is cbt_fire_if_able's, held by a timer the pilot parks at one:
    these call pilot_frame and then cbt_update through a stub, with the edge
    poked into key_hits, so each frame is one frame and nothing else moves."""

    def stage(self):
        base = self.sym["ENTITIES"]
        for slot in range(self.ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        def place(slot, enemy, pos):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", *pos))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))
            self.c.write_ram(addr + ENT_HULL, b"\xff")
            self.c.write_ram(addr + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER, bytes([self.PILOT if not enemy else 0]))
            self.c.write_ram(addr + ENT_TARGET, b"\xff")
            self.c.write_ram(addr + ENT_TIMER, b"\x00")
        self.ME, self.ENEMY = 0, self.PLAYER_MAX
        place(self.ME, False, (0, 0, 0))
        place(self.ENEMY, True, (0, 0, -1000))              # well inside CBT_RANGE
        #  ...and flying AWAY from it: yaw 128 is +Z, and a ship flown at a
        #  hostile inside PILOT_RAM_DIST rams it, which is a different test.
        self.poke(self.ME, ENT_YAW, bytes([128]))
        self.c.write_ram(self.sym["PILOT_SLOT"], bytes([self.ME]))
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.c.write_ram(self.sym["AUTO_ARMED"], b"\x00")

    def one_frame(self, space):
        hits = bytearray(10)
        if space:
            k = self.sym["KEY_SPACE"]
            hits[k >> 3] |= 1 << (k & 7)
        self.c.write_ram(self.sym["KEY_HITS"], bytes(hits))
        pf, cu = self.sym["PILOT_FRAME"], self.sym["CBT_UPDATE"]
        stub = bytes([0x01, self.sym["GA_BANK_4"], 0x7F, 0xED, 0x49,     # bank 4 under the window
                      0xCD, pf & 0xFF, pf >> 8,
                      0xCD, cu & 0xFF, cu >> 8,
                      0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(2)

    def enemy_hull(self):
        return self.field(self.ENEMY, ENT_HULL)

    def test_a_ready_gun_does_not_fire_on_its_own(self):
        self.stage()
        for _ in range(4):
            self.one_frame(space=False)
            self.assertEqual(self.enemy_hull(), 255, "the flown ship fired by itself")
            self.assertEqual(self.field(self.ME, ENT_TIMER), 0, "the hold was not taken back to zero")

    def test_space_fires_once_and_the_cooldown_holds(self):
        self.stage()
        self.one_frame(space=True)
        self.assertLess(self.enemy_hull(), 255, "SPACE did not fire")
        hit = 255 - self.enemy_hull()
        self.assertEqual(self.field(self.ME, ENT_TIMER), self.sym["CBT_COOLDOWN"],
                         "the shot did not start the gun's own cooldown")
        self.one_frame(space=True)
        self.assertEqual(self.enemy_hull(), 255 - hit, "SPACE fired again inside the cooldown")
        for _ in range(self.sym["CBT_COOLDOWN"]):
            self.one_frame(space=False)
        self.assertEqual(self.field(self.ME, ENT_TIMER), 0)
        self.one_frame(space=True)
        self.assertEqual(self.enemy_hull(), 255 - 2 * hit, "the second shot after the cooldown did not land")

    def test_the_enemy_is_the_target_it_aims_at(self):
        self.stage()
        self.one_frame(space=True)
        self.assertEqual(self.field(self.ME, ENT_TARGET), self.ENEMY)


class TestInTheGame(PilotFixture):
    """The same two claims end to end, with the ship flying a circle round the
    enemy under a held LEFT so the range is never lost."""

    def stage_a_duel(self):
        p = self.take_the_stick()
        #  Far from the fleet, so nothing else can reach the enemy: a Manhattan
        #  distance past 16320 saturates cbt_distance and is never picked.
        self.poke(p, ENT_X, struct.pack("<hhh", 20000, 0, 20000))
        self.poke(p, ENT_YAW, bytes([0]))
        #  Twelve hundred units to -X: inside CBT_RANGE, and OFF the circle a
        #  held LEFT flies -- the turn veers to +X, so the circle's nearest
        #  point to the enemy is where the ship starts. Any closer and
        #  pilot_ram gets there before SPACE does.
        e = self.PLAYER_MAX
        self.poke(e, ENT_X, struct.pack("<hhh", 20000 - 1200, 0, 20000))
        self.poke(e, ENT_CLASS, bytes([0]))
        self.poke(e, ENT_HULL, b"\xff")
        self.poke(e, ENT_SQUAD, b"\xff")
        self.poke(e, ENT_ORDER, b"\x00")
        self.poke(e, ENT_TARGET, b"\xff")
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        self.c.key_down(cpc.KEY_LEFT)
        return p, e

    def test_space_does_not_pause_and_does_shoot(self):
        p, e = self.stage_a_duel()
        #  Twelve taps and not thirty: the enemy shoots back at the same rate
        #  and an interceptor's 255 hull is ten hits. Measured, the flown ship
        #  dies on the twenty-fifth tap -- with the enemy at 39.
        for _ in range(12):
            self.c.run_frames(6)
            self.c.key_down(cpc.KEY_SPACE)
            self.c.run_frames(6)
            self.c.key_up(cpc.KEY_SPACE)
            self.assertEqual(self.byte("ORDER_PAUSED"), 0, "SPACE paused the game while flying")
        self.c.key_up(cpc.KEY_LEFT)
        self.assertLess(self.field(e, ENT_HULL), 255, "the flown ship never hit the enemy")
        self.assertEqual(self.pilot(), p)

    def test_without_space_it_never_fires(self):
        p, e = self.stage_a_duel()
        self.c.run_frames(200)
        self.c.key_up(cpc.KEY_LEFT)
        self.assertEqual(self.pilot(), p, "the flown ship died inside the window: shorten it")
        self.assertEqual(self.field(e, ENT_HULL), 255, "the flown ship fired without SPACE")
        self.assertLess(self.field(p, ENT_HULL), 255, "the enemy never shot back, so the two were never in range")


class TestRamming(PilotFixture):
    """future.md item 7: a flown ship into a hostile, and both pay its hull."""

    def test_flying_into_a_hostile_costs_both_the_pilots_hull(self):
        p = self.take_the_stick()
        self.poke(p, ENT_X, struct.pack("<hhh", 20000, 0, 20000))
        self.poke(p, ENT_YAW, bytes([0]))                   # towards -Z
        e = self.PLAYER_MAX
        self.poke(e, ENT_X, struct.pack("<hhh", 20000, 0, 19000))
        self.poke(e, ENT_CLASS, bytes([0]))
        self.poke(e, ENT_HULL, bytes([100]))
        self.poke(e, ENT_SQUAD, b"\xff")
        self.poke(e, ENT_ORDER, b"\x00")
        self.poke(e, ENT_TARGET, b"\xff")
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        kills0 = self.byte("CBT_KILLS")
        for _ in range(60):
            self.c.run_frames(5)
            if self.pilot() == self.NONE:
                break
        else:
            self.fail("the two never met")
        self.assertEqual(self.field(p, ENT_FLAGS) & F_ACTIVE, 0, "the rammer survived its own hull")
        self.assertTrue(not self.field(e, ENT_FLAGS) & F_ACTIVE or self.field(e, ENT_FLAGS) & F_DISABLED,
                        "a hundred hull did not go down under a fresh interceptor")
        self.assertGreaterEqual(self.byte("CBT_KILLS"), kills0 + 1)

    def test_a_tougher_hull_survives_it_short_by_the_pilots_hull(self):
        p = self.take_the_stick()
        self.poke(p, ENT_X, struct.pack("<hhh", 20000, 0, 20000))
        self.poke(p, ENT_YAW, bytes([0]))
        e = self.PLAYER_MAX
        self.poke(e, ENT_X, struct.pack("<hhh", 20000, 0, 19000))
        self.poke(e, ENT_CLASS, bytes([0]))
        self.poke(e, ENT_HULL, b"\xff")
        self.poke(e, ENT_SQUAD, b"\xff")
        self.poke(e, ENT_ORDER, b"\x00")
        self.poke(e, ENT_TARGET, b"\xff")
        self.poke(e, ENT_TIMER, bytes([200]))               # it does not shoot first
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        self.poke(p, ENT_HULL, bytes([100]))                # a shot-up ship is a poor missile
        mine = 100
        for _ in range(60):
            self.c.run_frames(5)
            if self.pilot() == self.NONE:
                break
        else:
            self.fail("the two never met")
        self.assertEqual(self.field(e, ENT_HULL), 255 - mine)
        self.assertEqual(self.field(e, ENT_FLAGS) & (F_ACTIVE | F_DISABLED), F_ACTIVE)


class TestAJumpHandsItBack(PilotFixture):

    def test_nothing_arrives_still_being_flown(self):
        p = self.take_the_stick()
        self.assertEqual(self.field(p, ENT_ORDER), self.PILOT)
        h.jump_mission(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 1, "the jump did not happen")
        self.assertEqual(self.pilot(), self.NONE, "the jump carried the pilot")
        for s in range(self.PLAYER_MAX):
            r = self.rec(s)
            if r[ENT_FLAGS] & F_ACTIVE:
                self.assertNotEqual(r[ENT_ORDER], self.PILOT, f"slot {s} arrived under the pilot's order")


if __name__ == "__main__":
    unittest.main()
