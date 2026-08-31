#!/usr/bin/env python3
"""Put the extended sprite banks on the disc, as raw sectors.

    python3 tools/discbanks.py build/homeplanet.dsk build/homeplanet.sym \\
            build/bank5.raw build/bank6.raw build/bank7.raw

Why the banks are not in DISC.BIN
---------------------------------
DISC.BIN loads at #4000 and must finish below #A700, where AMSDOS keeps its
workspace: a 26368-byte ceiling, and the file is already 25 KB. A ship class's
sprite library is 4320 bytes raw and several hundred packed, and Homeplanet.md
section 8 has eight classes -- 33.75 KB, which no amount of packing fits.

So ALL EIGHT libraries live in extended banks 5, 6 and 7 -- three, three and
two, because six yaw views made a library small enough that three fit a 16K
window -- and those banks travel on the disc as raw sectors that
src/sys/libload.asm reads at boot. This tool is the writing half of that.

Bank 7 is the short one and is padded out to LIB_SECTORS like the others: the
loader reads a fixed count into every bank, because a per-bank length would be
a fourth number for the assembler, this tool and lib_load to keep in step.

Raw sectors, not AMSDOS files
-----------------------------
The same trade the fleet save already makes, for the same reason: reading an
AMSDOS file means implementing directory allocation, which is several hundred
bytes more than the low 16K has to spare. AMSDOS hands out blocks from track 0
upward and DISC.BIN takes six tracks, so the library area at track 12 is a
long way from anything it would use -- but copy another file onto this disc
with CP/M and it may land on them.

There is exactly ONE copy of the layout, and it is in the assembly
-------------------------------------------------------------------
LIB_TRACK, LIB_TRACKS_PER_BANK, LIB_SECTORS and the rest are equates in
src/sys/libload.asm. RASM exports equates to the symbol file, so this tool
reads them from there rather than keeping a second copy that could drift. A
loader and a writer that disagree about where a sector is produce a disc that
loads garbage, silently, and looks exactly like a corrupted bank.

The .dsk format
---------------
EXTENDED CPC DSK: a 256-byte disc header, then one track at a time, each a
256-byte Track-Info block followed by its sectors in the order the sector-ID
table lists them. Track lengths come from the size table at offset #34 of the
disc header (in units of 256 bytes), because an extended image is allowed to
have tracks of different sizes.
"""

from __future__ import annotations

import re
import sys

DISC_HEADER = 0x100
TRACK_HEADER = 0x100
TRACK_SIZE_TABLE = 0x34
SECTOR_ID_TABLE = 0x18
SECTOR_ID_STRIDE = 8

STANDARD = b"MV - CPC"
EXTENDED = b"EXTENDED"


class DiscError(Exception):
    pass


_SYM_LINE = re.compile(r"^(\S+)\s+#([0-9A-Fa-f]+)\s")


def symbols(path: str) -> dict[str, int]:
    out = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _SYM_LINE.match(line)
            if m:
                out[m.group(1).upper()] = int(m.group(2), 16)
    if not out:
        raise DiscError(f"no symbols in {path}")
    return out


class Disc:
    """Just enough EDSK to find a sector by (track, sector id)."""

    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        magic = bytes(self.data[:8])
        if magic not in (STANDARD, EXTENDED):
            raise DiscError(f"{path} is not a DSK image")
        self.extended = magic == EXTENDED
        self.tracks = self.data[0x30]
        self.sides = self.data[0x31]
        if self.sides != 1:
            raise DiscError(f"{path} is double sided; the game assumes one")

    def track_offset(self, track: int) -> int:
        if track >= self.tracks:
            raise DiscError(
                f"track {track} is past the end of a {self.tracks}-track image"
            )
        off = DISC_HEADER
        for t in range(track):
            off += self._track_length(t)
        return off

    def _track_length(self, track: int) -> int:
        if self.extended:
            return self.data[TRACK_SIZE_TABLE + track] * 256
        return self.data[0x32] | (self.data[0x33] << 8)

    def sector_offset(self, track: int, sector_id: int) -> tuple[int, int]:
        """Byte offset and length of one sector's data."""
        base = self.track_offset(track)
        if bytes(self.data[base:base + 10]) != b"Track-Info":
            raise DiscError(f"track {track} has no Track-Info block")
        spt = self.data[base + 0x15]
        n = self.data[base + 0x14]
        size = 128 << n
        pos = base + TRACK_HEADER
        for s in range(spt):
            entry = base + SECTOR_ID_TABLE + s * SECTOR_ID_STRIDE
            this_id = self.data[entry + 2]
            #  An extended image records each sector's real length; a standard
            #  one has them all the same.
            this_len = (self.data[entry + 6] | (self.data[entry + 7] << 8)) \
                if self.extended else size
            if not this_len:
                this_len = size
            if this_id == sector_id:
                return pos, this_len
            pos += this_len
        raise DiscError(f"track {track} has no sector #{sector_id:02X}")

    def write_sector(self, track: int, sector_id: int, payload: bytes) -> None:
        off, length = self.sector_offset(track, sector_id)
        if len(payload) != length:
            raise DiscError(
                f"track {track} sector #{sector_id:02X} is {length} bytes, "
                f"not {len(payload)}"
            )
        self.data[off:off + length] = payload

    def save(self) -> None:
        open(self.path, "wb").write(bytes(self.data))


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    dsk_path, sym_path = argv[0], argv[1]
    banks = argv[2:]

    sym = symbols(sym_path)
    try:
        track0 = sym["LIB_TRACK"]
        per_bank = sym["LIB_TRACKS_PER_BANK"]
        n_banks = sym["LIB_BANKS"]
        sectors = sym["LIB_SECTORS"]
        first = sym["LIB_FIRST_SECTOR"]
        last = sym["LIB_LAST_SECTOR"]
        sector_size = sym["FDC_SECTOR_SIZE"]
    except KeyError as e:
        raise DiscError(f"{sym_path} has no {e.args[0]} -- is it the game's?")

    if len(banks) != n_banks:
        raise DiscError(f"LIB_BANKS is {n_banks} but {len(banks)} images were given")

    disc = Disc(dsk_path)
    per_track = last - first + 1
    if sectors > per_bank * per_track:
        raise DiscError(
            f"LIB_SECTORS is {sectors}, which does not fit "
            f"{per_bank} tracks of {per_track}"
        )

    total = 0
    for i, path in enumerate(banks):
        image = open(path, "rb").read()
        room = sectors * sector_size
        if len(image) > room:
            raise DiscError(
                f"{path} is {len(image)} bytes, and LIB_SECTORS leaves {room}"
            )
        #  Padded to the sector, because the loader reads a fixed count -- a
        #  short last sector would be a fourth length to keep in step.
        image = image + b"\x00" * (room - len(image))

        for s in range(sectors):
            track = track0 + i * per_bank + s // per_track
            sector_id = first + s % per_track
            disc.write_sector(
                track, sector_id,
                image[s * sector_size:(s + 1) * sector_size])
        total += sectors
        print(f"{path}: bank {5 + i} -> tracks "
              f"{track0 + i * per_bank}-{track0 + i * per_bank + per_bank - 1}, "
              f"{sectors} sectors")

    disc.save()
    print(f"{dsk_path}: {total} sectors of sprite library written")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except DiscError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
