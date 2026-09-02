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

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_TARGET = 9, 10, 11, 12, 14
F_ACTIVE = 1


class BarFixture(unittest.TestCase):
    """One machine per test: nearly every one of these presses a mode key,
    and a mode left open would be the next test's starting state."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        #  ...and then let it PAINT. See harness.let_the_game_draw.
        h.let_the_game_draw(self.c, self.sym)
        self.font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H))

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def give_the_yard_a_harvester(self, slot=25):
        return h.give_the_yard_a_harvester(self.c, self.sym, slot)

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
        return h.read_bank4(self.c, self.sym[name], 1)[0]

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

    @staticmethod
    def _ink(cell_bytes) -> int:
        """Which pen a cell was drawn in, from the planes its pixels are in.

        The mirror of _to_pen1, and the reason it has to exist: folding the low
        nibble up deliberately THROWS THE COLOUR AWAY, so a decoder built on it
        reads the same words whether the keys are blue and the actions white or
        the other way round. A test that only reads the words would pass with
        the whole scheme reversed.

        Ink 1 is %01 and puts its pixels in the high nibble, ink 2 is %10 and
        puts them in the low one, ink 3 is both -- so the two planes read back
        as the pen number itself. A blank cell is 0.
        """
        hi = any(b & 0xF0 for b in cell_bytes)
        lo = any(b & 0x0F for b in cell_bytes)
        return (1 if hi else 0) | (2 if lo else 0)

    def strip_cells(self, y=None, cells=40, base=None):
        """(text, inks) for the bar's text row: a character and a pen a cell.

        Anything that is not a glyph in the font comes back as '?', which is
        how a ship drawn into the strip would show up.

        `base` names a buffer to read instead of whichever is in front. A
        screen test that only reads the front one is half a test -- the display
        page-flips -- and every page in this game has to be painted into both.
        """
        if y is None:
            y = self.sym["CTX_Y"]
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        raw = [[ram[h.screen_offset(y + r, x)] for x in range(80)]
               for r in range(CHAR_H)]

        text, inks = [], []
        for cell in range(cells):
            x = cell * CHAR_W_BYTES
            if x + 1 >= 80:
                break
            want = [(self._to_pen1(raw[r][x]), self._to_pen1(raw[r][x + 1]))
                    for r in range(CHAR_H)]
            text.append(self._match(want))
            inks.append(self._ink([raw[r][x + c]
                                   for r in range(CHAR_H)
                                   for c in range(CHAR_W_BYTES)]))
        return "".join(text), inks

    def strip_text(self, y=None, cells=40, base=None) -> str:
        return self.strip_cells(y, cells, base)[0].rstrip()

    def assert_reads(self, expect, y=None):
        """Walk the bar left to right checking each word AND the ink it is in.

        `expect` is [(word, pen), ...] in the order they appear, which is what
        lets "B" and "BUILD" be told apart without an index: the search for one
        starts where the last one ended. Blank cells inside a word -- the space
        inside ", ." -- carry no ink and are skipped.
        """
        text, inks = self.strip_cells(y)
        pos = 0
        for word, pen in expect:
            i = text.find(word, pos)
            self.assertNotEqual(i, -1,
                                f"{word!r} is not on the bar, which reads {text.rstrip()!r}")
            got = {inks[i + k] for k in range(len(word)) if text[i + k] != " "}
            self.assertEqual(got, {pen},
                             f"{word!r} is drawn in ink {sorted(got)}, not {pen}, "
                             f"on a bar that reads {text.rstrip()!r}")
            pos = i + len(word)

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

    def test_an_armed_recycle_asks_on_the_bar(self):
        """`Y` arms and asks again, and the asking has to be VISIBLE.

        Without a line here the first `Y` does nothing a player can see, and a
        key that does nothing visible is a key that is broken -- which is the
        exact failure this whole strip was built to end: a player who had been
        told the build panel was `B`, then `,`/`.`, then ENTER asked twice how
        to choose what to build.
        """
        self.hold("y")
        self.assertNotEqual(self.byte("ECO_RECYCLE_ARMED"), 0, "`Y` did not arm")
        text = self.strip_text()
        self.assertTrue(text.startswith("RECYCLE?"), f"the bar reads {text!r}")
        self.assert_reads([("RECYCLE?", 3), ("Y", 2), ("CONFIRM", 1),
                           ("ESC", 2), ("CANCEL", 1)])

    def test_and_the_question_goes_away_when_it_is_answered(self):
        """A caption that outlived the state would be worse than none -- the
        same rule PAUSED follows."""
        self.hold("y")
        self.assertIn("RECYCLE?", self.strip_text())
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.byte("ECO_RECYCLE_ARMED"), 0)
        self.assertNotIn("RECYCLE?", self.strip_text())

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

    def setUp(self):
        super().setUp()
        self.give_the_yard_a_harvester()

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

    def test_a_busy_yard_no_longer_refuses_and_the_bar_no_longer_says_it_does(self):
        """It used to say YARD BUSY the moment one ship was on the slipway,
        which was eco_queue's first refusal. The yard queues ten orders now,
        so a second ENTER is taken -- and a bar still saying BUSY would be
        telling the player not to press the key that works."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 500))
        self.open_panel()
        self.assertIn("ENTER BUY", self.strip_text())
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertNotEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                            "the order was not taken, so this proves nothing")
        text = self.strip_text()
        self.assertIn("ENTER BUY", text, f"the bar reads {text!r}")
        self.assertNotIn("QUEUE FULL", text)

    def test_it_says_when_the_queue_is_full(self):
        """Ten orders outstanding is the only thing left that a rich player
        can be refused for, so it is the one the bar has to name."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.open_panel()
        for _ in range(14):                          # the slipway and nine more
            if self.byte("ECO_QUEUE_LEN") == 9:
                break
            self.hold(cpc.KEY_ENTER, frames=25)
            #  Ten presses take longer than a Scout takes to build, so without
            #  this the yard launches one while the queue is being filled and
            #  the line is one short of full for reasons that have nothing to
            #  do with the refusal under test.
            self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([255]))
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 9,
                         "the queue did not fill, so this proves nothing")
        text = self.strip_text()
        self.assertIn("QUEUE FULL", text, f"the bar reads {text!r}")
        self.assertNotIn("ENTER BUY", text)

        #  ...and it is telling the truth: the eleventh really is refused.
        before = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 9)
        self.assertEqual(int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2),
                                        "little"), before,
                         "the yard charged for an order the bar said it would refuse")

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

    # -- the fleet's own ceiling --------------------------------------------
    #  The entity table is partitioned (game/entity.asm), so the fleet has a
    #  limit of its own and a player who builds will reach it. Before that,
    #  eco_queue simply failed to find a slot with nothing said -- so the yard
    #  took the RU for a ship that was never going to appear.
    def fill_the_fleet(self, free=0):
        """Leave `free` slots of the PLAYER region empty and fill the rest."""
        limit = self.sym["ENT_PLAYER_MAX"] - free
        for slot in range(limit):
            base = self.sym["ENTITIES"] + slot * ENT_SIZE
            if self.c.read_ram(base + ENT_FLAGS, 1)[0] & F_ACTIVE:
                continue
            self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
            self.c.write_ram(base + ENT_CLASS, bytes([0]))      # an interceptor
            self.c.write_ram(base + ENT_HULL, bytes([255]))
            self.c.write_ram(base + ENT_SQUAD, bytes([1]))
            self.c.write_ram(base + ENT_TARGET, bytes([0xFF]))
            self.c.write_ram(base + ENT_FLAGS, bytes([F_ACTIVE]))
        self.c.run_frames(30)

    def test_it_says_when_the_FLEET_is_full(self):
        """The other ceiling, and it needs its own word: QUEUE FULL is "wait,
        then press ENTER again" and this one is "there is nowhere for another
        ship to be". Saying the first about the second would leave the player
        waiting for a slipway that is already empty."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.fill_the_fleet()
        self.open_panel()

        text = self.strip_text()
        self.assertIn("FLEET FULL", text, f"the bar reads {text!r}")
        self.assertNotIn("ENTER BUY", text)
        self.assertNotIn("QUEUE FULL", text)
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 0,
                         "the queue was full too, so the two words are not being told apart")

        #  ...and it is telling the truth: the order really is refused, and
        #  refused BEFORE the money moves.
        before = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "the yard took an order the bar said it would refuse")
        self.assertEqual(int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2),
                                        "little"), before,
                         "the yard charged for a ship the fleet has no room for")

    def test_the_bar_and_eco_queue_never_disagree_about_the_fleet_either(self):
        """The same walk as above, up the FLEET's ceiling rather than up the
        price ladder. The refusal is against everything OUTSTANDING and not
        just this one order -- the RU is taken at order time, so a queue of
        ten against one free slot would be nine ships bought and never built.
        """
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 900))
        self.open_panel()
        seen = set()
        for free in (3, 2, 1, 0):
            self.fill_the_fleet(free=free)
            says_yes = "ENTER BUY" in self.strip_text()
            before = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
            self.hold(cpc.KEY_ENTER, frames=25)
            took = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2),
                                  "little") != before
            #  Nothing must LAUNCH while this walk is going on: a ship off the
            #  slipway takes one of the slots the next rung is counting.
            self.c.write_ram(self.sym["ECO_BUILD_TIMER"], bytes([255]))
            self.assertEqual(says_yes, took,
                             f"with {free} of the fleet's slots free the bar said "
                             f"{'BUY' if says_yes else 'no'} and the yard "
                             f"{'took' if took else 'refused'} the order")
            seen.add(says_yes)
        self.assertEqual(seen, {True, False},
                         "one of the two answers never came up: half a test")


PEN_WHITE, PEN_BLUE, PEN_RED = 1, 2, 3


class TestTheKeysAreBlue(BarFixture):
    """Every key in ink 2, what it does in ink 1.

    The bar is forty characters above a battle, and in one colour it has to be
    READ rather than glanced at. Blue on the key and white on the action is the
    same split the HUD already makes between chrome and values, used here to
    say "this part is something you press" -- so the eye finds the keys without
    spelling out the words beside them.

    Every one of these asserts the INK and not just the text, because the
    decoder in BarFixture folds the colour out on purpose: a test that read
    only the words would pass just as happily with the scheme reversed.
    """

    def test_the_playing_line_alternates_key_and_action(self):
        self.assert_reads([
            ("ESC", PEN_BLUE), ("MENU", PEN_WHITE),
            ("ENTER", PEN_BLUE), ("MOVE", PEN_WHITE),
            ("B", PEN_BLUE), ("BUILD", PEN_WHITE),
            (", .", PEN_BLUE), ("TARGET", PEN_WHITE),
        ])

    def test_the_move_disc_line_does_too_and_may_end_on_a_key(self):
        """ESC closes the disc and there is no word for it that is not already
        on the line -- ENTER is OK, so ESC is not-OK -- so the run ends on a
        blue word with nothing beside it. ctx_run allows that; what it cannot
        express is two blue words running, which is the rule "every key says
        what it does" written where the build would catch it."""
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1, "the disc did not open")
        self.assert_reads([
            ("ARROWS", PEN_BLUE), ("MOVE", PEN_WHITE),
            ("SHIFT", PEN_BLUE), ("HEIGHT", PEN_WHITE),
            ("ENTER", PEN_BLUE), ("OK", PEN_WHITE),
            ("ESC", PEN_BLUE),
        ])

    def test_PAUSED_keeps_ink_3_and_its_tail_is_an_ordinary_run(self):
        """Section 2 reserves ink 3 for the thing that wants attention, and a
        paused fleet does not look paused -- it looks broken. PAUSED is also
        the one word on this line that is neither a key nor an action: it is
        the STATE, and the third ink is what says so."""
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "SPACE did not pause")
        self.assert_reads([
            ("PAUSED", PEN_RED),
            ("SPACE", PEN_BLUE), ("RESUME", PEN_WHITE),
            ("ESC", PEN_BLUE), ("MENU", PEN_WHITE),
        ])

    def test_the_build_panel_colours_the_keys_and_not_the_goods(self):
        """The class and its price are NOT keys. They are what the player is
        choosing between and the two things that move when `,` or `.` is
        pressed, so they are values and they are white -- blue would have made
        the name of a ship read as something to press, which is the exact
        confusion this bar was built to end. RU is a unit caption, so it is
        chrome, so it is ink 2 like every other caption in the game.

        ENTER BUY stays wholly ink 3. It is not there to teach the key, it is
        the one thing on the screen asking to be pressed -- the same job JUMP
        does in the HUD -- and splitting it into a blue key and a white action
        would make it look like the other four.
        """
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 500))
        self.give_the_yard_a_harvester()    # ...or the list is one class long
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")
        self.assert_reads([
            ("SCOUT", PEN_WHITE),
            ("25", PEN_WHITE), ("RU", PEN_BLUE),
            (", .", PEN_BLUE), ("PICK", PEN_WHITE),
            ("ENTER BUY", PEN_RED),
        ])

    def test_a_refusal_is_an_answer_and_stays_white(self):
        """NEED MORE RU is the answer to a question the player asked by opening
        the panel, not an alarm, so it does not get the alarm ink -- and it is
        not a key either, so it does not get the key ink."""
        self.c.write_ram(self.sym["ECO_RU"], struct.pack("<H", 10))
        self.hold("b")
        self.assert_reads([
            (", .", PEN_BLUE), ("PICK", PEN_WHITE),
            ("NEED MORE RU", PEN_WHITE),
        ])

    def test_no_context_leaves_a_pen_behind_it(self):
        """txt_set_pen is not sticky by convention: whoever changes the ink
        puts it back to 1. The bar now changes it four to eight times a
        repaint, and it ends on a blue word in the move disc and on ink 3 in
        the build panel -- so the proof that it puts the pen back is the HUD,
        which is drawn by a different routine straight afterwards.

        RU is the HUD's own caption and sets itself to ink 2; the four digits
        beside it are drawn in whatever the bar left, and they must be white.
        """
        y = self.sym["HUD_ROW_A_Y"]

        def check(where):
            self.c.run_frames(30)
            text, inks = self.strip_cells(y=y)
            i = text.find("RU")
            self.assertNotEqual(i, -1, f"the HUD reads {text.rstrip()!r} ({where})")
            self.assertEqual({inks[i], inks[i + 1]}, {PEN_BLUE},
                             f"the HUD's RU caption changed colour ({where})")
            digits = [k for k in range(i + 2, i + 8) if text[k].isdigit()]
            self.assertEqual(len(digits), 4, f"no RU figure in {text.rstrip()!r}")
            self.assertEqual({inks[k] for k in digits}, {PEN_WHITE},
                             f"the RU figure inherited an ink from the bar ({where})")

        check("playing")
        self.hold(cpc.KEY_ENTER, frames=25)      # the disc: ends on a blue ESC
        check("the move disc")
        self.hold(cpc.KEY_ESC, frames=25)
        self.hold(cpc.KEY_SPACE)                 # paused: opens in ink 3
        check("paused")
        self.hold(cpc.KEY_SPACE)
        self.hold("b")                           # the yard: ends in ink 3
        check("the build panel")


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
        #  Bank 5 in around the call and bank 4 back after, the way
        #  class_tier_addr and class_blit_done do it. The interceptor moved out
        #  of bank 4 with the 3+3+2 repack, and a blit with the wrong bank
        #  under the window still draws SOMETHING -- whatever bank 4 has at
        #  that address -- so this test would go on passing while measuring
        #  the clipping of a page of help text.
        self.c.write_ram(h.STUB, bytes([0xF3,
                                        0x01, 0xC5, 0x7F, 0xED, 0x49,
                                        0xCD, addr & 0xFF, addr >> 8,
                                        0x01, 0xC4, 0x7F, 0xED, 0x49,
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
