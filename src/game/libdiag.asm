; ============================================================================
;  game/libdiag.asm -- what the disc actually said, on the screen
; ============================================================================
;  TURN IT OFF WITH `DIAG_DISC equ 0` IN src/main.asm. One edit; this file
;  stops being included and every capture site in sys/fdc.asm and
;  sys/libload.asm compiles away with it.
;
;  WHY IT EXISTS
;  -------------
;  The eight ship classes come up as solid white boxes on Retro Virtual
;  Machine. White boxes are class_use_fallback's stand-in, and the only way to
;  reach it is lib_load returning CF clear -- so the sprite libraries are not
;  being read off the disc on real hardware. Under cpcemu they are, every
;  time, on both boot paths, with 521 tests agreeing.
;
;  That disagreement cannot be resolved by looking harder at the emulator.
;  cpcemu's controller resolves its execution phase synchronously, the instant
;  the last command byte is written, and never runs out of patience -- so
;  every timing assumption this code makes is one cpcemu will agree with
;  whether or not a real uPD765 would. Two fixes have been reasoned out from
;  the datasheet and shipped, and the boxes are still there. Guessing a third
;  time is not a plan.
;
;  So: make the machine say it. lib_load knows which bank it was filling,
;  which track and sector it asked for, how many sectors had already arrived
;  and what the controller replied -- and it threw all of it away on the way
;  to `jr @lib_failed`. It does not any more.
;
;  WHAT THE FIVE LINES MEAN
;  ------------------------
;      DISC DIAG  LIB n
;          n=1 the libraries loaded and the art on screen is real.
;          n=0 lib_load failed and every ship is a white box.
;
;      BANK n  TRK nn  SEC xx  DONE nn
;          The bank being filled when it stopped (5, 6 or 7 -- and 8 on a
;          clean run, meaning it got past the last one), the track and the
;          sector of the last read attempted, and how many of LIB_SECTORS had
;          already arrived IN THAT BANK. DONE is the decisive number:
;            0  -- the very first read of that bank failed
;            9 or 18 -- it failed on the first sector after a track advance
;            26 -- that bank finished (so on a clean run every field reads
;                  BANK 8, DONE 26)
;            anything else -- it failed part way along a track
;
;      ST0 xx  ST1 xx  ST2 xx
;          The last read's result bytes, in hex. ST0 bits 7-6 are the
;          interesting ones: 00 finished normally, 01 finished abnormally,
;          10 the command was invalid, 11 the drive changed state. ST1 is why:
;            bit 0 (01) missing address mark
;            bit 1 (02) write protected
;            bit 2 (04) no data -- the sector was not found on this track
;            bit 4 (10) OVERRUN -- we did not feed the controller fast enough
;            bit 5 (20) data error, a CRC failure
;            bit 7 (80) end of cylinder
;          ST2 bit 4 (10) is "wrong cylinder": the sector's own ID said a
;          different track from the one the command carried, which is what a
;          seek that has not finished looks like from inside a read.
;          ST0 = 80 means the command was rejected outright and ST1/ST2 are
;          left over from the seek before it -- ignore them in that case.
;
;      SEEK FAIL nn  ST0 xx
;          How many seeks timed out over the whole boot, and the ST0 the last
;          one gave up on. Non-zero here and the read failures downstream are
;          a consequence, not the cause.
;
;      FLEET n  ST0 xx  ST1 xx  ST2 xx
;          The fleet block's own transfer, which is the SAME fdc_seek and the
;          SAME fdc_sector_rw against track 39. On the title screen this is
;          the boot-time LOAD; under a briefing after a jump it is the SAVE.
;          n=1 worked, n=2 failed, n=0 it never ran.
;
;  A LOAD THAT WORKS BESIDE A LIBRARY THAT DOES NOT is the most useful thing
;  this can say: it is two sectors against seventy-eight, one seek against
;  nine, and one spin-up against a drive that has been running for a second
;  and a half. Whichever of those the difference is, it is not "the FDC code
;  cannot talk to the controller at all".
;
;  It is in bank 4 because it only ever runs with the game stopped -- see the
;  one rule in game/shipclass.asm. The variables it reads are all in the low
;  16K, where lib_load and fdc.asm put them, and it reads them with the window
;  at rest like everything else in here.
; ----------------------------------------------------------------------------

DIAG_STEP           equ 10              ; scanlines between rows
DIAG_ROWS           equ 5
DIAG_W_BYTES        equ 58              ; the widest row is 56; one to spare
DIAG_TITLE_Y        equ 54              ; on the title screen: two lines under
                                        ; the big letters, which end at 51, and
                                        ; five rows later still clear of the
                                        ; flight of ships at TITLE_SHIP_Y
DIAG_BRIEF_Y        equ 150             ; under a briefing: below its prompt at
                                        ; 132 and above HUD_TOP, so static_wipe
                                        ; still owns the ground it sits on


; ----------------------------------------------------------------------------
;  diag_draw -- the whole panel, five rows
;  In : A = the top scanline
;  Uses: everything
; ----------------------------------------------------------------------------
diag_draw:
    ld (diag_row),a

    ;  Black behind the whole panel first. The title screen's flight of ships
    ;  is drawn before this and two of them cross these rows -- and txt_draw is
    ;  opaque only INSIDE a glyph cell, so without this a wing sits in the gap
    ;  between ST0 and its value and reads as a digit. Which is the one thing
    ;  a diagnostic may not do.
    ld c,a
    dec c
    ld b,0
    ld d,DIAG_W_BYTES
    ld e,DIAG_ROWS * DIAG_STEP
    xor a
    call scr_fill_rect

    ;  --- DISC DIAG  LIB n ---------------------------------------------
    ;  Red when the art is a stand-in, which is section 2's ink for the thing
    ;  that wants attention and is the one field a glance has to land on.
    ld a,(lib_ok)
    or a
    ld a,PEN_WHITE
    jr nz,@diag_head_pen
    ld a,PEN_RED
@diag_head_pen:
    call txt_set_pen

    ld hl,diag_t_head
    ld b,0
    call @diag_text
    ld a,(lib_ok)
    ld b,30
    ld d,1
    call @diag_num

    ld a,PEN_WHITE                      ; and put it back, per the convention
    call txt_set_pen
    call @diag_next_row

    ;  --- BANK n  TRK nn  SEC xx  DONE nn -------------------------------
    ld hl,diag_t_bank
    ld b,0
    call @diag_text
    ;  lib_bank holds the gate-array byte, GA_BANK_5..7 = #C5..#C7, and #C8
    ;  once the loop has walked off the end of bank 7. The low nibble IS the
    ;  bank number, and 8 is therefore "it finished".
    ld a,(lib_bank)
    and #0F
    ld b,10
    ld d,1
    call @diag_num

    ld hl,diag_t_trk
    ld b,14
    call @diag_text
    ld a,(lib_cur_track)
    ld b,22
    ld d,2
    call @diag_num

    ld hl,diag_t_sec
    ld b,28
    call @diag_text
    ld a,(lib_diag_sector)
    ld b,36
    call @diag_hex

    ld hl,diag_t_done
    ld b,42
    call @diag_text
    ;  lib_left is decremented AFTER a sector arrives, so on a failure it still
    ;  counts the one that did not.
    ld a,LIB_SECTORS
    ld hl,lib_left
    sub (hl)
    ld b,52
    ld d,2
    call @diag_num
    call @diag_next_row

    ;  --- ST0 xx  ST1 xx  ST2 xx ----------------------------------------
    ld hl,lib_diag_st0
    call @diag_status_row
    call @diag_next_row

    ;  --- SEEK FAIL nn  ST0 xx ------------------------------------------
    ld hl,diag_t_seek
    ld b,0
    call @diag_text
    ld a,(fdc_seek_fails)
    ld b,20
    ld d,2
    call @diag_num
    ld hl,diag_t_st0
    ld b,26
    call @diag_text
    ld a,(fdc_seek_st0)
    ld b,34
    call @diag_hex
    call @diag_next_row

    jr @diag_fleet_row


; ----------------------------------------------------------------------------
;  diag_draw_fleet -- one row, the fleet transfer on its own
;  In : A = the scanline
;  Uses: everything
;
;  The briefing gets this and not the whole panel, because the briefing's own
;  prompt sits at 132 and the HUD owns everything from 168 -- there is one row
;  of clear ground between them. One row is enough: the library load is over
;  and reported by then, and the only NEW fact a post-jump briefing carries is
;  whether the save went out.
; ----------------------------------------------------------------------------
diag_draw_fleet:
    ld (diag_row),a

@diag_fleet_row:
    ld hl,diag_t_fleet
    ld b,0
    call @diag_text
    ld a,(fleet_diag_res)
    ld b,12
    ld d,1
    call @diag_num
    ld hl,fleet_diag_st0
    ld b,16
    jp @diag_status_at


; ----------------------------------------------------------------------------
;  @diag_status_row -- "ST0 xx ST1 xx ST2 xx" from three adjacent bytes
;  In : HL -> ST0, ST1, ST2
;  Uses: everything
; ----------------------------------------------------------------------------
@diag_status_row:
    ld b,0
@diag_status_at:
    ld (diag_ptr),hl
    ld a,b                              ; the row's left edge; every field
    ld (diag_x),a                       ; below is an offset from it

    ld hl,diag_t_st0
    call @diag_text
    ld a,(diag_x)
    add a,8
    ld b,a
    ld hl,(diag_ptr)
    ld a,(hl)
    call @diag_hex

    ld a,(diag_x)
    add a,14
    ld b,a
    ld hl,diag_t_st1
    call @diag_text
    ld a,(diag_x)
    add a,22
    ld b,a
    ld hl,(diag_ptr)
    inc hl
    ld a,(hl)
    call @diag_hex

    ld a,(diag_x)
    add a,28
    ld b,a
    ld hl,diag_t_st2
    call @diag_text
    ld a,(diag_x)
    add a,36
    ld b,a
    ld hl,(diag_ptr)
    inc hl
    inc hl
    ld a,(hl)
;  fall through to @diag_hex


; ----------------------------------------------------------------------------
;  @diag_hex -- A as two hex digits at (B, the current row)
;  In : A = byte, B = x in bytes
;  Uses: everything
;
;  Hex and not decimal, because every bit of these three bytes means something
;  on its own and 68 does not read as %01000100 to anybody.
; ----------------------------------------------------------------------------
@diag_hex:
    push af
    ld a,(diag_row)
    ld c,a
    pop af

    ld e,a
    rrca
    rrca
    rrca
    rrca
    call @diag_nibble                   ; the high one; B and C come back
    inc b
    inc b                               ; TXT_CHAR_W_BYTES
    ld a,e
;  ...and fall into the low one, which returns to whoever called @diag_hex
@diag_nibble:
    and #0F
    add a,'0'
    cp '9' + 1
    jr c,@diag_nibble_out
    add a,'A' - '0' - 10
@diag_nibble_out:
    push de
    push bc
    call txt_draw_char
    pop bc
    pop de
    ret


; ----------------------------------------------------------------------------
;  @diag_text -- HL at (B, the current row)
;  @diag_num  -- A in a D-wide decimal field at (B, the current row)
;  Uses: everything
; ----------------------------------------------------------------------------
@diag_text:
    ld a,(diag_row)
    ld c,a
    jp txt_draw

@diag_num:
    push af
    ld a,(diag_row)
    ld c,a
    pop af
    jp txt_draw_num

@diag_next_row:
    ld hl,diag_row
    ld a,(hl)
    add a,DIAG_STEP
    ld (hl),a
    ret


; ============================================================================
;  Words and state
; ============================================================================
diag_t_head:        defb "DISC DIAG  LIB", 0
diag_t_bank:        defb "BANK", 0
diag_t_trk:         defb "TRK", 0
diag_t_sec:         defb "SEC", 0
diag_t_done:        defb "DONE", 0
diag_t_seek:        defb "SEEK FAIL", 0
diag_t_fleet:       defb "FLEET", 0
diag_t_st0:         defb "ST0", 0
diag_t_st1:         defb "ST1", 0
diag_t_st2:         defb "ST2", 0

diag_row:           defb 0
diag_x:             defb 0
diag_ptr:           defw 0
