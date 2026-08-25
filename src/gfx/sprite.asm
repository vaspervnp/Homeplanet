; ============================================================================
;  gfx/sprite.asm -- the masked sprite blitter (Homeplanet.md section 5.3)
; ============================================================================
;  Sprite data is mask/data pairs, row-major, exactly as tools/rt2sprite.py
;  emits it, so the inner loop eats it without rearranging anything:
;
;      ld a,(de) : and (hl) : inc hl : or (hl) : inc hl : ld (de),a : inc de
;
;  HL is the sprite and DE the screen, not the other way round, because the
;  Z80 has AND (HL) but no AND (DE).
;
;  The run is unrolled per width and entered part-way in, so there is no DJNZ
;  in the inner loop -- 46 T-states a byte instead of 59. The entry address is
;  computed once per sprite and patched into the CALL below.
; ----------------------------------------------------------------------------

SPR_MAX_W_BYTES     equ 8               ; tier C is 7; one spare
SPR_UNIT_BYTES      equ 7               ; size of one blit unit, in opcodes
SPR_ENEMY_UNIT      equ 17              ; the recolouring unit is longer


; ----------------------------------------------------------------------------
;  spr_blit -- draw one sprite block into the back buffer, clipped
;
;  In : (spr_src) = block address
;       (spr_x)   = LEFT edge, signed 16-bit, in BYTES (4 pixels each)
;       (spr_y)   = TOP edge, signed 16-bit, in lines
;       (spr_w)   = width in bytes, unclipped
;       (spr_h)   = height in lines, unclipped
;  Out: CF set   -> something was drawn, and (spr_rect) holds what
;       CF clear -> entirely off screen, nothing touched
;  Uses: everything
; ----------------------------------------------------------------------------
spr_blit:
    ; ================= vertical clip =====================================
    ld hl,(spr_y)
    ld a,(spr_h)
    ld b,a                              ; B = rows still to draw
    ld de,(spr_src)

    bit 7,h
    jr z,@y_not_negative

    ;  Top edge above the screen: drop that many rows and step the source
    ;  past them.
    ld a,l
    neg                                 ; rows to skip (y is > -256 in practice)
    cp b
    jp nc,spr_reject                    ; the whole sprite is above the screen
    ld c,a                              ; C = rows skipped
    ld a,b
    sub c
    ld b,a                              ; B = rows left

    ;  src += skipped * w * 2
    ld a,(spr_w)
    add a,a                             ; bytes per source row
    ld l,a
    ld h,0
@skip_rows:
    ex de,hl
    add hl,de
    ex de,hl
    dec c
    jr nz,@skip_rows

    ld hl,0                             ; y = 0

@y_not_negative:
    ;  Bottom edge: clamp the row count so we stop at line 199.
    ld a,h
    or a
    jp nz,spr_reject                    ; y >= 256, off the bottom
    ld a,(spr_clip_bottom)
    sub l
    jp z,spr_reject
    jp c,spr_reject                     ; below the viewport
    cp b
    jr nc,@height_ok
    ld b,a                              ; clamp
@height_ok:
    ld a,l
    ld (spr_cur_y),a
    ld a,b
    ld (spr_rows_left),a
    ld (spr_rect + 3),a                 ; record the clipped height
    ld (spr_src_cur),de

    ; ================= horizontal clip ===================================
    ld hl,(spr_x)
    ld a,(spr_w)
    ld c,a                              ; C = full width

    bit 7,h
    jr z,@x_not_negative

    ld a,l
    neg                                 ; byte columns to skip on the left
    cp c
    jp nc,spr_reject                    ; entirely off the left edge
    ld b,a
    ;  src += skipped * 2
    add a,a
    ld e,a
    ld d,0
    ld hl,(spr_src_cur)
    add hl,de
    ld (spr_src_cur),hl

    ld a,c
    sub b
    ld c,a                              ; columns available after the skip
    ld hl,0                             ; x = 0

@x_not_negative:
    ld a,h
    or a
    jp nz,spr_reject                    ; x >= 256 bytes, off the right
    ld a,SCR_BYTES_PER_LINE
    sub l
    jp z,spr_reject
    jp c,spr_reject
    cp c
    jr nc,@width_ok
    ld c,a                              ; clamp to the right edge
@width_ok:
    ld a,c
    or a
    jp z,spr_reject
    ld (spr_draw_w),a
    ld (spr_rect + 2),a
    ld a,l
    ld (spr_cur_x),a
    ld (spr_rect + 0),a
    ld a,(spr_cur_y)
    ld (spr_rect + 1),a

    ; ================= per-sprite setup ==================================
    ;  Bytes to step the source on at the end of each row. Note this does not
    ;  depend on the LEFT skip: the row is w*2 long and we consumed draw_w*2
    ;  of it starting at the skip, so the same (w - draw_w)*2 lands us on the
    ;  next row at the same offset.
    ld a,(spr_w)
    ld b,a
    ld a,(spr_draw_w)
    ld c,a
    ld a,b
    sub c
    add a,a
    ld l,a
    ld h,0
    ld (spr_row_advance),hl

    ;  Entry point into the unrolled run: draw_w units back from its end.
    ;  Enemies go down a different run with a longer unit, so both the size
    ;  and the end address depend on which.
    ld a,(spr_enemy)
    or a
    jr nz,@spr_enemy_entry

    ld a,c                              ; draw_w
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; w * 8
    ld e,a
    ld d,0
    or a
    sbc hl,de                           ; w * SPR_UNIT_BYTES
    ex de,hl
    ld hl,spr_row_end
    jr @spr_have_entry

@spr_enemy_entry:
    ld a,c
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                           ; w * 16
    ld e,a
    ld d,0
    add hl,de                           ; w * 17 = SPR_ENEMY_UNIT
    ex de,hl
    ld hl,spr_erow_end

@spr_have_entry:
    or a
    sbc hl,de
    ld (spr_call_entry),hl              ; patches the CALL below

    ; ================= draw ==============================================
@row:
    ld a,(spr_cur_y)
    call scr_line_addr                  ; HL = start of the line
    ld a,(spr_cur_x)
    add a,l
    ld l,a
    jr nc,@spr_no_carry
    inc h
@spr_no_carry:
    ex de,hl                            ; DE = screen
    ld hl,(spr_src_cur)                 ; HL = sprite

spr_call_entry equ $+1
    call 0                              ; patched above

    ld de,(spr_row_advance)
    add hl,de
    ld (spr_src_cur),hl

    ld hl,spr_cur_y
    inc (hl)
    ld hl,spr_rows_left
    dec (hl)
    jr nz,@row

    scf
    ret

spr_reject:
    or a
    ret


; ----------------------------------------------------------------------------
;  The unrolled run. Entered SPR_UNIT_BYTES * width bytes back from the end,
;  so it draws exactly that many bytes and falls into the RET.
;
;  In : HL = sprite (mask, data, mask, data, ...), DE = screen
; ----------------------------------------------------------------------------
spr_row_start:
    repeat SPR_MAX_W_BYTES
    ld a,(de)
    and (hl)
    inc hl
    or (hl)
    inc hl
    ld (de),a
    inc de
    rend
spr_row_end:
    ret


; ----------------------------------------------------------------------------
;  The same run again, recolouring pen 1 as pen 3 on the way past.
;
;  Enemies are the same ships in the enemy colour (Homeplanet.md section 2),
;  and in Mode 1 that costs no storage at all. A byte holds pixels A B C D as
;  A0 B0 C0 D0 A1 B1 C1 D1, so the pen's bit 0 lives in the high nibble and
;  its bit 1 in the low one. Pen 1 is %01 and pen 3 is %11, so
;
;      data OR ((data >> 4) AND #0F)
;
;  turns every pen 1 into a pen 3 and leaves pens 0 and 2 exactly where they
;  are. A whole second copy of every sprite library would be 5.6 KB a class;
;  this is four instructions.
;
;  Only the DATA is recoloured, never the background that shows through the
;  mask -- a friendly ship behind an enemy stays white.
; ----------------------------------------------------------------------------
spr_erow_start:
    repeat SPR_MAX_W_BYTES
    ld a,(de)
    and (hl)
    inc hl
    ld c,(hl)
    inc hl
    or c
    ld b,a
    ld a,c
    rrca
    rrca
    rrca
    rrca
    and #0F
    or b
    ld (de),a
    inc de
    rend
spr_erow_end:
    ret

    ;  The entry-offset arithmetic above assumes each unit is exactly
    ;  SPR_UNIT_BYTES long. Adding an instruction to the unit without updating
    ;  that constant would enter the run at the wrong place, mid-instruction.
    assert spr_row_end - spr_row_start == SPR_MAX_W_BYTES * SPR_UNIT_BYTES, "blit unit is not SPR_UNIT_BYTES long"
    assert spr_erow_end - spr_erow_start == SPR_MAX_W_BYTES * SPR_ENEMY_UNIT, "enemy blit unit is not SPR_ENEMY_UNIT long"


; ============================================================================
;  State
; ============================================================================
;  First scanline the tactical view may NOT touch. The HUD owns the strip
;  below it, and clipping here rather than redrawing the HUD every frame is
;  worth about 90,000 T-states a frame -- the HUD only has to be redrawn when
;  it actually changes, which is almost never.
;
;  Callers that want the whole screen (the blitter's own tests) set this to
;  SCR_HEIGHT_PX.
spr_clip_bottom:    defb SCR_HEIGHT_PX

;  Set before spr_blit to draw the sprite in the enemy colour.
spr_enemy:          defb 0

spr_src:            defw 0              ; input: block address
spr_x:              defw 0              ; input: left edge, signed, in bytes
spr_y:              defw 0              ; input: top edge, signed, in lines
spr_w:              defb 0              ; input: width in bytes
spr_h:              defb 0              ; input: height in lines

spr_src_cur:        defw 0
spr_row_advance:    defw 0
spr_cur_x:          defb 0
spr_cur_y:          defb 0
spr_draw_w:         defb 0
spr_rows_left:      defb 0

;  What was actually drawn, in the form scr_fill_rect wants so it can be
;  erased again: x byte, y, width bytes, height lines.
spr_rect:           defs 4, 0
