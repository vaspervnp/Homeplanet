; ============================================================================
;  fdc.asm -- FLEET.DAT, by driving the uPD765 ourselves
; ============================================================================
;  Homeplanet.md section 10 wants the fleet on the disc, and section 11
;  suggests bringing the firmware back "on the screens between missions" to
;  get there. That route is closed: screen B lives at #8000-#BFFF, right on
;  top of AMSDOS's workspace at #A700, so the first time the game clears its
;  second screen the firmware is gone and there is no putting it back.
;
;  So we talk to the controller directly. It is less work than it sounds --
;  the uPD765 is a byte pump with a status register, and everything below is
;  the same three-phase dance:
;
;      COMMAND    push N bytes while RQM=1, DIO=0
;      EXECUTION  push or pull 512 bytes, same handshake
;      RESULT     pull 7 bytes, RQM=1, DIO=1
;
;  The controller will not accept a new command until every result byte has
;  been taken, so the drain at the end of fdc_sector_rw is not optional.
;
;  WHERE IT GOES ON THE DISC
;  -------------------------
;  Two raw sectors -- track 39, #C1 and #C2 -- and NOT an AMSDOS file. A real
;  file would mean implementing directory allocation, which is several hundred
;  more bytes than the low 16K has to spare. The disc is 40 tracks and
;  DISC.BIN takes about five of them from track 2 up, so the last track is
;  a long way from anything AMSDOS would hand out.
;
;  The trade is honest but worth writing down: copy another file onto this
;  disc with CP/M and it may land on the save.
; ----------------------------------------------------------------------------

FLEET_TRACK         equ 39
FLEET_SECTOR        equ #C1             ; and #C2 -- 1 KB over two sectors
FDC_SECTOR_SIZE     equ 512
FDC_SECTOR_N        equ 2               ; the code for 512 bytes
FLEET_BLOCK_SIZE    equ 1024

;  The header sits in front of the fleet inside the same block, so a save is
;  two whole sectors from one address rather than a gather.
FLEET_HDR_SIZE      equ 4
FLEET_MAGIC_0       equ "H"
FLEET_MAGIC_1       equ "P"


; ----------------------------------------------------------------------------
;  fdc_out -- hand one byte to the controller
;  In : A = the byte
;  Out: -
;  Uses: AF, BC, E
; ----------------------------------------------------------------------------
fdc_out:
    ld e,a
@fdc_out_wait:
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO
    cp FDC_ST_RQM                       ; ready, and wanting a byte from us
    jr nz,@fdc_out_wait
    ld bc,FDC_DATA
    out (c),e
    ret


; ----------------------------------------------------------------------------
;  fdc_in -- take one byte from the controller
;  In : -
;  Out: A = the byte
;  Uses: AF, BC
; ----------------------------------------------------------------------------
fdc_in:
@fdc_in_wait:
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO
    cp FDC_ST_RQM + FDC_ST_DIO          ; ready, with a byte for us
    jr nz,@fdc_in_wait
    ld bc,FDC_DATA
    in a,(c)
    ret


; ----------------------------------------------------------------------------
;  fdc_spin -- spin the drive up or down
;  In : A = 1 to start, 0 to stop
;  Uses: AF, BC, DE
; ----------------------------------------------------------------------------
fdc_spin:
    ld bc,FDC_MOTOR
    out (c),a
    or a
    ret z                               ; stopping needs no settling time

    ;  A real drive is not up to speed for something like half a second, and
    ;  reading during spin-up is how you get a sector that is nearly right.
    ;  The emulator is ready immediately and does not care; this runs between
    ;  missions, where a third of a second costs nothing either way.
    ld de,0
@fdc_spin_wait:
    dec de
    ld a,d
    or e
    jr nz,@fdc_spin_wait
    ret


; ----------------------------------------------------------------------------
;  fdc_seek -- put the head over a track and wait for it to get there
;  In : A = track
;  Uses: everything except HL
;
;  READ DATA and WRITE DATA do NOT seek. They take a cylinder number and check
;  it against what is under the head, so arriving on the wrong track reads as
;  "sector not found" rather than as anything that mentions seeking.
; ----------------------------------------------------------------------------
fdc_seek:
    ld (fdc_track),a
    ld a,FDC_CMD_SEEK
    call fdc_out
    xor a
    call fdc_out                        ; drive 0, head 0
    ld a,(fdc_track)
    call fdc_out

@fdc_seek_busy:
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_BUSY0
    jr nz,@fdc_seek_busy

    ;  A seek finishes by raising an interrupt, and the controller will not
    ;  start another command until it has been acknowledged.
    ld a,FDC_CMD_SENSE_INT
    call fdc_out
    call fdc_in                         ; ST0
    call fdc_in                         ; the cylinder it thinks it is on
    ret


; ----------------------------------------------------------------------------
;  fdc_sector_rw -- move one 512-byte sector
;  In : A = FDC_CMD_READ or FDC_CMD_WRITE
;       (fdc_track), (fdc_sector), (fdc_buf) -> memory
;  Out: (fdc_st0) = ST0; (fdc_buf) advanced past the sector
;  Uses: everything
; ----------------------------------------------------------------------------
fdc_sector_rw:
    ld (fdc_cmd),a
    call fdc_out
    xor a
    call fdc_out                        ; (head << 2) | unit
    ld a,(fdc_track)
    call fdc_out                        ; C -- must match what is under the head
    xor a
    call fdc_out                        ; H
    ld a,(fdc_sector)
    call fdc_out                        ; R
    ld a,FDC_SECTOR_N
    call fdc_out                        ; N
    ld a,(fdc_sector)
    call fdc_out                        ; EOT: the LAST sector of the transfer,
                                        ; so equal to R for a single one
    ld a,#2A
    call fdc_out                        ; GPL, the standard gap
    ld a,#FF
    call fdc_out                        ; DTL, unused while N is non-zero

    ;  Did it actually start? A command the controller will not do -- no disc
    ;  in the drive, no such sector on the track -- skips the execution phase
    ;  and goes straight to handing back its seven result bytes. Pumping 512
    ;  bytes at a controller that is trying to talk to US waits on an RQM that
    ;  never comes, and the game hangs on the boot that looks for a save.
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_EXM
    jr z,@fdc_rw_drain

    ;  Execution phase. The handshake is the same as the command phase, but
    ;  the count is ours to keep: the controller leaves execution when it has
    ;  had its sector, and asking for one byte more hangs on RQM forever.
    ld hl,(fdc_buf)
    ld de,FDC_SECTOR_SIZE
    ld a,(fdc_cmd)
    cp FDC_CMD_READ
    jr z,@fdc_read_byte

@fdc_write_byte:
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO
    cp FDC_ST_RQM
    jr nz,@fdc_write_byte
    ld a,(hl)
    inc hl
    ld bc,FDC_DATA
    out (c),a
    dec de
    ld a,d
    or e
    jr nz,@fdc_write_byte
    jr @fdc_rw_result

@fdc_read_byte:
    ld bc,FDC_STATUS
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO
    cp FDC_ST_RQM + FDC_ST_DIO
    jr nz,@fdc_read_byte
    ld bc,FDC_DATA
    in a,(c)
    ld (hl),a
    inc hl
    dec de
    ld a,d
    or e
    jr nz,@fdc_read_byte

@fdc_rw_result:
    ld (fdc_buf),hl                     ; left ready for the next sector

@fdc_rw_drain:
    ;  Seven result bytes, and all seven have to go: the controller sits in
    ;  the result phase until the last one is read and ignores everything
    ;  sent to it in the meantime.
    call fdc_in
    ld (fdc_st0),a
    ld b,6
@fdc_drain:
    push bc
    call fdc_in
    pop bc
    djnz @fdc_drain
    ret


; ----------------------------------------------------------------------------
;  fdc_fleet_save / fdc_fleet_load -- the block, both ways
;  Out: CF set if the transfer worked
;  Uses: everything
;
;  Interrupts are off for the whole transfer. Our IM 1 handler runs snd_update
;  every fiftieth of a second, and the controller wants a byte roughly every
;  32 microseconds; a handler that runs between two of them loses the sector.
; ----------------------------------------------------------------------------
fdc_fleet_save:
    ld a,FDC_CMD_WRITE
    jr fdc_fleet_io

fdc_fleet_load:
    ld a,FDC_CMD_READ

fdc_fleet_io:
    ld (fdc_want),a
    di
    ld a,1
    call fdc_spin
    ld a,FLEET_TRACK
    call fdc_seek

    ld hl,fleet_block
    ld (fdc_buf),hl
    ld a,FLEET_SECTOR
    ld (fdc_sector),a
    ld b,FLEET_BLOCK_SIZE / FDC_SECTOR_SIZE

@fdc_io_sector:
    push bc
    ld a,(fdc_want)
    call fdc_sector_rw
    pop bc
    ld a,(fdc_st0)
    and #C0                             ; ST0 bits 7-6: 00 is "finished normally"
    jr nz,@fdc_io_failed
    ld hl,fdc_sector
    inc (hl)
    djnz @fdc_io_sector

    xor a
    call fdc_spin
    ei
    scf
    ret

@fdc_io_failed:
    xor a
    call fdc_spin
    ei
    or a                                ; CF clear: no save, or no drive
    ret


; ----------------------------------------------------------------------------
;  fleet_disc_save -- stamp the header and put the fleet on the disc
;  Out: CF set if it went out
;  Uses: everything
; ----------------------------------------------------------------------------
fleet_disc_save:
    ld hl,fleet_block
    ld (hl),FLEET_MAGIC_0
    inc hl
    ld (hl),FLEET_MAGIC_1
    inc hl
    ld a,(mis_index)
    ld (hl),a
    inc hl
    ld a,(fleet_count)
    ld (hl),a
    jp fdc_fleet_save


; ----------------------------------------------------------------------------
;  fleet_disc_load -- read the fleet back, if this disc has one
;  Out: CF set and mis_index / fleet_count / mis_saved filled in
;  Uses: everything
;
;  Everything read off a disc is guesswork until it has been checked. A blank
;  disc, another game's disc and a half-written save all get here, and two of
;  them would index off the end of the mission table.
; ----------------------------------------------------------------------------
fleet_disc_load:
    call fdc_fleet_load
    ret nc                              ; no drive, no disc, or a bad sector

    ld hl,fleet_block
    ld a,(hl)
    cp FLEET_MAGIC_0
    jr nz,@fleet_no_save
    inc hl
    ld a,(hl)
    cp FLEET_MAGIC_1
    jr nz,@fleet_no_save

    inc hl
    ld a,(hl)
    cp MIS_COUNT
    jr nc,@fleet_no_save                ; would run off the mission table
    ld (mis_index),a

    inc hl
    ld a,(hl)
    or a
    jr z,@fleet_no_save                 ; a fleet of nobody is not a save
    cp ENT_MAX + 1
    jr nc,@fleet_no_save
    ld (fleet_count),a

    ld a,1
    ld (mis_saved),a                    ; so fleet_restore will act on it
    scf
    ret

@fleet_no_save:
    or a
    ret


; ============================================================================
;  State
; ============================================================================
fdc_track:          defb 0
fdc_sector:         defb 0
fdc_cmd:            defb 0
fdc_want:           defb 0
fdc_st0:            defb 0
fdc_buf:            defw 0
