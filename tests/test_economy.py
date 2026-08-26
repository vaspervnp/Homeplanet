"""Phase 7: resources, harvesters and construction.

The criterion is "οικονομικός βρόχος πλήρης" -- the loop has to close, so the
last test drives the whole of it: build a harvester, send it to work, and
watch RU come back out the other end.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Mirrored from src/game/entity.asm, shipclass.asm and economy.asm
ENT_SIZE = 20
ENT_CLASS, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_LOAD = 9, 11, 12, 13, 15
F_ACTIVE, F_ENEMY = 1, 2
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER = 0, 1, 2
CLASS_BUILDABLE = 7
ORDER_HARVEST = 4
PATCH_COUNT, PATCH_SIZE = 4, 8
COST = {CLASS_INTERCEPTOR: 35, CLASS_HARVESTER: 40}
START_RU = 120
LOAD_MAX = 60


class EconomyFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading ------------------------------------------------------------
    def ru(self):
        return int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def ent(self, slot, offset):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def stock(self):
        base = self.sym["ECO_PATCHES"]
        return [int.from_bytes(self.c.read_ram(base + i * PATCH_SIZE + 6, 2), "little")
                for i in range(PATCH_COUNT)]

    def ships_by_class(self):
        out = {}
        for slot in range(48):
            f = self.ent(slot, ENT_FLAGS)
            if (f & F_ACTIVE) and not (f & F_ENEMY):
                k = self.ent(slot, ENT_CLASS)
                out[k] = out.get(k, 0) + 1
        return out

    # -- pressing -----------------------------------------------------------
    def hold(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(12)

    def set_pick(self, ship_class):
        """Walk the build panel round to a class, wherever it starts.

        eco_build_order is in bank 4 with the rest of the per-class data, so
        it has to be read through the CPU's view -- read_ram would hand back
        bank 1 and index() would find the class at a fictional position.
        """
        order = list(h.read_cpu(self.c, self.sym["ECO_BUILD_ORDER"],
                                CLASS_BUILDABLE))
        want = order.index(ship_class)
        for _ in range(len(order)):
            if self.byte("ECO_BUILD_PICK") == want:
                return
            self.hold(".", frames=20)
        self.fail(f"could not select class {ship_class}")

    #  Long enough for the yard to finish AND clear itself, with margin. This
    #  is a count of 50Hz frames while the yard counts GAME frames -- ten of
    #  them each at the rate this actually runs -- so 350 was about one game
    #  frame of slack and any change that moved a frame boundary tipped it.
    #  Colouring the HUD did exactly that, and the ship was building fine.
    def build(self, ship_class, wait=800):
        self.hold("b")                              # open the panel
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1)
        self.set_pick(ship_class)
        self.hold(cpc.KEY_ENTER, frames=25)
        started = self.byte("ECO_BUILD_CLASS")
        self.hold("b")                              # close it again
        self.c.run_frames(wait)
        return started


class TestStartingState(EconomyFixture):

    def test_the_fleet_starts_with_resources_and_stocked_patches(self):
        """How many patches there are is the MISSION's business, not ours."""
        self.assertEqual(self.ru(), START_RU)
        self.assertGreater(sum(self.stock()), 0, "the mission laid out no resources")

    def test_there_are_no_harvesters_to_begin_with(self):
        self.assertNotIn(CLASS_HARVESTER, self.ships_by_class())


class TestBuildPanel(EconomyFixture):

    def test_b_toggles_the_panel(self):
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 0)
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1)
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 0)

    def test_the_panel_takes_over_the_comma_and_period_keys(self):
        """They walk the target list otherwise; while it is open they pick a class."""
        self.hold(".", frames=20)
        target_moved = self.byte("ORDER_TARGET")
        self.assertNotEqual(target_moved, 0xFF, "'.' did not walk the target")

        self.hold("b")
        pick_before = self.byte("ECO_BUILD_PICK")
        self.hold(".", frames=20)
        self.assertNotEqual(self.byte("ECO_BUILD_PICK"), pick_before,
                            "'.' did not change the build selection")
        self.assertEqual(self.byte("ORDER_TARGET"), target_moved,
                         "'.' walked the target while the panel was open")

    def test_enter_queues_a_ship_and_charges_for_it(self):
        self.hold("b")
        self.set_pick(CLASS_HARVESTER)
        before = self.ru()
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_HARVESTER)
        self.assertEqual(self.ru(), before - COST[CLASS_HARVESTER])

    def test_only_one_ship_is_on_the_slipway_at_a_time(self):
        self.hold("b")
        self.set_pick(CLASS_INTERCEPTOR)
        self.hold(cpc.KEY_ENTER, frames=25)
        after_first = self.ru()
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.ru(), after_first, "a second order was taken and paid for")

    def test_a_ship_you_cannot_afford_is_refused(self):
        self.c.write_ram(self.sym["ECO_RU"], (10).to_bytes(2, "little"))
        self.hold("b")
        self.set_pick(CLASS_HARVESTER)
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.ru(), 10, "RU was spent on something unaffordable")
        self.assertGreaterEqual(self.byte("ECO_BUILD_CLASS"), 3, "it was queued anyway")


class TestConstruction(EconomyFixture):

    def test_a_finished_ship_appears_and_joins_the_squadron(self):
        before = self.ships_by_class().get(CLASS_HARVESTER, 0)
        selected = self.byte("SQUAD_SEL")
        counts_before = list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))

        self.build(CLASS_HARVESTER)

        after = self.ships_by_class().get(CLASS_HARVESTER, 0)
        self.assertEqual(after, before + 1, "no harvester came out of the yard")

        counts_after = list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))
        self.assertEqual(counts_after[selected], counts_before[selected] + 1,
                         "the new ship did not join the squadron that ordered it")

    def test_the_slipway_clears_when_the_ship_is_done(self):
        self.build(CLASS_INTERCEPTOR)
        self.assertGreaterEqual(self.byte("ECO_BUILD_CLASS"), 3,
                                "the yard is still holding a finished ship")


class TestHarvesting(EconomyFixture):

    def _harvester_slots(self):
        return [s for s in range(48)
                if (self.ent(s, ENT_FLAGS) & F_ACTIVE)
                and self.ent(s, ENT_CLASS) == CLASS_HARVESTER]

    def test_h_only_puts_harvesters_to_work(self):
        """Section 9 marks the harvest order '(harvesters)'."""
        self.build(CLASS_HARVESTER)
        self.hold("h")

        working = 0
        for slot in range(48):
            if not (self.ent(slot, ENT_FLAGS) & F_ACTIVE):
                continue
            harvesting = self.ent(slot, ENT_ORDER) == ORDER_HARVEST
            if harvesting:
                working += 1
                self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_HARVESTER,
                                 f"slot {slot} is not a harvester but was sent to mine")
        self.assertEqual(working, 1, "the wrong number of ships went to work")

    def test_h_with_no_harvesters_does_nothing(self):
        before = self.stock()
        self.hold("h")
        self.c.run_frames(300)
        self.assertEqual(self.ru(), START_RU)
        self.assertEqual(self.stock(), before, "the patches were mined with no harvesters")

    def test_the_loop_closes(self):
        """Build a harvester, send it out, and watch RU come back."""
        self.build(CLASS_HARVESTER)
        self.hold("h")

        after_build = self.ru()
        stock_before = sum(self.stock())

        delivered = False
        for _ in range(14):
            self.c.run_frames(200)
            if self.ru() > after_build:
                delivered = True
                break
        self.assertTrue(delivered,
                        f"no resources came back: RU {after_build}, stock {self.stock()}")

        self.assertLess(sum(self.stock()), stock_before, "the patches were not mined")

    def test_resources_are_conserved(self):
        """What the fleet gains is what the patches lose."""
        self.build(CLASS_HARVESTER)
        self.hold("h")

        ru_before, stock_before = self.ru(), sum(self.stock())
        carried_before = sum(self.ent(s, ENT_LOAD) for s in self._harvester_slots())

        self.c.run_frames(1400)

        ru_after, stock_after = self.ru(), sum(self.stock())
        carried_after = sum(self.ent(s, ENT_LOAD) for s in self._harvester_slots())

        mined = stock_before - stock_after
        gained = (ru_after - ru_before) + (carried_after - carried_before)
        self.assertGreater(mined, 0, "nothing was mined")
        self.assertEqual(gained, mined,
                         f"{mined} mined but {gained} accounted for")

    def test_a_patch_never_goes_below_empty(self):
        """A 16-bit stock taken below zero wraps to 65534.

        That turned an exhausted field into an inexhaustible one, and the
        symptom was a patch reading 65336 several minutes into a run.
        """
        #  Start the nearest patch nearly empty so it is drained during the test.
        self.c.write_ram(self.sym["ECO_PATCHES"] + 6, (4).to_bytes(2, "little"))
        self.build(CLASS_HARVESTER)
        self.hold("h")

        for _ in range(12):
            self.c.run_frames(150)
            for i, st in enumerate(self.stock()):
                self.assertLessEqual(st, 900, f"patch {i} wrapped round to {st}")

    def test_harvesters_leave_the_formation(self):
        """Otherwise phase4_fly pulls them back as fast as the economy pushes.

        Both step by PHASE4_STEP, so the two cancel exactly and the harvester
        sits still while the RU never moves.
        """
        self.build(CLASS_HARVESTER)
        slot = self._harvester_slots()[0]
        self.hold("h")

        def position():
            base = self.sym["ENTITIES"] + slot * ENT_SIZE
            return tuple(int.from_bytes(self.c.read_ram(base + i * 2, 2), "little", signed=True)
                         for i in range(3))

        start = position()
        self.c.run_frames(250)
        self.assertNotEqual(position(), start, "the harvester never left the formation")


if __name__ == "__main__":
    unittest.main()
