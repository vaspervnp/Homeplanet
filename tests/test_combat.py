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
from tools import gentables as g

#  Mirrored from src/game/entity.asm and src/game/combat.asm
ENT_SIZE = 20
ENT_X, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_TARGET, ENT_TIMER = 0, 10, 11, 12, 14, 19
ENT_CLASS, ENT_ORDER = 9, 13
ENT_ORDER_NONE, ENT_ORDER_ATTACK = 0, 2
F_ACTIVE, F_ENEMY = 1, 2
#  Mirrored from src/game/combat.asm.
CBT_RANGE = 40
CBT_COOLDOWN = 6
#  The game runs at 12.5fps on a 50Hz machine.
TICKS_PER_GAME_FRAME = 4
EXPL_MAX, EXPL_SIZE, EXPL_TIMER = 6, 7, 6
CBT_DAMAGE = 24


class CombatFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)
        self.to_combat_mission()

    def to_combat_mission(self):
        """Jump forward to the first mission that has an enemy in it.

        The campaign opens on training and then on a mission the design
        describes as "καμία μάχη· μόνο περισυλλογή επιζώντων και σιωπή".
        Both are ARRIVE missions and complete immediately, so two jumps get
        here; there is nothing to shoot at before that.
        """
        for _ in range(2):
            h.jump_mission(self.c)
        self.assertGreater(self.counts()[1], 0, "no enemies after jumping to mission 3")

    def tearDown(self):
        #  Free it now; see harness.close.
        h.close(getattr(self, "c", None))

    # -- reading the fleet --------------------------------------------------
    def ent(self, slot, offset, size=1):
        addr = self.sym["ENTITIES"] + slot * ENT_SIZE + offset
        return self.c.read_ram(addr, size)

    def flags(self, slot):
        return self.ent(slot, ENT_FLAGS)[0]

    def position(self, slot):
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        return [int.from_bytes(self.c.read_ram(base + i * 2, 2), "little", signed=True)
                for i in range(3)]

    def closest_pair(self):
        """The nearest friendly/enemy pair, in the units cbt_distance uses.

        Manhattan on coordinates shifted down by WORLD_SHIFT -- the same
        saturating measure the Z80 uses, so the number is comparable with
        CBT_RANGE. The shift has to track WORLD_SHIFT: the world is authored
        four times smaller than it was, and against the old >>8 every ship
        would look four times closer than the game thinks it is.
        """
        friendly = [s for s in range(48) if (self.flags(s) & 3) == F_ACTIVE]
        enemy = [s for s in range(48) if (self.flags(s) & 3) == F_ACTIVE | F_ENEMY]
        if not friendly or not enemy:
            return 255
        return min(min(255, sum(abs(a - b) >> g.WORLD_SHIFT
                                for a, b in zip(self.position(f), self.position(e))))
                   for f in friendly for e in enemy)

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
        """How many enemies is the mission's business; that there ARE some is ours."""
        friendly, enemy = self.counts()
        self.assertGreater(friendly, 10, "the player has no fleet")
        self.assertGreater(enemy, 0, "there is nobody to fight")

    def test_nobody_fires_until_someone_has_closed(self):
        """They start out of range, and the Vekhar have to come and get them.

        This used to be "no shots in the first 30 frames", which passed for
        the wrong reason: nothing had a target yet, because retargeting was
        round-robin at one ship a frame and took ENT_MAX frames to reach
        anybody. Once ships re-acquired promptly the picket started closing
        immediately and the battle opened inside those 30 frames -- correctly.
        The invariant worth holding is not a delay, it is that a shot implies
        contact: nobody can fire from where they spawn.
        """
        self.assertEqual(self.shots(), 0, "shots were fired at spawn")
        self.assertEqual(self.kills(), 0)
        self.assertGreater(self.closest_pair(), CBT_RANGE,
                           "the mission spawns the two fleets already in range")

        shots = 0
        for _ in range(90):
            self.c.run_frames(1)
            if self.shots() != shots:
                shots = self.shots()
                self.assertLessEqual(self.closest_pair(), CBT_RANGE,
                                     "a shot was fired with nobody in range")

    def test_nothing_is_ever_aimed_at_its_own_side(self):
        """A zeroed ENT_TARGET names slot 0, not 'nobody'.

        That is the field that made every fresh ship come up aimed at whatever
        was in the first slot. Checking for #FF stopped working once targeting
        stopped being range-limited -- ships now acquire at any distance, so
        by the time a test looks they all have one. The invariant that
        actually matters was always this one.
        """
        for slot in range(48):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            target = self.ent(slot, ENT_TARGET)[0]
            if target == 0xFF:
                continue
            self.assertLess(target, 48, f"slot {slot} targets nonexistent {target}")
            mine = self.flags(slot) & F_ENEMY
            theirs = self.flags(target) & F_ENEMY
            self.assertNotEqual(mine, theirs,
                                f"slot {slot} is aimed at slot {target} on its own side")


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
        self.order_fleet_to(0, 0, 5500)
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

        Stand the picket somewhere it can actually be seen first. Left where
        it starts it flies straight at the fleet and parks BEHIND it, and the
        painter's algorithm then correctly hides every enemy pixel behind
        sixteen friendly ships -- a blank screen that says nothing about the
        colour of a sprite. Nor is moving it sideways enough on its own: at
        the picket's own depth of z=5000 even a 1750-unit shift is four
        pixels on screen, so it has to come forward as well as across.
        """
        #  Do NOT send the fleet in: it would clear the picket and there
        #  would be nothing left to be the wrong colour. Just stand it above
        #  and beside the fleet, spread out, and look at it.
        placed = 0
        for slot in range(48):
            if self.flags(slot) & F_ENEMY:
                self.c.write_ram(
                    self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_X,
                    struct.pack("<hhh", -1250 + placed * 850, 1000, 750))
                placed += 1
        self.assertGreater(placed, 0, "the mission fielded no enemies to colour")
        self.c.run_frames(40)

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


class TestConcentration(CombatFixture):
    """A fleet has to be able to bring its guns to bear.

    Both tests here started as one symptom: eight friendly interceptors
    against eight enemy ones, identical hulls and identical guns, ended 8-0
    to the enemy every single time.
    """

    def even_duel(self, order):
        """Eight against eight, same class, same hull, at point-blank.

        Returns (friendly survivors, enemy survivors). Everything is wiped
        first so the mission's own ships cannot join in.
        """
        base = self.sym["ENTITIES"]
        for slot in range(48):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        def place(slot, enemy, x):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", x, 0, 0))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))          # interceptor
            self.c.write_ram(addr + ENT_HULL, bytes([255]))
            self.c.write_ram(addr + ENT_FLAGS,
                             bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER,
                             bytes([ENT_ORDER_NONE if enemy else order]))
            self.c.write_ram(addr + ENT_TARGET, bytes([255]))

        for i in range(8):
            place(i, False, -1000 + i * 200)
            place(8 + i, True, 1000 + i * 200)

        #  Station the squadron where it stands, and keep the defeat check off
        #  a slot that is now an interceptor.
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))

        self.c.run_frames(2500)
        alive = lambda lo, hi: sum(1 for s in range(lo, hi)
                                   if self.flags(s) & F_ACTIVE)
        return alive(0, 8), alive(8, 16)

    def test_an_attack_order_closes_the_ship_on_its_target(self):
        """`A` used to set a target and nothing else.

        Section 9 lists `A` as "Επίθεση". The ship aimed from wherever its
        formation slot happened to be while the Vekhar -- who always close --
        massed on it, so the order the player reaches for in a fight was the
        one that did the least.
        """
        friendly, enemy = self.even_duel(ENT_ORDER_ATTACK)
        self.assertEqual(enemy, 0, "an attacking squadron failed to finish an even fight")
        self.assertGreater(friendly, 0, "the attackers were wiped out winning it")

    def test_a_ship_re_acquires_the_frame_its_target_dies(self):
        """Otherwise concentrating fire is punished instead of rewarded.

        Ships close together all pick the same nearest enemy, so one kill
        left the whole squadron holding a dead target. Retargeting was
        round-robin at one ship a frame, so they stood idle for up to ENT_MAX
        frames -- while a strung-out enemy, each ship aiming at a different
        target, only ever lost the few that had been aiming at the casualty.
        """
        base = self.sym["ENTITIES"]
        for slot in range(48):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        #  One shooter, two enemies stacked on it. Kill the one it is aiming
        #  at and it must pick the other up at once, not in forty frames.
        for slot, (enemy, hull) in enumerate([(False, 255), (True, 255), (True, 255)]):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", slot * 200, 0, 0))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))
            self.c.write_ram(addr + ENT_HULL, bytes([hull]))
            self.c.write_ram(addr + ENT_FLAGS,
                             bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER, bytes([ENT_ORDER_NONE]))
            self.c.write_ram(addr + ENT_TARGET, bytes([255]))
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))

        self.c.run_frames(60)
        aimed = self.ent(0, ENT_TARGET)[0]
        self.assertIn(aimed, (1, 2), "the shooter never acquired anything")

        #  Take that target away. Re-acquisition happens when the ship is next
        #  ready to shoot, so allow the weapon to come off cooldown. The game
        #  ticks at 12.5fps on a 50Hz machine, so a game frame is FOUR of the
        #  emulator frames run_frames counts -- the cooldown is 24 of them,
        #  and the round-robin sweep this replaces is 192.
        self.c.write_ram(base + aimed * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames((CBT_COOLDOWN + 4) * TICKS_PER_GAME_FRAME)

        other = 2 if aimed == 1 else 1
        self.assertEqual(self.ent(0, ENT_TARGET)[0], other,
                         "the shooter sat idle instead of switching to the survivor")


class TestRange(CombatFixture):

    def test_ships_only_fire_once_they_are_close(self):
        self.assertEqual(self.shots(), 0)

        #  Drop the whole fleet on top of the picket rather than flying it
        #  there, so the only variable is distance. The station has to move
        #  with them, or phase4_fly pulls them straight back out of range.
        self.order_fleet_to(0, 0, 5500)
        for slot in range(48):
            if (self.flags(slot) & F_ACTIVE) and not (self.flags(slot) & F_ENEMY):
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_X,
                                 struct.pack("<hhh", 0, 0, 5500))
        #  Retargeting is round-robin, one entity a frame, so give it time to
        #  come round to the ships that are now in contact.
        self.c.run_frames(300)
        self.assertGreater(self.shots(), 0, "point blank and still not firing")


if __name__ == "__main__":
    unittest.main()
