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

;  20 characters at 2 bytes is 40, so 20 bytes of margin each side.
title_prompt:
    defb "PRESS SPACE TO START",0

TITLE_PROMPT_X      equ 20

;  18 characters at 2 bytes is 36, so 22 bytes of margin each side. It names
;  the key the same way the line above it does -- "PRESS SPACE TO START" and
;  "T FOR THE TUTORIAL" are the same sentence about two keys, and the whole
;  point is that one is not more discoverable than the other.
title_tut:
    defb "T FOR THE TUTORIAL",0
title_tut_end:

TITLE_TUT_X         equ 22


;  --- the flight: x in BYTES (word, signed -- spr_x is a byte column, not a
;      pixel), y, sprite, width in bytes, height ------------------------------
;      The Mothership leads with the frigate's hull -- the same stand-in the
;      game itself uses until the class has art of its own.
title_ship_table:
    defw   36
    defb  104
    defw  frigate_c
    defb  FRIGATE_C_W_BYTES, FRIGATE_C_H
    defb  GA_BANK_6
    defw   18
    defb   92
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_5
    defw   55
    defb   94
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_5
    defw    7
    defb  120
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_5
    defw   66
    defb  122
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_5

TITLE_SHIPS         equ 5
