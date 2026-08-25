"""Phase 6: firing, damage, death and explosions.

Homeplanet.md phase 6's criterion is "πρώτη πραγματική σύγκρουση στόλων" -- so
the last test here drives an actual battle and insists it resolves. The ones
before it pin the pieces, and in particular pin the bug that made the fleet
open fire on itself.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

#  Mirrored from src/game/entity.asm and src/game/combat.asm
ENT_SIZE = 20
ENT_X, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_TARGET, ENT_TIMER = 0, 10, 11, 12, 14, 19
F_ACTIVE, F_ENEMY = 1, 2
EXPL_MAX, EXPL_SIZE, EXPL_TIMER = 6, 7, 6
CBT_DAMAGE = 24


class CombatFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)

    def tearDown(self):
        #  Free it now; see harness.close.
        h.close(getattr(self, "c", None))

    # -- reading the fleet --------------------------------------------------
    def ent(self, slot, offset, size=1):
        addr = self.sym["ENTITIES"] + slot * ENT_SIZE + offset
        return self.c.read_ram(addr, size)

    def flags(self, slot):
        return self.ent(slot, ENT_FLAGS)[0]

    def hull(self, slot):
        return self.ent(slot, ENT_HULL)[0]

    def counts(self):
        friendly = enemy = 0
        for slot in range(48):
            f = self.flags(slot)
            if f & F_ACTIVE:
                if f & F_ENEMY:
                    enemy += 1
                else:
                    friendly += 1
        return friendly, enemy

    def shots(self):
        return self.c.read_ram(self.sym["CBT_SHOTS"], 1)[0]

    def kills(self):
        return self.c.read_ram(self.sym["CBT_KILLS"], 1)[0]

    def live_explosions(self):
        base = self.sym["CBT_EXPLOSIONS"]
        return sum(1 for i in range(EXPL_MAX)
                   if self.c.read_ram(base + i * EXPL_SIZE + EXPL_TIMER, 1)[0])

    # -- staging ------------------------------------------------------------
    def order_fleet_to(self, x, y, z):
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", x, y, z))

    def kill_all_enemies(self):
        for slot in range(48):
            if self.flags(slot) & F_ENEMY:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")


class TestStartingState(CombatFixture):

    def test_both_fleets_are_present(self):
        friendly, enemy = self.counts()
        self.assertGreater(friendly, 10, "the player has no fleet")
        self.assertGreater(enemy, 5, "there is nobody to fight")

    def test_nobody_has_fired_before_the_fleets_meet(self):
        """They start well out of range of each other."""
        self.assertEqual(self.shots(), 0, "shots were fired at spawn")
        self.assertEqual(self.kills(), 0)
        self.c.run_frames(200)
        self.assertEqual(self.shots(), 0, "shots were fired while still out of range")

    def test_nothing_starts_out_targeting_slot_zero(self):
        """A zeroed ENT_TARGET names slot 0, not 'nobody'.

        This is the field that made every fresh ship come up aimed at whatever
        was in the first slot.
        """
        for slot in range(48):
            if self.flags(slot) & F_ACTIVE:
                self.assertEqual(self.ent(slot, ENT_TARGET)[0], 0xFF,
                                 f"slot {slot} spawned already targeting {self.ent(slot, ENT_TARGET)[0]}")


class TestNoFriendlyFire(CombatFixture):
    """The regression that matters most: the fleet shooting itself."""

    def test_with_no_enemies_alive_nothing_is_ever_fired(self):
        self.kill_all_enemies()
        self.c.write_ram(self.sym["CBT_SHOTS"], b"\x00")
        self.c.write_ram(self.sym["CBT_KILLS"], b"\x00")

        friendly_before, _ = self.counts()
        self.c.run_frames(400)

        self.assertEqual(self.shots(), 0,
                         "shots were fired with no enemy left to shoot at")
        friendly_after, _ = self.counts()
        self.assertEqual(friendly_after, friendly_before,
                         "the fleet lost ships with nobody fighting it")

    def test_a_target_on_your_own_side_is_refused(self):
        """Point a ship at its neighbour by hand and it must still hold fire.

        Checked at the moment of firing, not only when a target is picked: a
        slot index is just a number, and stale or recycled ones name something.
        """
        self.kill_all_enemies()
        self.c.write_ram(self.sym["CBT_SHOTS"], b"\x00")

        #  Slot 0 aims at slot 1, which is in the same formation and so well
        #  inside weapons range.
        self.c.write_ram(self.sym["ENTITIES"] + 0 * ENT_SIZE + ENT_TARGET, b"\x01")
        self.c.write_ram(self.sym["ENTITIES"] + 0 * ENT_SIZE + ENT_TIMER, b"\x00")
        hull_before = self.hull(1)

        self.c.run_frames(120)

        self.assertEqual(self.hull(1), hull_before, "a ship shot its own wingman")
        self.assertEqual(self.shots(), 0)


class TestBattle(CombatFixture):
    """Phase 6's acceptance criterion, driven end to end."""

    def _fight(self, max_frames=1600, until_kills=3):
        self.order_fleet_to(0, 0, 22000)
        for _ in range(max_frames // 40):
            self.c.run_frames(40)
            if self.kills() >= until_kills:
                return True
        return False

    def test_the_fleets_engage_and_ships_die(self):
        self.assertTrue(self._fight(), f"no engagement: {self.shots()} shots, {self.kills()} kills")
        friendly, enemy = self.counts()
        self.assertLess(enemy, 10, "the enemy picket is untouched")
        self.assertGreater(self.shots(), 20)

    def test_a_kill_frees_the_slot_and_updates_the_squadron_counts(self):
        self._fight()
        for slot in range(48):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            self.assertGreater(self.hull(slot), 0, f"slot {slot} is active with no hull")

        #  squad_count is derived, so it has to agree with the table.
        counted = [0] * 10
        for slot in range(48):
            if self.flags(slot) & F_ACTIVE:
                squadron = self.ent(slot, ENT_SQUAD)[0]
                if 1 <= squadron <= 9:
                    counted[squadron] += 1
        live = list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))
        self.assertEqual(live[1:], counted[1:],
                         "the HUD counts drifted from the entity table after a kill")

    def test_deaths_leave_explosions_that_expire(self):
        self.assertTrue(self._fight(until_kills=1))
        seen = 0
        for _ in range(30):
            self.c.run_frames(8)
            seen = max(seen, self.live_explosions())
        self.assertGreater(seen, 0, "nothing exploded")

        #  Stop the fighting and they must all burn out.
        self.kill_all_enemies()
        self.c.run_frames(200)
        self.assertEqual(self.live_explosions(), 0, "an explosion never expired")

    def test_nobody_ends_up_targeting_a_dead_ship(self):
        self._fight()
        for slot in range(48):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            target = self.ent(slot, ENT_TARGET)[0]
            if target == 0xFF:
                continue
            self.assertLess(target, 48)
            self.assertTrue(self.flags(target) & F_ACTIVE,
                            f"slot {slot} is still aiming at dead slot {target}")

    def test_enemies_draw_in_the_enemy_colour(self):
        """Section 2: enemy ships are ink 3, and it costs no extra sprite data.

        Pen 3 is both bit planes set, so an enemy ship puts bits in the LOW
        nibble of a screen byte, which nothing friendly ever does -- friendly
        ships are pens 1 and 2 and the HUD is pen 1.
        """
        self.order_fleet_to(0, 0, 22000)
        self.c.run_frames(900)              # let them actually make contact

        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        pen3 = 0
        for y in range(168):
            for x in range(80):
                byte = ram[h.screen_offset(y, x)]
                #  A pixel is pen 3 when both its planes are set.
                for shift in range(4):
                    if (byte >> (7 - shift)) & 1 and (byte >> (3 - shift)) & 1:
                        pen3 += 1
        self.assertGreater(pen3, 8, "no enemy-coloured pixels anywhere on screen")


class TestRange(CombatFixture):

    def test_ships_only_fire_once_they_are_close(self):
        self.assertEqual(self.shots(), 0)

        #  Drop the whole fleet on top of the picket rather than flying it
        #  there, so the only variable is distance. The station has to move
        #  with them, or phase4_fly pulls them straight back out of range.
        self.order_fleet_to(0, 0, 22000)
        for slot in range(48):
            if (self.flags(slot) & F_ACTIVE) and not (self.flags(slot) & F_ENEMY):
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_X,
                                 struct.pack("<hhh", 0, 0, 22000))
        #  Retargeting is round-robin, one entity a frame, so give it time to
        #  come round to the ships that are now in contact.
        self.c.run_frames(300)
        self.assertGreater(self.shots(), 0, "point blank and still not firing")


if __name__ == "__main__":
    unittest.main()
