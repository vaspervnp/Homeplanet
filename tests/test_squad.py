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
         a squadron left with no ships is deactivated
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

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
            self.tap("m")
        self.assertEqual(self.counts()[0], 1, self.counts())
        before = self.counts()
        self.tap("d")
        self.assertEqual(self.counts(), before, "a lone ship was divided")


class TestMoveOne(SquadFixture):

    def test_m_moves_exactly_one_ship_to_the_next_number(self):
        before = self.counts()
        self.tap("m")
        after = self.counts()
        self.assertEqual(after[0], before[0] - 1, f"{before} -> {after}")
        self.assertEqual(after[1], before[1] + 1, f"{before} -> {after}")
        self.assertEqual(sum(after), sum(before))

    def test_m_creates_the_target_squadron(self):
        self.assertEqual(self.counts()[1], 0)
        self.tap("m")
        self.assertEqual(self.counts()[1], 1, "squadron 2 was not created")

    def test_n_moves_to_the_previous_number_and_1_wraps_to_9(self):
        """'For squadron 1 the previous one is the last.'"""
        before = self.counts()
        self.tap("n")
        after = self.counts()
        self.assertEqual(after[0], before[0] - 1, f"{before} -> {after}")
        self.assertEqual(after[8], 1, f"squadron 9 did not receive it: {after}")

    def test_m_is_edge_triggered(self):
        before = self.counts()
        self.hold("m")
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
            self.tap("m")

        self.assertEqual(self.counts()[1], 0, f"squadron 2 still has ships: {self.counts()}")
        self.assertNotEqual(self.selected(), 2,
                            "the selection stayed on a squadron with no ships")

    def test_an_empty_squadron_cannot_be_selected(self):
        self.assertEqual(self.counts()[4], 0, "squadron 5 should not exist yet")
        self.tap("5")
        self.assertEqual(self.selected(), 1, "selected a squadron with no ships")

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
