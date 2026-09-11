# hud2.md — buttons at the bottom, two lines at the top

*"Θέλω μία μεγάλη αλλαγή στο HUD που θα την ξεκινήσεις σε νέο branch. Θα
μπουν εικονίδια (buttons) για τις λειτουργίες στο κάτω μέρος, κάποια θα
είναι ομαδοποιημένα. Το πάνω hud θα γίνει 2 γραμμές. Κάθε λειτουργία που θα
επιλέγεται θα εμφανίζεται η περιγραφή της στο πάνω hud για 4 δευτερόλεπτα.
Ξεκίνησε με τον σχεδιασμό των γραφικών των κουμπιών."*

*"Όταν τα βελάκια δεν χρησιμοποιούνται για να μετακινήσουν squadron θα
επιλέγουν buttons στο hud με απόλυτη προτεραιότητα."*

*"Τα ενεργά squadrons θα φαίνονται γραφικά με τον τίτλο Squadrons και μετά
μπλε γραμμούλα για τα ενεργά και άσπρη για τα μη ενεργά. Θα φαίνεται μόνο ο
αριθμός (1 ως 9) και ο αριθμός σκαφών του επιλεγμένου."* *"Το επιλεγμένο
squadron να ξεχωρίζει με κόκκινο."*

*"Το Hull και το Base ποσοστό να είναι γραφικά (progress bars). Να είναι
στην πρώτη γραμμή του πάνω hud. Να φύγουν από εκεί το κείμενο για τις
λειτουργίες. Αντικαθίσταται με τα buttons στο κάτω hud."*

Branch `hud-buttons`. This file is the plan; the sections are ticked as they
land.

## 1. The icons — DONE, and the owner's to repaint

`tools/hudicons.py` holds forty 16×16 pictures in the four inks and writes
`art/hudicons.png` and `art/hudicons.aseprite` in the ship sheets' kind of
grid — cells 4 in from the edge, but **8 apart rather than 2**, because the
gap under every cell carries the icon's **label** in a 3×5 font (*"από κάτω
από κάθε button ... τι είναι το καθένα με όσο το δυνατόν μικρότερη
περιγραφή"*): `MENU`, `ZOOM+`, `DOCK`, `TGT>`, `MINE`, `SCRAP`, six
characters at most, outside the sprite so the importer never reads them. So
Aseprite's *Import Sprite Sheet* wants 16×16, offset 4,4, padding 10,10 — or
open the `.aseprite`, which carries the grid and a named slice per icon. Same five-colour palette as the ships:
magenta is NOT DRAWN, and the two frame cells use it so the game can lay the
selection frame over an icon.

| row | cells |
|---|---|
| 0 | MENU, PAUSE, HELP, MUSIC, ZOOM IN, ZOOM OUT, ORBIT, PAN |
| 1 | CENTRE BASE, SENSORS, MOVE, STATION, FORMATION, JUMP, LAND, INFO |
| 2 | ATTACK, GUARD, STRAFE, FLY, TARGET PREV, TARGET NEXT, HARVEST, TOW |
| 3 | BUILD, REPAIR, RECYCLE, DIVIDE, COMBINE, SPLIT BY CLASS, SHIP PREV, SHIP NEXT |
| 4 | the five GROUP icons (combat, economy, squadron, camera, system), BACK, and the two frames |

**Why 16×16.** A Mode 1 byte is four pixels, so 16 wide is exactly four bytes
and a button can be blitted with the ordinary sprite path (no pre-shift needed
if buttons sit on even pixels, which a 20-pixel pitch gives). The HUD strip is
32 lines: one row of buttons is half of it, which leaves the other half for a
second row — the open group's members — or for whatever text does not fit at
the top. Sixteen buttons at a 20-pixel pitch fill the 320.

**The inks mean what §2 says.** White is the thing, blue is chrome and what
you press, red is the enemy and what wants attention. So the target in
TARGET NEXT and ATTACK is red, the Mothership under STATION is blue, and the
ship in every icon is white. The selection frame is blue at rest and white
when pressed.

**ORBIT is a button now, because of the arrows rule below.** Today the cursor
keys orbit the camera whenever nothing else has them; once they walk the
button bar by default, orbiting is a MODE the player enters — like PAN is
already — and leaves with ESC.

## 2. What the arrows do — the rule

> The cursor keys belong to the move disc, the pan, the orbit and the cockpit
> while one of those is open. Otherwise they walk the button bar, and nothing
> else may take them.

"Absolute priority" means the bar is the DEFAULT owner rather than the
fallback: `order_update`'s chain today is disc → pilot → pan → orbit, and it
becomes disc → pilot → pan → orbit-mode → bar. Left and right move the
selection frame along the row; ENTER presses the button under it; ESC closes
an open group (BACK) or opens the menu as it does now. Up and down step
between the two rows while a group is open.

**Every key still works.** A button INJECTS its key the way the orders menu
does (`key_inject`), so the bar is a second front end onto `phase4_commands`
and not a second copy of any command — the exact reason the menu was built
that way. Pressing `A` and pressing the ATTACK button are the same event by
construction.

## 3. The bar's layout — TO DECIDE

Sixteen slots. A first cut, to be argued with:

```
MENU PAUSE | MOVE STATION FORMATION | ATTACK GUARD | HARVEST BUILD | JUMP | INFO HELP
   + groups: COMBAT+ (strafe, fly, target prev/next)
             ECONOMY+ (tow, repair, recycle)
             SQUADRON+ (divide, combine, split, ship prev/next)
             CAMERA+ (zoom in/out, orbit, pan, centre, sensors)
```

That is 12 direct + 4 groups = 16. A group opens its members on the second
row; BACK (or ESC) closes it. `LAND` replaces `JUMP` on the last mission, as
the HUD's word does today, through `mis_is_last`.

**Modal buttons stay modal.** `, .` mean "step the target" with the panel
shut and "step the price list" with it open; the bar shows whichever pair is
live, which is what the context bar does now in words.

## 4. The top strip: two lines — TO BUILD

`CTX_BAR_H` 10 → 20, two text rows, and **the context bar's key list is gone
from it**: the buttons are what say which keys are live now, so `ESC MENU
ENTER MOVE B BUILD A ATTACK` has no job left. What the old bar said that was
not a key list — `PAUSED`, `JUMPING nn ESC CANCEL`, the build panel's class
and price and its `ENTER BUY` / `NEED MORE RU` — is STATE, and it moves to
line 2 (below).

**Line 1 is the fleet's health, as bars.** `HULL` and `BASE` — the two
figures `wave_draw` puts on the HUD's third row today — become two
**progress bars**, 72 pixels (18 bytes) by 6 lines: a blue frame, a white
fill, and the fill turns red below `HUD_HP_ALARM` (33%), which is the same
moment the figure turns red today. The caption stays a word in the chrome
ink. `wave_pct` and the Mothership's own percentage are already computed
every fourth frame; a bar is `fill = 70 * pct / 100` and one `scr_fill_rect`
per buffer when the byte changes, so the cost is the HUD's own dirty-flag
discipline and nothing per frame. `RU nnnn` and `M nn` fit after the two bars
(40 characters: 4 + 9 + 1 + 4 + 9 + 1 + 11 = 39) and come up here with them,
because the HUD's bottom half is now the buttons.

**Line 2 is the description**: when a button is selected — not pressed,
selected — its one-line description appears there **with its key in
parentheses after it** (*"μαζί με το πλήκτρο του σε παρένθεση"*), for **4
seconds** (200 ticks on `sys_tick_50hz`, the way the countdown counts), and
then clears. `CLOSE ON THE TARGET AND FIRE (A)`. The line is forty characters
and the captions are authored in `tools/hudicons.py` beside the pictures,
where `tests/test_hudicons.py` holds every one of them inside the forty, in
the font's own range, with the key on the end; `python3 tools/hudicons.py
list` prints them and `mockup` draws the screen with one up. A group has no
key and gets no parentheses. **When no description is up the line carries
the state** the old bar carried — `PAUSED`, the countdown, the build panel's
readout — in the inks it had. The words live in bank 7 with the rest of the
stopped-world text; bank 7 has four bytes free, so a table goes to bank 6
first (see the `bank7_data_end <= SPR_SCALE_ORG` assert).

**The playfield shrinks by ten lines** (20..167), and `PROJ_CENTRE_Y` moves to
`(CTX_BAR_H + HUD_TOP) / 2` = 94, which `src/main.asm` already asserts
against. The reticle, the scanner box, `MOTH_CENTRE_Y`, `JFX_TOP` and the
homeplanet's horizon all read the equates, and the tests that read the bar
back off the pixels (`tests/test_ctxbar.py`) read words today and must learn
bars.

## 5. The bottom strip — DECIDED IN OUTLINE

Lines 168..183 are the sixteen buttons; lines 184..199 are one text row.

**The squadron list is graphical.** `SQUADRONS` in the chrome ink, then
**nine marks**, one a squadron, a little vertical line each (2 × 7 pixels at
an 8-pixel pitch, 72 pixels for the nine): **blue for a squadron with ships
in it, white for an empty one, and RED for the selected one** — the owner's
assignment, written down here because it is the reverse of the palette's
usual "white is the thing" and must not be "corrected" — and after them **only the selected squadron's
number and its ship count**, in white: `2 15`. Nine counts of two digits
were 40 bytes of the old row; this is 9 + 1 + 9 + 4 characters' worth and
tells the player the two things they act on — which squadrons exist, and how
big the one they are about to order is. The marks are `scr_fill_rect`s from
`squad_count`, which is derived every frame already, so the row repaints on
the same `phase4_hud_changed` shadow it does now.

The rest of the row is the **yard's readout** (`>SCT 4`) and **`JUMP` /
`LAND`** at the right in the attention ink. `HULL`, `BASE`, `RU` and `M`
have gone up to line 1, and the **message row's word** (`INCOMING`, `YARD:
FRIGATE`, `AUTO RESPONSE ON`) goes to the top strip's line 2, where the
state lives when no description is up — it is news, and news is what that
line is for. Three rows' worth of text becomes one, so the strip's repaint
gets cheaper, not dearer.

## 6. Where the room is

The bar is bank-4 code by the narrow rule (it repaints only when the
selection moves, with the window at rest), and bank 4's window is at 24
bytes. The icons are 40 × 128 bytes = 5 KB of sprite data with no home:
bank 7 is full, banks 5 and 6 are full to the byte with the scaled blitter's
copies. The candidates, in the order to try them:

1. **A fourth track's worth of sectors is already read** — `LIB_SECTORS` 32
   fills the 16 KB window exactly, so no.
2. **Drop the scaled blitter's copy from ONE bank** and route that bank's
   scaled blits through another — costs a page flip per scaled sprite, only
   in the cockpit and at the innermost zooms.
3. **Icons as 1bpp masks** (one plane, 32 bytes each, 1.3 KB for forty) drawn
   through `txt_draw`'s pen machinery: white icons only, blue and red painted
   as a second overlay where an icon needs them. Cheapest by far, and the
   pictures above are mostly one ink.
4. **A ninth bank does not exist** on a 6128.

Option 3 is the one to measure first: it fits the low 16K's slack if the
draw code is bank 4 and the masks are bank 6 behind `bank6_copy`.
