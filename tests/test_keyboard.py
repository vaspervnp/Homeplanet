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
STUB = 0x3000
RESULT = 0x2F00

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
    ("x", "KEY_X"),
    ("z", "KEY_Z"),
    (0x20, "KEY_SPACE"),
    (0x0B, "KEY_CUR_UP"),
    (0x0A, "KEY_CUR_DOWN"),
    (0x08, "KEY_CUR_LEFT"),
    (0x09, "KEY_CUR_RIGHT"),
    (0x0D, "KEY_ENTER"),
]

ALL_IDS = [name for _, name in PRESSABLE] + ["KEY_TAB", "KEY_SHIFT"]


class KeyboardFixture(unittest.TestCase):
    """Drive key_scan / key_down / key_hit directly, with real keypresses."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()

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
        """Call key_scan once, exactly as the frame loop would."""
        addr = self.sym["KEY_SCAN"]
        self._run_stub([0xF3,                                   # di
                        0xCD, addr & 0xFF, addr >> 8,           # call key_scan
                        0x18, 0xFE])                            # jr $

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


class TestEdges(KeyboardFixture):

    def test_a_held_key_hits_exactly_once(self):
        """Homeplanet.md section 9: holding `d` splits the squadron once."""
        self.press("d")
        self.scan()
        self.assertTrue(self.hit("KEY_D"), "the first scan missed the press")
        self.assertTrue(self.down("KEY_D"))

        for i in range(5):
            self.scan()
            self.assertFalse(self.hit("KEY_D"),
                             f"scan {i + 2} fired the edge again -- the "
                             f"squadron would split every frame")
            self.assertTrue(self.down("KEY_D"), "but it is still held")

        self.release("d")
        self.scan()
        self.assertFalse(self.hit("KEY_D"))
        self.assertFalse(self.down("KEY_D"))

        self.press("d")
        self.scan()
        self.assertTrue(self.hit("KEY_D"), "a second press must hit again")
        self.release("d")

    def test_an_idle_keyboard_hits_nothing(self):
        self.scan()
        self.scan()
        for name in ALL_IDS:
            self.assertFalse(self.hit(name), name)

    def test_an_edge_is_only_reported_for_the_key_that_moved(self):
        """One key already held, a second one arrives: only the new one hits."""
        self.press("1")
        self.scan()
        self.scan()                     # 1's edge is spent
        self.press("2")
        self.scan()
        self.assertFalse(self.hit("KEY_1"))
        self.assertTrue(self.hit("KEY_2"))
        self.assertTrue(self.down("KEY_1"))
        self.assertTrue(self.down("KEY_2"))
        self.release("1")
        self.release("2")


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
