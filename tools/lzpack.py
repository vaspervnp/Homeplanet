#!/usr/bin/env python3
"""LZ-pack an image for the loader stub in src/disc.asm.

    python3 tools/lzpack.py IN OUT

DISC.BIN has a hard ceiling -- it loads at #4000 and must end below AMSDOS's
workspace at #A700 -- and for a long time the answer to hitting it was to
move DATA out of the file. The data levers ran out at 23 bytes of headroom;
this is the code lever. Both images the file carries, the low 16K and bank
4, are code and text, which run-length coding cannot touch (tools/
packsprites.py measured it making the file BIGGER) and which an LZ77 takes
to about three quarters.

The format is this project's own, chosen for the DECODER: about sixty bytes
of Z80 in the stub, which is thrown away once the game is running, so the
decoder costs the file nothing that lasts. A stream is a run of tokens:

    0nnnnnnn  b...          n+1 literal bytes follow (1..128)
    10llllll  o             copy l+2 bytes from o+1 back        (offset 1..256)
    11llllll  o_lo o_hi     copy l+3 bytes from o back          (offset 1..65535)
    11000000  00 00         end of stream

and when the six length bits are all set, ONE more byte follows the token,
before the offset, and is added to the length -- so a match runs to 320 or
321 bytes and a longer one is two tokens. A match may overlap its own
output (offset 1 is a run), which is what LDIR does naturally.

Greedy with a one-step lazy look: if the match starting one byte later is
two bytes better, emit a literal first. Not an optimal parse; a few per cent
on the table, and not worth a slower build. unpack() is the reference
decoder and tests/test_lz.py drives the Z80 one against it.
"""

import sys

WINDOW = 65535
MAX_SHORT_OFF = 256
LEN_BITS = 0x3F
MAX_EXTRA = 255


def _find_match(data: bytes, i: int, heads: dict, max_len: int) -> tuple[int, int]:
    """The longest match for data[i:], as (length, offset); (0, 0) if none."""
    n = len(data)
    if i + 2 > n:
        return 0, 0
    key = data[i:i + 2]
    best_len, best_off = 0, 0
    cands = heads.get(key)
    if not cands:
        return 0, 0
    limit = min(max_len, n - i)
    tried = 0
    for j in reversed(cands):
        off = i - j
        if off > WINDOW:
            break
        tried += 1
        if tried > 96:
            break
        #  A quick reject on the byte the current best would have to extend.
        if best_len and data[j + best_len] != data[i + best_len]:
            continue
        L = 2
        while L < limit and data[j + L] == data[i + L]:
            L += 1
        if L > best_len or (L == best_len and off < best_off):
            best_len, best_off = L, off
            if L == limit:
                break
    return best_len, best_off


def _cost(length: int, off: int) -> int:
    """Bytes a match token takes."""
    if off <= MAX_SHORT_OFF:
        base, tok = 2, 2
    else:
        base, tok = 3, 3
    return tok + (1 if length - base >= LEN_BITS else 0)


def _usable(length: int, off: int) -> int:
    """The longest length this token form can carry, at most `length`."""
    base = 2 if off <= MAX_SHORT_OFF else 3
    return min(length, base + LEN_BITS + MAX_EXTRA)


def pack(data: bytes) -> bytes:
    out = bytearray()
    lits = bytearray()
    heads: dict[bytes, list[int]] = {}
    n = len(data)

    def flush_lits():
        while lits:
            chunk = lits[:128]
            del lits[:128]
            out.append(len(chunk) - 1)
            out.extend(chunk)

    def add_heads(pos: int):
        if pos + 2 <= n:
            heads.setdefault(data[pos:pos + 2], []).append(pos)

    i = 0
    while i < n:
        max_len = 3 + LEN_BITS + MAX_EXTRA
        L, off = _find_match(data, i, heads, max_len)
        if L:
            L = _usable(L, off)
        gain = L - _cost(L, off) if L else -1
        take = gain > 0
        if take and i + 1 < n:
            L2, off2 = _find_match(data, i + 1, heads, max_len)
            if L2:
                L2 = _usable(L2, off2)
                if L2 - _cost(L2, off2) >= gain + 2:
                    take = False
        if not take:
            lits.append(data[i])
            add_heads(i)
            i += 1
            continue
        flush_lits()
        base = 2 if off <= MAX_SHORT_OFF else 3
        l6 = L - base
        if l6 >= LEN_BITS:
            extra = l6 - LEN_BITS
            l6 = LEN_BITS
        else:
            extra = None
        if base == 2:
            out.append(0x80 | l6)
            if extra is not None:
                out.append(extra)
            out.append(off - 1)
        else:
            out.append(0xC0 | l6)
            if extra is not None:
                out.append(extra)
            out.append(off & 0xFF)
            out.append(off >> 8)
        for k in range(L):
            add_heads(i + k)
        i += L
    flush_lits()
    out += bytes([0xC0, 0, 0])
    return bytes(out)


def unpack(packed: bytes) -> bytes:
    """The reference decoder: what src/disc.asm's lz_unpack must produce."""
    out = bytearray()
    p = 0
    while True:
        t = packed[p]
        p += 1
        if not t & 0x80:
            n = t + 1
            out += packed[p:p + n]
            p += n
            continue
        length = t & LEN_BITS
        if length == LEN_BITS:
            length += packed[p]
            p += 1
        if t & 0x40:
            length += 3
            off = packed[p] | (packed[p + 1] << 8)
            p += 2
            if off == 0:
                return bytes(out)
        else:
            length += 2
            off = packed[p] + 1
            p += 1
        for _ in range(length):
            out.append(out[-off])


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    raw = open(argv[0], "rb").read()
    packed = pack(raw)
    if unpack(packed) != raw:
        print("error: the packer does not round-trip", file=sys.stderr)
        return 1
    open(argv[1], "wb").write(packed)
    print(f"{argv[1]}: {len(raw)} -> {len(packed)} bytes "
          f"({100 * len(packed) // max(1, len(raw))}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
