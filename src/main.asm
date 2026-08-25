; ============================================================================
;  HOMEPLANET -- Amstrad CPC 6128, Mode 1
; ============================================================================
;  Build with:  make          (see CLAUDE.md)
;
;  Phases 2 and 3: masked sprite blitting. A squadron of interceptors sits in
;  3D while the camera orbits, each picking its yaw view and size tier.
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
    include "math/mul.asm"
    include "math/cam.asm"
    include "math/proj.asm"
    include "gfx/sprite.asm"
    include "demo/phase3.asm"

; ----------------------------------------------------------------------------
;  Sprite data. Only one class fits under #4000 alongside the code and
;  tables; three would be 16.9 KB. Multi-class needs the #4000 bank window.
; ----------------------------------------------------------------------------
    include "gen/spr_interceptor.asm"

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
