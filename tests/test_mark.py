"""The world points that are not ships: the resource fields and the Mothership
indicator.

Both go through gfx/mark.asm, and the reason they share it is that they are
the same problem -- project a fixed world point, draw a handful of pixels,
record a rectangle. The tests here read PENS off the framebuffer rather than
counting lit bytes, because the whole of item 3's design decision is WHICH ink
a patch is drawn in.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

MIS_SIZE = 20
MIS_PATCH_COUNT = 15
MIS_COUNT = 8

ECO_PATCH_SIZE = 8


def decode_mode1(byte: int) -> list[int]:
    """One Mode 1 byte -> four pens. A B C D pack as A0 B0 C0 D0 A1 B1 C1 D1."""
    return [((byte >> (7 - p)) & 1) | (((byte >> (3 - p)) & 1) << 1)
            for p in range(4)]


class MarkFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=400)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # ---- reading -----------------------------------------------------------

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def signed(self, name):
        return struct.unpack("<b", bytes(self.c.read_ram(self.sym[name], 1)))[0]

    def word(self, name):
        return int.from_bytes(self.c.read_ram(self.sym[name], 2), "little")

    def markers(self):
        """The marker cache: (sx, sy, tag), tag 0 = the plane, n = patch n-1."""
        n = self.byte("MARK_COUNT")
        raw = self.c.read_ram(self.sym["MARK_CACHE"], n * 4)
        return [(raw[i * 4] | (raw[i * 4 + 1] << 8), raw[i * 4 + 2], raw[i * 4 + 3])
                for i in range(n)]

    def stock(self, i):
        return int.from_bytes(
            self.c.read_ram(self.sym["ECO_PATCHES"] + i * ECO_PATCH_SIZE + 6, 2),
            "little")

    def pens_around(self, sx, sy, w_bytes=3, h_lines=5):
        """Every pen in a small box centred on a pixel position."""
        base = h.front_buffer(self.c)
        x0 = max(0, (sx >> 2) - 1)
        out = []
        for y in range(max(0, sy - 2), min(200, sy + h_lines - 2)):
            for x in range(x0, min(80, x0 + w_bytes)):
                out += decode_mode1(h.peek_pixel_byte(self.c, base, y, x))
        return out

    def pan(self, x, y, z):
        self.c.write_ram(self.sym["CAM_PAN"], struct.pack("<hhh", x, y, z))
        self.c.run_frames(40)

    def press(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(30)


class TestEveryMissionFieldsResources(MarkFixture):
    """Section 7's economy is meant to be a running choice, and a choice that
    only exists in five missions out of eight is not one."""

    def test_no_mission_fields_none(self):
        base = self.sym["MISSION_TABLE"]
        for m in range(MIS_COUNT):
            n = h.read_bank4(self.c, base + m * MIS_SIZE + MIS_PATCH_COUNT, 1)[0]
            self.assertGreater(n, 0, f"mission {m + 1} fields no resource patches")

    def test_the_first_mission_actually_lays_them_out(self):
        stocked = [i for i in range(4) if self.stock(i)]
        self.assertGreaterEqual(len(stocked), 2,
                                "the mission put nothing in the patch table")


class TestThePatchesAreDrawn(MarkFixture):

    def cached_patches(self):
        return [(sx, sy, tag - 1) for sx, sy, tag in self.markers() if tag]

    def test_a_stocked_patch_is_drawn_in_ink_2(self):
        """Ink 2 is the scenery ink: a field with something in it is scenery.
        Spending ink 3 on it would make it read as a hostile."""
        drawn = 0
        for sx, sy, i in self.cached_patches():
            if not self.stock(i):
                continue
            self.assertIn(2, self.pens_around(sx, sy),
                          f"patch {i} at ({sx},{sy}) drew nothing in ink 2")
            drawn += 1
        self.assertGreater(drawn, 0, "no patch was both stocked and on screen")

    def test_a_patch_running_out_is_drawn_in_ink_1(self):
        """The attention ink, because a field about to run dry is exactly when
        the player has to send the harvesters somewhere else."""
        patches = [(sx, sy, i) for sx, sy, i in self.cached_patches() if self.stock(i)]
        self.assertTrue(patches, "nothing to run down")
        sx, sy, i = patches[0]

        low = self.sym["MARK_PATCH_LOW"] if "MARK_PATCH_LOW" in self.sym else 100
        self.c.write_ram(self.sym["ECO_PATCHES"] + i * ECO_PATCH_SIZE + 6,
                         struct.pack("<H", max(1, low // 2)))
        self.c.run_frames(40)
        pens = self.pens_around(sx, sy)
        self.assertIn(1, pens, f"the nearly-empty patch at ({sx},{sy}) is not white")

    def test_a_mined_out_patch_is_not_drawn_at_all(self):
        """Which also disposes of the empty slots: mis_setup zeroes the ones a
        mission does not use, and a stock of nothing is what "no field here"
        means."""
        patches = [(sx, sy, i) for sx, sy, i in self.cached_patches() if self.stock(i)]
        sx, sy, i = patches[0]
        before = sum(1 for p in self.pens_around(sx, sy) if p)
        self.c.write_ram(self.sym["ECO_PATCHES"] + i * ECO_PATCH_SIZE + 6, b"\0\0")
        self.c.run_frames(60)
        after = sum(1 for p in self.pens_around(sx, sy) if p)
        self.assertLess(after, before,
                        f"the exhausted patch at ({sx},{sy}) is still drawn")

    def test_the_ink_follows_the_stock_without_the_camera_moving(self):
        """The projection is cached against a camera hash; the INK must not be,
        because the stock runs down while the camera sits still."""
        shadow = self.byte("MARK_SHADOW")
        patches = [(sx, sy, i) for sx, sy, i in self.cached_patches() if self.stock(i)]
        sx, sy, i = patches[0]
        self.c.write_ram(self.sym["ECO_PATCHES"] + i * ECO_PATCH_SIZE + 6, b"\x10\0")
        self.c.run_frames(40)
        self.assertEqual(self.byte("MARK_SHADOW"), shadow,
                         "the camera moved; this test proves nothing")
        self.assertIn(1, self.pens_around(sx, sy),
                      "the ink did not follow the stock down")

    def test_the_patches_are_in_the_sensor_view_too(self):
        """Section 9's sensor view is where the long transits happen, and
        'is there anything out there to mine' is what it exists to answer."""
        before = [(sx, sy, i) for sx, sy, i in self.cached_patches() if self.stock(i)]
        self.press("s")
        self.c.run_frames(60)
        self.assertEqual(self.byte("VIEW_SENSORS"), 1)
        for sx, sy, i in before:
            self.assertTrue(set(self.pens_around(sx, sy)) & {1, 2},
                            f"patch {i} vanished in the sensor view")


class TestTheMothershipIndicator(MarkFixture):

    def test_there_is_none_while_the_mothership_is_on_screen(self):
        self.assertEqual(self.signed("MOTH_BAR"), 0,
                         "an indicator for a Mothership that is right there")

    def test_panning_away_puts_a_marker_on_the_edge(self):
        self.pan(-12000, 0, 0)
        self.assertNotEqual(self.signed("MOTH_BAR"), 0, "no indicator appeared")
        x = self.word("MOTH_X")
        self.assertGreater(x, 240, f"the marker is at x={x}, not against an edge")

    def test_the_bearing_mirrors(self):
        """The bug this catches: 160 + dx' is SIGNED, and a clamp that treated
        the high byte as unsigned put the left-hand marker on the right."""
        self.pan(-12000, 0, 0)
        right = self.word("MOTH_X")
        self.pan(12000, 0, 0)
        left = self.word("MOTH_X")
        self.assertGreater(right, 240, f"right pan gave x={right}")
        self.assertLess(left, 80, f"left pan gave x={left}")

    def test_it_is_drawn_in_ink_2(self):
        """A navigation aid, not an alarm."""
        self.pan(-12000, 0, 0)
        pens = self.pens_around(self.word("MOTH_X"), self.byte("MOTH_Y"),
                                w_bytes=2, h_lines=6)
        self.assertIn(2, pens, "the indicator drew nothing in ink 2")
        self.assertNotIn(3, pens, "the indicator is in the alarm ink")

    def test_the_height_bar_says_which_way(self):
        moth = self.byte("MOTH_SLOT")
        ent = self.sym["ENTITIES"] + moth * 20
        for y, expected in ((6000, 1), (-6000, -1)):
            self.c.write_ram(ent + 2, struct.pack("<h", y))
            self.pan(-12000, 0, 0)
            #  The projection is cached, so make sure it has been redone.
            self.c.write_ram(self.sym["MARK_SHADOW"], b"\xfe")
            self.c.run_frames(40)
            bar = self.signed("MOTH_BAR")
            self.assertEqual((bar > 0) - (bar < 0), expected,
                             f"the Mothership at y={y} gave a bar of {bar}")
            self.assertGreater(abs(bar), 1, "the bar has no length")

    def test_it_goes_away_again(self):
        self.pan(-12000, 0, 0)
        self.assertNotEqual(self.signed("MOTH_BAR"), 0)
        self.pan(0, 0, 0)
        self.assertEqual(self.signed("MOTH_BAR"), 0,
                         "the indicator stayed up with the Mothership on screen")

    def test_the_markers_leave_no_residue(self):
        """Everything drawn here records a dirty rectangle, and this is what
        says so: pan a long way and the old edge must come back to black."""
        self.pan(-12000, 0, 0)
        old_x, old_y = self.word("MOTH_X"), self.byte("MOTH_Y")
        self.pan(12000, 0, 0)
        self.c.run_frames(40)
        new_x = self.word("MOTH_X")
        self.assertNotEqual(old_x, new_x)
        self.assertEqual(set(self.pens_around(old_x, old_y, w_bytes=2, h_lines=6)),
                         {0}, "the old indicator was left on the screen")


if __name__ == "__main__":
    unittest.main()
