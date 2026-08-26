; ============================================================================
;  sys/libload.asm -- the sprite libraries that do not fit in DISC.BIN
; ============================================================================
;  Homeplanet.md section 8 has eight ship classes. A class's sprite library is
;  5.62 KB (see the note in CLAUDE.md about the pre-shift spill byte), so all
;  eight are 45 KB -- and DISC.BIN cannot carry them:
;
;      DISC.BIN loads at #4000 and must finish below #A700, where AMSDOS keeps
;      its workspace. That is a 26368-byte ceiling and the file is already
;      24183 bytes. Even ONE more library, RLE-packed, is 3746 bytes against
;      2185 of headroom.
;
;  So six of the eight libraries go on the disc as RAW SECTORS, exactly the
;  way the fleet save does, and lib_load reads them straight into banks 5, 6
;  and 7 at boot. Section 14's answer to "πολλή διακίνηση δισκέτας" is
;  "ολόκληρη η αποστολή φορτώνεται μία φορά στην αρχή, στις τράπεζες", and
;  this is that: one read, at boot, and the drive is never touched again
;  except to save the fleet.
;
;  WHERE THEY ARE ON THE DISC
;  --------------------------
;  Three tracks a bank from LIB_TRACK, LIB_SECTORS sectors of each read in
;  order. Not AMSDOS files: a real file needs directory allocation, which is
;  several hundred bytes more than the low 16K has, and the fleet save already
;  made this trade. AMSDOS hands out blocks from track 0 upward and DISC.BIN
;  takes six tracks, so track 12 is a long way from anything it would use --
;  but copy another file onto this disc with CP/M and it may land on them.
;
;  tools/discbanks.py writes them, and it reads the four equates below out of
;  build/homeplanet.sym rather than having its own copy. Change a number here
;  and the tool follows.
;
;  WHY THEY ARE NOT PACKED
;  -----------------------
;  The bank-4 library is RLE-packed because it lives in a file with a hard
;  ceiling. These do not: the disc has 29 free tracks after DISC.BIN and needs
;  9. Storing them raw means the sector read IS the load -- no decoder in the
;  low 16K, which has 512 bytes to its name, and no staging buffer, because
;  the controller writes straight into the window.
; ----------------------------------------------------------------------------

LIB_TRACK           equ 12              ; first track of the library area
LIB_TRACKS_PER_BANK equ 3               ; 27 sectors, of which we use LIB_SECTORS
LIB_BANKS           equ 3               ; banks 5, 6 and 7
LIB_SECTORS         equ 23              ; 11776 bytes: two 5760-byte libraries

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
    ld a,(fdc_st0)
    and #C0                             ; ST0 bits 7-6: 00 is "finished normally"
    jr nz,@lib_failed

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
