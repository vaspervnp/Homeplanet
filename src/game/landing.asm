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
    ld (mini_cls),a
    xor a
    ld (mini_view),a                    ; stern on: flying away, into it
    ld a,LAND_STEPS
    ld (land_left),a
    call snd_jump_in                    ; the drive winding down, on channel C
    ld a,(sys_tick_50hz)
    ld (mini_t0),a

@land_step:
    call mini_blank
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
    call mini_blit
@land_down:
    call mini_wait
    ld hl,land_left
    dec (hl)
    jr nz,@land_step

    ld a,CTX_BAR_H                      ; the viewport back to the game's
    ld (spr_clip_top),a
    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ret
