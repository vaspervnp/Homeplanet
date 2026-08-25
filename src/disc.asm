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
;      after  sprite library  -> staged at #C000, then into bank 4 at #4000
;      after  the stub
;
;  The stub CANNOT live at #4000. It has to page bank 4 into the #4000 window,
;  and the instant it does, the window stops being the RAM the stub is sitting
;  in and the CPU starts fetching sprite data as code. So the stub is
;  assembled at the very top of the file and runs from there; the AMSDOS
;  header carries a separate execution address, so that costs nothing.
;
;  The sprite library has the same problem in reverse: it is the SOURCE of the
;  copy that runs after bank 4 is paged in, so it cannot be sitting in the
;  window at the time. It used to be parked above #8000 for that reason, but
;  a second ship class pushed the file past #A700 -- where AMSDOS keeps its
;  workspace -- and the load corrupted the loader.
;
;  So it goes via SCREEN A instead. #C000-#FFFF is 16K of RAM that nothing
;  needs until sys_boot clears it, it is untouched by the #4000 paging, and it
;  is exactly one bank big. The file stays packed and well clear of AMSDOS.
; ----------------------------------------------------------------------------

    include "equ/hardware.asm"
    include "equ/memmap.asm"

GAME_LOAD           equ #4000           ; where AMSDOS drops the whole file
SPRITE_STAGE        equ #C000           ; screen A, used as scratch during load

;  AMSDOS keeps its workspace from #A700 up. Load past that and the transfer
;  corrupts the very code doing it, which shows up as a disc that boots to a
;  dead machine while `boot_quick` -- which pokes the image straight into RAM
;  -- keeps working perfectly. Assert it rather than rediscover it.
AMSDOS_WORKSPACE    equ #A700

    org GAME_LOAD

game_image:
    incbin "build/home.raw"
game_image_end:

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

    ;  Stage the sprite library in screen A first: it is about to be sitting
    ;  in the window we are going to page out from under it.
    ld hl,sprite_image
    ld de,SPRITE_STAGE
    ld bc,sprite_image_end - sprite_image
    ldir

    ;  Game down to #0040, while bank 1 is still in the window.
    ld hl,game_image
    ld de,CODE_START
    ld bc,game_image_end - game_image
    ldir

    ;  Now swap bank 4 in and fill it from the staged copy, which the paging
    ;  cannot touch.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c

    ld hl,SPRITE_STAGE
    ld de,BANK_WINDOW
    ld bc,sprite_image_end - sprite_image
    ldir

    jp CODE_START

disc_stub_end:

    assert game_image_end - game_image <= CODE_LIMIT - CODE_START, "game image will not fit under #4000"
    assert sprite_image_end - sprite_image <= BANK_WINDOW_SIZE, "sprite library will not fit in a bank"
    assert disc_stub_end < AMSDOS_WORKSPACE, "DISC.BIN loads over AMSDOS's workspace and will corrupt its own loader"

    run disc_stub

    print "DISC.BIN:", disc_stub_end - GAME_LOAD, "bytes, exec at", {hex}disc_stub

    save "DISC.BIN", GAME_LOAD, disc_stub_end - GAME_LOAD, DSK, "build/homeplanet.dsk"
    save "build/disc.raw", GAME_LOAD, disc_stub_end - GAME_LOAD
