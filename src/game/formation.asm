; ============================================================================
;  game/formation.asm -- the four squadron formations (Homeplanet.md section 9)
; ============================================================================
;      F   cycles Loose -> Wedge -> Sphere -> Wall
;
;  A formation is nothing but a table of sixteen offsets from the squadron's
;  station. Ships take slots in order, so changing formation changes every
;  ship's destination at once and the squadron visibly reshapes itself -- the
;  same mechanism as a move order, applied to the offsets instead of the
;  centre.
;
;  Each squadron keeps its own formation. Splitting a squadron gives the new
;  half the same shape, which is what you would expect of ships peeling off
;  in formation.
; ----------------------------------------------------------------------------

FORM_LOOSE          equ 0
FORM_WEDGE          equ 1
FORM_SPHERE         equ 2
FORM_WALL           equ 3
FORM_COUNT          equ 4

FORM_SLOTS          equ 16
FORM_SLOT_MASK      equ FORM_SLOTS - 1
FORM_STRIDE         equ FORM_SLOTS * 6


; ----------------------------------------------------------------------------
;  form_init -- everyone starts loose
;  Uses: AF, B, HL
; ----------------------------------------------------------------------------
form_init:
    ld hl,squad_form
    ld b,SQUAD_MAX + 1
    ld a,FORM_LOOSE
@form_zero:
    ld (hl),a
    inc hl
    djnz @form_zero
    ret


; ----------------------------------------------------------------------------
;  form_cycle -- the F key: next formation for the selected squadron
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
form_cycle:
    ld a,(squad_sel)
    ld l,a
    ld h,0
    ld de,squad_form
    add hl,de
    ld a,(hl)
    inc a
    cp FORM_COUNT
    jr c,@form_store
    xor a
@form_store:
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  form_slot_addr -- the offset for slot C of the formation squadron B is in
;  In : B = squadron 1..9, C = slot number
;  Out: HL -> three words of offset
;  Uses: everything
; ----------------------------------------------------------------------------
form_slot_addr:
    ld a,b
    ld l,a
    ld h,0
    ld de,squad_form
    add hl,de
    ld a,(hl)                           ; which formation

    ;  FORM_STRIDE is 96 = 64 + 32.
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                           ; formation * 32
    ld d,h
    ld e,l
    add hl,hl                           ; * 64
    add hl,de                           ; * 96

    ld a,c
    and FORM_SLOT_MASK                  ; more ships than slots: share them
    push hl
    call phase4_times6
    pop de
    add hl,de
    ld de,form_offsets
    add hl,de
    ret


; ============================================================================
;  State
; ============================================================================
;  Index 0 is unused so a squadron number indexes directly.
squad_form:         defs SQUAD_MAX + 1, 0


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

    assert (form_offsets_end - form_offsets) == FORM_COUNT * FORM_STRIDE, "a formation is not 16 slots"
