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
;      slow   = 1        one step a tick -- see the prescaler in sys/sound.asm.
;      slowc  = 1        MUST NOT be left at 0: snd_step reads that as 256 and
;                        the voice would hold for five seconds before moving.
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
;  THREE VOICES, and this is the MENU's mode: nothing else is making a sound
;  on that screen, so the tune has the chip to itself.
mus_start:
    xor a
    ld (mus_solo),a
    ld a,SND_MIX_B_TONE                 ; B carries the harmony on this screen
    ld (snd_mix_mask_b),a
    jr @mus_begin

; ----------------------------------------------------------------------------
;  mus_start_solo -- the same tune under the GAME, on channel C alone
;
;  WHICH CHANNEL IS NOT A CHOICE, and that is worth writing down because
;  todo.md called it a taste problem that "wants an ear". The game's effects
;  already own two of the three: snd_fire is on A, snd_explosion and snd_hit
;  are on B -- B is the noise voice, which is where section 12 puts them --
;  and C is used by NOTHING but the jump, which stops the world anyway. So
;  there is exactly one voice free during a battle and the question answers
;  itself.
;
;  The BASS, because that is what is left when you have one voice. The piece
;  is D Aeolian over a drone and the bass is the part that moves under
;  everything else; the lead is absent a third of the cycle and would come and
;  go, and the harmony on its own is two notes with nothing under them.
;
;  It is also why MUSIC3 was composed the way it was -- quiet, flat, no
;  tremolo, "the one meant to sit under something". This is the something.
; ----------------------------------------------------------------------------
mus_start_solo:
    ld a,1
    ld (mus_solo),a
    ld a,SND_MIX_B_NOISE                ; ...and B is the explosions again
    ld (snd_mix_mask_b),a

@mus_begin:
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

    ;  ...unless the player has asked for silence. THE MUTE OUTLIVES THE
    ;  SCREEN: `M` is one key with one meaning on the title and in the game
    ;  alike, so somebody who turned the tune off on the menu must not have it
    ;  come back the moment a mission starts. mus_toggle owns this byte and
    ;  nothing else writes it.
    ld a,(mus_muted)
    or a
    jr nz,mus_stop
    ld a,1
    ld (snd_music_on),a
    ret


; ----------------------------------------------------------------------------
;  mus_stop -- silence, and hand the channels back to the effects
;  Uses: AF, HL, BC
; ----------------------------------------------------------------------------
mus_stop:
    ld a,SND_MIX_B_NOISE                ; nothing of ours is on B any more
    ld (snd_mix_mask_b),a
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
    ld a,(mus_muted)
    xor 1
    ld (mus_muted),a
    or a
    jr nz,mus_stop

    ;  Coming back on: whichever mode this screen is in. mus_solo survives the
    ;  mute, so `M` twice in a battle brings back the battle's single voice and
    ;  not the menu's three.
    ld a,(mus_solo)
    or a
    jr nz,mus_start_solo
    jr mus_start


; ----------------------------------------------------------------------------
;  mus_update -- one call a frame; advances by however many ticks have passed
;  Uses: everything
; ----------------------------------------------------------------------------
mus_update:
    ld a,(snd_music_on)
    or a
    ret z

    call mus_duck
    call mus_battle                     ; bank 4: silent while shots are landing

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

    ;  ONE VOICE IN THE GAME, on channel C, and the other two are not touched
    ;  at all -- A and B belong to the shots and the explosions. Filling them
    ;  would not share the chip, it would fight for it: an effect takes a
    ;  channel by priority and the music only rewrites a block at a NOTE
    ;  boundary, so a shot would silence a voice for whole seconds at a time.
    ld a,(mus_solo)
    or a
    jr z,@mus_full

    ld hl,mus_v0
    ld de,snd_voice_c
    ld bc,mus_c0
    jp mus_one

@mus_full:
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
;  mus_duck -- go quiet while an effect is sounding, and come back after
;  Uses: AF, HL, DE
;
;  "Pause music on sound effects." The battle's effects are on channels A and
;  B and the music is on C, so without this they simply play at once and the
;  drone sits underneath every shot. Ducking gives the effect the room.
;
;  IT IS A LEVEL AND NOT A PAUSE OF THE STREAM, deliberately. Stopping the
;  music's clock would make the tune drift by however long the battle lasted,
;  and it would come back in the wrong place relative to nothing in
;  particular; and it would have to be un-stopped by something. Writing the
;  voice's volume byte leaves the note sounding underneath at zero and puts it
;  back untouched -- one byte down, one byte up, and the tune keeps its time.
;
;  A single `ld (nn),a` needs no DI. snd_update reads this byte from the
;  interrupt, but a byte write is atomic on a Z80: the worst case is one tick
;  played at the old level, which is 20 ms of a note that is seconds long.
;  snd_start holds DI because it copies EIGHT bytes and a half-copied
;  descriptor is a real sound.
;
;  THE GAME ONLY. On the menu the music has all three voices and nothing else
;  makes a sound at all, so there is nothing to duck for.
; ----------------------------------------------------------------------------
mus_duck:
    ld a,(mus_solo)
    or a
    ret z

    ;  Is C ours to touch? A priority on it means the JUMP has taken the
    ;  channel, and its own descriptor owns the level -- writing zero there
    ;  would cut the arrival's fade in half.
    ld a,(snd_voice_c + SND_V_PRI)
    or a
    ret nz

    ;  Is anything sounding on A or B? In a mission those two are the effects
    ;  and nothing else: snd_fire has A, snd_explosion and snd_hit have B.
    ld a,(snd_voice_a + SND_V_TIMER)
    ld hl,snd_voice_b + SND_V_TIMER
    or (hl)
    jr nz,@mus_duck_down

    ;  Nothing is: come back up, if we are down.
    ld a,(mus_ducked)
    or a
    ret z
    xor a
    ld (mus_ducked),a
    ld a,(mus_duck_vol)
    ld (snd_voice_c + SND_V_VOL),a
    ret

@mus_duck_down:
    ld a,(mus_ducked)
    or a
    ret nz                              ; already down; the level is saved
    ld a,(snd_voice_c + SND_V_VOL)
    ld (mus_duck_vol),a
    xor a
    ld (snd_voice_c + SND_V_VOL),a
    ld a,1
    ld (mus_ducked),a
    ret


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

    ;  AN EFFECT OWNS THIS VOICE: leave it alone. The music writes pri 0, so
    ;  its own blocks fall through here and are refreshed normally; anything
    ;  with a priority is a shot, a kill or a jump and it wins.
    ;
    ;  It matters on channel C and only there, because that is the voice the
    ;  game's music has and the jump's sound has -- and the jump's is 4.6
    ;  seconds long, which is longer than a note. Without this the tune walked
    ;  straight over the arrival, and the test for it read the BASS's period
    ;  where it wanted the sweep: "the period is 1703, outside the 55..715 the
    ;  in's own descriptor can reach".
    ;
    ;  The note is dropped rather than queued. The countdown has already been
    ;  set by the caller, so the stream stays in time with the other voices and
    ;  the music simply comes back at its next note -- which is what "an effect
    ;  interrupts the music" should sound like.
    ld a,(hl)                           ; +0 timer: is anything running?
    or a
    jr z,@mus_wb_free
    inc hl
    ld a,(hl)                           ; +1 pri
    dec hl
    or a
    ret nz

@mus_wb_free:
    ld a,(mus_held)
    or a
    jr nz,@mus_wb_idle                  ; a fight: the stream advances, silently
    ld a,(mus_note)
    or a
    jr nz,@mus_wb_sound
@mus_wb_idle:

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

    ;  ...and if the music is currently DUCKED, this note arrives quiet and the
    ;  level it would have had goes into the store instead. Without this a note
    ;  boundary during a shot would put the drone back at full volume until the
    ;  next frame noticed and ducked it again -- a fifth of a second of music
    ;  poking through every burst of fire.
    ld (mus_duck_vol),a                 ; the level this note would have had
    ld a,(mus_ducked)
    or a
    ld a,0                              ; ...and does not, while ducked
    jr nz,@mus_wb_level
    ld a,(mus_duck_vol)
@mus_wb_level:
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
    inc hl
    ld (hl),1                           ; +8 slow: one step per tick...
    inc hl
    ld (hl),1                           ; +9 slowc: ...starting with this one
    ret

;  THE STATE IS IN sys/sound.asm, in the LOW 16K, and the code is here in
;  bank 4. Same split as order.asm/ordercmd.asm and for the two reasons that
;  one gives: it takes twenty bytes out of a bank window that was thirteen
;  over, and a variable in the bank has to be read with read_bank4 where one
;  down there is read with read_ram -- which is what a test of a note stream
;  wants to do.
