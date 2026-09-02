"""Phase 7: resources, harvesters and construction.

The criterion is "οικονομικός βρόχος πλήρης" -- the loop has to close, so the
last test drives the whole of it: build a harvester, send it to work, and
watch RU come back out the other end.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Mirrored from src/game/entity.asm, shipclass.asm and economy.asm
ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walks range(ENT_MAX) then stops looking
#  exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_PLAYER_MAX = h.symbols()["ENT_PLAYER_MAX"]

#  src/game/entity.asm. IDLE is what a spawn has to leave behind and ATTACK is
#  what a slot can be carrying when the yard reaches it.
ENT_ORDER_IDLE, ENT_ORDER_ATTACK = 0, 2
ENT_CLASS, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_LOAD = 9, 11, 12, 13, 15
F_ACTIVE, F_ENEMY = 1, 2
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER = 0, 1, 2
CLASS_SCOUT, CLASS_BOMBER = 3, 4
CLASS_BUILDABLE = 7
#  src/game/economy.asm: ten orders outstanding, the one on the slipway being
#  one of them, so the waiting line holds nine.
QUEUE_MAX, QUEUE_WAIT = 10, 9
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

    def open_the_whole_list(self, slot=25):
        """A harvester in the air, so the yard offers every class."""
        return h.give_the_yard_a_harvester(self.c, self.sym, slot)

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

    def clear_every_slot_but_the_mothership(self):
        """Empty the table, and LEAVE THE MOTHERSHIP FLYING.

        Losing it now ends the campaign. mis_update sets mis_failed the frame
        its slot goes inactive, the game-over screen takes the whole screen,
        and demo_update returns before phase4_commands ever runs -- so every
        key a test presses afterwards is ignored and the failure reads as "the
        ship did not come back whole" rather than as "there is no game any
        more". Before there was a game-over screen this was harmless, which is
        why several fixtures wipe the table and none of them thought about it.

        It does not disturb what these tests measure: the Mothership is in
        squadron 0 and repair, recycle and the rest are scoped to squad_sel,
        so an untouched one is skipped anyway.
        """
        moth = self.byte("MOTH_SLOT")
        for slot in range(ENT_MAX):
            if slot == moth:
                continue
            self.c.write_ram(
                self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames(4)

    def ships_by_class(self):
        out = {}
        for slot in range(ENT_MAX):
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
        order = list(h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
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


    def setUp(self):
        super().setUp()
        #  These are about the yard, not about the rule that the economy comes
        #  first -- see TestTheEconomyComesFirst.
        self.open_the_whole_list()

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

    def test_a_second_order_goes_behind_the_first_rather_than_being_refused(self):
        """The yard used to take one order and refuse every other, which meant
        a player who had just mined a field dry had to sit and watch a
        countdown before they could spend it. Section 5.5 asked for a queue."""
        self.c.write_ram(self.sym["ECO_RU"], (500).to_bytes(2, "little"))
        self.hold("b")
        self.set_pick(CLASS_INTERCEPTOR)
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_INTERCEPTOR)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 0, "the first order queued twice")

        after_first = self.ru()
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 1,
                         "the second order was refused")
        self.assertEqual(self.ru(), after_first - COST[CLASS_INTERCEPTOR],
                         "the second order was taken and not paid for")
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_INTERCEPTOR,
                         "the second order pushed the first off the slipway")

    def test_a_ship_you_cannot_afford_is_refused(self):
        self.c.write_ram(self.sym["ECO_RU"], (10).to_bytes(2, "little"))
        self.hold("b")
        self.set_pick(CLASS_HARVESTER)
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.ru(), 10, "RU was spent on something unaffordable")
        self.assertGreaterEqual(self.byte("ECO_BUILD_CLASS"), 3, "it was queued anyway")


class TestConstruction(EconomyFixture):


    def setUp(self):
        super().setUp()
        #  These are about the yard, not about the rule that the economy comes
        #  first -- see TestTheEconomyComesFirst.
        self.open_the_whole_list()

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


class TestAShipIsBornWithNoOrders(EconomyFixture):
    """A replacement built after a casualty must not inherit its orders.

    THE BUG, reported as "χάνονται οι σχηματισμοί κάποιες φορές στην μάχη.
    Έκανα επίθεση και δεν ανταποκρίνονταν μετά. Μόνο τα καινούρια σκάφη."

    Two halves, and it took both to bite. A dead ship's record keeps every byte
    it had, ENT_SQUAD included -- so order_issue, which asked only about the
    squadron, wrote ENT_ORDER_ATTACK into the EMPTY slots of the selection as
    well. Then eco_spawn_built, which never wrote ENT_ORDER at all, built a
    ship into one of those holes and it came out of the Mothership already
    attacking. phase4_fly SKIPS an attacking ship on purpose, so the new ship
    never joined the formation and ignored every order given to it.

    It only shows while a hostile is alive to stop cbt_fire_if_able spending
    the order -- which since the attack waves is most of a mission, and is why
    it is "κάποιες φορές" rather than always.
    """

    def setUp(self):
        super().setUp()
        self.open_the_whole_list()

    def free_slot_in_the_selection(self):
        """A hole where a ship of the selected squadron used to be.

        Killed by clearing ACTIVE and nothing else, which is exactly what a
        killing blow leaves behind: cbt_kill does not tidy the record, and
        there is no reason it should.
        """
        squad = self.byte("SQUAD_SEL")
        for slot in range(ENT_PLAYER_MAX):
            f = self.ent(slot, ENT_FLAGS)
            if (f & F_ACTIVE) and not (f & F_ENEMY) \
                    and self.ent(slot, ENT_SQUAD) == squad \
                    and self.ent(slot, ENT_CLASS) != CLASS_MOTHERSHIP:
                self.c.write_ram(
                    self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS,
                    bytes([0]))
                return slot
        self.fail("the selected squadron has no ship to lose")

    def press_attack(self):
        self.hold(",")
        self.hold("a")

    def order_the_ship_is_born_with(self, ship_class, slot):
        """Build, and read ENT_ORDER the instant the slot comes alive.

        CAUGHT AT THE MOMENT OF SPAWN RATHER THAN A MOMENT LATER, and that is
        what makes this able to fail. An inherited attack order does not last:
        cbt_fire_if_able spends it on the first turn the new ship takes if
        there is no enemy to be found -- and mission 1 has none, so reading the
        byte after build()'s eight-hundred-frame wait comes back IDLE on the
        broken build as well as the fixed one.

        Keeping an enemy alive to stop that was tried and does not work: the
        Vekhar close at PHASE4_STEP, so any hostile near enough for
        cbt_find_enemy to see at all -- dist_manhattan saturates past 16320
        units -- crosses the gap and is killed well inside the same window.

        So the claim is narrowed to the one that is actually being made: THE
        SPAWN WRITES THE ORDER. What happens to it afterwards is combat's, and
        combat is right.
        """
        self.hold("b")
        self.set_pick(ship_class)
        self.hold(cpc.KEY_ENTER, frames=25)
        self.hold("b")
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        for _ in range(1400):
            if self.c.read_ram(base + ENT_FLAGS, 1)[0] & F_ACTIVE:
                return self.c.read_ram(base + ENT_ORDER, 1)[0]
            self.c.run_frames(1)
        self.fail("the yard never delivered into the slot that was free")

    def test_an_order_is_not_given_to_an_empty_slot(self):
        """The cause. An order issued to a slot with no ship in it cannot mean
        anything, and it is what plants the mine the yard then steps on."""
        slot = self.free_slot_in_the_selection()
        self.assertEqual(self.ent(slot, ENT_ORDER), ENT_ORDER_IDLE)
        self.press_attack()
        self.assertEqual(
            self.ent(slot, ENT_ORDER), ENT_ORDER_IDLE,
            "pressing A wrote an attack order into an EMPTY slot of the "
            "selected squadron")

    def test_a_ship_built_into_that_slot_comes_out_idle(self):
        """The guarantee, and it holds even if something else plants an order.

        The slot's order is poked directly rather than through `A`, so this
        still fails with only the order_issue half of the repair present: a
        spawn has to initialise every field it depends on, which is the rule
        ENT_TARGET on the line above it has always followed.
        """
        slot = self.free_slot_in_the_selection()
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_ORDER,
                         bytes([ENT_ORDER_ATTACK]))
        self.assertEqual(
            self.order_the_ship_is_born_with(CLASS_INTERCEPTOR, slot),
            ENT_ORDER_IDLE,
            "the new ship inherited the dead one's attack order, so "
            "phase4_fly will never fly it into formation")

    def test_and_pressing_A_does_not_arm_the_slot_for_the_next_one(self):
        """The two halves together, on the path the player actually walks:
        lose a ship, press A, build a replacement into the hole."""
        slot = self.free_slot_in_the_selection()
        self.press_attack()
        self.assertEqual(
            self.order_the_ship_is_born_with(CLASS_INTERCEPTOR, slot),
            ENT_ORDER_IDLE)


class TestTheEconomyComesFirst(EconomyFixture):
    """With no harvester flying and none on the way, only harvesters build.

    RU only ever arrives through a harvester, so this is the one place the game
    can be spent into a state it cannot get out of: no harvester, forty units
    left, buy an interceptor, never earn again. It is not a difficulty rule --
    it is a soft-lock guard, and the build list is where it belongs because
    eco_pick_step walks PAST a class it refuses. With no harvesters the panel
    offers one class and there is nothing to explain and nothing to refuse.
    """

    def offered(self):
        """Every class the panel will stop on, walked all the way round."""
        seen = set()
        for _ in range(CLASS_BUILDABLE + 1):
            order = list(h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
                                      CLASS_BUILDABLE))
            seen.add(order[self.byte("ECO_BUILD_PICK")])
            self.hold(".", frames=20)
        return seen

    def test_with_no_harvesters_the_panel_offers_only_the_harvester(self):
        self.assertNotIn(CLASS_HARVESTER, self.ships_by_class(),
                         "the fixture starts with a harvester")
        self.hold("b")
        self.assertEqual(self.offered(), {CLASS_HARVESTER},
                         "the yard offered something that cannot pay for itself")

    def test_and_the_panel_opens_on_it_rather_than_on_a_refusal(self):
        """The pick survives between openings and what is allowed moves under
        it, so opening on a class ENTER then refuses reads as a broken key."""
        self.hold("b")
        order = list(h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
                                  CLASS_BUILDABLE))
        self.assertEqual(order[self.byte("ECO_BUILD_PICK")], CLASS_HARVESTER)

    def test_one_on_order_is_enough_to_open_the_list_again(self):
        """ON THE WAY counts, or the first order would lock the list until that
        harvester was delivered and a player would queue three."""
        self.hold("b")
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_HARVESTER,
                         "the harvester did not go on the slipway")
        self.assertIn(CLASS_INTERCEPTOR, self.offered(),
                      "one harvester on order and the list is still closed")

    def test_the_refusal_survives_the_orders_menu_injecting_a_pick(self):
        """eco_queue asks again at ENTER, because the pick is a byte in RAM
        and eco_pick_step is not the only thing that can move it."""
        order = list(h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
                                  CLASS_BUILDABLE))
        self.hold("b")
        self.c.write_ram(self.sym["ECO_BUILD_PICK"],
                         bytes([order.index(CLASS_INTERCEPTOR)]))
        before = self.ru()
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "an interceptor went on the slipway with no harvester")
        self.assertEqual(self.ru(), before, "the refused order was charged for")


class TestTheRepairPrice(EconomyFixture):
    """Twice the ship's price, for the fraction of it that is gone.

        cost = 2 * eco_class_cost[class] * (full - hull) / full

    THE NUMBER IS THE DESIGN. At half damage repairing costs exactly what
    building costs, so the price tells the player which to do without a word of
    explanation: below half mend it, above half let it die. A test that only
    checked "repairing costs something" would pass with a multiplier of one,
    which would make repair strictly better than building and nobody would ever
    build again.
    """

    COST = {CLASS_INTERCEPTOR: 35, CLASS_HARVESTER: 40, CLASS_SCOUT: 25}
    FULL = {}

    def setUp(self):
        super().setUp()
        self.FULL = {c: h.read_bank4(self.c, self.sym["CLASS_HULL"] + c, 1)[0]
                     for c in self.COST}

    def hurt(self, slot, ship_class, fraction):
        """Put a ship of `ship_class` in `slot` at `fraction` of full hull."""
        full = self.FULL[ship_class]
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(base + 9, bytes([ship_class]))
        self.c.write_ram(base + 10, bytes([max(1, int(full * fraction))]))
        self.c.write_ram(base + 12, bytes([1]))         # ENT_SQUAD: the selection
        self.c.write_ram(base + 13, bytes([0]))
        self.c.write_ram(base + 14, bytes([0xFF]))
        self.c.write_ram(base + 11, bytes([1]))         # ENT_FLAGS: active
        self.c.run_frames(4)
        return full

    def wipe_the_fleet(self):
        """Nothing but the ships this test puts there, so the price read off
        the treasury is one ship's and not the squadron's."""
        self.clear_every_slot_but_the_mothership()

    def repair_and_measure(self, ship_class, fraction, purse=9000):
        #  wipe_the_fleet takes the picket with it, which is what lets the
        #  yard work at all -- repair is refused while anything hostile is
        #  flying. TestWhenTheYardWillNotWork is where that rule is driven.
        self.wipe_the_fleet()
        self.c.write_ram(self.sym["ECO_REPAIRED"], b"\x00")
        full = self.hurt(20, ship_class, fraction)
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", purse))
        self.hold("e")
        self.c.run_frames(20)
        spent = purse - self.ru()
        hull = self.c.read_ram(
            self.sym["ENTITIES"] + 20 * ENT_SIZE + 10, 1)[0]
        return spent, hull, full

    def test_half_a_ship_costs_what_a_whole_one_costs(self):
        """The load-bearing number: at 50% damage, mending and building are the
        same price. Everything else about this feature follows from it."""
        for cls in (CLASS_INTERCEPTOR, CLASS_SCOUT):
            with self.subTest(ship=cls):
                spent, hull, full = self.repair_and_measure(cls, 0.5)
                self.assertEqual(hull, full, "the ship did not come back whole")
                self.assertAlmostEqual(spent, self.COST[cls], delta=2,
                                       msg=f"half a ship cost {spent}, not "
                                           f"{self.COST[cls]}")

    def test_a_scratch_is_cheap_and_a_wreck_is_dear(self):
        """Linear in the damage, which is what makes the half-way point mean
        anything. A flat price would make a scratch as dear as a hulk."""
        light, _, _ = self.repair_and_measure(CLASS_INTERCEPTOR, 0.9)
        heavy, _, _ = self.repair_and_measure(CLASS_INTERCEPTOR, 0.1)
        self.assertLess(light, heavy // 4,
                        f"10% damage cost {light} against 90%'s {heavy}")
        #  0.9 of 2 x 35, not 2 x 35: the ceiling price is for a ship with NO
        #  hull left, which is a ship that is dead. This asserted the ceiling
        #  and the code was right -- linear is what linear gives.
        self.assertAlmostEqual(heavy, 0.9 * 2 * self.COST[CLASS_INTERCEPTOR],
                               delta=3,
                               msg=f"a nine-tenths dead interceptor cost {heavy}")

    def test_an_undamaged_ship_is_free_and_is_not_charged_for(self):
        spent, hull, full = self.repair_and_measure(CLASS_INTERCEPTOR, 1.0)
        self.assertEqual(hull, full)
        self.assertEqual(spent, 0, "the yard charged to mend a whole ship")

    def test_the_price_follows_the_class_and_not_a_flat_rate(self):
        """eco_class_cost, not a constant: a Harvester at 40 RU and a Scout at
        25 cannot cost the same to mend or the class table means nothing."""
        harv, _, _ = self.repair_and_measure(CLASS_HARVESTER, 0.5)
        scout, _, _ = self.repair_and_measure(CLASS_SCOUT, 0.5)
        self.assertGreater(harv, scout,
                           f"harvester {harv} against scout {scout}")


class TestBreakingShipsUp(EconomyFixture):
    """`Y` recycles the selected squadron: half the price back, rising to
    seven tenths for a ship in good order.

        refund = eco_class_cost[class] * (0.5 + 0.2 * hull / full)

    THE RANGE HAS A DRIVER AND IT IS THE HULL, not a die roll -- the same
    reasoning game/salvage.asm gives for wrecks being deterministic: a coin
    toss is not something a player can act on.
    """

    COST = {CLASS_INTERCEPTOR: 35, CLASS_HARVESTER: 40, CLASS_SCOUT: 25}

    def setUp(self):
        super().setUp()
        self.clear_every_slot_but_the_mothership()

    def full_of(self, ship_class):
        return h.read_bank4(self.c, self.sym["CLASS_HULL"] + ship_class, 1)[0]

    def put(self, slot, ship_class, fraction, squad=1):
        full = self.full_of(ship_class)
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(base + 9, bytes([ship_class]))
        self.c.write_ram(base + 10, bytes([max(1, int(full * fraction))]))
        self.c.write_ram(base + 12, bytes([squad]))
        self.c.write_ram(base + 13, bytes([0]))
        self.c.write_ram(base + 14, bytes([0xFF]))
        self.c.write_ram(base + 11, bytes([1]))
        self.c.run_frames(2)

    def recycle(self, purse=0):
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", purse))
        self.hold("y")
        self.c.run_frames(20)
        return self.ru() - purse

    def alive(self, slot):
        return bool(self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, 1)[0] & 1)

    def test_a_whole_ship_gives_seven_tenths_back(self):
        self.put(10, CLASS_INTERCEPTOR, 1.0)
        paid = self.recycle()
        self.assertFalse(self.alive(10), "the ship was not broken up")
        self.assertAlmostEqual(paid, 0.7 * self.COST[CLASS_INTERCEPTOR],
                               delta=2, msg=f"a whole interceptor paid {paid}")

    def test_and_a_hulk_gives_half(self):
        self.put(10, CLASS_INTERCEPTOR, 0.01)
        paid = self.recycle()
        self.assertAlmostEqual(paid, 0.5 * self.COST[CLASS_INTERCEPTOR],
                               delta=2, msg=f"a nearly-dead one paid {paid}")

    def test_the_range_is_driven_by_the_hull_and_not_by_chance(self):
        """The same ship at the same hull has to pay the same twice, or the
        player cannot decide anything with the number."""
        seen = set()
        for _ in range(3):
            self.setUp()
            self.put(10, CLASS_INTERCEPTOR, 0.5)
            seen.add(self.recycle())
        self.assertEqual(len(seen), 1, f"the refund varied: {sorted(seen)}")

    def test_the_price_follows_the_class(self):
        self.put(10, CLASS_HARVESTER, 1.0)
        harv = self.recycle()
        self.setUp()
        self.put(10, CLASS_SCOUT, 1.0)
        scout = self.recycle()
        self.assertGreater(harv, scout,
                           f"harvester {harv} against scout {scout}")

    def test_the_mothership_is_never_broken_up(self):
        """Section 8 makes losing it the end of the campaign, so a key that
        could scrap it is a key that can end the game by accident."""
        self.put(10, CLASS_MOTHERSHIP, 1.0)
        self.put(11, CLASS_INTERCEPTOR, 1.0)
        self.recycle()
        self.assertTrue(self.alive(10), "the Mothership was recycled")
        self.assertFalse(self.alive(11), "nothing else was recycled either")

    def test_nothing_outside_the_selection_is_touched(self):
        self.put(10, CLASS_INTERCEPTOR, 1.0, squad=1)
        self.put(11, CLASS_INTERCEPTOR, 1.0, squad=4)
        self.recycle()
        self.assertFalse(self.alive(10))
        self.assertTrue(self.alive(11), "a ship in another squadron went too")

    def test_it_cannot_earn_past_the_ceiling(self):
        """eco_earn saturates, and the refund goes through it rather than
        round it -- ECO_RU_MAX is what the HUD's four digits can say."""
        for slot in range(10, 16):
            self.put(slot, CLASS_INTERCEPTOR, 1.0)
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 9990))
        self.hold("y")
        self.c.run_frames(20)
        self.assertLessEqual(self.ru(), 9999, "the treasury went past its ceiling")


class TestWhenTheYardWillNotWork(EconomyFixture):
    """Two refusals, and each is checked with the OTHER one satisfied."""

    def full_hull(self):
        return h.read_bank4(self.c, self.sym["CLASS_HULL"], 1)[0]

    def hurt_one(self, slot=10, squad=1):
        full = self.full_hull()
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(base + 9, bytes([CLASS_INTERCEPTOR]))
        self.c.write_ram(base + 10, bytes([full // 2]))
        self.c.write_ram(base + 12, bytes([squad]))
        self.c.write_ram(base + 13, bytes([0]))
        self.c.write_ram(base + 14, bytes([0xFF]))
        self.c.write_ram(base + 11, bytes([1]))
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 9000))
        self.c.run_frames(4)
        return full

    def hull(self, slot=10):
        return self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + 10, 1)[0]

    def clear_the_board(self):
        for slot in range(self.sym["ENT_PLAYER_MAX"], ENT_MAX):
            self.c.write_ram(
                self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames(4)

    def put_one_hostile(self):
        base = self.sym["ENTITIES"] + self.sym["ENT_PLAYER_MAX"] * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 9000, 0, 9000))
        self.c.write_ram(base + 9, bytes([CLASS_INTERCEPTOR]))
        self.c.write_ram(base + 10, bytes([200]))
        self.c.write_ram(base + 12, bytes([0xFF]))
        self.c.write_ram(base + 14, bytes([0xFF]))
        self.c.write_ram(base + 11, bytes([3]))         # ACTIVE | ENEMY
        self.c.run_frames(4)

    def test_not_while_anything_hostile_is_flying(self):
        """The yard works in the lulls. Repairing under fire would turn a deep
        treasury into an attrition the enemy cannot win."""
        full = self.hurt_one()
        self.clear_the_board()
        self.put_one_hostile()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full // 2,
                         "the yard mended a ship with an enemy on the board")

        #  ...and with that one gone, the same keypress works. Same machine,
        #  same ship, one bit different.
        self.clear_the_board()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full, "and then it would not mend at all")

    def test_a_wreck_is_not_an_enemy_for_this_either(self):
        """The derelict is ACTIVE and ENEMY for the whole of missions 4 to 6,
        so counting it would mean no repair in three missions of the eight."""
        full = self.hurt_one()
        self.clear_the_board()
        base = self.sym["ENTITIES"] + self.sym["ENT_PLAYER_MAX"] * ENT_SIZE
        self.c.write_ram(base + 11, bytes([1 | 2 | 4]))     # ...and DISABLED
        self.c.run_frames(4)
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full, "a wreck stopped the yard working")

    def test_only_once_in_a_mission(self):
        full = self.hurt_one()
        self.clear_the_board()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full)
        self.assertEqual(self.byte("ECO_REPAIRED"), 1)

        #  Hurt it again and ask again: the yard has had its turn.
        self.c.write_ram(
            self.sym["ENTITIES"] + 10 * ENT_SIZE + 10, bytes([full // 2]))
        self.c.run_frames(4)
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full // 2,
                         "the yard mended twice in one mission")

    def test_a_press_that_mends_nothing_does_not_use_the_turn_up(self):
        """Set at the moment a hull moves, not at the top of the routine --
        or a press with nothing damaged would silently spend the mission's
        one repair and the player would never see why."""
        self.clear_the_board()
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 9000))
        self.hold("e")                                  # nothing is damaged
        self.c.run_frames(20)
        self.assertEqual(self.byte("ECO_REPAIRED"), 0,
                         "an empty repair used the mission's one up")

        full = self.hurt_one()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(), full, "and then the real one was refused")

    def test_and_a_press_that_cannot_be_afforded_does_not_either(self):
        self.hurt_one()
        self.clear_the_board()
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 1))
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.byte("ECO_REPAIRED"), 0,
                         "a repair nobody could pay for used the turn up")

    def test_the_turn_comes_back_with_the_next_mission(self):
        """mis_setup clears it, so "once per mission" is by construction."""
        self.clear_the_board()
        self.hurt_one()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.byte("ECO_REPAIRED"), 1)
        h.jump_mission(self.c)
        self.assertEqual(self.byte("ECO_REPAIRED"), 0,
                         "the repair did not come back with the new mission")


class TestRepairingASquadron(EconomyFixture):
    """`E` mends the selected squadron, as far as the RU goes."""

    def setUp(self):
        super().setUp()
        self.clear_every_slot_but_the_mothership()
        self.full = h.read_bank4(
            self.c, self.sym["CLASS_HULL"] + CLASS_INTERCEPTOR, 1)[0]

    def put(self, slot, hull, squad=1):
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(base + 9, bytes([CLASS_INTERCEPTOR]))
        self.c.write_ram(base + 10, bytes([hull]))
        self.c.write_ram(base + 12, bytes([squad]))
        self.c.write_ram(base + 13, bytes([0]))
        self.c.write_ram(base + 14, bytes([0xFF]))
        self.c.write_ram(base + 11, bytes([1]))
        self.c.run_frames(2)

    def hull(self, slot):
        return self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + 10, 1)[0]

    def test_every_ship_of_the_selection_comes_back(self):
        for slot in (10, 11, 12):
            self.put(slot, self.full // 2)
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 9000))
        self.hold("e")
        self.c.run_frames(20)
        for slot in (10, 11, 12):
            self.assertEqual(self.hull(slot), self.full,
                             f"slot {slot} was not mended")

    def test_and_nothing_outside_it_does(self):
        """Squadron-scoped, like H, T, A and G. Mending the whole fleet from
        one key would make the selection mean nothing."""
        self.put(10, self.full // 2, squad=1)
        self.put(11, self.full // 2, squad=3)
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 9000))
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(10), self.full)
        self.assertEqual(self.hull(11), self.full // 2,
                         "a ship in another squadron was mended")

    def test_what_cannot_be_afforded_is_skipped_and_not_a_full_stop(self):
        """Slot order, and an unaffordable ship does not hold up the cheap
        ones behind it -- that would be a rule the player has to be told."""
        self.put(10, 1)                                 # nearly dead: ~70 RU
        self.put(11, self.full - 4)                     # a scratch: about 1 RU
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 8))
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(10), 1, "the unaffordable ship was mended")
        self.assertEqual(self.hull(11), self.full,
                         "the cheap ship behind it was skipped as well")

    def test_a_ship_comes_back_whole_or_not_at_all(self):
        """Half a repair is expressible and is not offered: it would make the
        price of the next one depend on how much was bought last time."""
        self.put(10, 1)
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 30))
        before = self.ru()
        self.hold("e")
        self.c.run_frames(20)
        self.assertEqual(self.hull(10), 1, "a part-paid repair moved the hull")
        self.assertEqual(self.ru(), before, "a refused repair was charged for")


class TestTheBuildQueue(EconomyFixture):
    """Ten orders, mixed classes, first in first out.

    EVERY TEST HERE FOLLOWS INDIVIDUAL ORDERS, and that is deliberate rather
    than thorough. A queue that reverses itself, that loses the middle entry,
    or that builds the class the player picked LAST for every slot in the line
    has exactly the right depth at every moment -- so a test that reads
    ECO_QUEUE_LEN and stops is a test that passes against all three. It is the
    same blind spot as the squadron tests that counted ships while they went
    to the wrong squadrons, and the combat tests that counted kills while the
    fleet was stranded where the last one died.

    So: four DIFFERENT classes go in, and what comes out is checked by class,
    in order, one at a time.
    """

    #  Cheap, distinct, and cheap enough that four fit in one purse. The
    #  Mothership is not on the list and the Destroyer is not offered before
    #  mission 5, which leaves five to choose four from.
    LINE = [CLASS_SCOUT, CLASS_INTERCEPTOR, CLASS_HARVESTER, CLASS_BOMBER]


    def setUp(self):
        super().setUp()
        #  These are about the yard, not about the rule that the economy comes
        #  first -- see TestTheEconomyComesFirst.
        self.open_the_whole_list()

    def order(self, ship_class):
        """One ENTER on one class, with the panel already open."""
        self.set_pick(ship_class)
        self.hold(cpc.KEY_ENTER, frames=25)

    def active(self):
        return {s for s in range(ENT_MAX) if self.ent(s, ENT_FLAGS) & F_ACTIVE}

    def line(self):
        """The whole order book: the slipway first, then what is waiting.

        eco_build_class IS the head of the queue rather than a copy of it,
        which is why there is no second name for "what is being built".
        """
        head = self.byte("ECO_BUILD_CLASS")
        waiting = list(self.c.read_ram(self.sym["ECO_QUEUE_BUF"], QUEUE_WAIT))
        return ([] if head >= 8 else [head]) + waiting[:self.byte("ECO_QUEUE_LEN")]

    def launch_the_head(self, before):
        """Poke the countdown to zero and report the class that came out.

        The timer is poked rather than waited out for the reason
        test_shipclass gives: a Bomber is 60 GAME frames on the slipway, which
        at the rate this really runs is most of a minute of emulated time, and
        the countdown is not what is under test.
        """
        for _ in range(30):
            if self.byte("ECO_BUILD_CLASS") < 8:
                break
            self.c.run_frames(10)
        else:
            self.fail("nothing ever reached the slipway")
        self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([0]))
        for _ in range(30):
            self.c.run_frames(10)
            new = self.active() - before
            if new:
                self.assertEqual(len(new), 1, f"{len(new)} ships appeared at once")
                #  Let the next order reach the slipway before returning. A
                #  finished ship leaves it empty and the NEXT frame pops the
                #  queue, so a caller that read ECO_QUEUE_LEN the instant the
                #  hull appeared would sometimes catch the old depth and
                #  sometimes the new one -- which is a flaky test rather than
                #  a bug in the yard.
                self.c.run_frames(20)
                return self.ent(new.pop(), ENT_CLASS)
        self.fail("the ship on the slipway never came out")

    def test_the_ships_come_out_in_the_order_they_were_ordered(self):
        """The one property a FIFO has. Four distinct classes, so a queue that
        kept the right DEPTH while shuffling its contents fails here."""
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        self.hold("b")
        for ship_class in self.LINE:
            self.order(ship_class)
        self.assertEqual(self.line(), self.LINE, "four orders did not go in")
        self.hold("b")                              # close the panel

        came_out = []
        for _ in self.LINE:
            before = self.active()
            came_out.append(self.launch_the_head(before))
        self.assertEqual(came_out, self.LINE,
                         "the queue is not first in, first out")

    def test_the_line_shortens_by_one_for_every_ship_that_leaves(self):
        """The count is not the property under test above, but it still has to
        agree with it -- a queue that pops without shortening builds its head
        for ever."""
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        self.hold("b")
        for ship_class in self.LINE:
            self.order(ship_class)
        self.hold("b")

        seen = [self.byte("ECO_QUEUE_LEN")]
        for _ in self.LINE:
            self.launch_the_head(self.active())
            seen.append(self.byte("ECO_QUEUE_LEN"))
        self.assertEqual(seen, [3, 2, 1, 0, 0], f"the depth went {seen}")

    def test_ten_orders_are_taken_and_the_eleventh_is_refused(self):
        """The slipway is one of the ten, so the waiting line is nine.

        PAUSED FIRST, because this is a test about the queue's DEPTH and the
        yard drains it. SPACE freezes the battle and the economy and leaves the
        orders running (section 9), so B and ENTER still work and eco_update
        does not -- which is the only way to press ten orders in and still know
        that ten is what is standing there.

        It used to get away without: ten presses at 25 emulator frames each is
        250 frames, and at five game frames a second that was not quite long
        enough to finish a Scout. The frame rate went to about seven when
        cbt_find_enemy stopped sweeping the whole table, the first hull came
        off the slipway inside those same 250 frames, and the depth read 8.
        A test whose precondition is "the game is too slow to have done
        anything yet" was always going to break the day it got faster.
        """
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        self.hold(" ")
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "the yard did not stop")
        self.hold("b")
        self.set_pick(CLASS_SCOUT)
        cost = 25

        for n in range(10):
            before = self.ru()
            self.hold(cpc.KEY_ENTER, frames=25)
            self.assertEqual(self.ru(), before - cost,
                             f"order {n + 1} of ten was refused")
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 9)

        before = self.ru()
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 9,
                         "an eleventh order went into a ten-deep queue")
        self.assertEqual(self.ru(), before,
                         "the refused eleventh order was charged for")

    def test_a_refused_order_is_not_charged_for_and_a_full_queue_still_builds(self):
        """The refusal must not leave the yard stuck: what is already in the
        line goes on being built."""
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        self.hold("b")
        self.set_pick(CLASS_SCOUT)
        for _ in range(12):                          # two more than it will take
            self.hold(cpc.KEY_ENTER, frames=25)
        self.hold("b")

        before = self.active()
        self.assertEqual(self.launch_the_head(before), CLASS_SCOUT)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 8,
                         "the queue did not move on after being refused")

    def test_the_queue_carries_through_a_jump(self):
        """The RU was taken when the order was placed, so a queue thrown away
        at the jump would silently destroy the player's money. mis_setup does
        not touch it -- exactly as it has never touched the half-built hull on
        the slipway."""
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        self.hold("b")
        for ship_class in self.LINE:
            self.order(ship_class)
        self.hold("b")
        #  Hold the countdown well clear of the jump. A Scout is 30 game
        #  frames on the slipway and dismissing a briefing is about that many,
        #  so without this the test would race the yard rather than the jump.
        self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([255]))

        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1, "mission 1 never completed")
        self.assertEqual(self.line(), self.LINE, "the order book moved before the jump")
        h.jump_mission(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 1, "the jump did not happen")

        self.assertEqual(self.line(), self.LINE,
                         "the order book did not survive the jump")
        came_out = []
        for _ in self.LINE:
            came_out.append(self.launch_the_head(self.active()))
        self.assertEqual(came_out, self.LINE,
                         "the queue did not survive the jump intact")


class TestAnOrderRemembersWhoPlacedIt(EconomyFixture):
    """A ship joins the squadron that ORDERED it, not the one selected when it
    happens to come off the slipway.

    That was already true of the single slipway and nobody minded, because the
    window was one build time. The queue takes ten orders, so the window is ten
    build times -- order three interceptors for squadron 1, press `3` to look
    at something, and all three used to arrive in squadron 3.

    An order is a plan and a plan says who it is for. The moment the player
    said so is the moment they paid, which is the same moment eco_queue takes
    the RU and for the same reason.
    """

    def setUp(self):
        super().setUp()
        self.open_the_whole_list()

    def squadron_of(self, slot):
        return self.ent(slot, ENT_SQUAD)

    def active_slots(self):
        """Which of the fleet's slots hold a ship RIGHT NOW.

        Compared before and after rather than guessing at the first free one:
        open_the_whole_list pokes a harvester in, in squadron 0, and the first
        free slot is below it -- so a scan that took "everything above the free
        slot" collected that harvester and reported a ship in squadron 0 that
        nothing had ordered.
        """
        return {slot for slot in range(ENT_PLAYER_MAX)
                if self.ent(slot, ENT_FLAGS) & F_ACTIVE}

    def free_slot(self):
        for slot in range(ENT_PLAYER_MAX):
            if not (self.ent(slot, ENT_FLAGS) & F_ACTIVE):
                return slot
        self.fail("the fleet has no room to build into")

    def order(self, ship_class):
        """Queue one, without waiting for it."""
        self.hold("b")
        self.set_pick(ship_class)
        self.hold(cpc.KEY_ENTER, frames=25)
        self.hold("b")

    def test_the_squadron_is_taken_at_order_time(self):
        """Order for the selected squadron, then select another and wait."""
        ordered_for = self.byte("SQUAD_SEL")
        slot = self.free_slot()
        self.order(CLASS_INTERCEPTOR)

        #  ...and now look somewhere else, which is the whole scenario. A
        #  squadron with no ships is refused by squad_select, so `d` makes one
        #  first: the divide peels half of squadron 1 into the next free
        #  number and selects nothing, so the press after it can.
        self.hold("d")
        self.hold("2")
        moved_to = self.byte("SQUAD_SEL")
        self.assertNotEqual(moved_to, ordered_for,
                            "the selection never moved, so this proves nothing")

        for _ in range(1200):
            if self.ent(slot, ENT_FLAGS) & F_ACTIVE:
                break
            self.c.run_frames(2)
        else:
            self.fail("the yard never delivered")

        self.assertEqual(
            self.squadron_of(slot), ordered_for,
            f"the ship joined squadron {self.squadron_of(slot)}, which is "
            f"whoever was selected when it FINISHED, not the {ordered_for} "
            "that ordered it")

    def test_each_order_in_the_queue_keeps_its_own(self):
        """Two orders for two squadrons, waiting at once. One byte on the
        slipway would give both of them the second one's answer.

        SPACE FIRST, and it is the same trick TestTheBuildQueue uses: eco_update
        is skipped while the game is paused and phase4_commands is not, so the
        yard holds still while `B`, ENTER and the squadron keys go on working.
        Without it the first hull is delivered before the second order can be
        placed and there is no queue in the test at all -- measured, the first
        one came off the slipway during the two keypresses that change the
        selection.
        """
        self.hold(cpc.KEY_SPACE)
        before = self.active_slots()

        first_for = self.byte("SQUAD_SEL")
        self.order(CLASS_INTERCEPTOR)

        #  A squadron with no ships is refused by squad_select, so `d` makes
        #  one first: it peels half of squadron 1 into the next free number.
        self.hold("d")
        self.hold("2")
        second_for = self.byte("SQUAD_SEL")
        self.assertNotEqual(first_for, second_for,
                            "the selection never moved, so this proves nothing")
        self.order(CLASS_INTERCEPTOR)
        self.assertGreater(self.byte("ECO_QUEUE_LEN"), 0,
                           "both orders went to the slipway: there is no queue "
                           "in this test")

        self.hold(cpc.KEY_SPACE)                    # ...and let the yard work
        made = {}
        for _ in range(2400):
            for slot in self.active_slots() - before:
                made.setdefault(slot, self.squadron_of(slot))
            if len(made) >= 2:
                break
            self.c.run_frames(2)

        self.assertGreaterEqual(len(made), 2,
                                f"only {len(made)} ship(s) arrived: {made}")
        got = sorted(made.values())
        self.assertEqual(got, sorted([first_for, second_for]),
                         f"the two ships joined {got}, not one each for "
                         f"{first_for} and {second_for}")


class TestTheQueueOnTheScreen(EconomyFixture):
    """Section 5.5 asks the strip for "Πόροι (RU) και ουρά κατασκευής".

    Only the RU half was ever there. A player cannot manage a queue they
    cannot see, and this is the pixels rather than the variable -- the depth
    could be perfectly correct in memory and drawn nowhere, or drawn over the
    mission number, and ECO_QUEUE_LEN would say nothing about either.
    """

    YARD_X, YARD_W = 44, 12             # the field, in screen bytes
    MIS_X, MIS_W = 56, 24               # "M 1 JUMP", which it must not reach
    ROW_Y, ROW_H = 188, 8


    def setUp(self):
        super().setUp()
        #  These are about the yard, not about the rule that the economy comes
        #  first -- see TestTheEconomyComesFirst.
        self.open_the_whole_list()

    def field(self, x, w):
        self.c.write_ram(self.sym["PHASE4_HUD_DIRTY"], bytes([2]))
        self.c.run_frames(60)
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return bytes(ram[h.screen_offset(y, bx)]
                     for y in range(self.ROW_Y, self.ROW_Y + self.ROW_H)
                     for bx in range(x, x + w))

    def deepen_to(self, depth):
        """Press ENTER until `depth` orders are waiting behind the slipway.

        Built up in one machine rather than one per depth: a queue only ever
        gets deeper, so the depths can be visited in order.
        """
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        for _ in range(2 * QUEUE_MAX):              # bounded: a hang is a fail
            if (self.byte("ECO_QUEUE_LEN") >= depth
                    and self.byte("ECO_BUILD_CLASS") <= 7):
                break
            self.hold(cpc.KEY_ENTER, frames=25)
            #  Nothing may LEAVE the slipway while the field is being read, or
            #  the depth on screen is a different depth from the one asked for.
            self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([255]))
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), depth)

    def test_the_depth_is_drawn_and_every_depth_looks_different(self):
        self.hold("b")
        self.set_pick(CLASS_SCOUT)
        seen = {}
        for depth in (0, 1, 3, 9):
            self.deepen_to(depth)
            pixels = self.field(self.YARD_X, self.YARD_W)
            self.assertNotIn(pixels, seen,
                             f"a queue of {depth} is drawn exactly like "
                             f"a queue of {seen.get(pixels)}")
            seen[pixels] = depth

    def test_it_does_not_reach_the_mission_number(self):
        """The field grew a fifth character. txt_draw clips at the screen edge
        and not at a field, so an overrun would quietly eat 'M 1 JUMP' and
        nothing at run time would say so. src/main.asm asserts the geometry;
        this asserts the pixels."""
        self.c.run_frames(200)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "mission 1 is not complete, so JUMP would come and go")
        empty = self.field(self.MIS_X, self.MIS_W)

        self.hold("b")
        self.set_pick(CLASS_SCOUT)
        self.deepen_to(9)
        self.hold("b")
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        self.assertEqual(self.field(self.MIS_X, self.MIS_W), empty,
                         "the yard readout wrote into the mission field")


class TestTheResourcesAMissionCarries(EconomyFixture):
    """Five to ten times what they used to be, at the design owner's request.

    Stated as what the map has to be ABLE to pay for rather than as the
    numbers in campaign.asm, because the numbers are the thing under test and
    a test that repeats them is a copy rather than a check.
    """

    #  src/game/classdata.asm: the Destroyer, and ECO_QUEUE_MAX of them.
    DEAREST, QUEUE_MAX = 250, 10

    def test_a_rich_mission_can_pay_for_a_full_queue_of_the_dearest_class(self):
        """That is the point of the change: with 3200 RU in the ground a rich
        map could not fill one queue with anything above the bottom of the
        price list, so what to build was decided by what was affordable."""
        self.assertEqual(self.byte("MIS_INDEX"), 0, "mission 1 is the rich one")
        self.assertGreaterEqual(sum(self.stock()), self.DEAREST * self.QUEUE_MAX,
                                "a rich mission cannot fill the build queue")

    def test_no_patch_is_anywhere_near_wrapping_its_word(self):
        """The stock is a word and the mining clamp keeps it off the bottom;
        this is the other end, and it is the one the multiplier moved."""
        for n, stock in enumerate(self.stock()):
            self.assertLess(stock, 0x8000, f"patch {n} is within a doubling of 65535")


class TestTheRuCeiling(EconomyFixture):
    """eco_ru saturates at what the four-digit readout can say.

    Six times the resources means a whole campaign's mining adds up past
    65535 if none of it is ever spent, which would wrap the word -- and it
    passes 9999 long before that, at which point txt_draw_num4 draws the
    thousands column as '@' because it subtracts 1000 sixteen times. The
    number on the strip and the number in memory have to be the same number.
    """

    RU_MAX = 9999

    def cash_in(self, start, load):
        """Put a full harvester on the Mothership and let it be paid out."""
        self.c.write_ram(self.sym["ECO_RU"], int(start).to_bytes(2, "little"))
        moth = self.byte("MOTH_SLOT")
        base = self.sym["ENTITIES"]
        here = self.c.read_ram(base + moth * ENT_SIZE, 6)

        slot = next(s for s in range(ENT_MAX)
                    if (self.ent(s, ENT_FLAGS) & F_ACTIVE) and s != moth)
        self.c.write_ram(base + slot * ENT_SIZE, here)          # on top of it
        self.c.write_ram(base + slot * ENT_SIZE + ENT_CLASS, bytes([CLASS_HARVESTER]))
        self.c.write_ram(base + slot * ENT_SIZE + ENT_ORDER, bytes([ORDER_HARVEST]))
        self.c.write_ram(base + slot * ENT_SIZE + ENT_LOAD, bytes([LOAD_MAX]))
        self.c.run_frames(60)
        return self.ru()

    def test_a_delivery_that_would_go_over_stops_at_the_ceiling(self):
        self.assertEqual(self.cash_in(self.RU_MAX - 10, LOAD_MAX), self.RU_MAX)

    def test_a_delivery_that_would_not_is_paid_in_full(self):
        """The control: without it the test above passes against a yard that
        pays nothing at all."""
        self.assertEqual(self.cash_in(1000, LOAD_MAX), 1000 + LOAD_MAX)


class TestTheReadout(EconomyFixture):
    """What the player can SEE, which is not what ECO_RU says.

    eco_ru has always been a word and every add has always been 16-bit, so
    every test in this file passed while the strip showed the wrong number:
    phase4_hud did `ld a,(eco_ru)`, took the low byte, and printed it in a
    three-digit field. 300 RU read as 044.

    It went unnoticed because nothing could be bought for more than 40. All
    eight of section 8's classes landing made the Destroyer buyable at 250 --
    so a player has to save past 255 to afford one, and the counter read zero
    exactly when they got there. The assumption was sound when written; what
    invalidated it was somewhere else entirely.
    """

    RU_X, RU_W = 54, 16                 # the field, in screen bytes
    RU_Y, RU_H = 176, 10

    def readout(self, ru):
        """The pixels of the RU field with that much in hand."""
        self.c.write_ram(self.sym["ECO_RU"], int(ru).to_bytes(2, "little"))
        #  The HUD only redraws when it changes, and nothing else has.
        self.c.write_ram(self.sym["PHASE4_HUD_DIRTY"], bytes([2]))
        self.c.run_frames(60)
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return bytes(ram[h.screen_offset(y, x)]
                     for y in range(self.RU_Y, self.RU_Y + self.RU_H)
                     for x in range(self.RU_X, self.RU_X + self.RU_W))

    def test_the_readout_does_not_wrap_at_256(self):
        """300 and 44 differ by exactly one high byte, and used to look alike."""
        self.assertNotEqual(self.readout(300), self.readout(44),
                            "300 RU is drawn the same as 44 -- the readout wrapped")
        self.assertNotEqual(self.readout(256), self.readout(0),
                            "256 RU is drawn the same as none at all")

    def test_every_amount_a_player_can_hold_looks_different(self):
        seen = {}
        for ru in (0, 44, 120, 250, 255, 256, 300, 1000, 1234, 9999):
            pixels = self.readout(ru)
            self.assertNotIn(pixels, seen,
                             f"{ru} RU is drawn exactly like {seen.get(pixels)} RU")
            seen[pixels] = ru

    def test_it_fits_beside_the_help_hint(self):
        """Four digits reach byte 70, which is where ?HELP starts.

        txt_draw clips at the screen edge, not at a field, so an overrun would
        silently overwrite the hint rather than fail.
        """
        self.readout(9999)
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        label = h.read_bank4(self.c, self.sym["PHASE4_HUD_HELP"], 6)
        self.assertEqual(label, b"?HELP\x00")
        ink = sum(bin(ram[h.screen_offset(y, x)]).count("1")
                  for y in range(self.RU_Y, self.RU_Y + self.RU_H)
                  for x in range(70, 80))
        self.assertGreater(ink, 20, "the widest RU figure wiped out ?HELP")


class TestHarvesting(EconomyFixture):

    def _harvester_slots(self):
        return [s for s in range(ENT_MAX)
                if (self.ent(s, ENT_FLAGS) & F_ACTIVE)
                and self.ent(s, ENT_CLASS) == CLASS_HARVESTER]

    def test_h_only_puts_harvesters_to_work(self):
        """Section 9 marks the harvest order '(harvesters)'."""
        self.build(CLASS_HARVESTER)
        self.hold("h")

        working = 0
        for slot in range(ENT_MAX):
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
        #  ...and take the ceiling from the mission rather than writing a
        #  number down. The stocks are six times what they were and this test
        #  quietly became "is a patch under 900", which the first one no longer
        #  is. A stock can only fall, so what it started at IS the bound.
        ceiling = max(self.stock())
        self.build(CLASS_HARVESTER)
        self.hold("h")

        for _ in range(12):
            self.c.run_frames(150)
            for i, st in enumerate(self.stock()):
                self.assertLessEqual(st, ceiling, f"patch {i} wrapped round to {st}")

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


class TestTheHarvesterWithNothingToDo(EconomyFixture):
    """Two ways a harvester runs out of work, and they are the same bug.

    The obvious assertion -- "the RU stopped rising" -- is worthless here. It
    is true when the fix works, and it is equally true when the harvester
    stops dead in the sky with nobody steering it, which is the thing that was
    actually wrong. phase4_fly SKIPS ENT_ORDER_HARVEST, so a harvester whose
    order is never spent is moved by nothing at all and fleet_save carries its
    coordinates into the next mission.

    So these follow the ship BY SLOT and ask where it ends up.
    """

    ORDER_HARVEST, ORDER_IDLE = 4, 0
    PATCH_COUNT, PATCH_SIZE, PATCH_STOCK = 4, 8, 6

    def patch_stock(self):
        base = self.sym["ECO_PATCHES"]
        return [int.from_bytes(self.c.read_ram(
            base + i * self.PATCH_SIZE + self.PATCH_STOCK, 2), "little")
            for i in range(self.PATCH_COUNT)]

    def empty_every_patch(self):
        base = self.sym["ECO_PATCHES"]
        for i in range(self.PATCH_COUNT):
            self.c.write_ram(base + i * self.PATCH_SIZE + self.PATCH_STOCK,
                             (0).to_bytes(2, "little"))

    def harvesters(self):
        base = self.sym["ENTITIES"]
        out = []
        for s in range(ENT_MAX):
            b = base + s * 20
            f = self.c.read_ram(b + 11, 1)[0]
            if f & 1 and not f & 2 and self.c.read_ram(b + 9, 1)[0] == 2:
                out.append(s)
        return out

    def order_of(self, slot):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * 20 + 13, 1)[0]

    def pos_of(self, slot):
        b = self.sym["ENTITIES"] + slot * 20
        return tuple(int.from_bytes(self.c.read_ram(b + i * 2, 2), "little",
                                    signed=True) for i in range(3))

    def make_harvester(self, slot=20):
        """Mission 1 opens with interceptors and the Mothership and nothing
        else, so a harvester has to be put there. Slot 20 is inside the
        player's region (0..ENT_PLAYER_MAX-1) and clear of the starting
        fleet. It is placed FAR from squadron 1's station, because the second
        half of the exhausted-map test asks whether phase4_fly picks the ship
        up once the order is spent -- and a ship already standing on its
        station has nowhere to fly, which passes for the wrong reason."""
        b = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(b, struct.pack("<hhh", 6000, 0, 6000))
        self.c.write_ram(b + 9, bytes([2]))         # ENT_CLASS: harvester
        self.c.write_ram(b + 10, bytes([200]))      # ENT_HULL
        self.c.write_ram(b + 12, bytes([1]))        # ENT_SQUAD
        self.c.write_ram(b + 15, bytes([0]))        # ENT_LOAD: empty hold
        self.c.write_ram(b + 11, bytes([1]))        # ENT_FLAGS: active, ours
        return slot

    def send_them_out(self):
        self.make_harvester()
        slots = self.harvesters()
        self.assertTrue(slots, "the fixture has no harvesters to order")
        self.hold("h")
        self.c.run_frames(60)
        self.assertTrue(any(self.order_of(s) == self.ORDER_HARVEST for s in slots),
                        "`H` did not put anybody to work")
        return slots

    def test_a_full_treasury_stops_the_mining_and_sends_them_home(self):
        """The RU ceiling is 9999 and eco_earn saturates there, so mining on
        drains a finite patch for income that is thrown away."""
        slots = self.send_them_out()
        stock = self.patch_stock()

        self.c.write_ram(self.sym["ECO_RU"], (9999).to_bytes(2, "little"))
        self.c.run_frames(300)

        self.assertEqual(self.patch_stock(), stock,
                         "the patches are still being drained at the RU ceiling")
        for s in slots:
            self.assertEqual(self.order_of(s), self.ORDER_IDLE,
                             f"harvester in slot {s} still holds a harvest order "
                             f"with the treasury full -- phase4_fly skips it, so "
                             f"nothing is steering it")

    def test_an_exhausted_map_sends_them_home_rather_than_stranding_them(self):
        """The twin, and the one that was already shipping: with every patch
        mined out, eco_harvester_step used to return without spending the
        order, and the ship stopped dead where it stood."""
        slots = self.send_them_out()
        self.empty_every_patch()

        #  MEASURED FROM WHERE IT WAS PUT, and before a frame of the flight
        #  home has run. This asked whether the ship moved between two later
        #  windows, which is a statement about the FRAME RATE and not about
        #  phase4_fly: make_harvester places it 12,000 units out on purpose,
        #  and the day the game got faster it had flown home and stopped
        #  inside the first window -- so the second one saw a ship standing
        #  still, which is exactly what "nothing is steering it" looks like.
        home = struct.unpack("<hhh", self.c.read_ram(self.sym["SQUAD_DEST"], 6))
        away = lambda s: sum(abs(a - b) for a, b in zip(self.pos_of(s), home))
        started = {s: away(s) for s in slots}

        self.c.run_frames(400)

        for s in slots:
            self.assertEqual(self.order_of(s), self.ORDER_IDLE,
                             f"harvester in slot {s} is stranded on a mined-out map")
            #  Half the way home and no nearer test than that: where it stops
            #  is its FORMATION SLOT, which is a lattice corner some thousands
            #  of units off the station itself.
            self.assertLess(
                away(s), started[s] // 2,
                f"harvester in slot {s} is {away(s)} from its station and was "
                f"{started[s]} -- being IDLE is only half the fix; phase4_fly "
                "has to fly it home")
