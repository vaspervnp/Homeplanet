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
squadron να ξεχωρίζει με κόκκινο."* *"Πήγαινε τη δεύτερη γραμμή του κάτω hud
με τα squadrons κλπ στη δεύτερη γραμμή του πάνω hud και τη δεύτερη γραμμή του
πάνω hud στο κάτω hud."*

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

## 2. What the arrows do — BUILT

> The cursor keys belong to the move disc, the pan, the cockpit and the build
> panel while one of those is open, and to the tutorial throughout. Otherwise
> they walk the button bar, and nothing else may take them.

"Absolute priority" means the bar is the DEFAULT owner rather than the
fallback. `order_update`'s chain is disc → pilot → pan → **orbit mode** →
nothing: orbiting the camera, which used to be what the arrows did when
nothing else had them, is a MODE now — the ORBIT button enters it, ENTER
leaves it, exactly as PAN is a mode — and `orbit_mode` (low 16K, beside
`pan_active`) is what `order_update` asks before it calls `order_camera`.
The tutorial keeps the old arrows outright, because its first lesson is that
they turn the view, and the bar is not drawn there.

LEFT and RIGHT move the frame along the row and wrap; ENTER presses the
button under it; ESC closes an open group, and opens the menu as it does now
when none is. **Every key still works.** A button PRESSES ITS KEY: the bar
plants the key's edge into `key_hits` the way the orders menu's `key_inject`
does, and `phase4_commands`, which runs straight after (the bar is hooked at
its top, one `CALL` in the low 16K), acts on it in the same frame. So the
bar is a second front end onto the commands and not a second copy of any of
them, and pressing `A` and pressing ATTACK are the same event by
construction. The ENTER that pressed the button is taken OUT of the frame's
snapshot first, or `order_update` would open the move disc on top of every
press; the ESC that closed a group likewise, or the menu would open.

## 3. The bar's layout — BUILT

Sixteen slots at a 20-pixel pitch (`BAR_X0` 1, `BAR_PITCH` 5 bytes):

```
MOVE DOCK FORM ATTACK GUARD MINE BUILD JUMP INFO PAUSE MENU | COMBAT+ ECONOMY+ SQUADRON+ CAMERA+ SYSTEM+
   COMBAT+   : BACK STRAFE FLY TARGET< TARGET>
   ECONOMY+  : BACK TOW REPAIR RECYCLE
   SQUADRON+ : BACK DIVIDE JOIN SPLIT SHIP< SHIP>
   CAMERA+   : BACK ZOOM+ ZOOM- ORBIT PAN CENTRE SENSORS
   SYSTEM+   : BACK HELP MUSIC
```

**MOVE is first, and the frame starts on it**, so ENTER with nothing
selected opens the move disc exactly as it always did: the key every player
has learned keeps working, and the bar is discovered from it rather than in
its way. Eleven direct buttons and five groups, and **a group opens as a SUB-BAR in
the same row** — BACK first, then its members, the frame landing on the
first member — rather than as a second row: one row is what the strip has
above the context line, and a sub-bar is the same thing to look at and to
walk. BACK or ESC closes it and puts the frame back on the group's button.
`JUMP` wears `LAND` on the last mission, as the HUD's word does; the key is
`J` either way. The groups are the last five slots in the order of their
icons, so a group's slot is arithmetic and `bar_close` needs no table.

**It runs from bank 6.** The bar wanted ~300 bytes of code and ~600 of
words; bank 4 had 111 to its window, the low 16K 31 to its page, bank 7
four. Bank 6 had a thousand, and the chase had set the precedent for CODE in
a sprite bank. `game/hudbar.asm` is assembled into bank 6 after the tune's
streams, runs with the window at rest from two bank-4 call sites through
**`bankn_call`** (`sys/libload.asm`: `A` = bank, `IX` = routine, and
`bank_home` says which bank `bankn_copy` should page BACK to — so bank-6
code can copy the icons in from bank 5 and still be there when the copy
returns), and calls nothing but the low 16K. It carries its own copies of
`key_inject`'s and `key_clear`'s bit arithmetic, because those are bank 4.
An icon comes down in two halves of thirty-two through `bank7_line`, the one
RAM outside the window, and goes on a row at a time. The state is in bank 6
with the code, like the chase's; tests read it with `harness.read_bank`,
which parks the machine in `scr_wait_vsync`, copies the bytes down and jumps
back in. `tests/test_hudbar.py` reads the row and the frame off the pixels.

**A key that is a visible button selects it** (*"όταν πατάω ένα πλήκτρο που
αντιστοιχεί σε ορατό κουμπί, να επιλέγεται το κουμπί και να εκτελείται η
εντολή"*): `bar_update` scans the row showing for a key hit this frame and
moves the frame onto that button — its caption comes up — leaving the key in
the snapshot so the command runs as it always did. ENTER is skipped (it is
the bar's own press and MOVE's key), and a key whose button is inside a
closed group moves nothing. **The arrows walk the bar with the build panel
open too** (*"τα βελάκια δεξιά αριστερά και η επιλογή κουμπιών να έχουν
απόλυτη προτεραιότητα"*); ENTER and ESC stay the panel's there. The move
disc, the pan and the cockpit keep the arrows, because for them the arrows
are the tool itself.

**Each mark carries its number** (*"οι γραμμές των squadron να έχουν μέσα
τον αριθμό με μαύρο από 1 ως 9, με μισού πλάτους γράμματα"*): a 4×7 digit
font in `game/hudmarks.asm` (`hud_digits`, one nibble a row), cut out of the
mark's byte in black — both planes cleared where the digit is set, which is
the whole font engine. The marks and their alarm run from **bank 5**, like
`txt_big`; the room is the icons', stored as fourteen rows now because a
cell's top and bottom rows are the frame's blank margin by the sheet's own
rule (296 bytes back).

**The squadron under attack blinks** (*"να αναβοσβήνει η γραμμή του
squadron που δέχεται επίθεση"*): `cbt_retaliate`, which every hit already
reaches, flags the target's squadron in `hud_alarm` (a byte a squadron, low
16K) and restarts `hud_alarm_left`; while that runs, `hud_alarm_frame` (from
`wave_draw`) redraws the nine marks into the back buffer every frame with
the tick's phase — bit 4 of `sys_tick_50hz`, sixteen ticks on, sixteen off
— blanking the flagged ones on the off phase, and when it runs out clears
the flags and marks the strip dirty so both buffers settle. `hud_marks` (bank
4, in `game/wavesdraw.asm`) is the marks' one loop, called by `hud_draw` with
the phase on. The room: `txt_big` runs from bank 5 now (the ORBIT icon left
the bank to make its 112 bytes), the title's ship table is in bank 6 and
comes down into `bank7_line` each title frame, `bank6_call` shares the
trampoline's bank byte, and the hit's arithmetic is computed once for the
alarm and the auto response.

**The joystick walks it too** (*"τα κουμπιά να επιλέγονται και με
joystick"*): joystick 1 is row 9 of the matrix, which `key_scan` reads with
the rest, so the stick's left and right are two more key ids beside the
arrows' and fire one beside ENTER (`KEY_JOY_*` in `game/hudbar.asm`).

**The tutorial plays by the same rules** (*"φτιάξε και το tutorial να
λαμβάνει υπόψη του τις αλλαγές"*): the bar is drawn and live on the stage,
`tut_enter` puts it at rest (frame on MOVE, no group) through `bar_reset`,
step 1 says `SHIFT+ARROWS TURN THE VIEW`, and a new step 2 — `ARROWS WALK THE
BUTTONS BELOW`, gated on the bar's own "a description is up" —
makes nineteen steps. Bank 7 had 42 bytes and the two lines took 36.

**Modal buttons stay modal.** `, .` are on the COMBAT group as TARGET< and
TARGET>; with the build panel open the panel has ENTER and `,` `.`, and the
bar stands aside until it closes.

## 4. The top strip: two lines — BUILT

`CTX_BAR_H` is **20**, two text rows (`CTX_Y` 1, `CTX_Y2` 11), and **the
context bar's key list is gone from it**: the buttons are what will say
which keys are live, so `ESC MENU ENTER MOVE B BUILD A ATTACK` has no job
left and ordinary play draws nothing on the context line at all. What the
old bar said that was not a key list — `PAUSED`, `JUMPING nn ESC CANCEL`,
`RECYCLE?`, the move disc's and the cockpit's lines, the build panel's class
and price and its `ENTER BUY` / `NEED MORE RU` — is STATE, and it moved with
`ctx_bar` to the bottom strip's text line (§5).

**`game/huddraw.asm` draws the strip**, and it is `phase4_hud` reshaped:
the same shadow compare (`phase4_hud_changed`), the same dirty counter, the
same state in `demo/phase4.asm`, and a whole-strip blank followed by
everything but the bars. It was written for bank 4 by the narrow rule and
**lives in the low 16K by arithmetic**: bank 4 was 24 bytes from its window
and this is four hundred, while removing the old `phase4_hud` — nine
`>n:cc` slots and their row walker — had just given the low 16K two pages
back. Low 16K `free:` 402 after, hand-written code at `#25E1`; bank 4
**139**, up from 24.

**Line 1 is the fleet's health, as bars.** `HULL` and `BASE` are captions in
the chrome ink on two **bars**, 18 bytes by 6 lines (`HUD_BAR_*`): a blue
trough (`SOLID_INK_2`) with the inner four lines overwritten from the left
in white for `(pct × 46 + 128) >> 8` bytes — `pct × 18 / 100` rounded, one
`mul_u8` and no divide, 0 at 0 and 18 at 100 — and in **red below
`HUD_HP_ALARM`**, the same third at which the old figure turned. `hud_bar`
is bank 4, in `game/wavesdraw.asm`, and `wave_draw` draws exactly the two
bars on `wave_dirty`: the hull moves every time a shot lands, so the bars
keep the flag the figures had, and `hud_draw` sets it whenever it has
blanked the strip under them. `RU nnnn` and `M nn` follow at bytes 56 and
72; the mission number keeps its two right-aligned digits.

**Line 2 is the squadrons.** `SQUADRONS`, then **nine marks** — one byte by
seven lines at a two-byte pitch, `scr_fill_rect`s from `squad_count` — blue
with ships, white empty, **red for the selected one** (the owner's
assignment, and the reverse of "white is the thing": leave it), then the
selected squadron's number and its count (`2 15`) and nothing for the others,
the yard's five-character readout at byte 50, and `JUMP` / `LAND` at byte 72
in the attention ink, through `mis_leave_word` as before. With the base
selected (`0`) there is no number and no count. **The tutorial owns this
line** while it runs: `tut_draw` is reached from `wave_draw` on the same
flag, blanks the line and draws its instruction there, and `hud_draw` leaves
line 2 alone while `tut_active` is set. What the tutorial gives up is the
marks; the HULL and BASE bars stay.

**The playfield is 20..167** and `PROJ_CENTRE_Y` is **94**, in
`src/equ/memmap.asm` and `tools/gentables.py` both, asserted equal and equal
to `(CTX_BAR_H + HUD_TOP) / 2`. Everything that reads the equates followed —
the jump wipe, the Mothership marker's band, the horizon's asserts, the
reticle and the scanner. `MG_TEXT_Y` moved 16 → 20 to clear the strip. The
mission field, the way-out word, the message's ink and every reader of the
old rows in the tests read the new symbols now; `test_ctxbar` grew a
`TestTheFleetStrip` that reads both lines and both bars back off the pixels,
because every readout bug this project has had passed on the variables.

## 5. The bottom strip — the context line BUILT, the buttons TO BUILD

Lines 168..183 (`HUD_BTN_Y`, `HUD_BTN_H`) are the sixteen buttons, black
until the bar lands; line 190 (`HUD_TEXT_Y`, `CTX_LINE_Y`) is the **context
line**, which is `ctx_bar` moved down whole: `PAUSED SPACE RESUME ESC MENU`,
`JUMPING nn ESC CANCEL`, `RECYCLE? Y CONFIRM ESC CANCEL`, the disc's
`ARROWS MOVE SHIFT HEIGHT ENTER OK ESC`, the cockpit's `ARROWS FLY SPACE
FIRE V BACK`, the build panel's `SCOUT 25 RU , . PICK ENTER BUY`, with the
inks they had. **The message row's word came here too** — `INCOMING`,
`YARD: FRIGATE`, `AUTO RESPONSE ON` — drawn by `ctx_draw_message` while
PLAYING (and while flying, where it outranks the cockpit's key line for its
few seconds): `ctx_classify` folds `wave_saying` into `ctx_sub`, so the
shadow repaints on the word's two transitions and not on its countdown, and
`wave_changed` no longer compares it. A state outranks the message: `PAUSED`
over `INCOMING`, as the old bar's contexts outranked each other.

**The description is BUILT.** When the frame moves, `bar_show` notes the
tick and `bar_desc_state` answers `ctx_classify`'s question every frame:
while `sys_tick_50hz − bar_tick < 200` (four seconds) and no state or
message outranks it, the context is `CTX_DESC` with the icon in `ctx_sub`,
and `ctx_draw_desc` has `bar_caption` build the line — the description from
`gen/hudcaptions.asm` (`tools/hudicons.py import` writes it beside the icons:
descriptions, keys, key names) and the key in parentheses after it — into
`bank7_line` and draws it white. The descriptions were shortened to fit a
forty-character line with ` (ARROWS)` on the end and bank 6's room:
`PAUSE THE BATTLE (SPACE)`, `TURN THE VIEW (ARROWS)`.

## 6. Where the room is — DONE: bank 5

The icons are **2560 bytes** — forty of them at 64: sixteen rows of four
Mode 1 bytes, encoded by `rt2sprite.encode_mode1_byte` exactly as a sprite's
data is, and **no mask**, because a button is drawn onto the black of the
HUD's strip. `tools/hudicons.py import` writes `src/gen/hudicons.asm` off the
PNG (the Makefile runs it when the PNG or the tool changes), with `hud_icons`
and an `ICON_<NAME>` index per icon, and `src/main.asm` includes it in
**bank 5**.

**Bank 5 was the one bank with room, and the room was already being read.**
Banks 5, 6 and 7 all print 16378 of 16384 because the scaled blitter's copy
sits at `SPR_SCALE_ORG` (`#7D64`) and ends at the top; what that figure
hides is the gap between each bank's DATA and that origin. Bank 7's data
ended at `#7D60`, four bytes short; bank 6's at `#7948`, 1052 bytes; bank
5's — three libraries and nothing else — at `#72A0`, **2756 bytes** that
`lib_load` reads off the disc every boot and nothing ever looked at. Lever 1
of CLAUDE.md's four, exactly. It ends at `#7CA0` now, **196 bytes** before
the blitter, and the existing `bank5_data_end <= SPR_SCALE_ORG` assert is
the guard; the build prints the figure.

**How the bar will read them.** An icon is drawn with the window at rest
(the bar repaints only when the selection moves), so the draw code is bank 4
and the icon comes down through `bankn_copy` with `A = GA_BANK_5` — 64
bytes into the save block's pad, which has 135 bytes left after
`fleet_pad_end` — and is written into both buffers' strips from there: four
bytes a row, sixteen rows, `TXT_ROW_STRIDE` apart, no mask and no shift,
because the buttons sit on byte columns (x = 4 + 20·i is byte 5·i + 1). The
two frame cells overlay an icon the same way, pen 0 skipped. Nothing new in
the low 16K, which is at its page edge.

`tests/test_hudicons.TestTheIconsAreInBank5` reads `build/bank5.raw` at the
symbol file's `HUD_ICONS` and compares every icon with the sheet encoded in
Python; `test_shipclass`'s content test already says the machine's bank 5 is
`bank5.raw`.

The other candidates, kept for the day 196 bytes is not enough:

1. **Drop the scaled blitter's copy from ONE bank** and route that bank's
   scaled blits through another — costs a page flip per scaled sprite, only
   in the cockpit and at the innermost zooms. About 660 bytes.
2. **Bank 6** has 1052 spare, for the words and tables the bar will want.
3. **A ninth bank does not exist** on a 6128.
