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

*(The sixth — "an attacking ship never comes home" — is fixed.
`cbt_fire_if_able` spends the order the moment its re-acquire comes back
`ENT_NO_TARGET`, dropping it to `ENT_ORDER_IDLE` and not to `ENT_ORDER_GUARD`
as this entry proposed: `cbt_retarget_one` returns early for GUARD, so a ship
put there would keep whatever target it picked up next and never be re-pointed
at a nearer one. See "An attack order has to be spent, and for a long time
nothing spent it" in CLAUDE.md for why the clear is guarded on ATTACK — a
harvester reaches the same line — and for the one swing in `tools/balance.py`
that has ever survived its own control.)*

*(Zoom on `+` and `-` is done. `-` is a key of its own; `+` is not a key at
all -- it is SHIFT + `;`, and the matrix reports only the physical key, so
KEY_PLUS is the `;` position. Same trick as KEY_SLASH for `?`.)*
