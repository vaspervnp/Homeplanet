"""`I`: what the selected squadron is made of.

Every test here reads the page back off the SCREEN, through the machine's own
font table, rather than asking a variable what it thinks. That is not
ceremony: the page's whole job is to put three numbers in front of a player,
and a test that checked `info_count` would pass just as happily with the rows
drawn on top of each other, in the HUD's strip, or not at all -- which is
exactly the class of defect that put the last two lines of the orders menu
across "RU 0080 ?HELP" for weeks.

The decoder is BarFixture's, for the same reason it exists there: folding a
screen byte's low nibble up with `(b | (b << 4)) & 0xF0` recovers the pen-1
glyph whichever ink it was drawn in, so one decoder reads a white row and a
red one without being told which -- and `_ink` reads the colour back
separately, because a decoder that throws the ink away cannot see a page whose
alarm colour never fires.

squadinfo.asm is in the LOW 16K, so its state is read with read_ram. It is the
first static screen that is: bank 4 had 235 bytes left and this is four
hundred. See the header of src/game/squadinfo.asm.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tests.test_ctxbar import BarFixture, CHAR_H
import cpc

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD = 9, 10, 11, 12
F_ACTIVE, F_ENEMY = 1, 2

CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_HARVESTER = 0, 1, 2
CLASS_FRIGATE = 5

PEN_WHITE, PEN_RED = 1, 3


class InfoFixture(BarFixture):
    """BarFixture for the screen decoder; everything else is this page's."""

    def open_info(self):
        self.hold("i")
        self.assertEqual(self.byte("INFO_SHOWN"), 1, "`I` did not open the page")

    def rows(self):
        """Every text row of the page, top to bottom, as strings.

        Read at the font's own 8-pixel pitch from the title down to HUD_TOP,
        so a row that drifted into the HUD's strip turns up as a row this
        never looks at -- and the test that cares about that says so directly.
        """
        top = self.sym["INFO_TITLE_Y"]
        out = []
        for y in range(top, self.sym["HUD_TOP"] - CHAR_H + 1):
            line = self.strip_text(y=y)
            if line:
                out.append((y, line))
        return out

    def page(self):
        return "\n".join(text for _, text in self.rows())

    def find_row(self, word):
        for y, text in self.rows():
            if word in text:
                return y, text
        self.fail(f"{word!r} is nowhere on a page that reads:\n{self.page()}")

    def make(self, slot, cls, hull, squad, enemy=False):
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(base + ENT_CLASS, bytes([cls]))
        self.c.write_ram(base + ENT_HULL, bytes([hull]))
        self.c.write_ram(base + ENT_SQUAD, bytes([squad]))
        self.c.write_ram(base + ENT_FLAGS,
                         bytes([F_ACTIVE | (F_ENEMY if enemy else 0)]))


class TestWhatItSays(InfoFixture):

    def test_it_names_the_squadron_and_its_one_class(self):
        """Mission 1 opens with fifteen interceptors in squadron 1 and the
        Mothership on its own in 2, so this is the whole starting state."""
        self.open_info()
        page = self.page()
        self.assertIn("SQUADRON 1", page, f"the page reads:\n{page}")
        _, row = self.find_row("INTERCEPTOR")
        self.assertIn("15", row, f"the interceptor row reads {row!r}")
        self.assertIn("100%", row, f"the interceptor row reads {row!r}")

    def test_the_whole_word_and_not_the_three_letter_tag(self):
        """class_tag exists because the HUD's yard readout has five bytes.
        This page has eighty, and "INT" in a corner is the readout that sent a
        player to ask what he was building."""
        self.open_info()
        page = self.page()
        self.assertIn("INTERCEPTOR", page, f"the page reads:\n{page}")
        self.assertNotIn("INT ", page.replace("INTERCEPTOR", ""),
                         "the page fell back to the three-letter tag")

    def test_a_class_the_squadron_does_not_have_gets_no_row(self):
        """Eight classes at nought would bury the two lines that matter."""
        self.open_info()
        page = self.page()
        for absent in ("DESTROYER", "BOMBER", "SCOUT", "SALVAGE", "FRIGATE"):
            self.assertNotIn(absent, page,
                             f"{absent} has no ships here but has a row:\n{page}")

    def test_two_classes_get_two_rows_and_a_total(self):
        self.make(40, CLASS_HARVESTER, 255, 1)
        self.make(41, CLASS_HARVESTER, 255, 1)
        self.open_info()

        _, interceptors = self.find_row("INTERCEPTOR")
        _, harvesters = self.find_row("HARVESTER")
        _, total = self.find_row("ALL")
        self.assertIn("15", interceptors, f"{interceptors!r}")
        self.assertIn(" 2", harvesters, f"{harvesters!r}")
        self.assertIn("17", total,
                      f"the total is not the two rows added up: {total!r}")

    def test_the_mothership_is_not_in_squadron_one(self):
        """It is in squadron 0 -- none at all -- not in 2, which is reserved
        and empty. If it turned up here the page would be ignoring ENT_SQUAD,
        and the count would be sixteen rather than fifteen."""
        self.open_info()
        page = self.page()
        self.assertNotIn("MOTHERSHIP", page,
                         f"the Mothership is not in squadron 1:\n{page}")


class TestTheHullFigure(InfoFixture):
    """The third of the three things asked for, and the only one that needs
    arithmetic. It shares wave_pct_of with the HUD's fleet percentage."""

    def test_half_hull_reads_about_half(self):
        base = self.sym["ENTITIES"]
        for slot in range(48):
            flags = self.c.read_ram(base + slot * ENT_SIZE + ENT_FLAGS, 1)[0]
            squad = self.c.read_ram(base + slot * ENT_SIZE + ENT_SQUAD, 1)[0]
            if flags & F_ACTIVE and not flags & F_ENEMY and squad == 1:
                self.c.write_ram(base + slot * ENT_SIZE + ENT_HULL, bytes([128]))
        self.open_info()
        _, row = self.find_row("INTERCEPTOR")
        self.assertIn("50%", row,
                      f"128 of 255 is not being read as half: {row!r}")

    def test_it_is_per_class_and_not_one_figure_for_the_squadron(self):
        """A battered class beside a fresh one is the reading the player wants
        -- "which half of this squadron is in trouble" -- and one number for
        the whole squadron cannot answer it."""
        self.make(40, CLASS_HARVESTER, 26, 1)          # about a tenth
        self.open_info()
        _, interceptors = self.find_row("INTERCEPTOR")
        _, harvesters = self.find_row("HARVESTER")
        self.assertIn("100%", interceptors, f"{interceptors!r}")
        self.assertNotIn("100%", harvesters,
                         f"a harvester at 26 hull reads full: {harvesters!r}")

    def test_a_class_below_a_third_is_drawn_in_the_alarm_ink(self):
        """Section 2 reserves ink 3 for the thing that wants attention, and
        HUD_HP_ALARM is where the HUD's own fleet figure turns. The two have to
        agree or "in trouble" means two different things on two rows.

        A test that only read the words would pass with the colour never
        changing at all, which is why the decoder hands back the ink too.
        """
        self.make(40, CLASS_HARVESTER, 20, 1)
        self.open_info()

        y, row = self.find_row("HARVESTER")
        text, inks = self.strip_cells(y=y)
        i = text.find("%")
        self.assertNotEqual(i, -1, f"no percentage on the harvester row: {row!r}")
        self.assertEqual(inks[i], PEN_RED,
                         f"a harvester at 20 of 255 hull is not in the alarm ink: {row!r}")

        y, _ = self.find_row("INTERCEPTOR")
        text, inks = self.strip_cells(y=y)
        i = text.find("%")
        self.assertEqual(inks[i], PEN_WHITE,
                         "a class at full hull is drawn in the alarm ink")

    def test_the_fleet_figure_in_the_hud_is_not_disturbed(self):
        """wave_pct is the HUD's, and this page borrows the DIVIDE and not the
        variables. It matters because the world is stopped while the page is
        up: wave_update does not run, so a percentage overwritten here would
        stay wrong on the HUD for as long as the player looked at the page --
        and this page's figure is a squadron's, which is a different number.
        """
        self.make(40, CLASS_HARVESTER, 10, 1)
        before = self.byte("WAVE_PCT")
        self.open_info()
        self.assertEqual(self.byte("WAVE_PCT"), before,
                         "the squadron page overwrote the fleet's hull percentage")


class TestTheFormation(InfoFixture):
    """The shape the squadron is flying in, on the title line.

    This class is the guard that src/main.asm could not be: info_form_names is
    INDEXED BY WALKING TERMINATORS, so a list one name short does not draw the
    wrong word -- it walks off the end of the table into whatever the assembler
    put next. RASM cannot count zero bytes in a run, so the check has to press
    the key and read the screen.
    """

    FORM_COUNT = 4

    def formation(self):
        y, text = self.find_row("SQUADRON")
        after = text.split("SQUADRON", 1)[1]
        #  Past the squadron number, and stopping before the ESC prompt.
        word = after.replace("1", " ", 1).split("ESC")[0].strip()
        return word

    def test_it_names_the_formation_it_starts_in(self):
        """form_init puts everyone in Loose."""
        self.open_info()
        self.assertEqual(self.formation(), "LOOSE",
                         f"the title line reads {self.find_row('SQUADRON')[1]!r}")

    def test_every_formation_has_its_own_name(self):
        """Round the whole cycle. A missing name shows up as a repeat, as an
        empty field, or as rubbish walked out of the next table -- and all
        three fail here.
        """
        seen = []
        for step in range(self.FORM_COUNT):
            self.open_info()
            got = self.formation()
            self.assertRegex(got, r"^[A-Z]{3,8}$",
                             f"formation {step} reads {got!r}, which is not a word")
            seen.append(got)
            self.hold(cpc.KEY_ESC)
            self.hold("f")

        self.assertEqual(len(set(seen)), self.FORM_COUNT,
                         f"the {self.FORM_COUNT} formations do not have "
                         f"{self.FORM_COUNT} distinct names: {seen}")

    def test_it_comes_back_round_to_the_first(self):
        """FORM_COUNT presses of `F` is a whole turn, so the name has to be
        the one it started with -- which is what says the page is reading
        squad_form and not counting presses of its own."""
        self.open_info()
        first = self.formation()
        self.hold(cpc.KEY_ESC)
        for _ in range(self.FORM_COUNT):
            self.hold("f")
        self.open_info()
        self.assertEqual(self.formation(), first,
                         "a whole cycle of F did not come back to the start")

    def test_it_is_the_SELECTED_squadron_s_formation(self):
        """squad_form is per squadron. Cycling squadron 1 must not change what
        the page says about squadron 2, or the field is decorative.

        The second squadron has to be MADE. Mission 1 opens with exactly one
        non-empty squadron -- the fifteen interceptors in 1 -- and the
        Mothership is in squadron 0, i.e. none at all. Squadron 2 is reserved
        (SPLIT BY CLASS would hand it to the Mothership's class and does not),
        so it is empty, and squad_select rightly refuses to select an empty
        squadron: pressing `2` leaves the selection where it was and the page
        then reports squadron 1 twice, correctly. That is what the first
        version of this test measured, and it read as a bug in the page.
        """
        #  squad_count is an ARRAY, one byte per squadron, derived by
        #  recounting the entity table -- not a scalar "how many squadrons".
        self.hold("d")                                  # 1 divides; 2 is born
        counts = list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))
        self.assertGreater(counts[2], 0,
                           f"`d` did not make a second squadron: {counts}")

        self.hold("f")                                  # ...and 1 alone cycles
        self.open_info()
        one = self.formation()
        self.hold(cpc.KEY_ESC)

        self.hold("2")
        self.open_info()
        self.assertIn("SQUADRON 2", self.page(), "pressing 2 did not select the new squadron")
        two = self.formation()
        self.assertNotEqual(one, two,
                            f"both squadrons report {one!r} after only 1 was cycled")


class TestItBehavesLikeTheOtherStaticScreens(InfoFixture):

    def test_escape_closes_it_and_pays_the_screen_debt(self):
        self.open_info()
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.byte("INFO_SHOWN"), 0, "ESC did not close the page")

    def test_nothing_simulates_while_it_is_up(self):
        base = self.sym["ENTITIES"]
        self.open_info()
        self.c.run_frames(10)
        before = [self.c.read_ram(base + s * ENT_SIZE, 6) for s in range(48)]
        self.c.run_frames(200)
        self.assertEqual([self.c.read_ram(base + s * ENT_SIZE, 6) for s in range(48)],
                         before, "the fleet flew on behind the squadron page")

    def test_it_is_repainted_into_both_buffers(self):
        """The display page-flips. A page painted once alternates with
        whatever the other buffer still holds, which on the machine is a
        flicker and in a front-buffer-only test is nothing at all.

        SAMPLED OVER SEVERAL GAME FRAMES, and that is not slack. static_wipe
        clears the buffer and the page redraws it, all inside one GAME frame --
        which is about ten emulator frames at the rate this actually runs, so
        a single read at an arbitrary emulator-frame boundary lands inside
        that window perfectly often and finds a buffer that has been wiped and
        not yet redrawn. The first version of this test did exactly that and
        reported 0 bytes in screen A, which says nothing whatever about
        page-flipping. The same trap as reading phase4_visible mid-projection.

        So the claim tested is the honest one: over a window of several game
        frames, EACH buffer is seen carrying the page at least once. A page
        painted into one buffer only fails it however the sampling lands.
        """
        self.open_info()
        top = self.sym["INFO_TITLE_Y"]

        def lit(base):
            ram = self.c.read_ram(base, 0x4000)
            return sum(1 for y in range(top, top + CHAR_H)
                       for x in range(80)
                       if ram[h.screen_offset(y, x)])

        best = {0x8000: 0, 0xC000: 0}
        for _ in range(12):
            for base in best:
                best[base] = max(best[base], lit(base))
            self.c.run_frames(5)

        for base, seen in best.items():
            self.assertGreater(seen, 20,
                               f"the page's title never appeared in the buffer "
                               f"at #{base:04X} over twelve samples")

    def test_the_context_bar_is_suppressed(self):
        """Like the briefing, the help page and the orders menu: the page
        draws its own ESC prompt, and two prompts for one screen is one of
        them being wrong the first time the other changes."""
        self.open_info()
        text = self.strip_text()
        self.assertNotIn("MENU", text,
                         f"the context bar is still up behind the page: {text!r}")

    def test_no_row_reaches_the_hud_strip(self):
        """The defect this page was written just after: thirteen rows of the
        orders menu ran past HUD_TOP into a strip that does not clear itself.
        Eight classes and a total is nine rows, and CLASS_COUNT will grow.
        """
        self.make(40, CLASS_HARVESTER, 255, 1)
        self.make(41, CLASS_FRIGATE, 255, 1)
        self.make(42, CLASS_MOTHERSHIP, 255, 1)
        self.open_info()

        base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        top = self.sym["HUD_TOP"]
        for y in range(top, top + CHAR_H):
            row = self.strip_text(y=y)
            for word in ("ALL", "HARVESTER", "FRIGATE", "MOTHERSHIP"):
                self.assertNotIn(word, row,
                                 f"the page drew {word!r} into the HUD's strip at y={y}")


if __name__ == "__main__":
    unittest.main()
