"""Phases 8 and 9: the campaign, and the fleet that carries between missions.

"Ο στόλος είναι μόνιμος. Ό,τι επιβιώνει σε μια αποστολή ξεκινά την επόμενη.
Ό,τι χάνεται, χάνεται οριστικά." That sentence is the game, so most of what is
here is about losses surviving a jump rather than about the missions.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

ENT_SIZE = 20
ENT_HULL, ENT_FLAGS, ENT_CLASS = 10, 11, 9
F_ACTIVE, F_ENEMY = 1, 2
MIS_COUNT, MIS_SIZE = 8, 20
MIS_OBJ_CLEAR, MIS_OBJ_SURVIVE, MIS_OBJ_ARRIVE = 0, 1, 2


class CampaignFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading ------------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def mission(self):
        return self.byte("MIS_INDEX")

    def ent(self, slot, offset):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def fleet(self):
        friendly = enemy = 0
        for slot in range(48):
            f = self.ent(slot, ENT_FLAGS)
            if f & F_ACTIVE:
                if f & F_ENEMY:
                    enemy += 1
                else:
                    friendly += 1
        return friendly, enemy

    def descriptor(self, index):
        """A mission row, read out of bank 4 through the CPU's view."""
        base = self.sym["MISSION_TABLE"] + index * MIS_SIZE
        return h.read_bank4(self.c, base, MIS_SIZE)

    # -- playing ------------------------------------------------------------
    def hold(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(12)
        if key == "j":
            #  Every mission opens on a briefing, and nothing runs while it is
            #  up. Clear it, or the rest of the test watches a static screen.
            h.dismiss_briefing(self.c)

    def send_fleet_in(self):
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 5000))

    def play_until_complete(self, max_frames=4000):
        self.send_fleet_in()
        for _ in range(max_frames // 30):
            self.c.run_frames(30)
            if self.byte("MIS_COMPLETE"):
                return True
            if self.byte("MIS_FAILED"):
                return False
        return False


class TestCampaignShape(CampaignFixture):

    def test_it_starts_at_the_first_mission(self):
        self.assertEqual(self.mission(), 0)
        self.assertEqual(self.byte("MIS_FAILED"), 0)
        #  Mission 1 is an ARRIVE mission -- getting there is the objective --
        #  so it is complete from the first frame and the jump is open. That
        #  is what makes it the tutorial: the way out is available while the
        #  player works out the controls.
        self.assertEqual(self.descriptor(0)[18], MIS_OBJ_ARRIVE)

    def test_there_are_eight_missions_and_they_are_all_sane(self):
        seen_names = set()
        for i in range(MIS_COUNT):
            d = self.descriptor(i)
            name = bytes(d[:12]).split(b"\x00")[0]
            self.assertTrue(name, f"mission {i + 1} has no name")
            self.assertNotIn(name, seen_names, f"two missions called {name!r}")
            seen_names.add(name)

            self.assertLessEqual(d[12], 20, f"mission {i + 1} fields {d[12]} enemies")
            self.assertLessEqual(d[15], 4, f"mission {i + 1} wants {d[15]} patches")
            self.assertIn(d[18], (MIS_OBJ_CLEAR, MIS_OBJ_SURVIVE, MIS_OBJ_ARRIVE),
                          f"mission {i + 1} has objective {d[18]}")

    def test_the_early_missions_have_nothing_to_fight(self):
        """Section 10: mission 1 is training and mission 2 is 'only silence'."""
        for i in (0, 1):
            self.assertEqual(self.descriptor(i)[12], 0,
                             f"mission {i + 1} has enemies in it")

    def test_the_enemy_grows_over_the_campaign(self):
        counts = [self.descriptor(i)[12] for i in range(MIS_COUNT)]
        self.assertEqual(counts[:2], [0, 0])
        self.assertGreater(max(counts[5:]), max(counts[2:4]),
                           f"the campaign does not escalate: {counts}")


class TestEveryPicketFits(CampaignFixture):
    """The entity table is partitioned now (game/entity.asm) and hostiles get
    ENT_ENEMY_MAX slots of it. mis_setup places what fits and stops, so a row
    asking for more than that would field fewer enemies than the mission was
    authored around and say nothing whatever about it.

    RASM cannot take the largest of eight rows of data, so the guard is here
    rather than in src/main.asm -- read out of the mission table itself, in
    the machine, so a row edited in campaign.asm is checked by the thing that
    will actually read it.
    """

    def test_no_mission_asks_for_more_hostiles_than_there_is_room_for(self):
        room = self.sym["ENT_ENEMY_MAX"]
        for i in range(MIS_COUNT):
            count = self.descriptor(i)[12]
            self.assertLessEqual(
                count, room,
                f"mission {i + 1} fields {count} hostiles and only {room} fit")

    def test_the_largest_picket_leaves_room_for_a_whole_attack_wave(self):
        """Twenty is twelve plus eight, and that is the arithmetic the number
        was chosen by rather than a coincidence -- so state it. A wreck is not
        a third thing to make room for: slv_make_wreck converts the hostile in
        place and takes no new slot."""
        biggest = max(self.descriptor(i)[12] for i in range(MIS_COUNT))
        self.assertEqual(biggest, 12, "the campaign's largest picket has changed")
        self.assertLessEqual(biggest + self.sym["WAVE_MAX"],
                             self.sym["ENT_ENEMY_MAX"],
                             "a full wave cannot land on the largest picket")


class TestObjectives(CampaignFixture):

    def test_an_arrival_mission_completes_on_its_own(self):
        self.assertEqual(self.descriptor(0)[18], MIS_OBJ_ARRIVE)
        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "mission 1 has nothing to do and did not complete")

    def test_a_clearance_mission_needs_the_enemy_dead(self):
        self.hold("j", frames=25)                 # into mission 2
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # into mission 3, which has enemies
        self.assertEqual(self.mission(), 2)
        self.assertEqual(self.descriptor(2)[18], MIS_OBJ_CLEAR)

        _, enemies = self.fleet()
        self.assertGreater(enemies, 0, "the clearance mission spawned nothing to clear")
        self.assertEqual(self.byte("MIS_COMPLETE"), 0, "complete before a shot was fired")

        self.assertTrue(self.play_until_complete(), "the fleet never cleared the picket")
        self.assertEqual(self.fleet()[1], 0)


class TestJump(CampaignFixture):

    def test_j_is_refused_until_the_objective_is_met(self):
        self.hold("j", frames=25)
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # now on mission 3
        self.assertEqual(self.mission(), 2)
        self.assertEqual(self.byte("MIS_COMPLETE"), 0)

        self.hold("j", frames=25)
        self.assertEqual(self.mission(), 2, "jumped away from an unfinished mission")

    def test_j_advances_and_lays_out_the_next_mission(self):
        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        self.hold("j", frames=25)
        self.assertEqual(self.mission(), 1)

        #  Jump on to mission 3, which has a picket, and THAT one must start
        #  incomplete -- the check is that mis_setup resets the flag, and an
        #  ARRIVE mission cannot show it because it completes immediately.
        self.c.run_frames(120)
        self.hold("j", frames=25)
        self.assertEqual(self.mission(), 2)
        self.assertEqual(self.byte("MIS_COMPLETE"), 0, "the new mission started complete")

    def test_the_campaign_ends_rather_than_wrapping(self):
        self.c.write_ram(self.sym["MIS_INDEX"], bytes([MIS_COUNT - 1]))
        self.c.write_ram(self.sym["MIS_COMPLETE"], b"\x01")
        self.hold("j", frames=25)
        self.assertEqual(self.mission(), MIS_COUNT - 1,
                         "jumped past the last mission")


class TestFleetPersistence(CampaignFixture):
    """The mechanic the whole design rests on."""

    def test_the_fleet_carries_across_a_jump(self):
        before, _ = self.fleet()
        self.assertGreater(before, 5)
        self.c.run_frames(120)
        self.hold("j", frames=25)
        after, _ = self.fleet()
        self.assertEqual(after, before, "the fleet changed size crossing a jump")

    def test_losses_are_permanent(self):
        """'Ό,τι χάνεται, χάνεται οριστικά.'"""
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # mission 2
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # mission 3, with a picket

        before, _ = self.fleet()
        #  Take two ships out by hand rather than waiting on the battle.
        killed = 0
        for slot in range(48):
            f = self.ent(slot, ENT_FLAGS)
            if (f & F_ACTIVE) and not (f & F_ENEMY) and self.ent(slot, ENT_CLASS) == 0:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
                killed += 1
                if killed == 2:
                    break
        self.assertEqual(killed, 2)

        self.assertTrue(self.play_until_complete())
        self.hold("j", frames=25)
        after, _ = self.fleet()
        self.assertEqual(after, before - 2,
                         "losses did not survive the jump -- the fleet healed")

    def test_the_enemy_does_not_come_with_you(self):
        self.c.run_frames(120)
        self.hold("j", frames=25)
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # mission 3 has a picket
        self.assertGreater(self.fleet()[1], 0)

        #  Wipe them and jump: the next mission's enemy must be its own.
        for slot in range(48):
            if self.ent(slot, ENT_FLAGS) & F_ENEMY:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames(60)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        expected = self.descriptor(3)[12]
        self.hold("j", frames=25)
        self.assertEqual(self.fleet()[1], expected,
                         "the wrong number of enemies crossed into mission 4")

    def test_moth_slot_follows_the_mothership_when_the_fleet_packs_down(self):
        """fleet_restore closes the gaps left by the dead, so the Mothership
        moves. moth_slot has to move with it.

        It did not, and the consequence was not a cosmetic one. With two
        interceptors lost the fleet reloads into slots 0..13 and the
        Mothership comes home to 13, but moth_slot still said 15 -- which
        mis_setup had just filled with an enemy. The defeat check then watched
        an enemy interceptor, and the moment the fleet shot it down the
        campaign ended with "the Mothership was lost".
        """
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # mission 2
        self.c.run_frames(120)
        self.hold("j", frames=25)                 # mission 3, with a picket

        killed = 0
        for slot in range(48):
            f = self.ent(slot, ENT_FLAGS)
            if (f & F_ACTIVE) and not (f & F_ENEMY) and self.ent(slot, ENT_CLASS) == 0:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
                killed += 1
                if killed == 2:
                    break
        self.assertEqual(killed, 2)

        self.assertTrue(self.play_until_complete())
        self.hold("j", frames=25)                 # mission 4 lays out its own enemies

        slot = self.byte("MOTH_SLOT")
        flags = self.ent(slot, ENT_FLAGS)
        self.assertTrue(flags & F_ACTIVE, "moth_slot points at an empty slot")
        self.assertFalse(flags & F_ENEMY, "moth_slot points at an ENEMY ship")
        self.assertEqual(self.ent(slot, ENT_CLASS), 1,
                         "moth_slot does not point at a Mothership")
        self.assertEqual(self.byte("MIS_FAILED"), 0)

    def test_the_saved_fleet_holds_the_hull_of_every_ship(self):
        """A damaged ship must arrive damaged, not repaired."""
        slot = next(s for s in range(48)
                    if (self.ent(s, ENT_FLAGS) & F_ACTIVE)
                    and not (self.ent(s, ENT_FLAGS) & F_ENEMY))
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_HULL, bytes([77]))

        self.c.run_frames(120)
        self.hold("j", frames=25)

        hulls = [self.ent(s, ENT_HULL) for s in range(48)
                 if (self.ent(s, ENT_FLAGS) & F_ACTIVE)
                 and not (self.ent(s, ENT_FLAGS) & F_ENEMY)]
        self.assertIn(77, hulls, "the damaged ship came out of the jump repaired")


class TestDefeat(CampaignFixture):

    def test_losing_the_mothership_ends_it(self):
        """Section 8: 'Αν χαθεί -> τέλος παιχνιδιού.' The colony is aboard."""
        slot = self.byte("MOTH_SLOT")
        self.assertEqual(self.byte("MIS_FAILED"), 0)
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames(60)
        self.assertEqual(self.byte("MIS_FAILED"), 1, "the Mothership died and nothing happened")


if __name__ == "__main__":
    unittest.main()
