# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

## 1. More zoom levels

At least **four more steps out and four more in**, reusing the sprite tiers
there already are — the ships stay the same small or large sizes, only the
camera distance changes.

Today `cam_zoom_dist` in `src/math/cam.asm` is four distances (110, 150, 200,
250) and `CAM_ZOOM_STEPS` is 4. Widening the table is the easy half.

Things to check when doing it:

- `Z_NEAR` is 84 and `proj_z` must stay inside a byte, so there is a floor on
  how close the camera may come before the perspective divide runs out of
  range. `tools/gentables.py` explains where 84 comes from.
- Zooming *out* pushes entities past the tier thresholds in `tier_lut`, so far
  ships fall to tier A and the whole fleet becomes 8×6 specks. That is item 3
  below, and the two want doing together.
- The world is now ±512 camera units per axis, but `proj_deltas` clips anything
  more than 8191 world units off the focus. A very wide zoom will show a lot of
  empty space rather than more ships unless that limit moves too — and it
  cannot move far, because `proj_v16` has to stay in a signed byte.

## 2. Off-screen Mothership indicator

When the Mothership is not on screen, draw a **blue marker at the edge of the
view** showing its bearing, and its height relative to the camera.

- Ink 2 by the semantic palette (§2): it is a navigation aid, not an alarm.
- `proj_point` already returns CF clear for anything clipped, so "is it off
  screen" is free — what is missing is *which way*, which means keeping the
  rotated camera-space vector instead of throwing it away on the clip path.
- Height wants the same vertical-line idiom the move disc uses
  (`order_draw_disc`), so the two read as the same language.
- The marker must record a dirty rectangle or it will smear; see the note on
  the briefing and help pages, which learned that the hard way.

## 3. Consolidate overlapping distant ships

At wide zoom, ships that land on top of each other should draw as **one sprite
with a small `+` beside it**, one group per class.

- Grouping is per class, so the counts go beside the tier-A sprite the group
  collapses to.
- `phase4_sort` already builds a z-ordered list every frame; the grouping pass
  wants to run over that, after projection and before drawing.
- Watch the frame budget: the sort is already O(n²) and 73,000 T-states (see
  the measured table in CLAUDE.md). A grouping pass that is also O(n²) doubles
  the worst case. Screen-space bucketing is likely cheaper than comparing every
  pair.
- This is what makes item 1's wider zoom-out legible rather than a field of
  identical dots.

## 4. Split the whole fleet into squadrons by class

One command that takes every ship and reassigns it so each **class gets its own
squadron**.

- `squad_count` is derived by recounting the entity table, never maintained
  incrementally — so this only has to write `ENT_SQUAD` and call
  `squad_refresh`. Everything else follows.
- Nine squadrons, eight classes: it fits, but decide what happens when a class
  has no ships (leave the number unused rather than shuffling, or the numbers
  move under the player's fingers between missions).
- Belongs in the orders menu as well as on a key. The menu injects key ids
  rather than calling commands, so it is one row in `menutext.asm` once the key
  exists.
