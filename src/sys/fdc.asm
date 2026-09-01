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
;  "H2" AND NOT "HP", AND THE SECOND BYTE IS A FORMAT NUMBER. A ship on the
;  disc was twenty bytes -- the entity record itself -- until doubling
;  ENT_PLAYER_MAX made 56 of them overflow the two sectors this block gets. It
;  is thirteen now (game/entity.asm), so the fleet, the count it is read with
;  and fleet_unlocks behind it all sit somewhere else in the block.
;
;  A save written by an older build still matches "H", still has a plausible
;  mission index and a plausible count, and would be read back as a fleet of
;  rubbish. The magic is the only thing standing in front of that, so it moves
;  whenever the layout does: an old disc reads as NO SAVE, which is what every
;  other failed check in fleet_disc_load does, and the campaign starts again.
FLEET_MAGIC_1       equ "2"

;  The tag in front of the campaign's unlock byte, out in the block's pad --
;  see fleet_unlocks in src/main.asm for why it is there rather than in the
;  header, and fleet_disc_load for why it needs a tag of its own.
FLEET_UNLOCK_TAG    equ "U"

;  What the FLEET line of the disc diagnostic can say. Zero is the one that
;  is never written: it means the fleet transfer has not run at all, which on
;  the title screen would mean demo_init never reached fleet_disc_load.
DIAG_FLEET_NONE     equ 0
DIAG_FLEET_OK       equ 1
DIAG_FLEET_BAD      equ 2


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
;  A seek is milliseconds of head movement, and how many milliseconds is
;  whatever step rate AMSDOS put in the controller's SPECIFY -- we never issue
;  one of our own, so the number is not ours to know. So the wait below asks,
;  pauses, and asks again, rather than spinning: 256 rounds of about eight
;  milliseconds is a ceiling a little over two seconds, which is longer than
;  the widest seek this disc can ask for (39 tracks) at any rate the firmware
;  is likely to have set, and short enough that a controller which never
;  answers costs a pause at boot instead of a machine that never comes up.
;
;  Detecting the arrival up to eight milliseconds late costs nine seeks' worth
;  of that at boot -- under a tenth of a second against the second and a half
;  the 78 sector reads themselves take.
FDC_SEEK_ROUNDS     equ 0               ; 0 means 256 times round
FDC_SEEK_SETTLE     equ 1200            ; ~8 ms of `dec bc` at 4 MHz



; ----------------------------------------------------------------------------
;  fdc_transfer_ok -- did the last READ or WRITE actually move the data?
;  Out: CF set if it did
;  Uses: AF
;
;  "ST0 bits 7-6 are 00 or it failed" is what this used to be, in two places,
;  and IT IS WRONG ON REAL HARDWARE. A single-sector transfer sends EOT equal
;  to R -- it has to, the last sector of the transfer IS the sector -- so the
;  controller reaches the end of the cylinder as a matter of course, and a
;  uPD765 reports that with IC = 01 and ST1 bit 7, END OF CYLINDER. The bytes
;  are already in memory; the "error" is the chip saying it has finished.
;
;  cpcemu returns IC = 00 for the same transfer, so every test in this project
;  agreed with the old check and Retro Virtual Machine did not: on RVM the
;  FIRST library read came back ST0 = #40, ST1 = #80 and lib_load gave up,
;  every boot, with the data sitting in the bank. Two wrong guesses were spent
;  on the seek and on the 32-microsecond budget before a diagnostic build put
;  those two bytes on the title screen.
;
;  So EN alone is success. A fault is IC != 00 together with something in ST1
;  that names an actual failure -- missing address mark, sector not found,
;  overrun, data error -- or anything at all in ST2.
; ----------------------------------------------------------------------------
fdc_transfer_ok:
    ld a,(fdc_st0)
    and #C0
    jr z,@fdc_ok                        ; IC = 00: plainly normal
    cp #40
    jr nz,@fdc_bad                      ; #80 invalid, #C0 polling: not ours

    ;  NOT READY first, and this is the one the tests caught. No disc gives
    ;  ST0 = #48 -- IC = 01 with bit 3 -- and ST1 = #00, so a check that only
    ;  looked for faults in ST1 called an empty drive a successful read and the
    ;  stand-ins stopped appearing. IC = 01 means "something is wrong"; ST1 and
    ;  ST0's own bit 3 are where it says what.
    ld a,(fdc_st0)
    and FDC_ST0_NR
    jr nz,@fdc_bad

    ld a,(fdc_st1)
    and FDC_ST1_REAL
    jr nz,@fdc_bad
    ld a,(fdc_st2)
    or a
    jr nz,@fdc_bad
@fdc_ok:
    scf
    ret
@fdc_bad:
    or a
    ret


; ----------------------------------------------------------------------------
;  fdc_sense_int -- ask the controller what its last interrupt was about
;  In : -
;  Out: A = ST0, and (fdc_st0) holds the same. Zero if nothing came back.
;  Uses: AF, BC, E, HL -- D is deliberately untouched, fdc_seek counts in it
;
;  (fdc_st0) is cleared FIRST because fdc_drain_result returns without writing
;  anything when CB is already clear -- so a controller that declines to answer
;  would otherwise leave the PREVIOUS ST0 sitting there, and a previous ST0
;  with SEEK END still in it reads as "the head has arrived" for a seek that
;  has not started.
; ----------------------------------------------------------------------------
fdc_sense_int:
    xor a
    ld (fdc_st0),a
    ld a,FDC_CMD_SENSE_INT
    call fdc_out
    call fdc_drain_result               ; ST0, then the cylinder, however many
    ld a,(fdc_st0)
    ret


; ----------------------------------------------------------------------------
;  fdc_seek -- put the head over a track and wait for it to get there
;  In : A = track
;  Uses: everything
;
;  READ DATA and WRITE DATA do NOT seek. They take a cylinder number and check
;  it against what is under the head, so arriving on the wrong track reads as
;  "sector not found" rather than as anything that mentions seeking. That is
;  what makes this routine's ONE job -- not returning until the head is really
;  there -- worth more than it looks: get it wrong and the failure is reported
;  by the next command, in the vocabulary of sectors, with nothing anywhere
;  saying "seek".
;
;  IT USED TO WATCH THE DRIVE-BUSY BIT AND THAT WAS WRONG TWICE OVER, in
;  opposite directions, and cpcemu could not show either -- it has never set
;  that bit at all (see the note beside FDC_ST_BUSY0). The datasheet raises it
;  a few microseconds after the last command byte is taken, and the poll that
;  followed the OUT was five microseconds later, so on a controller running in
;  real time the loop read zero and fell straight through a seek that had not
;  begun; and it is cleared by SENSE INTERRUPT STATUS rather than by the head
;  arriving, so on a controller that reads the datasheet the other way the
;  same loop waits for something only the line after it can cause.
;
;  Asking is the portable answer and it is what the CPC firmware does: SENSE
;  INTERRUPT STATUS until ST0 says SEEK END. With nothing pending the reply is
;  ST0 = #80 -- invalid command, one byte, SE clear -- which IS the "not yet",
;  and fdc_drain_result already reads results by status rather than by count
;  for exactly that reason.
; ----------------------------------------------------------------------------
fdc_seek:
    ld (fdc_track),a

    ;  Take whatever seek-end the controller is still holding BEFORE starting
    ;  ours, or the wait below takes that stale answer for this seek's and lets
    ;  the read start while the head is still moving. AMSDOS ran before us, and
    ;  a seek of our own that timed out leaves one too. Four at most, one per
    ;  drive; with nothing pending the first answer has SE clear and that is
    ;  the exit.
    ld d,4
@fdc_seek_flush:
    call fdc_sense_int
    and FDC_ST0_SE
    jr z,@fdc_seek_issue
    dec d
    jr nz,@fdc_seek_flush

@fdc_seek_issue:
    ld a,FDC_CMD_SEEK
    call fdc_out
    xor a
    call fdc_out                        ; drive 0, head 0
    ld a,(fdc_track)
    call fdc_out

    ld d,FDC_SEEK_ROUNDS
@fdc_seek_wait:
    call fdc_sense_int
    and FDC_ST0_SE
    ret nz                              ; the head is where we asked for it

    ld bc,FDC_SEEK_SETTLE
@fdc_seek_settle:
    dec bc
    ld a,b
    or c
    jr nz,@fdc_seek_settle

    dec d
    jr nz,@fdc_seek_wait
IF DIAG_DISC
    ;  It gave up. Nothing downstream can tell anyone that: the read which
    ;  follows is on the wrong track and fails in the vocabulary of SECTORS,
    ;  with the word "seek" appearing nowhere. So count it here, and keep the
    ;  ST0 it gave up on. Cumulative over the whole boot, every seek there is.
    ld hl,fdc_seek_fails
    inc (hl)
    ld a,(fdc_st0)
    ld (fdc_seek_st0),a
ENDIF
    ret                                 ; gave up. Say nothing: the read that
                                        ; follows is on the wrong track and
                                        ; fails honestly, which is a stand-in
                                        ; on the screen rather than a hang


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

    ;  Execution phase, and the loop has to watch for three things at once.
    ;
    ;  A command the controller will not do -- no disc, no such sector, write
    ;  protected -- never enters the execution phase at all; it goes straight
    ;  to handing back its seven result bytes. And a transfer it gives up on
    ;  part way, because we were too slow feeding it, LEAVES the execution
    ;  phase early. Either way it is then trying to talk to US, and a loop
    ;  that only ever waits for "ready, wants a byte" waits forever. Both of
    ;  those hung the game on a real controller while working perfectly in
    ;  the emulator here, which resolves the phase the instant the last
    ;  command byte is written and never runs out of patience.
    ;
    ;  Testing EXM alongside RQM and DIO costs nothing -- it is one more bit
    ;  in a mask that was already being compared -- so the fast path is the
    ;  same length it always was, and the loop stays inside the controller's
    ;  32-microsecond-a-byte budget.
    ld hl,(fdc_buf)
    ld de,FDC_SECTOR_SIZE
    ;  BC HOLDS THE STATUS PORT FOR THE WHOLE TRANSFER, and the data port is
    ;  one INC C away -- #FB7E and #FB7F differ in bit 0 alone. It used to
    ;  reload both, twice a byte, which is 20 T-states of address arithmetic
    ;  per byte in a loop measured at 132 T against a deadline of 128.
    ;
    ;  That is not a micro-optimisation, it is the bug: RVM reported
    ;  ST1 = #90, END OF CYLINDER with OVERRUN, on the first sector after a
    ;  track advance, 63 sectors into the load. Overrun means the controller
    ;  gave up waiting for us. cpcemu feeds the byte synchronously and can
    ;  never produce it, which is why a loop three microseconds over budget
    ;  passed every test for the life of this project.
    ld bc,FDC_STATUS
    ld a,(fdc_cmd)
    cp FDC_CMD_READ
    jr z,@fdc_read_byte

@fdc_write_byte:
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO + FDC_ST_EXM
    cp FDC_ST_RQM + FDC_ST_EXM          ; executing, and wanting a byte from us
    jr z,@fdc_write_go
    bit 5,a                             ; EXM: still executing?
    jr nz,@fdc_write_byte               ; yes -- it just has not asked yet
    bit 7,a                             ; no -- wait for RQM and take the result
    jr z,@fdc_write_byte
    jr @fdc_rw_drain
@fdc_write_go:
    ld a,(hl)
    inc hl
    inc c                               ; -> FDC_DATA
    out (c),a
    dec c                               ; -> FDC_STATUS, for the next round
    dec de
    ld a,d
    or e
    jr nz,@fdc_write_byte
    jr @fdc_rw_result

@fdc_read_byte:
    in a,(c)
    and FDC_ST_RQM + FDC_ST_DIO + FDC_ST_EXM
    cp FDC_ST_RQM + FDC_ST_DIO + FDC_ST_EXM     ; executing, with a byte for us
    jr z,@fdc_read_go
    bit 5,a
    jr nz,@fdc_read_byte
    bit 7,a
    jr z,@fdc_read_byte
    jr @fdc_rw_drain
@fdc_read_go:
    inc c                               ; -> FDC_DATA
    in a,(c)
    dec c                               ; -> FDC_STATUS, for the next round
    ld (hl),a
    inc hl
    dec de
    ld a,d
    or e
    jr nz,@fdc_read_byte

@fdc_rw_result:
    ld (fdc_buf),hl                     ; left ready for the next sector

fdc_drain_result:
@fdc_rw_drain:
    ;  Every result byte has to be taken: the controller sits in the result
    ;  phase until the last one is read and ignores anything sent to it in the
    ;  meantime. Drain until it says it is idle rather than counting to seven
    ;  -- READ and WRITE return seven, SENSE INTERRUPT STATUS returns two, and
    ;  a SENSE with no interrupt pending returns ONE. Counting means the count
    ;  has to be right everywhere, and being one too high is a wait for a byte
    ;  that is never coming.
    ld hl,fdc_st0                       ; the first byte is ST0; keep it
@fdc_drain:
    ld bc,FDC_STATUS
    in a,(c)
    bit 4,a                             ; CB: still working on the command?
    ret z                               ; no -- idle, and nothing left to take
    bit 7,a                             ; RQM
    jr z,@fdc_drain
    ld bc,FDC_DATA
    in a,(c)
    ld (hl),a
IF DIAG_DISC
    ;  ST0, ST1 and ST2, then the bin. ST0 alone says only that the command
    ;  did not finish normally; ST1 says WHY -- bit 2 no such sector, bit 4
    ;  overrun (we were too slow feeding the controller), bit 5 a data error --
    ;  and ST2 says whether the sector's own cylinder byte disagreed with the
    ;  one we sent, which is what a seek that has not finished looks like from
    ;  in here. Walking three and then sticking costs one byte over the old
    ;  "everything after ST0 goes in the bin"; main.asm asserts the four are
    ;  contiguous and inside one page, because this steps L and compares it.
    ld a,l
    cp fdc_spill & 255
    jr z,@fdc_drain
    inc hl
    jr @fdc_drain
ELSE
    ld hl,fdc_spill                     ; everything after ST0 goes in the bin
    jr @fdc_drain
ENDIF


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

    ;  Start from a controller that is not mid-conversation. AMSDOS ran before
    ;  us and the chip keeps its state across the ROMs being switched out, so
    ;  anything it left in the result phase would make our first command byte
    ;  land as a result read -- and fdc_out would then wait for a DIO that
    ;  never clears. Returns at once when there is nothing pending.
    call fdc_drain_result

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
    call fdc_transfer_ok                ; EN alone is not a failure -- see there
    jr nc,@fdc_io_failed
    ld hl,fdc_sector
    inc (hl)
    djnz @fdc_io_sector

    xor a
    call fdc_spin
IF DIAG_DISC
    ld a,DIAG_FLEET_OK
    call fdc_diag_fleet
ENDIF
    ei
    scf
    ret

@fdc_io_failed:
    xor a
    call fdc_spin
IF DIAG_DISC
    ld a,DIAG_FLEET_BAD
    call fdc_diag_fleet
ENDIF
    ei
    or a                                ; CF clear: no save, or no drive
    ret


IF DIAG_DISC
; ----------------------------------------------------------------------------
;  fdc_diag_fleet -- keep what the fleet transfer said before anything else
;                    uses the controller
;  In : A = DIAG_FLEET_OK or DIAG_FLEET_BAD
;  Uses: AF, BC, DE, HL -- and NOT the carry, which both callers set after it
;
;  The boot-time load and the save at every jump both come through here, so
;  what is on the title screen is the LOAD (the only one that has happened by
;  then) and what is under the briefing after a jump is the SAVE. They are the
;  same routine either way, differing only in READ against WRITE, so a load
;  that works and a save that does not is a fact about writing.
; ----------------------------------------------------------------------------
fdc_diag_fleet:
    ld (fleet_diag_res),a
    ld hl,fdc_st0
    ld de,fleet_diag_st0
    ld bc,3
    ldir
    ret
ENDIF


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

    ;  ...and what the campaign has learned, out in the pad behind the fleet.
    ld hl,fleet_unlocks
    ld (hl),FLEET_UNLOCK_TAG
    inc hl
    ld a,(campaign_unlocks)
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
    ;  ENT_PLAYER_MAX and not ENT_MAX: fleet_restore packs the survivors into
    ;  slots 0..n-1, and slots from ENT_PLAYER_MAX up are the enemy's. A count
    ;  past the partition can only come off a disc written by a build that did
    ;  not have one, and it would lay the fleet across the hostile region --
    ;  where mis_clear_enemies does not touch it and mis_setup spawns on top of
    ;  it. Read as "no save", which is what every other failed check here does.
    cp ENT_PLAYER_MAX + 1
    jr nc,@fleet_no_save
    ld (fleet_count),a

    ;  What the campaign had unlocked. It is TAGGED, and that is not belt and
    ;  braces: this field lives in the save block's pad, the pad is bank RAM
    ;  declared after bank4_end, and nothing has ever written it -- so a disc
    ;  saved by yesterday's build has whatever powered up at this offset, not a
    ;  zero. "An old save reads as not unlocked" is a property of the TAG, not
    ;  of the pad. Anything else -- no tag, or a bit nothing sets -- reads as
    ;  nothing unlocked, which is what every other failed check here does.
    xor a
    ld (campaign_unlocks),a
    ld hl,fleet_unlocks
    ld a,(hl)
    cp FLEET_UNLOCK_TAG
    jr nz,@fleet_no_unlocks
    inc hl
    ld a,(hl)
    cp CAMP_UNLOCK_ALL + 1
    jr nc,@fleet_no_unlocks
    ld (campaign_unlocks),a
@fleet_no_unlocks:

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
;  These four are walked by an INC L in fdc_drain_result, so they have to stay
;  in this order, adjacent, and inside one page. src/main.asm asserts all of
;  that -- move one and the drain writes ST1 over whatever is next instead.
fdc_st0:            defb 0
;  ST1 AND ST2 ARE NOT DIAGNOSTIC. They were declared inside IF DIAG_DISC when
;  only the panel read them, and fdc_transfer_ok now needs them on every build
;  to tell END OF CYLINDER -- which is normal -- from a fault. With the panel
;  off the assembly failed, and because `make` was piped to /dev/null the tests
;  that followed ran against the PREVIOUS image with a symbol file that no
;  longer matched it. That is the trap CLAUDE.md describes for running rasm by
;  hand, arriving through a different door: check that a build succeeded before
;  believing anything measured after it.
fdc_st1:            defb 0
fdc_st2:            defb 0
fdc_spill:          defb 0
fdc_buf:            defw 0

IF DIAG_DISC
fdc_seek_fails:     defb 0              ; how many seeks timed out, all boot
fdc_seek_st0:       defb 0              ; ...and the ST0 the last one gave up on
fleet_diag_res:     defb DIAG_FLEET_NONE
fleet_diag_st0:     defb 0
fleet_diag_st1:     defb 0
fleet_diag_st2:     defb 0
ENDIF
