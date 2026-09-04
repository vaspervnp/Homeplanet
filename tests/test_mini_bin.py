"""MINI.BIN -- the vortex chase on its own, off the same disc.

"make me a bin to test only the minigame" / "in the same disk add a mini.bin
that runs the minigame". src/mini.asm assembles the game a second time with
MINI_ONLY set, and the boot loop then runs the chase for ever with the intro
page in front of every round. These boot it the way a user does -- RUN"MINI
off the real image -- because the whole point of the file is the disc.

Its symbols are its own (build/mini/homeplanet.sym): the low 16K is a few
bytes longer, so the game's symbol file names the wrong addresses for it.
"""

import unittest

from tests import harness as h
from tests.harness import cpc


class TestMiniBin(unittest.TestCase):

    FIRST_CHAR, LAST_CHAR, CHAR_H = 32, 95, 8

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols(h.MINI_SYM)
        cls.game = h.symbols()
        #  One machine for the class: booting off the disc is the slow part.
        cls.c = h.boot_disc(frames=500, program="MINI")
        for _ in range(300):
            if cls.b("MINI_ACTIVE"):
                break
            cls.c.run_frames(10)
        else:
            raise AssertionError("RUN\"MINI never reached the chase")
        cls.c.run_frames(20)

    @classmethod
    def tearDownClass(cls):
        h.close(getattr(cls, "c", None))

    @classmethod
    def b(cls, name):
        return cls.c.read_ram(cls.sym[name], 1)[0]

    def row(self, y, x0, cells):
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (self.LAST_CHAR - self.FIRST_CHAR + 1) * self.CHAR_H))
        out = []
        for bx in range(x0, x0 + cells * 2, 2):
            cell = []
            for r in range(self.CHAR_H):
                a = ram[h.screen_offset(y + r, bx)]
                b = ram[h.screen_offset(y + r, bx + 1)]
                cell.append(((a | (a << 4)) & 0xF0) | (((b | (b << 4)) & 0xF0) >> 4))
            best, bd = " ", 999
            for ci in range(self.FIRST_CHAR, self.LAST_CHAR + 1):
                g = font[(ci - self.FIRST_CHAR) * self.CHAR_H:(ci - self.FIRST_CHAR + 1) * self.CHAR_H]
                d = sum(bin(p ^ q).count("1") for p, q in zip(g, cell))
                if d < bd:
                    bd, best = d, chr(ci)
            out.append(best if bd <= 2 else "?")
        return "".join(out)

    def prompt(self):
        return self.row(self.sym["MG_INTRO_GO_Y"], self.sym["MG_INTRO_GO_X"], 13)

    def test_1_it_boots_straight_to_the_page_and_waits_there(self):
        """No title, no briefing: the intro page, and nothing moves until
        ENTER -- read off the pixels, so a build that skipped the page and
        sat on a black screen with the flag up would not pass."""
        self.assertEqual(self.prompt(), "ENTER - BEGIN")
        self.c.run_frames(200)
        self.assertEqual(self.b("MINI_LEFT"), self.sym["MG_STEPS"],
                         "the chase started without waiting for ENTER")
        self.assertEqual(self.prompt(), "ENTER - BEGIN")

    def test_2_enter_begins_it_and_the_arrows_steer(self):
        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)
        for _ in range(100):
            self.c.run_frames(5)
            if self.b("MINI_LEFT") < self.sym["MG_STEPS"]:
                break
        else:
            self.fail("ENTER did not start the chase")
        self.assertNotEqual(self.prompt(), "ENTER - BEGIN",
                            "the page is still up under the chase")
        x0 = self.b("MINI_X")
        self.c.key_down(cpc.KEY_LEFT)
        self.c.run_frames(60)
        self.c.key_up(cpc.KEY_LEFT)
        self.assertLess(self.b("MINI_X"), x0, "LEFT did not steer")

    def test_3_when_the_chase_ends_the_page_comes_back(self):
        """The loop: a fresh fleet and the page again, so ENTER is
        "play again". Watched by the step counter going back to full."""
        for _ in range(4000):
            self.c.run_frames(5)
            if self.b("MINI_LEFT") == self.sym["MG_STEPS"]:
                break
        else:
            self.fail("the chase never came round again")
        self.c.run_frames(30)
        self.assertEqual(self.prompt(), "ENTER - BEGIN",
                         "the page did not come back for the second round")
        #  ...and the fleet is whole again whatever the first round cost.
        flags = [self.c.read_ram(self.sym["ENTITIES"] + i * h.ENT_SIZE + h.ENT_FLAGS, 1)[0]
                 for i in range(self.sym["PHASE4_SHIPS"] + 1)]
        self.assertTrue(all(f & 1 for f in flags), f"the fleet was not respawned: {flags}")

    def test_the_catalogue_lists_the_game_first(self):
        """RUN"DISC is still the file a player runs; MINI is beside it."""
        import subprocess
        out = subprocess.run(["iDSK", h.DSK, "-l"], capture_output=True, text=True).stdout
        names = [ln.split()[0] for ln in out.splitlines() if ".BIN" in ln or ".BAS" in ln or ".SCR" in ln]
        self.assertIn("DISC", names[0], names)
        self.assertIn("MINI", "".join(names), names)


if __name__ == "__main__":
    unittest.main()
