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

;  ...AND THE SHAPE IS REPEATED IN LAYERS, which is what makes it hold a fleet.
;
;  It did not. `and FORM_SLOT_MASK` had the comment "more ships than slots:
;  share them", and sharing a slot means two ships flying to the same point --
;  invisible, harmless at seventeen ships, and the normal case the moment
;  ENT_PLAYER_MAX doubled to 56. Doubling the fleet without touching this would
;  have been doubling the number of ships inside each other.
;
;  Four layers of the SAME authored shape, displaced along the axis that shape
;  does not use: Y for Loose, Wedge and Sphere, which are flat in XZ or spread
;  evenly, and Z for Wall, which is already standing in XY. That keeps all four
;  shapes exactly as they were drawn -- a wedge of 40 ships is four wedges in
;  echelon rather than a wedge with a different outline -- and it costs one
;  16-bit add per ship per frame plus an eight-byte table.
;
;  The layers alternate about zero (0, +1, -1, +2) so the station stays in the
;  MIDDLE of the squadron. All one way and a big squadron would sit entirely to
;  one side of the point the camera orbits.
FORM_LAYERS         equ 4
FORM_LAYER_MASK     equ FORM_LAYERS - 1
FORM_CAPACITY       equ FORM_SLOTS * FORM_LAYERS

;  Offsets within form_off: which axis a formation's layers move along.
FORM_AXIS_Y         equ 2
FORM_AXIS_Z         equ 4


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
;  Uses: everything
; ----------------------------------------------------------------------------
form_cycle:
    ;  The Mothership has no formation: it is one ship and it holds station.
    ;  squad_form has a row 0 so this would not corrupt anything, but a key
    ;  that silently changes a shape nothing is drawn in is worse than one
    ;  that does nothing.
    call order_have_squadron
    ret nc
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

    ;  Changing the shape is telling the squadron where to BE, so it ends an
    ;  attack order the same way the station and the move disc do. Without it
    ;  `F` is silently ignored for exactly as long as the fleet is out
    ;  fighting -- which is when a player is most likely to press it. See
    ;  order_release_attack for what was reported and what was measured.
    jp order_release_attack


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
    and FORM_SLOT_MASK                  ; where in the shape...
    ld (form_slot),a
    ld a,c
    rrca
    rrca
    rrca
    rrca
    and FORM_LAYER_MASK                 ; ...and which copy of it
    ld (form_layer),a

    ld a,FORM_AXIS_Y                    ; every shape but Wall layers upward
    ld (form_axis),a

    ld a,(form_which)
    cp FORM_SPHERE
    jr nz,@form_flat

    ;  The one shape with three real axes, and the only one still stored.
    ld a,(form_slot)
    call phase4_times6
    ld de,form_shell
    add hl,de
    ld a,(form_layer)
    or a
    ret z                               ; layer 0: point straight at the shape

    ;  Past that it has to be copied out, because the layer is added to it and
    ;  form_shell is in bank 4 -- read-only in every sense that matters.
    ld de,form_off
    ld bc,6
    ldir
    jr @form_layered

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
    jr @form_layered

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
    jr @form_layered
@form_upright:
    ld (form_off + 2),de                ; Wall: stood on end in XY
    ld hl,0
    ld (form_off + 4),hl
    ld a,FORM_AXIS_Z                    ; ...so its layers go back, not up
    ld (form_axis),a
;  ...and fall through.


; ----------------------------------------------------------------------------
;  @form_layered -- displace the shape in form_off by its layer
;  Out: HL -> form_off
;  Uses: everything
; ----------------------------------------------------------------------------
@form_layered:
    ld hl,form_off
    ld a,(form_layer)
    or a
    ret z                               ; the common case, and it costs a test

    add a,a                             ; a word an entry
    ld e,a
    ld d,0
    ld hl,form_layer_off
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = how far this layer stands off

    ld a,(form_axis)
    ld l,a
    ld h,0
    ld bc,form_off
    add hl,bc                           ; HL -> the axis this shape layers on
    ld a,(hl)
    add a,e
    ld (hl),a
    inc hl
    ld a,(hl)
    adc a,d
    ld (hl),a

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
form_layer:         defb 0
form_axis:          defb 0
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
