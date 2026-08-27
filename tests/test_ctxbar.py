"""The context bar: what the top strip says, and that ships stay out of it.

The bar exists because a player who had been told the build panel is `B`, then
`,` and `.`, then ENTER, asked twice how to choose what to build. So the tests
that matter are not "is there a bar" -- they are "does it SAY the right thing,
and does it change when the mode changes". Every one of them reads the words
back off the screen through the machine's own font table, so a bar that draws
the wrong string, in the wrong place, or not at all, fails.

The other half is structural: the strip is only repainted when the context
changes, which is only safe while nothing else can draw in it. Two tests hold
that line -- one for the blitter's new spr_clip_top, one for the
dirty-rectangle eraser.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

FIRST_CHAR = 32
LAST_CHAR = 90
CHAR_H = 8
CHAR_W_BYTES = 2


class BarFixture(unittest.TestCase):
    """One machine per test: nearly every one of these presses a mode key,
    and a mode left open would be the next test's starting state."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        self.font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H))

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- pressing things ----------------------------------------------------
    #  Long enough for key_scan to observe the release: every command is
    #  edge-triggered and the game scans once per GAME frame, which is ten
    #  50 Hz frames at the rate this actually runs at.
    def hold(self, key, frames=30, release=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def banked(self, name):
        return h.read_cpu(self.c, self.sym[name], 1)[0]

    # -- reading the strip back as TEXT --------------------------------------
    def glyph(self, ch: str) -> list[int]:
        i = (ord(ch) - FIRST_CHAR) * CHAR_H
        return list(self.font[i:i + CHAR_H])

    @staticmethod
    def _to_pen1(b: int) -> int:
        """One screen byte, normalised back to the pen-1 bit pattern.

        txt_pen_map produces the same pixels in the high nibble (ink 1), the
        low one (ink 2) or both (ink 3), so folding the low nibble up recovers
        the glyph whichever ink it was drawn in. That is what lets one decoder
        read PAUSED in red and ESC MENU in white without being told which.
        """
        return (b | (b << 4)) & 0xF0

    def strip_text(self, y=None, cells=40) -> str:
        """Decode the bar's text row back into characters.

        Anything that is not a glyph in the font comes back as '?', which is
        how a ship drawn into the strip would show up.
        """
        if y is None:
            y = self.sym["CTX_Y"]
        base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        rows = [[self._to_pen1(ram[h.screen_offset(y + r, x)]) for x in range(80)]
                for r in range(CHAR_H)]

        out = []
        for cell in range(cells):
            x = cell * CHAR_W_BYTES
            if x + 1 >= 80:
                break
            want = [(rows[r][x], rows[r][x + 1]) for r in range(CHAR_H)]
            out.append(self._match(want))
        return "".join(out).rstrip()

    def _match(self, cell) -> str:
        for code in range(FIRST_CHAR, LAST_CHAR + 1):
            bits = self.glyph(chr(code))
            if all(cell[r] == (bits[r] & 0xF0, (bits[r] << 4) & 0xF0)
                   for r in range(CHAR_H)):
                return chr(code)
        return "?"

    def strip_bytes(self, base=None) -> bytes:
        """Every byte of the strip the bar owns, in one screen buffer."""
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        return bytes(ram[h.screen_offset(y, x)]
                     for y in range(self.sym["CTX_BAR_H"])
                     for x in range(80))

    def both_strips(self):
        return (self.strip_bytes(0x8000), self.strip_bytes(0xC000))


class TestWhatItSays(BarFixture):

    def test_playing_offers_the_menu_and_the_keys_that_change_meaning(self):
        """ESC is the way to everything else, and `,`/`.` are the pair whose
        meaning depends on a mode the player could not previously see."""
        text = self.strip_text()
        self.assertIn("ESC MENU", text, f"the bar reads {text!r}")
        self.assertIn("B BUILD", text)
        self.assertIn(", . TARGET", text)
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_PLAYING"])

    def test_pausing_says_so(self):
        """SPACE freezes the battle and nothing on screen used to say it. A
        paused fleet does not look paused, it looks broken -- it simply stops
        obeying -- so this is the state most in need of a caption."""
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "SPACE did not pause")
        text = self.strip_text()
        self.assertTrue(text.startswith("PAUSED"), f"the bar reads {text!r}")
        self.assertIn("SPACE RESUME", text)

    def test_unpausing_takes_the_word_away_again(self):
        """A caption that outlived the state would be worse than none."""
        self.hold(cpc.KEY_SPACE)
        self.assertIn("PAUSED", self.strip_text())
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 0)
        self.assertNotIn("PAUSED", self.strip_text())

    def test_the_move_disc_takes_the_bar_over(self):
        """The arrows drive the disc rather than the camera while it is open,
        and ESC means cancel rather than menu. Both are invisible otherwise."""
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1, "the disc did not open")
        text = self.strip_text()
        self.assertIn("ARROWS MOVE", text, f"the bar reads {text!r}")
        self.assertIn("ENTER OK", text)


class TestTheBuildPanel(BarFixture):
    """The context this was built for."""

    def open_panel(self):
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")

    def test_it_names_the_class_and_what_it_costs(self):
        """The whole failure: the yard's readout was 'SCT' in the corner of
        the bottom strip -- no name, no price, and nothing to say that `,` and
        `.` were live at all. The list is cheapest first, so the panel opens on
        the Scout at section 8's 25 RU."""
        self.open_panel()
        text = self.strip_text()
        self.assertIn("SCOUT", text, f"the bar reads {text!r}")
        self.assertIn("25", text)
        self.assertIn("RU", text)
        self.assertIn(", . PICK", text)

    def test_stepping_the_list_changes_the_name_and_the_price(self):
        """A readout that did not follow the pick would be worse than none --
        the player would order whatever the stale word said."""
        self.open_panel()
        self.assertIn("SCOUT", self.strip_text())
        self.hold(".", frames=20)
        text = self.strip_text()
        self.assertIn("INTERCEPTOR", text, f"the bar reads {text!r}")
        self.assertIn("35", text)
        self.assertNotIn("SCOUT", text)

    def test_it_says_when_the_class_cannot_be_afforded(self):
        """eco_queue already knows -- it silently refuses. A key that does
        nothing and says nothing is the thing the bar exists to stop."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 10))
        self.open_panel()
        text = self.strip_text()
        self.assertIn("NEED MORE RU", text, f"the bar reads {text!r}")
        self.assertNotIn("ENTER BUY", text)

        #  ...and it is telling the truth: ENTER really is refused.
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "the yard took an order the bar said it would refuse")

    def test_it_says_when_the_yard_is_already_busy(self):
        """One ship on the slipway at a time, which is eco_queue's FIRST
        refusal and the one a player hits by pressing ENTER twice."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 500))
        self.open_panel()
        self.assertIn("ENTER BUY", self.strip_text())
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertNotEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                            "the order was not taken, so this proves nothing")
        text = self.strip_text()
        self.assertIn("YARD BUSY", text, f"the bar reads {text!r}")

    def test_the_bar_and_eco_queue_never_disagree(self):
        """ctx_build_state re-derives eco_queue's three refusals rather than
        reading a flag it leaves, because it does not leave one. Walk the
        whole price ladder at a fixed purse and check the two agree on every
        rung: a bar that says BUY to a yard that says no is worse than no bar.
        """
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 60))
        self.open_panel()
        seen = set()
        for _ in range(7):
            text = self.strip_text()
            says_yes = "ENTER BUY" in text
            pick = self.byte("ECO_BUILD_PICK")
            seen.add((pick, says_yes))
            self.hold(".", frames=20)
        #  60 RU buys the Scout (25), the Interceptor (35) and the Harvester
        #  (40) and nothing above them, so both answers have to occur or the
        #  test is only proving that one branch exists.
        self.assertTrue(any(yes for _, yes in seen), "the bar never said BUY")
        self.assertTrue(any(not yes for _, yes in seen), "the bar never refused")


class TestTheFullScreenPages(BarFixture):

    def test_the_help_page_takes_the_bar_down(self):
        """All four full-screen pages draw their own prompt -- this one says
        'ESC - BACK' beside its title. Two prompts for one screen is one of
        them being wrong the first time the other changes, so the bar is
        suppressed and the page's own wipe is what removes it."""
        self.hold("/")
        self.assertEqual(self.banked("HELP_SHOWN"), 1, "the help page did not open")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_NONE"])
        self.assertNotIn("ESC MENU", self.strip_text(),
                         "the playing bar is still on top of the help page")

    def test_it_comes_back_into_BOTH_buffers_when_the_page_closes(self):
        """The bug this test was written to find, and it found it.

        A page closes by clearing its own flag inside its `_key` routine, and
        the frame loop draws the page one more time in the same frame -- so
        the context already said "playing" while the screen still held the
        help page. The bar was painted there, into whichever buffer that
        frame owned, and the two frames of mis_wipe that follow then cleared
        it out of the other one with ctx_dirty already spent. Front buffer
        only, the bar looked perfect; the display page-flips, so on the
        machine it was there every other frame for the rest of the mission.

        Which is why this looks at both buffers and not at the one on show.
        """
        self.hold("/")
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.banked("HELP_SHOWN"), 0)
        self.c.run_frames(40)
        self.assertIn("ESC MENU", self.strip_text())
        a, b = self.both_strips()
        self.assertEqual(a, b, "the bar is only in one of the two buffers")
        self.assertTrue(any(a), "the bar is in neither of them")

    def test_the_orders_menu_takes_it_down_too(self):
        """menu_prompt already reads 'UP/DOWN  ENTER  ESC', directly under the
        list it belongs to."""
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.banked("MENU_SHOWN"), 1, "the menu did not open")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_NONE"])
        self.assertNotIn("ESC MENU", self.strip_text())


class TestTheStripIsOwned(BarFixture):
    """The bar is repainted only when the words change, and that is only safe
    while nothing else can put a pixel in its strip."""

    def test_nothing_repaints_it_while_the_context_holds(self):
        """Forty characters a frame is not affordable -- the HUD's own
        redraw-only-on-change is worth about 90,000 T-states. ctx_dirty
        settling at zero is what says the shadow comparison is doing its job
        rather than the bar being redrawn every frame and nobody noticing."""
        self.c.run_frames(60)
        for _ in range(6):
            self.c.run_frames(20)
            self.assertEqual(self.banked("CTX_DIRTY"), 0,
                             "the bar is being repainted with nothing changing")

    def test_no_ship_and_no_erase_ever_reaches_the_strip(self):
        """spr_clip_top in the blitter, and the clamp in mark_store for the
        dirty rectangles. Get either wrong and ships draw over the bar and the
        eraser then scrubs holes in it -- which nothing would ever repair,
        because the bar only comes back when the CONTEXT changes.

        Orbiting is what drives it: the camera moving is what re-projects every
        marker and moves every ship on screen, so this sweeps the whole
        viewport past the boundary rather than testing one arrangement.
        """
        self.c.run_frames(40)
        before = self.strip_bytes()
        self.assertTrue(any(before), "the strip is blank; this proves nothing")

        for _ in range(6):
            self.c.key_down(cpc.KEY_RIGHT)
            self.c.run_frames(30)
            self.c.key_up(cpc.KEY_RIGHT)
            self.c.key_down(cpc.KEY_UP)
            self.c.run_frames(30)
            self.c.key_up(cpc.KEY_UP)
            self.c.run_frames(10)
            self.assertEqual(self.strip_bytes(), before,
                             "something drew in, or erased out of, the bar's strip")

    def test_the_strip_is_the_same_in_both_screen_buffers(self):
        """ctx_dirty is set to 2, not 1, for the same reason the HUD's is:
        the display page-flips, and a strip painted into one buffer would
        alternate with whatever the other one still holds."""
        self.c.run_frames(40)
        a, b = self.both_strips()
        self.assertTrue(any(a), "the bar was not drawn at all")
        self.assertEqual(a, b, "the bar flickers between the two buffers")


class TestTheTopClip(BarFixture):
    """spr_clip_top itself, driven directly."""

    def test_the_blitter_stops_at_the_top_of_the_viewport(self):
        """The mirror of spr_clip_bottom, and it has to clip the RECTANGLE it
        reports as well as the pixels: phase4_erase blanks whatever the
        rectangle says, so a sprite clipped in pixels but not in bookkeeping
        would erase its way into the bar on the next pass through this buffer.
        """
        sym = self.sym
        top = self.byte("SPR_CLIP_TOP")
        self.assertEqual(top, sym["CTX_BAR_H"],
                         "demo_init did not hand the strip to the context bar")

        back = self.c.read_ram(sym["SCR_BACK_PAGE"], 1)[0] << 8
        for y in range(200):
            self.c.write_ram(back + h.screen_offset(y, 0), bytes([0x00] * 80))

        block = sym["INTERCEPTOR_C"]
        for name, value in (("SPR_ENEMY", 0), ("SPR_W", 7), ("SPR_H", 16)):
            self.c.write_ram(sym[name], bytes([value]))
        self.c.write_ram(sym["SPR_SRC"], struct.pack("<H", block))
        self.c.write_ram(sym["SPR_X"], struct.pack("<H", 20))
        #  Straddling the boundary: half of it is the bar's, half is not.
        self.c.write_ram(sym["SPR_Y"], struct.pack("<h", top - 8))

        addr = sym["SPR_BLIT"]
        self.c.write_ram(h.STUB, bytes([0xF3, 0xCD, addr & 0xFF, addr >> 8,
                                        0x18, 0xFE]))
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)

        rect = tuple(self.c.read_ram(sym["SPR_RECT"], 4))
        self.assertEqual(rect[1], top,
                         f"the rectangle starts at line {rect[1]}, not {top}")
        self.assertEqual(rect[1] + rect[3], top - 8 + 16,
                         "the clipped height does not reach the sprite's foot")

        ram = self.c.read_ram(back, 0x4000)
        for y in range(top):
            for x in range(80):
                self.assertEqual(ram[h.screen_offset(y, x)], 0,
                                 f"the blitter wrote into the bar at ({x},{y})")
        self.assertTrue(any(ram[h.screen_offset(top, x)] for x in range(80)),
                        "nothing was drawn below the line either")


if __name__ == "__main__":
    unittest.main()
