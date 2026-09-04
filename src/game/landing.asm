; ============================================================================
;  landing.asm -- the Mothership sets down on the homeplanet
; ============================================================================
;  "There should be a sequence of the mothership landing on the planet before
;  the end screen." finishup.md item 4, and the shape it argued for: NOT an
;  atmosphere -- there is nothing in four inks to draw air with -- but the
;  world getting closer and the ship getting smaller against it. The planet
;  is drawn where the victory page draws it, so the page that follows is the
;  same picture with the ship gone into it; the Mothership crosses from the
;  top left towards the disc's face, tier C, then B, then A, and is not
;  drawn at all for the last few steps -- it is down.
;
;  ITS OWN LOOP, like the chase and the wipe, for the same reasons: nothing
;  else is left to run, and mis_jump_now stays atomic. Every step blanks the
;  back buffer, draws the planet and the ship, flips, and paces on the 50 Hz
;  tick through mini_wait -- LAND_STEPS * MG_STEP_TICKS / 50 seconds, by
;  arithmetic. mini_blit does the blit, with mini_cls set to the Mothership:
;  its bank and its row of class_sprite come from the class tables, so this
;  file has no sprite address in it.
; ----------------------------------------------------------------------------

LAND_STEPS          equ 30              ; 30 * 7 ticks = 4.2 s
LAND_X0             equ 44              ; where it starts, top left...
LAND_Y0             equ 32
LAND_DX             equ 4               ; ...and how far it moves a step: into the disc by LAND_GONE
LAND_DY             equ 3
LAND_TIER_C         equ 10              ; steps at each size, near to far
LAND_TIER_B         equ 20
LAND_GONE           equ 27              ; from this step it is on the ground

    assert LAND_X0 + LAND_STEPS * LAND_DX < OVER_PLANET_CX + TITLE_PLANET_RX, "the Mothership lands past the planet"
    assert LAND_Y0 + LAND_STEPS * LAND_DY < OVER_PLANET_CY, "the Mothership lands below the planet's centre"
    assert LAND_GONE < LAND_STEPS, "the Mothership never lands"

; ----------------------------------------------------------------------------
;  land_run -- the sequence, from a black screen to the planet with no ship
;  Uses: everything
; ----------------------------------------------------------------------------
land_run:
    xor a
    ld (spr_clip_top),a                 ; the whole screen: the strips are gone
    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    ld a,CLASS_MOTHERSHIP
    ld (land_cls),a
    xor a
    ld (land_view),a                    ; stern on: flying away, into it
    ld a,LAND_STEPS
    ld (land_left),a
    call snd_jump_in                    ; the drive winding down, on channel C
    ld a,(sys_tick_50hz)
    ld (land_t0),a

@land_step:
    call land_blank
    ld hl,OVER_PLANET_CX
    ld (planet_cx),hl
    ld a,OVER_PLANET_CY
    ld (planet_cy),a
    call planet_draw

    ;  p = steps taken so far; the ship is at (X0 + p*DX, Y0 + p*DY)
    ld a,LAND_STEPS
    ld hl,land_left
    sub (hl)
    cp LAND_GONE
    jr nc,@land_down                    ; on the ground: nothing to draw
    ld b,a                              ; p
    ld c,a
    add a,a
    add a,c                             ; p * 3 = LAND_DX
    add a,LAND_X0
    ld e,a                              ; x
    ld a,b
    add a,a                             ; p * 2 = LAND_DY
    add a,LAND_Y0
    ld c,a                              ; y
    ld a,b
    ld b,CLASS_TIERS - 1                ; tier C...
    cp LAND_TIER_C
    jr c,@land_tiered
    dec b                               ; ...B...
    cp LAND_TIER_B
    jr c,@land_tiered
    dec b                               ; ...A
@land_tiered:
    call land_blit
@land_down:
    call land_wait
    ld hl,land_left
    dec (hl)
    jr nz,@land_step

    ld a,CTX_BAR_H                      ; the viewport back to the game's
    ld (spr_clip_top),a
    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ret


; ----------------------------------------------------------------------------
;  land_blit -- one ship of class land_cls, centred on (E, C), at tier B
;  In : B = tier, E = centre x in pixels, C = centre y
;  Uses: everything
;
;  The chase's mini_blit as it was before the chase moved to bank 7: the
;  geometry from class_geom, the row from class_sprite_addr, the view stepped
;  along by blocks, and the page through spr_blit_banked -- because from bank
;  4 that is legal and from bank 7 it is not.
; ----------------------------------------------------------------------------
land_blit:
    ld a,c
    ld (land_sy),a
    ld a,e
    ld (land_sx),a

    ld l,b
    ld h,0
    push hl                             ; the tier, for the sprite address
    ld c,l
    ld b,h
    add hl,hl                           ; * 2
    add hl,bc                           ; * 3
    add hl,hl                           ; * 6 = CLASS_GEOM_SIZE
    ld bc,class_geom
    add hl,bc

    ld a,(hl)
    ld (spr_w),a
    inc hl
    ld a,(hl)
    ld (spr_h),a
    inc hl
    ld c,(hl)                           ; half width, pixels
    inc hl
    ld b,(hl)                           ; half height, lines
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (land_bsz),de                    ; one (view, pre-shift) block

    ;  x = (centre - half width) >> 2. In single bytes, and it cannot borrow:
    ;  the leftmost either ship can be drawn at is 72 - 14.
    ld a,(land_sx)
    sub c
    srl a
    srl a
    ld l,a
    ld h,0
    ld (spr_x),hl

    ld a,(land_sy)
    sub b
    ld l,a
    ld h,0
    ld (spr_y),hl

    ;  The interceptor's row of class_sprite, which is the first one, and view
    ;  MG_VIEW at pre-shift 0.
    ;  The class's row of class_sprite -- land_cls, which the chase sets to
    ;  the interceptor and the landing to the Mothership -- and the tier's
    ;  entry in it.
    pop hl
    add hl,hl                           ; tier * 2
    push hl
    ld a,(land_cls)
    call class_sprite_addr              ; HL = &class_sprite[class]
    pop de
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = the tier's base: view 0, shift 0

    ;  ...stepped to (land_view): view * shifts blocks along, at pre-shift 0.
    ;  The same walk phase4_blit_body does, and the assert in src/main.asm
    ;  is why the `add a,a` is the number of pre-shifts.
    ld a,(land_view)
    add a,a
    jr z,@land_view_base
    ld b,a
    ld hl,(land_bsz)
    ex de,hl                            ; HL = base, DE = a block
@land_view_step:
    add hl,de
    djnz @land_view_step
    ex de,hl
@land_view_base:
    ld (spr_src),de

    ld a,(land_cls)
    ld e,a
    ld d,0
    ld hl,class_bank
    add hl,de
    ld a,(hl)                           ; ...and the bank that class is in
    jp spr_blit_banked

;  Steering -> view: straight, left, right.


; ----------------------------------------------------------------------------
;  land_wait -- show this step, then hold the rest of its MG_STEP_TICKS
;  Uses: everything
; ----------------------------------------------------------------------------
land_wait:
    call scr_wait_vsync
    call scr_flip
@land_pace:
    ld a,(sys_tick_50hz)
    ld hl,land_t0
    sub (hl)
    cp MG_STEP_TICKS
    jr nc,@land_paced
    call scr_wait_vsync
    jr @land_pace
@land_paced:
    ld a,(sys_tick_50hz)
    ld (land_t0),a
    ret


; ----------------------------------------------------------------------------
;  land_blank -- the back buffer, all two hundred lines, black
;  Uses: everything
; ----------------------------------------------------------------------------
land_blank:
    ld bc,#0000
    ld d,SCR_BYTES_PER_LINE
    ld e,SCR_HEIGHT_PX
    xor a
    jp scr_fill_rect
