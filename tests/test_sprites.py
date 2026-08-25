"""Tests for the RetroTools -> Z80 sprite converter.

The interesting property is not "does it produce bytes" but "do those bytes
mean the picture we drew". So the oracle is cpc.py's Mode 1 decoder -- an
independent implementation, in the emulator, written by someone else -- and
the blit itself is simulated exactly as the Z80 will do it:

    screen = (screen AND mask) OR data
"""

from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness  # noqa: E402,F401  (puts cpc.py on the path)
import cpc  # noqa: E402
from tools import rt2sprite  # noqa: E402


def decode_mode1(byte: int) -> list[int]:
    """Four pens, left to right. The emulator's decoder, used as the oracle."""
    return cpc._decode_byte(byte, 1)


def make_project(width=8, height=3, pixels=None, mask=None, palette=None, frames=1):
    """A minimal but schema-accurate .retrotools.json document."""
    if pixels is None:
        pixels = [(x + y) % 4 for y in range(height) for x in range(width)]
    doc = {
        "format": "retrotools-project",
        "version": 1,
        "generator": "test",
        "name": "test",
        "platformCode": "cpc",
        "modeCode": "cpc.mode1",
        "palette": [{"slot": i, "color": c}
                    for i, c in enumerate(palette or rt2sprite.GAME_PALETTE)],
        "groups": [],
        "spriteMaps": [],
        "sprites": [{
            "id": 1,
            "name": "ship",
            "width": width,
            "height": height,
            "hasMask": mask is not None,
            "sortOrder": 0,
            "frames": [
                {
                    "index": i,
                    "durationMs": 100,
                    "pixels": base64.b64encode(bytes(pixels)).decode(),
                    **({"mask": base64.b64encode(bytes(mask)).decode()} if mask else {}),
                }
                for i in range(frames)
            ],
        }],
    }
    return doc


class TestMode1Encoding(unittest.TestCase):

    def test_round_trips_through_the_emulators_decoder(self):
        """Every pen quad must decode back to itself."""
        for a in range(4):
            for b in range(4):
                for c in range(4):
                    for d in range(4):
                        byte = rt2sprite.encode_mode1_byte([a, b, c, d])
                        self.assertEqual(decode_mode1(byte), [a, b, c, d])

    def test_solid_pen_bytes_match_the_assembler_constants(self):
        """SOLID_INK_n in src/sys/screen.asm must agree with the encoder."""
        for pen, want in enumerate(harness.SOLID_INK):
            got = rt2sprite.encode_mode1_byte([pen] * 4)
            self.assertEqual(got, want, f"pen {pen}: #{got:02X} != #{want:02X}")

    def test_mask_bits_cover_exactly_one_pixel(self):
        """A mask bit pair must blank its own pixel and no other."""
        for p in range(4):
            m = rt2sprite.mask_bits(p)
            # A byte of solid pen 3 with only pixel p left showing through
            byte = rt2sprite.encode_mode1_byte([3, 3, 3, 3]) & ~m & 0xFF
            pens = decode_mode1(byte)
            self.assertEqual(pens[p], 0, f"pixel {p} was not cleared")
            self.assertEqual([pens[i] for i in range(4) if i != p], [3, 3, 3],
                             f"mask for pixel {p} spilled onto its neighbours")


class TestBlit(unittest.TestCase):
    """(screen AND mask) OR data must reproduce the sprite over a background."""

    def _blit(self, doc, shift, background_pen=2):
        sprite = doc["sprites"][0]
        w, h = sprite["width"], sprite["height"]
        pens, opaque = rt2sprite.frame_grids(sprite, sprite["frames"][0])
        out_w = w + 4
        sp, so = rt2sprite.shift_grid(pens, opaque, shift, out_w)
        block = rt2sprite.encode_block(sp, so)

        w_bytes = out_w // 4
        bg = rt2sprite.encode_mode1_byte([background_pen] * 4)
        result = []
        i = 0
        for _ in range(h):
            row = []
            for _ in range(w_bytes):
                mask, data = block[i], block[i + 1]
                i += 2
                row += decode_mode1((bg & mask) | data)
            result.append(row)
        return result, sp, so

    def test_opaque_pixels_land_and_transparent_ones_do_not(self):
        # A deliberately holey sprite: pen 0 is empty space, so it is transparent
        pixels = [0, 1, 2, 3, 3, 0, 1, 0,
                  1, 1, 0, 0, 2, 2, 3, 3,
                  0, 0, 0, 0, 1, 1, 1, 1]
        doc = make_project(width=8, height=3, pixels=pixels)
        got, sp, so = self._blit(doc, shift=0, background_pen=2)

        for y in range(3):
            for x in range(12):
                if so[y][x]:
                    self.assertEqual(got[y][x], sp[y][x],
                                     f"opaque pixel ({x},{y}) came out wrong")
                else:
                    self.assertEqual(got[y][x], 2,
                                     f"transparent pixel ({x},{y}) did not let the background through")

    def test_preshift_moves_the_sprite_by_two_pixels(self):
        pixels = [1, 2, 3, 1, 2, 3, 1, 2] * 3
        doc = make_project(width=8, height=3, pixels=pixels)
        at0, _, _ = self._blit(doc, shift=0)
        at2, _, _ = self._blit(doc, shift=2)
        for y in range(3):
            self.assertEqual(at2[y][2:10], at0[y][0:8],
                             "the 2-pixel pre-shift is not a 2-pixel shift")

    def test_explicit_mask_overrides_the_pen_0_default(self):
        """With a mask supplied, pen 0 may be opaque black."""
        pixels = [0] * 8
        mask = [1] * 8                      # every pixel opaque
        doc = make_project(width=8, height=1, pixels=pixels, mask=mask)
        got, _, _ = self._blit(doc, shift=0, background_pen=3)
        self.assertEqual(got[0][:8], [0] * 8,
                         "explicitly opaque black should paint over the background")


class TestValidation(unittest.TestCase):

    def _convert(self, doc, **kw):
        warnings = rt2sprite.check_palette(doc, kw.get("strict", False))
        return rt2sprite.convert(doc, (0, 2), warnings)

    def test_rejects_a_non_mode1_project(self):
        doc = make_project()
        doc["modeCode"] = "cpc.mode0"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(doc, f)
            path = f.name
        try:
            with self.assertRaises(rt2sprite.ConversionError):
                rt2sprite.load_project(path)
        finally:
            os.unlink(path)

    def test_rejects_a_width_that_is_not_a_multiple_of_four(self):
        doc = make_project(width=6, height=2)
        with self.assertRaises(rt2sprite.ConversionError):
            self._convert(doc)

    def test_rejects_pens_outside_mode_1(self):
        doc = make_project(width=4, height=1, pixels=[0, 1, 2, 7])
        with self.assertRaises(rt2sprite.ConversionError):
            self._convert(doc)

    def test_warns_when_the_palette_is_not_the_games(self):
        doc = make_project(palette=[0, 26, 11, 24])     # enemy ink is wrong
        warnings = rt2sprite.check_palette(doc, strict=False)
        self.assertTrue(any("pen 3" in w for w in warnings), warnings)
        with self.assertRaises(rt2sprite.ConversionError):
            rt2sprite.check_palette(doc, strict=True)

    def test_emits_equates_the_assembler_can_use(self):
        doc = make_project(width=8, height=3, frames=2)
        text = self._convert(doc)
        for want in ("ship_w_px      equ 8", "ship_h         equ 3",
                     "ship_frames    equ 2", "ship_shifts    equ 2",
                     "ship_w_bytes   equ 3"):
            self.assertIn(want, text)
        # 2 frames x 2 shifts x (3 bytes wide x 2 planes x 3 rows)
        self.assertIn("ship_block_sz  equ 18", text)


if __name__ == "__main__":
    unittest.main()
