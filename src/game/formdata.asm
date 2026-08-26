; ============================================================================
;  game/formdata.asm -- the four formation lattices. In bank 4.
; ============================================================================
;  Sixteen slots a formation, six bytes each: the offset from the squadron's
;  station. game/formation.asm has the code that reads them and the reason
;  they live over here rather than in the low 16K with it.
; ----------------------------------------------------------------------------

; ============================================================================
;  The shapes
; ============================================================================
;  Everything below is in world units, and world units got four times smaller
;  when WORLD_SHIFT went from 8 to 6 -- so every figure here is a quarter of
;  what it was, and a formation is exactly the same size on screen. See the
;  note in src/math/proj.asm.
FORM_SPACING        equ 550

;  --- Loose: a flat 4 x 4 lattice on the squadron's own XZ plane -----------
;  The default. Spread out, nothing clever, easy to read at a glance.
form_offsets:
loz = 0
    repeat 4
lox = 0
        repeat 4
            defw (lox * 2 - 3) * FORM_SPACING
            defw 0
            defw (loz * 2 - 3) * FORM_SPACING
lox = lox + 1
        rend
loz = loz + 1
    rend

;  --- Wedge: an arrowhead, point forward ----------------------------------
;  Slot 0 leads; the rest fall back in widening pairs. Two ranks, so a
;  sixteen-ship squadron still looks like one arrow rather than a queue.
    defw      0, 0,  1100
    defw   -550, 0,   550
    defw    550, 0,   550
    defw  -1100, 0,     0
    defw   1100, 0,     0
    defw  -1650, 0,  -550
    defw   1650, 0,  -550
    defw  -2200, 0, -1100
    defw   2200, 0, -1100
    defw      0, 0,     0
    defw   -550, 0,  -550
    defw    550, 0,  -550
    defw  -1100, 0, -1100
    defw   1100, 0, -1100
    defw  -1650, 0, -1650
    defw   1650, 0, -1650

;  --- Sphere: a shell around the station ----------------------------------
;  Two rings of six at different heights plus one above and one below. The
;  point is that nothing is in anybody's line of fire, which matters once
;  there is fire.
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

;  --- Wall: a 4 x 4 sheet standing upright --------------------------------
;  Flat in XY with no depth, so the squadron presents its whole broadside at
;  once. The counterpart to the wedge.
way = 0
    repeat 4
wax = 0
        repeat 4
            defw (wax * 2 - 3) * FORM_SPACING
            defw (way * 2 - 3) * FORM_SPACING
            defw 0
wax = wax + 1
        rend
way = way + 1
    rend
form_offsets_end:

