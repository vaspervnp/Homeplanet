#!/usr/bin/env python3
"""The sprite map: every ship sprite in one PNG you can paint, and back again.

    python3 tools/spritemap.py export                 # art/*.retrotools.json -> art/spritemap.png
    python3 tools/spritemap.py import                 # art/spritemap.png -> src/gen/spr_*.asm
    python3 tools/spritemap.py import --check         # ...and compare with what the JSONs give

The build imports the PNG when it exists (see the Makefile): `make` then reads
the sprites off art/spritemap.png and the RetroTools projects are only the
source of the first export. Delete the PNG to go back to them.

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


def import_map(check: bool, png: str = PNG, gen: str = GEN) -> int:
    docs = {cls: rt2sprite.load_project(project_path(cls)) for cls in CLASSES}
    sizes = tier_sizes(docs[CLASSES[0]], CLASSES[0])
    cells, row_w, row_h = layout(sizes)
    (W, H), at = read_map(png)
    want_h = MARGIN + len(CLASSES) * (row_h + TIER_GAP) - TIER_GAP + MARGIN
    if (W, H) != (row_w, want_h):
        raise SystemExit(f"{png} is {W}x{H}; the layout wants {row_w}x{want_h} -- the grid has moved")
    differ = 0
    for row, cls in enumerate(CLASSES):
        y0 = MARGIN + row * (row_h + TIER_GAP)
        doc = docs[cls]
        for t, v, x0, w, h in cells:
            sprite = sprite_of(doc, cls, TIERS[t])
            frame = sorted(sprite["frames"], key=lambda f: f["index"])[v]
            pixels, mask = bytearray(w * h), bytearray(w * h)
            for y in range(h):
                for x in range(w):
                    i = at(x0 + x, y0 + y)
                    if i == NONE:
                        pixels[y * w + x], mask[y * w + x] = 0, 0
                    else:
                        pixels[y * w + x], mask[y * w + x] = i, 1
            frame["pixels"] = base64.b64encode(bytes(pixels)).decode()
            frame["mask"] = base64.b64encode(bytes(mask)).decode()
        text = rt2sprite.convert(doc, rt2sprite.DEFAULT_SHIFTS, [])
        text = text.replace("GENERATED by tools/rt2sprite.py", "GENERATED by tools/spritemap.py, from art/spritemap.png, through tools/rt2sprite.py")
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
    ap.add_argument("what", choices=["export", "import", "palette"])
    ap.add_argument("--check", action="store_true", help="import: compare with the projects, write nothing")
    ap.add_argument("--png", default=PNG, help="the map to write or read (default art/spritemap.png)")
    ap.add_argument("--gen", default=GEN, help="import: where the spr_*.asm go (default src/gen)")
    args = ap.parse_args(argv)
    if args.what == "export":
        export(args.png); palette()
        return 0
    if args.what == "palette":
        palette()
        return 0
    return import_map(args.check, args.png, args.gen)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
