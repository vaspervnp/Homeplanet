# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

*(Nothing outstanding.)*

*(The two items that were here — showing that the game is paused, and a
context bar along the top — were one job and are done together. See "The
context bar" in CLAUDE.md for what it shows, how `spr_clip_top` was threaded
through the blitter, `gfx_vline` and `mark_store`, and the page-flip bug it
turned up.)*

*(The third — using the whole screen for the playfield — is done. See "Using
the width of the screen" in CLAUDE.md: `proj_mag`, six patched bytes carried
in the zoom record, and the eleven lines the projection had been low ever
since the context bar arrived. It came out ~100 T-states an entity CHEAPER
than what it replaced, and the note that item carried about mission 8 has its
answer: the frame time came back and the campaign did not change at all.)*

*(The fourth — "selecting squadrons mixes them up" — is fixed. It was not the
selection and it was not the membership: `squad_dest` gave a newly created
squadron a FIXED station out of `order_home`, up to 6000 units from where its
ships actually were, so dividing a formation flung half of it off the screen.
See "A squadron is born where its ships are" in CLAUDE.md for the rule, and
for why every existing squadron test — all of which counted — agreed with the
bug.)*

*(The fifth — attack waves after three minutes, random in number, strength and
spacing, and a fleet-health percentage on screen — is done. See "Attack waves,
and the price of staying" in CLAUDE.md for the scaling rule (hull, not
headcount), the measured win rate, and the three design decisions; and "The
fleet's hull, on the screen" for the third HUD row and the only division in
the game. `tools/waverate.py` is the measuring stick.)*

## An attacking ship never comes home

Found by `tools/waverate.py` and deliberately not fixed there, because it is
not about the waves.

`phase4_fly` skips a ship whose `ENT_ORDER` is `ENT_ORDER_ATTACK` — correctly,
so `cbt_move_enemies` can close it on its target without the two systems
cancelling by stepping it `PHASE4_STEP` in opposite directions. But **nothing
clears the order when the target dies.** So after any fight the fleet sits
wherever the last enemy was, forever, and `fleet_save` carries those
coordinates into the next mission.

It has always been true and the waves only made it visible: loiter through
three waves in mission 4 and the fleet begins mission 5 scattered six thousand
units from the Mothership, which is alone at the origin when THE NEBULA's eight
hostiles spawn on top of it. Measured: the campaign died at mission 5 in six
runs out of six, at full hull, with no wave on the screen.

`G` is the workaround and a player has to know to press it. The fix is in
`cbt_fire_if_able`, where the target is already found to be wreckage: if the
re-acquire comes back with `ENT_NO_TARGET` there is nothing left to attack, and
the order could drop to `ENT_ORDER_GUARD` there — which is what "the fight is
over" means. Check what `cbt_retarget_one` does with GUARD first; it also
returns early for it, for the same "not the AI's to overwrite" reason.

*(Zoom on `+` and `-` is done. `-` is a key of its own; `+` is not a key at
all -- it is SHIFT + `;`, and the matrix reports only the physical key, so
KEY_PLUS is the `;` position. Same trick as KEY_SLASH for `?`.)*
