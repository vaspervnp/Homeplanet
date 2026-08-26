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
;  The shapes are in game/formdata.asm, in bank 4
; ============================================================================
;  384 bytes of authored lattice, read by form_slot_offset when a ship is
;  given a destination -- never inside the one window where bank 4 is paged
;  out (see game/shipclass.asm). It moved there when section 8's eight ship
;  classes took the low 16K past its ceiling, and it moved rather than
;  something else because it is the largest thing in the frame loop's 16K
;  that the frame loop does not touch per byte.
;
;  Same split as help.asm/helptext.asm and menu.asm/menutext.asm: the code
;  that walks a table stays here, the table goes in the bank.
; ----------------------------------------------------------------------------
