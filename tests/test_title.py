"""The screen the game opens on.

HOMEPLANET across the full width, a starfield, a flight of ships, and the
credit line. Most of what is worth pinning here is the width: the title is
sized to the screen rather than centred on it, so ten glyphs at eight bytes
IS the eighty-byte line, and nothing in the drawing does any arithmetic to
make that true.

Everything the title owns lives in bank 4 -- the code as well as the strings,
because it runs once before the first mission and has no business competing
for the low 16K with the frame loop. So it is read through read_cpu here;
read_ram would hand back bank 1.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

SCR_BYTES_PER_LINE = 80
TXT_BIG_W_BYTES = 8
TITLE_Y = 20
TITLE_H = 32
CREDIT_Y = 186
PROMPT_Y = 160


class TitleFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        #  briefing=True: the harness would otherwise press ENTER past both
        #  this and the briefing behind it before the test got a look.
        self.c = h.boot_quick(frames=400, briefing=True)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def banked(self, name, size=1):
        return h.read_cpu(self.c, self.sym[name], size)

    def string(self, name, limit=40):
        raw = self.banked(name, limit)
        return raw.split(b"\x00")[0]

    def row_ink(self, y):
        """Lit pixels on one scanline of the visible screen."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return sum(bin(ram[h.screen_offset(y, x)]).count("1") for x in range(80))


class TestItIsUpAtTheStart(TitleFixture):

    def test_the_game_opens_on_it(self):
        self.assertEqual(self.banked("TITLE_SHOWN")[0], 1,
                         "the game did not open on the title screen")

    def test_space_starts_the_game(self):
        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(25)
        self.c.key_up(cpc.KEY_SPACE)
        self.c.run_frames(30)
        self.assertEqual(self.banked("TITLE_SHOWN")[0], 0, "SPACE did not start the game")
        #  And what it hands over to is the first mission's briefing, which
        #  mis_init opened behind it before the player ever saw this screen.
        self.assertEqual(self.c.read_ram(self.sym["MIS_BRIEFING"], 1)[0], 1,
                         "the title did not hand over to the briefing")

    def test_nothing_simulates_behind_it(self):
        base = self.sym["ENTITIES"]
        before = [self.c.read_ram(base + s * 20, 6) for s in range(48)]
        self.c.run_frames(200)
        after = [self.c.read_ram(base + s * 20, 6) for s in range(48)]
        self.assertEqual(after, before, "the fleet was flying behind the title screen")


class TestTheWords(TitleFixture):

    def test_the_title_is_exactly_the_width_of_the_screen(self):
        """The reason the game is called a ten-letter word on this screen.

        src/main.asm asserts this at build time too; here it is measured on
        the machine, because the build-time version only checks the string
        and this checks what was drawn.
        """
        title = self.string("TITLE_TEXT")
        self.assertEqual(len(title) * TXT_BIG_W_BYTES, SCR_BYTES_PER_LINE,
                         f"{title!r} is not eighty bytes of glyphs")

        #  The tenth glyph has to be in the tenth cell, which starts at byte
        #  72. Not the last byte column: the font's face is five pixels in an
        #  eight-pixel cell, so every glyph carries three columns of tracking
        #  and the last three bytes of the line are blank by construction. The
        #  title is flush left and ends a tracking-width short of the right,
        #  which is what "spans the screen" means for this font.
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)

        def band_ink(column):
            return sum(bin(ram[h.screen_offset(y, column)]).count("1")
                       for y in range(TITLE_Y, TITLE_Y + TITLE_H))

        self.assertGreater(band_ink(0), 0,
                           "byte column 0 is blank -- the title is not flush left")
        last_cell = SCR_BYTES_PER_LINE - TXT_BIG_W_BYTES        # 72
        self.assertGreater(sum(band_ink(c) for c in range(last_cell, last_cell + 5)), 0,
                           "the last glyph is not in the last cell -- the title fell short")
        self.assertEqual(sum(band_ink(c) for c in range(last_cell + 5, SCR_BYTES_PER_LINE)), 0,
                         "something is drawn in the last glyph's tracking")

    def test_the_credit_line_is_there_and_centred(self):
        credit = self.string("TITLE_CREDIT")
        self.assertEqual(credit, b"REVIVE8BIT - 2026 - VASPER")

        #  Two bytes a glyph, and what is left over is split evenly.
        margin = (SCR_BYTES_PER_LINE - len(credit) * 2) // 2
        self.assertEqual(self.sym["TITLE_CREDIT_X"], margin,
                         "the credit line is not centred")

    def test_the_prompt_says_which_key(self):
        """A title screen that does not say how to leave it is a dead end."""
        self.assertEqual(self.string("TITLE_PROMPT"), b"PRESS SPACE TO START")
        margin = (SCR_BYTES_PER_LINE - len(b"PRESS SPACE TO START") * 2) // 2
        self.assertEqual(self.sym["TITLE_PROMPT_X"], margin,
                         "the prompt is not centred")

    def test_the_prompt_blinks(self):
        """It is drawn on some frames and not others, which on a screen that
        repaints in full every frame is all a blink needs to be."""
        seen = set()
        for _ in range(40):
            self.c.run_frames(4)
            seen.add(self.row_ink(PROMPT_Y + 3) > 10)
            if len(seen) == 2:
                return
        self.fail(f"the prompt never changed state: always {'on' if True in seen else 'off'}")

    def test_the_credit_sits_below_the_ships_at_the_bottom(self):
        self.assertGreater(CREDIT_Y, 160, "the credit line is not near the bottom")
        self.assertGreater(self.row_ink(CREDIT_Y + 3), 20,
                           "nothing is drawn on the credit line")


class TestTheGraphics(TitleFixture):

    def test_there_are_stars_and_ships(self):
        """Pen 2 is stars, pen 1 is hulls and letters -- the palette is
        semantic, so counting pens says what is actually on screen."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        pens = {}
        #  Below the title band, so the letters cannot be mistaken for ships.
        for y in range(TITLE_Y + TITLE_H, CREDIT_Y - 8):
            for x in range(80):
                byte = ram[h.screen_offset(y, x)]
                for shift in range(4):
                    pen = ((byte >> (7 - shift)) & 1) | (((byte >> (3 - shift)) & 1) << 1)
                    pens[pen] = pens.get(pen, 0) + 1

        self.assertGreater(pens.get(2, 0), 20, "no starfield")
        self.assertGreater(pens.get(1, 0), 60, "no ships")

    def test_it_is_repainted_every_frame(self):
        """The display page-flips, so a screen painted once alternates with
        whatever the other buffer still holds -- the title would strobe."""
        first = self.row_ink(TITLE_Y + 16)
        self.assertGreater(first, 0)
        for _ in range(6):
            self.c.run_frames(1)
            self.assertGreater(self.row_ink(TITLE_Y + 16), 0,
                               "the title flickered -- one buffer has it and the other does not")


if __name__ == "__main__":
    unittest.main()
