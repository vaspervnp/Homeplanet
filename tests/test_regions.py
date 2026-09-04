"""The entity table is two regions, and which one a spawn lands in.

ENT_MAX was one pool of forty-eight for everything -- the fleet, the
Mothership, the mission's picket, every wave ship, every wreck -- and
ent_find_free handed out the first free slot from zero. So a player who built
hard filled the low slots and wave_send stopped finding anywhere to put a
wave. THE WAVES SILENTLY STOPPED, and the mechanism that makes `J` a decision
rather than a formality switched itself off for the player who had done best.
Nothing reported it.

WHAT THESE TESTS HAVE TO DO, GIVEN THIS PROJECT'S BLIND SPOT
-----------------------------------------------------------
"There are still forty-eight slots" and "a wave spawned" are both assertions
that survive the partition being wrong -- the first is true of any build and
the second is true of a build that allocates from zero, as long as the fleet
happens to be small on the day the test runs. Every test here therefore
follows entities BY SLOT and says which REGION each one landed in.

The discriminating pair, and it is worth knowing which is which:

  * test_a_wave_arrives_with_the_fleet_at_its_ceiling states the invariant.
    It would pass against the old build too, because the old build's fleet was
    allowed to keep growing past twenty-eight -- so on its own it proves the
    right thing about the wrong fleet.
  * TestTheFleetStopsAtItsOwnCeiling is what closes that. It is the test the
    old build FAILS: it lets the yard build until the game refuses, and asks
    where the ships went. Against a pool allocated from zero they walk into
    the slots a wave needs.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD = 9, 10, 11, 12
ENT_ORDER, ENT_TARGET = 13, 14
F_ACTIVE, F_ENEMY, F_WAVE = 1, 2, 8
ENT_NO_TARGET = 0xFF
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP = 0, 1

MIS_SIZE = 20
MIS_ENEMY_COUNT = 12                    # the byte in a mission_table row

#  Long enough for key_scan to see the release: every command is edge
#  triggered and the game scans once per GAME frame, ten 50 Hz frames at the
#  rate this really runs at.
HOLD, RELEASE = 30, 30


class RegionFixture(unittest.TestCase):
    """One machine per test. Every one of these fills the fleet up or lets a
    wave in, and either would be the next test's starting state."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.ENT_MAX = cls.sym["ENT_MAX"]
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.ENEMY_MAX = cls.sym["ENT_ENEMY_MAX"]
        cls.WAVE_MAX = cls.sym["WAVE_MAX"]

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.pin_rng(self.c, 0x1234)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading the table --------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def word(self, name):
        return int.from_bytes(self.c.read_ram(self.sym[name], 2), "little")

    def ent(self, slot, offset):
        return self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def poke_ent(self, slot, offset, value):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset,
                         bytes([value]))

    def slots(self, predicate):
        return [s for s in range(self.ENT_MAX)
                if predicate(self.ent(s, ENT_FLAGS))]

    def friendly(self):
        return self.slots(lambda f: f & F_ACTIVE and not f & F_ENEMY)

    def hostile(self):
        return self.slots(lambda f: f & F_ACTIVE and f & F_ENEMY)

    def riders(self):
        return self.slots(
            lambda f: f & F_ACTIVE and f & F_ENEMY and f & F_WAVE)

    def picket(self):
        return self.slots(
            lambda f: f & F_ACTIVE and f & F_ENEMY and not f & F_WAVE)

    # -- putting the machine in a state -------------------------------------
    def fill_the_fleet(self, upto=None):
        """Make every free slot of the PLAYER region hold an interceptor.

        Poked rather than built, because "what happens when the fleet is at
        its ceiling" is a question about the ceiling and not about the yard --
        TestTheFleetStopsAtItsOwnCeiling is the one that gets there by
        playing. Everything a live ship needs is written, ENT_TARGET
        included: a zeroed one names slot 0, which is now permanently a
        friendly, and a table full of ships aimed at one of their own is not
        the state under test.
        """
        if upto is None:
            upto = self.PLAYER_MAX
        made = []
        for slot in range(upto):
            if self.ent(slot, ENT_FLAGS) & F_ACTIVE:
                continue
            base = self.sym["ENTITIES"] + slot * ENT_SIZE
            self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
            self.poke_ent(slot, ENT_CLASS, CLASS_INTERCEPTOR)
            self.poke_ent(slot, ENT_HULL, 255)
            self.poke_ent(slot, ENT_SQUAD, 1)
            self.poke_ent(slot, ENT_ORDER, 0)
            self.poke_ent(slot, ENT_TARGET, ENT_NO_TARGET)
            self.poke_ent(slot, ENT_FLAGS, F_ACTIVE)
            made.append(slot)
        self.c.run_frames(20)
        return made

    def hold(self, key, frames=HOLD, release=RELEASE):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def force_wave(self, frames=60):
        h.force_wave(self.c, self.sym)
        self.c.run_frames(frames)

    def settle_after_a_jump(self):
        """Wait the jump's REVEAL out before sending another command.

        h.dismiss_briefing polls jfx_mode, and mis_brief_key clears the
        briefing a frame BEFORE the sweep starts -- so the poll can see zero
        and return with the reveal about to begin. The reveal stops the world
        for 857 emulator frames, and a J pressed into it is simply lost. That
        is what made a walk through the campaign advance on alternate
        missions only, which looks exactly like a jump being refused.
        """
        self.c.run_frames(60)
        h.wait_for_jump_wipe(self.c)
        self.c.run_frames(30)

    def jump_once(self):
        """Clear the objective the crude way and press J."""
        #  All three of mis_gate's conditions; see test_campaign.TestTheWayOut.
        h.clear_the_way_out(self.c)
        was = self.byte("MIS_INDEX")
        self.hold("j", frames=40, release=40)
        h.dismiss_briefing(self.c)
        self.settle_after_a_jump()
        self.assertEqual(self.byte("MIS_INDEX"), was + 1,
                         "the jump was refused, so nothing after this means anything")

    def jump_to(self, index):
        """Walk forward to mission `index`, counting from zero."""
        while self.byte("MIS_INDEX") < index:
            self.jump_once()

    # -- assertions about regions -------------------------------------------
    def assert_sides_stay_home(self, why=""):
        theirs = [s for s in self.friendly() if s >= self.PLAYER_MAX]
        ours = [s for s in self.hostile() if s < self.PLAYER_MAX]
        self.assertEqual(theirs, [],
                         f"friendly ships in the hostile region {theirs} {why}")
        self.assertEqual(ours, [],
                         f"hostiles in the fleet's region {ours} {why}")


class TestAWaveArrivesWithTheFleetAtItsCeiling(RegionFixture):
    """The whole point of the change, in one test.

    Fill every slot the fleet is allowed to have, run the clock past the first
    wave, and ask whether the Vekhar turned up. Before the partition the
    answer was eventually no, and nothing anywhere said so.
    """

    def test_a_full_fleet_does_not_stop_the_waves(self):
        made = self.fill_the_fleet()
        self.assertTrue(made, "the fleet was already at its ceiling: no test")
        self.assertEqual(len(self.friendly()), self.PLAYER_MAX,
                         "the player's region is not full, so this proves nothing")

        self.assertEqual(self.riders(), [], "a wave had already landed")
        self.force_wave()

        riders = self.riders()
        self.assertTrue(riders, "no wave arrived with the fleet at its ceiling")
        self.assertTrue(all(s >= self.PLAYER_MAX for s in riders),
                        f"a wave ship landed in the fleet's region: {riders}")
        self.assert_sides_stay_home("after a wave")

    def test_the_whole_wave_fits_and_not_just_the_first_of_it(self):
        """wave_send counts wave_left down as it places ships and gives up
        when it cannot find a slot, so wave_left back at zero is the wave
        arriving WHOLE. A wave truncated to one ship is the same silent
        failure wearing a different number."""
        self.fill_the_fleet()
        self.force_wave()

        self.assertGreater(self.byte("WAVE_SIZE"), 1,
                           "a wave of one proves nothing about room")
        self.assertEqual(self.byte("WAVE_LEFT"), 0,
                         "wave_send ran out of slots part way through the wave")
        self.assertEqual(len(self.riders()), self.byte("WAVE_SIZE"))

    def test_a_full_fleet_and_a_full_picket_still_leaves_room_for_a_wave(self):
        """Mission 7 fields the campaign's largest picket, twelve, and that
        is the case the twenty was sized for: twelve hostiles with a whole
        WAVE_MAX wave able to land on top of them."""
        self.jump_to(6)
        self.assertEqual(len(self.picket()), 12,
                         "mission 7 did not field its twelve, so this proves nothing")
        self.fill_the_fleet()
        self.force_wave()

        riders = self.riders()
        self.assertTrue(riders, "no wave arrived on top of the largest picket")
        self.assertEqual(self.byte("WAVE_LEFT"), 0,
                         "the picket left no room for the whole wave")
        self.assert_sides_stay_home("with the largest picket up")


class TestTheFleetStopsAtItsOwnCeiling(RegionFixture):
    """The other half, and the one the old build fails.

    A pool allocated from zero lets the fleet walk into the slots a wave
    needs; a partitioned one does not, and the game has to SAY so rather than
    taking RU for a ship that will never appear.
    """

    def open_panel(self):
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")

    def order(self):
        """One ENTER at the build panel. Returns True if the RU moved."""
        before = self.word("ECO_RU")
        self.hold(cpc.KEY_ENTER, frames=25)
        return self.word("ECO_RU") != before

    def test_ships_are_built_into_the_fleets_region_and_never_past_it(self):
        """Follow them by slot. Two free slots, five orders: two are taken,
        three are refused, and both ships appear inside the fleet's own
        region with the hostile one untouched."""
        self.fill_the_fleet(upto=self.PLAYER_MAX - 2)
        self.assertEqual(len(self.friendly()), self.PLAYER_MAX - 2)
        before = set(self.friendly())

        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.open_panel()

        taken = 0
        for _ in range(5):
            if self.order():
                taken += 1
            #  Five presses take longer than a Scout takes to build, and a
            #  launch part way through would free the room the refusal under
            #  test depends on.
            self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([255]))
        self.assertEqual(taken, 2,
                         "the yard took a number of orders the fleet has no room for")

        #  Let both of them off the slipway.
        self.hold(cpc.KEY_ESC)
        for _ in range(2):
            self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([0]))
            self.c.run_frames(60)

        new = set(self.friendly()) - before
        self.assertEqual(len(new), 2, f"two ships were ordered, {len(new)} appeared")
        self.assertTrue(all(s < self.PLAYER_MAX for s in new),
                        f"a built ship landed in the hostile region: {sorted(new)}")
        self.assertEqual(len(self.friendly()), self.PLAYER_MAX)
        self.assert_sides_stay_home("after building to the ceiling")

    def test_the_yard_refuses_rather_than_charging_for_a_ship_with_nowhere_to_go(self):
        """eco_queue used to fail to find a slot with nothing said, minutes
        after the money had gone. The refusal is at ORDER time now, which is
        where the RU is taken."""
        self.fill_the_fleet()
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.open_panel()

        before = self.word("ECO_RU")
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.word("ECO_RU"), before,
                         "the yard charged for a ship the fleet has no room for")
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "an order went on the slipway with nowhere for it to go")
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 0)

    def test_room_freed_by_a_loss_can_be_ordered_again(self):
        """A ceiling that never lifts would be a different bug. The count is
        derived from the table every time it is asked, like squad_count."""
        self.fill_the_fleet()
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.open_panel()
        self.assertFalse(self.order(), "the full fleet took an order")

        dead = max(s for s in self.friendly()
                   if self.ent(s, ENT_CLASS) != CLASS_MOTHERSHIP)
        self.poke_ent(dead, ENT_FLAGS, 0)
        self.c.run_frames(30)

        self.assertTrue(self.order(), "a slot came free and the yard still refused")


class TestTheMissionsPicketAlwaysFits(RegionFixture):
    """mis_setup places what fits and stops, so a picket that did not fit
    would be a mission quietly fielding fewer enemies than it was authored
    around. mis_clear_enemies frees the whole hostile region first, so the
    only way that happens is a row asking for more than ENT_ENEMY_MAX --
    which tests/test_campaign.TestEveryPicketFits reads out of the table.
    Here is the same thing played rather than read."""

    def test_every_picket_lands_in_the_hostile_region(self):
        #  One machine, walked the whole campaign: jumping is what lays each
        #  picket out, and re-booting per mission would be seven more
        #  emulators. The fleet is at its ceiling throughout, which is the
        #  state that used to leave nothing for the enemy.
        self.fill_the_fleet()

        #  AND THE BATTLE IS FROZEN FOR THE WHOLE WALK, because this test
        #  counts what mis_setup PLACED and a live fleet does not leave that
        #  alone. Fifty-six interceptors sitting on the Mothership killed one
        #  of mission 5's picket inside the four game frames between the setup
        #  and the count, and the test reported it as a slot the mission could
        #  not find -- which is the opposite of what happened. SPACE stops the
        #  battle and not the orders, so `J` still works and mis_setup still
        #  runs; nothing here is about combat.
        #
        #  It only became reachable when the fleet's ceiling doubled: at 28
        #  ships those four frames were not enough to kill anything.
        self.hold(" ")
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "the battle did not stop")
        for index in range(1, 8):
            self.jump_once()
            with self.subTest(mission=index + 1):
                self.assertEqual(self.byte("MIS_INDEX"), index)
                #  AND THE FLEET IS TOPPED BACK UP RATHER THAN ASSUMED WHOLE.
                #  The jump out of every MG_EVERY'th mission has the vortex
                #  chase in it, and a chase nobody plays costs a tenth to a
                #  half of the fleet -- so this walk came out of mission 4 with
                #  28 ships of 56 and reported it as the fleet not surviving a
                #  jump, which is now a thing that legitimately happens. See
                #  game/minigame.asm.
                #
                #  What this test is about is whether the PICKET fits beside a
                #  fleet at its CEILING, so the ceiling is restored here and
                #  the ambush is somebody else's subject. The count below is
                #  what says the refill worked.
                self.fill_the_fleet()
                self.assertEqual(len(self.friendly()), self.PLAYER_MAX,
                                 "the fleet is not at its ceiling for this mission")
                self.assert_sides_stay_home(f"in mission {index + 1}")
                #  ...and every hostile the row asks for is actually there.
                #  mis_setup "places what fits and stops", so a region one
                #  slot short would field a smaller picket and say nothing.
                with open("build/bank7.raw", "rb") as f:
                    bank7 = f.read()
                wanted = bank7[self.sym["MISSION_TABLE"] - 0x4000
                               + index * MIS_SIZE + MIS_ENEMY_COUNT]
                #  ...plus the DERELICT, in the missions that field one. It is
                #  a hostile-region entity like any other -- which is exactly
                #  why it has to be counted here rather than filtered out: it
                #  is one slot the picket and a wave cannot have, and this is
                #  the test that would notice when that stops adding up.
                if (self.sym["MIS_DERELICT_FROM"] <= index
                        <= self.sym["MIS_DERELICT_UNTIL"]):
                    wanted += 1
                self.assertEqual(len(self.picket()), wanted,
                                 f"mission {index + 1} asked for {wanted} hostiles")


class TestTheMothershipAtTheCeiling(RegionFixture):
    """fleet_restore packs the survivors into slots 0..n-1 and re-finds the
    Mothership by class as it loads. That is inside the player's region and
    should be untouched by the partition -- but it is the routine that has
    already ended one campaign every run with "the Mothership was lost", so
    it gets a test rather than a glance."""

    def test_it_survives_a_jump_with_the_fleet_at_its_ceiling(self):
        self.fill_the_fleet()
        self.assertEqual(len(self.friendly()), self.PLAYER_MAX)
        self.jump_to(1)

        slot = self.byte("MOTH_SLOT")
        self.assertLess(slot, self.PLAYER_MAX,
                        "moth_slot points into the hostile region")
        flags = self.ent(slot, ENT_FLAGS)
        self.assertTrue(flags & F_ACTIVE, "moth_slot points at an empty slot")
        self.assertFalse(flags & F_ENEMY, "moth_slot points at an ENEMY ship")
        self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_MOTHERSHIP)
        self.assertEqual(self.byte("MIS_FAILED"), 0)

    def test_a_packed_fleet_at_the_ceiling_still_finds_it(self):
        """Kill ships from underneath the Mothership so the restore has to
        move it, with the region full to start with -- the exact arithmetic
        that produced the original bug, at the one fleet size the partition
        makes newly reachable."""
        self.fill_the_fleet()
        moth = self.byte("MOTH_SLOT")
        killed = 0
        for slot in range(moth):
            if self.ent(slot, ENT_FLAGS) & F_ACTIVE:
                self.poke_ent(slot, ENT_FLAGS, 0)
                killed += 1
                if killed == 3:
                    break
        self.assertEqual(killed, 3)
        self.c.run_frames(30)

        self.jump_to(1)
        moved = self.byte("MOTH_SLOT")
        self.assertNotEqual(moved, moth, "the fleet did not pack down: no test")
        self.assertEqual(self.ent(moved, ENT_CLASS), CLASS_MOTHERSHIP,
                         "moth_slot did not follow the Mothership down")
        self.assertEqual(self.byte("MIS_FAILED"), 0)

    def test_a_saved_fleet_never_names_more_ships_than_the_region_can_hold(self):
        """fleet_disc_load range-checks the count against ENT_PLAYER_MAX now,
        because fleet_restore packs into slots 0..n-1 and a bigger n would lay
        the fleet across the hostile region -- where mis_clear_enemies does not
        touch it and mis_setup spawns on top of it. This is the other end of
        that check: a save the game itself writes, at the largest fleet the
        game can have, must not be one the loader would refuse."""
        self.fill_the_fleet()
        self.jump_to(1)
        count = self.byte("FLEET_COUNT")
        self.assertEqual(count, self.PLAYER_MAX,
                         "the full fleet did not all get saved")
        self.assertLessEqual(count, self.PLAYER_MAX,
                             "fleet_save wrote a count fleet_disc_load would reject")


class TestSlotZeroIsPermanentlyOurs(RegionFixture):
    """A zeroed ENT_TARGET names slot 0, and slot 0 is now always a friendly.
    That was already guarded -- cbt_fire_if_able checks the sides at the
    moment of FIRING rather than only when a target is chosen -- so this is a
    guard rather than a new claim, and it passes on both sides of the change.
    It is here because the partition is what makes slot 0's side permanent."""

    def test_slot_zero_is_ours_from_the_first_frame_and_after_a_wave(self):
        flags = self.ent(0, ENT_FLAGS)
        self.assertTrue(flags & F_ACTIVE)
        self.assertFalse(flags & F_ENEMY)
        self.force_wave()
        flags = self.ent(0, ENT_FLAGS)
        self.assertTrue(flags & F_ACTIVE, "slot 0 was emptied by a wave")
        self.assertFalse(flags & F_ENEMY, "a hostile took slot 0")

    def test_a_fleet_all_aiming_at_slot_zero_does_not_shoot_it(self):
        """The state a zeroed field produces, arranged deliberately. Every
        friendly is pointed at one of its own and there is a real enemy on
        the map to make the guns live."""
        self.force_wave()
        self.assertTrue(self.hostile(), "no enemy: the guns are not live")
        for slot in self.friendly():
            self.poke_ent(slot, ENT_TARGET, 0)
        before = self.ent(0, ENT_HULL)
        self.c.run_frames(300)
        self.assertEqual(self.ent(0, ENT_FLAGS) & F_ACTIVE, F_ACTIVE,
                         "the fleet shot slot 0 dead")
        self.assertGreaterEqual(self.ent(0, ENT_HULL), before,
                                "slot 0 lost hull to its own side")
