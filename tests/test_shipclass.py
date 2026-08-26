"""Section 8's eight ship classes, and the three banks they live in.

Two things are being tested here and they are not the same thing.

The first is that a CLASS is a real thing: it costs what section 8 says, it
has a hull, it has a row in the balance triangle, and the yard will build it.
None of that depends on where its sprites are.

The second is the memory arrangement that makes eight classes possible at all.
Forty-five kilobytes of sprite library does not fit in DISC.BIN, so six of the
eight are raw sectors on the disc that lib_load reads into extended banks 5, 6
and 7 -- and drawing one means paging bank 4 out from under the mission table,
the fleet buffer and the code for every static screen. The tests for that are
about the WINDOW: that the right bank is under it while a class is being
drawn, and that bank 4 is back under it afterwards.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Mirrored from src/game/shipclass.asm
(CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER, CLASS_SCOUT,
 CLASS_BOMBER, CLASS_FRIGATE, CLASS_SALVAGE, CLASS_DESTROYER) = range(8)
CLASS_COUNT = 8
CLASS_BUILDABLE = 7
CLASS_DESTROYER_MIS = 4
CLASS_TIERS = 3
CLASS_SPRITE_STRIDE = 6

NAME = ["interceptor", "mothership", "harvester", "scout",
        "bomber", "frigate", "salvage", "destroyer"]

#  Homeplanet.md section 8, verbatim. The Mothership has no cost.
SECTION_8_COST = {
    CLASS_SCOUT: 25, CLASS_INTERCEPTOR: 35, CLASS_HARVESTER: 40,
    CLASS_BOMBER: 55, CLASS_SALVAGE: 90, CLASS_FRIGATE: 120,
    CLASS_DESTROYER: 250,
}

GA_BANK_4 = 0xC4
BANK_WINDOW = 0x4000

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS = 9, 10, 11
F_ACTIVE, F_ENEMY = 1, 2

BUILD_DIR = os.path.join(h.ROOT, "build")


class ClassFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def boot(self, **kw):
        self.c = h.boot_quick(frames=300, **kw)
        return self.c

    # -- reading ------------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def banked(self, name, size):
        """Read something out of bank 4, the way the CPU sees it."""
        return h.read_cpu(self.c, self.sym[name], size)

    def ent(self, slot, offset):
        return self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def class_bank(self):
        return list(self.c.read_ram(self.sym["CLASS_BANK"], CLASS_COUNT))

    def class_sprite(self):
        raw = self.c.read_ram(self.sym["CLASS_SPRITE"],
                              CLASS_COUNT * CLASS_SPRITE_STRIDE)
        return [[raw[c * 6 + t * 2] | (raw[c * 6 + t * 2 + 1] << 8)
                 for t in range(CLASS_TIERS)] for c in range(CLASS_COUNT)]

    # -- pressing -----------------------------------------------------------
    def hold(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(12)

    # -- running Z80 --------------------------------------------------------
    def call(self, addr, setup=b"", collect=b""):
        """Run `setup`, CALL addr, run `collect`, then stop dead."""
        code = bytes(setup) + bytes([0xCD, addr & 0xFF, addr >> 8]) \
            + bytes(collect) + b"\x18\xfe"
        self.c.write_ram(h.STUB, code)
        self.c.set_pc(h.STUB)
        self.c.run_us(20000)

    def page_in(self, bank):
        """Put an extended bank under the window and leave it there."""
        self.c.write_ram(h.STUB,
                         bytes([0x01, bank, 0x7F, 0xED, 0x49, 0x18, 0xFE]))
        self.c.set_pc(h.STUB)
        self.c.run_us(200)


class TestTheClassesExist(ClassFixture):
    """Every class of section 8, with the numbers section 8 gives."""

    def test_the_yard_offers_every_class_section_8_gives_a_price(self):
        """Section 8 lists eight classes and puts a cost on seven of them.
        The Mothership is the exception -- there is only ever one, and it is
        the thing you lose the game by losing, not a thing you order."""
        self.boot()
        order = list(self.banked("ECO_BUILD_ORDER", CLASS_BUILDABLE))
        self.assertEqual(sorted(order), sorted(SECTION_8_COST),
                         "the build list is not section 8's seven classes")
        self.assertNotIn(CLASS_MOTHERSHIP, order)

    def test_every_cost_is_the_one_in_the_design_document(self):
        self.boot()
        cost = list(self.banked("ECO_CLASS_COST", CLASS_COUNT))
        for cls, want in SECTION_8_COST.items():
            self.assertEqual(cost[cls], want,
                             f"{NAME[cls]} costs {cost[cls]}, section 8 says {want}")
        self.assertEqual(cost[CLASS_MOTHERSHIP], 0,
                         "the Mothership has a price, so the yard would build one")

    def test_the_yard_is_a_price_list_in_ascending_order(self):
        """The panel shows one class at a time, so , and . are the only way to
        see what else there is. Ordering it by price means the player walking
        the list is walking up a ladder rather than guessing."""
        self.boot()
        order = list(self.banked("ECO_BUILD_ORDER", CLASS_BUILDABLE))
        cost = list(self.banked("ECO_CLASS_COST", CLASS_COUNT))
        prices = [cost[c] for c in order]
        self.assertEqual(prices, sorted(prices), prices)

    def test_every_class_has_a_tag_the_hud_can_show(self):
        """The yard readout is three characters wide. A class with no tag
        would print whatever follows the table, in the middle of the HUD."""
        self.boot()
        tags = self.banked("CLASS_TAG", CLASS_COUNT * 4)
        seen = set()
        for cls in range(CLASS_COUNT):
            tag = bytes(tags[cls * 4:cls * 4 + 3])
            self.assertEqual(tags[cls * 4 + 3], 0,
                             f"{NAME[cls]}'s tag is not terminated")
            self.assertTrue(all(32 <= b < 127 for b in tag), tag)
            self.assertNotIn(tag, seen, f"two classes are called {tag!r}")
            seen.add(tag)


class TestTheBalanceTriangle(ClassFixture):
    """Section 8: Interceptor -> Bomber -> Frigate -> Interceptor.

    Tested through cbt_damage_for rather than by reading the table, because
    the table is only half of it: the row index is three hand-written shifts
    that assume eight columns, and a matrix that is right with an indexing
    that is wrong gives a Frigate the Harvester's gun.
    """

    def damage(self, shooter_class, target_class):
        """What a ship of one class does to a ship of another, for real."""
        base = self.sym["ENTITIES"]
        for slot, cls, flags in ((0, shooter_class, F_ACTIVE),
                                 (1, target_class, F_ACTIVE | F_ENEMY)):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_CLASS, bytes([cls]))
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, bytes([flags]))
        self.c.write_ram(self.sym["CBT_ENT"],
                         (base & 0xFF).to_bytes(1, "little") + bytes([base >> 8]))
        self.c.write_ram(self.sym["CBT_TARGET"], bytes([1]))
        #  ld (RESULT),a straight after the call
        self.call(self.sym["CBT_DAMAGE_FOR"],
                  collect=bytes([0x32, h.RESULT & 0xFF, h.RESULT >> 8]))
        return self.c.read_ram(h.RESULT, 1)[0]

    def test_each_leg_of_the_triangle_favours_the_class_that_should_win(self):
        """This is the ONLY place the triangle exists. Movement, range and
        cooldown are identical for every class, so if these three comparisons
        do not hold then section 8's balance is not implemented at all."""
        self.boot()
        for winner, loser in ((CLASS_INTERCEPTOR, CLASS_BOMBER),
                              (CLASS_BOMBER, CLASS_FRIGATE),
                              (CLASS_FRIGATE, CLASS_INTERCEPTOR)):
            there = self.damage(winner, loser)
            back = self.damage(loser, winner)
            self.assertGreater(
                there, back * 2,
                f"{NAME[winner]} does {there} to {NAME[loser]} and takes "
                f"{back} back -- section 8 says it wins that fight")

    def test_the_unarmed_classes_are_unarmed(self):
        """Section 8 calls the Harvester 'άοπλο'. It has a row because the
        matrix is square, and the row has to be nearly nothing -- a harvester
        that fights is a harvester that is not mining."""
        self.boot()
        armed = self.damage(CLASS_INTERCEPTOR, CLASS_INTERCEPTOR)
        for cls in (CLASS_HARVESTER, CLASS_SALVAGE, CLASS_SCOUT):
            self.assertLess(self.damage(cls, CLASS_INTERCEPTOR), armed // 2,
                            f"{NAME[cls]} shoots like a warship")

    def test_the_interceptor_row_is_what_it_was_before_there_were_eight(self):
        """The enemy fields interceptors and nothing else, so this one cell is
        the whole campaign's arithmetic. It was 24 when the matrix was three
        classes wide and it has to still be 24, or every balance number in
        CLAUDE.md is about a different game."""
        self.boot()
        self.assertEqual(self.damage(CLASS_INTERCEPTOR, CLASS_INTERCEPTOR), 24)

    def test_a_class_index_out_of_range_does_not_read_off_the_matrix(self):
        """ENT_CLASS is a byte in a table that is also a save format. A wild
        value would index past 64 entries into whatever follows."""
        self.boot()
        self.assertEqual(self.damage(200, 200),
                         self.damage(CLASS_INTERCEPTOR, CLASS_INTERCEPTOR))


class TestTheDestroyerIsGated(ClassFixture):
    """Section 8: the Destroyer is 'διαθέσιμο από την 5η αποστολή'."""

    def pick_class(self):
        order = list(self.banked("ECO_BUILD_ORDER", CLASS_BUILDABLE))
        return order[self.byte("ECO_BUILD_PICK")]

    def walk_the_whole_list(self):
        """Every class the panel will stop on, going round once."""
        seen = []
        self.hold("b")
        for _ in range(3 * CLASS_BUILDABLE):
            seen.append(self.pick_class())
            self.hold(".", frames=20)
        return seen

    def test_it_is_not_on_the_list_before_mission_5(self):
        """Stepped over rather than shown and refused. The panel has room for
        one three-letter tag, so an entry the player can see but cannot order
        looks like a broken ENTER key."""
        self.boot()
        self.assertEqual(self.byte("MIS_INDEX"), 0)
        self.assertNotIn(CLASS_DESTROYER, self.walk_the_whole_list())

    def test_it_is_on_the_list_from_mission_5(self):
        self.boot()
        self.c.write_ram(self.sym["MIS_INDEX"], bytes([CLASS_DESTROYER_MIS]))
        self.assertIn(CLASS_DESTROYER, self.walk_the_whole_list())

    def test_ordering_it_early_is_refused_even_if_the_pick_gets_there(self):
        """The pick is a byte in RAM and the panel is not the only thing that
        moves it -- the orders menu injects keys, and a class that is off the
        list one mission is on it the next. So eco_queue checks as well."""
        self.boot()
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        order = list(self.banked("ECO_BUILD_ORDER", CLASS_BUILDABLE))
        self.c.write_ram(self.sym["ECO_BUILD_PICK"],
                         bytes([order.index(CLASS_DESTROYER)]))
        self.hold("b")
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "a Destroyer went on the slipway in mission 1")
        self.assertEqual(int.from_bytes(
            self.c.read_ram(self.sym["ECO_RU"], 2), "little"), 900,
            "the refused order was still paid for")


class TestBuildingThroughTheUI(ClassFixture):
    """B, then , and . to pick, then ENTER -- the way the player does it."""

    def order(self, ship_class):
        self.c.write_ram(self.sym["ECO_RU"], (900).to_bytes(2, "little"))
        if ship_class == CLASS_DESTROYER:
            self.c.write_ram(self.sym["MIS_INDEX"], bytes([CLASS_DESTROYER_MIS]))
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "the panel did not open")

        order = list(self.banked("ECO_BUILD_ORDER", CLASS_BUILDABLE))
        #  Generous, because every command is edge-triggered and a press the
        #  game did not scan is simply not a press. Going round the list twice
        #  is harmless; giving up after exactly one lap is a flaky test.
        for _ in range(3 * CLASS_BUILDABLE):
            if order[self.byte("ECO_BUILD_PICK")] == ship_class:
                break
            self.hold(".", frames=20)
        else:
            self.fail(f"the panel never offered {NAME[ship_class]}")

        self.hold(cpc.KEY_ENTER)
        return int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")

    def test_every_buildable_class_can_be_ordered_and_costs_what_it_says(self):
        """One boot per class, because a yard that is already busy refuses --
        which is the behaviour, not a way to test seven of them at once."""
        for cls, cost in sorted(SECTION_8_COST.items(), key=lambda kv: kv[1]):
            with self.subTest(ship=NAME[cls]):
                self.boot()
                left = self.order(cls)
                self.assertEqual(self.byte("ECO_BUILD_CLASS"), cls,
                                 f"{NAME[cls]} did not go on the slipway")
                self.assertEqual(900 - left, cost,
                                 f"{NAME[cls]} cost {900 - left}, not {cost}")
                h.close(self.c)
                self.c = None

    def test_the_ship_that_comes_out_is_the_class_that_was_ordered(self):
        """The panel writes eco_build_class and eco_spawn_built reads it, one
        countdown later. Two different fields have been the wrong one before.

        The timer is poked to zero rather than waited out: a Frigate is 120
        GAME frames on the slipway, which at the rate this actually runs is
        the best part of a minute of emulated time, and the countdown is not
        the thing under test."""
        for cls in (CLASS_SCOUT, CLASS_BOMBER, CLASS_FRIGATE, CLASS_DESTROYER):
            with self.subTest(ship=NAME[cls]):
                self.boot()
                before = {s for s in range(48)
                          if self.ent(s, ENT_FLAGS) & F_ACTIVE}
                self.order(cls)
                self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([0]))
                self.c.run_frames(80)

                new = [s for s in range(48)
                       if (self.ent(s, ENT_FLAGS) & F_ACTIVE) and s not in before]
                self.assertEqual(len(new), 1, f"{NAME[cls]}: {len(new)} new ships")
                slot = new[0]
                self.assertEqual(self.ent(slot, ENT_CLASS), cls)
                self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                                 "the slipway did not clear itself")
                h.close(self.c)
                self.c = None

    def test_a_new_ship_gets_its_class_hull_and_not_a_hard_coded_one(self):
        """Section 8 makes the Harvester and the Scout flimsy. eco_spawn_built
        used to write 255 for everything, so 'needs protection' was a comment
        rather than a number."""
        self.boot()
        hull = list(self.banked("CLASS_HULL", CLASS_COUNT))
        self.assertLess(hull[CLASS_SCOUT], hull[CLASS_INTERCEPTOR])

        before = {s for s in range(48) if self.ent(s, ENT_FLAGS) & F_ACTIVE}
        self.order(CLASS_SCOUT)
        self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([0]))
        self.c.run_frames(80)
        slot = next(s for s in range(48)
                    if (self.ent(s, ENT_FLAGS) & F_ACTIVE) and s not in before)
        self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_SCOUT)
        self.assertEqual(self.ent(slot, ENT_HULL), hull[CLASS_SCOUT])


class TestTheBanks(ClassFixture):
    """Where the sprite libraries actually are, in the machine."""

    def test_lib_load_reads_all_three_banks_off_the_disc(self):
        self.boot()
        self.assertEqual(self.byte("LIB_OK"), 1,
                         "the sprite libraries did not come off the disc")

    def test_each_bank_holds_exactly_what_the_build_put_on_the_disc(self):
        """The loader and tools/discbanks.py have to agree about where every
        sector goes, and they only agree because both read LIB_TRACK and
        friends out of the symbol file. A disagreement is not a crash: it is
        a bank full of the wrong ship, which looks like a rendering bug."""
        self.boot()
        for bank, name in ((0xC5, "bank5"), (0xC6, "bank6"), (0xC7, "bank7")):
            with open(os.path.join(BUILD_DIR, f"{name}.raw"), "rb") as f:
                want = f.read()
            self.page_in(bank)
            got = h.read_cpu(self.c, BANK_WINDOW, len(want))
            self.assertEqual(got, want, f"{name} is not what was written")

    def test_every_class_points_into_the_window(self):
        """A sprite address is meaningless without the bank beside it, and the
        two are separate tables. An address outside #4000-#7FFF is a class
        that was linked into the low 16K by mistake."""
        self.boot()
        for cls, tiers in enumerate(self.class_sprite()):
            for tier, addr in enumerate(tiers):
                self.assertTrue(BANK_WINDOW <= addr < BANK_WINDOW + 0x4000,
                                f"{NAME[cls]} tier {tier} is at #{addr:04X}")

    def test_the_two_classes_inside_disc_bin_are_in_bank_4(self):
        """They are the fallback for everything else, so they cannot be
        anywhere that might fail to load."""
        self.boot()
        banks = self.class_bank()
        self.assertEqual(banks[CLASS_INTERCEPTOR], GA_BANK_4)
        self.assertEqual(banks[CLASS_FRIGATE], GA_BANK_4)

    def test_the_window_is_back_on_bank_4_between_frames(self):
        """The single rule the whole arrangement rests on. Bank 4 holds the
        mission table, the fleet buffer and the code for the title screen, the
        help page and the orders menu; anything that pages it out and does not
        put it back leaves the next static screen executing sprite data.

        Checked by reading the mission table through the CPU's view and
        comparing it with the disc image, which only matches if bank 4 is
        under the window."""
        self.boot()
        want = bytes(self.banked("MISSION_TABLE", 12))
        for _ in range(6):
            h.run_to_stable_point(self.c, self.sym)
            self.assertEqual(bytes(self.banked("MISSION_TABLE", 12)), want)
            self.c.run_frames(7)
        self.assertTrue(want.startswith(b"THE TEST"),
                        f"bank 4 is not under the window at all: {want!r}")

    def test_a_frame_with_every_class_in_it_still_leaves_bank_4_up(self):
        """The interesting case, because the draw loop is sorted by depth and
        walks straight from a bank-7 ship to a bank-5 one to a bank-4 one."""
        self.boot()
        base = self.sym["ENTITIES"]
        live = [s for s in range(48) if self.ent(s, ENT_FLAGS) & F_ACTIVE]
        self.assertGreaterEqual(len(live), CLASS_COUNT)
        for i, slot in enumerate(live[:CLASS_COUNT]):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_CLASS, bytes([i]))
        self.c.run_frames(60)
        h.run_to_stable_point(self.c, self.sym)
        self.assertTrue(bytes(self.banked("MISSION_TABLE", 8)).startswith(b"THE TEST"),
                        "bank 4 was left paged out after a mixed-class frame")
        self.assertEqual(self.byte("MIS_FAILED"), 0)


class TestTheFallback(ClassFixture):
    """No disc, no libraries -- and the game still has to draw ships."""

    def test_without_a_disc_the_banked_classes_wear_stand_ins(self):
        """Blitting whatever bank 5 happens to contain is twenty-four sprites
        of noise a frame. Wearing the frigate's hull is a cosmetic loss, and
        it is exactly what the game did before there were eight classes."""
        self.boot(disc=False)
        self.assertEqual(self.byte("LIB_OK"), 0,
                         "a machine with no disc thinks it loaded the libraries")
        banks = self.class_bank()
        self.assertEqual(banks, [GA_BANK_4] * CLASS_COUNT,
                         f"a class is still pointing at a bank that never loaded: {banks}")

    def test_the_stand_in_is_the_class_named_in_the_fallback_table(self):
        self.boot(disc=False)
        fallback = list(self.banked("CLASS_FALLBACK", CLASS_COUNT))
        sprites = self.class_sprite()
        for cls in range(CLASS_COUNT):
            self.assertEqual(sprites[cls], sprites[fallback[cls]],
                             f"{NAME[cls]} does not draw as {NAME[fallback[cls]]}")

    def test_every_stand_in_is_its_own_stand_in(self):
        """class_use_fallback rewrites the tables in place and skips the
        classes that map to themselves, and that is the ONLY reason the order
        it visits them in does not matter. A fallback chain two deep would
        make the result depend on the loop counter."""
        self.boot(disc=False)
        fallback = list(self.banked("CLASS_FALLBACK", CLASS_COUNT))
        for cls, stand_in in enumerate(fallback):
            self.assertEqual(fallback[stand_in], stand_in,
                             f"{NAME[cls]} stands in as {NAME[stand_in]}, "
                             f"which itself stands in as {NAME[fallback[stand_in]]}")

    def test_the_fallback_draws_about_as_much_as_the_real_thing(self):
        """The failure this exists to catch is a fleet of INVISIBLE ships.

        class_use_fallback rewrites two tables in place, and getting it half
        right -- the bank without the address, or the other way round -- gives
        a sprite pointer that resolves to a bank-4 address in a bank that
        never loaded. The blitter draws it perfectly happily and nothing on
        screen moves.

        Compared against the same mission WITH the disc rather than against a
        fixed number, because how much ink there is depends on the zoom, the
        formation and where the camera happens to be pointing."""
        self.boot()
        self.c.run_frames(120)
        with_disc = self.ink()
        h.close(self.c)

        self.boot(disc=False)
        self.c.run_frames(120)
        without = self.ink()

        self.assertGreater(with_disc, 20, "nothing was drawn WITH a disc either")
        self.assertGreater(without, with_disc // 2,
                           f"{without} bytes of ink without a disc against "
                           f"{with_disc} with one -- the stand-ins are not drawing")
        self.assertEqual(self.byte("MIS_FAILED"), 0)

    def ink(self):
        """Bytes of the tactical view that are not empty space."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return sum(1 for y in range(160) for x in range(80)
                   if ram[h.screen_offset(y, x)])


class TestTierBias(ClassFixture):
    """Section 5.1's tiers are a distance ladder, not a size one."""

    def bias(self, ship_class, tier):
        """class_apply_bias(A = tier, B = class)."""
        self.call(self.sym["CLASS_APPLY_BIAS"],
                  setup=bytes([0x3E, tier, 0x06, ship_class]),
                  collect=bytes([0x32, h.RESULT & 0xFF, h.RESULT >> 8]))
        return self.c.read_ram(h.RESULT, 1)[0]

    def test_capitals_draw_a_size_larger_than_their_distance_alone_gives(self):
        """Without it a Mothership at 200 units is exactly as big as a fighter
        at 200 units and the fleet reads as a swarm of identical specks."""
        self.boot()
        for cls in (CLASS_MOTHERSHIP, CLASS_FRIGATE, CLASS_DESTROYER):
            self.assertEqual(self.bias(cls, 0), 1, NAME[cls])
        for cls in (CLASS_INTERCEPTOR, CLASS_SCOUT, CLASS_BOMBER,
                    CLASS_HARVESTER, CLASS_SALVAGE):
            self.assertEqual(self.bias(cls, 0), 0, NAME[cls])

    def test_the_bias_cannot_push_a_class_past_the_largest_tier(self):
        """There is no fourth tier. An unclamped bias walks class_geom off its
        end and blits with somebody else's width."""
        self.boot()
        for cls in range(CLASS_COUNT):
            self.assertLess(self.bias(cls, CLASS_TIERS - 1), CLASS_TIERS,
                            NAME[cls])


if __name__ == "__main__":
    unittest.main()
