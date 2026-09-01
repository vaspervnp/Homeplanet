"""Consolidating overlapping distant ships (todo item 3).

At the wide end of the zoom ladder a squadron is a handful of pixels, and a
dozen ships drawn on top of each other look exactly like one ship. phase4_group
gathers them and phase4_draw_count writes "+n" beside the survivor.

Two of these drive the routines directly with a hand-built visible list, which
is the only way to say anything definite about grouping: the running game does
not tell you which ships joined which group, only how many each survivor
speaks for.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tools import gentables as g

#  Mirrored from src/demo/phase4.asm.
VIS_SIZE = 6
ENEMY_BIT = 0x80
PEN_WHITE = 1
PEN_RED = 3


def vis_entry(sx, sy, z, view, ship_class, tier, enemy=False):
    return struct.pack("<HBBBB", sx, sy, z, view,
                       (ENEMY_BIT if enemy else 0) | (ship_class << 2) | tier)


class GroupFixture(unittest.TestCase):
    """A booted machine, with the ability to hand-build a visible list."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=250)
        cls.sym = h.symbols()

    def call(self, symbol, setup=b"", frames=2):
        addr = self.sym[symbol]
        stub = b"\xF3" + setup + bytes([0xCD, addr & 0xFF, addr >> 8, 0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(frames)

    def load_vis(self, entries, zoom=None):
        """Put `entries` in phase4_vis, in z order, at the given zoom step.

        AN ORDER ENTRY IS TWO BYTES -- the index, and a copy of its depth --
        since phase4_sort stopped fetching the depth through phase4_vis_addr
        for every comparison. Written as one byte a piece this reads every
        other entry as a depth, so phase4_group walked half the list at
        double stride and every grouping test came out with singletons.
        """
        self.c.write_ram(self.sym["PHASE4_VIS"], b"".join(entries))
        order = bytearray()
        for i, entry in enumerate(entries):
            order += bytes([i, entry[3]])           # index, then its depth
        self.c.write_ram(self.sym["PHASE4_ORDER"], bytes(order))
        self.c.write_ram(self.sym["PHASE4_VISIBLE"], bytes([len(entries)]))
        if zoom is not None:
            self.c.write_ram(self.sym["CAM_ZOOM"], bytes([zoom]))

    def gcounts(self, n):
        return list(self.c.read_ram(self.sym["PHASE4_GCOUNT"], n))


class TestGrouping(GroupFixture):

    #  Far enough apart that nothing can merge: the threshold is the label's
    #  own size, three characters by one.
    APART = 64

    def test_a_stack_of_one_class_becomes_one_sprite_and_a_count(self):
        """The whole point: n ships on one spot draw once, and say so."""
        self.load_vis([vis_entry(160 + i, 100, 200, 0, 0, 0) for i in range(6)],
                      zoom=len(g.ZOOM_STEPS) - 1)
        self.call("PHASE4_GROUP")
        counts = self.gcounts(6)
        self.assertEqual([c for c in counts if c], [6],
                         f"six ships on one spot did not become one group: {counts}")

    def test_no_ship_is_lost_or_invented(self):
        """The counts must add up to the fleet, whatever the arrangement.

        This is the property that makes a consolidated view trustworthy. A
        group that dropped a member, or a member that stayed drawable AND was
        counted, would both show here -- and either one is a fleet strength
        the player cannot rely on.
        """
        entries = []
        for i in range(12):
            entries.append(vis_entry(40 + (i % 3) * self.APART,
                                     30 + (i // 6) * self.APART,
                                     200, 0, i % 2, 0))
        self.load_vis(entries, zoom=len(g.ZOOM_STEPS) - 1)
        self.call("PHASE4_GROUP")
        counts = self.gcounts(12)
        self.assertEqual(sum(counts), 12, f"the counts do not add up: {counts}")

    def test_the_two_sides_are_never_one_group(self):
        """Section 2's palette: a count in one ink cannot speak for both.

        Four ships of one class on one spot, two friendly and two hostile. The
        proximity test alone would make that a single group of four, which
        would be a lie about the balance of a fight -- so the side is part of
        the key.
        """
        self.load_vis([
            vis_entry(160, 100, 200, 0, 0, 0, enemy=False),
            vis_entry(161, 100, 200, 0, 0, 0, enemy=True),
            vis_entry(162, 100, 200, 0, 0, 0, enemy=False),
            vis_entry(163, 100, 200, 0, 0, 0, enemy=True),
        ], zoom=len(g.ZOOM_STEPS) - 1)
        self.call("PHASE4_GROUP")
        counts = self.gcounts(4)
        self.assertEqual(sorted(c for c in counts if c), [2, 2],
                         f"the sides were merged: {counts}")

    def test_classes_are_not_merged_either(self):
        """Section 5.1 gives every class its own silhouette; a group has one."""
        self.load_vis([
            vis_entry(160, 100, 200, 0, 0, 0),
            vis_entry(161, 100, 200, 0, 3, 0),
            vis_entry(162, 100, 200, 0, 0, 0),
        ], zoom=len(g.ZOOM_STEPS) - 1)
        self.call("PHASE4_GROUP")
        counts = self.gcounts(3)
        self.assertEqual(sorted(c for c in counts if c), [1, 2],
                         f"two classes became one group: {counts}")

    def test_ships_further_apart_than_a_label_stay_separate(self):
        """The merge distance IS the label's size, and that is load-bearing.

        Two groups closer together than "+nn" is wide would draw their counts
        over each other -- which the first version of this did, and the
        screenshot read "++7". Making the threshold the label's own size is
        what rules that out by construction rather than by luck.
        """
        self.load_vis([
            vis_entry(60, 100, 200, 0, 0, 0),
            vis_entry(61, 100, 200, 0, 0, 0),
            vis_entry(60 + self.APART, 100, 200, 0, 0, 0),
            vis_entry(61 + self.APART, 100, 200, 0, 0, 0),
        ], zoom=len(g.ZOOM_STEPS) - 1)
        self.call("PHASE4_GROUP")
        counts = self.gcounts(4)
        self.assertEqual(sorted(c for c in counts if c), [2, 2],
                         f"two stacks a screen apart were merged: {counts}")

    def test_nothing_is_consolidated_at_the_old_zoom_steps(self):
        """Below CAM_ZOOM_GROUP_FROM the picture must be what it always was.

        The four steps that were already there are not "wide zoom" and were
        never asked to be summarised; a fleet that suddenly drew as one sprite
        at the default view would be a regression dressed as a feature.
        """
        for zoom in range(g.ZOOM_GROUP_FROM):
            self.load_vis([vis_entry(160 + i, 100, 200, 0, 0, 0) for i in range(6)],
                          zoom=zoom)
            self.call("PHASE4_GROUP")
            self.assertEqual(self.gcounts(6), [1] * 6,
                             f"zoom step {zoom} consolidated the fleet")


class TestCountLabel(GroupFixture):
    """phase4_draw_count -- the "+n" itself."""

    def setUp(self):
        #  Somewhere with nothing else on it, and a rectangle slot to widen.
        self.rects = self.sym["PHASE4_RECTS_A"]
        self.c.write_ram(self.sym["PHASE4_RECT_PTR"],
                         struct.pack("<H", self.rects + 4))
        self.c.write_ram(self.rects, bytes([20, 96, 2, 6]))

    def _draw(self, count, enemy):
        #  The BACK buffer: txt_draw writes where the next flip will show, and
        #  the game is stopped at our stub so nothing is going to flip it.
        base = self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0] << 8
        #  Blank the patch first. txt_draw_char ORs its glyph in, so a second
        #  reading taken over the first would be measuring both inks at once.
        for y in range(96, 104):
            self.c.write_ram(base + h.screen_offset(y, 24), bytes(8))
        self.load_vis([vis_entry(84, 100, 200, 0, 0, 0, enemy=enemy)])
        self.c.write_ram(self.sym["PHASE4_GRP_I"], b"\x00")
        self.c.write_ram(self.sym["PHASE4_GRP_N"], bytes([count]))
        self.call("PHASE4_DRAW_COUNT")
        pix = self.c.decode_screen_ram(base)
        return [row[96:96 + 6 * 4] for row in pix[96:104]]

    def _pens(self, rows):
        from collections import Counter
        c = Counter()
        for row in rows:
            c.update(row)
        return c

    def test_a_friendly_count_is_white_and_a_hostile_one_is_red(self):
        """Section 2 makes the ink the meaning; the count inherits its group's.

        Counted rather than eyeballed, and both cases drawn at the same place
        with the same glyphs, so the only difference between the two readings
        is the ink -- which separates "not coloured" from "not drawn".
        """
        friendly = self._pens(self._draw(7, enemy=False))
        hostile = self._pens(self._draw(7, enemy=True))

        self.assertGreater(friendly[PEN_WHITE], 0, "the friendly count drew nothing")
        self.assertEqual(friendly[PEN_RED], 0, "a friendly count in the alarm ink")
        self.assertGreater(hostile[PEN_RED], 0, "the hostile count is not red")
        self.assertEqual(hostile[PEN_WHITE], 0, "the hostile count is still white")
        self.assertEqual(friendly[PEN_WHITE], hostile[PEN_RED],
                         "the two inks did not draw the same glyphs")

    def test_the_label_is_inside_a_dirty_rectangle(self):
        """Anything drawn must be erasable, or it smears.

        The label takes no rectangle slot of its own -- it widens the sprite's,
        because a slot per entity in two buffers is 384 bytes the low 16K does
        not have. So the thing to check is that the widened rectangle really
        does reach over the text.
        """
        self._draw(12, enemy=False)
        x, y, w, hh = self.c.read_ram(self.rects, 4)

        #  Where phase4_draw_count puts it: three bytes right of the ship's
        #  centre, half a glyph up. Two digits, so three characters wide.
        label_x = 84 // 4 + 3
        label_y = 100 - 4
        self.assertLessEqual(x, label_x, "the rectangle starts right of the label")
        self.assertGreaterEqual(x + w, label_x + 3 * 2,
                                "the rectangle stops before the label ends")
        self.assertLessEqual(y, label_y, "the rectangle starts below the label")
        self.assertGreaterEqual(y + hh, label_y + 8,
                                "the rectangle stops above the label's last row")

        #  ...and it must still cover the sprite it was written for.
        self.assertLessEqual(x, 20)
        self.assertGreaterEqual(y + hh, 96 + 6)


if __name__ == "__main__":
    unittest.main()
