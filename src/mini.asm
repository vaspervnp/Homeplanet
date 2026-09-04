; ============================================================================
;  mini.asm -- MINI.BIN's game image: the vortex chase on its own
; ============================================================================
;  One line of substance. Everything is in src/main.asm behind IF MINI_ONLY,
;  so the chase that ships in MINI.BIN is byte for byte the chase that ships
;  in the game -- there is no second copy of anything to drift. See the
;  MINI_ONLY note at the top of main.asm for what the build does differently.
; ----------------------------------------------------------------------------
MINI_ONLY           equ 1

    include "main.asm"
