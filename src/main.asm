; ============================================================================
;  HOMEPLANET -- Amstrad CPC 6128, Mode 1
; ============================================================================
;  Build with:  make          (see CLAUDE.md)
;
;  Phase 4: entities and squadrons. A fleet flies in formation while the
;  camera orbits; the player carves it into squadrons from the keyboard.
; ----------------------------------------------------------------------------

    include "equ/hardware.asm"
    include "equ/memmap.asm"

    org CODE_START
    run game_main

; ============================================================================
;  Entry point
; ============================================================================
game_main:
    di
    ld sp,STACK_TOP                     ; before any CALL, obviously
    call sys_boot                       ; one-way: firmware is gone after this

    call demo_init

@frame_loop:
    call demo_update                    ; draw into the back buffer
    call demo_wait_frame                ; hold the loop to 4 VSYNCs = 12.5 fps
    call scr_wait_vsync
    call scr_flip                       ; back becomes front
    jr @frame_loop


; ============================================================================
;  Subsystems
; ============================================================================
    include "sys/boot.asm"
    include "sys/irq.asm"
    include "sys/screen.asm"
    include "sys/keyboard.asm"
    include "sys/sound.asm"
    include "sys/fdc.asm"
    include "math/mul.asm"
    include "math/cam.asm"
    include "math/proj.asm"
    include "gfx/sprite.asm"
    include "gfx/text.asm"
    include "gfx/line.asm"
    include "gfx/grid.asm"
    include "game/entity.asm"
    include "game/squad.asm"
    include "game/shipclass.asm"
    include "game/formation.asm"
    include "game/order.asm"
    include "game/combat.asm"
    include "game/economy.asm"
    include "game/mission.asm"
    include "game/help.asm"
    include "demo/phase4.asm"

; ----------------------------------------------------------------------------
;  Generated lookup tables. Must come last: they are page-aligned and would
;  otherwise push the hand-written code around on every regeneration.
; ----------------------------------------------------------------------------
    include "gen/tables.asm"

code_end:

; ----------------------------------------------------------------------------
;  Table layout invariants.
;
;  The lookup routines index these tables by page register -- qsq_f does
;  `inc h : inc h` to cross from the low plane to the high one, scr_line_addr
;  does a single `inc h`. That only works if the generator lays them out
;  exactly so. Check it here rather than at the point of use, because RASM
;  evaluates ASSERT where it stands and the tables are included last.
; ----------------------------------------------------------------------------
    assert qsq_hi == qsq_lo + 512,          "quarter-square planes are not 512 bytes apart"
    assert scr_line_hi == scr_line_lo + 256, "screen line planes are not on consecutive pages"
    assert (qsq_lo & 255) == 0,             "qsq_lo is not page aligned"
    assert (scr_line_lo & 255) == 0,        "scr_line_lo is not page aligned"
    assert (sin7 & 255) == 0,               "sin7 is not page aligned"
    assert (recip & 255) == 0,              "recip is not page aligned"

; ----------------------------------------------------------------------------
;  The low 16K is the whole world below the bank window. If we ever spill past
;  #4000 the next thing we would overwrite is paged sprite data, and the
;  symptom would be baffling. Fail the build instead -- and leave room for the
;  stack, which is growing down from #4000 to meet us.
; ----------------------------------------------------------------------------
    assert code_end < CODE_LIMIT - STACK_SIZE, "code + tables overflow into the stack"

    print "code+tables:", {hex}CODE_START, "..", {hex}code_end, " free:", CODE_LIMIT - STACK_SIZE - code_end

; ============================================================================
;  Output
; ============================================================================
;  A headerless blob only. src/disc.asm wraps it in the relocating stub that
;  actually gets it to #0040 -- see the long explanation there.
; ----------------------------------------------------------------------------
    save "build/home.raw", CODE_START, code_end - CODE_START


; ============================================================================
;  Bank 4 -- the sprite library
; ============================================================================
;  Assembled at #4000 but NOT part of the low-memory image: src/disc.asm pages
;  extended bank 4 into the window and copies this there at load time, so the
;  labels below resolve to bank-4 addresses and the low 16K keeps its space.
;
;  Nothing pages this back out, so #4000-#7FFF is the sprite library for the
;  whole run. Missions that need different libraries will page banks 5-7.
; ----------------------------------------------------------------------------
    org BANK_WINDOW
bank4_start:
    include "gen/spr_interceptor.asm"
    include "gen/spr_frigate.asm"
    include "game/campaign.asm"
    include "game/helptext.asm"
;  The title screen RUNS from the bank. Nothing pages bank 4 out, so #4000
;  upwards is ordinary executable RAM -- and this is code that runs once,
;  before the first mission, so it has no business competing for the low 16K
;  that everything in the frame loop has to share.
    include "gfx/bigtext.asm"
    include "game/title.asm"
    include "game/titletext.asm"
bank4_end:

; ----------------------------------------------------------------------------
;  Uninitialised bank storage, deliberately BELOW the save above.
;
;  The fleet between missions -- section 10 calls it FLEET.DAT. It has no
;  starting contents, so putting it inside the saved image would add its 960
;  bytes to DISC.BIN for nothing, and DISC.BIN has to finish below #A700
;  where AMSDOS keeps its workspace. That ceiling is close now.
; ----------------------------------------------------------------------------
;  The header goes in front of the fleet inside the same block, padded out to
;  a whole number of sectors, so a save is two 512-byte writes from one
;  address rather than a gather -- which is what keeps the FDC code small
;  enough to fit what is left of the low 16K.
fleet_block:
    defs FLEET_HDR_SIZE, 0              ; magic, magic, mission index, count
fleet_buffer:
    defs ENT_MAX * ENT_SIZE, 0
    defs FLEET_BLOCK_SIZE - FLEET_HDR_SIZE - ENT_MAX * ENT_SIZE, 0
bank4_limit:

    assert fleet_buffer == fleet_block + FLEET_HDR_SIZE, "the fleet must follow its header"
    assert bank4_limit - fleet_block == FLEET_BLOCK_SIZE, "the save block is not whole sectors"
    assert bank4_limit <= BANK_WINDOW + BANK_WINDOW_SIZE, "bank 4 contents overflow the window"

;  The title is sized to the screen rather than centred on it: ten glyphs at
;  TXT_BIG_W_BYTES is exactly the 80-byte line. Checked here rather than beside
;  txt_big because ASSERT is evaluated where it stands and the strings are in
;  the bank, which is included further down than the code that draws them.
    assert (title_credit - title_text - 1) * TXT_BIG_W_BYTES == SCR_BYTES_PER_LINE, "the title no longer spans the screen"

    print "bank 4:", {hex}BANK_WINDOW, "..", {hex}bank4_limit, " image:", bank4_end - BANK_WINDOW, " free:", BANK_WINDOW + BANK_WINDOW_SIZE - bank4_limit

    save "build/sprites.raw", BANK_WINDOW, bank4_end - BANK_WINDOW
