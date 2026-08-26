"""Keyboard matrix scanning -- src/sys/keyboard.asm.

The firmware is switched off by the time any of this runs, so key_scan drives
the PPI and the PSG itself. That is exactly the sort of code that cannot be
checked by reading it: the failure mode of getting the PPI port A direction
wrong is a scan that quietly reads #FF for every row, which looks like a
keyboard where nobody is typing.

So these tests press real keys in the emulator -- which models the 10x8 matrix,
the 74LS145 row decoder and the AY's port A the way the hardware wires them --
and then call key_down / key_hit on the CPC itself and read the carry flag back
out of RAM. The key ids come from the assembler's symbol file, so a wrong id in
the source shows up here as "pressed 1, but KEY_1 says no".

There are two clocks in here and they are not the same one. key_scan runs from
the interrupt at 50 Hz and ACCUMULATES press edges; key_consume runs once a
game frame -- about five times a second -- and hands the accumulated edges to
key_hit. The fixture below exposes both (`scan`, `consume`) plus `frame`, which
is one of each. A test that calls only `scan` will find key_hit reporting
nothing, and that is correct rather than a bug.

The emulator's joystick emulation is left at its default (type 0). With it on,
SPACE and the four cursor keys are diverted to the joystick port and never
reach the key matrix at all.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

#  Scratch addresses in the slack between the end of the code and the stack.
STUB = h.STUB
RESULT = h.RESULT

KEY_ROWS = 10

#  Every key id the game defines, paired with the character the emulator wants
#  in order to press it. This is the mapping under test: the id is read out of
#  the build, the keypress goes in through the emulated matrix, and the two are
#  only ever compared inside the CPC.
#
#  Two ids are missing on purpose:
#    KEY_TAB   -- the emulator's keymap has no entry for TAB, so there is no
#                 way to press it and nothing to compare against.
#    KEY_SHIFT -- only reachable as a modifier, so it is tested by pressing an
#                 upper-case letter (see test_shift_and_a_letter_together).
PRESSABLE = [
    ("1", "KEY_1"),
    ("2", "KEY_2"),
    ("3", "KEY_3"),
    ("4", "KEY_4"),
    ("5", "KEY_5"),
    ("6", "KEY_6"),
    ("7", "KEY_7"),
    ("8", "KEY_8"),
    ("9", "KEY_9"),
    ("0", "KEY_0"),
    ("a", "KEY_A"),
    ("b", "KEY_B"),
    ("c", "KEY_C"),
    ("d", "KEY_D"),
    ("f", "KEY_F"),
    ("g", "KEY_G"),
    ("h", "KEY_H"),
    ("j", "KEY_J"),
    ("m", "KEY_M"),
    ("n", "KEY_N"),
    ("r", "KEY_R"),
    ("s", "KEY_S"),
    ("x", "KEY_X"),
    ("z", "KEY_Z"),
    (0x20, "KEY_SPACE"),
    (0x0B, "KEY_CUR_UP"),
    (0x0A, "KEY_CUR_DOWN"),
    (0x08, "KEY_CUR_LEFT"),
    (0x09, "KEY_CUR_RIGHT"),
    (0x0D, "KEY_ENTER"),
    (0x03, "KEY_ESC"),
]

ALL_IDS = [name for _, name in PRESSABLE] + ["KEY_TAB", "KEY_SHIFT"]


class KeyboardFixture(unittest.TestCase):
    """Drive key_scan / key_down / key_hit directly, with real keypresses."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()

    @classmethod
    def tearDownClass(cls):
        #  One machine for the whole class, freed when the class is done.
        #  See harness.close for why leaving it to the garbage collector is
        #  not good enough.
        h.close(getattr(cls, "c", None))

    def setUp(self):
        #  Whatever a previous test left held, let go of -- and give the
        #  emulator two frames to do it. Its matrix keeps a key pressed for a
        #  sticky ~16 ms after key_up, so scanning immediately would still see
        #  it down.
        self.release_all()

    #  --- driving the Z80 ---------------------------------------------------

    def _run_stub(self, code):
        self.c.write_ram(STUB, bytes(code))
        self.c.set_pc(STUB)
        self.c.run_frames(1)

    def scan(self):
        """One 50 Hz sample, exactly as sys_irq takes it.

        key_scan has no DI of its own any more -- it runs inside the interrupt,
        where they are already off -- so the stub provides one. Every stub in
        this file starts with DI, which is also what keeps the game's OWN
        interrupt from scanning underneath the test between calls.
        """
        addr = self.sym["KEY_SCAN"]
        self._run_stub([0xF3,                                   # di
                        0xCD, addr & 0xFF, addr >> 8,           # call key_scan
                        0x18, 0xFE])                            # jr $

    def consume(self):
        """One frame boundary: the edges the scans piled up become the hits.

        key_scan ACCUMULATES into key_edge and never clears it, so nothing
        reaches key_hit until this runs. That is the whole point of the split:
        a press between two frames survives until a frame comes to collect it.
        """
        addr = self.sym["KEY_CONSUME"]
        self._run_stub([0xF3,                                   # di
                        0xCD, addr & 0xFF, addr >> 8,           # call key_consume
                        0x18, 0xFE])                            # jr $

    def frame(self):
        """A game frame's worth: sample the matrix, then collect the edges."""
        self.scan()
        self.consume()

    def _query(self, routine, key):
        """A = key id, CALL routine, and bring its carry flag back in RAM."""
        addr = self.sym[routine]
        self._run_stub([0xF3,                                   # di
                        0x3E, self.sym[key] & 0xFF,             # ld a,id
                        0xCD, addr & 0xFF, addr >> 8,           # call ...
                        0x9F,                                   # sbc a,a
                        0x32, RESULT & 0xFF, RESULT >> 8,       # ld (RESULT),a
                        0x18, 0xFE])                            # jr $
        return self.c.read_ram(RESULT, 1)[0] == 0xFF

    def down(self, key):
        return self._query("KEY_DOWN", key)

    def hit(self, key):
        return self._query("KEY_HIT", key)

    def digit_down(self, digit):
        """key_digit(digit) -> key_down, the way a squadron-number loop does."""
        digit_addr = self.sym["KEY_DIGIT"]
        down_addr = self.sym["KEY_DOWN"]
        self._run_stub([0xF3,                                   # di
                        0x3E, digit,                            # ld a,digit
                        0xCD, digit_addr & 0xFF, digit_addr >> 8,
                        0x32, RESULT + 1 & 0xFF, RESULT + 1 >> 8,
                        0xCD, down_addr & 0xFF, down_addr >> 8,
                        0x9F,                                   # sbc a,a
                        0x32, RESULT & 0xFF, RESULT >> 8,
                        0x18, 0xFE])                            # jr $
        result = self.c.read_ram(RESULT, 2)
        return result[0] == 0xFF, result[1]

    def state(self):
        """The raw 10-byte held-state array. A 1 bit means the key is down."""
        return list(self.c.read_ram(self.sym["KEY_STATE"], KEY_ROWS))

    #  --- driving the keyboard ---------------------------------------------

    def press(self, key):
        #  Deliberately does NOT run the machine. The emulated matrix goes
        #  down the moment key_down is called, and letting the game's own
        #  frame loop run here would let ITS key_scan consume the press edge
        #  before the test ever gets to look at it. The next scan() is a stub
        #  we control, so this stays true once key_scan is in the frame loop.
        self.c.key_down(key)

    def release(self, key):
        self.c.key_up(key)
        self.c.run_frames(2)            # outlast the emulator's sticky release

    def release_all(self):
        for key, _ in PRESSABLE:
            self.c.key_up(key)
        self.c.key_up("D")              # the shifted one, from its own test
        self.c.run_frames(2)

    def assert_only(self, expected):
        """Exactly these ids are down and no others."""
        for name in ALL_IDS:
            want = name in expected
            self.assertEqual(
                self.down(name), want,
                f"{name}: expected {'down' if want else 'up'} "
                f"while {sorted(expected)} held; state={self.state()}")


class TestScan(KeyboardFixture):

    def test_an_idle_keyboard_reports_nothing_down(self):
        """The #FF-forever bug's mirror image: a scan that invents keypresses."""
        self.scan()
        self.assertEqual(self.state(), [0] * KEY_ROWS)
        self.assert_only(set())

    def test_a_single_key_lights_exactly_one_bit(self):
        """No ghosting: one key down must not light its neighbours' rows.

        A scan that leaves the PPI's row select stale, or that reads the same
        row ten times, still reports 'a' keypress -- it just reports it in
        several places at once. Counting bits catches that; counting keys does
        not.
        """
        self.press("1")
        self.scan()
        state = self.state()
        bits = sum(bin(b).count("1") for b in state)
        self.assertEqual(bits, 1, f"'1' lit {bits} matrix bits: {state}")
        self.release("1")

    def test_every_key_is_seen_at_its_own_id(self):
        """The classic bug is reporting *a* keypress for the wrong id."""
        for char, name in PRESSABLE:
            with self.subTest(key=name):
                self.press(char)
                self.scan()
                self.assert_only({name})
                self.release(char)

    def test_two_keys_at_once(self):
        self.press("1")
        self.press("d")
        self.scan()
        self.assert_only({"KEY_1", "KEY_D"})
        self.release("1")
        self.release("d")

    def test_shift_and_a_letter_together(self):
        """Upper-case D presses SHIFT and D, on two different matrix rows."""
        self.press("D")
        self.scan()
        self.assert_only({"KEY_SHIFT", "KEY_D"})
        self.release("D")

    def test_releasing_a_key_clears_it(self):
        self.press("5")
        self.scan()
        self.assertTrue(self.down("KEY_5"))
        self.release("5")
        self.scan()
        self.assert_only(set())

    def test_the_scan_survives_being_run_over_and_over(self):
        """Ten scans in a row must agree -- the PPI is left as it was found.

        key_scan reconfigures PPI port A to read the PSG and has to put it
        back. If it did not, the second scan would behave differently from the
        first, which is precisely the kind of bug that only shows up once the
        routine is in the frame loop.
        """
        self.press("n")
        for i in range(10):
            self.scan()
            self.assertTrue(self.down("KEY_N"), f"scan {i} lost the key")
            self.assertEqual(sum(bin(b).count("1") for b in self.state()), 1)
        self.release("n")


class TestDigits(KeyboardFixture):
    """key_digit: digit -> key id.

    The squadron keys are the game's busiest input and the one place where the
    obvious shortcut is wrong: the digits are not consecutive in the matrix, so
    `KEY_1 + n` lands on ESC, Q, TAB and A instead of on 3, 4, 5 and 6.
    """

    def test_every_digit_maps_to_its_own_key(self):
        for digit in range(10):
            with self.subTest(digit=digit):
                self.press(str(digit))
                self.scan()
                down, key_id = self.digit_down(digit)
                self.assertEqual(key_id, self.sym[f"KEY_{digit}"],
                                 f"key_digit({digit}) returned #{key_id:02X}")
                self.assertTrue(down, f"pressed {digit}, key_digit missed it")
                self.release(str(digit))

    def test_a_digit_does_not_answer_for_its_neighbours(self):
        self.press("7")
        self.scan()
        for digit in range(10):
            down, _ = self.digit_down(digit)
            self.assertEqual(down, digit == 7,
                             f"'7' held but key_digit({digit}) says "
                             f"{'down' if down else 'up'}")
        self.release("7")


class TestEdges(KeyboardFixture):

    def test_a_held_key_hits_exactly_once(self):
        """Homeplanet.md section 9: holding `d` splits the squadron once.

        Now that the matrix is sampled fifty times a second and a game frame is
        ten of those, this is the property most at risk from the change: an
        accumulator that forgot to check key_state would hand the frame ten
        edges instead of one, and the squadron would be divided until there was
        nothing left of it. So the hold is several SCANS long inside one frame,
        not one scan per frame.
        """
        self.press("d")
        for _ in range(10):
            self.scan()
        self.consume()
        self.assertTrue(self.hit("KEY_D"), "ten scans over a press saw nothing")
        self.assertTrue(self.down("KEY_D"))

        for i in range(5):
            self.frame()
            self.assertFalse(self.hit("KEY_D"),
                             f"frame {i + 2} fired the edge again -- the "
                             f"squadron would split every frame")
            self.assertTrue(self.down("KEY_D"), "but it is still held")

        self.release("d")
        self.frame()
        self.assertFalse(self.hit("KEY_D"))
        self.assertFalse(self.down("KEY_D"))

        self.press("d")
        self.frame()
        self.assertTrue(self.hit("KEY_D"), "a second press must hit again")
        self.release("d")

    def test_an_idle_keyboard_hits_nothing(self):
        self.frame()
        self.frame()
        for name in ALL_IDS:
            self.assertFalse(self.hit(name), name)

    def test_an_edge_is_only_reported_for_the_key_that_moved(self):
        """One key already held, a second one arrives: only the new one hits."""
        self.press("1")
        self.frame()
        self.frame()                    # 1's edge is spent
        self.press("2")
        self.frame()
        self.assertFalse(self.hit("KEY_1"))
        self.assertTrue(self.hit("KEY_2"))
        self.assertTrue(self.down("KEY_1"))
        self.assertTrue(self.down("KEY_2"))
        self.release("1")
        self.release("2")

    def test_an_edge_survives_until_a_frame_collects_it(self):
        """THE bug, in miniature.

        A key that goes down and comes back up between two frames used to be
        gone: key_scan rebuilt key_edge from the hardware, so the release wiped
        the press before anything read it. Here the key is up again -- not
        merely up, but seen to be up by three further scans -- before the frame
        that collects the edge ever runs, and the press must still be there.
        """
        self.press("d")
        self.scan()                                     # the interrupt sees it
        self.release("d")
        for _ in range(3):
            self.scan()                                 # ...and sees it go
        self.assertFalse(self.down("KEY_D"), "it should be up by now")

        self.consume()
        self.assertTrue(self.hit("KEY_D"),
                        "the press was dropped because the key was released "
                        "before the frame got round to reading it")

    def test_edges_pile_up_across_a_whole_frame(self):
        """Two different keys inside one frame both arrive, in the same frame.

        Fifty samples a second against five frames a second means a frame can
        legitimately be handed several presses at once, and the array is an OR
        rather than a replace so that none of them is lost to the next one.
        """
        self.press("d")
        self.scan()
        self.release("d")
        self.scan()
        self.press("n")
        self.scan()
        self.release("n")
        self.scan()

        self.consume()
        self.assertTrue(self.hit("KEY_D"), "the first of the two was dropped")
        self.assertTrue(self.hit("KEY_N"), "the second of the two was dropped")

    def test_consume_hands_an_edge_to_one_frame_only(self):
        """Otherwise a tap would repeat for as long as nothing else happened."""
        self.press("d")
        self.frame()
        self.assertTrue(self.hit("KEY_D"))
        self.release("d")
        self.consume()
        self.assertFalse(self.hit("KEY_D"),
                         "the same press was handed out twice")


class TestAShortPressIsNotLost(unittest.TestCase):
    """A keypress of a REALISTIC LENGTH, in the running game.

    This is the test that was missing, and its absence is the whole reason the
    bug shipped. Every other keyboard test in the suite -- here, in test_phase5,
    in test_menu, in test_squad -- holds its key for 25 emulator frames or more.
    That is half a second. It is not a keypress, it is leaning on the keyboard,
    and it passes whether the matrix is sampled at 50 Hz or once an hour.

    A quick tap on a real keyboard is 50-100 ms. When key_scan was called once
    per game frame -- and the game runs at about five frames a second, not the
    12.5 it aims at -- the matrix was read every 200 ms, so a key that went down
    and came back up in between was never seen. Measured on that build:

        held  2 frames ( 40 ms): 2/6 registered
        held  4 frames ( 80 ms): 4/6
        held  6 frames (120 ms): 6/6

    SPACE is the key to test it with because ORDER_PAUSED toggles, so one press
    is exactly one observable change and a press that arrived twice would show
    up as one that did not arrive at all.
    """

    KEY_SPACE = 0x20
    KEY_X = "x"

    #  Two emulator frames is 40 ms, near the short end of a human tap. The
    #  scan runs every 20 ms, so nothing this long can fall between two of them.
    TAP_FRAMES = 2
    TRIALS = 6

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=400)
        cls.sym = h.symbols()

    @classmethod
    def tearDownClass(cls):
        h.close(getattr(cls, "c", None))

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def tap(self, key, frames):
        """Press, hold for `frames` emulator frames, release, let it land."""
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        #  Long enough for the release to be scanned and for a game frame to
        #  run and act on the edge -- a game frame is about ten of these.
        self.c.run_frames(40)

    def test_a_forty_millisecond_tap_registers_every_time(self):
        misses = []
        for trial in range(self.TRIALS):
            before = self.byte("ORDER_PAUSED")
            self.tap(self.KEY_SPACE, self.TAP_FRAMES)
            if self.byte("ORDER_PAUSED") == before:
                misses.append(trial)
        self.assertEqual(
            misses, [],
            f"{len(misses)} of {self.TRIALS} taps of "
            f"{self.TAP_FRAMES * 20} ms were dropped (trials {misses}); the "
            f"keyboard is not being sampled often enough")

    def test_even_a_single_frame_tap_registers(self):
        """20 ms, the scan period itself. Not a promise -- a canary.

        If this ever starts failing while the test above still passes, the scan
        has slipped off the 50 Hz tick onto something slower.
        """
        misses = 0
        for _ in range(self.TRIALS):
            before = self.byte("ORDER_PAUSED")
            self.tap(self.KEY_SPACE, 1)
            if self.byte("ORDER_PAUSED") == before:
                misses += 1
        self.assertEqual(misses, 0,
                         f"{misses} of {self.TRIALS} 20 ms taps were dropped")

    def test_holding_a_key_still_acts_exactly_once(self):
        """The other half of the bargain, and the one a fix can break.

        Edges accumulate between frames now, so the obvious mistake is to
        accumulate the HELD state instead of the transition -- at which point
        one leaned-on key becomes ten presses a frame. `X` counts, which is why
        it is the key here: zoom is twelve discrete steps, so 'acted once' and
        'acted eleven times' are different numbers rather than the same flag
        flipped an odd number of times.
        """
        start = self.byte("CAM_ZOOM")
        self.c.key_down(self.KEY_X)
        self.c.run_frames(120)              # about a dozen game frames
        self.c.key_up(self.KEY_X)
        self.c.run_frames(40)
        self.assertEqual(
            self.byte("CAM_ZOOM"), start + 1,
            "holding X did not step the zoom exactly one notch -- every "
            "command in the game is edge-triggered and this is the guard")


class TestIds(unittest.TestCase):
    """The id encoding itself: (row << 3) | bit, with row < 10."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def test_ids_are_inside_the_matrix(self):
        for name in ALL_IDS:
            value = self.sym[name]
            self.assertLess(value >> 3, KEY_ROWS, f"{name} is off the matrix")

    def test_ids_are_distinct(self):
        seen = {}
        for name in ALL_IDS:
            value = self.sym[name]
            self.assertNotIn(value, seen,
                             f"{name} and {seen.get(value)} are the same key")
            seen[value] = name


if __name__ == "__main__":
    unittest.main()
