# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

## 1. Off-screen Mothership indicator

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

## 2. Split the whole fleet into squadrons by class

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

## 3. Resources in every mission, and visible

Two halves:

- **Every mission fields resource patches.** Today it is per-mission data:
  `MIS_PATCH_COUNT` and `MIS_PATCH_PTR` in the descriptor, laid out in
  `src/game/campaign.asm`, and some missions field none. §7's economy is meant
  to be a running choice, not something that appears in a few missions.
- **They can be seen.** Draw each patch as a **dot in the tactical view** and
  again in the sensor view — a handful, not a field. Two colours.

Notes for whoever does it:

- The grid at Y=0 (`src/gfx/grid.asm`) is the precedent: a small cached set of
  points, reprojected only when a camera hash changes, each recording its own
  dirty rectangle. A patch is a world point that does not move, so it is the
  same problem and should reuse the same shape rather than invent a second one.
- **Which two colours is a real decision, not a detail.** The palette is
  semantic (§2) and there are only three inks: 1 is friendly and text, 2 is
  stars and the grid, 3 is enemies and alarms. Spending 3 on resources would
  make a rich patch look like a hostile. The obvious reading is ink 2 for a
  patch with stock and ink 1 for one nearly exhausted — colour carrying the
  thing the player actually needs to know, since `eco_patches` already tracks a
  stock that runs down. Decide it deliberately and write down why.
- The sensor view already draws entities as dots; patches want to go in the
  same pass so they share its cost and its erase.
- Patches are static, so their projection can be cached exactly like the grid's
  — this should cost almost nothing per frame, and if it does not, that is the
  sign it has been built the wrong way.
