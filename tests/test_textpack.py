"""The briefings are packed five bits a character (tools/packtext.py) and
decoded on the machine by b7_packed (game/textpack.asm). This holds the two
decoders together: every line the packer wrote is what the Z80 hands back
through bank7_fetch, the alphabet is the same thirty-two bytes on both sides,
and a RAW table -- the orders menu's words -- still comes through the same
call untouched, because bank7_fetch tells the two kinds apart by one byte."""

import os
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])
from tests import harness as h

sys.path.insert(0, os.path.join(h.ROOT, "tools"))
import packtext  # noqa: E402


class TestThePackerOnItsOwn(unittest.TestCase):
    """Python against Python: the packer round-trips the authored text."""

    def test_every_briefing_line_round_trips(self):
        strings = packtext.strings_in(os.path.join(h.ROOT, "src", "game", "briefings.asm"))
        self.assertTrue(strings, "no briefing lines found")
        packed = packtext.pack_table(strings)
        self.assertEqual(packtext.unpack_table(packed, 0, len(strings)), strings)

    def test_a_character_outside_the_alphabet_stops_the_build(self):
        with self.assertRaises(ValueError):
            packtext.pack_line("NO LOWER CASE here")
        with self.assertRaises(ValueError):
            packtext.pack_line("A" * (packtext.MAX_CHARS + 1))

    def test_the_table_the_build_wrote_is_the_authored_text(self):
        sym = h.symbols()
        bank7 = open(os.path.join(h.ROOT, "build", "bank7.raw"), "rb").read()
        strings = packtext.strings_in(os.path.join(h.ROOT, "src", "game", "briefings.asm"))
        n = sym["MIS_COUNT"] * sym["BRIEF_LINES"]
        self.assertEqual(len(strings), n)
        on_disc = packtext.unpack_table(bank7, sym["MISSION_TEXT"] - 0x4000, n)
        self.assertEqual(on_disc, strings)

    def test_the_z80_alphabet_is_the_packers(self):
        sym = h.symbols()
        bank7 = open(os.path.join(h.ROOT, "build", "bank7.raw"), "rb").read()
        at = sym["B7_ALPHA"] - 0x4000
        self.assertEqual(bank7[at:at + 32], packtext.ALPHABET.encode("ascii"))


class TestTheZ80Decoder(unittest.TestCase):
    """bank7_fetch driven through a stub, one string at a time, against the
    packer's own reading of the same table."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick()
        cls.sym = h.symbols()
        h.run_to_stable_point(cls.c, cls.sym)
        cls.bank7 = open(os.path.join(h.ROOT, "build", "bank7.raw"), "rb").read()

    def fetch(self, table, skip):
        """What bank7_fetch(HL=table, A=skip) leaves in bank7_line."""
        call = self.sym["BANK7_FETCH"]
        stub = bytes([
            0xF3,                                   # di
            0x21, table & 0xFF, table >> 8,         # ld hl,table
            0x3E, skip,                             # ld a,skip
            0xCD, call & 0xFF, call >> 8,           # call bank7_fetch
            0x18, 0xFE,                             # jr $
        ])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)
        line = self.c.read_ram(self.sym["BANK7_LINE"], self.sym["B7_BUF_SIZE"])
        return line[:line.index(b"\0")].decode("ascii")

    def test_every_packed_line_decodes_on_the_machine(self):
        n = self.sym["MIS_COUNT"] * self.sym["BRIEF_LINES"]
        want = packtext.unpack_table(self.bank7, self.sym["MISSION_TEXT"] - 0x4000, n)
        bad = []
        for i in range(n):
            got = self.fetch(self.sym["MISSION_TEXT"], i)
            if got != want[i]:
                bad.append((i, want[i], got))
        self.assertEqual(bad, [], f"{len(bad)} lines decoded wrong on the Z80")

    def test_a_raw_table_still_comes_through_the_same_call(self):
        at = self.sym["MENU_WORDS"] - 0x4000
        raw = []
        for _ in range(self.sym["MENU_COUNT"]):
            end = self.bank7.index(b"\0", at)
            raw.append(self.bank7[at:end].decode("ascii"))
            at = end + 1
        self.assertNotEqual(self.bank7[self.sym["MENU_WORDS"] - 0x4000], packtext.TEXT_PACKED)
        for i in (0, 3, self.sym["MENU_COUNT"] - 1):
            self.assertEqual(self.fetch(self.sym["MENU_WORDS"], i), raw[i])


if __name__ == "__main__":
    unittest.main()
