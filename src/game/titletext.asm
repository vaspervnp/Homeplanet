; ============================================================================
;  titletext.asm -- the words and the scatter on the title screen, in bank 4
; ============================================================================
;  Data only, and in the bank because the low 16K has a few hundred bytes left
;  in total. title.asm walks all three tables.
; ----------------------------------------------------------------------------

;  Ten letters, and txt_big is 8 bytes a glyph, so this is exactly the 80-byte
;  width of the screen. The assert in title.asm holds it to that.

;  26 characters at 2 bytes each is 52, leaving 28 -- 14 bytes of margin each
;  side, which is TITLE_CREDIT_X.

TITLE_CREDIT_X      equ 14

;  20 characters at 2 bytes is 40, so 20 bytes of margin each side.

TITLE_PROMPT_X      equ 20

;  18 characters at 2 bytes is 36, so 22 bytes of margin each side. It names
;  the key the same way the line above it does -- "PRESS SPACE TO START" and
;  "T FOR THE TUTORIAL" are the same sentence about two keys, and the whole
;  point is that one is not more discoverable than the other.

;  19 characters at 2 bytes is 38, so 21 bytes of margin each side -- and this
;  is 20, deliberately. A CHARACTER CELL IS TWO BYTES, so every screen decoder
;  in the test suite walks cells from byte 0 and can only read text drawn at an
;  EVEN byte column; at 21 this line came back as a row of question marks and
;  the tutorial's own test could not see the word TUTORIAL at all. Two pixels
;  left of true centre is invisible on a Mode 1 screen. The game-over screen
;  had the same collision and paid for it with a phase-aware reader; this line
;  is one byte, so it pays with the byte.
;
;  IT USED TO READ "T FOR THE TUTORIAL", one sentence mirroring the one above
;  it, and the note over TITLE_TUT_Y argues for that at length: whatever this
;  screen says about SPACE it should say about T, in the same words. The music
;  needs naming too and there is nowhere to put a fourth line -- the planet
;  ends at 152 and the prompt starts at 160 -- so the second line carries both
;  keys in the terser form. T loses its sentence; what it keeps is being on the
;  screen at all, which is the thing that argument was really about.
TITLE_TUT_X         equ 20


;  --- the flight: x in BYTES (word, signed -- spr_x is a byte column, not a
;      pixel), y, sprite, width in bytes, height ------------------------------
;      The Mothership leads with the frigate's hull -- the same stand-in the
;      game itself uses until the class has art of its own.
;  THE FOUR STRINGS ARE IN BANK 7 -- title_words in game/screentext.asm, fetched
;  a line at a time by title_draw through bank7_fetch. Only their columns stay.

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
