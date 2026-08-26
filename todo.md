# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

*(Nothing outstanding. The three items that were here — the off-screen
Mothership indicator, splitting the fleet into squadrons by class, and
resources in every mission and visible — are done; see the marker pass in
CLAUDE.md.)*
## 1. RU reads as one byte and wraps at 256

**The resources are not lost** -- `eco_ru` is a word and every add is 16-bit.
Only the readout is wrong: `phase4_hud` does `ld a,(eco_ru)`, which takes the
low byte, into a three-digit field. At 300 RU the strip shows `044`.

The comment beside it says "RU never nears 65535", and that was true when the
only things to buy were 35 and 40. It stopped being true the moment all eight
classes landed: the Destroyer is **250**, so a player must save past 255 to
afford one -- and the counter reads zero exactly when they get there. The
assumption did not age; the feature that broke it is unrelated to it.

- `txt_draw_num` takes the value in `A`, so it is byte-only. This needs a
  16-bit form, or the value clamping at 999 with the reason written down.
- **There is no room on row A.** `RU ` starts at byte 56, three digits reach
  68, and `?HELP` runs 70 to 80 -- the last glyph starts at 78 of 80. A wider
  field means moving something, and item 2's context bar may be where the help
  hint should go anyway.
- Worth a test that spends past 255 and reads the screen back, not just the
  variable. Every economy test today asserts on `ECO_RU`, which is correct and
  says nothing about what the player can see.

## 2. Show that the game is paused

`SPACE` freezes the battle (`order_paused`) and nothing on screen says so. §9
calls it "τακτική παύση" and it is a state the player chooses and then forgets
they are in — the fleet simply stops obeying and looks broken.

- The HUD strip is the place. It already redraws only when it changes, and
  `phase4_hud_changed` compares counts against a shadow copy — the pause flag
  wants adding to that comparison, or the word will only appear when something
  else happens to change.
- Ink 3: §2 reserves it for attention, and this is the one thing a stuck-looking
  fleet needs explaining. `JUMP` already uses it.
- Row A's right-hand end is spoken for (`RU nnn ?HELP` reaches byte 78 of 80).
  Row B has `M n JUMP` from byte 56 and the yard at 44, so the left of row B or
  a shortened label is where the space is. Check what fits before choosing the
  word — the strip is 80 bytes and `txt_draw` clips rather than wraps.
- **Memory: bank 4 has 9 bytes free.** Even a seven-character string needs
  finding somewhere. CLAUDE.md's "Where the bytes came from" notes how the last
  two features found theirs.

## 3. A context bar along the top

A strip at the **top** of the screen showing which keys do something *right
now*. Starts `ESC FOR MENU`, and while any mode is open it shows that mode's
keys instead.

This is the answer to a real failure: a player who had been told the build
panel is `B` then `,`/`.` then `ENTER` asked twice how to choose what to build.
The yard's entire readout is a three-letter tag in the corner of the bottom
strip — no cost, no class name, and nothing to say `,`/`.` are live. Worse,
those three keys mean one thing with the panel open and another with it shut,
and the player cannot see which.

The contexts, which are already flags the game keeps:

| when | what it should offer |
|---|---|
| playing | `ESC` menu, and the handful worth naming |
| `disc_active` | arrows move, `SHIFT` height, `ENTER` confirm, `ESC` cancel |
| `eco_build_open` | `,` `.` choose, `ENTER` order — **and the cost** |
| `menu_shown` | up/down, `ENTER`, `ESC` |
| `mis_briefing`, `help_shown`, `title_shown` | their own prompt, which they draw themselves today |

Things that decide the shape:

- **The tactical view has no top clip.** `spr_clip_bottom` keeps ships out of
  the bottom strip and is what lets the HUD redraw only when it changes; there
  is no `spr_clip_top`, so a top strip needs the same treatment in `spr_blit`
  and in the dirty-rectangle erase, or ships will draw over it.
- **Redraw only when the context changes**, the way `phase4_hud_changed`
  compares against a shadow copy. The bar is static for seconds at a time and
  redrawing 40 characters every frame is not affordable.
- Item 1 (paused) belongs **in this bar**, not in the bottom strip: it is the
  same idea — the game telling the player what state it is in.
- **Memory is the blocker, not the code.** Six contexts of text is a few
  hundred bytes and bank 4 has nine. This one needs the space found first, and
  §14's mitigation (6 yaw views instead of 8, ~25% of a sprite library) is the
  only large reserve left.

## 4. Use the whole screen for the playfield

The tactical view does not fill the screen and at wide zoom it is not close.

`sx = 160 + ((x * recip[z]) >> PROJ_SHIFT)` with `recip[z] = PROJ_K / z` and
`PROJ_K = 160 << 7`, so the offset is `x * 160 / z`. `proj_deltas` clips `x` to
a signed byte, so:

| z | widest offset | screen used |
|---|---|---|
| 84 (`Z_NEAR`) | ±242 | all of it, and clipped |
| 250 (widest zoom) | ±81 | 162 px of 320 |

`PROJ_K` was chosen so that `x == z` — 45 degrees off axis — lands exactly on
the screen edge. Content never gets near 45 degrees at the wide steps, so half
the width is margin by construction. Vertically the same, against a playfield
that is only 168 lines to begin with and about to lose more to a top bar.

**The fix is a magnification between the perspective divide and the screen
clip**: multiply the offset by a per-zoom factor before adding 160. It is not
zoom — it shows the same world — it spreads that world across the screen it
has. Ships keep their size, because the size tier comes from `proj_z` and this
does not touch it.

- `proj_scale` (`src/math/proj.asm`) is already a branch-free shift ladder with
  its instructions patched per zoom step, and `order_apply_zoom` already LDIRs
  those patches out of a table. A magnify ladder is the same shape and should
  reuse it rather than grow a second one.
- It lands in `proj_point`, which is **~4,960 T-states an entity and the
  biggest single cost in the frame**. Two more shift ladders is real money;
  measure it against `PROJ_POINT_BUDGET_T` before committing to it.
- `tools/gentables.py` is the bit-exact reference model. Change the maths in
  one and not the other and the differential tests compare against the wrong
  answer.
- Do the vertical at the same time and against the *actual* playfield bounds,
  which are `spr_clip_top`..`spr_clip_bottom` once item 2 exists — otherwise
  this gets done twice.
