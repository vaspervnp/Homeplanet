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
