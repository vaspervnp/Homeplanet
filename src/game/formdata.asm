; ============================================================================
;  game/formdata.asm -- the four formation shapes. In bank 4.
; ============================================================================
;  Sixteen slots a formation: the offset from the squadron's station.
;  game/formation.asm has the code that reads them and the reason they live
;  over here rather than in the low 16K with it.
;
;  This used to be 384 bytes -- four formations, sixteen slots, six bytes each,
;  written out. Half of it was the same four numbers over and over, and a third
;  of the rest was a structural zero:
;
;      Loose and Wall are the SAME 4 x 4 lattice. One lies flat in XZ and the
;      other stands upright in XY, and that is the whole difference between
;      them -- so between them they are four numbers, not 192 bytes.
;
;      Wedge is flat too, so its Y is zero in all sixteen slots.
;
;      Sphere is the only one that is genuinely three-dimensional, and it is
;      the only one still written out in full.
;
;  Same find as class_tiers (192 -> 66) and tier_lut (256 -> 0): a table earns
;  its bytes when it holds numbers you could not have worked out, and these
;  mostly did not.
; ----------------------------------------------------------------------------

; ============================================================================
;  The shapes
; ============================================================================
;  Everything below is in world units, and world units got four times smaller
;  when WORLD_SHIFT went from 8 to 6 -- so every figure here is a quarter of
;  what it was, and a formation is exactly the same size on screen. See the
;  note in src/math/proj.asm.
FORM_SPACING        equ 550

;  --- how far the four LAYERS of every shape stand off each other ---------
;  A squadron bigger than sixteen repeats its shape rather than stacking ships
;  on one point; see FORM_LAYERS in game/formation.asm. Alternating about zero
;  so the station stays in the middle of the squadron. Two spacings apart,
;  which is far enough that two layers of a Loose lattice do not interleave and
;  near enough that a squadron still reads as one thing.
form_layer_off:
    defw  0
    defw  2 * FORM_SPACING
    defw -2 * FORM_SPACING
    defw  4 * FORM_SPACING

;  --- Loose and Wall: a 4 x 4 lattice ------------------------------------
;  Slot n takes column n AND 3 on one axis and row n >> 2 on the other. Loose
;  is the default: spread out, nothing clever, easy to read at a glance. Wall
;  is the same sheet stood on end, so the squadron presents its whole
;  broadside at once -- the counterpart to the wedge.
form_grid:
    defw -3 * FORM_SPACING
    defw -1 * FORM_SPACING
    defw  1 * FORM_SPACING
    defw  3 * FORM_SPACING

;  --- Wedge: an arrowhead, point forward ----------------------------------
;  Slot 0 leads; the rest fall back in widening pairs. Two ranks, so a
;  sixteen-ship squadron still looks like one arrow rather than a queue.
;  Flat, so only x and z are stored.
form_arrow:
    defw      0,  1100
    defw   -550,   550
    defw    550,   550
    defw  -1100,     0
    defw   1100,     0
    defw  -1650,  -550
    defw   1650,  -550
    defw  -2200, -1100
    defw   2200, -1100
    defw      0,     0
    defw   -550,  -550
    defw    550,  -550
    defw  -1100, -1100
    defw   1100, -1100
    defw  -1650, -1650
    defw   1650, -1650

;  --- Sphere: a shell around the station ----------------------------------
;  Two rings of six at different heights plus one above and one below. The
;  point is that nothing is in anybody's line of fire, which matters once
;  there is fire. The only shape here with three real axes.
form_shell:
    defw      0,   900,      0
    defw      0,  -900,      0
    defw    800,   350,      0
    defw    400,   350,    700
    defw   -400,   350,    700
    defw   -800,   350,      0
    defw   -400,   350,   -700
    defw    400,   350,   -700
    defw    800,  -350,      0
    defw    400,  -350,    700
    defw   -400,  -350,    700
    defw   -800,  -350,      0
    defw   -400,  -350,   -700
    defw    400,  -350,   -700
    defw    600,     0,    350
    defw   -600,     0,   -350
form_shell_end:
