"""fdc_seek, on its own, away from the boot path that hides it.

WHAT THIS FILE CAN AND CANNOT SAY
---------------------------------
It cannot say the seek is correct. cpcemu's uPD765 resolves a SEEK
synchronously the instant the last command byte is written -- and, in
chips/upd765.h, carries a `FIXME: drive bits 0..2 should be set while drive is
seeking`, so the drive-busy bit this routine used to wait on has never been set
here at all. Every timing assumption fdc_seek makes is one this emulator will
agree with. CLAUDE.md's rule stands: the FDC is believed after Retro Virtual
Machine, not after `make test`.

What it CAN say is that the routine terminates, leaves the controller able to
take the very next command, and puts the head where it was asked to -- for
three distances lib_load never asks for. lib_load only ever seeks forwards, by
eleven tracks once a bank and by one track twice a bank; a seek BACKWARDS and a
seek of ZERO tracks are both unexercised by the whole rest of the suite, and a
zero-distance seek is exactly the shape that hangs a routine which waits for a
busy bit to appear before waiting for it to go away.

The reads are against the sprite-library tracks, whose contents the build wrote
and this test re-reads off the image, so "the head arrived" is a statement
about bytes rather than about a status register.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h  # noqa: E402  (puts cpc.py on the path)

sys.path.insert(0, __file__.rsplit("/", 2)[0] + "/tools")
from discbanks import Disc  # noqa: E402

#  Screen B. Sixteen kilobytes of RAM that nothing touches while the stub sits
#  in its halt loop, and far away from the few hundred bytes of slack between
#  CODE_END and the stack that h.DATA carves a test buffer out of -- a sector
#  is 512 bytes and would be sitting where the stack is going.
BUF = 0x9000
#  A byte the stub writes as the last thing it does. Reading PC and comparing
#  it against the halt loop looked like the obvious way to say "it came back"
#  and is not: the emulator's PC is sampled at whatever instruction boundary
#  the frame ended on, so it lands on the halt loop's `jr` or on the byte
#  before it depending on the length of the stub. A byte in RAM is not
#  ambiguous.
DONE = BUF + 512
DONE_MARK = 0x5A

FDC_MOTOR = 0xFA7E
FDC_CMD_READ = 0x46

LIB_TRACK = 20                  # the first library track; see sys/libload.asm
SECTOR_C1 = 0xC1


class SeekFixture(unittest.TestCase):
    """One machine for the file. Each case pokes its own stub and runs it."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()
        cls.disc = Disc(h.DSK)

    @classmethod
    def tearDownClass(cls):
        h.close(getattr(cls, "c", None))

    # ---- machine plumbing --------------------------------------------------

    def _call(self, addr: int) -> bytes:
        return bytes([0xCD, addr & 0xFF, addr >> 8])

    def _motor(self, on: int) -> bytes:
        return bytes([0x01, FDC_MOTOR & 0xFF, FDC_MOTOR >> 8,   # ld bc,#FA7E
                      0x3E, on,                                 # ld a,on
                      0xED, 0x79])                              # out (c),a

    def seek_and_read(self, tracks: list[int], sector: int = SECTOR_C1,
                      frames: int = 20) -> bytes:
        """Seek down `tracks` in order, then read `sector` off the last of them.

        Interrupts off for the whole thing, exactly as lib_load and
        fdc_fleet_io run it: the controller wants a byte every 32 microseconds
        and our IM 1 handler is longer than that.
        """
        stub = bytes([0xF3])                                    # di
        stub += self._motor(1)
        stub += self._call(self.sym["FDC_DRAIN_RESULT"])        # as lib_load does
        for track in tracks:
            stub += bytes([0x3E, track])                        # ld a,track
            stub += self._call(self.sym["FDC_SEEK"])
        stub += bytes([0x21, BUF & 0xFF, BUF >> 8,              # ld hl,BUF
                       0x22, self.sym["FDC_BUF"] & 0xFF,        # ld (fdc_buf),hl
                       self.sym["FDC_BUF"] >> 8,
                       0x3E, sector,                            # ld a,sector
                       0x32, self.sym["FDC_SECTOR"] & 0xFF,     # ld (fdc_sector),a
                       self.sym["FDC_SECTOR"] >> 8,
                       0x3E, FDC_CMD_READ])                     # ld a,READ DATA
        stub += self._call(self.sym["FDC_SECTOR_RW"])
        stub += self._motor(0)
        stub += bytes([0x3E, DONE_MARK,                         # ld a,#5A
                       0x32, DONE & 0xFF, DONE >> 8,            # ld (DONE),a
                       0x18, 0xFE])                             # jr $

        self.c.write_ram(BUF, bytes(513))                       # no stale answer
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(frames)

        self.assertEqual(self.c.read_ram(DONE, 1)[0], DONE_MARK,
                         f"fdc_seek/fdc_sector_rw did not come back within "
                         f"{frames} frames")
        return bytes(self.c.read_ram(BUF, 512))

    def on_the_disc(self, track: int, sector: int = SECTOR_C1) -> bytes:
        off, length = self.disc.sector_offset(track, sector)
        return bytes(self.disc.data[off:off + length])

    def st0(self) -> int:
        return self.c.read_ram(self.sym["FDC_ST0"], 1)[0]


class TestTheHeadGetsThere(SeekFixture):
    """Three distances, one of which the game itself never asks for."""

    def test_a_seek_forwards_lands_on_the_track_it_was_given(self):
        """The ordinary case, and the control for the two below.

        READ DATA does not seek: it checks the cylinder it is given against
        the ID field under the head, so a read that comes back with the right
        512 bytes is a statement that the head is on track 20 and not merely
        that the controller said so.
        """
        got = self.seek_and_read([LIB_TRACK])
        self.assertEqual(self.st0() & 0xC0, 0,
                         "the read terminated abnormally")
        self.assertEqual(got, self.on_the_disc(LIB_TRACK))

    def test_a_seek_backwards_lands_on_the_track_it_was_given(self):
        """lib_load only ever walks up the disc, so nothing else tries this."""
        got = self.seek_and_read([LIB_TRACK + 6, LIB_TRACK])
        self.assertEqual(self.st0() & 0xC0, 0)
        self.assertEqual(got, self.on_the_disc(LIB_TRACK))

    def test_a_seek_of_no_distance_at_all_comes_back(self):
        """The head is already there, so the seek is over before it starts.

        This is the shape that hangs a routine which waits for the drive-busy
        bit to APPEAR before waiting for it to go away: on a zero-track seek
        there may be no window in which it is ever seen set. Nothing in the
        game does it -- lib_load's nine seeks are all a track or more -- which
        is precisely why it is worth a case of its own.
        """
        got = self.seek_and_read([LIB_TRACK + 3, LIB_TRACK + 3, LIB_TRACK + 3])
        self.assertEqual(self.st0() & 0xC0, 0)
        self.assertEqual(got, self.on_the_disc(LIB_TRACK + 3))

    def test_the_next_command_is_taken_straight_after_a_seek(self):
        """A seek that leaves a result byte untaken wedges everything after it.

        The controller sits in the result phase until the last byte is read and
        ignores anything sent to it meanwhile -- and fdc_out waits for DIO to
        say "I want a byte from you", which it never will. That is a hang, not
        a bad read, so the assertion is that the sector arrived at all.

        Nine seeks run back to back at boot, so this is the property the whole
        sprite load rests on.
        """
        got = self.seek_and_read([LIB_TRACK, LIB_TRACK + 1, LIB_TRACK + 2,
                                  LIB_TRACK + 1, LIB_TRACK])
        self.assertEqual(got, self.on_the_disc(LIB_TRACK))

    def test_the_buffer_pointer_is_left_past_the_sector(self):
        """lib_load reads 26 sectors into a bank without ever touching fdc_buf.

        It is fdc_sector_rw that advances it, on the success path only, and the
        track advance in the middle of a bank deliberately leaves it alone --
        so a bank's 13312 bytes land contiguously across three tracks.
        """
        self.seek_and_read([LIB_TRACK])
        buf = self.c.read_ram(self.sym["FDC_BUF"], 2)
        self.assertEqual(buf[0] | (buf[1] << 8), BUF + 512)


if __name__ == "__main__":
    unittest.main()
