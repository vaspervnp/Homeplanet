; ============================================================================
;  gfx/text.asm -- 8x8 text for the HUD
; ============================================================================
;  The firmware is gone, so there is no TXT OUTPUT and no ROM font. Glyphs are
;  stored 1 bit per pixel, 8 bytes each, and expanded to Mode 1 as they are
;  drawn -- 8 bytes a glyph rather than the 32 a pre-expanded Mode 1 bitmap
;  would cost, which matters when the font has to live under #4000.
;
;  Text is drawn in ink 1 on ink 0, opaque, byte aligned. The HUD is a fixed
;  strip so there is no call for anything cleverer.
;
;  The expansion is two instructions' worth of work per screen byte, because
;  the two formats happen to agree. A Mode 1 byte holds pixels A B C D as
;
;      A0 B0 C0 D0 A1 B1 C1 D1        (bit 7 first)
;
;  where n0/n1 are the two bits of that pixel's pen. Ink 1 is %01, so every
;  lit pixel sets its bit in the HIGH nibble and clears it in the low one:
;  four 1bpp pixels ARE their own Mode 1 byte once the low nibble is zeroed.
;  So a row byte g becomes
;
;      left  screen byte = g AND #F0        (pixels 0-3, already in place)
;      right screen byte = g SHL 4          (pixels 4-7, shifted up into it)
;
;  and nothing can ever set a bit in the low nibble, which is why text cannot
;  produce pen 2 or pen 3.
;
;  The face is 5x7 in an 8x8 cell, left aligned: columns are bits 7..3 and
;  row 7 is blank. That leaves 3 pixels of tracking and 1 of leading -- airy
;  rather than dense, which is the tone the design document asks for.
; ----------------------------------------------------------------------------

TXT_CHAR_W_BYTES    equ 2               ; 8 pixels, Mode 1
TXT_CHAR_H          equ 8

;  --- colour -------------------------------------------------------------
;  Everything above produces PEN 1: four 1bpp pixels are their own Mode 1 byte
;  because ink 1 is %01, so a lit pixel sets its bit in the high nibble and
;  nothing in the low one.
;
;  The other two inks fall out of that for almost nothing. Ink 2 is %10 -- the
;  same pixels in the LOW nibble, so pen 2 is the pen-1 byte shifted right
;  four. Ink 3 is %11, which is both. So one mask per plane covers all three:
;
;      pen 1:  hi = #FF  lo = #00
;      pen 2:  hi = #00  lo = #FF
;      pen 3:  hi = #FF  lo = #FF
;
;  The masks are patched into the AND immediates rather than read from memory,
;  which is the difference between this costing a handful of T-states a byte
;  and costing a load. txt_set_pen is the only thing that writes them.
;
;  Space..'Z'. Lowercase and #5B-#5F are dropped: 5 glyphs is 40 bytes and
;  nothing in the HUD spells anything in lower case. Everything outside the
;  range prints as a space rather than as garbage.
TXT_FIRST_CHAR      equ 32              ; space
TXT_LAST_CHAR       equ 90              ; 'Z'; uppercase only

TXT_NUM_MAX         equ 5               ; widest field txt_draw_num will take


; ----------------------------------------------------------------------------
;  txt_set_pen -- choose the ink the next string is drawn in
;  In : A = 1, 2 or 3
;  Uses: AF, B
;
;  NOT sticky by convention: whoever changes it puts it back to 1, so a
;  routine that draws in white does not have to ask what the last one left.
; ----------------------------------------------------------------------------
txt_set_pen:
    ld b,a
    rrca                                ; bit 0 -> CF: does this ink use plane 0?
    sbc a,a                             ; #FF if it does, #00 if not
    ld (txt_mask_hi),a
    ld a,b
    rrca
    rrca                                ; bit 1 -> CF: and plane 1?
    sbc a,a
    ld (txt_mask_lo),a
    ret


; ----------------------------------------------------------------------------
;  txt_pen_map -- recolour one screen byte's worth of pen-1 pixels
;  In : A = the pixels, lit in the high nibble
;  Out: A = the same pixels in the chosen ink
;  Uses: AF  (B and C belong to the glyph loop and must survive)
; ----------------------------------------------------------------------------
txt_pen_map:
    push bc
    ld c,a
    rrca
    rrca
    rrca
    rrca                                ; the same pixels, low nibble
txt_mask_lo equ $+1
    and #00                             ; PATCHED by txt_set_pen
    ld b,a
    ld a,c
txt_mask_hi equ $+1
    and #FF                             ; PATCHED by txt_set_pen
    or b
    pop bc
    ret


; ----------------------------------------------------------------------------
;  txt_draw -- draw a zero-terminated string into the back buffer
;
;  Stops early rather than wrapping if the string reaches the right edge: a
;  glyph at x=79 would put its second byte on the following scanline, which
;  is worse than a truncated label.
;  In : HL = string, B = x in BYTES (0..79), C = y in lines (0..199)
;  Uses: everything
; ----------------------------------------------------------------------------
txt_draw:
@txt_str_loop:
    ld a,b
    cp SCR_BYTES_PER_LINE - TXT_CHAR_W_BYTES + 1
    ret nc                              ; no room left for a whole glyph
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    call txt_draw_char
    pop bc
    pop hl
    inc hl
    inc b
    inc b                               ; TXT_CHAR_W_BYTES
    jr @txt_str_loop


; ----------------------------------------------------------------------------
;  txt_draw_char -- one glyph
;
;  The glyph pointer lives in DE and the screen address in HL, not the other
;  way round, because scr_line_addr owns HL and promises nothing else -- and
;  the Z80 has LD A,(DE) for the source side, which is all this needs.
;
;  scr_line_addr is called ONCE, not once a row. The HUD redraws around fifty
;  glyphs a frame and the call is 81 T-states, which is 42% of a row that only
;  writes two bytes -- it does not survive that arithmetic. So the address is
;  stepped by hand instead: within a character row the next scanline is #800
;  further on, and every eighth one instead goes back #3800 and forward 80.
;  C counts down to that step, which is why it is loaded with 8 - (y AND 7).
;
;  This is exactly the assumption CLAUDE.md warns about, so the boundary is
;  pinned by test_it_straddles_the_eight_line_character_row_boundary.
;  In : A = character, B = x in bytes, C = y in lines
;  Uses: everything
; ----------------------------------------------------------------------------
TXT_ROW_STRIDE      equ #800            ; next scanline, same character row
TXT_ROW_WRAP        equ -#3800 + SCR_BYTES_PER_LINE     ; ...and over the edge

txt_draw_char:
    sub TXT_FIRST_CHAR
    cp TXT_LAST_CHAR - TXT_FIRST_CHAR + 1
    jr c,@txt_in_range
    xor a                               ; unprintable -> space
@txt_in_range:
    ld l,a                              ; glyph = txt_font + char * 8
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,txt_font
    add hl,de
    ex de,hl                            ; DE = glyph row 0

    ld a,c
    call scr_line_addr                  ; HL = line C; BC and DE survive
    ld a,b
    add a,l                             ; + x
    ld l,a
    jr nc,@txt_no_carry
    inc h
@txt_no_carry:

    ;  C = 8 - (y AND 7): rows left before the character-row wrap. NOT (y) has
    ;  the low three bits of 7 - (y AND 7) already, so this is four bytes.
    ld a,c
    cpl
    and 7
    inc a
    ld c,a
    ld b,TXT_CHAR_H

@txt_row:
    ld a,(de)                           ; 1bpp row, bit 7 = leftmost pixel
    and #F0                             ; left four pixels, already in place
    call txt_pen_map
    ld (hl),a
    inc hl
    ld a,(de)                           ; re-read: cheaper than PUSH/POP AF
    inc de
    add a,a                             ; right four pixels, up into the
    add a,a                             ; pen-bit-0 nibble
    add a,a
    add a,a
    call txt_pen_map
    ld (hl),a
    dec hl

    dec c
    jr z,@txt_next_char_row
    ld a,h                              ; += #800
    add a,TXT_ROW_STRIDE / 256
    ld h,a
@txt_next_row:
    djnz @txt_row
    ret

@txt_next_char_row:
    ld c,SCR_LINES_PER_CHAR
    ld a,l                              ; += -#3800 + 80
    add a,TXT_ROW_WRAP & 255
    ld l,a
    ld a,h
    adc a,(TXT_ROW_WRAP >> 8) & 255
    ld h,a
    jr @txt_next_row


; ----------------------------------------------------------------------------
;  txt_draw_num -- A as decimal, right-aligned in a fixed field
;
;  The HUD shows ship counts, so it needs 0..255 without leading zeros but
;  without the column jumping about either. The field is built in full, spaces
;  and all, so that a number that has just got shorter erases its own old
;  leading digit instead of leaving it on screen.
;
;  A value too wide for the field loses its top digits rather than growing to
;  the left; the field is exactly D characters wide, always.
;  In : A = value, B = x in bytes, C = y in lines, D = field width in chars
;  Uses: everything
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  txt_draw_num4 -- draw HL as four decimal digits, leading zeros
;  In : HL = value (0..9999), B = x in bytes, C = y
;  Uses: everything
;
;  The 8-bit form below divides by ten with repeated subtraction, which costs
;  25 iterations at worst and is cheaper than a table. At 16 bits that becomes
;  6553, so this one goes the other way: subtract each power of ten as many
;  times as it fits, most significant first. Thirty-six subtractions at worst,
;  no division and no reciprocal table.
;
;  Four digits rather than a width parameter, because there is one caller. A
;  general version was written first and cost 250 bytes -- most of it the
;  right-align-into-a-narrower-field logic that nothing wanted.
; ----------------------------------------------------------------------------
txt_draw_num4:
    push bc                             ; x and y, for the txt_draw below
    ld de,txt_pow10
    ld bc,txt_num_buf
    ld (txt_n4_ptr),bc
    ld b,4

@txt_n4_place:
    push bc
    ld a,(de)
    ld c,a
    inc de
    ld a,(de)
    ld b,a
    inc de                              ; BC = this power of ten
    push de

    ld e,'0'
@txt_n4_sub:
    or a
    sbc hl,bc
    jr c,@txt_n4_undo
    inc e
    jr @txt_n4_sub
@txt_n4_undo:
    add hl,bc                           ; one subtraction too many; put it back

    ld a,e                              ; the digit, BEFORE DE is reused
    ld de,(txt_n4_ptr)
    ld (de),a
    inc de
    ld (txt_n4_ptr),de

    pop de                              ; the powers pointer
    pop bc
    djnz @txt_n4_place

    ld de,(txt_n4_ptr)
    xor a
    ld (de),a                           ; terminator, one past the four digits

    pop bc
    ld hl,txt_num_buf
    jp txt_draw

txt_pow10:          defw 1000, 100, 10, 1
txt_n4_ptr:         defw 0


txt_draw_num:
    ld e,a                              ; E = what is left to convert
    ld a,d
    or a
    ret z                               ; zero-width field: nothing to draw
    cp TXT_NUM_MAX + 1
    jr c,@txt_width_ok
    ld d,TXT_NUM_MAX                    ; clamp to the buffer
@txt_width_ok:
    push bc                             ; x and y, for the txt_draw below

    ld hl,txt_num_buf
    ld c,d
    ld b,0
    add hl,bc
    ld (hl),0                           ; terminator, one past the field

@txt_digit:
    dec hl
    ;  E / 10 -> B, E MOD 10 -> A. Twenty-five subtractions at worst, a
    ;  handful of times a frame; a division table would not earn its bytes.
    ld a,e
    ld b,0
@txt_div10:
    cp 10
    jr c,@txt_div10_done
    sub 10
    inc b
    jr @txt_div10
@txt_div10_done:
    add a,'0'
    ld (hl),a
    ld a,b
    ld e,a                              ; carry on with the quotient
    dec c
    jr z,@txt_num_done                  ; field full
    or a
    jr nz,@txt_digit

@txt_pad:
    dec hl                              ; blank the rest, right to left
    ld (hl),' '
    dec c
    jr nz,@txt_pad

@txt_num_done:
    pop bc                              ; x, y
    ld hl,txt_num_buf
    jp txt_draw


; ============================================================================
;  State
; ============================================================================
txt_num_buf:        defs TXT_NUM_MAX + 1, 0


; ============================================================================
;  The font
; ============================================================================
;  8 bytes a glyph, one per pixel row, bit 7 leftmost. Read the 1s in each
;  block and you can see the letter -- that is the point of the layout, and
;  the reason the glyphs are written out rather than generated.
; ----------------------------------------------------------------------------
txt_font:
    ;  space
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000

    ;  exclamation
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00000000
    defb %00100000
    defb %00000000

    ;  quote
    defb %01010000
    defb %01010000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000

    ;  hash
    defb %01010000
    defb %01010000
    defb %11111000
    defb %01010000
    defb %11111000
    defb %01010000
    defb %01010000
    defb %00000000

    ;  dollar
    defb %00100000
    defb %01111000
    defb %10100000
    defb %01110000
    defb %00101000
    defb %11110000
    defb %00100000
    defb %00000000

    ;  percent
    defb %11001000
    defb %11001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %10011000
    defb %10011000
    defb %00000000

    ;  ampersand
    defb %01100000
    defb %10010000
    defb %10100000
    defb %01000000
    defb %10101000
    defb %10010000
    defb %01101000
    defb %00000000

    ;  apostrophe
    defb %00100000
    defb %00100000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000

    ;  open paren
    defb %00010000
    defb %00100000
    defb %01000000
    defb %01000000
    defb %01000000
    defb %00100000
    defb %00010000
    defb %00000000

    ;  close paren
    defb %01000000
    defb %00100000
    defb %00010000
    defb %00010000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %00000000

    ;  star
    defb %00000000
    defb %00100000
    defb %10101000
    defb %01110000
    defb %10101000
    defb %00100000
    defb %00000000
    defb %00000000

    ;  plus
    defb %00000000
    defb %00100000
    defb %00100000
    defb %11111000
    defb %00100000
    defb %00100000
    defb %00000000
    defb %00000000

    ;  comma
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %01100000
    defb %01000000
    defb %00000000

    ;  minus
    defb %00000000
    defb %00000000
    defb %00000000
    defb %11111000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000

    ;  full stop
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %00000000
    defb %01100000
    defb %01100000
    defb %00000000

    ;  slash
    defb %00001000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %10000000
    defb %10000000
    defb %00000000

    ;  0
    defb %01110000
    defb %10001000
    defb %10011000
    defb %10101000
    defb %11001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  1
    defb %00100000
    defb %01100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %01110000
    defb %00000000

    ;  2
    defb %01110000
    defb %10001000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %11111000
    defb %00000000

    ;  3
    defb %11111000
    defb %00010000
    defb %00100000
    defb %00010000
    defb %00001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  4
    defb %00010000
    defb %00110000
    defb %01010000
    defb %10010000
    defb %11111000
    defb %00010000
    defb %00010000
    defb %00000000

    ;  5
    defb %11111000
    defb %10000000
    defb %11110000
    defb %00001000
    defb %00001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  6
    defb %00110000
    defb %01000000
    defb %10000000
    defb %11110000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  7
    defb %11111000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %01000000
    defb %01000000
    defb %00000000

    ;  8
    defb %01110000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  9
    defb %01110000
    defb %10001000
    defb %10001000
    defb %01111000
    defb %00001000
    defb %00010000
    defb %01100000
    defb %00000000

    ;  colon
    defb %00000000
    defb %01100000
    defb %01100000
    defb %00000000
    defb %01100000
    defb %01100000
    defb %00000000
    defb %00000000

    ;  semicolon
    defb %00000000
    defb %01100000
    defb %01100000
    defb %00000000
    defb %01100000
    defb %01100000
    defb %01000000
    defb %00000000

    ;  less
    defb %00010000
    defb %00100000
    defb %01000000
    defb %10000000
    defb %01000000
    defb %00100000
    defb %00010000
    defb %00000000

    ;  equals
    defb %00000000
    defb %00000000
    defb %11111000
    defb %00000000
    defb %11111000
    defb %00000000
    defb %00000000
    defb %00000000

    ;  greater
    defb %01000000
    defb %00100000
    defb %00010000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %00000000

    ;  question
    defb %01110000
    defb %10001000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %00000000
    defb %00100000
    defb %00000000

    ;  at
    defb %01110000
    defb %10001000
    defb %10111000
    defb %10101000
    defb %10111000
    defb %10000000
    defb %01110000
    defb %00000000

    ;  A
    defb %01110000
    defb %10001000
    defb %10001000
    defb %11111000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %00000000

    ;  B
    defb %11110000
    defb %10001000
    defb %10001000
    defb %11110000
    defb %10001000
    defb %10001000
    defb %11110000
    defb %00000000

    ;  C
    defb %01110000
    defb %10001000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  D
    defb %11110000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %11110000
    defb %00000000

    ;  E
    defb %11111000
    defb %10000000
    defb %10000000
    defb %11110000
    defb %10000000
    defb %10000000
    defb %11111000
    defb %00000000

    ;  F
    defb %11111000
    defb %10000000
    defb %10000000
    defb %11110000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %00000000

    ;  G
    defb %01110000
    defb %10001000
    defb %10000000
    defb %10111000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  H
    defb %10001000
    defb %10001000
    defb %10001000
    defb %11111000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %00000000

    ;  I
    defb %01110000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %01110000
    defb %00000000

    ;  J
    defb %00111000
    defb %00010000
    defb %00010000
    defb %00010000
    defb %00010000
    defb %10010000
    defb %01100000
    defb %00000000

    ;  K
    defb %10001000
    defb %10010000
    defb %10100000
    defb %11000000
    defb %10100000
    defb %10010000
    defb %10001000
    defb %00000000

    ;  L
    defb %10000000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %11111000
    defb %00000000

    ;  M
    defb %10001000
    defb %11011000
    defb %10101000
    defb %10101000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %00000000

    ;  N
    defb %10001000
    defb %10001000
    defb %11001000
    defb %10101000
    defb %10011000
    defb %10001000
    defb %10001000
    defb %00000000

    ;  O
    defb %01110000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  P
    defb %11110000
    defb %10001000
    defb %10001000
    defb %11110000
    defb %10000000
    defb %10000000
    defb %10000000
    defb %00000000

    ;  Q
    defb %01110000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10101000
    defb %10010000
    defb %01101000
    defb %00000000

    ;  R
    defb %11110000
    defb %10001000
    defb %10001000
    defb %11110000
    defb %10100000
    defb %10010000
    defb %10001000
    defb %00000000

    ;  S
    defb %01110000
    defb %10001000
    defb %10000000
    defb %01110000
    defb %00001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  T
    defb %11111000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00000000

    ;  U
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %01110000
    defb %00000000

    ;  V
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10001000
    defb %01010000
    defb %00100000
    defb %00000000

    ;  W
    defb %10001000
    defb %10001000
    defb %10001000
    defb %10101000
    defb %10101000
    defb %11011000
    defb %10001000
    defb %00000000

    ;  X
    defb %10001000
    defb %10001000
    defb %01010000
    defb %00100000
    defb %01010000
    defb %10001000
    defb %10001000
    defb %00000000

    ;  Y
    defb %10001000
    defb %10001000
    defb %01010000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00100000
    defb %00000000

    ;  Z
    defb %11111000
    defb %00001000
    defb %00010000
    defb %00100000
    defb %01000000
    defb %10000000
    defb %11111000
    defb %00000000
txt_font_end:

    ;  txt_draw_char indexes this with a byte shifted left three times, so a
    ;  short table would read past the end and draw noise.
    assert txt_font_end - txt_font == (TXT_LAST_CHAR - TXT_FIRST_CHAR + 1) * TXT_CHAR_H, "font table is not 8 bytes a glyph"
