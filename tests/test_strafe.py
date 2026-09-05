"""W: a strafing run (game/strafe.asm, future.md item 3).

An attack with a budget: the armed ships close, fire for CBT_STRAFE_FRAMES
frames of contact, and the order spends itself so phase4_fly takes them home.
Every claim is by slot -- which ships took the order, what their budget reads,
where they are -- because a count of shots is exactly what a pass preserves.
"""

import struct
import unittest

from tests import harness as h
from tests.harness import cpc

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_LOAD, ENT_TIMER = 9, 10, 11, 12, 13, 14, 15, 19
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4


class StrafeFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.STRAFE = cls.sym["ENT_ORDER_STRAFE"]
        cls.IDLE = cls.sym["ENT_ORDER_IDLE"]
        cls.HARVEST = cls.sym["ENT_ORDER_HARVEST"]
        cls.BUDGET = cls.sym["CBT_STRAFE_FRAMES"]

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.let_the_game_draw(self.c, self.sym)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def rec(self, slot):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE, ENT_SIZE)

    def field(self, slot, off):
        return self.rec(slot)[off]

    def pos(self, slot):
        return struct.unpack("<hhh", self.rec(slot)[:6])

    def poke(self, slot, off, data):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, data)

    def hold(self, key, frames=30, release=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def squadron(self, n=None):
        n = self.byte("SQUAD_SEL") if n is None else n
        return [s for s in range(self.PLAYER_MAX)
                if self.field(s, ENT_FLAGS) & F_ACTIVE and self.field(s, ENT_SQUAD) == n]

    def place_enemy(self, pos=(0, 0, 5000), hull=255, timer=255):
        """One hostile out along +Z with its own gun held, so the pass is the
        only thing being measured."""
        e = self.PLAYER_MAX
        self.poke(e, 0, struct.pack("<hhh", *pos))
        self.poke(e, ENT_CLASS, b"\x00")
        self.poke(e, ENT_HULL, bytes([hull]))
        self.poke(e, ENT_SQUAD, b"\xff")
        self.poke(e, ENT_ORDER, b"\x00")
        self.poke(e, ENT_TARGET, b"\xff")
        self.poke(e, ENT_TIMER, bytes([timer]))
        self.poke(e, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        return e

    def distance(self, a, b):
        return sum(abs(p - q) for p, q in zip(self.pos(a), self.pos(b)))


class TestTheOrder(StrafeFixture):

    def test_w_puts_the_armed_ships_under_strafe_with_a_full_budget(self):
        e = self.place_enemy()
        ships = self.squadron()
        self.assertGreater(len(ships), 4)
        self.hold("w")
        for s in ships:
            self.assertEqual(self.field(s, ENT_ORDER), self.STRAFE, f"slot {s} did not take the run")
            self.assertLessEqual(self.field(s, ENT_LOAD), self.BUDGET)
            self.assertGreater(self.field(s, ENT_LOAD), 0, f"slot {s} has no budget")

    def test_a_harvester_in_the_squadron_keeps_mining(self):
        e = self.place_enemy()
        ships = self.squadron()
        miner = ships[-1]
        self.poke(miner, ENT_CLASS, bytes([self.sym["CLASS_HARVESTER"]]))
        self.poke(miner, ENT_ORDER, bytes([self.HARVEST]))
        self.poke(miner, ENT_LOAD, bytes([7]))                # its hold
        self.hold("w")
        self.assertEqual(self.field(miner, ENT_ORDER), self.HARVEST, "W sent the miner on a run")
        self.assertEqual(self.field(miner, ENT_LOAD), 7, "W overwrote the miner's hold")
        self.assertEqual(self.field(ships[0], ENT_ORDER), self.STRAFE)

    def test_with_nothing_to_run_at_the_order_is_spent_at_once(self):
        ships = self.squadron()
        self.hold("w")
        for s in ships:
            self.assertEqual(self.field(s, ENT_ORDER), self.IDLE, f"slot {s} is running at nobody")

    def test_the_other_squadron_is_not_sent(self):
        e = self.place_enemy()
        ships = self.squadron()
        other = ships[-1]
        self.poke(other, ENT_SQUAD, bytes([2]))
        self.hold("w")
        self.assertEqual(self.field(other, ENT_ORDER), self.IDLE)

    def test_r_calls_the_run_off(self):
        e = self.place_enemy()
        ships = self.squadron()
        self.hold("w")
        self.assertEqual(self.field(ships[0], ENT_ORDER), self.STRAFE)
        self.hold("r")
        for s in ships:
            self.assertEqual(self.field(s, ENT_ORDER), self.IDLE, f"R did not recall slot {s}")


class TestThePass(StrafeFixture):

    def test_the_ships_close_shoot_and_come_home_by_themselves(self):
        e = self.place_enemy(pos=(0, 0, 5000))
        ships = self.squadron()
        #  TWO ships on the run, not sixteen: a whole squadron's first volley
        #  is 255 hull and the order is spent on the kill, budget and all --
        #  which is right, and is not what this test is about. The rest go to
        #  squadron 3, where they hold station out of range.
        for s in ships[2:]:
            self.poke(s, ENT_SQUAD, bytes([3]))
        ships = ships[:2]
        lead = ships[0]
        #  ...and the Mothership out of it: its turret reaches eighty units and
        #  the hostile is at seventy-eight, so the base would kill it inside the
        #  budget and the order would be spent on the kill.
        self.poke(self.byte("MOTH_SLOT"), 0, struct.pack("<hhh", -20000, 0, -20000))
        dest = struct.unpack("<hhh", self.c.read_ram(self.sym["SQUAD_DEST"], 6))
        home = lambda s: sum(abs(p - q) for p, q in zip(self.pos(s), dest))
        d0 = self.distance(lead, e)
        self.hold("w")
        self.c.run_frames(60)
        self.assertLess(self.distance(lead, e), d0, "the run never closed on the hostile")
        #  The budget only moves in contact, so the flight out costs none of it.
        spent = 0
        for _ in range(120):
            self.c.run_frames(10)
            if self.field(lead, ENT_ORDER) == self.IDLE:
                break
            spent = max(spent, self.BUDGET - self.field(lead, ENT_LOAD))
        else:
            self.fail("the run never ended")
        self.assertLess(self.field(e, ENT_HULL), 255, "the pass hit nothing")
        self.assertEqual(self.field(lead, ENT_LOAD), 0, "the order ended with budget left")
        #  ...and home: nearer its station after the run than at the turn.
        far = home(lead)
        self.c.run_frames(150)
        self.assertLess(home(lead), far, "the ship did not fly home after the run")
        self.assertEqual(self.field(lead, ENT_ORDER), self.IDLE)

    def test_the_budget_does_not_move_on_the_way_out(self):
        """The hostile is far enough that the first frames are all flight."""
        e = self.place_enemy(pos=(0, 0, 9000))
        lead = self.squadron()[0]
        self.hold("w", frames=30, release=10)
        b = self.field(lead, ENT_LOAD)
        self.assertEqual(self.field(lead, ENT_ORDER), self.STRAFE)
        self.assertEqual(b, self.BUDGET, "the budget was spent before contact")


if __name__ == "__main__":
    unittest.main()
