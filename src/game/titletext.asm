; ============================================================================
;  titletext.asm -- the words and the scatter on the title screen, in bank 4
; ============================================================================
;  Data only, and in the bank because the low 16K has a few hundred bytes left
;  in total. title.asm walks all three tables.
; ----------------------------------------------------------------------------

;  Ten letters, and txt_big is 8 bytes a glyph, so this is exactly the 80-byte
;  width of the screen. The assert in title.asm holds it to that.
title_text:
    defb "HOMEPLANET",0

;  26 characters at 2 bytes each is 52, leaving 28 -- 14 bytes of margin each
;  side, which is TITLE_CREDIT_X.
title_credit:
    defb "REVIVE8BIT - 2026 - VASPER",0

TITLE_CREDIT_X      equ 14


;  --- the starfield: x in bytes, y, pixel mask (pen 2 lives in the low
;      nibble, so the mask is the bit and nothing else) ---------------------
title_star_table:
    defb 13,  56, #02
    defb 24,  57, #01
    defb 28,  60, #08
    defb 12,  62, #02
    defb 50,  64, #08
    defb 52,  71, #02
    defb  6,  73, #08
    defb 39,  73, #01
    defb 15,  87, #02
    defb 45,  87, #01
    defb 53,  88, #01
    defb 59,  88, #04
    defb  8,  90, #04
    defb 24,  91, #02
    defb 65,  95, #04
    defb 71,  95, #01
    defb 18,  97, #08
    defb 77, 115, #04
    defb 74, 118, #01
    defb 63, 129, #04
    defb 40, 131, #04
    defb 42, 131, #04
    defb 55, 131, #02
    defb 13, 135, #01
    defb 73, 135, #08
    defb 37, 147, #02
    defb  9, 152, #08
    defb 45, 157, #04
    defb 71, 158, #02
    defb 56, 160, #02
    defb 75, 160, #08
    defb 30, 161, #08
    defb 43, 161, #01
    defb 36, 164, #01
    defb 28, 165, #04
    defb  0, 166, #02
    defb  9, 167, #08
    defb  4, 172, #08
    defb 34, 173, #08
    defb 69, 175, #04


;  --- the flight: x in BYTES (word, signed -- spr_x is a byte column, not a
;      pixel), y, sprite, width in bytes, height ------------------------------
;      The Mothership leads with the frigate's hull -- the same stand-in the
;      game itself uses until the class has art of its own.
title_ship_table:
    defw   36
    defb  104
    defw  frigate_c
    defb  FRIGATE_C_W_BYTES, FRIGATE_C_H
    defw   18
    defb   92
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defw   55
    defb   94
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defw    7
    defb  120
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defw   66
    defb  122
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H

TITLE_SHIPS         equ 5
