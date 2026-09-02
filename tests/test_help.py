"""The key list, on `?`, out with ESC.

Section 9 is a page and a half of controls and the game had no way to look
them up. The page itself is just text, so most of what is worth testing is
the way it takes over: like the mission briefing, while it is up the battle
has to actually stop.
"""

from __future__ import annotations

import struct
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
        #  ...and then let it PAINT. See harness.let_the_game_draw.
        h.let_the_game_draw(self.c, self.sym)

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
    """BOTH of these need the fleet to have somewhere to go, and for a long
    time neither said so.

    They were written when the fleet was still flying out to its station on
    its own -- so "nothing moved" and "something moved" were both statements
    about how far along that flight the game happened to be. The day the boot
    got faster the fleet was already parked, and the pair inverted: the second
    failed, and the FIRST would have passed against a build where the help page
    did not stop the world at all.

    So the station is moved first. Now the fleet has a reason to fly and the
    two claims are about the page rather than about the frame rate.
    """

    STATION = (4000, 0, 4000)

    def give_the_fleet_somewhere_to_go(self):
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", *self.STATION))
        self.c.run_frames(2)

    def positions(self):
        return [self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_X, 6)
                for s in range(ENT_MAX)
                if self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_FLAGS, 1)[0] & F_ACTIVE]

    def test_nothing_moves_while_the_keys_are_up(self):
        """Section 10 wants the briefing static and this is the same screen.

        Reading the keys is not a pause the player asked for, so it must not
        be one they pay for either: no flying, no shooting, no mining.
        """
        self.give_the_fleet_somewhere_to_go()
        self.open_help()
        self.c.run_frames(10)                   # let it settle on the page

        before = self.positions()
        shots = self.byte("CBT_SHOTS")
        self.c.run_frames(200)

        self.assertEqual(self.positions(), before, "the fleet flew on with the keys up")
        self.assertEqual(self.byte("CBT_SHOTS"), shots, "the battle carried on")

    def test_the_game_runs_again_once_it_is_closed(self):
        self.give_the_fleet_somewhere_to_go()
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


class TestTheColumnsFitBesideEachOther(unittest.TestCase):
    """txt_draw clips at the SCREEN edge and not at the column, so a left-hand
    line one character too long does not fail -- it runs silently into the
    right-hand column and the two are drawn on top of each other.

    src/main.asm asserts the table's TOTAL length against HELP_ROWS *
    (HELP_MAX_CHARS + 1), which catches a row added without HELP_ROWS moving,
    and cannot catch one line being three long while another is three short.
    That is what this measures, one line at a time, and it is the same shape as
    the 36-character check on the briefings -- which found two lines that had
    been quietly losing their full stops since the day they were written.

    OFF build/bank7.raw: what the build put on the disc, not the source."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        with open("build/bank7.raw", "rb") as f:
            cls.bank7 = f.read()

    def strings_between(self, first, last):
        at, end_of_table = self.sym[first] - 0x4000, self.sym[last] - 0x4000
        out = []
        while at < end_of_table:
            end = self.bank7.index(b"\0", at)
            out.append(self.bank7[at:end].decode("ascii"))
            at = end + 1
        return out

    def test_the_left_column_stops_short_of_the_right_one(self):
        lines = self.strings_between("HELP_WORDS", "HELP_WORDS_END")
        self.assertEqual(len(lines), self.sym["HELP_ROWS"],
                         "help_words is not HELP_ROWS lines long")
        for line in lines:
            self.assertLessEqual(
                len(line), self.sym["HELP_MAX_CHARS"],
                f"{line!r} runs into the orders column")

    def test_the_right_column_stops_at_the_edge_of_the_screen(self):
        """The right-hand column is the orders menu's own words, drawn at
        HELP_COL2_X rather than at MENU_TEXT_X -- a different x, so its fit is
        a different question from the menu's own."""
        room = ((self.sym["SCR_BYTES_PER_LINE"] - self.sym["HELP_COL2_X"])
                // self.sym["TXT_CHAR_W_BYTES"])
        for line in self.strings_between("MENU_WORDS", "MENU_WORDS_END"):
            self.assertLessEqual(len(line), room,
                                 f"{line!r} runs off the right of the help page")


if __name__ == "__main__":
    unittest.main()
