"""8x8 HUD text -- src/gfx/text.asm.

The font is stored 1 bit per pixel and expanded to Mode 1 as it is drawn, so
the thing worth proving is that the expansion is right, not that something
appeared. The oracle is cpc.py's own Mode 1 decoder -- an independent
implementation, in the emulator -- run over the bytes that actually landed in
screen RAM. Decoding them back to pen indices and comparing against the glyph
bitmaps read out of the machine's own font table checks the whole path:
character -> glyph address -> 1bpp row -> two Mode 1 bytes -> screen address.

`_decode_byte` is used the same way tests/test_sprites.py uses it.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h  # noqa: E402  (puts cpc.py on the path)
import cpc  # noqa: E402

FIRST_CHAR = 32
LAST_CHAR = 90
CHAR_W_BYTES = 2
CHAR_H = 8

STUB = h.STUB                  # scratch, in the slack between code and stack
STRBUF = h.DATA                # ditto, for strings we hand to txt_draw


def decode_mode1(byte: int) -> list[int]:
    """Four pen indices, left to right. The emulator's decoder, as oracle."""
    return cpc._decode_byte(byte, 1)


class TextFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()
        #  ...and let the game finish PAINTING before any stub is poked in.
        #  txt_set_pen is not sticky by convention -- whoever changes the ink
        #  puts it back -- so a machine caught in the middle of the HUD, which
        #  draws its chrome in ink 2, hands these tests a pen that is not 1.
        #  Every glyph then comes back as pen 2 and eleven tests here fail
        #  saying the font is wrong. Thirty frames used to land after the
        #  paint; the title screen's music made the boot a shade slower.
        h.let_the_game_draw(cls.c, cls.sym)
        cls.font = bytes(cls.c.read_ram(cls.sym["TXT_FONT"],
                                        (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H))

    # ---- machine plumbing --------------------------------------------------

    def back_buffer(self) -> int:
        return self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0] << 8

    def clear_back(self, value: int = 0x00) -> None:
        base = self.back_buffer()
        for y in range(200):
            self.c.write_ram(base + h.screen_offset(y, 0), bytes([value] * 80))

    def _run(self, setup: bytes, routine: str) -> None:
        addr = self.sym[routine]
        stub = (bytes([0xF3])                                   # di
                + setup
                + bytes([0xCD, addr & 0xFF, addr >> 8])         # call
                + bytes([0x18, 0xFE]))                          # jr $
        self.c.write_ram(STUB, stub)
        self.c.set_pc(STUB)
        self.c.run_frames(3)

    def draw(self, text: str, x: int, y: int) -> None:
        self.c.write_ram(STRBUF, text.encode("ascii") + b"\0")
        self._run(bytes([0x21, STRBUF & 0xFF, STRBUF >> 8,      # ld hl,STRBUF
                         0x01, y, x]),                          # ld bc,x*256+y
                  "TXT_DRAW")

    def draw_char(self, ch: str, x: int, y: int) -> None:
        self._run(bytes([0x01, y, x,                            # ld bc,x*256+y
                         0x3E, ord(ch)]),                       # ld a,ch
                  "TXT_DRAW_CHAR")

    def draw_char_code(self, code: int, x: int, y: int) -> None:
        self._run(bytes([0x01, y, x, 0x3E, code]), "TXT_DRAW_CHAR")

    def draw_num(self, value: int, x: int, y: int, width: int) -> None:
        self._run(bytes([0x01, y, x,                            # ld bc,x*256+y
                         0x16, width,                           # ld d,width
                         0x3E, value]),                         # ld a,value
                  "TXT_DRAW_NUM")

    # ---- reading the result ------------------------------------------------

    def pen_grid(self, x: int, y: int, w_cells: int = 1) -> list[list[int]]:
        """The pens of a w_cells x 1 run of character cells, as CHAR_H rows."""
        base = self.back_buffer()
        grid = []
        for row in range(CHAR_H):
            pens: list[int] = []
            for byte in range(w_cells * CHAR_W_BYTES):
                pens += decode_mode1(
                    h.peek_pixel_byte(self.c, base, y + row, x + byte))
            grid.append(pens)
        return grid

    def glyph_bits(self, ch: str) -> list[int]:
        """The eight stored 1bpp rows for a character."""
        i = (ord(ch) - FIRST_CHAR) * CHAR_H
        return list(self.font[i:i + CHAR_H])

    def expected_grid(self, rows: list[int]) -> list[list[int]]:
        """1bpp rows -> the pen grid they must produce. Bit 7 is leftmost."""
        return [[1 if r & (0x80 >> b) else 0 for b in range(8)] for r in rows]

    def assert_cell(self, ch: str, x: int, y: int, msg: str = "") -> None:
        self.assertEqual(self.pen_grid(x, y),
                         self.expected_grid(self.glyph_bits(ch)),
                         f"glyph {ch!r} at ({x},{y}) {msg}")


class TestGlyphExpansion(TextFixture):
    """1bpp -> Mode 1, pixel by pixel, against the stored bitmaps."""

    #  Letters with ink hard against the left edge of the cell (bit 7) and
    #  ones that reach the last column the face uses (bit 3, which is the
    #  FIRST pixel of the second screen byte -- the byte boundary).
    SAMPLE = "AHMWZEXY08.:- "

    def test_the_sample_exercises_both_ends_of_the_cell(self):
        """Guard: without this the next test could pass on blank glyphs."""
        rows = [r for ch in self.SAMPLE for r in self.glyph_bits(ch)]
        self.assertTrue(any(r & 0x80 for r in rows),
                        "no sample glyph lights the leftmost column")
        self.assertTrue(any(r & 0x08 for r in rows),
                        "no sample glyph reaches the second screen byte")

    def test_every_sample_glyph_matches_its_stored_bitmap(self):
        self.clear_back()
        for i, ch in enumerate(self.SAMPLE):
            x, y = 2 + i * CHAR_W_BYTES, 40
            self.draw_char(ch, x, y)
        for i, ch in enumerate(self.SAMPLE):
            self.assert_cell(ch, 2 + i * CHAR_W_BYTES, 40)

    def test_expansion_is_right_for_every_column_of_the_cell(self):
        """The face never lights bits 2..0, so patch the font and check them.

        This is the only way to prove the rightmost pixel of the second
        screen byte -- and a shift-by-one bug in the low nibble would
        otherwise hide behind a 5-pixel-wide face forever.
        """
        slot = self.sym["TXT_FONT"] + (ord("@") - FIRST_CHAR) * CHAR_H
        saved = bytes(self.c.read_ram(slot, CHAR_H))
        patterns = [
            [0xFF] * 8,                                     # every column
            [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01],   # one at a time
            [0x81] * 8,                                     # both edges only
            [0x55, 0xAA] * 4,                               # alternating
            [0x00] * 8,                                     # nothing at all
        ]
        try:
            for rows in patterns:
                self.c.write_ram(slot, bytes(rows))
                self.clear_back()
                self.draw_char("@", 12, 90)
                self.assertEqual(self.pen_grid(12, 90),
                                 self.expected_grid(rows),
                                 f"pattern {[hex(r) for r in rows]}")
        finally:
            self.c.write_ram(slot, saved)

    def test_it_is_opaque(self):
        """Ink 0 pixels must erase what was underneath, not leave it."""
        self.clear_back(0xFF)                       # solid pen 3
        self.draw_char("H", 20, 100)
        self.assert_cell("H", 20, 100, "over a solid background")

    def test_unprintable_characters_come_out_as_spaces(self):
        self.clear_back(0xFF)
        for code in (0, 7, ord("a"), ord("_"), 200, 255):
            self.draw_char_code(code, 30, 120)
            self.assertEqual(self.pen_grid(30, 120),
                             [[0] * 8 for _ in range(CHAR_H)],
                             f"character {code} drew something")


class TestPens(TextFixture):
    """Ink 1 on ink 0, and never anything else."""

    def test_only_pens_0_and_1_ever_appear(self):
        self.clear_back()
        self.draw("HOMEPLANET 0123456789 -.:", 4, 30)
        self.draw("WMX@%&/", 4, 60)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        seen = set()
        for y in range(200):
            for x in range(80):
                seen.update(decode_mode1(ram[h.screen_offset(y, x)]))
        self.assertEqual(seen, {0, 1},
                         f"text produced pens {sorted(seen)}; "
                         "the expansion is leaking into the low nibble")

    def test_the_ink_is_pen_1_not_merely_non_zero(self):
        self.clear_back()
        self.draw_char("H", 10, 10)
        lit = [p for row in self.pen_grid(10, 10) for p in row if p]
        self.assertGreater(len(lit), 8, "'H' drew almost nothing")
        self.assertTrue(all(p == 1 for p in lit))


class TestPositioning(TextFixture):
    """Where the text lands -- the CPC interleave is easy to get wrong."""

    def test_a_string_lands_at_the_column_and_line_it_was_given(self):
        text = "HOMEPLANET"
        for x, y in ((0, 0), (7, 33), (60, 192), (30, 100)):
            self.clear_back()
            self.draw(text, x, y)
            for i, ch in enumerate(text):
                self.assert_cell(ch, x + i * CHAR_W_BYTES, y, f"of {text!r}")

    def test_it_straddles_the_eight_line_character_row_boundary(self):
        """y=6 puts rows 6,7 in one CRTC row and rows 8..13 in the next.

        Consecutive scanlines are #800 apart until the wrap, where they jump
        back by #3800-80. Anything that assumes a constant stride draws the
        bottom six rows of every glyph in the wrong place, and only here.
        """
        for y in (1, 5, 6, 7, 62, 63, 190):
            self.clear_back()
            self.draw("BOX", 20, y)
            for i, ch in enumerate("BOX"):
                self.assert_cell(ch, 20 + i * CHAR_W_BYTES, y, "across a row")

    def test_nothing_is_written_outside_the_bounding_box(self):
        text = "HOMEPLANET"
        x, y = 10, 6                                # straddles the boundary
        self.clear_back(0x5A)
        self.draw(text, x, y)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        w = len(text) * CHAR_W_BYTES
        for by in range(200):
            for bx in range(80):
                if x <= bx < x + w and y <= by < y + CHAR_H:
                    continue
                self.assertEqual(ram[h.screen_offset(by, bx)], 0x5A,
                                 f"byte ({bx},{by}) outside the text changed")

    def test_a_string_stops_at_the_right_edge_instead_of_wrapping(self):
        """Byte 80 of a line is byte 0 of the line eight below it."""
        y = 50
        self.clear_back(0x5A)
        self.draw("ABCDEFGH", 76, y)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        for by in range(200):
            for bx in range(80):
                if 76 <= bx < 80 and y <= by < y + CHAR_H:
                    continue
                self.assertEqual(ram[h.screen_offset(by, bx)], 0x5A,
                                 f"byte ({bx},{by}) was written past the edge")
        self.assert_cell("A", 76, y)
        self.assert_cell("B", 78, y)


class TestDrawNum(TextFixture):
    """Right alignment, because the HUD counters change width every frame."""

    def assert_field(self, want: str, x: int, y: int) -> None:
        for i, ch in enumerate(want):
            self.assert_cell(ch, x + i * CHAR_W_BYTES, y, f"of field {want!r}")

    def test_right_aligns_in_a_three_character_field(self):
        for value, want in ((5, "  5"), (42, " 42"), (255, "255"),
                            (0, "  0"), (10, " 10"), (100, "100")):
            self.clear_back()
            self.draw_num(value, 20, 70, 3)
            self.assert_field(want, 20, 70)

    def test_the_units_column_never_moves(self):
        """The whole point: 5, 42 and 255 must share a units column."""
        units = {}
        for value in (5, 42, 255):
            self.clear_back()
            self.draw_num(value, 20, 70, 3)
            units[value] = self.pen_grid(20 + 2 * CHAR_W_BYTES, 70)
        self.assertEqual(units[5], self.expected_grid(self.glyph_bits("5")))
        self.assertEqual(units[42], self.expected_grid(self.glyph_bits("2")))
        self.assertEqual(units[255], self.expected_grid(self.glyph_bits("5")))

    def test_a_shorter_number_erases_the_longer_one_it_replaces(self):
        """No clearing in between: the field must blank its own leading cells."""
        self.clear_back()
        self.draw_num(255, 20, 70, 3)
        self.draw_num(5, 20, 70, 3)
        self.assert_field("  5", 20, 70)

        self.draw_num(42, 20, 70, 3)
        self.assert_field(" 42", 20, 70)

    def test_it_writes_exactly_the_field_and_no_more(self):
        self.clear_back(0x5A)
        self.draw_num(7, 30, 80, 4)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        for by in range(200):
            for bx in range(80):
                if 30 <= bx < 30 + 4 * CHAR_W_BYTES and 80 <= by < 88:
                    continue
                self.assertEqual(ram[h.screen_offset(by, bx)], 0x5A,
                                 f"byte ({bx},{by}) outside the field changed")
        self.assert_field("   7", 30, 80)

    def test_a_one_character_field(self):
        self.clear_back()
        self.draw_num(9, 40, 150, 1)
        self.assert_field("9", 40, 150)

    def test_a_zero_width_field_draws_nothing(self):
        self.clear_back(0x5A)
        self.draw_num(123, 40, 150, 0)
        base = self.back_buffer()
        ram = self.c.read_ram(base, 0x4000)
        self.assertTrue(all(ram[h.screen_offset(y, x)] == 0x5A
                            for y in range(200) for x in range(80)),
                        "a zero-width field drew something")


if __name__ == "__main__":
    unittest.main()
