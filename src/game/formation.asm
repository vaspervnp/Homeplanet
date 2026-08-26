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
;  form_slot_offset -- the offset for slot C of the formation squadron B is in
;  In : B = squadron 1..9, C = slot number
;  Out: HL -> three words of offset
;  Uses: everything
;
;  It BUILDS the three words rather than pointing at them, because three of the
;  four formations are not written out any more -- see game/formdata.asm. The
;  cost is a six-byte copy per ship per frame against a pointer, which is about
;  fifty T-states; what it buys is 216 bytes of bank 4, and the Mothership
;  indicator is made out of them.
; ----------------------------------------------------------------------------
form_slot_offset:
    ld a,b
    ld l,a
    ld h,0
    ld de,squad_form
    add hl,de
    ld a,(hl)                           ; which formation
    ld (form_which),a

    ld a,c
    and FORM_SLOT_MASK                  ; more ships than slots: share them
    ld (form_slot),a

    ld a,(form_which)
    cp FORM_SPHERE
    jr nz,@form_flat

    ;  The one shape with three real axes, and the only one still stored.
    ld a,(form_slot)
    call phase4_times6
    ld de,form_shell
    add hl,de
    ret

@form_flat:
    ;  The other three are flat, so two words say all of it. Wedge reads its
    ;  pair out of a table; Loose and Wall derive theirs from the same 4 x 4
    ;  lattice, column in one axis and row in the other.
    ld hl,0
    ld (form_off + 2),hl                ; the zero axis, until Wall moves it
    cp FORM_WEDGE
    jr nz,@form_grid_shape

    ld a,(form_slot)
    add a,a
    add a,a                             ; four bytes a pair
    ld l,a
    ld h,0
    ld de,form_arrow
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (form_off + 0),de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (form_off + 4),de
    ld hl,form_off
    ret

@form_grid_shape:
    ld a,(form_slot)
    and 3
    call form_grid_at
    ld (form_off + 0),de

    ld a,(form_slot)
    rrca
    rrca
    and 3
    call form_grid_at

    ld a,(form_which)
    cp FORM_WALL
    jr z,@form_upright
    ld (form_off + 4),de                ; Loose: flat in XZ
    ld hl,form_off
    ret
@form_upright:
    ld (form_off + 2),de                ; Wall: stood on end in XY
    ld hl,0
    ld (form_off + 4),hl
    ld hl,form_off
    ret


;  DE = form_grid[A], A = 0..3
;  Uses: AF, DE, HL
form_grid_at:
    add a,a
    ld l,a
    ld h,0
    ld de,form_grid
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ret


; ============================================================================
;  State
; ============================================================================
;  Index 0 is unused so a squadron number indexes directly.
squad_form:         defs SQUAD_MAX + 1, 0

;  Where form_slot_offset assembles its answer.
form_which:         defb 0
form_slot:          defb 0
form_off:           defs 6, 0


; ============================================================================
;  The shapes are in game/formdata.asm, in bank 4
; ============================================================================
;  168 bytes of authored shape, read by form_slot_offset when a ship is given
;  a destination -- never inside the one window where bank 4 is paged out (see
;  game/shipclass.asm). It moved there when section 8's eight ship classes took
;  the low 16K past its ceiling, and it moved rather than something else
;  because it is the largest thing in the frame loop's 16K that the frame loop
;  does not touch per byte. It was 384 bytes until the two lattice formations
;  stopped being written out.
;
;  Same split as help.asm/helptext.asm and menu.asm/menutext.asm: the code
;  that walks a table stays here, the table goes in the bank.
; ----------------------------------------------------------------------------
