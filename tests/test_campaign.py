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
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walks range(ENT_MAX) then stops looking
#  exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_HULL, ENT_FLAGS, ENT_CLASS = 10, 11, 9
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4
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
        """How many ships are FLYING on each side.

        A wreck is not one, and this is the counter that has to agree with
        mis_count_enemies: slv_make_wreck leaves the hostile that just died
        ACTIVE with DISABLED set, and mis_count_enemies masks that bit out --
        which is exactly what lets a CLEAR mission complete over a battlefield
        with hulls on it. Every enemy death leaves one now; it used to need a
        live Salvage Corvette, which this fixture never builds.
        """
        friendly = enemy = 0
        for slot in range(ENT_MAX):
            f = self.ent(slot, ENT_FLAGS)
            if (f & (F_ACTIVE | F_DISABLED)) != F_ACTIVE:
                continue
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

    def test_a_derelict_mission_has_room_for_the_hull_as_well(self):
        """The derelict IS a third thing to make room for, unlike a wreck.

        slv_make_wreck converts a hostile in place and takes no new slot, which
        is why the twenty above is twelve plus eight. mis_spawn_derelict places
        a WHOLE EXTRA ENTITY in the hostile region on top of the mission's own
        picket. If a mission that fields one ran out of room, the ship that did
        not fit would be the last of a wave -- and it would go missing without
        a word, which is the exact failure the partition exists to end.
        """
        for i in range(self.sym["MIS_DERELICT_FROM"],
                       self.sym["MIS_DERELICT_UNTIL"] + 1):
            count = self.descriptor(i)[12]
            want = count + 1 + self.sym["WAVE_MAX"]
            self.assertLessEqual(
                want, self.sym["ENT_ENEMY_MAX"],
                f"mission {i + 1} fields {count} hostiles and a derelict, so a "
                f"full wave on top of them needs {want} of "
                f"{self.sym['ENT_ENEMY_MAX']} hostile slots")

    def test_the_derelict_stops_where_the_room_stops(self):
        """MIS_DERELICT_UNTIL is mission 6, and this is the arithmetic that
        decides it rather than taste: mission 7's twelve, plus a derelict, plus
        a whole wave is twenty-one against twenty.

        Written as a check on the missions AFTER the range, so it fails if the
        reason ever goes away -- a picket that shrank, or a hostile region that
        grew, would mean the range could be widened and a whole class need not
        be lost to a briefing that was not read.
        """
        after = range(self.sym["MIS_DERELICT_UNTIL"] + 1, MIS_COUNT)
        biggest = max(self.descriptor(i)[12] for i in after)
        self.assertGreater(
            biggest + 1 + self.sym["WAVE_MAX"], self.sym["ENT_ENEMY_MAX"],
            "every mission after the derelict's range now has room for one, so "
            "MIS_DERELICT_UNTIL is short for a reason that no longer holds")


class TestObjectives(CampaignFixture):

    def test_an_arrival_mission_completes_on_its_own(self):
        self.assertEqual(self.descriptor(0)[18], MIS_OBJ_ARRIVE)
        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "mission 1 has nothing to do and did not complete")

    def test_a_clearance_mission_needs_the_enemy_dead(self):
        #  Through jump_mission, which arranges what mis_gate asks for. Two
        #  bare presses of J used to be enough; a mission cannot be walked out
        #  of any more -- see TestTheWayOut for the rule itself.
        h.jump_mission(self.c)                    # into mission 2
        h.jump_mission(self.c)                    # into mission 3, which has enemies
        self.assertEqual(self.mission(), 2)
        self.assertEqual(self.descriptor(2)[18], MIS_OBJ_CLEAR)

        _, enemies = self.fleet()
        self.assertGreater(enemies, 0, "the clearance mission spawned nothing to clear")
        self.assertEqual(self.byte("MIS_COMPLETE"), 0, "complete before a shot was fired")

        self.assertTrue(self.play_until_complete(), "the fleet never cleared the picket")
        self.assertEqual(self.fleet()[1], 0)


class TestTheWayOut(CampaignFixture):
    """mis_gate: what a mission asks before it will let the player leave.

    Three things, and the objective is only the first -- WAVE_BEFORE_JUMP
    waves have to have come and nothing hostile may still be flying. Each test
    below withholds exactly ONE of the three and presses J, which is the only
    way to know that all three are load-bearing: a gate tested by satisfying
    everything at once passes just as happily with two of its clauses deleted.
    """

    def waves_seen(self, n):
        self.c.write_ram(self.sym["WAVE_COUNT"], bytes([n]))

    def pay_the_fare(self, over=True):
        """The treasury the drive is fuelled out of. `over=False` leaves the
        player one unit short, which is the only interesting failing case."""
        cost = self.sym["MIS_JUMP_COST"]
        self.c.write_ram(self.sym["ECO_RU"],
                         struct.pack("<H", cost if over else cost - 1))

    def hostiles(self):
        return [s for s in range(self.sym["ENT_PLAYER_MAX"], ENT_MAX)
                if self.ent(s, ENT_FLAGS) & F_ACTIVE]

    def clear_the_board(self):
        for slot in self.hostiles():
            self.c.write_ram(
                self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

    def to_a_mission_with_a_picket(self):
        """Mission 3, which is the first with anything in it to kill."""
        for _ in range(2):
            h.jump_mission(self.c)
        self.assertEqual(self.mission(), 2)
        self.assertGreater(len(self.hostiles()), 0, "nothing to clear")

    def press_j(self):
        was = self.mission()
        self.hold("j", frames=25)
        self.c.run_frames(20)
        return self.mission() != was

    def test_three_waves_are_not_enough_with_the_picket_alive(self):
        self.to_a_mission_with_a_picket()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        self.c.run_frames(12)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 0)
        self.assertFalse(self.press_j(), "left a mission with the picket flying")

    def test_a_cleared_board_is_not_enough_before_the_third_wave(self):
        self.to_a_mission_with_a_picket()
        self.clear_the_board()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"] - 1)
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "the objective was not met by clearing the board")
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 0)
        self.assertFalse(self.press_j(), "left before the third wave")

    def test_and_with_both_it_goes(self):
        self.to_a_mission_with_a_picket()
        self.pay_the_fare()
        self.clear_the_board()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 1)
        self.assertTrue(self.press_j(), "the way out was closed with both met")

    def test_a_wave_that_lands_afterwards_shuts_it_again(self):
        """THE REASON IT IS NOT LATCHED INTO mis_complete. The objective stays
        met; the way out does not. A flag folded into mis_complete could not
        express this and would offer JUMP over the top of a live wave."""
        self.to_a_mission_with_a_picket()
        self.pay_the_fare()
        self.clear_the_board()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 1)

        h.force_wave(self.c, self.sym)
        self.c.run_frames(60)
        self.assertGreater(len(self.hostiles()), 0, "no wave arrived")
        self.assertEqual(self.byte("MIS_COMPLETE"), 1, "the objective was undone")
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 0,
                         "a wave landed and the jump was still on offer")
        self.assertFalse(self.press_j(), "left with a wave on the screen")

    def test_the_fare_is_the_fourth_thing_it_asks(self):
        """A jump spends MIS_JUMP_COST, so the drive has to be paid for. One
        unit short is the case worth writing: it separates "cannot afford it"
        from "has no money at all", which a treasury of zero would not."""
        self.to_a_mission_with_a_picket()
        self.clear_the_board()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        self.pay_the_fare(over=False)
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 0,
                         "the jump was offered a unit short of the fare")
        self.assertFalse(self.press_j(), "left without paying for the drive")

        self.pay_the_fare()
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 1,
                         "one more unit and it is still closed")

    def test_the_fare_is_actually_taken(self):
        """Charged once, and only when the jump happens."""
        self.to_a_mission_with_a_picket()
        self.clear_the_board()
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        purse = self.sym["MIS_JUMP_COST"] + 250
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", purse))
        self.c.run_frames(24)
        self.assertTrue(self.press_j(), "the way out was closed with the fare paid")
        h.dismiss_briefing(self.c)
        left = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.assertEqual(left, 250, f"the drive cost {purse - left}")

    def test_a_wreck_does_not_hold_the_player_in(self):
        """A crippled hull carries ACTIVE and ENEMY and is going nowhere, and
        the DERELICT is one for the whole of missions 4 to 6 -- counting it
        would make those three impossible to leave. Third time this trap has
        been avoided by one bit in a mask; see mis_count_enemies."""
        self.to_a_mission_with_a_picket()
        self.pay_the_fare()
        self.clear_the_board()
        slot = self.sym["ENT_PLAYER_MAX"]
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | 0x04]))
        self.waves_seen(self.sym["WAVE_BEFORE_JUMP"])
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 1,
                         "a wreck closed the way out")


class TestJump(CampaignFixture):

    def test_j_is_refused_until_the_objective_is_met(self):
        h.jump_mission(self.c)
        h.jump_mission(self.c)                    # now on mission 3
        self.assertEqual(self.mission(), 2)
        self.assertEqual(self.byte("MIS_COMPLETE"), 0)

        #  Everything the gate asks for EXCEPT the objective, so that what
        #  refuses this is the objective and not one of the other two.
        self.c.write_ram(self.sym["WAVE_COUNT"],
                         bytes([self.sym["WAVE_BEFORE_JUMP"]]))
        self.c.run_frames(12)
        self.hold("j", frames=25)
        self.assertEqual(self.mission(), 2, "jumped away from an unfinished mission")

    def test_j_advances_and_lays_out_the_next_mission(self):
        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        h.jump_mission(self.c)
        self.assertEqual(self.mission(), 1)

        #  Jump on to mission 3, which has a picket, and THAT one must start
        #  incomplete -- the check is that mis_setup resets the flag, and an
        #  ARRIVE mission cannot show it because it completes immediately.
        h.jump_mission(self.c)
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
        for slot in range(ENT_MAX):
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
        h.jump_mission(self.c)
        h.jump_mission(self.c)                    # mission 3 has a picket
        self.assertGreater(self.fleet()[1], 0)

        #  Wipe them and jump: the next mission's enemy must be its own.
        for slot in range(ENT_MAX):
            if self.ent(slot, ENT_FLAGS) & F_ENEMY:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames(60)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        #  Mission 4's DERELICT is NOT in this figure, and the reason it used
        #  to be is worth keeping. It carries ENT_F_ENEMY -- which is what
        #  keeps it out of fleet_save and out of the fleet's own hull, see
        #  tests/test_derelict.py -- so a counter that asked only about that
        #  bit found nine where the mission's row says eight. It also carries
        #  DISABLED, and fleet() now counts what is FLYING, which is the same
        #  question mis_count_enemies asks. The picket alone is the answer.
        expected = self.descriptor(3)[12]
        h.jump_mission(self.c)
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
        for slot in range(ENT_MAX):
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
        slot = next(s for s in range(ENT_MAX)
                    if (self.ent(s, ENT_FLAGS) & F_ACTIVE)
                    and not (self.ent(s, ENT_FLAGS) & F_ENEMY))
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_HULL, bytes([77]))

        self.c.run_frames(120)
        self.hold("j", frames=25)

        hulls = [self.ent(s, ENT_HULL) for s in range(ENT_MAX)
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
