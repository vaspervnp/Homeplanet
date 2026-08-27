# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

*(The two items that were here — showing that the game is paused, and a
context bar along the top — were one job and are done together. See "The
context bar" in CLAUDE.md for what it shows, how `spr_clip_top` was threaded
through the blitter, `gfx_vline` and `mark_store`, and the page-flip bug it
turned up.)*

## 1. Use the whole screen for the playfield

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
that is now **158 lines** — `spr_clip_top` (10) to `spr_clip_bottom` (168).

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
- **Do the vertical against the actual playfield bounds, which now exist.**
  The projection still centres on y=100 while the visible band runs 10..167,
  whose middle is 89. That is eleven lines of bias and it is cheaper to fix
  here, once, than to leave for a third pass.
- **This is also where the frame time to pay for the context bar would come
  from, if anyone wants mission 8 back.** See the balance table under "A fleet
  has to be able to concentrate": the campaign ending at 7 rather than 8 is
  2,500 T-states, not a balance change.

## Squadron numbers get mixed up after `d` / `m` / `n` / `c`

Reported from play: selecting squadrons "mixes them up", and the player
narrowed it to **after the reshaping commands** — divide, move one forward,
move one back, combine. Not after `1`-`9` on their own, and not after `O`.

**Three obvious causes are already ruled out** — do not spend the afternoon on
them again:

- **The digit mapping is right.** `key_digit_ids` was checked entry by entry
  against the hardware matrix: rows 8, 7, 6, 5, 4 with the odd/even pairs the
  right way round. This is the trap CLAUDE.md documents and it is not this.
- **The HUD lists squadrons by NUMBER, not by position.** `phase4_hud_row`
  walks 1..5 then 6..9 and prints each number with its count, blank if empty,
  so what sits in the third slot really is squadron 3. The display and the keys
  cannot disagree about which is which.
- **The derived counts are not stale.** All four commands end in
  `jp squad_refresh`, which recounts the whole entity table, so
  `squad_find_free` is never reading yesterday's `squad_count`.

Where to look next:

- `squad_move_ship` (`src/game/squadcmd.asm`) moves the FIRST active entity
  whose `ENT_SQUAD` matches — it has no notion of which ship, so repeated
  moves can walk the same ship back and forth, and `d` peels from the low slot
  numbers every time. Worth checking what a divide-then-divide actually leaves.
- `squad_find_free` searches upward *from the selection* and wraps. Combined
  with `O`'s class-based numbering, which leaves deliberate gaps, "the next
  free number" and "the number the player expects" may simply differ.
- `squad_refresh` also moves the SELECTION if the selected squadron emptied.
  A command that empties the selection and then reports through a HUD keyed on
  the new selection would look exactly like the numbers jumping about.
- Reproduce it as a test first: press the real keys in the emulator and assert
  on `ENT_SQUAD` across all 48 slots after each command, not just on
  `SQUAD_COUNT`. Every squadron test today checks counts, and counts are
  preserved by a swap that puts the wrong ships in the wrong places.
