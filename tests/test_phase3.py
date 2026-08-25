"""Phase 2 and 3 acceptance tests -- masked sprite blitting.

    Phase 2: "24 sprites κινούνται χωρίς σκιές/υπολείμματα"
    Phase 3: "Ένα σκάφος, 8 όψεις, 3 βαθμίδες, στην οθόνη"

The blitter is checked pixel-exact: the sprite bytes are read back out of the
emulator's RAM, the blit is simulated in Python exactly as the Z80 does it
(`screen = (screen AND mask) OR data`), and the result is compared against
what actually landed in screen memory. Clipping is checked the same way,
including that the clipped-off part did not scribble on its neighbours.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

#  Interceptor tier C: 24 px + the 4 px pre-shift spill = 7 bytes, 16 rows.
TIER_C_W_BYTES = 7
TIER_C_H = 16
TIER_C_BLOCK_SZ = TIER_C_W_BYTES * 2 * TIER_C_H


class SpriteFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()
        #  The sprite library lives in extended bank 4, so it has to be read
        #  through the CPU's view of memory rather than by base-RAM address.
        cls.block = h.read_cpu(cls.c, cls.sym["INTERCEPTOR_C"], TIER_C_BLOCK_SZ)
        #  The demo clips the tactical view above the HUD strip. These tests
        #  are about the blitter itself, so give it the whole screen back.
        cls.c.write_ram(cls.sym["SPR_CLIP_BOTTOM"], bytes([200]))

    def poke_word(self, name, value):
        self.c.write_ram(self.sym[name], struct.pack("<H", value & 0xFFFF))

    def poke_byte(self, name, value):
        self.c.write_ram(self.sym[name], bytes([value & 0xFF]))

    def blit(self, x, y, w=TIER_C_W_BYTES, hgt=TIER_C_H, block=None):
        """Set up spr_* and call spr_blit. Returns (carry, rect)."""
        self.poke_word("SPR_SRC", block if block is not None else self.sym["INTERCEPTOR_C"])
        self.poke_word("SPR_X", x)
        self.poke_word("SPR_Y", y)
        self.poke_byte("SPR_W", w)
        self.poke_byte("SPR_H", hgt)

        addr = self.sym["SPR_BLIT"]
        stub = bytes([0xF3,
                      0xCD, addr & 0xFF, addr >> 8,
                      0x9F,                                  # sbc a,a
                      0x32, 0x00, 0x2F,                      # ld (#2F00),a
                      0x18, 0xFE])
        self.c.write_ram(0x3000, stub)
        self.c.set_pc(0x3000)
        self.c.run_frames(3)

        carry = self.c.read_ram(0x2F00, 1)[0] == 0xFF
        rect = tuple(self.c.read_ram(self.sym["SPR_RECT"], 4))
        return carry, rect

    def back_buffer(self):
        return self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0] << 8

    def clear_back(self, value=0x00):
        base = self.back_buffer()
        for y in range(200):
            self.c.write_ram(base + h.screen_offset(y, 0), bytes([value] * 80))

    def expected(self, x, y, background=0x00, w=TIER_C_W_BYTES, hgt=TIER_C_H):
        """Simulate the blit in Python: (screen AND mask) OR data, clipped."""
        screen = {}
        for row in range(hgt):
            sy = y + row
            if not (0 <= sy < 200):
                continue
            for col in range(w):
                sx = x + col
                if not (0 <= sx < 80):
                    continue
                mask = self.block[(row * w + col) * 2]
                data = self.block[(row * w + col) * 2 + 1]
                screen[(sx, sy)] = (background & mask) | data
        return screen


class TestBlitter(SpriteFixture):

    def test_draws_exactly_what_the_model_says(self):
        self.clear_back()
        carry, rect = self.blit(20, 40)
        self.assertTrue(carry)
        self.assertEqual(rect, (20, 40, TIER_C_W_BYTES, TIER_C_H))

        base = self.back_buffer()
        want = self.expected(20, 40)
        ram = self.c.read_ram(base, 0x4000)
        for (bx, by), value in want.items():
            got = ram[h.screen_offset(by, bx)]
            self.assertEqual(got, value,
                             f"byte ({bx},{by}): got #{got:02X}, want #{value:02X}")

    def test_leaves_the_background_alone_where_the_mask_says_so(self):
        """A non-zero background must survive under transparent pixels."""
        self.clear_back(0xFF)                       # solid pen 3 everywhere
        self.blit(10, 60)

        base = self.back_buffer()
        want = self.expected(10, 60, background=0xFF)
        ram = self.c.read_ram(base, 0x4000)
        transparent_seen = 0
        for (bx, by), value in want.items():
            got = ram[h.screen_offset(by, bx)]
            self.assertEqual(got, value, f"byte ({bx},{by})")
            if value == 0xFF:
                transparent_seen += 1
        self.assertGreater(transparent_seen, 20,
                           "this sprite has almost no transparent bytes; "
                           "the test is not proving anything")

    def test_does_not_touch_a_single_byte_outside_its_rectangle(self):
        self.clear_back(0x5A)
        self.blit(30, 80)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        for y in range(200):
            for x in range(80):
                inside = 30 <= x < 30 + TIER_C_W_BYTES and 80 <= y < 80 + TIER_C_H
                if not inside:
                    self.assertEqual(ram[h.screen_offset(y, x)], 0x5A,
                                     f"byte ({x},{y}) outside the sprite was modified")


class TestClipping(SpriteFixture):

    def _check(self, x, y, want_rect):
        self.clear_back()
        carry, rect = self.blit(x, y)
        self.assertTrue(carry, f"({x},{y}) was rejected outright")
        self.assertEqual(rect, want_rect, f"({x},{y})")

        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        want = self.expected(x, y)
        for (bx, by), value in want.items():
            self.assertEqual(ram[h.screen_offset(by, bx)], value,
                             f"({x},{y}) -> byte ({bx},{by})")
        # and nothing outside the clipped rectangle
        rx, ry, rw, rh = rect
        for by in range(200):
            for bx in range(80):
                if rx <= bx < rx + rw and ry <= by < ry + rh:
                    continue
                self.assertEqual(ram[h.screen_offset(by, bx)], 0,
                                 f"({x},{y}) scribbled outside at ({bx},{by})")

    def test_clips_off_the_left(self):
        self._check(-3, 50, (0, 50, TIER_C_W_BYTES - 3, TIER_C_H))

    def test_clips_off_the_right(self):
        self._check(76, 50, (76, 50, 4, TIER_C_H))

    def test_clips_off_the_top(self):
        self._check(20, -5, (20, 0, TIER_C_W_BYTES, TIER_C_H - 5))

    def test_clips_off_the_bottom(self):
        self._check(20, 190, (20, 190, TIER_C_W_BYTES, 10))

    def test_clips_two_edges_at_once(self):
        self._check(-2, -4, (0, 0, TIER_C_W_BYTES - 2, TIER_C_H - 4))

    def test_rejects_what_is_entirely_off_screen(self):
        for x, y in ((-TIER_C_W_BYTES, 50), (80, 50), (20, -TIER_C_H), (20, 200)):
            self.clear_back()
            carry, _ = self.blit(x, y)
            self.assertFalse(carry, f"({x},{y}) should have been rejected")
            base = self.back_buffer()
            ram = self.c.read_ram(base, 0x4000)
            self.assertEqual(sum(ram), 0, f"({x},{y}) drew something anyway")


if __name__ == "__main__":
    unittest.main()
