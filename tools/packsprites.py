#!/usr/bin/env python3
"""Pack the sprite library for the disc.

    python3 tools/packsprites.py build/sprites.raw build/sprites.rle

Why this exists
---------------
DISC.BIN loads at #4000 and must finish below #A700, where AMSDOS keeps its
workspace. Uncompressed, the game plus the sprite library ended at #A66C --
148 bytes of headroom for everything the game might ever grow by.

THERE IS NO SPRITE LIBRARY IN BANK 4 ANY MORE. All eight are in banks 5-7 and
are read off the disc raw (three, three and two -- see src/sys/libload.asm), so
what this now packs is the bank's CODE and TEXT, which has none of the runs
below in it: 6445 bytes come out as 6650. The tool is a small net LOSS today
and is kept because DISC.BIN has thousands of bytes of headroom, the round-trip
check below is worth having either way, and the moment a ninth class has to
travel inside the file again this is what makes it fit. Do not read the "about
half" figure below as a current measurement.

Why RLE, and why de-interleaved
-------------------------------
The library is mask/data pairs, and run-length coding it as-is saves NOTHING:
the interleave breaks every run, because a mask byte is almost always #FF and
the data byte beside it almost always #00, so no two adjacent bytes match.

Split the two streams apart and the runs reappear -- a transparent row is a
long run of #FF in one stream and of #00 in the other. That takes the library
to about half, which is enough. A real LZ would do better (zlib manages 18%),
but this is thirty bytes of Z80 whose format both ends agree on by
construction, and the decoder re-interleaves as it writes: masks to the even
addresses, data to the odd.

Format
------
    00              end of stream
    01..FD  n       n literal bytes follow
    FE      n b     n copies of b

A literal #FE is emitted as a run of one, so the marker is never ambiguous.
"""

from __future__ import annotations

import sys

RUN_MARK = 0xFE
MAX_LITERAL = 253


def pack_stream(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        run = 1
        while i + run < len(data) and data[i + run] == b and run < 255:
            run += 1

        #  A run of three pays for itself; a literal #FE must be escaped
        #  whatever its length.
        if run >= 3 or b == RUN_MARK:
            out += bytes([RUN_MARK, run, b])
            i += run
            continue

        #  The bound is "can two more bytes still fit", not "is there room for
        #  one", because the body below appends a whole short run -- up to the
        #  two bytes that were not long enough to be worth encoding as one. A
        #  test for len < MAX_LITERAL lets the literal reach 254, which IS
        #  RUN_MARK, and the decoder then reads the count byte as a run and
        #  walks off the end of the stream. It took an odd number of bytes in
        #  one bank to produce a literal of exactly that length, and the
        #  round-trip check below is what caught it.
        literal = bytearray()
        j = i
        while j < len(data) and len(literal) <= MAX_LITERAL - 2:
            b2 = data[j]
            run2 = 1
            while j + run2 < len(data) and data[j + run2] == b2 and run2 < 255:
                run2 += 1
            if run2 >= 3 or b2 == RUN_MARK:
                break
            literal += data[j:j + run2]
            j += run2

        if not literal:                      # cannot happen, but never stall
            literal = bytearray(data[i:i + 1])
            j = i + 1

        out += bytes([len(literal)]) + literal
        i = j

    out += bytes([0])
    return bytes(out)


def unpack_stream(packed: bytes) -> bytes:
    """The Z80 decoder's twin, so the tests can check both against each other."""
    out = bytearray()
    i = 0
    while True:
        n = packed[i]
        i += 1
        if n == 0:
            return bytes(out)
        if n == RUN_MARK:
            out += bytes([packed[i + 1]]) * packed[i]
            i += 2
        else:
            out += packed[i:i + n]
            i += n


def pack_library(raw: bytes) -> bytes:
    """De-interleave into two streams, pack each, and concatenate.

    The de-interleave is a HEURISTIC, not a format requirement: it pays for
    itself because the bulk of the bank is mask/data pairs. The mission table
    and the briefing text sit in the same bank and are not pairs at all --
    they just compress a little less well, and they still round-trip exactly.

    An odd length is padded, since the decoder writes in strides of two.
    """
    if len(raw) % 2:
        raw = raw + b"\x00"
    return pack_stream(raw[0::2]) + pack_stream(raw[1::2])


def unpack_library(packed: bytes, size: int) -> bytes:
    size += size % 2
    masks = unpack_stream(packed)
    #  The second stream starts after the first one's terminator.
    i = 0
    n = 0
    while True:
        c = packed[i]
        i += 1
        if c == 0:
            break
        if c == RUN_MARK:
            n += packed[i]
            i += 2
        else:
            n += c
            i += c
    data = unpack_stream(packed[i:])
    out = bytearray(size)
    out[0::2] = masks
    out[1::2] = data
    return bytes(out)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    raw = open(argv[0], "rb").read()
    packed = pack_library(raw)

    padded = raw + (b"\x00" if len(raw) % 2 else b"")
    if unpack_library(packed, len(padded)) != padded:
        print("error: the packer does not round-trip", file=sys.stderr)
        return 1

    open(argv[1], "wb").write(packed)
    print(f"{argv[1]}: {len(raw)} -> {len(packed)} bytes "
          f"({100 * len(packed) // len(raw)}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
