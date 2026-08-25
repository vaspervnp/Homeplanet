"""Phase 0 acceptance tests -- boot, Mode 1, and page flipping on the VSYNC.

Everything here asserts on emulator state after real Z80 code has run.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tools import gentables


class TestBoot(unittest.TestCase):
    """The machine ends up where sys_boot says it should."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=40)
        cls.sym = h.symbols()

    def test_running_our_code_not_the_firmware(self):
        """PC must be inside the game, which means the lower ROM really is off.

        This is the test that would have caught the original boot bug: the
        game was copied to #0040 correctly but the CPU was still fetching
        firmware bytes from the shadowing ROM.
        """
        pc = self.c.pc
        self.assertLess(pc, self.sym["CODE_END"], f"PC #{pc:04X} is outside the game")
        self.assertGreaterEqual(pc, 0x0040, f"PC #{pc:04X} is below the entry point")

    def test_lower_rom_is_disabled(self):
        """What the CPU reads at #0040 must be what is in RAM at #0040."""
        ram = self.c.read_ram(0x0040, 8)
        cpu = bytes(self.c.peek(0x0040 + i) for i in range(8))
        self.assertEqual(ram, cpu, "lower ROM is still shadowing #0000-#3FFF")

    def test_mode_1(self):
        self.assertEqual(self.c.mode, 1)

    def test_our_interrupt_handler_is_installed(self):
        """#0038 must hold JP sys_irq, not the firmware's vector."""
        v = self.c.read_ram(0x0038, 3)
        self.assertEqual(v[0], 0xC3, "no JP at the IM 1 vector")
        self.assertEqual(v[1] | (v[2] << 8), self.sym["SYS_IRQ"])

    def test_irq_is_ticking_at_50hz(self):
        """sys_tick_50hz counts one per PAL frame, give or take a frame."""
        addr = self.sym["SYS_TICK_50HZ"]
        before = self.c.read_ram(addr, 1)[0]
        self.c.run_frames(50)
        after = self.c.read_ram(addr, 1)[0]
        self.assertAlmostEqual((after - before) % 256, 50, delta=2)


class TestPageFlip(unittest.TestCase):
    """Homeplanet.md phase 0: 'σταθερή εναλλαγή οθονών στο VSync'."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=40)

    def test_one_flip_per_game_frame(self):
        """The display must swap exactly once per game frame, and use both buffers.

        Counting transitions rather than checking alternation at each sample
        is deliberate: the loop runs at ~8 fps, so sampling per PAL frame sees
        each buffer several times in a row, and where the sample lands
        relative to the flip is arbitrary. Transitions per frame is the same
        invariant without the phase sensitivity.
        """
        sym = h.symbols()
        tick = sym["DEMO_FRAMES"]

        pages = [h.crtc_page(self.c)]
        frames_before = self.c.read_ram(tick, 1)[0]
        for _ in range(120):
            self.c.run_frames(1)
            pages.append(h.crtc_page(self.c))
        frames_after = self.c.read_ram(tick, 1)[0]

        game_frames = (frames_after - frames_before) % 256
        transitions = sum(1 for i in range(1, len(pages)) if pages[i] != pages[i - 1])

        self.assertGreater(game_frames, 4, "the game loop is barely advancing")
        self.assertNotIn(-1, pages, "CRTC parked on neither buffer")
        self.assertEqual(set(pages), {h.SCREEN_A, h.SCREEN_B}, "only one buffer ever shown")
        self.assertAlmostEqual(
            transitions, game_frames, delta=1,
            msg=f"{transitions} flips for {game_frames} game frames",
        )

    def test_r13_offset_stays_zero(self):
        """Only R12 changes; a stray R13 would shift the whole picture."""
        for _ in range(6):
            self.c.run_frames(1)
            self.assertEqual(self.c.crtc_screen_addr & 0xFF, 0)


class TestDrawing(unittest.TestCase):
    """scr_fill_rect and the per-buffer dirty rectangles."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=60)
        cls.sym = h.symbols()

    def test_fill_rect_honours_width_and_height(self):
        """Call the routine directly with known arguments and measure it.

        Regression test for the DE clobber: scr_line_addr used to destroy DE,
        so scr_fill_rect read its width out of a trashed register and drew
        two bytes wide no matter what it was asked for.
        """
        fill = self.sym["SCR_FILL_RECT"]
        x, y, w, ht, byte = 3, 5, 8, 4, 0x3C

        #  Blank the buffer first. Sprite data contains arbitrary bytes, so
        #  there is no fill value that cannot also occur in a ship the demo
        #  has already drawn here, and find_block would take the bounding box
        #  of both.
        back = self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0] << 8
        for line in range(200):
            self.c.write_ram(back + h.screen_offset(line, 0), bytes(80))
        stub = bytes([
            0xF3,                                   # di
            0x01, y, x,                             # ld bc  -> B=x, C=y
            0x11, ht, w,                            # ld de  -> D=w, E=h
            0x3E, byte,                             # ld a,fill
            0xCD, fill & 0xFF, fill >> 8,           # call scr_fill_rect
            0x18, 0xFE,                             # jr $
        ])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)

        back = self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0] << 8
        got = h.find_block(self.c, back, byte)
        self.assertEqual(got, (x, y, w, ht))


#  The moving-block and static-frame tests that used to live here belonged to
#  the Phase 0 demo, which Phase 1 replaced. What they really covered -- that
#  each buffer erases only what IT is holding -- is now tested against the
#  Phase 1 point lists in tests/test_phase1.py (test_no_pixel_trails).


class TestTables(unittest.TestCase):
    """The generated tables must actually be in RAM, and be correct.

    gentables.py is the specification; these compare it against the bytes the
    assembler really emitted, so a table that silently changes shape fails
    here rather than quietly corrupting the projection later.
    """

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=10)
        cls.sym = h.symbols()

    def _plane(self, name: str, n: int) -> list[int]:
        return list(self.c.read_ram(self.sym[name], n))

    def test_screen_line_offsets(self):
        want = gentables.screen_line_offsets()
        lo = self._plane("SCR_LINE_LO", len(want))
        hi = self._plane("SCR_LINE_HI", len(want))
        self.assertEqual([l | (hgh << 8) for l, hgh in zip(lo, hi)], want)

    def test_line_planes_are_on_consecutive_pages(self):
        """scr_line_addr crosses between them with a bare `inc h`."""
        self.assertEqual(self.sym["SCR_LINE_HI"], self.sym["SCR_LINE_LO"] + 0x100)
        self.assertEqual(self.sym["SCR_LINE_LO"] & 0xFF, 0, "plane is not page aligned")

    def test_quarter_squares(self):
        want = gentables.quarter_squares()
        lo = self._plane("QSQ_LO", 512)
        hi = self._plane("QSQ_HI", 512)
        self.assertEqual([l | (hgh << 8) for l, hgh in zip(lo, hi)], want)

    def test_quarter_square_identity(self):
        """a*b == f(a+b) - f(a-b) for every 8-bit pair, using the RAM table."""
        lo = self._plane("QSQ_LO", 512)
        hi = self._plane("QSQ_HI", 512)
        f = [l | (hgh << 8) for l, hgh in zip(lo, hi)]
        for a in range(0, 256, 7):
            for b in range(0, 256, 5):
                self.assertEqual(f[a + b] - f[abs(a - b)], a * b, f"{a}*{b}")

    def test_sine(self):
        want = gentables.sine_table()
        lo = self._plane("SIN_LO", 256)
        hi = self._plane("SIN_HI", 256)
        got = [l | (hgh << 8) for l, hgh in zip(lo, hi)]
        got = [v - 0x10000 if v >= 0x8000 else v for v in got]
        self.assertEqual(got, want)

    def test_tables_are_page_aligned(self):
        for name in ("QSQ_LO", "QSQ_HI", "SIN_LO", "SIN_HI"):
            self.assertEqual(self.sym[name] & 0xFF, 0, f"{name} is not page aligned")


class TestDiscImage(unittest.TestCase):
    """The .dsk must boot the way a real user would boot it.

    Slow (it emulates the FDC), but it is the only test that proves the disc
    image, the AMSDOS header and the relocating stub all agree.
    """

    def test_run_disc_starts_the_game(self):
        c = h.boot_disc(frames=400)
        sym = h.symbols()
        self.assertEqual(c.mode, 1)
        self.assertLess(c.pc, sym["CODE_END"], "did not end up in the game")
        self.assertIn(h.crtc_page(c), (h.SCREEN_A, h.SCREEN_B))

        ram = c.read_ram(0x0040, 8)
        cpu = bytes(c.peek(0x0040 + i) for i in range(8))
        self.assertEqual(ram, cpu, "lower ROM still shadowing after disc boot")


if __name__ == "__main__":
    unittest.main()
