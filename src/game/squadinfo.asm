; ============================================================================
;  squadinfo.asm -- `I`: what the selected squadron is made of (the low half)
; ============================================================================
;  The layout, and the one byte the frame loop and the tests read. The CODE is
;  in game/squadinforun.asm, in bank 4.
;
;  How many ships, of what class, and what state their hulls are in. One row
;  per class that is PRESENT, then a total.
;
;  It is the fourth screen to work like the mission briefing and shares the
;  same two obligations: repaint EVERY frame, because the display page-flips
;  and a screen painted once alternates with whatever the other buffer still
;  holds; and set mis_wipe on the way out, because it covers the tactical area
;  without recording a dirty rectangle for any of it.
;
;  IT USED TO BE IN THE LOW 16K ENTIRELY, and said so at length: by the rule in
;  CLAUDE.md it belonged in the bank, because it only ever runs while the game
;  is stopped -- and bank 4 had 235 bytes left and this is over four hundred,
;  so arithmetic overruled the principle. That is the day the file predicted:
;  the bank has thousands free and the low 16K is paying for a fleet twice the
;  size, so the four hundred bytes went across.
;
;  The split is game/order.asm's and game/tutorial.asm's: DATA down here so a
;  test can use read_ram, CODE up there because it runs on a keypress.
;
;  NOTHING IS CACHED AND NOTHING IS COUNTED INCREMENTALLY. The tally walks the
;  entity table once per class, eight times a frame, which is the same
;  reasoning that makes squad_count derived: a running total drifts the moment
;  ships start dying, and this page runs with the world stopped, so the time
;  is free. Eight walks of the table buys not one byte of state.
; ----------------------------------------------------------------------------


INFO_TITLE_Y        equ 8
INFO_BODY_Y         equ 30
INFO_STEP           equ 12
INFO_TOTAL_GAP      equ 8               ; a blank line's worth, above the total

INFO_NAME_X         equ 4               ; x is in BYTES: 4 pixels each
INFO_NUM_X          equ 22              ; the squadron number, after the title
INFO_FORM_X         equ 28              ; ...and its formation beside that
INFO_COUNT_X        equ 34
INFO_PCT_X          equ 46
INFO_PROMPT_X       equ 58              ; beside the title, as on the help page


;  Whether the page is up. The one byte of this feature the frame loop reads.
info_shown:         defb 0
