#!/usr/bin/env python3
"""The HUD's button icons: authored here as 16x16 pictures in the game's four
inks, exported to art/hudicons.png and art/hudicons.aseprite in the ship
sprite sheets' kind of grid (cells GAP apart, MARGIN in from the edge -- but
GAP is 8 here, not 2, because the row gap under every cell carries the icon's
LABEL in a 3x5 font, outside the sprite), so the owner can repaint them in
Aseprite exactly as they repaint the ships: Import Sprite Sheet, 16x16,
offset 4,4, padding 10,10.

    python3 tools/hudicons.py export      # the pictures below -> art/hudicons.{png,aseprite}
    python3 tools/hudicons.py preview     # build/hudicons-x4.png, to look at
    python3 tools/hudicons.py list        # name, key, cell and description of every icon
    python3 tools/hudicons.py mockup      # build/hud-mockup-x3.png: the proposed screen
    python3 tools/hudicons.py import      # art/hudicons.png -> src/gen/hudicons.asm, for bank 5

The sheet is COLS by ROWS cells, read left to right, top to bottom; ICONS is
the order. `.` is pen 0 (black), `W` pen 1 (white), `B` pen 2 (sky blue), `R`
pen 3 (red) and `M` magenta, NOT DRAWN -- the same five indices as the ship
sheets, so one palette serves both. The two frame cells are the selection
chrome the game draws OVER an icon, which is what the magenta is for.

The inks mean what section 2 says they mean: white is the thing itself, blue
is chrome and what you press, red is the enemy and what wants attention. So a
target is red, a shield's boss is blue, and the ship in every icon is white.

The game reads the icons off the PNG: `import` cuts the cells by the grid and
writes src/gen/hudicons.asm, sixty-four bytes an icon -- sixteen rows of four
Mode 1 bytes, encoded exactly as rt2sprite encodes a sprite's data, with no
mask, because a button is drawn onto the black of the HUD's strip. The
pictures here are the seed, not the source of truth, exactly as
tools/mkships.py's models are for the ships: repaint the PNG and the build
takes the repaint.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spritemap  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = spritemap.ROOT
ART = spritemap.ART
PNG = os.path.join(ART, "hudicons.png")
ASE = os.path.join(ART, "hudicons.aseprite")
PREVIEW = os.path.join(ROOT, "build", "hudicons-x4.png")

W = H = 16
COLS = 8
GAP = 10              # both ways: the row gap holds each icon's LABEL, the column gap lets a label be six characters
MARGIN = spritemap.MARGIN
LABEL_Y = 1           # the label sits this far under its cell, in the gap
INK = {".": 0, "W": 1, "B": 2, "R": 3, "M": spritemap.NONE}
DESC_CHARS = 39               # the line is forty, and bank7_line holds the terminator
DESC_SECS = 4

# (name, label, description, key, group, picture) -- the LABEL is written
# under the cell on the sheet, outside the sprite, in a 3x5 font, six
# characters at most: *"τι είναι το καθένα με όσο το δυνατόν μικρότερη
# περιγραφή"*; the description is what the top strip's second line says for
# DESC_SECS while the button is selected, and DESC_CHARS is that line's width.
ICONS = [
    # -- row 0: the system, and the camera ------------------------------------
    ("menu", "MENU", 'MENU', "ESC", "system", [
        "................",
        "................",
        "................",
        "..WWWWWWWWWWWW..",
        "..WWWWWWWWWWWW..",
        "................",
        "................",
        "..WWWWWWWWWWWW..",
        "..WWWWWWWWWWWW..",
        "................",
        "................",
        "..WWWWWWWWWWWW..",
        "..WWWWWWWWWWWW..",
        "................",
        "................",
        "................",
    ]),
    ("pause", "PAUSE", 'PAUSE', "SPACE", "system", [
        "................",
        "................",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "....WWW...WWW...",
        "................",
        "................",
    ]),
    ("help", "HELP", 'KEY LIST', "?", "system", [
        "................",
        "................",
        "....WWWWWWW.....",
        "...WW.....WW....",
        "...WW.....WW....",
        "..........WW....",
        ".........WW.....",
        "........WW......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        "................",
        ".......WW.......",
        ".......WW.......",
        "................",
        "................",
    ]),
    ("music", "MUSIC", 'MUSIC', "M", "system", [
        "................",
        "................",
        ".........WW.....",
        ".........WWW....",
        ".........WWWW...",
        ".........WW.WW..",
        ".........WW..W..",
        ".........WW.....",
        ".........WW.....",
        ".........WW.....",
        "......WWWWW.....",
        ".....WWWWWW.....",
        ".....WWWWWW.....",
        "......WWWW......",
        "................",
        "................",
    ]),
    ("zoom_in", "ZOOM+", 'ZOOM IN', "Z", "camera", [
        "................",
        "................",
        "....WWWW........",
        "...W....W.......",
        "..W..WW..W......",
        "..W..WW..W......",
        "..W.WWWW.W......",
        "..W..WW..W......",
        "..W..WW..W......",
        "...W....W.......",
        "....WWWW.W......",
        "..........WW....",
        "...........WW...",
        "............WW..",
        "................",
        "................",
    ]),
    ("zoom_out", "ZOOM-", 'ZOOM OUT', "X", "camera", [
        "................",
        "................",
        "....WWWW........",
        "...W....W.......",
        "..W......W......",
        "..W......W......",
        "..W.WWWW.W......",
        "..W......W......",
        "..W......W......",
        "...W....W.......",
        "....WWWW.W......",
        "..........WW....",
        "...........WW...",
        "............WW..",
        "................",
        "................",
    ]),
    ("orbit", "ORBIT", 'TURN THE VIEW', "ARROWS", "camera", [
        "................",
        "................",
        "................",
        ".....BBBBBB.....",
        "...BB......BB...",
        "..B..........B..",
        ".B.....WW.....B.",
        ".B....WWWW....B.",
        ".B....WWWW....B.",
        ".B.....WW.....B.",
        "..B.........WWW.",
        "...BB......WWWW.",
        ".....BBBBBB.WW..",
        "................",
        "................",
        "................",
    ]),
    ("pan", "PAN", 'DRAG THE VIEW', "P", "camera", [
        "................",
        ".......WW.......",
        "......WWWW......",
        ".....WWWWWW.....",
        ".......WW.......",
        "...W...WW...W...",
        "..WW...WW...WW..",
        ".WWWWWWWWWWWWWW.",
        ".WWWWWWWWWWWWWW.",
        "..WW...WW...WW..",
        "...W...WW...W...",
        ".......WW.......",
        ".....WWWWWW.....",
        "......WWWW......",
        ".......WW.......",
        "................",
    ]),
    # -- row 1: the view, and where a squadron goes ----------------------------
    ("centre", "CENTRE", 'CENTRE', "0", "camera", [
        "................",
        ".......WW.......",
        ".......WW.......",
        "....BBBBBBBB....",
        "...B........B...",
        "..B..........B..",
        "..B..........B..",
        ".WB...WWWW...BW.",
        ".WB...WWWW...BW.",
        "..B..........B..",
        "..B..........B..",
        "...B........B...",
        "....BBBBBBBB....",
        ".......WW.......",
        ".......WW.......",
        "................",
    ]),
    ("sensors", "SENSOR", 'SENSOR VIEW', "S", "camera", [
        "................",
        "................",
        ".....BBBBBB.....",
        "...BB......BB...",
        "..B..........B..",
        ".B.........W..B.",
        ".B........W...B.",
        ".B...RR..W....B.",
        ".B......WW....B.",
        ".B......WW.RR.B.",
        ".B............B.",
        "..B..........B..",
        "...BB......BB...",
        ".....BBBBBB.....",
        "................",
        "................",
    ]),
    ("move", "MOVE", 'MOVE DISC', "ENTER", "orders", [
        "................",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        "....BBBWWBBB....",
        "..BB...WW...BB..",
        ".B.....WW.....B.",
        ".B............B.",
        "..BB........BB..",
        "....BBBBBBBB....",
        "................",
        "................",
        "................",
        "................",
    ]),
    ("station", "DOCK", 'DOCK AT BASE', "R", "orders", [
        "................",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        "....WWWWWWWW....",
        ".....WWWWWW.....",
        "......WWWW......",
        ".......WW.......",
        "................",
        "..BBBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "..BBBB....BBBB..",
        "................",
        "................",
    ]),
    ("formation", "FORM", 'FORMATION', "F", "orders", [
        "................",
        "................",
        ".......WW.......",
        ".......WW.......",
        "................",
        "....WW....WW....",
        "....WW....WW....",
        "................",
        ".WW....WW....WW.",
        ".WW....WW....WW.",
        "................",
        "................",
        "..B..B..B..B..B.",
        "................",
        "................",
        "................",
    ]),
    ("jump", "JUMP", 'JUMP OUT', "J", "system", [
        "................",
        "................",
        ".........W......",
        ".........WW.....",
        ".........WWW....",
        ".BB.WWWWWWWWW...",
        ".BB.WWWWWWWWWW..",
        ".B..WWWWWWWWWWW.",
        ".B..WWWWWWWWWWW.",
        ".BB.WWWWWWWWWW..",
        ".BB.WWWWWWWWW...",
        ".........WWW....",
        ".........WW.....",
        ".........W......",
        "................",
        "................",
    ]),
    ("land", "LAND", 'LAND', "L", "system", [
        "................",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        "....WWWWWWWW....",
        ".....WWWWWW.....",
        "......WWWW......",
        ".......WW.......",
        "................",
        ".....BBBBBB.....",
        "...BBBBBBBBBB...",
        "..BBBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "................",
    ]),
    ("info", "INFO", 'SQUAD INFO', "I", "squadron", [
        "................",
        "................",
        ".....BBBBBB.....",
        "...BB......BB...",
        "..B..........B..",
        ".B.....WW.....B.",
        ".B.....WW.....B.",
        ".B............B.",
        ".B....WWW.....B.",
        ".B.....WW.....B.",
        ".B.....WW.....B.",
        "..B...WWWW...B..",
        "...BB......BB...",
        ".....BBBBBB.....",
        "................",
        "................",
    ]),
    # -- row 2: combat, and the economy ----------------------------------------
    ("attack", "ATTACK", 'ATTACK', "A", "combat", [
        "................",
        "................",
        "................",
        ".WW.............",
        ".WWWW...........",
        ".WWWWW......RR..",
        ".WWWWWWW.W.RRRR.",
        ".WWWWWWWW.WRRRR.",
        ".WWWWWWW.W.RRRR.",
        ".WWWWW......RR..",
        ".WWWW...........",
        ".WW.............",
        "................",
        "................",
        "................",
        "................",
    ]),
    ("guard", "GUARD", 'GUARD', "G", "combat", [
        "................",
        "...WWWWWWWWWW...",
        "..W..........W..",
        "..W..........W..",
        "..W...BBBB...W..",
        "..W..BBBBBB..W..",
        "..W..BBBBBB..W..",
        "..W...BBBB...W..",
        "..W..........W..",
        "...W........W...",
        "....W......W....",
        ".....W....W.....",
        "......W..W......",
        ".......WW.......",
        "................",
        "................",
    ]),
    ("strafe", "STRAFE", 'STRAFE', "W", "combat", [
        "................",
        ".WW.............",
        "..WW............",
        "...WW...........",
        "....WW..........",
        ".....WW.........",
        "......WW..RRR...",
        ".......WW.RRR...",
        "........WWRRR...",
        ".........WW...W.",
        "..........WW..W.",
        "...........WW.W.",
        "............WWW.",
        "..........WWWWW.",
        "................",
        "................",
    ]),
    ("fly", "FLY", 'FLY A SHIP', "V", "combat", [
        "................",
        "......WWWW......",
        ".....WWWWWW.....",
        ".....WWWWWW.....",
        "......WWWW......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        ".......WW.......",
        "....BBBBBBBB....",
        "..BBBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "................",
        "................",
    ]),
    ("target_prev", "TGT<", 'PREV TARGET', ",", "combat", "mirror:target_next"),
    ("target_next", "TGT>", 'NEXT TARGET', ".", "combat", [
        "................",
        "................",
        ".BB.....BB......",
        ".B.......B......",
        "................",
        "....RRR.....W...",
        "...RRRRR....WW..",
        "...RRRRR....WWW.",
        "...RRRRR....WWW.",
        "....RRR.....WW..",
        "............W...",
        ".B.......B......",
        ".BB.....BB......",
        "................",
        "................",
        "................",
    ]),
    ("harvest", "MINE", 'HARVEST', "H", "economy", [
        "................",
        "................",
        "......B....B....",
        ".....BBB..BBB...",
        "....BBBBBBBBBB..",
        ".....BBB..BBB...",
        "......B....B....",
        "................",
        ".......WW.......",
        "......WWWW......",
        ".....WWWWWW.....",
        "....WWWWWWWW....",
        "...WWWWWWWWWW...",
        "..WWWW.WW.WWWW..",
        "................",
        "................",
    ]),
    ("tow", "TOW", 'TOW', "T", "economy", [
        "................",
        "................",
        "................",
        "................",
        "..........R.RR..",
        ".WW.......RRRR..",
        ".WWWW.....RRRRR.",
        ".WWWWWWWWWRRRRR.",
        ".WWWWWWWWWRRRRR.",
        ".WWWW.....RRRR..",
        ".WW.......RR.R..",
        "................",
        "................",
        "................",
        "................",
        "................",
    ]),
    # -- row 3: the yard, and the squadron -------------------------------------
    ("build", "BUILD", 'BUILD A SHIP', "B", "economy", [
        "................",
        ".BBBB......BBBB.",
        ".B............B.",
        ".B............B.",
        "................",
        ".......WW.......",
        "......WWWW......",
        ".....WWWWWW.....",
        "....WWWWWWWW....",
        "...WWWWWWWWWW...",
        "..WWWW.WW.WWWW..",
        "................",
        ".B............B.",
        ".B............B.",
        ".BBBB......BBBB.",
        "................",
    ]),
    ("repair", "REPAIR", 'REPAIR', "E", "economy", [
        "................",
        "..........WWW...",
        ".........WWWWW..",
        ".........W..WW..",
        ".........W..WW..",
        "..........WWWW..",
        ".........WWW....",
        "........WWW.....",
        ".......WWW......",
        "......WWW.......",
        ".....WWW........",
        "....WWW.........",
        "...WWW..........",
        "..WWW...........",
        "..WW............",
        "................",
    ]),
    ("recycle", "SCRAP", 'SCRAP FOR RU', "Y", "economy", [
        "................",
        "................",
        "....WWWWWW......",
        "..WWW....WWW..W.",
        ".WW........WW.W.",
        ".W..........WWW.",
        ".W.........WWWW.",
        ".W..............",
        ".W..............",
        ".WW.............",
        "..WW........WW..",
        "...WWW....WWW...",
        ".....WWWWWW.....",
        "................",
        "................",
        "................",
    ]),
    ("divide", "DIVIDE", 'DIVIDE', "D", "squadron", [
        "................",
        "................",
        "................",
        "................",
        "..WWWW..B.WWWW..",
        "..WWWW..B.WWWW..",
        "..WWWW....WWWW..",
        "........B.......",
        "..W.....B....W..",
        ".WW..........WW.",
        ".WWW........WWW.",
        ".WW.....B....WW.",
        "..W.....B....W..",
        "................",
        "................",
        "................",
    ]),
    ("combine", "JOIN", 'JOIN NEXT', "C", "squadron", [
        "................",
        "................",
        "................",
        "..WWWW....WWWW..",
        "..WWWW....WWWW..",
        "..WWWW....WWWW..",
        "................",
        "................",
        "....W......W....",
        "....WW....WW....",
        ".WWWWWW..WWWWWW.",
        "....WW....WW....",
        "....W......W....",
        "................",
        "................",
        "................",
    ]),
    ("split", "SPLIT", 'ONE PER CLASS', "O", "squadron", [
        "................",
        "................",
        "..WW.B....B.WW..",
        ".WWWWBWWWWB.WW..",
        ".....B....B.....",
        "..WW.BWWWWB.WW..",
        ".WWWWB....B.WW..",
        ".....B....B.....",
        "..WW.BWWWWB.WW..",
        ".WWWWB....B.WW..",
        ".....B....B.....",
        "..WW.BWWWWB.WW..",
        ".WWWWB....B.WW..",
        ".....B....B.....",
        "................",
        "................",
    ]),
    ("ship_prev", "SHIP<", 'SHIP PREV', "K", "squadron", "mirror:ship_next"),
    ("ship_next", "SHIP>", 'SHIP NEXT', "L", "squadron", [
        "................",
        "................",
        "................",
        "..BB............",
        "..BB..BB........",
        "......BB........",
        "................",
        "..BB.......W....",
        "..BB..WW...WW...",
        "......WWWWWWWW..",
        "......WW...WW...",
        "...........W....",
        "................",
        "................",
        "................",
        "................",
    ]),
    # -- row 4: the groups, and the chrome -------------------------------------
    ("grp_combat", "COMBAT", 'COMBAT', "", "group", [
        "................",
        ".W............W.",
        ".WW..........WW.",
        "..WW........WW..",
        "...WW......WW...",
        "....WW....WW....",
        ".....WW..WW.....",
        "......RRRR......",
        "......RRRR......",
        ".....WW..WW.....",
        "....WW....WW....",
        "...WW......WW...",
        "..WW........WW..",
        ".WW..........WW.",
        ".W............W.",
        "................",
    ]),
    ("grp_economy", "ECON", 'ECONOMY', "", "group", [
        "................",
        "................",
        "....WWWWWWWW....",
        "..WW........WW..",
        "..WWWWWWWWWWWW..",
        "..BBBBBBBBBBBB..",
        "..WWWWWWWWWWWW..",
        "..BBBBBBBBBBBB..",
        "..WWWWWWWWWWWW..",
        "..BBBBBBBBBBBB..",
        "..WWWWWWWWWWWW..",
        "..BBBBBBBBBBBB..",
        "...WWWWWWWWWW...",
        "................",
        "................",
        "................",
    ]),
    ("grp_squadron", "SQUAD", 'SQUADRON', "", "group", [
        "................",
        "................",
        ".......WW.......",
        "......WWWW......",
        ".....WWWWWW.....",
        "....WWWWWWWW....",
        "................",
        "...WW......WW...",
        "..WWWW....WWWW..",
        ".WWWWWW..WWWWWW.",
        ".WWWWWWWWWWWWWW.",
        "................",
        "................",
        "................",
        "................",
        "................",
    ]),
    ("grp_camera", "CAMERA", 'CAMERA', "", "group", [
        "................",
        "................",
        "................",
        "................",
        ".....WWWWWW.....",
        "...WW......WW...",
        "..W....BB....W..",
        ".W....BBBB....W.",
        ".W....BBBB....W.",
        "..W....BB....W..",
        "...WW......WW...",
        ".....WWWWWW.....",
        "................",
        "................",
        "................",
        "................",
    ]),
    ("grp_system", "SYSTEM", 'SYSTEM', "", "group", [
        "................",
        "......WWWW......",
        "..W...WWWW...W..",
        "..WW.WWWWWW.WW..",
        "...WWWWWWWWWW...",
        "....WWW..WWW....",
        ".WWWWW....WWWWW.",
        ".WWWWW....WWWWW.",
        ".WWWWW....WWWWW.",
        ".WWWWW....WWWWW.",
        "....WWW..WWW....",
        "...WWWWWWWWWW...",
        "..WW.WWWWWW.WW..",
        "..W...WWWW...W..",
        "......WWWW......",
        "................",
    ]),
    ("back", "BACK", 'BACK', "ESC", "group", [
        "................",
        "................",
        "................",
        "................",
        ".W...W..........",
        ".W..WW..........",
        ".W.WWWWWWWWWW...",
        ".WWWWWWWWWWWWW..",
        ".W.WWWWWWWWWW...",
        ".W..WW..........",
        ".W...W..........",
        "................",
        "................",
        "................",
        "................",
        "................",
    ]),
    ("frame", "FRAME", '', "", "chrome", [
        "BBBBBBBBBBBBBBBB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BMMMMMMMMMMMMMMB",
        "BBBBBBBBBBBBBBBB",
    ]),
    ("frame_hot", "PRESS", '', "", "chrome", [
        "WWWWWWWWWWWWWWWW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WMMMMMMMMMMMMMMW",
        "WWWWWWWWWWWWWWWW",
    ]),
]

ROWS = (len(ICONS) + COLS - 1) // COLS
#  What goes into bank 5: the sheet's two frame cells are the game's chrome
#  drawn by fills, and ORBIT is not on the bar (SHIFT + the arrows orbit).
NOT_BANKED = ("frame", "frame_hot", "orbit")
BANKED = [i for i in ICONS if i[0] not in NOT_BANKED]

# A 3x5 font for the labels, one string a glyph, rows top to bottom, `#` lit.
TINY = {
    "A": "010 101 111 101 101", "B": "110 101 110 101 110", "C": "011 100 100 100 011",
    "D": "110 101 101 101 110", "E": "111 100 110 100 111", "F": "111 100 110 100 100",
    "G": "011 100 101 101 011", "H": "101 101 111 101 101", "I": "111 010 010 010 111",
    "J": "001 001 001 101 010", "K": "101 101 110 101 101", "L": "100 100 100 100 111",
    "M": "101 111 111 101 101", "N": "110 101 101 101 101", "O": "010 101 101 101 010",
    "P": "110 101 110 100 100", "Q": "010 101 101 111 011", "R": "110 101 110 101 101",
    "S": "011 100 010 001 110", "T": "111 010 010 010 010", "U": "101 101 101 101 011",
    "V": "101 101 101 101 010", "W": "101 101 111 111 101", "X": "101 101 010 101 101",
    "Y": "101 101 010 010 010", "Z": "111 001 010 100 111", "+": "000 010 111 010 000",
    "-": "000 000 111 000 000", "<": "001 010 100 010 001", ">": "100 010 001 010 100",
    " ": "000 000 000 000 000",
}
TINY_W, TINY_H, TINY_PITCH = 3, 5, 4


def tiny(px, x, y, s, pen):
    for ch in s:
        for r, bits in enumerate(TINY[ch].split()):
            for c, b in enumerate(bits):
                if b == "#" or b == "1":
                    px[x + c, y + r] = pen
        x += TINY_PITCH


def caption(name: str) -> str:
    """What the top strip says while the button is selected: the description
    and the key in parentheses after it -- *"η περιγραφή ... μαζί με το
    πλήκτρο του σε παρένθεση"* -- so the bar teaches the key every time it
    is used. A group has no key and gets no parentheses."""
    _, _, desc, key, _, _ = next(i for i in ICONS if i[0] == name)
    return f"{desc} ({key})" if key else desc


def pictures() -> dict:
    """{name: [[index]]}, mirrors resolved, every picture checked."""
    raw = {name: pic for name, _, _, _, _, pic in ICONS}
    out = {}
    for name, _, _, key, group, pic in ICONS:
        if isinstance(pic, str):
            src = raw[pic.split(":", 1)[1]]
            pic = [row[::-1] for row in src]
        if len(pic) != H or any(len(row) != W for row in pic):
            raise SystemExit(f"{name}: not {W}x{H}")
        bad = {c for row in pic for c in row} - set(INK)
        if bad:
            raise SystemExit(f"{name}: unknown ink {bad}")
        out[name] = [[INK[c] for c in row] for row in pic]
    return out


def cells():
    """[(name, x, y)] on the sheet, and the sheet's size."""
    at = []
    for i, (name, _, _, _, _, _) in enumerate(ICONS):
        c, r = i % COLS, i // COLS
        at.append((name, MARGIN + c * (W + GAP), MARGIN + r * (H + GAP)))
    SW = MARGIN * 2 + COLS * W + (COLS - 1) * GAP
    SH = MARGIN * 2 + ROWS * (H + GAP)      # a gap under the LAST row too: its labels live there
    return at, SW, SH


def export(png: str = PNG, ase: str = ASE):
    pics = pictures()
    at, SW, SH = cells()
    img = Image.new("P", (SW, SH), spritemap.NONE)
    pal = []
    for c in spritemap.COLOURS:
        pal += list(c)
    img.putpalette(pal + [0] * (768 - len(pal)))
    px = img.load()
    labels = {name: label for name, label, _, _, _, _ in ICONS}
    for name, x0, y0 in at:
        g = pics[name]
        for y in range(H):
            for x in range(W):
                px[x0 + x, y0 + y] = g[y][x]
        # the label, centred under the cell, in the row gap: outside the
        # sprite, so the importer never sees it
        lw = len(labels[name]) * TINY_PITCH - 1
        tiny(px, x0 + (W - lw) // 2, y0 + H + LABEL_Y, labels[name], 1)
    os.makedirs(os.path.dirname(png), exist_ok=True)
    img.save(png, optimize=True)
    spritemap.write_ase(ase, img, W, H, [(name, x0, y0, W, H) for name, x0, y0 in at], gap=(GAP, GAP))
    return img


def read(png: str = PNG) -> dict:
    """The icons back off the PNG, {name: [[index]]}, by the grid."""
    at, SW, SH = cells()
    (gw, gh), pix = spritemap.read_map(png)
    if (gw, gh) != (SW, SH):
        raise SystemExit(f"{png} is {gw}x{gh}; the sheet wants {SW}x{SH} -- the grid has moved")
    return {name: [[pix(x0 + x, y0 + y) for x in range(W)] for y in range(H)] for name, x0, y0 in at}


ASM = os.path.join(spritemap.GEN, "hudicons.asm")
CAPTIONS = os.path.join(spritemap.GEN, "hudcaptions.asm")
#  A key as the game's equate, for the bar to press it; and its NAME as the
#  caption shows it: a letter, or a code for the four words (game/hudbar.asm's
#  bar_names, in that order), or 0 for a group. ARROWS is the ORBIT button,
#  which presses no key -- it is a mode -- so its key is 0 and its name 4.
KEY_EQU = {",": "KEY_COMMA", ".": "KEY_PERIOD", "?": "KEY_SLASH", "0": "KEY_0",
           "ESC": "KEY_ESC", "SPACE": "KEY_SPACE", "ENTER": "KEY_ENTER", "ARROWS": "0", "": "0"}
NAME_CODE = {"ESC": 1, "SPACE": 2, "ENTER": 3, "ARROWS": 4, "": 0}


def key_equate(key: str) -> str:
    return KEY_EQU.get(key) or f"KEY_{key}"


def name_code(key: str) -> int:
    return NAME_CODE[key] if key in NAME_CODE else ord(key)
ICON_ROWS = H - 2           # rows 1..14: the top and bottom rows are the frame's margin, blank by rule
ICON_BYTES = W // 4 * ICON_ROWS   # 56: fourteen rows of four bytes, no mask


def encode(g) -> list:
    """One icon as ICON_BYTES of Mode 1 data, row-major, rows 1..14 only:
    the first and last rows are blank by the sheet's own rule (the frame's
    margin) and cost the bank nothing. NOT DRAWN is pen 0: the strip under a
    button is black, so there is nothing to mask."""
    import rt2sprite
    out = []
    for row in g[1:H - 1]:
        pens = [0 if v == spritemap.NONE else v for v in row]
        for x in range(0, W, 4):
            out.append(rt2sprite.encode_mode1_byte(pens[x:x + 4]))
    return out


def import_icons(png: str = PNG, asm: str = ASM, captions: str = CAPTIONS) -> None:
    """art/hudicons.png -> src/gen/hudicons.asm: `hud_icons`, ICON_BYTES each
    in ICONS order, and an ICON_<NAME> equate per icon with its index -- and
    src/gen/hudcaptions.asm: the descriptions, keys and key names."""
    pics = read(png)
    banked = BANKED
    lines = [
        "; GENERATED by tools/hudicons.py import -- do not edit; repaint art/hudicons.png",
        f"; {len(banked)} icons, {W}x{ICON_ROWS} (rows 1..{H - 2} of the {W}x{H} cell), {ICON_BYTES} bytes each: rows of {W // 4} Mode 1 bytes, no mask",
        f"HUD_ICON_BYTES      equ {ICON_BYTES}",
        f"HUD_ICON_ROWS       equ {ICON_ROWS}",
        f"HUD_ICON_W_BYTES    equ {W // 4}",
        f"HUD_ICON_COUNT      equ {len(banked)}",
    ]
    for i, (name, _, _, _, _, _) in enumerate(banked):
        lines.append(f"ICON_{name.upper():13}equ {i}")
    lines.append("hud_icons:")
    for name, _, _, _, _, _ in banked:
        lines.append(f"    ; {name}")
        data = encode(pics[name])
        for r in range(ICON_ROWS):
            row = data[r * (W // 4):(r + 1) * (W // 4)]
            lines.append("    defb " + ",".join(f"#{b:02X}" for b in row))
    lines.append("hud_icons_end:")
    os.makedirs(os.path.dirname(asm), exist_ok=True)
    with open(asm, "w") as f:
        f.write("\n".join(lines) + "\n")
    #  ...and the captions, for bank 6 beside the bar: the descriptions in
    #  icon order, the key each icon presses, and the key's name code.
    cap = [
        "; GENERATED by tools/hudicons.py import -- do not edit; the words are in ICONS",
        "; the descriptions, in icon order, zero-terminated; the bar appends \" (KEY)\"",
        "hud_desc_text:",
    ]
    for name, _, desc, key, _, _ in banked:
        cap.append(f'    defb "{desc}",0' if desc else "    defb 0")
    cap.append("hud_desc_text_end:")
    cap.append("; the key an icon presses (0: none), by icon")
    cap.append("hud_icon_key:")
    cap.append("    defb " + ",".join(key_equate(k) for _, _, _, k, _, _ in banked))
    cap.append("; ...and how the caption names it: a letter, 1..4 a word, 0 nothing")
    cap.append("hud_icon_name:")
    cap.append("    defb " + ",".join(str(name_code(k)) for _, _, _, k, _, _ in banked))
    with open(captions, "w") as f:
        f.write("\n".join(cap) + "\n")


def preview(png: str = PNG, out: str = PREVIEW, scale: int = 4):
    img = Image.open(png).convert("RGB")
    img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    return out


# -- a mock-up of the proposed screen, in the game's own font -----------------
MOCKUP = os.path.join(ROOT, "build", "hud-mockup-x3.png")
RGB = spritemap.COLOURS[:4]
BAR = ["menu", "pause", "move", "station", "formation", "attack", "guard", "harvest",
       "build", "jump", "info", "help", "grp_combat", "grp_economy", "grp_squadron", "grp_camera"]
PITCH = 20            # a button every 20 pixels: 16 of them across the 320
BAR_Y = 168           # HUD_TOP: the button row is the top half of the strip
TEXT_Y = 190          # the numbers row, the bottom half
CTX_H = 20            # the top strip, two lines
CTX_Y1, CTX_Y2 = 1, 11


def font() -> dict:
    """The game's 8x8 glyphs out of src/gfx/text.asm, {char: [row bytes]}."""
    src = open(os.path.join(ROOT, "src", "gfx", "text.asm")).read()
    body = src[src.index("txt_font:"):src.index("txt_font_end:")]
    rows = [int(t.split("%")[1][:8], 2) for t in body.splitlines() if t.strip().startswith("defb %")]
    return {chr(32 + i): rows[i * 8:i * 8 + 8] for i in range(len(rows) // 8)}


def text(px, x, y, s, pen, glyphs):
    for ch in s:
        for r, bits in enumerate(glyphs.get(ch, glyphs[" "])):
            for c in range(8):
                if bits & (0x80 >> c):
                    px[x + c, y + r] = RGB[pen]
        x += 8


def run(px, x, y, words, glyphs):
    """The context bar's run: key blue, action white, alternating."""
    for i, w in enumerate(words):
        text(px, x, y, w, 2 if i % 2 == 0 else 1, glyphs)
        x += (len(w) + 1) * 8


BAR_W, BAR_H = 72, 6   # a hull bar: 18 bytes wide, blue frame, white fill, red under the alarm


def bar(px, x, y, pct, alarm=33):
    for c in range(BAR_W):
        for r in range(BAR_H):
            edge = r in (0, BAR_H - 1) or c in (0, BAR_W - 1)
            if edge:
                px[x + c, y + r] = RGB[2]
    fill = (BAR_W - 2) * pct // 100
    pen = 3 if pct < alarm else 1
    for c in range(fill):
        for r in range(1, BAR_H - 1):
            px[x + 1 + c, y + r] = RGB[pen]


SQ_PITCH, SQ_W, SQ_H = 8, 2, 7   # the nine squadron marks: a little line each


def squadrons(px, x, y, active, selected, count, glyphs):
    """SQUADRONS, nine marks -- blue for an active squadron, white for an
    empty one, RED for the selected one, the owner's assignment -- then the
    selected one's number and its ship count, and nothing else."""
    text(px, x, y, "SQUADRONS", 2, glyphs)
    x += 9 * 8 + 6
    for n in range(1, 10):
        pen = 3 if n == selected else 2 if n in active else 1
        for c in range(SQ_W):
            for r in range(SQ_H):
                px[x + (n - 1) * SQ_PITCH + c, y + r] = RGB[pen]
    x += 9 * SQ_PITCH + 6
    text(px, x, y, f"{selected} {count}", 1, glyphs)


def blit(px, x, y, g, over=False):
    for r, row in enumerate(g):
        for c, v in enumerate(row):
            if v == spritemap.NONE:
                continue
            if over and v == 0:
                continue
            px[x + c, y + r] = RGB[v]


def mockup(out: str = MOCKUP, selected: str = "attack", scale: int = 3):
    glyphs = font()
    pics = pictures()
    img = Image.new("RGB", (320, 200), RGB[0])
    px = img.load()
    # the top strip: line 1 the two hull bars and the treasury, line 2 the
    # squadrons; the bottom strip: the buttons, and under them the selected
    # button's description
    x = 0
    for label, pct in (("HULL", 98), ("BASE", 31)):
        text(px, x, CTX_Y1, label, 2, glyphs)
        bar(px, x + 34, CTX_Y1 + 1, pct)
        x += 34 + BAR_W + 10
    run(px, x, CTX_Y1, ["RU", "1050", "M", "3"], glyphs)
    # line 2: the squadrons, the yard, the way out -- the strip's second line
    # is the fleet's, the buttons' description goes under the buttons
    squadrons(px, 0, CTX_Y2, active={1, 2, 5}, selected=2, count=15, glyphs=glyphs)
    run(px, 200, CTX_Y2, [">", "SCT 4"], glyphs)
    text(px, 288, CTX_Y2, "JUMP", 3, glyphs)
    # the playfield: the lattice, and a squadron of sixteen with the base
    for i in range(4):
        for j in range(4):
            px[70 + i * 60 + j * 4, 120 + j * 12 - i * 3] = RGB[2]
    try:
        _, cells = spritemap.cells_from_sheets(spritemap.SPLIT)
        ship = cells[("interceptor", "b", 3)]
        base = cells[("mothership", "c", 2)]
        blit(px, 148, 84, base, over=True)
        for i in range(16):
            blit(px, 96 + (i % 4) * 34 + (i // 4) * 6, 60 + (i // 4) * 22, ship, over=True)
    except Exception:
        pass
    # the bottom strip: the buttons, the frame, the numbers
    for i, name in enumerate(BAR):
        x = 2 + i * PITCH
        blit(px, x, BAR_Y, pics[name])
        if name == selected:
            blit(px, x, BAR_Y, pics["frame"])
    text(px, 0, TEXT_Y, caption(selected), 1, glyphs)
    img = img.resize((320 * scale, 200 * scale), Image.NEAREST)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    return out


def main(argv) -> int:
    cmd = argv[1] if len(argv) > 1 else "export"
    if cmd == "export":
        export()
        print(f"wrote {PNG} and {ASE}: {len(ICONS)} icons, {COLS}x{ROWS} cells of {W}x{H}")
    elif cmd == "preview":
        print(preview())
    elif cmd == "mockup":
        print(mockup())
    elif cmd == "import":
        import_icons()
        print(f"wrote {ASM}: {len(BANKED)} icons, {ICON_BYTES * len(BANKED)} bytes; and {CAPTIONS}")
    elif cmd == "list":
        at, _, _ = cells()
        for (name, label, desc, key, group, _), (_, x, y) in zip(ICONS, at):
            print(f"{name:14} {label:6} {group:9} at {x:3},{y:3}  {caption(name)}")
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
