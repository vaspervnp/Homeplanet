; ============================================================================
;  minidisc.asm -- MINI.BIN, wrapped for AMSDOS exactly as DISC.BIN is
; ============================================================================
;  See src/mini.asm. This is src/disc.asm with MINI_ONLY set, so the loader
;  stub is the same stub and only the image it carries and the name on the
;  disc differ.
; ----------------------------------------------------------------------------
MINI_ONLY           equ 1

    include "disc.asm"
