; ============================================================================
;  music.asm -- the title screen's music, on `M`
; ============================================================================
;  IT WRITES NO PSG REGISTERS AT ALL, and that is the whole design.
;
;  snd_update owns the AY. It runs from the 50 Hz interrupt, rebuilds the
;  mixer from scratch every tick, and MUTES every idle channel -- so a second
;  writer would be silenced within a tick, whatever it wrote. Rather than
;  fight that, this fills in the three VOICE BLOCKS and lets snd_update do
;  exactly what it already does.
;
;  A voice block turns out to be a held note already:
;
;      timer  = 200      not zero, so snd_step calls it live
;      pri    = 0        an effect may still take the channel
;      vol    = v << 4   snd_step hands back the top nibble
;      dvol   = 0        no decay, so the level does not move
;      period = p        the note
;      dstep  = 0        no sweep
;
;  and it is refreshed every frame, so the timer never runs out. Nothing in
;  sound.asm changed except which mixer mask channel B takes -- see below.
;
;  IT IS DRIVEN BY sys_tick_50hz, NOT BY THE FRAME LOOP'S RATE. mus_update is
;  called once a game frame, and a game frame is not a fixed length; the
;  durations in the stream are 50 Hz ticks. So it takes the difference between
;  the free-running counter and where it was last time and advances by that
;  many ticks. The tempo is then right whatever the frame rate does, and none
;  of this has to run in the interrupt -- which matters, because the interrupt
;  can fire with a sprite bank paged into the window and this reads its notes
;  out of bank 4.
; ----------------------------------------------------------------------------

MUS_TIMER           equ 200             ; refreshed every frame; must be < 255
MUS_END             equ #FF
MUS_VOICES          equ 3


; ----------------------------------------------------------------------------
;  mus_start -- rewind to the top and open the channels
;  Uses: everything
; ----------------------------------------------------------------------------
mus_start:
    ld hl,mus_menu_bass
    ld (mus_v0),hl
    ld hl,mus_menu_harmony
    ld (mus_v1),hl
    ld hl,mus_menu_lead
    ld (mus_v2),hl

    xor a
    ld (mus_c0),a                       ; all three are due at once
    ld (mus_c1),a
    ld (mus_c2),a

    ld a,(sys_tick_50hz)
    ld (mus_last_tick),a
    ld a,1
    ld (snd_music_on),a
    ret


; ----------------------------------------------------------------------------
;  mus_stop -- silence, and hand the channels back to the effects
;  Uses: AF, HL, BC
; ----------------------------------------------------------------------------
mus_stop:
    xor a
    ld (snd_music_on),a

    ;  Zero the timers rather than the whole blocks: timer 0 is what snd_step
    ;  reads as idle, and it is the one byte that ends a sound.
    ld hl,snd_voice_a
    ld (hl),a
    ld hl,snd_voice_b
    ld (hl),a
    ld hl,snd_voice_c
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  mus_toggle -- `M`
;  Uses: everything
; ----------------------------------------------------------------------------
mus_toggle:
    ld a,(snd_music_on)
    or a
    jr nz,mus_stop
    jr mus_start


; ----------------------------------------------------------------------------
;  mus_update -- one call a frame; advances by however many ticks have passed
;  Uses: everything
; ----------------------------------------------------------------------------
mus_update:
    ld a,(snd_music_on)
    or a
    ret z

    ;  How many 50 Hz ticks since the last call. The counter is one byte and
    ;  free-runs, so the subtraction wraps correctly for anything under five
    ;  seconds -- and a game frame is a fifth of that at its very worst.
    ld a,(sys_tick_50hz)
    ld b,a
    ld hl,mus_last_tick
    sub (hl)
    ld (hl),b
    or a
    ret z                               ; same tick: nothing to do

    ld (mus_elapsed),a

    ld hl,mus_v0
    ld de,snd_voice_a
    ld bc,mus_c0
    call mus_one

    ld hl,mus_v1
    ld de,snd_voice_b
    ld bc,mus_c1
    call mus_one

    ld hl,mus_v2
    ld de,snd_voice_c
    ld bc,mus_c2
    jp mus_one


; ----------------------------------------------------------------------------
;  mus_one -- advance one voice and refresh its block
;  In : HL -> the stream pointer, DE -> the voice block, BC -> the countdown
;  Uses: everything
; ----------------------------------------------------------------------------
mus_one:
    ld (mus_ptr_at),hl
    ld (mus_block),de
    ld (mus_count_at),bc

    ;  Take the elapsed ticks off the countdown, and fetch while it is spent.
    ;  A loop rather than a single subtract, because one call may cross a note
    ;  boundary -- at five frames a second a frame is ten ticks and the
    ;  shortest note here is fifty, but a slow frame must not desynchronise
    ;  the three voices from each other.
    ld a,(mus_elapsed)
    ld (mus_left),a

@mus_step:
    ld hl,(mus_count_at)
    ld a,(hl)
    or a
    jr z,@mus_fetch

    ld b,a
    ld a,(mus_left)
    cp b
    jr nc,@mus_spend_all                ; the elapsed time swallows the rest

    ;  The note survives: take the elapsed time off it and stop.
    ld a,b
    ld hl,mus_left
    sub (hl)
    ld hl,(mus_count_at)
    ld (hl),a
    ret

@mus_spend_all:
    sub b
    ld (mus_left),a
    ld hl,(mus_count_at)
    ld (hl),0
    ld a,(mus_left)
    or a
    ret z                               ; exactly used up; the next call fetches

@mus_fetch:
    ld hl,(mus_ptr_at)
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = the stream position
    ld a,(de)
    cp MUS_END
    jr nz,@mus_take

    ;  Round again: this is a loop, not a piece with an end.
    call mus_rewind
    ld hl,(mus_ptr_at)
    ld e,(hl)
    inc hl
    ld d,(hl)

@mus_take:
    ld a,(de)
    ld (mus_note),a
    inc de
    ld a,(de)
    ld (mus_vol),a
    inc de
    ld a,(de)
    ld (mus_dur),a
    inc de

    ld hl,(mus_ptr_at)
    ld (hl),e
    inc hl
    ld (hl),d

    ld hl,(mus_count_at)
    ld a,(mus_dur)
    ld (hl),a

    call mus_write_block
    jr @mus_step


; ----------------------------------------------------------------------------
;  mus_rewind -- point this voice back at the top of its stream
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
mus_rewind:
    ld hl,(mus_ptr_at)
    ld de,mus_v0
    ld a,l
    cp e
    jr nz,@mus_rw_1
    ld de,mus_menu_bass
    jr @mus_rw_set
@mus_rw_1:
    ld de,mus_v1
    cp e
    jr nz,@mus_rw_2
    ld de,mus_menu_harmony
    jr @mus_rw_set
@mus_rw_2:
    ld de,mus_menu_lead
@mus_rw_set:
    ld (hl),e
    inc hl
    ld (hl),d
    ret


; ----------------------------------------------------------------------------
;  mus_write_block -- the current note into the voice block
;  Uses: AF, DE, HL
;
;  This is the whole of the "player": six bytes that make snd_update hold a
;  note. A rest writes timer 0, which is exactly what snd_step reads as idle.
; ----------------------------------------------------------------------------
mus_write_block:
    ld hl,(mus_block)
    ld a,(mus_note)
    or a
    jr nz,@mus_wb_sound

    ld (hl),0                           ; timer 0: idle, and snd_update mutes it
    ret

@mus_wb_sound:
    dec a                               ; the period table is one-based
    add a,a
    ld e,a
    ld d,0
    push hl
    ld hl,mus_menu_periods
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = the twelve-bit period
    pop hl

    ld (hl),MUS_TIMER                   ; +0 timer
    inc hl
    ld (hl),0                           ; +1 pri: an effect may still take it
    inc hl
    ld a,(mus_vol)
    add a,a
    add a,a
    add a,a
    add a,a
    ld (hl),a                           ; +2 vol, as the top nibble
    inc hl
    ld (hl),0                           ; +3 dvol: no decay, so no wobble
    inc hl
    ld (hl),e                           ; +4 period low
    inc hl
    ld (hl),d                           ; +5 period high
    inc hl
    ld (hl),0                           ; +6 dstep: no sweep
    inc hl
    ld (hl),0                           ; +7
    ret


; ============================================================================
;  State
; ============================================================================
mus_v0:             defw 0
mus_v1:             defw 0
mus_v2:             defw 0
mus_c0:             defb 0
mus_c1:             defb 0
mus_c2:             defb 0

mus_ptr_at:         defw 0
mus_count_at:       defw 0
mus_block:          defw 0
mus_last_tick:      defb 0
mus_elapsed:        defb 0
mus_left:           defb 0
mus_note:           defb 0
mus_vol:            defb 0
mus_dur:            defb 0
