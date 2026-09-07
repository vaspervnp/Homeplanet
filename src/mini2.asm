; ============================================================================
;  mini2.asm -- MINI2.BIN's game image: the R-Type run on its own
; ============================================================================
;  See src/mini.asm: the same one line, with MINI_ONLY at 2, which is what
;  boot_after_init hands chase_run as "the run". Everything else is shared.
; ----------------------------------------------------------------------------
MINI_ONLY           equ 2

    include "main.asm"
