; ============================================================================
;  disc.asm -- DISC.BIN, the only file the user ever runs
; ============================================================================
;  The game runs at #0040, and that is not negotiable: two 16K screens at
;  #8000 and #C000 plus the 16K bank window at #4000 leave nothing else.
;
;  But #0000-#3FFF is shadowed by the lower ROM. Writes go to RAM, so AMSDOS
;  can LOAD there quite happily -- it is the JP that kills you, because the
;  CPU fetches firmware bytes instead of your code. A program that simply
;  loads at #0040 and autoruns looks like it hangs.
;
;  The obvious fix is a stub that calls CAS IN OPEN to pull the game in. It
;  does not work: by the time a binary started with RUN" is executing, the
;  CAS jumpblock has been handed back to the cassette manager, so the stub
;  sits there printing "Press PLAY then any key" forever.
;
;  So we do not ask the firmware for anything. One file, loaded at #4000 by
;  AMSDOS in the normal way; the stub at its head switches the ROMs out and
;  block-copies the game down to #0040 itself. Source and destination do not
;  overlap, and the stub is above the destination, so nothing eats itself.
; ----------------------------------------------------------------------------

    include "equ/hardware.asm"
    include "equ/memmap.asm"

LOADER_ORG          equ #4000

    org LOADER_ORG
    run disc_stub

disc_stub:
    di

    ; Both ROMs out, Mode 1 in. From here on #0000-#3FFF reads as RAM and the
    ; firmware does not exist -- so no RSTs, and no interrupts until the game
    ; has installed its own handler.
    ld bc,GA_PORT * 256 + GA_GAME_ROMMODE
    out (c),c

    ld hl,game_image
    ld de,CODE_START
    ld bc,game_image_end - game_image
    ldir

    jp CODE_START

; ----------------------------------------------------------------------------
;  The assembled game, verbatim. Built first; see the Makefile.
; ----------------------------------------------------------------------------
game_image:
    incbin "build/home.raw"
game_image_end:

    assert game_image_end - game_image <= CODE_LIMIT - CODE_START, "game image will not fit under #4000"

    print "DISC.BIN:", game_image_end - LOADER_ORG, "bytes"

    save "DISC.BIN", LOADER_ORG, game_image_end - LOADER_ORG, DSK, "build/homeplanet.dsk"
    save "build/disc.raw", LOADER_ORG, game_image_end - LOADER_ORG
