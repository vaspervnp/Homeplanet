; ============================================================================
;  memmap.asm -- HOMEPLANET memory map (see Homeplanet.md section 11)
; ============================================================================
;
;   #0000-#003F   RST vectors + our IM 1 handler at #0038
;   #0040-#3FFF   game code, lookup tables, entity data      (16 KB)
;   #4000-#7FFF   BANK WINDOW (extended banks 4-7)           (16 KB)
;                 sprite libraries, mission data, text, music
;   #8000-#BFFF   screen buffer B                            (16 KB)
;   #C000-#FFFF   screen buffer A                            (16 KB)
;
;  Everything the code touches every frame must live below #4000, because the
;  #4000 window is being paged underneath it.
; ----------------------------------------------------------------------------

    ifndef MEMMAP_INCLUDED
MEMMAP_INCLUDED equ 1

CODE_START          equ #0040
CODE_LIMIT          equ #4000           ; hard ceiling; build fails past this

IRQ_VECTOR          equ #0038

BANK_WINDOW         equ #4000
BANK_WINDOW_SIZE    equ #4000

SCREEN_B            equ #8000
SCREEN_A            equ #C000
SCREEN_SIZE         equ #4000
SCREEN_XOR          equ #4000           ; SCREEN_A ^ SCREEN_XOR = SCREEN_B

; --- Mode 1 geometry --------------------------------------------------------
SCR_WIDTH_PX        equ 320
SCR_HEIGHT_PX       equ 200
SCR_BYTES_PER_LINE  equ 80              ; 4 pixels per byte
SCR_CHAR_ROWS       equ 25
SCR_LINES_PER_CHAR  equ 8
SCR_USED_BYTES      equ 16000           ; 25 * 8 * 80

; Screen centre, used by the projection
SCR_CENTRE_X        equ 160
SCR_CENTRE_Y        equ 100

;  ...but NOT vertically, because the screen is not the playfield. The context
;  bar owns lines 0..9 and the HUD everything from 168, so a ship may only be
;  drawn between them and the middle of that band is 89, not 100. Projecting
;  about 100 put the whole picture eleven lines low and pushed it under the
;  HUD from one end.
;
;  A literal here rather than (CTX_BAR_H + HUD_TOP) / 2, because those two live
;  in src/demo/phase4.asm and are included long after the projection; src/main.asm
;  asserts it against them, and against the model's own copy in
;  tools/gentables.py, once everything is in scope.
PROJ_CENTRE_Y       equ 89

; --- Semantic palette (Homeplanet.md section 2) -----------------------------
;  The four inks are meanings, not decoration.
INK_SPACE           equ 0               ; empty space
INK_FRIEND          equ 1               ; friendly ships, HUD, text
INK_NEUTRAL         equ 2               ; stars, reference grid, shading
INK_ENEMY           equ 3               ; enemy ships, explosions, alarms

; --- Stack ------------------------------------------------------------------
;  Grows DOWN from the top of the low 16K, into the slack between the end of
;  the code and the bank window. Putting it here rather than just under the
;  code means a stack overflow runs into empty space and gets caught by the
;  build-time margin check, instead of quietly eating the entry point.
STACK_TOP           equ CODE_LIMIT
STACK_SIZE          equ 256             ; reserved margin, enforced in main.asm

    endif
