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
            y = self.sym["CTX_LINE_Y"]         # the context line, under the buttons
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
        """Every byte of the TOP strip -- the fleet's, hud_draw's -- in one
        screen buffer. The context line itself is one text row under the
        buttons; the strip that must be owned outright is this one."""
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        return bytes(ram[h.screen_offset(y, x)]
                     for y in range(self.sym["CTX_BAR_H"])
                     for x in range(80))

    def both_strips(self):
        return (self.strip_bytes(0x8000), self.strip_bytes(0xC000))


class TestWhatItSays(BarFixture):

    def test_playing_says_nothing_because_the_buttons_will(self):
        """The key list -- ESC MENU ENTER MOVE B BUILD A ATTACK -- is gone from
        the line (hud2.md): the buttons along the bottom are what say which
        keys are live. Ordinary play leaves the context line BLANK, and the
        line is the bottom strip's text row, not the top of the screen."""
        text = self.strip_text()
        self.assertEqual(text, "", f"the context line reads {text!r}")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_PLAYING"])
        self.assertGreaterEqual(self.sym["CTX_LINE_Y"], self.sym["HUD_TOP"])

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
        RU is on the top strip's first line now.
        """
        y = self.sym["CTX_Y"]

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


class TestFlyingAShip(BarFixture):
    """V hands the arrows and SPACE to one ship (game/pilot.asm), which is two
    keys changing meaning at once -- the exact thing this bar exists to say."""

    def a_fight(self):
        """V is refused on a quiet board: one hostile, far off and cold."""
        import struct
        e = self.sym["ENTITIES"] + (self.sym["ENT_MAX"] - 1) * 20
        self.c.write_ram(e, struct.pack("<hhh", 12000, 0, 12000))
        self.c.write_ram(e + 9, bytes([0, 255, 3, 255, 0, 255]))   # class, hull, ACTIVE+ENEMY, squad, order, target
        self.c.write_ram(e + 19, b"\xff")                           # a cold gun

    def hold_v(self):
        self.a_fight()
        self.hold("v")

    def test_v_puts_the_flying_line_up_in_the_right_inks(self):
        self.hold_v()
        self.assertLess(self.byte("PILOT_SLOT"), self.sym["ENT_PLAYER_MAX"], "V did not take a ship")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_PILOT"])
        self.assert_reads([
            ("ARROWS", PEN_BLUE), ("FLY", PEN_WHITE),
            ("SPACE", PEN_BLUE), ("FIRE", PEN_WHITE),
            ("V", PEN_BLUE), ("BACK", PEN_WHITE),
        ])

    def test_space_is_the_gun_and_the_line_stays(self):
        self.hold_v()
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 0, "SPACE paused the game while flying")
        self.assertIn("SPACE FIRE", self.strip_text())

    def test_v_again_takes_the_flying_line_down(self):
        self.hold_v()
        self.hold("v")
        self.assertEqual(self.byte("PILOT_SLOT"), self.sym["ENT_NO_TARGET"])
        self.assertEqual(self.strip_text(), "")

    def test_a_pause_entered_first_outranks_it_and_space_resumes(self):
        """SPACE is the resume while paused whatever else is going on, and
        the bar has to name THAT rather than the gun."""
        self.hold(cpc.KEY_SPACE)
        self.hold_v()
        self.assertLess(self.byte("PILOT_SLOT"), self.sym["ENT_PLAYER_MAX"])
        text = self.strip_text()
        self.assertTrue(text.startswith("PAUSED"), f"the bar reads {text!r}")
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 0, "SPACE did not resume")
        self.assertIn("SPACE FIRE", self.strip_text())


class TestTheFullScreenPages(BarFixture):

    def test_the_help_page_takes_the_bar_down(self):
        """All four full-screen pages draw their own prompt -- this one says
        'ESC - BACK' beside its title. Two prompts for one screen is one of
        them being wrong the first time the other changes, so the bar is
        suppressed and the page's own wipe is what removes it."""
        self.hold(cpc.KEY_SPACE)                # PAUSED, so the line has words on it
        self.assertTrue(self.strip_text().startswith("PAUSED"))
        self.hold("/")
        self.assertEqual(self.banked("HELP_SHOWN"), 1, "the help page did not open")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_NONE"])
        self.assertNotIn("PAUSED", self.strip_text(),
                         "the context line is still drawn under the help page")

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
        #  The top strip -- the fleet's -- is what the page wiped and what has
        #  to come back into both buffers; the context line is blank in play.
        for base in (0x8000, 0xC000):
            self.assertIn("SQUADRONS", self.strip_text(y=self.sym["CTX_Y2"], base=base),
                          f"the fleet strip is missing from buffer {base:#06x}")
        a, b = self.both_strips()
        self.assertEqual(a, b, "the strip is only in one of the two buffers")
        self.assertTrue(any(a), "the strip is in neither of them")

    def test_the_orders_menu_takes_it_down_too(self):
        """menu_prompt already reads 'UP/DOWN  ENTER  ESC', directly under the
        list it belongs to."""
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.banked("MENU_SHOWN"), 1, "the menu did not open")
        self.assertEqual(self.banked("CTX_KEY"), self.sym["CTX_NONE"])
        self.assertEqual(self.strip_text(), "")


class TestTheFleetStrip(BarFixture):
    """The top strip is the FLEET'S now (hud2.md, game/huddraw.asm): line 1
    the hull bars, RU and the mission; line 2 SQUADRONS as nine marks, the
    selected one's number and count, the yard and the way out. Read back off
    the pixels, because every earlier readout bug passed on the variables."""

    def line(self, which, base=None):
        return self.strip_cells(y=self.sym["CTX_Y" if which == 1 else "CTX_Y2"], base=base)

    def mark_rows(self, n, ink):
        """What a mark's HUD_SQ_MARK_H bytes are in `ink` (a solid ink byte)
        with squadron n's digit cut out of it, off the font the build put on
        the disc (game/hudmarks.asm, bank 5)."""
        with open("build/bank5.raw", "rb") as f:
            off = self.sym["HUD_DIGITS"] - 0x4000 + (n - 1) * 7
            font = f.read()[off:off + 7]
        return [ink & ~((m << 4) | m) & 0xFF for m in font]

    def test_line_one_is_the_hull_captions_the_treasury_and_the_mission(self):
        text, inks = self.line(1)
        for word in ("HULL", "BASE", "RU", "M"):
            i = text.find(word)
            self.assertNotEqual(i, -1, f"line 1 reads {text.rstrip()!r}")
            self.assertEqual({inks[i + k] for k in range(len(word))}, {PEN_BLUE},
                             f"{word} is not in the chrome ink")
        ru = struct.unpack("<H", self.c.read_ram(self.sym["ECO_RU"], 2))[0]
        self.assertIn(f"RU {ru:04d}", text)
        self.assertIn("M  1", text)

    def test_the_bars_are_a_blue_trough_with_a_white_fill(self):
        """A whole fleet: HUD_BAR_W bytes of fill in ink 1 on the bar's middle
        row, and a row of the chrome ink above it. Both bars, both buffers."""
        for base in (0x8000, 0xC000):
            ram = self.c.read_ram(base, 0x4000)
            for x0 in (self.sym["HUD_BAR_X"], self.sym["HUD_MOTH_BAR_X"]):
                top = [ram[h.screen_offset(self.sym["HUD_BAR_Y"], x)]
                       for x in range(x0, x0 + self.sym["HUD_BAR_W"])]
                mid = [ram[h.screen_offset(self.sym["HUD_BAR_Y"] + 2, x)]
                       for x in range(x0, x0 + self.sym["HUD_BAR_W"])]
                self.assertEqual(set(top), {0x0F}, f"the trough at {x0} in {base:#06x}: {top}")
                self.assertEqual(set(mid), {0xF0}, f"the fill at {x0} in {base:#06x}: {mid}")

    def test_line_two_is_the_squadrons_as_marks(self):
        """Blue for a squadron with ships in it, white for an empty one, red
        for the selected one -- the owner's assignment -- then the selected
        squadron's number and its ship count, and no other figures."""
        text, inks = self.line(2)
        self.assertTrue(text.startswith("SQUADRONS"), f"line 2 reads {text.rstrip()!r}")
        counts = self.c.read_ram(self.sym["SQUAD_COUNT"], 10)
        sel = self.byte("SQUAD_SEL")
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        for n in range(1, 10):
            x = self.sym["HUD_SQ_MARK_X"] + (n - 1) * self.sym["HUD_SQ_MARK_STEP"]
            col = [ram[h.screen_offset(self.sym["CTX_Y2"] + r, x)]
                   for r in range(self.sym["HUD_SQ_MARK_H"])]
            ink = 0xFF if n == sel else 0x0F if counts[n] else 0xF0
            self.assertEqual(col, self.mark_rows(n, ink), f"squadron {n}'s mark is {col}")
        self.assertEqual(sel, 1)
        self.assertIn(f"{sel} {counts[sel]:>2}", text)
        self.assertNotIn(":", text, "the old >n:cc slots are still drawn")

    def test_every_digit_is_a_different_picture_and_none_is_solid(self):
        """The number is what tells the marks apart, so no two may share a
        shape, and a digit that cut nothing out would be no digit."""
        seen = set()
        for n in range(1, 10):
            rows = tuple(self.mark_rows(n, 0xFF))
            self.assertNotEqual(rows, (0xFF,) * 7, f"digit {n} cuts nothing out")
            self.assertNotIn(rows, seen, f"digit {n} looks like another")
            seen.add(rows)

    def test_selecting_another_squadron_moves_the_red_mark(self):
        #  Make squadron 2 with `d`, then select it: its mark goes red and 1's blue.
        self.hold("d")
        self.hold("2")
        self.assertEqual(self.byte("SQUAD_SEL"), 2, "2 did not select")
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        y = self.sym["CTX_Y2"]
        x1 = self.sym["HUD_SQ_MARK_X"]
        x2 = x1 + self.sym["HUD_SQ_MARK_STEP"]
        col1 = [ram[h.screen_offset(y + r, x1)] for r in range(7)]
        col2 = [ram[h.screen_offset(y + r, x2)] for r in range(7)]
        self.assertEqual(col1, self.mark_rows(1, 0x0F), "squadron 1's mark is not blue")
        self.assertEqual(col2, self.mark_rows(2, 0xFF), "squadron 2's mark is not red")
        text, _ = self.line(2)
        counts = self.c.read_ram(self.sym["SQUAD_COUNT"], 10)
        self.assertIn(f"2 {counts[2]:>2}", text)


class TestTheSquadronAlarm(BarFixture):
    """"Να αναβοσβήνει η γραμμή του squadron που δέχεται επίθεση": a hit an
    enemy lands on one of ours flags its squadron, and for HUD_ALARM_FRAMES
    the flagged marks go on and off with the tick's phase."""

    def mark(self, n, base=None):
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        x = self.sym["HUD_SQ_MARK_X"] + (n - 1) * self.sym["HUD_SQ_MARK_STEP"]
        return ram[h.screen_offset(self.sym["CTX_Y2"] + 3, x)]

    def flag(self, n):
        return self.c.read_ram(self.sym["HUD_ALARM"] + n, 1)[0]

    def lit(self, n, ink):
        """Row 3 of squadron n's mark in `ink`, digit cut out (see mark_rows)."""
        with open("build/bank5.raw", "rb") as f:
            m = f.read()[self.sym["HUD_DIGITS"] - 0x4000 + (n - 1) * 7 + 3]
        return ink & ~((m << 4) | m) & 0xFF

    def test_a_flagged_squadrons_mark_blinks_and_then_stands_again(self):
        red1, white2 = self.lit(1, 0xFF), self.lit(2, 0xF0)
        self.assertEqual(self.mark(1), red1)            # selected: red, steady
        self.c.write_ram(self.sym["HUD_ALARM"] + 1, b"\x01")
        self.c.write_ram(self.sym["HUD_ALARM_LEFT"], bytes([40]))
        seen, seen2 = set(), set()
        for _ in range(60):
            self.c.run_frames(2)
            seen.add(self.mark(1))
            seen2.add(self.mark(2))
        self.assertEqual(seen, {0x00, red1}, f"the mark did not blink: {seen}")
        self.assertEqual(seen2, {white2}, f"squadron 2's mark, not flagged, moved: {seen2}")
        self.c.write_ram(self.sym["HUD_ALARM_LEFT"], bytes([3]))
        self.c.run_frames(120)
        self.assertEqual(self.byte("HUD_ALARM_LEFT"), 0)
        self.assertEqual(self.flag(1), 0, "the flag was not cleared when the alarm ran out")
        for base in (0x8000, 0xC000):
            self.assertEqual(self.mark(1, base), red1, f"the mark is not back in {base:#06x}")

    def call_retaliate(self, shooter_slot, target_slot):
        e = self.sym["ENTITIES"] + shooter_slot * 20
        self.c.write_ram(self.sym["CBT_ENT"], bytes([e & 0xFF, e >> 8]))
        self.c.write_ram(self.sym["CBT_TARGET"], bytes([target_slot]))
        addr = self.sym["CBT_RETALIATE"]
        self.c.write_ram(h.STUB, bytes([0x01, 0xC4, 0x7F, 0xED, 0x49,       # bank 4 under the window
                                        0xCD, addr & 0xFF, addr >> 8, 0x18, 0xFE]))
        self.c.set_pc(h.STUB)
        self.c.run_frames(2)

    def test_an_enemys_hit_on_one_of_ours_raises_it(self):
        """cbt_retaliate, driven through a stub: an enemy shooter, and a
        target in squadron 1."""
        ent = self.sym["ENTITIES"]
        shooter = self.sym["ENT_MAX"] - 1
        self.c.write_ram(ent + shooter * 20 + 11, bytes([3]))          # ACTIVE + ENEMY
        self.assertEqual(self.c.read_ram(ent + 12, 1)[0], 1, "slot 0 is not in squadron 1")
        self.call_retaliate(shooter, 0)
        self.assertEqual(self.flag(1), 1, "squadron 1 was not flagged")
        self.assertEqual(self.byte("HUD_ALARM_LEFT"), self.sym["HUD_ALARM_FRAMES"])

    def test_our_own_shot_raises_nothing(self):
        self.call_retaliate(1, 0)
        self.assertEqual(self.c.read_ram(self.sym["HUD_ALARM"], 10), bytes(10))
        self.assertEqual(self.byte("HUD_ALARM_LEFT"), 0)


class TestTheStripIsOwned(BarFixture):
    """The top strip is repainted only when what it says changes, and that is
    only safe while nothing else can put a pixel in it."""

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
                             "something drew in, or erased out of, the fleet strip")

    def test_the_strip_is_the_same_in_both_screen_buffers(self):
        """ctx_dirty is set to 2, not 1, for the same reason the HUD's is:
        the display page-flips, and a strip painted into one buffer would
        alternate with whatever the other one still holds."""
        self.c.run_frames(40)
        a, b = self.both_strips()
        self.assertTrue(any(a), "the strip was not drawn at all")
        self.assertEqual(a, b, "the strip flickers between the two buffers")


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
                         "demo_init did not hand the top strip to the HUD")

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
