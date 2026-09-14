"""The button bar (game/hudbar.asm, bank 6): sixteen icons along the bottom
strip, a frame the arrows (or the joystick) move, ENTER (or fire) pressing
the key under it, groups as sub-bars, SHIFT + the arrows still orbiting, and
the description on the strip's third line for four seconds.

Read off the PIXELS wherever the bar draws -- the frame's column, the icon's
bytes against the sheet in build/bank5.raw, the caption on its line -- and
off bank 6 through harness.read_bank where it keeps state, because every
earlier readout bug this project has had passed on the variables.
"""
import os
import sys
import unittest

from tests import harness as h

import cpc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import hudicons  # noqa: E402

FIRST_CHAR, LAST_CHAR, CHAR_H, CHAR_W_BYTES = 32, 90, 8, 2
BANK_6 = 0xC6
TOP_ROW = ("move", "build", "attack", "harvest", "info", "formation", "station",
           "guard", "jump", "pause", "menu",
           "grp_combat", "grp_economy", "grp_squadron", "grp_camera", "grp_system")


class BarFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.icons = hudicons.read(hudicons.PNG)
        cls.index = {name: i for i, (name, _, _, _, _, _) in enumerate(hudicons.BANKED)}

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.let_the_game_draw(self.c, self.sym)
        self.font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H))
        self.c.run_frames(30)               # ...and the bar's own first paint, both buffers

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- pressing -------------------------------------------------------------
    def hold(self, key, frames=20, release=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def shifted(self, key, frames=40, release=30):
        """SHIFT + a key: the emulator takes an uppercase character as the
        modifier, and the game binds Q to nothing."""
        self.c.key_down("Q")
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.key_up("Q")
        self.c.run_frames(release)

    def go(self, slot):
        """Walk the frame to a slot from wherever it is, with RIGHT."""
        for _ in range(32):
            if self.framed_slot() == slot:
                return
            self.hold(cpc.KEY_RIGHT, release=15)
        self.fail(f"the frame never reached slot {slot}")

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def bank6(self, name, size=1):
        return h.read_bank(self.c, BANK_6, self.sym[name], size)

    # -- reading the row ---------------------------------------------------------
    def slot_bytes(self, slot, base=None):
        """The 4x16 bytes of a slot's cell, off one screen buffer."""
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        x0 = self.sym["BAR_X0"] + slot * self.sym["BAR_PITCH"]
        y0 = self.sym["HUD_BTN_Y"]
        return [[ram[h.screen_offset(y0 + r, x0 + x)] for x in range(4)] for r in range(16)]

    def icon_bytes(self, name):
        """The cell's sixteen rows, the top and bottom blank: the bank holds
        rows 1..14, and the row is drawn from HUD_BTN_Y + 1."""
        data = hudicons.encode(self.icons[name])
        return [[0] * 4] + [list(data[r * 4:(r + 1) * 4]) for r in range(14)] + [[0] * 4]

    def framed_slot(self, base=None):
        """Which slot carries the blue frame: a top line of four #0F bytes and
        a blue leftmost pixel down the side. None if no slot does."""
        found = []
        for slot in range(16):
            cell = self.slot_bytes(slot, base)
            if cell[0] == [0x0F] * 4 and cell[15] == [0x0F] * 4 \
                    and all((row[0] & 0x88) == 0x08 for row in cell[1:15]):
                found.append(slot)
        self.assertLessEqual(len(found), 1, f"the frame is on {found}")
        return found[0] if found else None

    def assert_icon_at(self, slot, name):
        """The cell holds the icon -- inside the frame's one-pixel rim, so it
        can be asserted whether the slot is selected or not."""
        cell = self.slot_bytes(slot)
        want = self.icon_bytes(name)
        for r in range(1, 15):
            for x in range(4):
                mask = 0x77 if x == 0 else (0xEE if x == 3 else 0xFF)
                self.assertEqual(cell[r][x] & mask, want[r][x] & mask,
                                 f"slot {slot} row {r} byte {x} is not {name}")

    # -- reading the strip's text lines -----------------------------------------
    def context_line(self, base=None):
        return self.text_line(self.sym["CTX_LINE_Y"], base)

    def desc_line(self, base=None):
        """The strip's third line: the selected button's caption."""
        return self.text_line(self.sym["HUD_DESC_Y"], base)

    def text_line(self, y, base=None):
        if base is None:
            base = h.front_buffer(self.c)
        ram = self.c.read_ram(base, 0x4000)
        raw = [[(ram[h.screen_offset(y + r, x)] | (ram[h.screen_offset(y + r, x)] << 4)) & 0xF0
                for x in range(80)] for r in range(CHAR_H)]
        out = []
        for cell in range(40):
            x = cell * CHAR_W_BYTES
            want = [(raw[r][x], raw[r][x + 1]) for r in range(CHAR_H)]
            out.append(self._match(want))
        return "".join(out).rstrip()

    def _match(self, cell):
        for code in range(FIRST_CHAR, LAST_CHAR + 1):
            i = (code - FIRST_CHAR) * CHAR_H
            g = self.font[i:i + CHAR_H]
            if all(cell[r] == (g[r] & 0xF0, (g[r] << 4) & 0xF0) for r in range(CHAR_H)):
                return chr(code)
        return "?"


class TestTheRow(BarFixture):

    def test_sixteen_buttons_with_move_first_and_the_frame_on_it(self):
        """MOVE first, so ENTER at rest opens the disc as it always did."""
        self.assertEqual(self.framed_slot(), 0)
        for slot, name in enumerate(TOP_ROW):
            self.assert_icon_at(slot, name)

    def test_the_row_is_in_both_buffers(self):
        for base in (0x8000, 0xC000):
            self.assertEqual(self.framed_slot(base), 0, f"no frame in {base:#06x}")

    def test_the_icons_are_the_ones_on_the_disc(self):
        """The bytes on the screen are bank 5's, and bank 5 is the sheet."""
        raw = open(os.path.join(ROOT, "build", "bank5.raw"), "rb").read()
        base = self.sym["HUD_ICONS"] - 0x4000
        i = self.index["build"]
        want = raw[base + i * 56:base + (i + 1) * 56]
        cell = self.slot_bytes(1)
        self.assertEqual(bytes(b for row in cell[1:15] for b in row), want)
        self.assertEqual(cell[0], [0] * 4)
        self.assertEqual(cell[15], [0] * 4)


class TestTheArrows(BarFixture):

    def test_right_moves_the_frame_and_the_description_names_the_button(self):
        self.hold(cpc.KEY_RIGHT)
        self.assertEqual(self.framed_slot(), 1)
        self.assertEqual(self.desc_line(), hudicons.caption("build"))
        self.hold(cpc.KEY_RIGHT)
        self.assertEqual(self.framed_slot(), 2)
        self.assertEqual(self.desc_line(), hudicons.caption("attack"))

    def test_left_wraps_round_to_the_last_button(self):
        self.hold(cpc.KEY_LEFT)
        self.assertEqual(self.framed_slot(), 15)
        self.assertEqual(self.desc_line(), hudicons.caption("grp_system"))
        self.assertEqual(self.bank6("BAR_SEL")[0], 15)

    def test_the_description_goes_away_after_four_seconds(self):
        self.hold(cpc.KEY_RIGHT, release=10)
        self.assertEqual(self.desc_line(), hudicons.caption("build"))
        self.c.run_frames(self.sym["BAR_DESC_TICKS"] + 40)
        self.assertEqual(self.desc_line(), "")

    def test_the_bare_arrows_no_longer_orbit_and_shifted_ones_do(self):
        """The bar owns them by default (hud2.md section 2); SHIFT + the
        arrows are the camera's, as the bare arrows used to be -- and while
        SHIFT is down the frame stays where it is."""
        yaw = self.byte("CAM_YAW")
        self.hold(cpc.KEY_RIGHT, frames=40)
        self.assertEqual(self.byte("CAM_YAW"), yaw, "RIGHT still orbits the camera")
        self.assertEqual(self.framed_slot(), 1)
        self.shifted(cpc.KEY_RIGHT)
        self.assertNotEqual(self.byte("CAM_YAW"), yaw, "SHIFT + RIGHT does not orbit")
        self.assertEqual(self.framed_slot(), 1, "SHIFT + RIGHT moved the frame")

    def test_a_state_and_a_description_share_the_strip_on_two_lines(self):
        """PAUSED on the context line, the caption on the line under it --
        the owner's third line, so the two never fight for one."""
        self.go(9)                                  # PAUSE
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        self.hold(cpc.KEY_RIGHT, release=10)        # MENU: a fresh caption, while paused
        self.assertTrue(self.context_line().startswith("PAUSED"), self.context_line())
        self.assertEqual(self.desc_line(), hudicons.caption("menu"))


class TestPressing(BarFixture):

    def test_enter_on_pause_pauses_and_does_not_open_the_disc(self):
        self.go(9)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "PAUSE did not pause")
        self.assertEqual(self.byte("DISC_ACTIVE"), 0, "the ENTER that pressed the button opened the disc")

    def test_enter_on_menu_opens_the_orders_menu(self):
        self.go(10)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(h.read_bank4(self.c, self.sym["MENU_SHOWN"], 1)[0], 1)

    def test_enter_at_rest_opens_the_disc_and_the_disc_then_has_the_arrows(self):
        """MOVE is the first button and the frame starts on it, so a plain
        ENTER still opens the move disc -- and while it is open the arrows
        are the disc's, not the bar's."""
        self.assertEqual(self.framed_slot(), 0)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("DISC_ACTIVE"), 1, "ENTER did not open the disc")
        self.hold(cpc.KEY_RIGHT)
        self.assertEqual(self.bank6("BAR_SEL")[0], 0, "the arrows moved the frame while the disc was open")

    def test_enter_on_attack_is_the_attack_key(self):
        """Mission 1 has nothing to attack, so `A` ARMS the auto response --
        which is what pressing the key does, and so what the button does."""
        self.go(2)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(h.read_bank4(self.c, self.sym["AUTO_ARMED"], 1)[0], 1,
                         "ATTACK did not do what A does")


class TestAKeySelectsItsButton(BarFixture):
    """"Όταν πατάω ένα πλήκτρο που αντιστοιχεί σε ορατό κουμπί, να επιλέγεται
    το κουμπί και να εκτελείται η εντολή." The frame follows the key, the
    command still runs, and a key whose button is not showing moves nothing."""

    def test_space_selects_pause_and_pauses(self):
        self.hold(cpc.KEY_SPACE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "SPACE did not pause")
        self.assertEqual(self.framed_slot(), 9, "the frame did not follow SPACE to PAUSE")
        self.assertEqual(self.desc_line(), hudicons.caption("pause"))

    def test_b_selects_build_and_opens_the_yard(self):
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")
        self.assertEqual(self.framed_slot(), 1, "the frame did not follow B to BUILD")

    def test_a_key_whose_button_is_in_a_closed_group_moves_nothing(self):
        self.hold("t")                          # TOW, inside ECONOMY+
        self.assertEqual(self.framed_slot(), 0)
        self.assertEqual(self.desc_line(), "")

    def test_inside_a_group_a_members_key_selects_it(self):
        self.go(12)                             # ECONOMY+
        self.hold(cpc.KEY_ENTER)
        self.assert_icon_at(1, "tow")
        self.hold("e")                          # REPAIR, the second member
        self.assertEqual(self.framed_slot(), 2, "the frame did not follow E to REPAIR")
        self.assertEqual(self.desc_line(), hudicons.caption("repair"))

    def test_the_arrows_walk_the_bar_with_the_build_panel_open_and_enter_stays_the_panels(self):
        """"Τα βελάκια δεξιά αριστερά και η επιλογή κουμπιών να έχουν απόλυτη
        προτεραιότητα": the yard's panel takes , . and ENTER, not the arrows."""
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1)
        self.assertEqual(self.framed_slot(), 1)              # B selected BUILD
        self.go(9)                                           # PAUSE, panel still up
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "walking the bar shut the panel")
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.byte("ORDER_PAUSED"), 0, "ENTER pressed the button instead of buying")

    def test_enter_does_not_jump_the_frame_to_move(self):
        """ENTER is MOVE's key and the bar's own press: with the frame on
        ATTACK it presses ATTACK, and the frame stays there."""
        self.go(2)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.framed_slot(), 2)


class TestTheJoystick(BarFixture):
    """"Τα κουμπιά να επιλέγονται και με joystick." Joystick 1 is row 9 of the
    matrix, so the stick walks and fire presses. The emulator's digital
    joystick diverts the cursor keys, so these tests drive the stick alone."""

    def setUp(self):
        super().setUp()
        self.c.set_joystick_type(1)

    def stick(self, mask, frames=20, release=30):
        self.c.joystick(mask)
        self.c.run_frames(frames)
        self.c.joystick(0)
        self.c.run_frames(release)

    def test_the_stick_walks_the_frame_both_ways(self):
        self.stick(cpc.JOY_RIGHT)
        self.assertEqual(self.framed_slot(), 1)
        self.assertEqual(self.desc_line(), hudicons.caption("build"))
        self.stick(cpc.JOY_LEFT)
        self.stick(cpc.JOY_LEFT)
        self.assertEqual(self.framed_slot(), 15)

    def test_fire_presses_the_button(self):
        for _ in range(9):
            self.stick(cpc.JOY_RIGHT, release=15)
        self.assertEqual(self.framed_slot(), 9)     # PAUSE
        self.stick(cpc.JOY_FIRE)
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "fire did not press PAUSE")
        self.assertEqual(self.byte("DISC_ACTIVE"), 0)


class TestGroups(BarFixture):

    def open_system(self):
        self.hold(cpc.KEY_LEFT)                 # slot 15: SYSTEM
        self.assertEqual(self.framed_slot(), 15)
        self.hold(cpc.KEY_ENTER)

    def test_a_group_opens_as_a_sub_bar_with_back_first(self):
        self.open_system()
        self.assertEqual(self.bank6("BAR_GROUP")[0], 4)
        self.assert_icon_at(0, "back")
        self.assert_icon_at(1, "help")
        self.assert_icon_at(2, "music")
        self.assertEqual(self.framed_slot(), 1, "the frame did not land on the first member")
        self.assertEqual(self.desc_line(), hudicons.caption("help"))
        for slot in range(3, 16):
            self.assertEqual(self.slot_bytes(slot), [[0] * 4] * 16, f"slot {slot} is not blank")

    def test_back_closes_it_and_the_frame_returns_to_the_group(self):
        self.open_system()
        self.hold(cpc.KEY_LEFT)
        self.assertEqual(self.framed_slot(), 0)
        self.hold(cpc.KEY_ENTER)
        self.assertEqual(self.bank6("BAR_GROUP")[0], 0xFF)
        self.assertEqual(self.framed_slot(), 15)
        self.assert_icon_at(0, "move")

    def test_escape_closes_it_without_opening_the_menu(self):
        self.open_system()
        self.hold(cpc.KEY_ESC)
        self.assertEqual(self.bank6("BAR_GROUP")[0], 0xFF)
        self.assertEqual(h.read_bank4(self.c, self.sym["MENU_SHOWN"], 1)[0], 0,
                         "the ESC that closed the group opened the orders menu")

    def test_a_member_presses_its_key(self):
        self.open_system()
        self.hold(cpc.KEY_ENTER)                # HELP
        self.assertEqual(h.read_bank4(self.c, self.sym["HELP_SHOWN"], 1)[0], 1)

    def test_the_camera_group_is_zoom_pan_centre_and_sensors(self):
        self.go(14)                             # CAMERA
        self.hold(cpc.KEY_ENTER)
        for slot, name in enumerate(("back", "zoom_in", "zoom_out", "pan", "centre", "sensors")):
            self.assert_icon_at(slot, name)
        zoom = self.byte("CAM_ZOOM")
        self.hold(cpc.KEY_ENTER)                # ZOOM IN
        self.assertEqual(self.byte("CAM_ZOOM"), zoom - 1, "ZOOM IN did not do what Z does")


class TestTheTutorialPlaysByTheSameRules(unittest.TestCase):
    """"Φτιάξε και το tutorial να λαμβάνει υπόψη του τις αλλαγές": the bar is
    drawn and live on the stage, its first step says SHIFT+ARROWS, and the
    frame starts on MOVE however the last game left it."""

    def test_the_bar_is_up_and_shift_arrows_turn_the_view(self):
        sym = h.symbols()
        c = h.boot_quick(frames=250, briefing=True)
        try:
            h.wait_for_title(c)
            c.key_down("t")
            c.run_frames(30)
            c.key_up("t")
            c.run_frames(80)
            self.assertEqual(c.read_ram(sym["TUT_ACTIVE"], 1)[0], 1, "T did not start the tutorial")
            self.assertEqual(h.read_bank(c, BANK_6, sym["BAR_SEL"], 2), b"\x00\xff",
                             "the stage did not start with the frame on MOVE and no group open")
            ram = c.read_ram(h.front_buffer(c), 0x4000)
            row = sum(ram[h.screen_offset(sym["HUD_BTN_Y"] + r, x)]
                      for r in range(16) for x in range(80))
            self.assertGreater(row, 0, "the button row is not drawn in the tutorial")
            yaw = c.read_ram(sym["CAM_YAW"], 1)[0]
            c.key_down(cpc.KEY_RIGHT)
            c.run_frames(40)
            c.key_up(cpc.KEY_RIGHT)
            c.run_frames(20)            # the emulator wants a scan between an up and the next down
            self.assertEqual(c.read_ram(sym["CAM_YAW"], 1)[0], yaw, "the bare arrows still orbit on the stage")
            c.key_down("Q")
            c.key_down(cpc.KEY_RIGHT)
            c.run_frames(80)
            c.key_up(cpc.KEY_RIGHT)
            c.key_up("Q")
            self.assertNotEqual(c.read_ram(sym["CAM_YAW"], 1)[0], yaw, "SHIFT + RIGHT does not orbit on the stage")
        finally:
            h.close(c)


if __name__ == "__main__":
    unittest.main()
