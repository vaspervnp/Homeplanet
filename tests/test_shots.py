"""Shots you can see (game/shots.asm, future.md item 4).

Three dots between the shooter and its target, in the shooter's ink, for one
frame, erased by the buffer's own list rather than by a dirty rectangle. The
claims are about ADDRESSES: which bytes carry a dot, which plane it is in,
where that is on the screen, and that the same bytes are clean again the next
time that buffer is drawn.
"""

import struct
import unittest

from tests import harness as h

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_TIMER = 9, 10, 11, 12, 13, 14, 19
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4
PEN1_MASKS = {0x80, 0x40, 0x20, 0x10}
PEN3_MASKS = {0x88, 0x44, 0x22, 0x11}


class ShotFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.ENT_MAX = cls.sym["ENT_MAX"]
        #  Screen offset -> (y, byte column), for turning a dot's address back
        #  into a place on the screen.
        cls.where = {}
        for y in range(200):
            for xb in range(80):
                cls.where[h.screen_offset(y, xb)] = (y, xb)

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.let_the_game_draw(self.c, self.sym)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def poke(self, slot, off, data):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, data)

    def field(self, slot, off):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, 1)[0]

    def stage_a_gun(self):
        """Slot 0 becomes a fixed gun far from the fleet, with the camera on
        it, and one hostile a thousand units in front of it.

        The gun is a ship under ENT_ORDER_PILOT with nobody flying it: the
        formation does not move it and nothing else steers it, and its gun is
        the ordinary one -- the pilot's hold on the trigger only exists while
        pilot_slot names it. The camera follows it through moth_slot, which
        is what `0` does, so both ships are on the screen.
        """
        self.GUN, self.ENEMY = 0, self.PLAYER_MAX
        self.poke(self.GUN, 0, struct.pack("<hhh", 20000, 0, 20000))
        self.poke(self.GUN, ENT_ORDER, bytes([self.sym["ENT_ORDER_PILOT"]]))
        self.poke(self.GUN, ENT_TARGET, b"\xff")
        self.poke(self.ENEMY, 0, struct.pack("<hhh", 20000, 0, 19000))
        self.poke(self.ENEMY, ENT_CLASS, b"\x00")
        self.poke(self.ENEMY, ENT_HULL, b"\xff")
        self.poke(self.ENEMY, ENT_SQUAD, b"\xff")
        self.poke(self.ENEMY, ENT_ORDER, b"\x00")
        self.poke(self.ENEMY, ENT_TARGET, b"\xff")
        self.poke(self.ENEMY, ENT_TIMER, b"\x00")
        self.poke(self.ENEMY, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([self.GUN]))
        self.c.write_ram(self.sym["SEL_MOTHERSHIP"], b"\x01")
        self.c.write_ram(self.sym["AUTO_ARMED"], b"\x00")

    def dot_list(self, name):
        raw = h.read_bank4(self.c, self.sym[name], self.sym["SHOT_LIST_SIZE"])
        n = raw[0]
        return [(raw[1 + i * 3] | (raw[2 + i * 3] << 8), raw[3 + i * 3]) for i in range(n)]

    def dots_seen(self, frames=200, every=2):
        """(buffer, address, mask) for every dot the two lists carried."""
        out = []
        for _ in range(frames // every):
            self.c.run_frames(every)
            for base, name in ((0xC000, "SHOT_DOTS_A"), (0x8000, "SHOT_DOTS_B")):
                for addr, mask in self.dot_list(name):
                    out.append((base, addr, mask))
        return out

    def cached(self, slot):
        raw = h.read_bank4(self.c, self.sym["SHOT_POS"] + slot * 4, 4)
        return raw[0] | (raw[1] << 8), raw[2], raw[3]


class TestTheDots(ShotFixture):

    def test_nothing_is_drawn_while_nothing_is_fired(self):
        """Mission 1 has no enemy, so no shot and no dot."""
        self.c.run_frames(60)
        self.assertEqual(self.byte("CBT_SHOTS"), 0)
        self.assertEqual(self.dot_list("SHOT_DOTS_A"), [])
        self.assertEqual(self.dot_list("SHOT_DOTS_B"), [])

    def test_a_shot_puts_dots_on_the_buffer_in_the_shooters_ink(self):
        self.stage_a_gun()
        seen = self.dots_seen()
        self.assertGreater(self.byte("CBT_SHOTS"), 0, "nobody fired")
        self.assertTrue(seen, "a fight happened and not one dot was listed")
        masks = {m for _, _, m in seen}
        self.assertTrue(masks & PEN1_MASKS, f"no dot in the fleet's ink: {masks}")
        self.assertTrue(masks & PEN3_MASKS, f"no dot in the enemy's ink: {masks}")
        self.assertFalse(masks - PEN1_MASKS - PEN3_MASKS, f"a dot in neither side's ink: {masks}")

    def test_a_listed_dot_is_on_the_screen_where_the_list_says(self):
        """The list is what shot_erase trusts, so every entry has to be true:
        the byte at that address carries that mask -- unless it is the
        entry's own buffer being redrawn, which is why each sample reads the
        list and the byte together."""
        self.stage_a_gun()
        checked = 0
        for _ in range(60):
            self.c.run_frames(2)
            for name in ("SHOT_DOTS_A", "SHOT_DOTS_B"):
                for addr, mask in self.dot_list(name):
                    b = self.c.read_ram(addr, 1)[0]
                    if b & mask == mask:
                        checked += 1
        self.assertGreater(checked, 5, "no dot was ever found lit at its listed address")

    def test_the_dots_lie_between_the_two_ships(self):
        self.stage_a_gun()
        checked = 0
        for _ in range(60):
            self.c.run_frames(2)
            gx, gy, gs = self.cached(self.GUN)
            ex, ey, es = self.cached(self.ENEMY)
            if gs != es:
                continue                    # not both projected on the same frame
            for name in ("SHOT_DOTS_A", "SHOT_DOTS_B"):
                for addr, mask in self.dot_list(name):
                    y, xb = self.where[addr & 0x3FFF]
                    pixel = {0x80: 0, 0x40: 1, 0x20: 2, 0x10: 3}[mask & 0xF0]
                    x = xb * 4 + pixel
                    lo, hi = sorted((gx, ex))
                    self.assertTrue(lo - 8 <= x <= hi + 8,
                                    f"a dot at x={x} with the ships at {gx} and {ex}")
                    lo, hi = sorted((gy, ey))
                    self.assertTrue(lo - 8 <= y <= hi + 8,
                                    f"a dot at y={y} with the ships at {gy} and {ey}")
                    checked += 1
        self.assertGreater(checked, 5)

    def test_the_dots_are_taken_off_again_when_the_buffer_is_next_drawn(self):
        self.stage_a_gun()
        seen = self.dots_seen(frames=120)
        self.assertTrue(seen)
        #  End the fight and move the gun away, so nothing is drawn near where
        #  the dots were; the lists must empty and the dots' own plane clear.
        self.poke(self.ENEMY, ENT_FLAGS, b"\x00")
        self.poke(self.GUN, 0, struct.pack("<hhh", -20000, 0, -20000))
        #  ...AND PAN THE CAMERA OFF THE GUN. It is moth_slot, so the view
        #  follows it to the middle of the screen wherever it goes -- which is
        #  exactly where the dots were, because the enemy sat on the view
        #  axis behind it. Whether the pixel under the gun's own centre is lit
        #  is a fact about the sprite map, and it changed the day the
        #  interceptor was repainted: the test read a ship and called it a
        #  dot that stayed. Four thousand units of pan puts the gun off to
        #  one side and leaves black where the dots were.
        self.c.write_ram(self.sym["CAM_PAN"], struct.pack("<hhh", 4000, 0, 0))
        self.c.run_frames(60)
        self.assertEqual(self.dot_list("SHOT_DOTS_A"), [])
        self.assertEqual(self.dot_list("SHOT_DOTS_B"), [])
        for base, addr, mask in seen:
            b = self.c.read_ram(addr, 1)[0]
            self.assertEqual(b & mask & 0xF0, 0, f"a dot is still on {base:#x} at {addr:#x}")


class TestTheRecord(ShotFixture):
    """shot_note through a stub: one cbt_update, both ships ready, and the
    list names who shot whom."""

    def test_both_shots_are_recorded_shooter_first(self):
        base = self.sym["ENTITIES"]
        for slot in range(self.ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        def place(slot, enemy, pos):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", *pos))
            self.c.write_ram(addr + ENT_CLASS, b"\x00")
            self.c.write_ram(addr + ENT_HULL, b"\xff")
            self.c.write_ram(addr + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_ORDER, b"\x00")
            self.c.write_ram(addr + ENT_TARGET, b"\xff")
            self.c.write_ram(addr + ENT_TIMER, b"\x00")
        ME, THEM = 3, self.PLAYER_MAX + 2
        place(ME, False, (0, 0, 0))
        place(THEM, True, (0, 0, -1000))
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        h.write_bank4(self.c, self.sym["SHOT_COUNT"], b"\x00")
        cu = self.sym["CBT_UPDATE"]
        stub = bytes([0x01, self.sym["GA_BANK_4"], 0x7F, 0xED, 0x49,
                      0xCD, cu & 0xFF, cu >> 8, 0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(2)
        n = h.read_cpu(self.c, self.sym["SHOT_COUNT"], 1)[0]
        raw = h.read_cpu(self.c, self.sym["SHOT_LIST"], n * 2)
        shots = {(raw[i * 2], raw[i * 2 + 1]) for i in range(n)}
        self.assertEqual(shots, {(ME, THEM), (THEM, ME)})


if __name__ == "__main__":
    unittest.main()
