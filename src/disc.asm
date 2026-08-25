; ============================================================================
;  disc.asm -- DISC.BIN, the only file the user ever runs
; ============================================================================
;  The game runs at #0040, and that is not negotiable: two 16K screens at
;  #8000 and #C000 plus the 16K bank window at #4000 leave nowhere else.
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
;  AMSDOS in the normal way; a stub switches the ROMs out and moves everything
;  into place itself.
;
;  Layout of the file, and why
;  ---------------------------
;      #4000  game image      -> copied down to #0040
;      #8000  sprite library  -> copied into extended bank 4 at #4000
;      after  the stub
;
;  The stub CANNOT live at #4000 like it used to. It now has to page bank 4
;  into the #4000 window, and the instant it does, the window stops being the
;  RAM the stub is sitting in and the CPU starts fetching sprite data as code.
;  So the stub is assembled at the top of the file, above #8000, in bank 2 --
;  which the #4000 paging does not touch. The AMSDOS header carries a separate
;  execution address, so starting there costs nothing.
;
;  The sprite library has to sit above #8000 for the same reason: it is the
;  SOURCE of the copy that runs after bank 4 is paged in, so it must live
;  somewhere the paging leaves alone. Hence the gap between the two images.
;  It costs a few KB of zeros in a file on a 178 KB-free disc.
;
;  #8000-#BFFF is screen B, so both the library and the stub are sitting in a
;  screen buffer while this runs. That is fine: sys_boot clears both screens,
;  and by then the copy is long done.
; ----------------------------------------------------------------------------

    include "equ/hardware.asm"
    include "equ/memmap.asm"

GAME_LOAD           equ #4000           ; where AMSDOS drops the game image
SPRITE_LOAD         equ #8000           ; above the bank window, so paging spares it

    org GAME_LOAD

game_image:
    incbin "build/home.raw"
game_image_end:

    org SPRITE_LOAD

sprite_image:
    incbin "build/sprites.raw"
sprite_image_end:

; ----------------------------------------------------------------------------
;  The stub. Runs from bank 2, which the #4000 paging cannot pull out from
;  under it.
; ----------------------------------------------------------------------------
disc_stub:
    di

    ;  Both ROMs out, Mode 1 in. From here #0000-#3FFF reads as RAM and the
    ;  firmware does not exist -- so no RSTs, and no interrupts until the game
    ;  installs its own handler.
    ld bc,GA_PORT * 256 + GA_GAME_ROMMODE
    out (c),c

    ;  Game down to #0040, while bank 1 is still in the window.
    ld hl,game_image
    ld de,CODE_START
    ld bc,game_image_end - game_image
    ldir

    ;  Now swap bank 4 into the window and fill it. Everything this reads from
    ;  is above #8000, so the swap cannot pull the ground away.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c

    ld hl,sprite_image
    ld de,BANK_WINDOW
    ld bc,sprite_image_end - sprite_image
    ldir

    jp CODE_START

disc_stub_end:

    assert game_image_end - game_image <= CODE_LIMIT - CODE_START, "game image will not fit under #4000"
    assert game_image_end <= SPRITE_LOAD, "game image runs into the sprite library"
    assert sprite_image_end - sprite_image <= BANK_WINDOW_SIZE, "sprite library will not fit in a bank"

    run disc_stub

    print "DISC.BIN:", disc_stub_end - GAME_LOAD, "bytes, exec at", {hex}disc_stub

    save "DISC.BIN", GAME_LOAD, disc_stub_end - GAME_LOAD, DSK, "build/homeplanet.dsk"
    save "build/disc.raw", GAME_LOAD, disc_stub_end - GAME_LOAD
