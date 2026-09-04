"""The screen that says the campaign is over.

Section 8 makes losing the Mothership the end of the game, and mis_update has
set mis_failed on that condition since the campaign was written -- but nothing
ever looked at it except the wave generator, which quietly stopped sending
waves. The frame loop went on running and the player was left flying a fleet
around an empty map. A defeat condition that is computed and not shown is not
a defeat condition, and these are what say it is shown.

The words are read back OFF THE SCREEN, through the decoder in test_ctxbar --
so "the page says THE MOTHERSHIP IS GONE" is a statement about pixels rather
than about a flag.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tests.test_ctxbar import BarFixture, CHAR_H
import cpc

ENT_SIZE = 20
ENT_FLAGS = 11

SOLID_INK_1, SOLID_INK_3 = 0xF0, 0xFF


class OverFixture(BarFixture):

    def lose_the_mothership(self):
        """Clear its ACTIVE bit, which is what a killing blow leaves behind.

        Polled rather than counted: mis_update runs once a GAME frame and a
        game frame is seven to ten emulator ones, so a fixed run_frames is a
        test asserting on the frame rate. That mistake is recorded four times
        over in CLAUDE.md.
        """
        slot = self.byte("MOTH_SLOT")
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base + ENT_FLAGS, bytes([0]))
        for _ in range(300):
            if self.byte("MIS_FAILED"):
                break
            self.c.run_frames(2)
        else:
            self.fail("the Mothership was destroyed and the campaign "
                      "did not end")

        #  ...AND THEN WAIT FOR IT TO BE ON THE SCREEN, which is a different
        #  moment. mis_update sets the flag on the playing path and the page is
        #  drawn by the NEXT game frame, into one buffer, and by the one after
        #  that into the other -- so returning the instant the flag goes up
        #  hands the caller a machine that agrees the campaign is over and is
        #  still showing the battle. Every test of the drawing failed that way
        #  first, on a build whose screenshot was perfect.
        for _ in range(300):
            if all("THE MOTHERSHIP IS GONE" in self.line(1, b)
                   for b in (0x8000, 0xC000)):
                return
            self.c.run_frames(2)
        self.fail("the campaign ended and the page never reached both buffers")

    def text_at(self, y, x0, base=None):
        """One row of text, decoded from byte column x0 rather than from 0.

        THE PHASE MATTERS AND IT IS NOT AN IMPLEMENTATION DETAIL. A character
        cell is TXT_CHAR_W_BYTES = 2 bytes wide, and BarFixture's decoder walks
        cells from byte 0 -- so it can only see text drawn at an EVEN byte
        column. Two of this page's four lines are centred on an odd one, which
        the centring arithmetic has every right to do and txt_draw draws
        perfectly, and they read back as blank. Every test here failed that way
        first, against a screenshot that was correct.
        """
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        cells = []
        for cell in range((80 - x0) // 2):
            x = x0 + cell * 2
            cells.append(self._match([
                (self._to_pen1(ram[h.screen_offset(y + r, x)]),
                 self._to_pen1(ram[h.screen_offset(y + r, x + 1)]))
                for r in range(CHAR_H)]))
        return "".join(cells).rstrip()

    def line(self, n, base=None):
        """Body line 1, 2 or 3 -- read at the y and x its equates put it.

        Asking for the exact row is what makes this a test of the LAYOUT as
        well as of the words: a line that drifted a step would come back blank
        rather than being found somewhere else on the page.
        """
        y = self.sym["OVER_BODY_Y"] + (n - 1) * self.sym["OVER_LINE_STEP"]
        return self.text_at(y, self.sym[f"OVER_LINE_{n}_X"], base)

    def prompt(self, base=None):
        return self.text_at(self.sym["OVER_PROMPT_Y"],
                            self.sym["OVER_PROMPT_X"], base)

    def page(self, base=None):
        return "\n".join([self.line(n, base) for n in (1, 2, 3)]
                         + [self.prompt(base)])

    def title_band(self, base=None):
        """The bytes GAME OVER is drawn into, at four times the font's size."""
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        top = self.sym["OVER_TITLE_Y"]
        return [ram[h.screen_offset(y, x)]
                for y in range(top, top + self.sym["TXT_BIG_H"])
                for x in range(80)]


class TestItComesUp(OverFixture):

    def test_losing_the_mothership_ends_the_campaign(self):
        self.assertEqual(self.byte("MIS_FAILED"), 0,
                         "the campaign was over before it started")
        self.lose_the_mothership()

    def test_it_says_so_in_the_biggest_letters_there_are(self):
        self.lose_the_mothership()
        page = self.page()
        self.assertIn("THE MOTHERSHIP IS GONE", page,
                      f"the screen reads:\n{page}")
        self.assertIn("SIXTY THOUSAND SLEEPERS", page,
                      f"the screen reads:\n{page}")
        self.assertIn("SPACE", page, f"the screen reads:\n{page}")

    def test_the_big_word_is_in_the_alarm_ink(self):
        """Ink 3, which section 2 reserves for the thing that demands
        attention -- and it took a self-modifying byte in txt_big, which has
        one fixed ink because it writes a whole screen byte per source pixel.

        A solid ink 3 byte is #FF and a solid ink 1 is #F0, so this also says
        the ink was PUT BACK: the title screen goes through the same routine
        and is white.
        """
        self.lose_the_mothership()
        band = self.title_band()
        self.assertGreater(band.count(SOLID_INK_3), 200,
                           "GAME OVER is not drawn in ink 3")
        self.assertEqual(band.count(SOLID_INK_1), 0,
                         "part of GAME OVER is still white")

    def test_it_is_painted_into_both_buffers(self):
        """The display page-flips, so a page painted once is on screen every
        OTHER frame -- which looks like flicker on the machine and like nothing
        at all in a test that reads the front buffer.
        """
        self.lose_the_mothership()
        for base in (0x8000, 0xC000):
            self.assertIn("THE MOTHERSHIP IS GONE", self.page(base),
                          f"buffer {base:#06x} is not carrying the page")

    def test_it_takes_the_hud_strip_as_well(self):
        """The other four full-screen pages stop at spr_clip_bottom and leave
        the fleet counts standing, because that is what a player is about to
        give an order about. There are no more orders: RU and M 5 under GAME
        OVER are the instruments of a ship that is gone.
        """
        self.lose_the_mothership()
        #  ...and this page then uses the strip for its own prompt, which is
        #  the point rather than an exception: it owns all two hundred lines.
        #  Every OTHER line of the strip has to be black, and the three rows
        #  the HUD draws -- C at 168, A at 178, B at 188 -- all fall outside
        #  the prompt's own eight, so a surviving one cannot hide inside it.
        prompt = range(self.sym["OVER_PROMPT_Y"],
                       self.sym["OVER_PROMPT_Y"] + CHAR_H)
        for base in (0x8000, 0xC000):
            ram = self.c.read_ram(base, 0x4000)
            below = [(y, x)
                     for y in range(self.sym["HUD_TOP"], 200)
                     if y not in prompt
                     for x in range(80)
                     if ram[h.screen_offset(y, x)]]
            self.assertFalse(below[:8],
                             f"the HUD strip survived into buffer {base:#06x}")

    def test_the_context_bar_is_suppressed(self):
        """Every full-screen page draws its own prompt, and two prompts for
        one screen is one of them being wrong the first time the other
        changes."""
        self.lose_the_mothership()
        self.assertEqual(self.strip_text(), "",
                         "the context bar is still up over the game-over page")

    def test_nothing_simulates_behind_it(self):
        """Static means static: the same obligation the briefing has.

        mis_timer is the clock the attack waves run on and mis_update is on the
        playing path, so a clock that moves is a frame loop that is still
        running the battle underneath a screen saying the battle is over.
        """
        self.lose_the_mothership()
        before = int.from_bytes(self.c.read_ram(self.sym["MIS_TIMER"], 2),
                                "little")
        self.c.run_frames(120)
        after = int.from_bytes(self.c.read_ram(self.sym["MIS_TIMER"], 2),
                               "little")
        self.assertEqual(before, after, "the mission clock ran behind the page")


class TestTheBurningWorld(OverFixture):
    """The same ellipse the title screen draws, at the middle of this one,
    with fires on it. The sameness is the point: the title shows the world the
    fleet is flying towards and this shows it burning."""

    def geometry(self):
        s = self.sym
        return (s["OVER_PLANET_CX"], s["OVER_PLANET_CY"],
                s["TITLE_PLANET_RX"], s["TITLE_PLANET_RY"])

    def pen_at(self, ram, x, y):
        byte = ram[h.screen_offset(y, x >> 2)]
        shift = x & 3
        return ((byte >> (7 - shift)) & 1) | (((byte >> (3 - shift)) & 1) << 1)

    def fires(self):
        n = self.sym["OVER_FIRE_COUNT"]
        #  Off build/bank7.raw -- what the build put on the disc -- because
        #  the table is in BANK 7 now, where read_bank4 would hand back
        #  whichever sprite bank happens to be under the window.
        with open("build/bank7.raw", "rb") as f:
            bank7 = f.read()
        off = self.sym["OVER_FIRE_TABLE"] - 0x4000
        raw = bank7[off:off + n * 3]
        out = []
        for i in range(n):
            dx, dy, hgt = raw[i * 3:i * 3 + 3]
            out.append((dx - 256 if dx > 127 else dx,
                        dy - 256 if dy > 127 else dy, hgt))
        return out

    def test_every_fire_is_on_the_planet(self):
        """Re-derived from the ellipse, top AND bottom of each column.

        There is no per-fire clip in over_fires and there should not be one --
        a fire outside the planet is a fire in space, and the table is where
        that is got right. This is what makes that safe to say.
        """
        _, _, rx, ry = self.geometry()
        fires = self.fires()
        self.assertEqual(len(fires), self.sym["OVER_FIRE_COUNT"])
        for dx, dy, hgt in fires:
            for edge in (dy, dy + hgt - 1):
                r = (dx / rx) ** 2 + (edge / ry) ** 2
                self.assertLess(r, 0.9,
                                f"the fire at ({dx}, {dy}) reaches {r:.2f} of "
                                "the way to the limb")

    def test_the_world_is_there_and_it_is_burning(self):
        """Ink 2 at the limb, and ink 3 inside it -- read off the screen.

        Not a pixel count: the claim is that the two extreme points of the
        ellipse are lit AND that the only ink 3 inside the disc is where the
        table says a fire is. Ink 3 is nowhere else on this screen below the
        big letters, so finding it inside the planet is finding a fire.
        """
        self.lose_the_mothership()
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)

        for x in (cx - rx, cx + rx):
            self.assertEqual(self.pen_at(ram, x, cy), 2,
                             f"the limb is not lit at x={x}")

        burning = [(x, y)
                   for y in range(cy - ry, cy + ry + 1)
                   for x in range(cx - rx, cx + rx + 1)
                   if self.pen_at(ram, x, y) == 3]
        self.assertGreater(len(burning), 60,
                           "the planet is not on fire")

        want = {(cx + dx, cy + dy + r)
                for dx, dy, hgt in self.fires() for r in range(hgt)}
        self.assertEqual(set(burning) - want, set(),
                         "there is ink 3 on the planet that no fire in the "
                         "table accounts for")

    def test_nothing_is_burning_off_the_planet(self):
        """Ink 3 is the alarm ink and this screen spends it twice -- on GAME
        OVER and on the fires. Anywhere else it would be a fill that walked."""
        self.lose_the_mothership()
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        stray = [(x, y)
                 for y in range(self.sym["OVER_TITLE_Y"] + self.sym["TXT_BIG_H"],
                                200)
                 for x in range(320)
                 if self.pen_at(ram, x, y) == 3
                 and not (cx - rx <= x <= cx + rx and cy - ry <= y <= cy + ry)]
        self.assertFalse(stray[:8],
                         f"ink 3 outside the planet at {stray[:8]}")


class TestBeginningAgain(OverFixture):

    def press_space(self):
        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(30)
        self.c.key_up(cpc.KEY_SPACE)
        #  demo_reset writes the disc on the way through, and a disc write is
        #  the drive spinning up: about a third of a second, with DI held for
        #  the transfer. Polled, and generously bounded.
        for _ in range(400):
            if h.read_bank4(self.c, self.sym["TITLE_SHOWN"], 1)[0]:
                return
            self.c.run_frames(2)
        self.fail("SPACE did not begin the game again")

    def test_space_goes_back_to_the_title(self):
        self.lose_the_mothership()
        self.press_space()
        self.assertEqual(self.byte("MIS_FAILED"), 0,
                         "the campaign is still over after starting again")

    def test_the_save_is_destroyed_and_the_campaign_starts_at_one(self):
        """THE POINT OF THE WHOLE SCREEN, and the reason it erases anything.

        FLEET.DAT is written at every jump, so it holds the fleet as it stood
        at the START of the mission just lost -- with the Mothership alive.
        Leave it and "τέλος παιχνιδιού" costs nothing at all: the player
        reboots and resumes one mission earlier. Section 1's premise is that
        what is lost is lost.

        demo_reset re-reads the disc, so mis_saved and mis_index coming back
        zero IS the disc no longer carrying a campaign -- not a flag somebody
        cleared in RAM.
        """
        h.clear_the_way_out(self.c)
        h.jump_mission(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 1, "the jump did not happen")
        self.assertEqual(self.byte("MIS_SAVED"), 1, "the jump wrote no save")

        self.lose_the_mothership()
        self.press_space()

        self.assertEqual(self.byte("MIS_SAVED"), 0,
                         "the disc still has a campaign on it")
        self.assertEqual(self.byte("MIS_INDEX"), 0,
                         "the new campaign did not start at mission 1")


if __name__ == "__main__":
    unittest.main()
