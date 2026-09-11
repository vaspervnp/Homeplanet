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
            self.assertLessEqual(len(cap) + 1, 40, f"{cap}: bank7_line is forty bytes")
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


class TestTheIconsAreInBank5(unittest.TestCase):
    """hud2.md section 6: the icons travel in bank 5's spare, read off the
    disc by lib_load with the libraries. What the build put on the disc has
    to be the sheet, byte for byte, where the symbol file says it is."""

    def test_bank5_raw_holds_every_icon_encoded_as_the_sheet(self):
        sym = {}
        for line in open(os.path.join(ROOT, "build", "homeplanet.sym")):
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith("#"):
                sym[parts[0].upper()] = int(parts[1][1:], 16)
        base = sym["HUD_ICONS"] - 0x4000
        raw = open(os.path.join(ROOT, "build", "bank5.raw"), "rb").read()
        pics = hudicons.read(hudicons.PNG)
        banked = hudicons.BANKED
        for i, (name, _, _, _, _, _) in enumerate(banked):
            want = bytes(hudicons.encode(pics[name]))
            got = raw[base + i * hudicons.ICON_BYTES:base + (i + 1) * hudicons.ICON_BYTES]
            self.assertEqual(got, want, f"{name} is not on the disc as drawn")
            self.assertEqual(sym[f"ICON_{name.upper()}"], i)
        self.assertEqual(sym["HUD_ICONS_END"] - sym["HUD_ICONS"], len(banked) * hudicons.ICON_BYTES)
        self.assertNotIn("ICON_FRAME", sym, "the sheet's frame cells are in the bank")
        self.assertLessEqual(sym["BANK5_DATA_END"], sym["SPR_SCALE_ORG"])

    def test_a_pen_lands_in_the_plane_the_blitter_expects(self):
        """Pen 1 is the high nibble, pen 2 the low, pen 3 both; NOT DRAWN is
        black. The frame cell is the sharpest case -- and the encoding is rows
        1..14 of the cell, so its first row is the frame's SIDES: a blue
        leftmost pixel and a blue rightmost one."""
        pics = hudicons.pictures()
        self.assertEqual(len(hudicons.encode(pics["frame"])), 14 * 4)
        self.assertEqual(hudicons.encode(pics["frame"])[:4], [0x08, 0x00, 0x00, 0x01])
        self.assertEqual(hudicons.encode(pics["frame_hot"])[:4], [0x80, 0x00, 0x00, 0x10])
        #  ...and MENU's third cell row, ..WWWWWWWWWWWW.., as pen 1: the two
        #  outer bytes half lit in the high nibble, the inner two full.
        self.assertEqual(hudicons.encode(pics["menu"])[8:12], [0x30, 0xF0, 0xF0, 0xC0])


if __name__ == "__main__":
    unittest.main()
