; ============================================================================
;  title.asm -- the screen the game opens on
; ============================================================================
;  HOMEPLANET across the full width, a starfield, a flight of ships, and the
;  credit line. ENTER goes on to the first briefing.
;
;  Drawn EVERY frame, like the briefing and the help page, because the display
;  page-flips and a screen painted once alternates with whatever the other
;  buffer holds. It is expensive -- a full clear plus 80x32 of title -- but it
;  is drawn while nothing else is running and it is over the moment the player
;  presses a key.
;
;  The title takes the whole width by construction rather than by centring:
;  txt_big is 8 bytes a glyph and the screen is 80, so ten letters is exactly
;  the line. There is an assert below to keep it that way.
; ----------------------------------------------------------------------------

TITLE_Y             equ 20              ; the big letters, 32 scanlines of them
TITLE_STARS         equ 40
TITLE_CREDIT_Y      equ 186
TITLE_PROMPT_Y      equ 160
TITLE_BLINK_BIT     equ %00000100   ; ~4 game frames on, ~4 off

;  The ships, as (x, y) in the flight below the title.
TITLE_SHIP_Y        equ 104


; ----------------------------------------------------------------------------
;  title_open -- the game starts here
;  Uses: AF
; ----------------------------------------------------------------------------
title_open:
    ld a,1
    ld (title_shown),a
    ret


; ----------------------------------------------------------------------------
;  title_key -- SPACE starts the game
;
;  SPACE is the tactical pause once the game is running, and there is no
;  clash: this screen returns out of demo_update before phase4_commands is
;  ever reached, so the keypress that starts the game cannot also pause it.
;  Uses: everything
; ----------------------------------------------------------------------------
title_key:
    ld a,KEY_SPACE
    call key_hit
    ret nc
    xor a
    ld (title_shown),a

    ;  Same debt as the briefing and the help page: the whole screen has been
    ;  painted with no dirty rectangle recorded for any of it. Two frames of
    ;  wipe, one per buffer. The briefing that follows paints over the top
    ;  anyway, but the credit line sits BELOW its wipe, in the HUD strip.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a             ; and the HUD has to come back

    ret


; ----------------------------------------------------------------------------
;  title_draw -- the whole screen
;  Uses: everything
; ----------------------------------------------------------------------------
title_draw:
    ;  All 200 lines, not just the tactical area: the credit line lives in
    ;  the strip the HUD normally owns, and the HUD is not up yet.
    ld bc,#0000
    ld d,SCR_BYTES_PER_LINE
    ld e,SCR_HEIGHT_PX
    xor a
    call scr_fill_rect

    ld hl,title_text
    ld c,TITLE_Y
    call txt_big

    call title_draw_stars
    call title_draw_ships

    ;  The prompt blinks. The whole screen is repainted every frame anyway, so
    ;  "blink" is just declining to draw it on half the frames -- no erase, no
    ;  dirty rectangle, six instructions. demo_frames counts GAME frames, so
    ;  bit 2 is about four of them either way: a little under a second on and
    ;  a little under a second off.
    ld a,(demo_frames)
    and TITLE_BLINK_BIT
    jr z,@title_no_prompt
    ld hl,title_prompt
    ld b,TITLE_PROMPT_X
    ld c,TITLE_PROMPT_Y
    call txt_draw
@title_no_prompt:

    ld hl,title_credit
    ld b,TITLE_CREDIT_X
    ld c,TITLE_CREDIT_Y
    jp txt_draw


; ----------------------------------------------------------------------------
;  title_draw_stars -- the backdrop
;
;  A table rather than anything generated: forty stars is 120 bytes in the
;  bank, and a random scatter recomputed every frame would twinkle -- which
;  would be a different design decision, not this one.
;
;  Each entry is (x in bytes, y, pixel mask). Pen 2 is %10, so a star sets its
;  pixel's bit in the LOW nibble and nothing in the high one -- the mask is
;  that bit, ready to be poked straight in.
;  Uses: everything
; ----------------------------------------------------------------------------
title_draw_stars:
    ld hl,title_star_table
    ld a,TITLE_STARS
    ld (title_left),a

@title_star:
    ld c,(hl)                           ; x in bytes
    inc hl
    ld a,(hl)                           ; y
    inc hl
    ld b,(hl)                           ; the pixel
    inc hl
    push hl

    call scr_line_addr                  ; HL = the line; BC survives
    ld a,l
    add a,c
    ld l,a
    jr nc,@title_star_no_carry
    inc h
@title_star_no_carry:
    ld a,(hl)
    or b
    ld (hl),a

    pop hl
    ld a,(title_left)
    dec a
    ld (title_left),a
    jr nz,@title_star
    ret


; ----------------------------------------------------------------------------
;  title_draw_ships -- a flight crossing the middle of the screen
;
;  The real sprites out of the bank, blitted by the real blitter. Nothing is
;  drawn for the title that the game does not already own.
;  Uses: everything
; ----------------------------------------------------------------------------
title_draw_ships:
    ;  Open the clip to the whole screen so the flight can sit anywhere, and
    ;  put it BACK before returning. Restoring it in title_key instead does
    ;  not work: title_key only clears the flag, and the frame loop goes on
    ;  to call title_draw one last time in the same frame -- which re-opened
    ;  it, permanently. The tactical view then drew over the HUD and the
    ;  dirty-rectangle erase rubbed it out again, so the strip came and went
    ;  with whatever happened to be flying low.
    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    xor a
    ld (spr_enemy),a

    ld hl,title_ship_table
    ld a,TITLE_SHIPS
    ld (title_left),a

@title_ship:
    ld e,(hl)                           ; x, signed, low byte
    inc hl
    ld d,(hl)
    inc hl
    ld (spr_x),de
    ld e,(hl)                           ; y
    inc hl
    ld d,0
    ld (spr_y),de
    ld e,(hl)                           ; the sprite block
    inc hl
    ld d,(hl)
    inc hl
    ld (spr_src),de
    ld a,(hl)                           ; width in bytes
    inc hl
    ld (spr_w),a
    ld a,(hl)                           ; height
    inc hl
    ld (spr_h),a

    push hl
    call spr_blit
    pop hl

    ld a,(title_left)
    dec a
    ld (title_left),a
    jr nz,@title_ship

    ld a,HUD_TOP                        ; the strip belongs to the HUD again
    ld (spr_clip_bottom),a
    ret


; ============================================================================
;  State
; ============================================================================
title_shown:        defb 0
title_left:         defb 0
