"""The key list, on `?`, out with ESC.

Section 9 is a page and a half of controls and the game had no way to look
them up. The page itself is just text, so most of what is worth testing is
the way it takes over: like the mission briefing, while it is up the battle
has to actually stop.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walks range(ENT_MAX) then stops looking
#  exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_X, ENT_FLAGS = 0, 11
F_ACTIVE = 1
HUD_TOP = 168

#  `?` is SHIFT + `/`, and the matrix reports the physical key either way, so
#  a test presses the key the player's finger is on.
HELP_KEY = "/"


class HelpFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=400)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def byte(self, name):
        #  read_cpu, not read_ram: the help page moved into bank 4 when the
        #  low 16K ran out, and read_ram would hand back bank 1 -- whatever
        #  the sprite library happens to have at that address.
        return h.read_bank4(self.c, self.sym[name], 1)[0]

    def press(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(15)

    def open_help(self):
        self.press(HELP_KEY)
        self.assertEqual(self.byte("HELP_SHOWN"), 1, "`?` did not open the key list")

    def lit_pixels_above_the_hud(self):
        """How much ink is in the tactical area of the visible screen."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return sum(bin(ram[h.screen_offset(y, x)]).count("1")
                   for y in range(HUD_TOP) for x in range(80))


class TestOpeningAndClosing(HelpFixture):

    def test_question_mark_opens_it_and_escape_puts_it_away(self):
        self.assertEqual(self.byte("HELP_SHOWN"), 0, "it was up before anyone asked")
        self.open_help()
        self.press(cpc.KEY_ESC)
        self.assertEqual(self.byte("HELP_SHOWN"), 0, "ESC did not close the key list")

    def test_it_puts_words_on_the_screen(self):
        """A page of text is a lot more ink than a few ships against space."""
        before = self.lit_pixels_above_the_hud()
        self.open_help()
        self.c.run_frames(20)
        self.assertGreater(self.lit_pixels_above_the_hud(), before * 3,
                           "the key list opened but drew almost nothing")

    def test_it_leaves_nothing_behind_when_it_closes(self):
        """The page paints the whole tactical area and records no dirty
        rectangle for any of it, so nothing would ever erase the text -- it
        would sit under the battle for the rest of the mission. The briefing
        taught this one first."""
        before = self.lit_pixels_above_the_hud()
        self.open_help()
        self.c.run_frames(20)
        self.press(cpc.KEY_ESC)
        #  Two frames of wipe, one per screen buffer, then let it redraw.
        self.c.run_frames(60)
        self.assertLess(self.lit_pixels_above_the_hud(), before * 2,
                        "the key list is still on the screen underneath the battle")


class TestItStopsTheWorld(HelpFixture):

    def positions(self):
        return [self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_X, 6)
                for s in range(ENT_MAX)
                if self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_FLAGS, 1)[0] & F_ACTIVE]

    def test_nothing_moves_while_the_keys_are_up(self):
        """Section 10 wants the briefing static and this is the same screen.

        Reading the keys is not a pause the player asked for, so it must not
        be one they pay for either: no flying, no shooting, no mining.
        """
        self.open_help()
        self.c.run_frames(10)                   # let it settle on the page

        before = self.positions()
        shots = self.byte("CBT_SHOTS")
        self.c.run_frames(200)

        self.assertEqual(self.positions(), before, "the fleet flew on with the keys up")
        self.assertEqual(self.byte("CBT_SHOTS"), shots, "the battle carried on")

    def test_the_game_runs_again_once_it_is_closed(self):
        self.open_help()
        self.c.run_frames(30)
        self.press(cpc.KEY_ESC)

        before = self.positions()
        self.c.run_frames(200)
        self.assertNotEqual(self.positions(), before,
                            "nothing moved after the key list was dismissed")

    def test_commands_do_not_leak_through_the_page(self):
        """The frame loop returns before phase4_commands while it is up, so
        a key pressed at the list cannot also give an order."""
        self.open_help()
        selected = self.byte("SQUAD_SEL")
        self.press("2")
        self.assertEqual(self.byte("SQUAD_SEL"), selected,
                         "a squadron was selected from behind the key list")
        self.assertEqual(self.byte("HELP_SHOWN"), 1, "'2' closed the key list")


class TestTheHudSaysSo(HelpFixture):

    def test_the_strip_offers_the_key(self):
        """A help screen nobody can find is not help.

        The glyphs are checked rather than the pixels: the label is the last
        thing on row A and the RU figure is right beside it, so "it is drawn
        somewhere" would pass with the two overlapping.
        """
        self.assertEqual(self.byte("HELP_SHOWN"), 0)
        label = h.read_bank4(self.c, self.sym["PHASE4_HUD_HELP"], 6)
        self.assertEqual(label, b"?HELP\x00", "the HUD label is not what gets drawn")

        #  And it is actually on the screen, in the HUD strip, not just in ROM.
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        ink = sum(bin(ram[h.screen_offset(y, x)]).count("1")
                  for y in range(178, 186) for x in range(70, 80))
        self.assertGreater(ink, 20, "nothing is drawn where the help label should be")


if __name__ == "__main__":
    unittest.main()
