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

; ----------------------------------------------------------------------------
;  MIS_TIMER IS IN 50 Hz TICKS, NOT IN GAME FRAMES, and that is the point of
;  this comment rather than a detail of it.
;
;  It counted game frames for the whole life of the campaign, and a game frame
;  is not a fixed length: the rate depends on how many entities are alive, how
;  far out the zoom is, and on whatever the last performance change did. So
;  every wall-clock figure derived from it was a conversion against a frame
;  rate somebody had looked at once -- and every one of them went silently
;  wrong the next time the frame rate moved. It happened THREE TIMES to the
;  attack waves: three minutes became two, two became a minute and a half
;  without a line changing, and a minute had to be re-derived from a fresh
;  measurement. The design owner asked the obvious question -- can it not be
;  measured in something else -- and the answer is yes.
;
;  A tick is 1/50th of a second on a PAL 6128, always. sys_tick_50hz is the
;  free-running counter the interrupt already keeps, so the cost is one
;  subtraction: mis_update adds the number of ticks that have gone by since
;  the last game frame rather than adding one. A word of ticks reaches 21
;  minutes, which is far longer than any mission.
;
;  WHY THE DELTA AND NOT THE COUNTER ITSELF. sys_tick_50hz runs through
;  everything -- the pause, the briefing, the help page, the jump wipe -- and
;  the mission clock must not. mis_update is called only from demo_update's
;  playing path, so accumulating there keeps every one of those exclusions
;  exactly as it was: SPACE still stops the clock along with the battle, which
;  is what a tactical pause is for.
;
;  sys_tick_50hz is a byte and wraps every 5.12 seconds; a game frame is seven
;  to fourteen ticks, so the modulo-256 subtraction is exact by a wide margin.
;  It would take a game frame five seconds long to lose time here, and a game
;  that slow has worse problems.
; ----------------------------------------------------------------------------

;  THIRTY SECONDS for MIS_OBJ_SURVIVE. It was 200 game frames, which was forty
;  seconds at the 5 fps of the day it was written and is twenty-eight at
;  today's 7.1 -- the same drift, in the one constant that already had "TICKS"
;  in its name. Thirty is the round number nearest what mission 8 has actually
;  been asking for lately.
MIS_SURVIVE_TICKS   equ 50 * 30

;  WHAT A JUMP COSTS. The drive is fuelled out of the same treasury the yard
;  spends, so leaving is a purchase and not a formality.
;
;  It is the fourth thing mis_gate asks and it is asked the same way as the
;  other three -- the HUD's JUMP simply does not appear until the RU is there,
;  so a player never presses a key that refuses them.
;
;  A THOUSAND AGAINST ECO_START_RU's 120 AND ECO_RU_MAX's 9999. The number
;  makes the economy compulsory rather than optional: a fleet that never mines
;  cannot leave mission 1, which is a bigger change than it looks -- see the
;  note in tools/balance.py, whose DEFAULT tactic never spends a unit and can
;  no longer finish the campaign at all.
MIS_JUMP_COST       equ 1000

; ----------------------------------------------------------------------------
;  THE DERELICT, and what the campaign can unlock
; ----------------------------------------------------------------------------
;  Section 8 gives the Frigate no unlock condition; this one is the design
;  owner's. From mission 4 a dead VEKHAR FRIGATE is adrift at the edge of the
;  play area, and towing it home with a Salvage Corvette is what teaches the
;  yard to build one. It is reverse-engineering rather than fetching a token,
;  which is what makes it this class and this ship rather than a key in a box.
;
;  IT COMES BACK UNTIL IT IS TAKEN, and only as far as mission 6. Two separate
;  reasons, and the second one is arithmetic rather than taste:
;
;    - Losing a whole class because a briefing was not read is a punishment for
;      not reading rather than for playing badly, and section 1's "what is lost
;      is lost" is already carried by the fleet itself. So three chances.
;    - It cannot come back for ever, because it is a HOSTILE-REGION entity.
;      ENT_ENEMY_MAX is twenty, chosen as the campaign's largest picket (mission
;      7's twelve) plus one whole WAVE_MAX wave. A derelict floating through
;      mission 7 would make that 12 + 1 + 8 = 21, and the ship that did not fit
;      would be the eighth of a wave -- silently, which is the exact failure the
;      partition exists to end. Missions 4, 5 and 6 field 8, 8 and 6, so all
;      three have room to spare. tests/test_campaign.TestEveryPicketFits reads
;      it out of the mission table rather than trusting these two numbers.
;
;  Both are 0-based, like mis_index.
MIS_DERELICT_FROM   equ 3               ; mission 4
MIS_DERELICT_UNTIL  equ 5               ; ...and it is still there in mission 6

;  What the campaign has unlocked, one bit each. It survives a jump because it
;  is not touched by mis_setup, and a power cycle because fleet_disc_save puts
;  it on the disc -- see src/sys/fdc.asm for why it goes in the save block's
;  PAD and why it is tagged.
CAMP_UNLOCK_FRIG_BIT equ 0
CAMP_UNLOCK_FRIGATE  equ 1
;  Every bit that means something today. fleet_disc_load range-checks what it
;  reads against this, because a blank disc and another game's disc both arrive
;  there and the pad is uninitialised bank RAM.
CAMP_UNLOCK_ALL      equ CAMP_UNLOCK_FRIGATE

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

;  WHETHER `J` WOULD WORK RIGHT NOW, recomputed every frame by mis_update.
;
;  It is not the same thing as mis_complete and it must not be latched into
;  it. mis_complete means "this mission's own objective is met" and stays set;
;  leaving also asks that three waves have come and that nothing hostile is
;  still flying, and a wave landing AFTER the objective was met takes the jump
;  away again. A flag folded into mis_complete could not do that -- it would
;  say the jump was available while a wave was on the screen.
;
;  A byte rather than a routine the HUD calls, because phase4_hud_changed
;  compares a shadow to decide whether to repaint: one byte compare a frame
;  against counting the hostile region twice.
mis_leave_ok:       defb 0
mis_failed:         defb 0
mis_saved:          defb 0
mis_timer:          defw 0              ; 50 Hz TICKS since mis_setup; see above

;  What sys_tick_50hz read on the last game frame, so the next one knows how
;  much real time has gone by. Primed wherever mis_timer is zeroed -- without
;  that, the first frame of a mission adds whatever the counter happened to
;  hold, which is up to five seconds of wave clock nobody asked for.
mis_tick_last:      defb 0
mis_desc:           defw 0
mis_src:            defw 0
mis_scan:           defb 0
mis_left:           defb 0

fleet_ptr:          defw 0
fleet_src:          defw 0
fleet_count:        defb 0

;  In the LOW 16K, with mis_index and mis_saved and for the same two reasons:
;  fleet_disc_save and fleet_disc_load are down here and would otherwise be
;  reaching into the bank, and half the suite would have to read it through
;  read_bank4 rather than read_ram. It is one byte; the code that acts on it is
;  all in bank 4.
campaign_unlocks:   defb 0

mis_briefing:       defb 0
mis_wipe:           defb 0

;  The jump wipe -- game/jumpfx.asm, whose CODE is in bank 4 with the rest of
;  what only runs while the game is stopped. These three are here for the same
;  reason mis_index and mis_briefing are: a variable in the bank has to be read
;  through the CPU with the window at rest, and a sweep is exactly the moment a
;  test wants to sample the machine several times a second.
jfx_mode:           defb 0              ; JFX_NONE / JFX_OUT / JFX_IN
jfx_col:            defb 0              ; where the line is, in bytes 0..80
jfx_armed:          defb 0              ; a jump happened; reveal on the way out
mis_text_ptr:       defw 0
mis_text_y:         defb 0
mis_text_left:      defb 0
mis_brief_prompt:   defb "ENTER",0

