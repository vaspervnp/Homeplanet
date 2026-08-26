; ============================================================================
;  game/mission.asm -- the campaign's equates and state (section 10)
; ============================================================================
;  THE CODE IS IN game/campaignrun.asm, WHICH IS IN BANK 4. A mission is set
;  up once, checked once a frame and torn down on a jump; none of that happens
;  with a foreign bank under the window, and all of it was competing for a low
;  16K that had 512 bytes. The variables below stayed, because the tests read
;  mis_index, mis_complete and mis_briefing constantly and a bank variable has
;  to be read through the CPU rather than out of base RAM.
;
;  Eight missions, and the fleet carries between them. That carrying IS the
;  game: "ό,τι επιβιώνει σε μια αποστολή ξεκινά την επόμενη. Ό,τι χάνεται,
;  χάνεται οριστικά."
;
;      J   jump to the next mission -- only once the objective is met, which
;          is what section 9's "όταν επιτρέπεται" means
;
;  A mission is a descriptor in bank 4: a name, where the enemy is, where the
;  resources are, and what winning looks like. Adding a mission is data.
;
;  WHERE THE FLEET IS KEPT
;  -----------------------
;  In bank 4 between missions, and on the DISC across a power cycle. The two
;  are the same block: fleet_save packs the survivors into the bank, and
;  fleet_disc_save puts that block on the disc on the way out of a jump.
;
;  Section 11 wants the firmware brought back "on the screens between
;  missions" to reach the drive, and that cannot be done -- the memory map
;  puts screen B at #8000-#BFFF, right on top of AMSDOS's workspace at #A700,
;  so the moment the game clears its second screen the firmware is gone for
;  good. src/sys/fdc.asm drives the uPD765 itself instead.
; ----------------------------------------------------------------------------

MIS_COUNT           equ 8

;  Descriptor layout, all of it in bank 4.
MIS_NAME            equ 0               ; 12 bytes, zero-terminated
MIS_ENEMY_COUNT     equ 12
MIS_ENEMY_PTR       equ 13              ; -> 6-byte positions
MIS_PATCH_COUNT     equ 15
MIS_PATCH_PTR       equ 16              ; -> 8-byte patches
MIS_OBJECTIVE       equ 18
MIS_TEXT            equ 19            ; index into mission_text_table
MIS_SIZE            equ 20

;  What winning looks like.
MIS_OBJ_CLEAR       equ 0               ; destroy every enemy
MIS_OBJ_SURVIVE     equ 1               ; still have a Mothership after a while
MIS_OBJ_ARRIVE      equ 2               ; nothing to fight; just be there

MIS_SURVIVE_TICKS   equ 200             ; game frames for MIS_OBJ_SURVIVE

;  The briefing screen (section 10). Three lines, and the tone the design asks
;  for: "λίγο κείμενο, πολλή σιωπή".
BRIEF_LINES         equ 3
BRIEF_X             equ 8
BRIEF_TITLE_Y       equ 60
BRIEF_TEXT_Y        equ 84
BRIEF_LINE_STEP     equ 12

; ============================================================================
;  State
; ============================================================================
mis_index:          defb 0              ; 0-based; the HUD shows it plus one
mis_complete:       defb 0
mis_failed:         defb 0
mis_saved:          defb 0
mis_timer:          defw 0
mis_desc:           defw 0
mis_src:            defw 0
mis_scan:           defb 0
mis_left:           defb 0

fleet_ptr:          defw 0
fleet_src:          defw 0
fleet_count:        defb 0

mis_briefing:       defb 0
mis_wipe:           defb 0
mis_text_ptr:       defw 0
mis_text_y:         defb 0
mis_text_left:      defb 0
mis_brief_prompt:   defb "ENTER",0

