; ============================================================================
;  gfx/bigtext.asm -- the 8x8 font at four times the size, for the title
; ============================================================================
;  No second font and no bitmap logo: the same 1bpp glyphs txt_draw uses, with
;  every pixel blown up to a 4x4 block. The arithmetic is kind to us -- a
;  Mode 1 byte is four pixels, so ONE source pixel is exactly ONE screen byte,
;  and a source row of eight becomes eight bytes.
;
;  Which is why the title is ten letters. Ten glyphs at 8 bytes is 80, and 80
;  bytes IS the screen: "HOMEPLANET" fills the width exactly, with no
;  centring arithmetic anywhere.
;
;  Ink 1 on ink 0, like the rest of the text. A lit pixel becomes #F0 -- pen 1
;  is %01, so all four pixels set their bit in the high nibble and none in the
;  low one, exactly as txt_draw_char explains at greater length.
; ----------------------------------------------------------------------------

TXT_BIG_SCALE       equ 4
TXT_BIG_W_BYTES     equ 8               ; one glyph: 8 source pixels, 4x
TXT_BIG_H           equ TXT_CHAR_H * TXT_BIG_SCALE
TXT_BIG_INK         equ #F0             ; four pixels of pen 1


; ----------------------------------------------------------------------------
;  txt_big -- draw a string at 4x from the left edge of the back buffer
;  In : HL = zero-terminated string, C = top scanline
;  Uses: everything
;
;  Starts at x=0 and does not clip: it is for one string of one length on one
;  screen, and the assert in title.asm is what keeps that true.
; ----------------------------------------------------------------------------
txt_big:
    ld b,0                              ; x, in bytes
@txt_big_char:
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    call txt_big_char
    pop bc
    pop hl
    inc hl
    ld a,b
    add a,TXT_BIG_W_BYTES
    ld b,a
    jr @txt_big_char


; ----------------------------------------------------------------------------
;  txt_big_char -- one glyph, 8 bytes wide and 32 scanlines tall
;  In : A = character, B = x in bytes, C = top scanline
;  Uses: everything
; ----------------------------------------------------------------------------
txt_big_char:
    sub TXT_FIRST_CHAR
    cp TXT_LAST_CHAR - TXT_FIRST_CHAR + 1
    jr c,@txt_big_in_range
    xor a                               ; unprintable draws as a space
@txt_big_in_range:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; glyph = txt_font + char * 8
    ld de,txt_font
    add hl,de
    ld (txt_big_glyph),hl

    ld a,TXT_CHAR_H
    ld (txt_big_rows),a

@txt_big_row:
    ;  Each source row is painted TXT_BIG_SCALE times, re-expanded rather
    ;  than buffered: the buffer would want eight bytes of the little RAM
    ;  there is left, and this screen is drawn once.
    ld a,TXT_BIG_SCALE
    ld (txt_big_reps),a

@txt_big_rep:
    ld a,c
    call scr_line_addr                  ; HL = the line; BC and DE survive
    ld a,b
    add a,l
    ld l,a
    jr nc,@txt_big_no_carry
    inc h
@txt_big_no_carry:

    ld de,(txt_big_glyph)
    ld a,(de)
    ld d,a                              ; D = the row, shifted left as we go
    ld e,TXT_BIG_W_BYTES
@txt_big_pixel:
    ld a,d
    add a,a                             ; bit 7 out into the carry
    ld d,a
    ld a,0                              ; NOT xor: it would clear the carry
    jr nc,@txt_big_dark
    ld a,TXT_BIG_INK
@txt_big_dark:
    ld (hl),a
    inc hl
    dec e
    jr nz,@txt_big_pixel

    inc c                               ; next scanline
    ld a,(txt_big_reps)
    dec a
    ld (txt_big_reps),a
    jr nz,@txt_big_rep

    ld hl,(txt_big_glyph)
    inc hl
    ld (txt_big_glyph),hl

    ld a,(txt_big_rows)
    dec a
    ld (txt_big_rows),a
    jr nz,@txt_big_row
    ret


; ============================================================================
;  State
; ============================================================================
txt_big_glyph:      defw 0
txt_big_rows:       defb 0
txt_big_reps:       defb 0
