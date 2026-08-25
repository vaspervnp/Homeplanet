"""FLEET.DAT on the disc, by way of the uPD765.

"Ο στόλος είναι μόνιμος. Ό,τι επιβιώνει σε μια αποστολή ξεκινά την επόμενη."
test_campaign.py already proves that across a jump. This proves it across the
power going off, which is what section 10 actually asks for and what banking
the fleet in RAM could never give.

These boot from the real .dsk rather than quickloading, because the disc IS
the thing under test. That is slow, so there are few of them.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

ENT_SIZE = 20
ENT_CLASS, ENT_FLAGS = 9, 11
F_ACTIVE, F_ENEMY = 1, 2
CLASS_MOTHERSHIP = 1


class DiscFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def fresh_machine(self):
        """A cold 6128 with our disc in the drive, sitting at the BASIC prompt."""
        c = cpc.CPC()
        c.run_frames(h.BOOT_FRAMES)
        if not c.insert_disc(h.DSK):
            raise RuntimeError(f"insert_disc failed for {h.DSK}")
        return c

    def run_the_game(self, c):
        """RUN"DISC and get past the opening briefing."""
        c.type_text("|DISC\n")
        c.run_frames(60)
        c.type_text('RUN"DISC\n')
        c.run_frames(400)
        h.dismiss_briefing(c)

    def power_cycle(self, c):
        """Reset the machine, leaving the disc where it is.

        The emulator keeps the disc image in memory, so what was written to it
        survives a reset exactly as a real floppy survives the power going off
        -- and the file on the host is never touched, so one test cannot leave
        a campaign half-played for the next.
        """
        c.reset()
        c.run_frames(h.BOOT_FRAMES)
        self.assertTrue(c.disc_inserted, "the reset ejected the disc")
        self.run_the_game(c)

    # -- reading ------------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def ent(self, slot, offset):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def fleet(self):
        return sum(1 for s in range(48) if (self.ent(s, ENT_FLAGS) & 3) == F_ACTIVE)

    def kill_one_interceptor(self):
        for slot in range(48):
            if ((self.ent(slot, ENT_FLAGS) & 3) == F_ACTIVE
                    and self.ent(slot, ENT_CLASS) != CLASS_MOTHERSHIP):
                self.c.write_ram(
                    self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
                return slot
        self.fail("no interceptor to lose")


class TestFleetSurvivesThePowerGoingOff(DiscFixture):

    def test_a_new_disc_starts_a_new_campaign(self):
        """Nothing is saved yet, so the read must fail and be ignored.

        The failure path matters as much as the success one: with no disc at
        all -- which is every quickloaded test in this suite -- the controller
        refuses the command and skips its execution phase, and a driver that
        pumped 512 bytes at it anyway would wait on RQM forever. The whole
        suite hanging was exactly that.
        """
        self.c = self.fresh_machine()
        self.run_the_game(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 0, "a fresh disc did not start at mission 1")
        self.assertEqual(self.byte("MIS_SAVED"), 0, "a fresh disc claimed to hold a save")
        self.assertGreater(self.fleet(), 10, "no fleet on a new game")

    def test_the_fleet_and_the_mission_come_back_after_a_reset(self):
        """The one that could not be done while the fleet lived in bank 4."""
        self.c = self.fresh_machine()
        self.run_the_game(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 0)

        before = self.fleet()
        self.kill_one_interceptor()             # a loss, and losses are forever
        self.c.run_frames(120)
        h.jump_mission(self.c)                  # the jump is what writes the disc

        mission = self.byte("MIS_INDEX")
        survivors = self.fleet()
        self.assertEqual(mission, 1)
        self.assertEqual(survivors, before - 1)

        self.power_cycle(self.c)

        self.assertEqual(self.byte("MIS_SAVED"), 1, "the disc had no save on it")
        self.assertEqual(self.byte("MIS_INDEX"), mission,
                         "came back on the wrong mission")
        self.assertEqual(self.fleet(), survivors,
                         "the fleet changed size across the power cycle")
        self.assertLess(self.fleet(), before,
                        "the lost ship came back -- losses are supposed to be permanent")

    def test_the_mothership_is_still_the_mothership_afterwards(self):
        """moth_slot is an index, and fleet_restore moves what it points at.

        Saving and reloading packs the fleet down exactly as a jump does, so
        this is the same trap as the one that ended the campaign at mission 5
        with "the Mothership was lost" -- reached by a different road.
        """
        self.c = self.fresh_machine()
        self.run_the_game(self.c)
        self.kill_one_interceptor()
        self.c.run_frames(120)
        h.jump_mission(self.c)

        self.power_cycle(self.c)

        slot = self.byte("MOTH_SLOT")
        self.assertTrue(self.ent(slot, ENT_FLAGS) & F_ACTIVE,
                        "moth_slot points at an empty slot after reloading")
        self.assertFalse(self.ent(slot, ENT_FLAGS) & F_ENEMY,
                         "moth_slot points at an enemy after reloading")
        self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_MOTHERSHIP)
        self.assertEqual(self.byte("MIS_FAILED"), 0)


class TestTheSaveIsChecked(DiscFixture):
    """Everything read off a disc is guesswork until it has been checked."""

    def put_block_on_the_disc(self, header):
        """Write an arbitrary block to the save sectors.

        Not by pressing J: fleet_disc_save stamps a correct header on its way
        past, so a scribble made before it is simply overwritten. This calls
        the layer underneath, which writes the block exactly as it stands --
        the only way to put a header on the disc that the game would not have
        written itself.
        """
        h.write_cpu(self.c, self.sym["FLEET_BLOCK"], header)
        addr = self.sym["FDC_FLEET_SAVE"]
        self.c.write_ram(h.STUB, bytes([0xCD, addr & 0xFF, addr >> 8,
                                        0x18, 0xFE]))       # call it, then spin
        self.c.set_pc(h.STUB)
        self.c.run_frames(120)

    def test_a_save_without_the_magic_is_ignored(self):
        """A blank disc, another game's disc and a half-written save all
        arrive here, and two of them would be nonsense to act on."""
        self.c = self.fresh_machine()
        self.run_the_game(self.c)
        self.kill_one_interceptor()
        self.c.run_frames(120)
        h.jump_mission(self.c)                  # a real, valid save first
        self.assertEqual(self.byte("MIS_INDEX"), 1)

        self.put_block_on_the_disc(b"\x00\x00\x01\x0F")

        self.power_cycle(self.c)
        self.assertEqual(self.byte("MIS_SAVED"), 0,
                         "a header without the magic was taken as a save")
        self.assertEqual(self.byte("MIS_INDEX"), 0,
                         "a rejected save still moved the campaign")

    def test_a_save_naming_a_mission_that_does_not_exist_is_ignored(self):
        """The index is used to walk the mission table, so a wild one reads
        somebody else's bytes as a mission and lays out the enemy from them."""
        self.c = self.fresh_machine()
        self.run_the_game(self.c)
        self.c.run_frames(120)
        h.jump_mission(self.c)

        #  Right magic, impossible mission.
        self.put_block_on_the_disc(bytes([ord("H"), ord("P"), 200, 15]))

        self.power_cycle(self.c)
        self.assertEqual(self.byte("MIS_SAVED"), 0,
                         "mission 201 of 8 was accepted")
        self.assertEqual(self.byte("MIS_INDEX"), 0)
        self.assertGreater(self.fleet(), 10, "the rejected save cost us the fleet")


if __name__ == "__main__":
    unittest.main()
