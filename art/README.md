# art/

The ships' source art. `*.retrotools.json` are RetroTools projects rendered by
`tools/mkships.py` from the 3D models (`make ships`) and retouched by hand;
`tools/rt2sprite.py` turns them into `src/gen/spr_*.asm` at build time.

## The sprite map

`spritemap.png` is every sprite on one PNG: a row per class in the game's
order (interceptor, mothership, harvester, scout, bomber, frigate, salvage,
destroyer), the three tiers A 8×6, B 16×10, C 24×16 left to right, six yaw
views each, view 0 nose-on. `homeplanet.gpl` is its palette for GIMP 3 — the
four inks plus **magenta for NOT DRAWN**, which is the mask; black is pen 0,
drawn. Paint in indexed mode with that palette, keep the grid where it is,
and `make` picks the map up (`tools/spritemap.py import`).

`python3 tools/spritemap.py export` regenerates it from the projects; delete
it to build from the projects again. `tests/test_ships.py` proves the two
routes give the same bytes.
