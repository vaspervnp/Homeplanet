"""tools/lzpack.py and the Z80 decoder in src/disc.asm agree, byte for byte.

DISC.BIN carries both of its images LZ-packed, and lz_unpack in the loader
stub is what turns them back into the game. Every other test in the suite
runs through that decoder once at boot -- so a wrong byte would show up as
something, somewhere, in the vocabulary of whatever test met it first. This
is the test that says it in its own words: the reference decoder in Python
and the Z80 one produce the same bytes from the same streams, including the
streams that exercise every token form the format has.
"""

import os
import random
import struct
import sys
import unittest

from tests import harness as h
from tests.harness import cpc

sys.path.insert(0, os.path.join(h.ROOT, "tools"))
import lzpack  # noqa: E402

DISC_SYM = os.path.join(h.BUILD, "disc.sym")


def disc_symbols() -> dict[str, int]:
    out = {}
    with open(DISC_SYM) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith("#"):
                out[parts[0].upper()] = int(parts[1][1:], 16)
    return out


def streams() -> list[tuple[str, bytes]]:
    """Inputs that between them use every token: literal runs longer than
    128, short and long offsets, lengths past the six bits, runs (offset 1),
    overlapping copies, and the two images the build actually packs."""
    rng = random.Random(7)
    noise = bytes(rng.randrange(256) for _ in range(700))
    cases = [
        ("empty", b""),
        ("one byte", b"Q"),
        ("a run", bytes([0x55]) * 1000),
        ("a short run", b"\x00" * 5),
        ("a long literal", noise),
        ("a short-offset copy", b"HOMEPLANET" * 40),
        ("a long-offset copy", noise + b"x" * 300 + noise),
        ("overlap of three", b"abc" * 500),
        ("mixed", (noise[:50] + b"\xff" * 400 + noise[50:120]) * 3 + noise),
    ]
    for name in ("home.raw", "sprites.raw"):
        with open(os.path.join(h.BUILD, name), "rb") as f:
            cases.append((name, f.read()))
    return cases


class TestTheReferenceDecoder(unittest.TestCase):

    def test_every_stream_round_trips_in_python(self):
        for name, data in streams():
            with self.subTest(name):
                self.assertEqual(lzpack.unpack(lzpack.pack(data)), data)

    def test_the_build_packed_what_the_tool_packs(self):
        """build/home.lz and build/sprites.lz are the tool's own output for
        the raw images beside them, not a stale pair from another build."""
        for raw, lz in (("home.raw", "home.lz"), ("sprites.raw", "sprites.lz")):
            with open(os.path.join(h.BUILD, raw), "rb") as f:
                data = f.read()
            with open(os.path.join(h.BUILD, lz), "rb") as f:
                packed = f.read()
            self.assertEqual(lzpack.unpack(packed), data, lz)
            self.assertLess(len(packed), len(data), f"{lz} did not shrink")


class TestTheZ80Decoder(unittest.TestCase):
    """lz_unpack, driven straight from the stub in build/disc.raw.

    A cold machine with the firmware up, the file dropped at #4000 as AMSDOS
    would, and a call into lz_unpack with a stream of ours: the destination is
    above #8000 so the lower ROM's shadow is not in the way and no game code
    is disturbed, because none is running.
    """

    #  The decoder is the LAST thing in disc.raw, so the output goes above
    #  the file's end -- read out of the symbols, because the first version
    #  put it at #8000 and a ten-kilobyte stream overwrote lz_unpack with
    #  its own output, and the second put it at #9000 and the file grew past
    #  that four hundred bytes later. The packed stream sits in screen
    #  memory, under the stub's stack at #FDF0.
    SRC = 0xC000

    @classmethod
    def setUpClass(cls):
        cls.sym = disc_symbols()
        assert "LZ_UNPACK" in cls.sym, "lz_unpack is not in build/disc.sym"
        cls.DST = (cls.sym["DISC_STUB_END"] + 0xFF) & 0xFF00
        assert cls.DST + 0x2800 < cls.SRC, "no room for the test's output above the loader"

    def setUp(self):
        self.c = cpc.CPC()
        self.c.run_frames(h.BOOT_FRAMES)
        with open(h.DISC_RAW, "rb") as f:
            self.c.write_ram(h.LOADER_ORG, f.read())

    def tearDown(self):
        h.close(self.c)

    def unpack_on_the_z80(self, packed: bytes, size: int) -> bytes:
        c = self.c
        self.assertLess(self.SRC + len(packed), 0xFD00, "stream too long for the test")
        self.assertLess(self.DST + size, self.SRC, "output too long for the test")
        c.write_ram(self.SRC, packed)
        c.write_ram(self.DST, b"\xa5" * (size + 4))       # a fence past the end
        #  di : ld sp,#FDF0 : ld hl,SRC : ld de,DST : call lz_unpack
        #  : ld (RESULT),de : jr $ -- interrupts off and a stack of its own,
        #  because a long stream at SRC runs over the firmware's workspace at
        #  #B100 and its stack, and the firmware must not wake up in the middle.
        stub_at = 0xFE00
        result = 0xFE80
        stub = (b"\xf3\x31\xf0\xfd"
                + b"\x21" + struct.pack("<H", self.SRC)
                + b"\x11" + struct.pack("<H", self.DST)
                + b"\xcd" + struct.pack("<H", self.sym["LZ_UNPACK"])
                + b"\xed\x53" + struct.pack("<H", result)
                + b"\x18\xfe")
        c.write_ram(stub_at, stub)
        c.write_ram(result, b"\x00\x00")
        c.set_pc(stub_at)
        for _ in range(200):
            c.run_frames(1)
            if c.pc == stub_at + len(stub) - 2:
                break
        else:
            self.fail("lz_unpack never returned")
        end = struct.unpack("<H", c.read_ram(result, 2))[0]
        self.assertEqual(end, self.DST + size, "DE did not end just past the output")
        fence = c.read_ram(self.DST + size, 4)
        self.assertEqual(fence, b"\xa5" * 4, "the decoder wrote past the end")
        return c.read_ram(self.DST, size)

    def test_every_stream_comes_out_as_the_reference_says(self):
        for name, data in streams():
            if len(data) > 0x2800:
                data = data[:0x2800]              # the test's window, not the format's
            with self.subTest(name):
                packed = lzpack.pack(data)
                self.assertEqual(self.unpack_on_the_z80(packed, len(data)), data)


if __name__ == "__main__":
    unittest.main()
