"""The HUD's button icons: tools/hudicons.py writes the sheet the owner
repaints, and what it writes has to read back as what was drawn."""
import os
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import hudicons  # noqa: E402
import spritemap  # noqa: E402


class TestThePictures(unittest.TestCase):

    def test_every_icon_is_sixteen_square_in_the_five_indices(self):
        pics = hudicons.pictures()
        self.assertEqual(len(pics), len(hudicons.ICONS))
        for name, g in pics.items():
            self.assertEqual((len(g), len(g[0])), (16, 16), name)
            self.assertTrue(all(0 <= v <= 4 for row in g for v in row), name)

    def test_every_caption_fits_the_top_strips_line(self):
        """The description and its key in parentheses, in the game's
        uppercase font, on one forty-character line."""
        for name, label, desc, key, group, _ in hudicons.ICONS:
            cap = hudicons.caption(name)
            self.assertLessEqual(len(cap), hudicons.DESC_CHARS, cap)
            self.assertEqual(cap, cap.upper(), cap)
            self.assertTrue(all(32 <= ord(c) <= 90 for c in cap), f"{cap}: outside the font")
            if key:
                self.assertTrue(cap.endswith(f"({key})"), cap)
            if not name.startswith("frame"):
                self.assertTrue(desc, f"{name} has no description")

    def test_every_label_is_short_unique_and_in_the_tiny_font(self):
        labels = [l for _, l, _, _, _, _ in hudicons.ICONS]
        self.assertEqual(len(labels), len(set(labels)))
        for l in labels:
            self.assertTrue(0 < len(l) <= 6, l)
            self.assertTrue(all(c in hudicons.TINY for c in l), l)
            self.assertLessEqual(len(l) * hudicons.TINY_PITCH - 1, hudicons.W + hudicons.GAP, l)

    def test_names_are_unique_and_the_mirrors_resolve(self):
        names = [n for n, _, _, _, _, _ in hudicons.ICONS]
        self.assertEqual(len(names), len(set(names)))
        pics = hudicons.pictures()
        self.assertEqual(pics["target_prev"], [row[::-1] for row in pics["target_next"]])
        self.assertEqual(pics["ship_prev"], [row[::-1] for row in pics["ship_next"]])

    def test_every_icon_but_the_frames_draws_something_and_leaves_the_edge(self):
        """A one-pixel margin all round is where the selection frame goes; an
        icon that reaches the edge would be overdrawn by it."""
        for name, g in hudicons.pictures().items():
            if name.startswith("frame"):
                continue
            self.assertTrue(any(v for row in g for v in row), f"{name} is blank")
            edge = g[0] + g[15] + [row[0] for row in g] + [row[15] for row in g]
            self.assertFalse(any(edge), f"{name} touches the cell's edge")

    def test_the_frames_are_hollow(self):
        pics = hudicons.pictures()
        for name, pen in (("frame", 2), ("frame_hot", 1)):
            g = pics[name]
            self.assertTrue(all(v == spritemap.NONE for row in g[1:15] for v in row[1:15]), name)
            self.assertTrue(all(v == pen for v in g[0] + g[15]), name)


class TestTheSheet(unittest.TestCase):

    def test_export_reads_back_as_the_pictures_and_the_aseprite_is_the_png(self):
        with tempfile.TemporaryDirectory() as tmp:
            png = os.path.join(tmp, "hudicons.png")
            ase = os.path.join(tmp, "hudicons.aseprite")
            hudicons.export(png, ase)
            self.assertEqual(hudicons.read(png), hudicons.pictures())
            data = open(ase, "rb").read()
            size, magic, frames, W, H, depth = struct.unpack_from("<IHHHHH", data, 0)
            self.assertEqual((size, magic, frames, depth), (len(data), 0xA5E0, 1, 8))
            self.assertEqual(data[28], spritemap.NONE)
            n = struct.unpack_from("<I", data, 140)[0]
            off, cel, slices = 144, None, []
            for _ in range(n):
                csize, kind = struct.unpack_from("<IH", data, off)
                body = data[off + 6:off + csize]
                if kind == 0x2005:
                    cel = zlib.decompress(body[20:])
                if kind == 0x2022:
                    ln = struct.unpack_from("<H", body, 12)[0]
                    slices.append(body[14:14 + ln].decode())
                off += csize
            self.assertEqual(off, len(data))
            from PIL import Image
            img = Image.open(png)
            self.assertEqual(img.size, (W, H))
            self.assertEqual(cel, img.tobytes())
            self.assertEqual(slices, [n for n, _, _, _, _, _ in hudicons.ICONS])

    def test_the_checked_in_sheet_is_what_the_tool_draws(self):
        """Until the owner repaints it, art/hudicons.png must be the seed --
        otherwise the tool and the art have already drifted."""
        self.assertEqual(hudicons.read(hudicons.PNG), hudicons.pictures())


if __name__ == "__main__":
    unittest.main()
