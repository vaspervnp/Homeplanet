"""The squadron commands, driven through the real keyboard.

These press keys in the emulator and read the resulting fleet out of the
entity table, so they exercise the whole chain -- matrix scan, edge detection,
command dispatch, squadron logic -- rather than calling the routines directly.
That matters here because the edge triggering is half the specification: a
held key must act once.

The spec being tested:

    1-9  select that squadron, if it has ships
    d    divide the selection in half; the new half takes the next free number
    m    move one ship to the next number, creating it if need be
    n    move one ship to the previous number; for 1 that is 9
    c    combine the selection with the next active squadron
    o    one squadron per ship class
         a squadron left with no ships is deactivated

THE MOVE-ONE-SHIP PAIR IS `K` AND `L`, NOT `M` AND `N`. `M` is the mute now --
one key with one meaning on the title screen and in the game alike -- and a
player who learned it on the menu must not reshape a squadron by pressing it in
a battle. K keeps N's place in the pair: it is left of L exactly as N was left
of M, so the left-hand key is still "back a number".
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Long enough for the game to run several frames with the key down, so a
#  wrongly level-triggered command would fire more than once and be caught.
HOLD_FRAMES = 30


class SquadFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        #  A fresh machine per test: these mutate the fleet, and a shared one
        #  would make the tests order-dependent.
        self.c = h.boot_quick(frames=200)

    def tearDown(self):
        #  Free it now; see harness.close.
        h.close(getattr(self, "c", None))

    def counts(self):
        """Ships per squadron, as squadron 1..9."""
        return list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))[1:]

    def selected(self):
        return self.c.read_ram(self.sym["SQUAD_SEL"], 1)[0]

    def total(self):
        return sum(self.counts())

    def tap(self, key, frames=HOLD_FRAMES):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(frames)

    def hold(self, key, frames=HOLD_FRAMES * 4):
        """Hold a key down for a long time without releasing it."""
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(HOLD_FRAMES)

    def fleet(self):
        """{slot: (squadron, (x, y, z))} for every live ship.

        Keyed by SLOT, so a test can follow one individual ship across a
        command rather than watching a total. Counts are preserved by a swap
        that puts the wrong ships in the wrong squadrons, which is exactly
        what "the squadrons get mixed up" looks like from the player's chair.
        """
        raw = self.c.read_ram(self.sym["ENTITIES"], ENT_MAX * ENT_SIZE)
        out = {}
        for i in range(ENT_MAX):
            b = raw[i * ENT_SIZE:(i + 1) * ENT_SIZE]
            if b[ENT_FLAGS] & F_ACTIVE:
                out[i] = (b[ENT_SQUAD], struct.unpack("<hhh", b[0:6]))
        return out

    def members(self, fleet=None):
        """{squadron: [slot, ...]} -- which ships, not how many."""
        out = {}
        for slot, (squadron, _) in (fleet or self.fleet()).items():
            out.setdefault(squadron, []).append(slot)
        return out

    def station(self, squadron):
        """Where squadron 1..9 is told to form up."""
        raw = self.c.read_ram(self.sym["SQUAD_DEST"] + (squadron - 1) * 6, 6)
        return struct.unpack("<hhh", raw)


ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walked a fixed forty-eight would
#  stop looking exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_CLASS, ENT_FLAGS, ENT_SQUAD = 9, 11, 12
F_ACTIVE = 1
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER = 0, 1, 2
CLASS_BOMBER, CLASS_FRIGATE = 4, 5


def manhattan(a, b):
    return sum(abs(p - q) for p, q in zip(a, b))


def spread(points):
    """The widest the fleet is, on any one axis."""
    return max(max(p[i] for p in points) - min(p[i] for p in points)
               for i in range(3))


class TestInitialState(SquadFixture):

    def test_the_fleet_starts_as_one_squadron(self):
        counts = self.counts()
        self.assertGreater(counts[0], 1, "squadron 1 is empty")
        self.assertEqual(counts[1:], [0] * 8, f"more than one squadron at boot: {counts}")
        self.assertEqual(self.selected(), 1)


class TestDivide(SquadFixture):

    def test_d_splits_the_selection_in_half(self):
        before = self.counts()[0]
        self.tap("d")
        counts = self.counts()
        self.assertEqual(counts[0], before - before // 2, f"{counts}")
        self.assertEqual(counts[1], before // 2, f"{counts}")
        self.assertEqual(self.total(), before, "ships appeared or vanished")

    def test_d_takes_the_next_free_number_each_time(self):
        self.tap("d")                       # 1 -> 1, 2
        self.tap("d")                       # 1 -> 1, 3   (2 is taken)
        counts = self.counts()
        self.assertGreater(counts[2], 0, f"squadron 3 was not created: {counts}")
        self.assertEqual(counts[3:], [0] * 6, f"{counts}")

    def test_d_is_edge_triggered(self):
        """Holding the key must divide once, not once per frame."""
        self.hold("d")
        active = [i + 1 for i, n in enumerate(self.counts()) if n]
        self.assertEqual(active, [1, 2],
                         f"holding d kept dividing: squadrons {active} exist")

    def test_a_single_ship_cannot_be_divided(self):
        #  Strip squadron 1 down to one ship, then try.
        for _ in range(self.counts()[0] - 1):
            self.tap("l")
        self.assertEqual(self.counts()[0], 1, self.counts())
        before = self.counts()
        self.tap("d")
        self.assertEqual(self.counts(), before, "a lone ship was divided")


class TestMoveOne(SquadFixture):

    def test_m_moves_exactly_one_ship_to_the_next_number(self):
        before = self.counts()
        self.tap("l")
        after = self.counts()
        self.assertEqual(after[0], before[0] - 1, f"{before} -> {after}")
        self.assertEqual(after[1], before[1] + 1, f"{before} -> {after}")
        self.assertEqual(sum(after), sum(before))

    def test_m_creates_the_target_squadron(self):
        self.assertEqual(self.counts()[1], 0)
        self.tap("l")
        self.assertEqual(self.counts()[1], 1, "squadron 2 was not created")

    def test_n_moves_to_the_previous_number_and_1_wraps_to_9(self):
        """'For squadron 1 the previous one is the last.'"""
        before = self.counts()
        self.tap("k")
        after = self.counts()
        self.assertEqual(after[0], before[0] - 1, f"{before} -> {after}")
        self.assertEqual(after[8], 1, f"squadron 9 did not receive it: {after}")

    def test_m_is_edge_triggered(self):
        before = self.counts()
        self.hold("l")
        after = self.counts()
        self.assertEqual(after[1], 1,
                         f"holding m moved {after[1]} ships, not 1: {after}")
        self.assertEqual(after[0], before[0] - 1)


class TestDeactivation(SquadFixture):

    def test_a_squadron_emptied_of_ships_is_deactivated(self):
        self.tap("d")                       # 1 and 2 both have ships
        self.tap("2")
        self.assertEqual(self.selected(), 2)

        #  Empty squadron 2 one ship at a time; 'm' sends them on to 3.
        for _ in range(self.counts()[1]):
            self.tap("l")

        self.assertEqual(self.counts()[1], 0, f"squadron 2 still has ships: {self.counts()}")
        self.assertNotEqual(self.selected(), 2,
                            "the selection stayed on a squadron with no ships")

    def test_an_empty_squadron_cannot_be_selected(self):
        self.assertEqual(self.counts()[4], 0, "squadron 5 should not exist yet")
        self.tap("5")
        self.assertEqual(self.selected(), 1, "selected a squadron with no ships")

    def test_every_digit_from_1_to_9_selects_its_own_squadron(self):
        """Guards a bug this suite previously passed straight over.

        The command loop used to derive each digit's key id by counting up
        from KEY_1, which is only right for 1 and 2: the ids are matrix
        positions, and 3 onwards are in different rows. Squadrons 3-9 were
        unreachable and Q, TAB, A and Z selected them instead -- and
        test_an_empty_squadron_cannot_be_selected passed anyway, because it
        pressed '5' and asserted that NOTHING happened.

        So: make every squadron real first, then insist each digit picks its
        own.
        """
        #  Assign the squadrons directly. Pressing 'm' repeatedly would not do
        #  it -- 'm' always moves out of the SELECTION, so eight taps just pile
        #  eight ships into squadron 2. What is under test here is the digit
        #  keys, not how the fleet got spread out.
        ent = self.sym["ENTITIES"]
        for i in range(9):
            self.c.write_ram(ent + i * 20 + 12, bytes([i + 1]))
        counts = [0] * 10
        for i in range(20):
            squadron = i + 1 if i < 9 else 1
            counts[squadron] += 1
        self.c.write_ram(self.sym["SQUAD_COUNT"], bytes(counts))

        counts = self.counts()
        self.assertEqual([n > 0 for n in counts], [True] * 9,
                         f"could not populate every squadron: {counts}")

        for squadron in range(1, 10):
            self.tap(str(squadron), frames=20)
            self.assertEqual(self.selected(), squadron,
                             f"pressing '{squadron}' selected {self.selected()}")

    def test_selecting_an_active_squadron_works(self):
        self.tap("d")
        self.tap("2")
        self.assertEqual(self.selected(), 2)
        self.tap("1")
        self.assertEqual(self.selected(), 1)


class TestCombine(SquadFixture):

    def test_c_merges_the_next_active_squadron_into_the_selection(self):
        self.tap("d")
        before = self.counts()
        self.assertGreater(before[1], 0)

        self.tap("c")
        after = self.counts()
        self.assertEqual(after[0], before[0] + before[1], f"{before} -> {after}")
        self.assertEqual(after[1], 0, "the absorbed squadron is still active")
        self.assertEqual(sum(after), sum(before), "ships appeared or vanished")
        self.assertEqual(self.selected(), 1, "the selection did not survive the merge")

    def test_c_with_nothing_to_merge_does_nothing(self):
        before = self.counts()
        self.tap("c")
        self.assertEqual(self.counts(), before)

    def test_c_skips_gaps_and_takes_the_next_ACTIVE_one(self):
        """Squadrons 1 and 3 exist, 2 does not; c must find 3."""
        self.tap("d")                       # 1, 2
        self.tap("2")
        self.tap("d")                       # 1, 2, 3
        self.tap("1")
        self.tap("c")                       # absorbs 2
        self.tap("c")                       # ...then 3
        counts = self.counts()
        self.assertEqual(counts[1:], [0] * 8, f"not everything merged back: {counts}")
        self.assertEqual(counts[0], self.total())


class TestFleetIsConserved(SquadFixture):

    def test_no_command_ever_creates_or_destroys_a_ship(self):
        total = self.total()
        self.assertGreater(total, 0)
        for key in "dmn2dcnm1dc":
            self.tap(key, frames=20)
            self.assertEqual(self.total(), total,
                             f"after '{key}' the fleet is {self.total()}, was {total}")

    def test_squadron_numbers_stay_in_range(self):
        for key in "dddmmmnnnccc":
            self.tap(key, frames=20)
        sel = self.selected()
        self.assertTrue(1 <= sel <= 9, f"selection is {sel}")
        counts = self.counts()
        self.assertEqual(len(counts), 9)
        self.assertGreater(counts[sel - 1], 0,
                           f"selection {sel} has no ships: {counts}")


if __name__ == "__main__":
    unittest.main()


class TestSplitByClass(SquadFixture):
    """`O`: one squadron per ship class.

    The number is the class index plus one and nothing else, which is what
    makes it worth having -- press it again three missions later and the
    interceptors are squadron 1 again, whatever was lost in between.
    """

    def make_mixed_fleet(self):
        """The starting fleet is all interceptors; give it something to sort."""
        plan = {2: CLASS_BOMBER, 3: CLASS_BOMBER, 4: CLASS_FRIGATE,
                5: CLASS_HARVESTER, 6: CLASS_HARVESTER}
        for slot, cls in plan.items():
            self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_CLASS,
                             bytes([cls]))
        self.c.run_frames(20)
        return plan

    def test_each_class_gets_its_own_squadron(self):
        plan = self.make_mixed_fleet()
        before = self.total()
        self.tap("o")
        counts = self.counts()                      # index 0 is squadron 1
        self.assertEqual(self.total(), before, "ships appeared or vanished")
        self.assertEqual(counts[CLASS_BOMBER], 2, f"the bombers are not together: {counts}")
        self.assertEqual(counts[CLASS_FRIGATE], 1, f"the frigate is misfiled: {counts}")
        self.assertEqual(counts[CLASS_HARVESTER], 2, f"the harvesters are not together: {counts}")
        self.assertEqual(counts[CLASS_INTERCEPTOR],
                         before - len(plan),
                         f"the interceptors did not keep squadron 1: {counts}")

    def test_the_mothership_is_left_out_and_so_is_its_number(self):
        """It is not part of the fleet, it is what the fleet is for -- and
        squadron 2, the number its class index would claim, stays empty."""
        self.make_mixed_fleet()
        self.tap("o")
        self.assertEqual(self.counts()[CLASS_MOTHERSHIP], 0,
                         "the Mothership was dragged into a squadron")

        moth = self.c.read_ram(self.sym["MOTH_SLOT"], 1)[0]
        squad = self.c.read_ram(self.sym["ENTITIES"] + moth * ENT_SIZE + 12, 1)[0]
        self.assertEqual(squad, 0, "the Mothership now belongs to a squadron")

    def test_the_numbers_are_the_same_the_second_time(self):
        """A class with no ships leaves its number empty rather than everything
        shuffling up: numbers that move between missions are worse than numbers
        with gaps in them."""
        self.make_mixed_fleet()
        self.tap("o")
        first = self.counts()
        self.tap("d")                               # scramble it
        self.tap("l")
        self.tap("o")
        self.assertEqual(self.counts(), first, "the numbering moved under the player")

    def test_it_is_edge_triggered(self):
        self.make_mixed_fleet()
        self.tap("o")
        before = self.counts()
        self.hold("o")
        self.assertEqual(self.counts(), before, "holding o did something the second time")

    def test_the_selection_still_means_something_afterwards(self):
        self.make_mixed_fleet()
        self.tap("o")
        sel = self.selected()
        self.assertGreater(self.counts()[sel - 1], 0,
                           f"squadron {sel} is selected and empty")


class TestWhichShipsEndUpWhere(SquadFixture):
    """The reshaping commands, asserted on ENT_SQUAD across every slot.

    Every other test in this file asserts on SQUAD_COUNT, and a count is
    preserved by a swap that puts the wrong ships in the wrong squadrons --
    which is precisely what a player means by "the squadrons get mixed up".
    So these follow individual ships, by slot, across each command, and say
    what each command is allowed to touch.
    """

    def step(self, key):
        """Press one key; return (selection before, {slot: (from, to)})."""
        before, sel = self.fleet(), self.selected()
        self.tap(key, frames=20)
        after = self.fleet()
        self.assertEqual(sorted(before), sorted(after),
                         f"'{key}' created or destroyed a ship")
        return sel, {slot: (before[slot][0], after[slot][0])
                     for slot in before if before[slot][0] != after[slot][0]}

    def test_m_moves_one_named_ship_and_touches_nothing_else(self):
        sel, moved = self.step("l")
        self.assertEqual(len(moved), 1, f"'m' moved {len(moved)} ships: {moved}")
        self.assertEqual(list(moved.values())[0], (sel, sel + 1), moved)

    def test_n_moves_one_named_ship_and_1_wraps_to_9(self):
        sel, moved = self.step("k")
        self.assertEqual(len(moved), 1, f"'n' moved {len(moved)} ships: {moved}")
        self.assertEqual(list(moved.values())[0], (1, 9), moved)

    def test_d_peels_half_of_one_squadron_into_one_empty_number(self):
        held = len(self.members()[1])
        sel, moved = self.step("d")
        self.assertEqual(len(moved), held // 2,
                         f"'d' moved {len(moved)} of {held}: {moved}")
        self.assertEqual({a for a, _ in moved.values()}, {sel},
                         f"'d' took ships out of a squadron it was not given: {moved}")
        self.assertEqual(len({b for _, b in moved.values()}), 1,
                         f"'d' scattered the half it peeled: {moved}")

    def test_c_absorbs_one_whole_squadron_and_no_part_of_another(self):
        self.tap("d")
        self.tap("2")
        self.tap("d")                       # 1, 2 and 3 all have ships
        self.tap("1")
        members = self.members()
        sel, moved = self.step("c")
        sources = {a for a, _ in moved.values()}
        self.assertEqual(len(sources), 1, f"'c' emptied more than one squadron: {moved}")
        source = sources.pop()
        self.assertEqual(sorted(moved), sorted(members[source]),
                         f"'c' left part of squadron {source} behind: {moved}")
        self.assertEqual({b for _, b in moved.values()}, {sel}, moved)

    def test_selecting_never_moves_a_ship(self):
        self.tap("d")
        self.tap("2")
        self.tap("d")
        for digit in "123456789":
            _, moved = self.step(digit)
            self.assertEqual(moved, {}, f"pressing '{digit}' reassigned ships")

    def test_a_long_sequence_leaves_every_ship_accounted_for(self):
        """No ship may end up in a squadron the HUD does not list, and the
        derived counts must agree with the table they are derived from."""
        for key in "dmn2dcnm1dc":
            self.tap(key, frames=20)
            fleet = self.fleet()
            tally = [0] * 10
            for squadron, _ in fleet.values():
                self.assertTrue(0 <= squadron <= 9,
                                f"after '{key}' a ship is in squadron {squadron}")
                tally[squadron] += 1
            self.assertEqual(self.counts(), tally[1:],
                             f"after '{key}' squad_count disagrees with ENT_SQUAD")


class TestANewSquadronIsBornWhereItsShipsAre(SquadFixture):
    """The bug the player reported as "selecting squadrons mixes them up".

    squad_dest held nine FIXED stations, copied out of order_home at boot and
    scattered up to 6000 units apart. Only squadron 1's was ever anywhere near
    the fleet, because that is where the fleet is spawned. So the instant a
    reshaping command put a ship into any other number, that ship was told to
    form up at a point it had never been sent to and flew off across the map
    -- half the fleet peeling away from the other half for no reason the
    player could see.

    The rule now: a squadron that is created takes its station from the ship
    that created it and its formation from the squadron that ship left. An
    empty squadron has no station; it acquires one by being made.
    """

    #  A settled Loose squadron is 6 * FORM_SPACING across -- the lattice runs
    #  -3 to +3 spacings on two axes (game/formdata.asm) -- and every figure
    #  below is measured against that rather than guessed. The distances the
    #  bug produced are 4500 to 11400 units, so none of this is a fine
    #  judgement; against HEAD the four tests here fail by 2x to 4x.
    FORM_SPACING = 550
    SQUADRON_SPAN = 6 * FORM_SPACING            # 3300

    def flying(self):
        """Every ship in a squadron -- the Mothership holds station and is
        deliberately in none, so it is not part of "the fleet moved"."""
        return [p for squadron, p in self.fleet().values() if squadron]

    def settle(self):
        """Let the fleet unpack into its formation before measuring it."""
        self.c.run_frames(600)

    def assert_stationed_on_its_own_ships(self, squadron):
        here = [p for s, p in self.fleet().values() if s == squadron]
        self.assertTrue(here, f"squadron {squadron} has no ships")
        near = min(manhattan(self.station(squadron), p) for p in here)
        self.assertLessEqual(
            near, self.SQUADRON_SPAN,
            f"squadron {squadron} is stationed at {self.station(squadron)}, "
            f"{near} units from the nearest of its own ships {here}")

    def test_a_squadron_made_by_d_is_stationed_where_its_ships_are(self):
        self.tap("d")
        members = self.members()
        new = [s for s in members if s not in (0, 1)]
        self.assertEqual(len(new), 1, f"expected one new squadron: {members}")
        self.assert_stationed_on_its_own_ships(new[0])

    def test_a_squadron_made_by_m_or_n_is_stationed_where_its_ship_is(self):
        """One ship, alone. 'm' creates squadron 2 and 'n' creates squadron 9,
        whose fixed stations were 4500 and 6000 units away in opposite
        directions -- so the ship left the screen on its own."""
        self.tap("l")
        self.assert_stationed_on_its_own_ships(2)
        self.tap("k")
        self.assert_stationed_on_its_own_ships(9)

    def test_a_squadron_made_by_O_is_stationed_where_its_ships_are(self):
        """`O` writes ENT_SQUAD without going through squad_move_ship, so it
        had the same defect -- invisible only because the starting fleet is
        all interceptors and therefore all still squadron 1."""
        for slot, cls in {2: CLASS_BOMBER, 3: CLASS_BOMBER,
                          5: CLASS_HARVESTER}.items():
            self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_CLASS,
                             bytes([cls]))
        self.settle()
        self.tap("o")
        for squadron in (CLASS_BOMBER + 1, CLASS_HARVESTER + 1):
            self.assert_stationed_on_its_own_ships(squadron)

    def test_dividing_does_not_tear_the_fleet_in_half(self):
        self.settle()
        was = spread(self.flying())
        self.tap("d")
        self.c.run_frames(900)              # long enough to fly a long way
        now = spread(self.flying())
        self.assertLessEqual(
            now, was + self.SQUADRON_SPAN,
            f"the fleet was {was} units across and is {now} after 'd'")

    def test_it_holds_after_the_squadron_has_been_moved(self):
        """The play scenario, and the worst case. The fixed stations were near
        the origin, so once the player had taken the fleet somewhere the new
        half was called all the way back -- 11400 units, right off the screen.
        """
        #  ENTER opens the move disc, the cursor keys drive it, ENTER confirms.
        self.tap(cpc.KEY_ENTER, frames=20)
        self.assertEqual(self.c.read_ram(self.sym["DISC_ACTIVE"], 1)[0], 1,
                         "the move disc did not open")
        self.c.key_down(cpc.KEY_RIGHT)
        self.c.run_frames(300)
        self.c.key_up(cpc.KEY_RIGHT)
        self.c.run_frames(20)
        self.tap(cpc.KEY_ENTER, frames=20)
        self.c.run_frames(900)              # let the squadron get there

        was = spread(self.flying())
        self.tap("d")
        self.c.run_frames(900)
        now = spread(self.flying())
        self.assertLessEqual(
            now, was + self.SQUADRON_SPAN,
            f"the fleet was {was} units across and is {now} after 'd'")

    def test_the_new_half_keeps_the_formation_it_peeled_off_in(self):
        """game/formation.asm has said so since it was written: 'Splitting a
        squadron gives the new half the same shape, which is what you would
        expect of ships peeling off in formation.'"""
        self.tap("f")                       # squadron 1 out of Loose
        shape = self.c.read_ram(self.sym["SQUAD_FORM"] + 1, 1)[0]
        self.assertNotEqual(shape, 0, "'f' did not change the formation")
        self.tap("d")
        new = [s for s in self.members() if s not in (0, 1)][0]
        self.assertEqual(self.c.read_ram(self.sym["SQUAD_FORM"] + new, 1)[0], shape,
                         f"squadron {new} peeled off in a different formation")
