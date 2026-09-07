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

;  LZ-packed by tools/lzpack.py, which explains the format. Both images are:
;  the file's ceiling was hit with 23 bytes to spare after every data lever
;  in CLAUDE.md's list had been pulled, and this is the code lever -- the low
;  16K packs to about 71% and bank 4 to about 83%, some 5,900 bytes, for a
;  sixty-byte decoder in a stub that is thrown away once the game runs.
game_image:
IF MINI_ONLY == 2
    incbin "build/mini2/home.lz"
ELSE
IF MINI_ONLY
    incbin "build/mini/home.lz"
ELSE
    incbin "build/home.lz"
ENDIF
ENDIF
game_image_end:

;  The bank-4 image, packed the same way. (It was run-length coded by a
;  tools/packsprites.py that is gone now: RLE was measured making this image
;  BIGGER once the sprite libraries left it for the disc, and the STORED
;  fallback it grew was the whole of what the file carried for a long time.)
sprite_image:
IF MINI_ONLY == 2
    incbin "build/mini2/sprites.lz"
ELSE
IF MINI_ONLY
    incbin "build/mini/sprites.lz"
ELSE
    incbin "build/sprites.lz"
ENDIF
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

    ;  Stage the packed bank-4 image in screen A first: it is about to be
    ;  sitting in the window we are going to page out from under it.
    ld hl,sprite_image
    ld de,SPRITE_STAGE
    ld bc,sprite_image_end - sprite_image
    ldir

    ;  Game down to #0040, while bank 1 is still in the window. The packed
    ;  image sits above its own destination and the ROMs are out, so the
    ;  decoder's back-references read the RAM it has just written.
    ld hl,game_image
    ld de,CODE_START
    call lz_unpack

    ;  Now swap bank 4 in and unpack into it. The source is in screen A, which
    ;  the #4000 paging does not touch, and the destination is the window.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ld hl,SPRITE_STAGE
    ld de,BANK_WINDOW
    call lz_unpack

    jp CODE_START


; ----------------------------------------------------------------------------
;  lz_unpack -- expand one stream from tools/lzpack.py
;  In : HL = packed source, DE = destination
;  Out: HL just past the stream's end marker, DE just past the output
;  Uses: everything
;
;  The format, from the tool:
;      0nnnnnnn  b...        n+1 literal bytes
;      10llllll  o           l+2 bytes from o+1 back
;      11llllll  o_lo o_hi   l+3 bytes from o back; o = 0 is the end
;  and when the six length bits are all set one more byte, between the
;  token and the offset, is added to the length. Matches may overlap their
;  own output, which LDIR copies forward and gets right.
; ----------------------------------------------------------------------------
lz_unpack:
@lz_loop:
    ld a,(hl)
    inc hl
    bit 7,a
    jr nz,@lz_match

    inc a                               ; 1..128 literals
    ld c,a
    ld b,0
    ldir
    jr @lz_loop

@lz_match:
    ld b,a                              ; the token, for bit 6 below
    and #3F
    ld c,a
    cp #3F
    jr nz,@lz_len_short
    ld a,(hl)                           ; the extra length byte
    inc hl
    add a,c
    ld c,a
    jr nc,@lz_len_short
    ld a,b
    ld b,1                              ; the length carried into B...
    jr @lz_len_long
@lz_len_short:
    ld a,b
    ld b,0                              ; ...or did not
@lz_len_long:
    inc bc                              ; +2 for a short match
    inc bc
    bit 6,a
    jr z,@lz_off_short
    inc bc                              ; +3 for a long one
    ld a,(hl)
    inc hl
    push hl
    ld h,(hl)                           ; HL = the 16-bit offset
    ld l,a
    ld a,h
    or l
    jr z,@lz_end
    jr @lz_copy
@lz_off_short:
    ld a,(hl)
    push hl
    ld l,a
    ld h,0
    inc hl                              ; HL = the 8-bit offset + 1
@lz_copy:
    ex de,hl                            ; HL = destination, DE = offset
    push hl
    or a
    sbc hl,de                           ; HL = destination - offset
    pop de
    ldir
    pop hl
    inc hl                              ; past the offset's last byte
    jr @lz_loop

@lz_end:
    pop hl
    inc hl
    ret

disc_stub_end:

    assert game_image_end - game_image <= CODE_LIMIT - CODE_START, "game image will not fit under #4000"
    assert sprite_image_end - sprite_image <= BANK_WINDOW_SIZE, "sprite library will not fit in a bank"
    assert disc_stub_end < AMSDOS_WORKSPACE, "DISC.BIN loads over AMSDOS's workspace and will corrupt its own loader"
    assert disc_stub >= SPRITE_STAGE_MIN, "the stub is inside the bank window and will page itself out"

    run disc_stub

IF MINI_ONLY == 2
    print "MINI2.BIN:", disc_stub_end - GAME_LOAD, "bytes, exec at", {hex}disc_stub
    save "MINI2.BIN", GAME_LOAD, disc_stub_end - GAME_LOAD, DSK, "build/homeplanet.dsk"
    save "build/mini2/disc.raw", GAME_LOAD, disc_stub_end - GAME_LOAD
ELSE
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
ENDIF
