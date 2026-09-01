"""ESC brings up the orders; cursor keys pick one.

The interesting property is not the drawing, it is that the menu does not
know what any command means. Each entry carries a key id, and choosing one
injects that key and lets phase4_commands do the work -- so the tests here
follow a menu selection all the way through to the thing it was supposed to
do, and a menu that drifted from the keyboard would fail them.

It runs from bank 4, so its state is read through read_cpu.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

MENU_COUNT = 15
#  Row order, mirrored from src/game/menutext.asm. SPLIT BY CLASS went in at 6,
#  beside the other thing that reshapes the fleet, and moved everything below it
#  down one. SQUADRON INFO went in at 12, next to CONTROLS -- the two entries
#  that tell you something rather than order somebody -- so only CONTROLS moved.
#  TOW WRECKS went in at 4, beside HARVEST because it is the same order for the
#  other work ship, and moved everything below IT down one again.
ROW_ATTACK, ROW_TOW, ROW_BY_CLASS, ROW_SENSORS, ROW_MOVE = 0, 4, 7, 8, 9
ROW_PAN, ROW_CENTRE, ROW_INFO, ROW_CONTROLS = 11, 12, 13, 14

ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walks range(ENT_MAX) then stops looking
#  exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_FLAGS, ENT_ORDER = 11, 13
F_ACTIVE, F_ENEMY = 1, 2
ENT_ORDER_ATTACK = 2


class MenuFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=400)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def banked(self, name):
        return h.read_bank4(self.c, self.sym[name], 1)[0]

    def press(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        #  Long enough for key_scan to see the release: every command in the
        #  game is edge-triggered, and a game frame is ten emulator frames.
        self.c.run_frames(30)

    def open_menu(self):
        self.press(cpc.KEY_ESC)
        self.assertEqual(self.banked("MENU_SHOWN"), 1, "ESC did not bring up the orders")

    def choose(self, row):
        """Walk down to a row and take it."""
        self.open_menu()
        for _ in range(row):
            self.press(cpc.KEY_DOWN)
        self.assertEqual(self.banked("MENU_PICK"), row)
        self.press(cpc.KEY_ENTER)
        self.c.run_frames(40)
        self.assertEqual(self.banked("MENU_SHOWN"), 0, "the menu stayed up after ENTER")


class TestOpeningAndPicking(MenuFixture):

    def test_escape_opens_it_and_escape_closes_it(self):
        self.assertEqual(self.banked("MENU_SHOWN"), 0)
        self.open_menu()
        self.press(cpc.KEY_ESC)
        self.assertEqual(self.banked("MENU_SHOWN"), 0, "ESC did not close the orders")

    def test_the_cursor_keys_walk_the_list_and_wrap(self):
        self.open_menu()
        self.assertEqual(self.banked("MENU_PICK"), 0)
        self.press(cpc.KEY_DOWN)
        self.assertEqual(self.banked("MENU_PICK"), 1)
        self.press(cpc.KEY_UP)
        self.assertEqual(self.banked("MENU_PICK"), 0)

        #  Off the top comes round to the bottom, which is the only way to
        #  reach the last entry without pressing DOWN nine times.
        self.press(cpc.KEY_UP)
        self.assertEqual(self.banked("MENU_PICK"), MENU_COUNT - 1,
                         "the selection did not wrap round the top")
        self.press(cpc.KEY_DOWN)
        self.assertEqual(self.banked("MENU_PICK"), 0,
                         "the selection did not wrap round the bottom")

    def test_nothing_simulates_while_it_is_up(self):
        base = self.sym["ENTITIES"]
        self.open_menu()
        self.c.run_frames(10)
        before = [self.c.read_ram(base + s * ENT_SIZE, 6) for s in range(ENT_MAX)]
        shots = self.byte("CBT_SHOTS")
        self.c.run_frames(200)
        self.assertEqual([self.c.read_ram(base + s * ENT_SIZE, 6) for s in range(ENT_MAX)],
                         before, "the fleet flew on behind the orders menu")
        self.assertEqual(self.byte("CBT_SHOTS"), shots, "the battle carried on")


class TestPickingActuallyDoesIt(MenuFixture):
    """The menu injects a keypress rather than calling the command itself.

    So each of these is really asking: does the row still name the key that
    does the thing? A table that drifted from the keyboard would pass a test
    that only looked at menu state.
    """

    def test_sensors_changes_the_view(self):
        self.assertEqual(self.byte("VIEW_SENSORS"), 0)
        self.choose(ROW_SENSORS)
        self.assertEqual(self.byte("VIEW_SENSORS"), 1,
                         "choosing SENSORS did not change the view")

    def test_attack_issues_the_order(self):
        """It needs something to attack, and that is not incidental.

        The fixture opens on mission 1, which has no enemies at all, and an
        attack order is now SPENT the moment there is nothing left to shoot at
        -- see cbt_fire_if_able. So an order given into an empty sky is gone
        again within a few frames, correctly, and asserting it survived there
        would be asserting the bug that stranded the fleet after every fight.
        One hostile, far enough out that nothing happens to it in the frames
        this takes, and the order has something to hold onto.
        """
        def attacking():
            return sum(1 for s in range(ENT_MAX)
                       if (self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_FLAGS, 1)[0] & 3) == F_ACTIVE
                       and self.c.read_ram(self.sym["ENTITIES"] + s * ENT_SIZE + ENT_ORDER, 1)[0] == ENT_ORDER_ATTACK)

        #  In the HOSTILE region. Slot 47 was the top of a 48-slot table and is
        #  now inside the fleet's half, where cbt_find_enemy will not look for
        #  it -- see tests/test_combat.TestConcentration.even_duel.
        base = self.sym["ENTITIES"] + (ENT_MAX - 1) * ENT_SIZE
        self.c.write_ram(base, struct.pack("<hhh", 0, 0, 12000))
        self.c.write_ram(base + 9, bytes([0]))              # ENT_CLASS: interceptor
        self.c.write_ram(base + 10, bytes([255]))           # ENT_HULL
        self.c.write_ram(base + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))

        self.assertEqual(attacking(), 0)
        self.choose(ROW_ATTACK)
        self.assertGreater(attacking(), 0, "choosing ATTACK ordered nobody to attack")

    def test_move_disc_opens_the_disc(self):
        self.assertEqual(self.byte("DISC_ACTIVE"), 0)
        self.choose(ROW_MOVE)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1,
                         "choosing MOVE DISC did not open it")

    def test_controls_opens_the_key_list(self):
        self.choose(ROW_CONTROLS)
        self.assertEqual(self.banked("HELP_SHOWN"), 1,
                         "choosing CONTROLS did not put the key list up")

    def test_squadron_info_opens_the_breakdown(self):
        """INFO_SHOWN is in the LOW 16K, not the bank: squadinfo.asm is one of
        the two static screens that did not fit in bank 4."""
        self.choose(ROW_INFO)
        self.assertEqual(self.byte("INFO_SHOWN"), 1,
                         "choosing SQUADRON INFO did not put the breakdown up")


class TestTheView(MenuFixture):
    """Section 4.3's camera, now that the player can leave the middle."""

    def pan(self):
        base = self.sym["CAM_PAN"]
        return tuple(int.from_bytes(self.c.read_ram(base + i * 2, 2), "little", signed=True)
                     for i in range(3))

    def test_pan_hands_the_cursor_keys_to_the_camera(self):
        self.assertEqual(self.byte("PAN_ACTIVE"), 0)
        yaw = self.byte("CAM_YAW")
        self.choose(ROW_PAN)
        self.assertEqual(self.byte("PAN_ACTIVE"), 1, "PAN VIEW did not turn panning on")

        self.assertEqual(self.pan(), (0, 0, 0))
        self.press(cpc.KEY_RIGHT, frames=60)
        self.assertNotEqual(self.pan(), (0, 0, 0), "the cursor keys did not move the view")
        self.assertEqual(self.byte("CAM_YAW"), yaw,
                         "the cursor keys orbited the camera as well as panning it")

    def test_centring_undoes_the_pan(self):
        """Otherwise "centre" leaves the camera exactly as far off the
        Mothership as the player had wandered -- which is the state they
        pressed it to get out of."""
        self.choose(ROW_PAN)
        self.press(cpc.KEY_RIGHT, frames=60)
        self.press(cpc.KEY_UP, frames=60)
        self.assertNotEqual(self.pan(), (0, 0, 0))

        self.choose(ROW_CENTRE)
        self.assertEqual(self.pan(), (0, 0, 0), "centring did not clear the pan")
        self.assertEqual(self.byte("PAN_ACTIVE"), 0,
                         "centring left the cursor keys panning")
        self.assertEqual(self.byte("SEL_MOTHERSHIP"), 1,
                         "centring did not select the Mothership")


class TestItDoesNotLeakTheKeyThatOpenedIt(MenuFixture):

    def test_choosing_an_order_does_not_also_cancel_it(self):
        """ESC opened the menu and ESC means "cancel" to order_update.

        Left in key_edge it would reach order_update on the very frame the
        chosen order was issued -- and cancel the move disc the player had
        just asked for. key_clear is what stops that, and this is the test
        that would notice if it went.
        """
        self.choose(ROW_MOVE)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1)
        self.c.run_frames(60)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1,
                         "the ESC that opened the menu cancelled the order it gave")

    def test_escape_cancels_the_move_disc_rather_than_opening_the_menu(self):
        """While something is open ESC still means what it always meant."""
        self.choose(ROW_MOVE)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1)

        self.press(cpc.KEY_ESC)
        self.assertEqual(self.byte("DISC_ACTIVE"), 0, "ESC did not cancel the disc")
        self.assertEqual(self.banked("MENU_SHOWN"), 0,
                         "ESC opened the orders instead of cancelling the disc")


class TestTheShortcutsAreShown(MenuFixture):

    def test_every_row_names_its_key(self):
        """"Show the keyboard shortcuts after each command" -- so each line
        has to end in one, and the key it ends in has to be the key the entry
        actually injects."""
        base = self.sym["MENU_ENTRIES"]
        raw = h.read_bank4(self.c, base, self.sym["MENU_ENTRIES_END"] - base)

        rows, i = [], 0
        while i < len(raw):
            key = raw[i]
            end = raw.index(0, i + 1)
            rows.append((key, raw[i + 1:end].decode("ascii")))
            i = end + 1

        self.assertEqual(len(rows), MENU_COUNT)
        for key, text in rows:
            self.assertEqual(len(text), 17, f"{text!r} is not the field width")
            self.assertNotEqual(text.rstrip(), text.rstrip().split()[0],
                                f"{text!r} has a command but no shortcut after it")

        #  And the printed shortcut is the key that gets injected, for the
        #  ones that are a single letter.
        for key, text in rows:
            shortcut = text.split()[-1]
            if len(shortcut) == 1 and shortcut.isalpha():
                name = f"KEY_{shortcut}"
                self.assertIn(name, self.sym, f"{name} is not a key id")
                self.assertEqual(key, self.sym[name],
                                 f"the row says {shortcut} but injects something else")


if __name__ == "__main__":
    unittest.main()
