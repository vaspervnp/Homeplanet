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
SPRITE_STAGE_MIN    equ #8000           ; first address the #4000 paging spares

;  AMSDOS keeps its workspace from #A700 up. Load past that and the transfer
;  corrupts the very code doing it, which shows up as a disc that boots to a
;  dead machine while `boot_quick` -- which pokes the image straight into RAM
;  -- keeps working perfectly. Assert it rather than rediscover it.
AMSDOS_WORKSPACE    equ #A700

;  MINI.BIN is this file assembled a second time -- see MINI_ONLY in
;  src/main.asm. src/minidisc.asm sets it and includes this; here it only
;  decides which image is wrapped and what the file on the disc is called.
    ifndef MINI_ONLY
MINI_ONLY           equ 0
    endif

    org GAME_LOAD

game_image:
IF MINI_ONLY
    incbin "build/mini/home.raw"
ELSE
    incbin "build/home.raw"
ENDIF
game_image_end:

;  Run-length coded by tools/packsprites.py, which explains the format and
;  why the two streams are separated. It used to be about half size, and that
;  was what kept the file under AMSDOS: uncompressed, DISC.BIN ended at #A66C
;  against a #A700 ceiling -- 148 bytes of headroom.
;
;  IT NO LONGER COMPRESSES ANYTHING, and that is the 3+3+2 repack rather than a
;  fault in the packer. Bank 4 held two sprite libraries and packed to 72%;
;  they are on the disc now and what is left is code and text, which has no
;  runs of #FF/#00 in it -- 6445 bytes go to 6650, so the RLE COSTS 205 bytes.
;  It is left in place because DISC.BIN has about 4500 bytes of headroom and
;  taking it out means deleting the decoder below and a Makefile step to buy
;  4% of that. The day the bank has sprites in it again -- a ninth class that
;  does not fit banks 5-7 -- it pays for itself once more.
sprite_image:
IF MINI_ONLY
    incbin "build/mini/sprites.rle"
ELSE
    incbin "build/sprites.rle"
ENDIF
sprite_image_end:

; ----------------------------------------------------------------------------
;  The stub. Runs from bank 2, which the #4000 paging cannot pull out from
;  under it.
;
;  It has to land above #8000, and with the packed library it does so on its
;  own -- but only just, and that is not a thing to leave to luck. The assert
;  below is the guard: if packing ever improves enough to pull the data back
;  under #8000, the stub follows it into the window it pages out, and the fix
;  is an ORG here to push it up again.
; ----------------------------------------------------------------------------
disc_stub:
    di

    ;  Both ROMs out, Mode 1 in. From here #0000-#3FFF reads as RAM and the
    ;  firmware does not exist -- so no RSTs, and no interrupts until the game
    ;  installs its own handler.
    ld bc,GA_PORT * 256 + GA_GAME_ROMMODE
    out (c),c

    ;  Stage the crunched library in screen A first: it is about to be
    ;  sitting in the window we are going to page out from under it.
    ld hl,sprite_image
    ld de,SPRITE_STAGE
    ld bc,sprite_image_end - sprite_image
    ldir

    ;  Game down to #0040, while bank 1 is still in the window.
    ld hl,game_image
    ld de,CODE_START
    ld bc,game_image_end - game_image
    ldir

    ;  Now swap bank 4 in and unpack into it. The source is in screen A, which
    ;  the #4000 paging does not touch, and the destination is the window.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c

    ;  THE FIRST BYTE SAYS WHETHER IT IS PACKED. tools/packsprites.py takes
    ;  the shorter of the two every build, and since the 3+3+2 repack left no
    ;  sprites in this bank at all the shorter one is the RAW image: what is
    ;  here now is the mission table, the menus and the campaign's code, and
    ;  code has no runs of #FF and #00 in it. Measured, the packer was making
    ;  DISC.BIN 366 bytes bigger and had pushed it over its #A700 ceiling.
    ld hl,SPRITE_STAGE
    ld a,(hl)
    inc hl
    or a
    jr nz,@disc_packed

    ;  Stored: it is already in the interleaved form the blitter reads, so it
    ;  is one copy.
    ld de,BANK_WINDOW
    ld bc,sprite_image_end - sprite_image - 1
    ldir
    jp CODE_START

@disc_packed:
    ;  Masks to the even addresses, data to the odd: the decoder re-weaves
    ;  the two streams as it writes them, so the library lands in exactly the
    ;  interleaved form the blitter reads.
    ld de,BANK_WINDOW
    call unrle_stride2                  ; masks; HL is left on the second stream
    ld de,BANK_WINDOW + 1
    call unrle_stride2                  ; data

    jp CODE_START


; ----------------------------------------------------------------------------
;  unrle_stride2 -- expand one packed stream, writing every OTHER byte
;  In : HL = packed source, DE = destination
;  Out: HL just past this stream's terminator, ready for the next one
;  Uses: everything
;
;  Format is in tools/packsprites.py:
;      00        end
;      01..FD n  that many literal bytes
;      FE   n b  n copies of b
; ----------------------------------------------------------------------------
unrle_stride2:
@unrle_next:
    ld a,(hl)
    inc hl
    or a
    ret z
    cp #FE
    jr z,@unrle_run

    ld b,a
@unrle_literal:
    ld a,(hl)
    inc hl
    ld (de),a
    inc de
    inc de
    djnz @unrle_literal
    jr @unrle_next

@unrle_run:
    ld b,(hl)
    inc hl
    ld a,(hl)
    inc hl
@unrle_repeat:
    ld (de),a
    inc de
    inc de
    djnz @unrle_repeat
    jr @unrle_next

disc_stub_end:

    assert game_image_end - game_image <= CODE_LIMIT - CODE_START, "game image will not fit under #4000"
    assert sprite_image_end - sprite_image <= BANK_WINDOW_SIZE, "sprite library will not fit in a bank"
    assert disc_stub_end < AMSDOS_WORKSPACE, "DISC.BIN loads over AMSDOS's workspace and will corrupt its own loader"
    assert disc_stub >= SPRITE_STAGE_MIN, "the stub is inside the bank window and will page itself out"

    run disc_stub

IF MINI_ONLY
    print "MINI.BIN:", disc_stub_end - GAME_LOAD, "bytes, exec at", {hex}disc_stub

    ;  INTO the same image, after DISC.BIN: -eo is what lets a second save
    ;  add to a .dsk that already exists. The Makefile mints the image fresh
    ;  every build, so the order of the two assemblies is what puts DISC.BIN
    ;  first in the catalogue.
    save "MINI.BIN", GAME_LOAD, disc_stub_end - GAME_LOAD, DSK, "build/homeplanet.dsk"
    save "build/mini/disc.raw", GAME_LOAD, disc_stub_end - GAME_LOAD
ELSE
    print "DISC.BIN:", disc_stub_end - GAME_LOAD, "bytes, exec at", {hex}disc_stub

    save "DISC.BIN", GAME_LOAD, disc_stub_end - GAME_LOAD, DSK, "build/homeplanet.dsk"
    save "build/disc.raw", GAME_LOAD, disc_stub_end - GAME_LOAD
ENDIF
