; ============================================================================
;  musicplay.asm -- the three-voice note-stream player, on its own
; ============================================================================
;  This is what MUSIC1.BIN and MUSIC2.BIN are. It is deliberately a program
;  with no game around it, because that is the honest order to build this in:
;  it proves the converter, the stream format, the period table and the AY
;  writes, all before any of them have to share a machine with a battle.
;
;  NO INTERRUPTS, and that is the whole reason this is simple.
;  ---------------------------------------------------------
;  The firmware's interrupt drives the firmware's own sound manager through
;  the same PSG and the same PPI port A, and scans the keyboard through them
;  too -- so leaving it running means two pieces of code writing the AY with
;  no contract between them. Instead: DI, and poll the VSYNC bit of PPI port B
;  exactly the way the game's scr_wait_vsync does. One VSYNC is one tick,
;  which is the 50 Hz the durations are counted in.
;
;  It keeps the ROMs paged in, so it can RET to BASIC when the tune ends.
;  Nothing here writes below #4000 and nothing calls the firmware while it is
;  playing.
;
;  A STREAM is triples of (note index, volume, duration in ticks) ending in
;  #FF. Note index 0 is a rest; anything else is one-based into mus_periods.
;  tools/genmusic.py writes them, and its header is careful about which parts
;  of them are measured and which are an arrangement.
; ----------------------------------------------------------------------------

    org #4000
    run mus_main

    include "equ/hardware.asm"

MUS_END             equ #FF

;  Tone on all three channels, noise off on all three. BIT 6 MUST STAY 0 --
;  setting it makes the PSG's port A an output, and port A is how the keyboard
;  is read. The game asserts this at build time; here it is one constant with
;  one reader.
MUS_MIXER           equ %00111000

;  Port A output / input, and the PSG's keyboard register. The same three the
;  game's key_scan uses, and they have to agree with it: this program hands
;  the machine back to BASIC, which expects port A an OUTPUT.
MUS_PPI_A_OUT       equ %10000010
MUS_PPI_A_IN        equ %10010010
MUS_PSG_KEYS        equ 14

;  ESC is row 8, bit 2 of the matrix -- which is where the game's
;  KEY_ESC equ 8*8+2 comes from. One row is all this needs.
MUS_ESC_ROW         equ 8
MUS_ESC_BIT         equ %00000100

;  One voice: where it is in its stream, how many ticks the current note has
;  left, and which PSG period register pair it owns (0, 2 or 4).
MUS_V_PTR           equ 0
MUS_V_COUNT         equ 2
MUS_V_REG           equ 3
MUS_V_SIZE          equ 4


; ----------------------------------------------------------------------------
;  mus_main -- play it once through, then hand the machine back
; ----------------------------------------------------------------------------
mus_main:
    di
    call mus_start

@mus_loop:
    call mus_wait_vsync
    call mus_tick
    jr z,@mus_done                      ; every voice has run out
    call mus_esc
    jr nc,@mus_loop

@mus_done:
    call mus_silence
    ;  Port A back to an output and the control lines released: the resting
    ;  state the firmware is about to assume it still has.
    ld bc,PPI_CONTROL * 256 + MUS_PPI_A_OUT
    out (c),c
    ld bc,PPI_PORT_C * 256 + PSG_INACTIVE
    out (c),c
    ei
    ret


; ----------------------------------------------------------------------------
;  mus_start -- point the three voices at their streams and open the mixer
;  Uses: everything
; ----------------------------------------------------------------------------
mus_start:
    ld hl,mus_bass
    ld (mus_v0 + MUS_V_PTR),hl
    ld hl,mus_harmony
    ld (mus_v1 + MUS_V_PTR),hl
    ld hl,mus_lead
    ld (mus_v2 + MUS_V_PTR),hl

    xor a
    ld (mus_v0 + MUS_V_COUNT),a         ; all three are due immediately
    ld (mus_v1 + MUS_V_COUNT),a
    ld (mus_v2 + MUS_V_COUNT),a

    ld e,7
    ld d,MUS_MIXER
    call mus_psg_out

    ;  Silence first: a voice writes its own amplitude the moment it takes its
    ;  first event, and whatever the firmware left in R8-R10 would be a click.
    jp mus_silence


; ----------------------------------------------------------------------------
;  mus_tick -- one 50 Hz tick of all three voices
;  Out: NZ while at least one voice is still playing, Z when all have ended
;  Uses: everything
; ----------------------------------------------------------------------------
mus_tick:
    xor a
    ld (mus_live),a

    ld hl,mus_v0
    call mus_one
    ld hl,mus_v1
    call mus_one
    ld hl,mus_v2
    call mus_one

    ld a,(mus_live)
    or a
    ret


; ----------------------------------------------------------------------------
;  mus_one -- one tick of the voice whose record is at HL
;  In : HL -> a four-byte voice record
;  Uses: everything
;
;  A voice that has ended leaves mus_live alone, so mus_tick comes back Z when
;  none of the three has touched it. That is the end condition, and it needs
;  no fourth counter.
; ----------------------------------------------------------------------------
mus_one:
    ld (mus_rec),hl

    ld de,MUS_V_COUNT
    add hl,de
    ld a,(hl)
    or a
    jr z,@mus_take_next

    dec (hl)                            ; still holding the current note
    jr @mus_still_live

@mus_take_next:
    ld hl,(mus_rec)
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = where this voice has got to
    ld a,d
    or e
    ret z                               ; ...or zero, meaning it has ended

    ld a,(de)
    cp MUS_END
    jr z,@mus_stream_end

    ld (mus_note),a
    inc de
    ld a,(de)
    ld (mus_vol),a
    inc de
    ld a,(de)
    ld (mus_dur),a
    inc de                              ; DE now points at the next triple

    ld hl,(mus_rec)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(mus_dur)
    ld (hl),a                           ; MUS_V_COUNT
    inc hl
    ld a,(hl)                           ; MUS_V_REG
    ld (mus_reg),a

    call mus_set_voice

@mus_still_live:
    ld hl,mus_live
    inc (hl)
    ret

@mus_stream_end:
    ;  Zero the pointer to mark it done, and shut the channel up -- otherwise
    ;  the last note of the shortest voice hangs on under the other two for the
    ;  rest of the piece.
    ld hl,(mus_rec)
    ld (hl),0
    inc hl
    ld (hl),0
    inc hl
    inc hl
    ld a,(hl)                           ; MUS_V_REG
    jp mus_voice_off


; ----------------------------------------------------------------------------
;  mus_set_voice -- period and amplitude, from (mus_note)/(mus_vol)/(mus_reg)
;  Uses: everything
; ----------------------------------------------------------------------------
mus_set_voice:
    ld a,(mus_note)
    or a
    jr nz,@mus_sound
    ld a,(mus_reg)
    jp mus_voice_off

@mus_sound:
    dec a                               ; the table is one-based; 0 is a rest
    add a,a
    ld l,a
    ld h,0
    ld de,mus_periods
    add hl,de
    ld c,(hl)
    inc hl
    ld b,(hl)                           ; BC = the twelve-bit period

    ld a,(mus_reg)
    ld e,a
    ld d,c
    push bc
    call mus_psg_out                    ; R(2n)   = period low
    pop bc

    ld a,(mus_reg)
    inc a
    ld e,a
    ld d,b
    call mus_psg_out                    ; R(2n+1) = period high

    ld a,(mus_reg)
    srl a                               ; 0, 2, 4 -> 0, 1, 2
    add a,8                             ; R8, R9, R10 are the amplitudes
    ld e,a
    ld a,(mus_vol)
    ld d,a
    jp mus_psg_out


; ----------------------------------------------------------------------------
;  mus_voice_off -- amplitude zero on the voice whose period register is A
;  In : A = 0, 2 or 4
;  Uses: everything
; ----------------------------------------------------------------------------
mus_voice_off:
    srl a
    add a,8
    ld e,a
    ld d,0
    jp mus_psg_out


; ----------------------------------------------------------------------------
;  mus_silence -- all three amplitudes to zero
;  Uses: everything
; ----------------------------------------------------------------------------
mus_silence:
    xor a
    call mus_voice_off
    ld a,2
    call mus_voice_off
    ld a,4
    jp mus_voice_off


; ----------------------------------------------------------------------------
;  mus_wait_vsync -- hold until the flyback starts
;  Uses: AF, BC
;
;  Both loops, the same as scr_wait_vsync: wait for the bit to go DOWN first,
;  or a call made while it is already high returns at once and that tick is
;  part of a frame long.
; ----------------------------------------------------------------------------
mus_wait_vsync:
    ld bc,PPI_PORT_B * 256
@mus_vs_low:
    in a,(c)
    and PPI_B_VSYNC
    jr nz,@mus_vs_low
@mus_vs_high:
    in a,(c)
    and PPI_B_VSYNC
    jr z,@mus_vs_high
    ret


; ----------------------------------------------------------------------------
;  mus_esc -- CF set if ESC is down
;  Uses: everything
;
;  One row of the matrix, read through PSG register 14 the way key_scan does:
;  port A to INPUT, the row into the low nibble of port C, then a PSG read.
;  Everything is put back afterwards, because the very next thing this program
;  does is write the PSG again.
; ----------------------------------------------------------------------------
mus_esc:
    ld bc,PPI_CONTROL * 256 + MUS_PPI_A_OUT
    out (c),c
    ld bc,PPI_PORT_A * 256 + MUS_PSG_KEYS
    out (c),c
    ld bc,PPI_PORT_C * 256 + PSG_SELECT
    out (c),c
    ld c,PSG_INACTIVE
    out (c),c

    ld bc,PPI_CONTROL * 256 + MUS_PPI_A_IN
    out (c),c
    ld bc,PPI_PORT_C * 256 + PSG_READ + MUS_ESC_ROW
    out (c),c
    ld bc,PPI_PORT_A * 256
    in a,(c)
    push af

    ld bc,PPI_CONTROL * 256 + MUS_PPI_A_OUT
    out (c),c
    ld bc,PPI_PORT_C * 256 + PSG_INACTIVE
    out (c),c

    pop af
    and MUS_ESC_BIT                     ; a key that is down reads as 0
    ret nz
    scf
    ret


; ----------------------------------------------------------------------------
;  mus_psg_out -- write one PSG register
;  In : E = register, D = value
;  Out: DE and HL untouched; port C back at PSG_INACTIVE
;  Uses: AF, BC
; ----------------------------------------------------------------------------
mus_psg_out:
    ;  The port is decoded from B; C is the low address byte and is not used,
    ;  but it is loaded anyway so nothing depends on what a caller left there.
    ld bc,PPI_PORT_A * 256
    out (c),e
    ld bc,PPI_PORT_C * 256 + PSG_SELECT
    out (c),c
    ld c,PSG_INACTIVE
    out (c),c

    ld bc,PPI_PORT_A * 256
    out (c),d
    ld bc,PPI_PORT_C * 256 + PSG_WRITE
    out (c),c
    ld c,PSG_INACTIVE
    out (c),c
    ret


; ============================================================================
;  State
; ============================================================================
mus_v0:             defw 0
                    defb 0, 0           ; count, period register pair
mus_v1:             defw 0
                    defb 0, 2
mus_v2:             defw 0
                    defb 0, 4

mus_rec:            defw 0
mus_note:           defb 0
mus_vol:            defb 0
mus_dur:            defb 0
mus_reg:            defb 0              ; the period register pair, 0/2/4
mus_live:           defb 0
