#!/usr/bin/env python3
"""The sprite map: every ship sprite in one PNG you can paint, and back again.

    python3 tools/spritemap.py export                 # art/*.retrotools.json -> art/spritemap.png
    python3 tools/spritemap.py split                  # art/spritemap.png -> art/spritemap-{a,b,c}.png + .aseprite
    python3 tools/spritemap.py aseprite               # the three .aseprite again, from the sheets as they are
    python3 tools/spritemap.py import                 # the maps -> src/gen/spr_*.asm
    python3 tools/spritemap.py import --check         # ...and compare with what the JSONs give

The build imports the maps when they exist (see the Makefile): `make` then
reads the sprites off art/spritemap-a.png, -b.png and -c.png -- one per size
tier -- if all three are there, else off art/spritemap.png, and the RetroTools
projects are only the source of the first export. Delete the PNGs to go back
to them.

THE THREE SHEETS, FOR ASEPRITE
------------------------------
`split` writes one sheet per tier: eight rows, one a class in the game's
order, six columns, one a yaw view, every cell exactly the tier's size, GAP
pixels apart both ways and MARGIN in from the edge -- a uniform grid, which is
what Aseprite's File > Import Sprite Sheet wants: type By Rows, the cell's
width and height, offset (MARGIN, MARGIN), padding (GAP, GAP). Beside each
PNG goes the same picture as a .aseprite: indexed, the five colours as the
palette with magenta as the TRANSPARENT index (so NOT DRAWN is transparent in
the editor and comes back as magenta or as alpha 0, and the importer reads
both), a grid of the cell pitch, and a named slice per sprite --
"interceptor/2" is the interceptor's third view. Written by this file from
the spec of the format; not verified in Aseprite itself.

THE LAYOUT
----------
One row per class, in the game's class order (interceptor, mothership,
harvester, scout, bomber, frigate, salvage, destroyer). In each row, the three
size tiers left to right -- A 8x6, B 16x10, C 24x16 -- and inside each tier
the six yaw views, 60 degrees apart, view 0 nose-on. Every cell is exactly its
tier's size; cells are GAP pixels apart and tiers TIER_GAP apart, on a field
of the "transparent" colour. The importer cuts the cells by arithmetic, so the
grid must not be moved; anything outside a cell is ignored.

THE FIVE COLOURS, and it is five, not four
------------------------------------------
The game has four inks and a sprite has a MASK: a pixel is either a pen 0..3
that is DRAWN, or not drawn at all, and "drawn black" is not the same as
"not drawn" -- the ships' shadow sides are drawn black over whatever is behind
them. A PNG cannot say both with one black, so the map uses a fifth colour for
"not drawn":

    index 0  black    #000000  pen 0, drawn (the ship's own dark side)
    index 1  white    #FFFFFF  pen 1, the fleet
    index 2  sky blue #0080FF  pen 2, shading
    index 3  red      #FF0000  pen 3 (nothing uses it in a sprite: enemies are
                               recoloured by the blitter)
    index 4  magenta  #FF00FF  NOT DRAWN -- the mask

art/homeplanet.gpl is the same five for GIMP. Paint in indexed mode with that
palette, or in RGB with exactly those colours: the importer maps by nearest
colour and refuses anything that is not close to one of the five.
"""

import argparse
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rt2sprite  # noqa: E402

from PIL import Image  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")
GEN = os.path.join(ROOT, "src", "gen")
PNG = os.path.join(ART, "spritemap.png")
GPL = os.path.join(ART, "homeplanet.gpl")

CLASSES = ["interceptor", "mothership", "harvester", "scout", "bomber", "frigate", "salvage", "destroyer"]
TIERS = ["a", "b", "c"]
VIEWS = 6
GAP = 2
TIER_GAP = 8
MARGIN = 4

SPLIT = {t: os.path.join(ART, f"spritemap-{t}.png") for t in TIERS}
ASEPRITE = {t: os.path.join(ART, f"spritemap-{t}.aseprite") for t in TIERS}

COLOURS = [(0, 0, 0), (255, 255, 255), (0, 128, 255), (255, 0, 0), (255, 0, 255)]
NAMES = ["pen 0 black (drawn)", "pen 1 white", "pen 2 sky blue", "pen 3 red", "NOT DRAWN (mask)"]
NONE = 4


def project_path(cls: str) -> str:
    return os.path.join(ART, f"{cls}.retrotools.json")


def sprite_of(doc: dict, cls: str, tier: str) -> dict:
    for s in doc["sprites"]:
        if s["name"] == f"{cls}_{tier}":
            return s
    raise SystemExit(f"{cls}: no sprite named {cls}_{tier} in its project")


def tier_sizes(doc: dict, cls: str) -> list[tuple[int, int]]:
    return [(sprite_of(doc, cls, t)["width"], sprite_of(doc, cls, t)["height"]) for t in TIERS]


def layout(sizes: list[tuple[int, int]]):
    """Cell origins for one row: [(tier, view, x, y)], and the row's width and height."""
    cells, x = [], MARGIN
    for t, (w, h) in enumerate(sizes):
        for v in range(VIEWS):
            cells.append((t, v, x, w, h))
            x += w + GAP
        x += TIER_GAP
    return cells, x + MARGIN - GAP - TIER_GAP, max(h for _, h in sizes)


def export(png: str = PNG) -> None:
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
    for cls in CLASSES:
        if tier_sizes(docs[cls], cls) != sizes:
            raise SystemExit(f"{cls}: its tiers are not the same sizes as the interceptor's")
    cells, row_w, row_h = layout(sizes)
    W, H = row_w, MARGIN + len(CLASSES) * (row_h + TIER_GAP) - TIER_GAP + MARGIN
    img = Image.new("P", (W, H), NONE)
    pal = []
    for c in COLOURS:
        pal += list(c)
    img.putpalette(pal + [0] * (768 - len(pal)))
    px = img.load()
    for row, cls in enumerate(CLASSES):
        y0 = MARGIN + row * (row_h + TIER_GAP)
        for t, v, x0, w, h in cells:
            sprite = sprite_of(docs[cls], cls, TIERS[t])
            frame = sorted(sprite["frames"], key=lambda f: f["index"])[v]
            pens, opaque = rt2sprite.frame_grids(sprite, frame)
            for y in range(h):
                for x in range(w):
                    px[x0 + x, y0 + y] = pens[y][x] if opaque[y][x] else NONE
    img.save(png, optimize=True)
    print(f"wrote {png}: {W}x{H}, {len(CLASSES)} classes x {len(TIERS)} tiers x {VIEWS} views")


def nearest(rgb) -> int:
    best, bd = None, None
    for i, c in enumerate(COLOURS):
        d = sum((a - b) ** 2 for a, b in zip(rgb[:3], c))
        if bd is None or d < bd:
            best, bd = i, d
    if bd > 3 * 40 ** 2:
        raise SystemExit(f"a pixel of colour {tuple(rgb[:3])} is not one of the map's five")
    return best


def read_map(png: str = PNG):
    img = Image.open(png)
    if img.mode == "P":
        pal = img.getpalette()
        table = {}
        px = img.load()
        conv = lambda i: table.setdefault(i, nearest(pal[i * 3:i * 3 + 3]))
        return img.size, lambda x, y: conv(px[x, y])
    rgb = img.convert("RGBA")
    px = rgb.load()
    def at(x, y):
        r, g, b, a = px[x, y]
        return NONE if a < 128 else nearest((r, g, b))
    return rgb.size, at


def sheet_layout(w: int, h: int):
    """One tier's sheet: cell origins [(row, view, x, y)] and the sheet's size.
    A uniform grid -- the same GAP between rows as between columns -- so an
    editor can import it as a sprite sheet with one cell size and one padding."""
    cells = []
    for row in range(len(CLASSES)):
        for v in range(VIEWS):
            cells.append((row, v, MARGIN + v * (w + GAP), MARGIN + row * (h + GAP)))
    W = MARGIN * 2 + VIEWS * w + (VIEWS - 1) * GAP
    H = MARGIN * 2 + len(CLASSES) * h + (len(CLASSES) - 1) * GAP
    return cells, W, H


def cells_from_map(png: str = PNG):
    """Every sprite of the combined map as {(cls, tier, view): [[index]]}."""
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
    cells, row_w, row_h = layout(sizes)
    (W, H), at = read_map(png)
    want_h = MARGIN + len(CLASSES) * (row_h + TIER_GAP) - TIER_GAP + MARGIN
    if (W, H) != (row_w, want_h):
        raise SystemExit(f"{png} is {W}x{H}; the layout wants {row_w}x{want_h} -- the grid has moved")
    out = {}
    for row, cls in enumerate(CLASSES):
        y0 = MARGIN + row * (row_h + TIER_GAP)
        for t, v, x0, w, h in cells:
            out[(cls, TIERS[t], v)] = [[at(x0 + x, y0 + y) for x in range(w)] for y in range(h)]
    return sizes, out


def cells_from_sheets(paths: dict):
    """The same, off the three sheets."""
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
    out = {}
    for t, (w, h) in zip(TIERS, sizes):
        cells, W, H = sheet_layout(w, h)
        (gw, gh), at = read_map(paths[t])
        if (gw, gh) != (W, H):
            raise SystemExit(f"{paths[t]} is {gw}x{gh}; the sheet wants {W}x{H} -- the grid has moved")
        for row, v, x0, y0 in cells:
            out[(CLASSES[row], t, v)] = [[at(x0 + x, y0 + y) for x in range(w)] for y in range(h)]
    return sizes, out


def write_sheet(png: str, w: int, h: int, grids: dict, tier: str):
    """One tier's PNG, indexed in the five colours."""
    cells, W, H = sheet_layout(w, h)
    img = Image.new("P", (W, H), NONE)
    pal = []
    for c in COLOURS:
        pal += list(c)
    img.putpalette(pal + [0] * (768 - len(pal)))
    px = img.load()
    for row, v, x0, y0 in cells:
        g = grids[(CLASSES[row], tier, v)]
        for y in range(h):
            for x in range(w):
                px[x0 + x, y0 + y] = g[y][x]
    img.save(png, optimize=True)
    return img


def write_aseprite(path: str, img, w: int, h: int, tier: str):
    """One tier's sheet as an .aseprite, a slice per sprite named class/view."""
    cells, _, _ = sheet_layout(w, h)
    write_ase(path, img, w, h, [(f"{CLASSES[row]}/{v}", x0, y0, w, h) for row, v, x0, y0 in cells])


def write_ase(path: str, img, w: int, h: int, slices: list, margin: int = MARGIN, gap=GAP):
    """An indexed image as an .aseprite: one layer, one frame, the five-colour
    palette with NONE as the transparent index, a grid of the cell pitch
    (w + gap by h + gap, from margin; gap may be an (x, y) pair), and a named
    slice per (name, x, y, w, h).
    Straight from the format's spec (ase-file-specs.md). The HUD's icons come
    through here too."""
    import struct as st
    import zlib
    W, H = img.size
    pixels = img.tobytes()

    def string(text: str) -> bytes:
        b = text.encode("utf-8")
        return st.pack("<H", len(b)) + b

    def chunk(kind: int, body: bytes) -> bytes:
        return st.pack("<IH", 6 + len(body), kind) + body

    chunks = []
    chunks.append(chunk(0x2007, st.pack("<HHI", 1, 0, 0) + bytes(8)))            # colour profile: sRGB
    chunks.append(chunk(0x0004, st.pack("<HBB", 1, 0, len(COLOURS))                # old palette, for old readers
                        + b"".join(bytes(c) for c in COLOURS)))
    pal = st.pack("<III", len(COLOURS), 0, len(COLOURS) - 1) + bytes(8)
    for c, n in zip(COLOURS, NAMES):
        pal += st.pack("<HBBBB", 1, c[0], c[1], c[2], 255) + string(n)
    chunks.append(chunk(0x2019, pal))                                              # palette
    chunks.append(chunk(0x2004, st.pack("<HHHHHHB", 3, 0, 0, 0, 0, 0, 255) + bytes(3) + string("sprites")))
    cel = st.pack("<HhhBHh", 0, 0, 0, 255, 2, 0) + bytes(5) + st.pack("<HH", W, H) + zlib.compress(pixels, 9)
    chunks.append(chunk(0x2005, cel))                                              # the picture, zlib
    for name, x0, y0, sw, sh in slices:
        body = st.pack("<III", 1, 0, 0) + string(name)
        body += st.pack("<IiiII", 0, x0, y0, sw, sh)
        chunks.append(chunk(0x2022, body))                                         # a named slice per sprite
    frame_body = b"".join(chunks)
    n = len(chunks)
    frame = st.pack("<IHHH", 16 + len(frame_body), 0xF1FA, n if n < 0xFFFF else 0xFFFF, 100) + bytes(2) + st.pack("<I", n) + frame_body
    header = st.pack("<IHHHHHIH", 128 + len(frame), 0xA5E0, 1, W, H, 8, 1, 100)
    header += st.pack("<II", 0, 0) + bytes([NONE]) + bytes(3)
    gx, gy = gap if isinstance(gap, tuple) else (gap, gap)
    header += st.pack("<HBBhhHH", len(COLOURS), 1, 1, margin, margin, w + gx, h + gy)
    header += bytes(84)
    assert len(header) == 128
    with open(path, "wb") as f:
        f.write(header + frame)


def split(src: str = PNG, pngs: dict = SPLIT, ases: dict = ASEPRITE) -> None:
    """The combined map -- or the projects, if there is none -- into the three sheets."""
    if os.path.exists(src):
        sizes, grids = cells_from_map(src)
        origin = src
    else:
        docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
        sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
        grids = {}
        for cls in CLASSES:
            for t in TIERS:
                sprite = sprite_of(docs[cls], cls, t)
                for v, frame in enumerate(sorted(sprite["frames"], key=lambda f: f["index"])):
                    pens, opaque = rt2sprite.frame_grids(sprite, frame)
                    grids[(cls, t, v)] = [[pens[y][x] if opaque[y][x] else NONE for x in range(len(pens[0]))]
                                          for y in range(len(pens))]
        origin = "the projects"
    for t, (w, h) in zip(TIERS, sizes):
        img = write_sheet(pngs[t], w, h, grids, t)
        write_aseprite(ases[t], img, w, h, t)
        print(f"wrote {pngs[t]} and {ases[t]}: {img.size[0]}x{img.size[1]}, cells {w}x{h}, "
              f"Aseprite import: By Rows, {w}x{h}, offset {MARGIN},{MARGIN}, padding {GAP},{GAP}")
    print(f"from {origin}")


def aseprite(pngs: dict = SPLIT, ases: dict = ASEPRITE) -> None:
    """The three .aseprite files again, from the sheet PNGs as they are -- for
    after a sheet has been repainted and exported, or an .aseprite saved by
    Aseprite wants its slices and grid back. Reads the sheets, never the
    combined map, so a repainted sheet is never overwritten."""
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
    for t, (w, h) in zip(TIERS, sizes):
        cells, W, H = sheet_layout(w, h)
        (gw, gh), at = read_map(pngs[t])
        if (gw, gh) != (W, H):
            raise SystemExit(f"{pngs[t]} is {gw}x{gh}; the sheet wants {W}x{H} -- the grid has moved")
        img = Image.new("P", (W, H), NONE)
        pal = []
        for c in COLOURS:
            pal += list(c)
        img.putpalette(pal + [0] * (768 - len(pal)))
        px = img.load()
        for y in range(H):
            for x in range(W):
                px[x, y] = at(x, y)
        write_aseprite(ases[t], img, w, h, t)
        print(f"wrote {ases[t]} from {pngs[t]}")


def import_map(check: bool, png: str = PNG, gen: str = GEN, sheets: dict = SPLIT) -> int:
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    if all(os.path.exists(sheets[t]) for t in TIERS):
        sizes, grids = cells_from_sheets(sheets)
        origin = "art/spritemap-{a,b,c}.png"
    else:
        sizes, grids = cells_from_map(png)
        origin = "art/spritemap.png"
    differ = 0
    for cls in CLASSES:
        doc = docs[cls]
        for t, (w, h) in zip(TIERS, sizes):
            sprite = sprite_of(doc, cls, t)
            for v, frame in enumerate(sorted(sprite["frames"], key=lambda f: f["index"])):
                g = grids[(cls, t, v)]
                pixels, mask = bytearray(w * h), bytearray(w * h)
                for y in range(h):
                    for x in range(w):
                        i = g[y][x]
                        if i == NONE:
                            pixels[y * w + x], mask[y * w + x] = 0, 0
                        else:
                            pixels[y * w + x], mask[y * w + x] = i, 1
                frame["pixels"] = base64.b64encode(bytes(pixels)).decode()
                frame["mask"] = base64.b64encode(bytes(mask)).decode()
        text = rt2sprite.convert(doc, rt2sprite.DEFAULT_SHIFTS, [])
        text = text.replace("GENERATED by tools/rt2sprite.py", f"GENERATED by tools/spritemap.py, from {origin}, through tools/rt2sprite.py")
        out = os.path.join(gen, f"spr_{cls}.asm")
        if check:
            have = rt2sprite.convert(rt2sprite.load_project(project_path(cls)), rt2sprite.DEFAULT_SHIFTS, [])
            same = have.split("\n")[2:] == text.split("\n")[2:]
            print(f"{cls}: {'same as the project' if same else 'DIFFERS from the project'}")
            differ += not same
        else:
            os.makedirs(gen, exist_ok=True)
            with open(out, "w", encoding="utf-8") as f:
                f.write(text)
            print(f"wrote {out}")
    return 1 if (check and differ) else 0


def palette() -> None:
    with open(GPL, "w", encoding="utf-8") as f:
        f.write("GIMP Palette\nName: HOMEPLANET\nColumns: 5\n#\n")
        f.write("# The game's four inks and the sprite map's fifth, NOT DRAWN.\n")
        f.write("# See tools/spritemap.py for what each one means.\n")
        for c, n in zip(COLOURS, NAMES):
            f.write(f"{c[0]:3d} {c[1]:3d} {c[2]:3d}\t{n}\n")
    print(f"wrote {GPL}")


def main(argv) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["export", "split", "aseprite", "import", "palette"])
    ap.add_argument("--check", action="store_true", help="import: compare with the projects, write nothing")
    ap.add_argument("--png", default=PNG, help="the combined map to write or read (default art/spritemap.png)")
    ap.add_argument("--sheets", default=ART, help="split/import: the directory of the three spritemap-{a,b,c} sheets (default art/)")
    ap.add_argument("--gen", default=GEN, help="import: where the spr_*.asm go (default src/gen)")
    args = ap.parse_args(argv)
    sheets = {t: os.path.join(args.sheets, f"spritemap-{t}.png") for t in TIERS}
    ases = {t: os.path.join(args.sheets, f"spritemap-{t}.aseprite") for t in TIERS}
    if args.what == "export":
        export(args.png); palette()
        return 0
    if args.what == "split":
        split(args.png, sheets, ases)
        return 0
    if args.what == "aseprite":
        aseprite(sheets, ases)
        return 0
    if args.what == "palette":
        palette()
        return 0
    return import_map(args.check, args.png, args.gen, sheets)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
