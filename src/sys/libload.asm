; ============================================================================
;  sys/libload.asm -- the sprite libraries that do not fit in DISC.BIN
; ============================================================================
;  Homeplanet.md section 8 has eight ship classes. A class's sprite library is
;  4320 bytes (six yaw views; see the note in CLAUDE.md about the pre-shift
;  spill byte), so all eight are 33.75 KB -- and DISC.BIN cannot carry them:
;
;      DISC.BIN loads at #4000 and must finish below #A700, where AMSDOS keeps
;      its workspace. That is a 26368-byte ceiling and the file is already
;      25 KB. Even ONE library, RLE-packed, is most of what is left.
;
;  So ALL EIGHT libraries go on the disc as RAW SECTORS, exactly the way the
;  fleet save does, and lib_load reads them straight into banks 5, 6 and 7 at
;  boot -- three, three and two. Section 14's answer to "πολλή διακίνηση
;  δισκέτας" is "ολόκληρη η αποστολή φορτώνεται μία φορά στην αρχή, στις
;  τράπεζες", and this is that: one read, at boot, and the drive is never
;  touched again except to save the fleet.
;
;  It was two a bank until six yaw views made a library 4320 bytes, at which
;  point THREE fit in a 16K window (12960 of 16384) and the two that used to
;  ride inside DISC.BIN -- the interceptor and the frigate -- stopped needing
;  to. What that bought is in CLAUDE.md; the price is that a machine with no
;  disc now has no ship art at all, which is why class_use_fallback paints a
;  stand-in instead of naming one.
;
;  WHERE THEY ARE ON THE DISC
;  --------------------------
;  Three tracks a bank from LIB_TRACK, LIB_SECTORS sectors of each read in
;  order. Not AMSDOS files: a real file needs directory allocation, which is
;  several hundred bytes more than the low 16K has, and the fleet save already
;  made this trade. AMSDOS hands out blocks from track 0 upward and everything
;  on this disc together takes about ten tracks, so track 20 is a long way from
;  anything it would use -- but copy another file on with CP/M and it may land
;  on them.
;
;  Three tracks a bank was already the reservation and the repack did not
;  change it: 26 sectors of 27. What it did change is that all three are now
;  nearly full, so a NINTH class no longer fits in the tracks that are set
;  aside -- it wants a fourth track for one of the banks, or a library packed.
;
;  tools/discbanks.py writes them, and it reads the four equates below out of
;  build/homeplanet.sym rather than having its own copy. Change a number here
;  and the tool follows.
;
;  WHY THEY ARE NOT PACKED
;  -----------------------
;  Because the disc has no ceiling the way DISC.BIN does: 29 free tracks after
;  the files and we need 9. Storing them raw means the sector read IS the load
;  -- no decoder in the low 16K, and no staging buffer, because the controller
;  writes straight into the window. (The bank-4 image is still run through
;  tools/packsprites.py, and now that there is no sprite data left in it the
;  RLE makes it very slightly BIGGER. That is DISC.BIN's business, not this
;  file's, and it is worth about 200 bytes of a file with 4500 spare.)
; ----------------------------------------------------------------------------

;  TWENTY, and it was twelve until MUSIC1.BIN and MUSIC2.BIN went on the disc.
;  These tracks are RAW SECTORS and AMSDOS knows nothing about them: they are
;  not files and they are not in its allocation map, so it hands the same
;  blocks out again to the next file it is asked to write. DISC.BIN, the 16 KB
;  splash and the two music binaries come to about twelve tracks, and
;  MUSIC2.BIN landed on top of bank 5.
;
;  IT DID NOT FAIL. lib_load read its sectors perfectly and set LIB_OK, because
;  the sectors were there and readable -- they just held a music player. That
;  is exactly the failure this file's header warns about, and what caught it
;  was test_each_bank_holds_exactly_what_the_build_put_on_the_disc comparing
;  the bank against build/bank5.raw. A test that only asks whether the load
;  SUCCEEDED cannot see this at all, and the one written alongside the music
;  asked precisely that and passed.
;
;  Twenty leaves about ten tracks of headroom above what is on the disc today,
;  and the libraries end at 28 -- clear of FLEET_TRACK at 39. The 3+3+2 repack
;  did NOT buy any of that back: it fills the same nine tracks more fully
;  rather than needing fewer of them, and the ~4 KB it takes off DISC.BIN is
;  one AMSDOS block, not a track.
LIB_TRACK           equ 20              ; first track of the library area
LIB_TRACKS_PER_BANK equ 4               ; 36 sectors on the disc, of which we use LIB_SECTORS
LIB_BANKS           equ 3               ; banks 5, 6 and 7

;  13312 bytes: THREE 4320-byte libraries and a little padding. It was 23 when
;  a library was 5760 bytes and two went in a bank, and 17 when six yaw views
;  took a quarter off each of them. Twenty-six is what a third one costs, and
;  it is the whole of this repack as far as the loader is concerned -- 78
;  sectors at boot rather than 51, for eight libraries rather than six.
;
;  LIB_TRACKS_PER_BANK was already 3, which is 27 sectors, so 26 still fits
;  and no track moves. The library area is the same nine tracks it always was;
;  what changed is that it is now nearly full rather than two thirds full.
;
;  Twenty-seven more sectors is a real cost on a real 6128 -- about another
;  second of drive at boot -- and it is NOT a measurable one under test:
;  cpcemu resolves the controller's execution phase synchronously, so emulated
;  sector reads are nearly free and timing the suite before and after gives you
;  the machine's load, not the change. Do not go looking for it either way.
;
;  It is not entirely invisible under test, though, and that is worth knowing:
;  it moves the boot by enough emulated time to change which side of a frame
;  boundary everything after it lands on. Two tests that read a running machine
;  at an arbitrary instant started failing on it and neither was about discs.
;
;  The assert in src/main.asm is what stops this being set too low; nothing
;  stops it being set too high except this comment.
;  THIRTY-TWO, WHICH IS THE WINDOW. A fourth track a bank is nine more sectors
;  on the disc and FIVE more in memory: 32 * 512 is 16384, the whole of the
;  #4000 window, and a 33rd would be read on top of screen B. So the fourth
;  track is four ninths used, and src/main.asm asserts the product against
;  BANK_WINDOW_SIZE now -- the "nothing stops it being set too high" of the
;  paragraph above stopped being true the day it nearly was. What it bought
;  is 2560 bytes of bank 7, which is where the words, the tables and, one
;  day, a minigame that runs from there go; banks 5 and 6 read the same five
;  sectors of padding for nothing, because one count is one loop, and fifteen
;  sectors a boot is a third of a second on a real drive.
LIB_SECTORS         equ 32

LIB_FIRST_SECTOR    equ #C1
LIB_LAST_SECTOR     equ #C9


; ----------------------------------------------------------------------------
;  lib_load -- read banks 5, 6 and 7 off the disc
;  Out: CF set if all three arrived; CF clear and bank 4 back if any did not
;  Uses: everything
;
;  Interrupts are off for the whole transfer, for the reason fdc.asm gives:
;  the controller wants a byte every 32 microseconds and our IM 1 handler runs
;  snd_update, which is longer than that.
;
;  The window is left holding BANK 4 whatever happens. Every caller and
;  everything either of them touches assumes that -- see game/shipclass.asm.
; ----------------------------------------------------------------------------
lib_load:
    di
    ;  AMSDOS ran before us and the controller keeps its state across the ROMs
    ;  going out, so anything it left in the result phase would make our first
    ;  command byte land as a result read. Returns at once if nothing is
    ;  pending.
    call fdc_drain_result

    ld a,1
    call fdc_spin

    ld a,GA_BANK_5
    ld (lib_bank),a
    ld a,LIB_TRACK
    ld (lib_next_track),a

@lib_bank_loop:
    ;  The controller writes through (fdc_buf), so the destination bank has to
    ;  be under the window before the first sector arrives, not after.
    ld a,(lib_bank)
    ld c,a
    ld b,GA_PORT
    out (c),c

    ld hl,BANK_WINDOW
    ld (fdc_buf),hl
    ld a,LIB_SECTORS
    ld (lib_left),a
    ld a,(lib_next_track)
    ld (lib_cur_track),a

@lib_track_loop:
    ld a,(lib_cur_track)
    call fdc_seek
    ld a,LIB_FIRST_SECTOR
    ld (fdc_sector),a

@lib_sector_loop:
    ld a,FDC_CMD_READ
    call fdc_sector_rw
    call fdc_transfer_ok                ; EN alone is not a failure -- see there
    jr nc,@lib_failed

    ld hl,lib_left
    dec (hl)
    jr z,@lib_bank_done

    ld hl,fdc_sector
    inc (hl)
    ld a,(hl)
    cp LIB_LAST_SECTOR + 1
    jr c,@lib_sector_loop

    ld hl,lib_cur_track
    inc (hl)
    jr @lib_track_loop

@lib_bank_done:
    ld hl,lib_next_track
    ld a,(hl)
    add a,LIB_TRACKS_PER_BANK
    ld (hl),a
    ld hl,lib_bank
    inc (hl)
    ld a,(hl)
    cp GA_BANK_7 + 1
    jr c,@lib_bank_loop

    call @lib_finish
    scf
    ret

@lib_failed:
    call @lib_finish
    or a                                ; CF clear: no disc, or a bad sector
    ret

@lib_finish:
IF DIAG_DISC
    ;  Everything else the diagnostic wants is already sitting in a variable
    ;  of its own -- lib_bank, lib_cur_track and lib_left are this file's and
    ;  nothing else writes them. These four are not: fleet_disc_load runs a
    ;  few lines after lib_init in demo_init and drives the same controller,
    ;  so by the time the title screen is up they would be the fleet's.
    ;
    ;  Both exits come through here, so a SUCCESSFUL boot is photographed on
    ;  the same terms as a failed one -- which is the point. A panel that only
    ;  appeared when something was wrong could not be told from a panel that
    ;  never appeared.
    ld a,(fdc_sector)
    ld (lib_diag_sector),a
    ld hl,fdc_st0
    ld de,lib_diag_st0
    ld bc,3
    ldir
ENDIF
    xor a
    call fdc_spin
    ;  Bank 4 back under the window before anything else runs -- the title
    ;  screen, the mission table and the fleet buffer are all in it.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ei
    ret


; ----------------------------------------------------------------------------
;  lib_init -- load the libraries, and fall back to stand-ins if they are not
;              there
;  Out: (lib_ok) = 1 if the real art is in memory
;  Uses: everything
; ----------------------------------------------------------------------------
lib_init:
    call lib_load
    jr c,@lib_have_it
    xor a
    ld (lib_ok),a
    jp class_use_fallback
@lib_have_it:
    ld a,1
    ld (lib_ok),a
    ret


; ----------------------------------------------------------------------------
;  bank7_fetch -- copy ONE zero-terminated string out of bank 7
;  In : HL = a string table in bank 7, A = how many strings to step over first
;  Out: bank7_line holds the string; HL points JUST PAST it, ready for the next
;  Uses: everything
;
;  IN THE LOW 16K, AND IT HAS TO BE. The words the stopped-world screens draw
;  -- the briefings, the orders menu's list and the help page's left column --
;  live in bank 7 with the salvage and destroyer libraries, and every one of
;  the three routines that wants them is bank 4 code. None of them can page
;  bank 7 in for itself: the instant it does, the window stops being the RAM it
;  is executing from. So the OUT happens here, with the CPU already running in
;  the low 16K, and bank 4 is back before the RET reaches a return address that
;  is in it. Exactly gfx/sprite.asm's spr_blit_banked, and exactly the trap
;  title_draw_ships fell into when the libraries repacked 3+3+2.
;
;  No DI. The interrupt handler calls snd_update and key_scan and neither reads
;  bank 4 -- which is why mus_update is called from the frame loop and not from
;  the tick. These screens are drawn with the world stopped, so nothing else is
;  looking at the window either.
;
;  Walked to rather than pointed at, for the reason the text has always been:
;  the strings are in order, so sixty pointers would be a hundred and twenty
;  bytes spent to avoid counting zero bytes that are already there.
;
;  IT RETURNS THE CURSOR, and that is what keeps a column of seventeen rows
;  from being quadratic. The briefing seeks -- it wants three lines out of
;  sixty and pays the skip once a line -- but a column draws every string in
;  its table in order, so it passes A=0 and hands back the HL it got. Seventeen
;  rows that would each have re-counted the rows above them count nothing.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  bank7_copy -- BC bytes out of bank 7, wherever they are
;  In : HL = source in bank 7, DE = destination, BC = how many
;  Out: HL and DE past the run, as LDIR leaves them
;  Uses: AF, BC, DE, HL
;
;  THE DESTINATION MUST NOT BE IN THE WINDOW. Bank 4 IS the window while this
;  runs, so a caller that copies into bank 4 writes its bytes back into bank 7
;  on top of the thing it is reading -- which is exactly the trap the briefings
;  fell into, and is why mis_row is in the low 16K.
;
;  The sibling of bank7_fetch, and here for the same reason it is: the OUT has
;  to happen with the CPU already executing in the low 16K, because every
;  caller is bank 4 code. This one carries no terminator, because the enemy
;  layouts it exists for are full of zero bytes.
; ----------------------------------------------------------------------------
bank7_copy:
    ld a,GA_BANK_7
    jr bankn_copy

; ----------------------------------------------------------------------------
;  bank6_copy -- the same, out of bank 6: the mission table, the enemy layouts
;  and the zoom records live there now, so that bank 7 has room for the
;  code that runs from it. Pure copies do not care which bank they come from.
; ----------------------------------------------------------------------------
bank6_copy:
    ld a,GA_BANK_6
    ;  ...and fall into bankn_copy.

; ----------------------------------------------------------------------------
;  bankn_copy -- BC bytes out of bank A, wherever they are
;  In : A = the bank's GA value, HL = source in it, DE = destination, BC = count
; ----------------------------------------------------------------------------
bankn_copy:
    push bc
    ld b,GA_PORT
    ld c,a
    out (c),c
    pop bc
    ldir
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ret


; ----------------------------------------------------------------------------
;  chase_run -- page bank 7 in, run minigame A from it, page bank 4 back
;  In : A = 0 the vortex chase, 1 the run
;  Uses: everything
;
;  The first CODE in a sprite bank, and the whole of why it is legal is in
;  minigame2.md: the chase runs when nothing else does, calls only the low
;  16K, and draws a library that is in the same bank. This is spr_blit_banked's
;  shape -- the OUT happens with the CPU already down here, and bank 4 is back
;  before the RET reaches a return address that is in it.
; ----------------------------------------------------------------------------
chase_run:
    ld bc,GA_PORT * 256 + GA_BANK_7
    out (c),c
    call mini_entry                     ; A = which minigame; see game/minigame.asm
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ret


bank7_fetch:
    ld bc,GA_PORT * 256 + GA_BANK_7
    out (c),c

    or a
    jr z,@b7_at_text
    ld b,a
@b7_skip_string:
    ld a,(hl)
    inc hl
    or a
    jr nz,@b7_skip_string
    djnz @b7_skip_string                ; ...one whole string per pass
@b7_at_text:

    ;  C is the room left in the buffer. A bound rather than a comment: the
    ;  text is authored in another file and a line long enough to run past the
    ;  end would write over whatever follows, on a screen that is drawn before
    ;  anyone could see what went wrong.
    ld de,bank7_line
    ld c,B7_BUF_SIZE
@b7_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    dec c
    jr z,@b7_full
    or a
    jr nz,@b7_copy
    jr @b7_done

@b7_full:
    ;  Out of room. Terminate what there is, so the drawing walks off the end
    ;  of a string rather than off the end of the buffer -- and then finish
    ;  stepping over the rest of it, or the cursor this hands back would be
    ;  stranded in the middle of a string and every row after it would be
    ;  garbage rather than merely short.
    dec de
    xor a
    ld (de),a
@b7_rest:
    ld a,(hl)
    inc hl
    or a
    jr nz,@b7_rest

@b7_done:
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ret


; ============================================================================
;  State
; ============================================================================
;  NOT lib_track: RASM is case-insensitive, so a variable by that name and the
;  LIB_TRACK equate above are the same symbol and the build stops with "there
;  is already an alias with the same name".
lib_bank:           defb 0
lib_next_track:     defb 0
lib_cur_track:      defb 0
lib_left:           defb 0
lib_ok:             defb 0

IF DIAG_DISC
;  The four bytes of the last library read, kept because the fleet load that
;  follows would otherwise have them. lib_bank, lib_cur_track and lib_left
;  need no copy: nothing but this file touches them.
lib_diag_sector:    defb 0
lib_diag_st0:       defb 0
lib_diag_st1:       defb 0
lib_diag_st2:       defb 0
ENDIF
