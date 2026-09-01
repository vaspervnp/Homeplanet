; ============================================================================
;  sys/sound.asm -- AY-3-8912 effects player (Homeplanet.md section 12)
; ============================================================================
;      Channel A   engines (low, varying with camera speed) and weapon fire
;      Channel B   noise: explosions, hull breach
;      Channel C   alerts, and music on the menu / jump / mission-end screens
;
;  There is no music during a battle -- only sounds, as in the game this is
;  modelled on. The player runs off the 300 Hz interrupt and does its work
;  every sixth one, i.e. at 50 Hz.
;
;  ---------------------------------------------------------------------------
;  Why the envelopes are in software
;
;  The AY has exactly ONE envelope generator, shared by all three channels. Two
;  effects overlapping -- a hit while an explosion is still ringing -- would
;  have to share its shape and its retrigger, so the second one would restart
;  the first. Every channel therefore gets its own envelope here: one byte of
;  volume, one byte of decay, stepped once per tick. Amplitude bit 4 (the "use
;  the hardware envelope" bit) is never set, and R11/R12/R13 are never written.
;
;  ---------------------------------------------------------------------------
;  Sharing the PSG with key_scan -- read that file's header first
;
;  PPI port A is the bidirectional data bus to the PSG, and its direction lives
;  in the PPI control word. key_scan needs it as an INPUT to read the keyboard
;  columns back out of PSG register 14; we need it as an OUTPUT to hand the PSG
;  register numbers and values. The contract between the two routines is:
;
;      A-OUTPUT, port C = PSG_INACTIVE is the machine's RESTING state.
;
;  key_scan flips port A to input, reads its ten rows, and puts it back before
;  it returns -- all inside DI, precisely so that this routine cannot land in
;  the middle of it. Coming the other way, snd_update runs from the interrupt
;  and can be entered at any instruction boundary the main loop reaches, so it
;  asserts the resting state on entry rather than assuming it, and every PSG
;  access it makes ends with port C back at PSG_INACTIVE.
;
;  Two more things this code must never do, because both silently kill the
;  keyboard rather than the sound:
;
;    - set bit 6 of the mixer register R7. That bit is the PSG's own port A
;      direction, and the keyboard columns only reach the CPU while it is 0.
;      SND_MIXER_OFF has it clear and the per-channel masks only ever clear
;      further bits, so it cannot come on by accident.
;    - write to the PSG without latching a register address first. The address
;      key_scan leaves latched is 14 -- port A -- so a stray write would land
;      on the keyboard's own column register.
; ----------------------------------------------------------------------------

;  Channel numbers. snd_update walks the voices in this order and derives the
;  PSG register numbers from the index, so these are the layout, not labels
;  for it -- see the asserts under the voice blocks.
SND_CH_A            equ 0
SND_CH_B            equ 1
SND_CH_C            equ 2

;  One voice block, and also one effect descriptor: they have identical layout
;  so that starting an effect is a single LDIR of the descriptor over the
;  voice.
;
;      +0  timer   STEPS left. 0 means idle, and it is the ONLY thing that
;                  ends a sound -- a decay that never quite reaches zero
;                  cannot leave a channel droning.
;      +1  pri     priority of the effect that owns the channel; 0 when idle
;      +2  vol     8-bit volume accumulator; the PSG gets the top nibble
;      +3  dvol    subtracted from vol every STEP, saturating at zero
;      +4  period  16-bit accumulator: tone period on A and C, and on B the
;      +5          high byte is the noise generator's 5-bit period
;      +6  dstep   added to period every STEP, signed -- the pitch sweep
;      +7
;      +8  slow    how many 50 Hz TICKS make one step of this voice; 1 is
;                  every tick, which is what every battle effect uses
;      +9  slowc   the countdown to the next step. A descriptor sets it to 1
;                  so the sound moves on the first tick it is heard.
SND_VOICE_SIZE      equ 10

SND_V_SLOW          equ 8
SND_V_SLOWC         equ 9

;  ---------------------------------------------------------------------------
;  THE PRESCALER, AND WHY THE TIMER IS STILL ONE BYTE
;
;  The timer is the only thing that ends a sound and it is a byte, so the
;  longest sound this engine could play was 255 ticks -- 5.1 seconds. The jump
;  now wants 300 ticks going out and 880 coming back, and neither fits.
;
;  `slow` is what buys it: a voice advances its envelope, its sweep and its
;  timer once every `slow` ticks rather than every tick, so the timer counts
;  STEPS and the sound lasts `timer * slow` of them. One byte per voice, and it
;  fixes the DECAY at the same time and for the same reason -- `dvol` is also
;  an integer, and 255 levels spread over 880 ticks would need a third of a
;  level a tick, which is not a number a byte can hold. Over 220 steps it is 1.
;
;  What it costs is RESOLUTION: at slow 4 the pitch moves 12.5 times a second
;  rather than 50, so a long sweep is a staircase rather than a glide. That is
;  why the jump descriptors carry the SMALLEST `slow` their length allows
;  (3 and 4, not 10) and take a longer timer instead, and it is the whole
;  reason `slow` is per descriptor rather than one constant.
;
;  The alternatives, and why not:
;    - re-arming the descriptor as it expires: something has to do the
;      re-arming, and the only thing running is snd_update, in the interrupt,
;      while the transition owns the main loop. That is a second mechanism to
;      get the sweep to CONTINUE rather than restart, for the same byte.
;    - a 16-bit timer: fixes the length and does nothing for `dvol`, so the
;      880-tick sound would still fall silent a third of the way through.
;      This one field does both.
;  ---------------------------------------------------------------------------

;  Mixer register R7, active LOW: a 0 bit ENABLES. Start from everything muted
;  and let each live channel clear its own bit.
;    bits 0-2  tone A/B/C off      bits 3-5  noise A/B/C off
;    bit 6     PSG port A = output <- must stay 0 or the keyboard goes deaf
;    bit 7     PSG port B = output (no port B on the 8912)
SND_MIXER_OFF       equ %00111111

SND_REG_NOISE       equ 6               ; noise period, 5 bits
SND_REG_MIXER       equ 7
SND_REG_AMP_A       equ 8               ; amplitudes are 8, 9, 10 = 8 + channel

SND_NOISE_MASK      equ %00011111       ; R6 is five bits wide


; ----------------------------------------------------------------------------
;  snd_init -- silence everything and set the PSG up
;
;  In : -
;  Out: all three voices idle, all three amplitudes 0, mixer fully muted
;  Uses: AF, BC, DE, HL
;
;  Interrupts are deliberately NOT touched. This is a one-shot called from
;  sys_boot, which runs its whole body inside its own DI/EI pair; an EI here
;  would hand the machine back to the interrupt handler halfway through the
;  boot. There is nothing to race with either way -- snd_update cannot be
;  running yet, because the voices it reads are what we are about to zero.
;
;  Silencing is done by zeroing the voices and then running one ordinary tick,
;  rather than by a separate table of quiet register values. That way "silent"
;  is by construction exactly what snd_update produces for idle voices, and
;  there is no second definition of it to drift.
; ----------------------------------------------------------------------------
snd_init:
    ld hl,snd_voice_a
    ld de,snd_voice_a + 1
    ld bc,SND_VOICE_SIZE * 3 - 1
    ld (hl),0
    ldir
    jp snd_update


; ----------------------------------------------------------------------------
;  snd_update -- one 50 Hz tick. Called FROM THE INTERRUPT.
;
;  In : -
;  Out: the PSG reprogrammed for this tick
;  Uses: AF and HL freely -- sys_irq has already saved those -- plus BC and DE,
;        which it saves and restores itself. IX, IY and the shadow set are
;        never touched.
;
;  Interrupts are off for the whole of this (the handler has not EI'd yet), so
;  nothing can observe the voice blocks mid-update.
; ----------------------------------------------------------------------------
snd_update:
    push bc
    push de

    ;  Assert the resting PPI state rather than assume it. This is four bytes
    ;  of insurance against being entered from somewhere that left port A as
    ;  an input, in which case every OUT below would go into the void and the
    ;  symptom would be silence with nothing wrong in the source.
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_OUT
    out (c),c

    ld a,SND_MIXER_OFF
    ld (snd_mixer),a                    ; each live channel clears its own bit

    ;  C is the channel number for the whole loop and doubles as the low byte
    ;  of every port address we use -- harmlessly, because the CPC decodes the
    ;  PPI on the HIGH byte alone (A11 low, A9/A8 pick the register), which is
    ;  the same trick key_scan's row loop plays.
    ld c,SND_CH_A
    ld hl,snd_voice_a
@snd_ch:
    call snd_step
    jr nc,@snd_ch_amp                   ; idle: A is 0, so fall into the
                                        ; amplitude write and mute it

    ; --- the pitch, to the tone period registers of this channel ----------
    push af                             ; the volume snd_step just worked out
    push hl                             ; the voice base
    inc hl
    inc hl
    inc hl
    inc hl                              ; -> +4, period low
    ld e,(hl)
    ld a,c
    add a,a                             ; register 2*channel = period fine
    call snd_psg_out
    inc hl                              ; -> +5, period high
    ld e,(hl)
    ld a,c
    add a,a
    inc a                               ; register 2*channel+1 = period coarse
    call snd_psg_out

    ;  Channel B is the noise voice, so the same accumulator also drives the
    ;  noise generator. Its tone registers were written just above and that is
    ;  harmless -- the mixer keeps tone B muted -- and costs less than
    ;  branching around them would.
    ld a,c
    sub SND_CH_B
    jr nz,@snd_ch_mix
    ld a,(hl)                           ; still +5, the period high byte
    and SND_NOISE_MASK
    ld e,a
    ld a,SND_REG_NOISE
    call snd_psg_out

@snd_ch_mix:
    ;  Unmute this channel: tone for A and C, noise for B.
    ld hl,snd_mix_mask
    ld b,0
    add hl,bc
    ld a,(snd_mixer)
    and (hl)
    ld (snd_mixer),a

    pop hl
    pop af

@snd_ch_amp:
    ;  A is 0..15 for a live voice and exactly 0 for an idle one, so this is
    ;  also what turns a finished sound off.
    ld e,a
    ld a,c
    add a,SND_REG_AMP_A                 ; amplitude register 8 + channel
    call snd_psg_out

    ld de,SND_VOICE_SIZE
    add hl,de
    inc c
    ld a,c
    cp 3
    jr c,@snd_ch

    ; --- the mixer last -------------------------------------------------
    ;  After the amplitudes, so that a channel which has just gone quiet is
    ;  already at volume 0 by the time its mixer bit is set: opening the mixer
    ;  on a stale amplitude is what makes a click.
    ld a,(snd_mixer)
    ld e,a
    ld a,SND_REG_MIXER
    call snd_psg_out

    pop de
    pop bc
    ret


; ----------------------------------------------------------------------------
;  snd_step -- advance one voice's envelope and pitch sweep by a tick
;
;  In : HL = voice block
;  Out: CF set   -> the voice is live and A is its PSG volume, 0..15
;       CF clear -> the voice is idle and A is 0, which the caller writes to
;                   the amplitude register unchanged
;       HL unchanged in both cases
;  Uses: AF, DE. BC is saved, because the caller is holding the channel number
;        in C across the whole loop.
;
;  The two CF-clear exits both come after an `or a`, and nothing between there
;  and the RET writes the carry -- DEC, LD and INC HL all leave it alone. That
;  is load-bearing: there is no explicit "clear carry" instruction on those
;  paths.
;
;  A voice only STEPS every (+8) ticks -- see the prescaler note at the top of
;  this file. On the ticks in between it is still live and still sounding, so
;  it reports the level it already has and the caller rewrites the same
;  registers; nothing branches on "did it move".
; ----------------------------------------------------------------------------
snd_step:
    ld a,(hl)                           ; +0, the timer
    or a
    ret z                               ; already idle, A = 0, CF clear

    ;  --- the prescaler ----------------------------------------------------
    ;  slowc is never 0 on a live voice: a descriptor sets it to 1 and this
    ;  reloads it from slow, which is at least 1 in every descriptor there is.
    ;  Zero here would be read as 256 and the voice would hold for five
    ;  seconds -- see mus_write_block, the only other thing that fills a block.
    push hl
    ld de,SND_V_SLOWC
    add hl,de
    ld a,(hl)
    dec a
    ld (hl),a
    jr z,@snd_step_due
    pop hl
    jr @snd_step_hold

@snd_step_due:
    dec hl                              ; -> +8, the reload
    ld a,(hl)
    inc hl
    ld (hl),a                           ; slowc = slow
    pop hl

    ld a,(hl)                           ; +0, the timer, in STEPS
    dec a
    ld (hl),a
    jr nz,@snd_step_live

    ;  The timer has just run out. Dropping the priority here is what releases
    ;  the channel for the next effect, and returning "idle" mutes it. This is
    ;  the hard stop: whatever the decay did, a sound cannot outlive its timer.
    inc hl
    ld (hl),a                           ; pri = 0 (A is 0)
    dec hl
    ret                                 ; A = 0, CF still clear

;  A tick the prescaler swallowed: nothing moves, and the level already in the
;  block is what the channel goes on sounding at.
@snd_step_hold:
    inc hl
    inc hl                              ; -> +2, vol
    ld a,(hl)
    dec hl
    dec hl                              ; -> +0, as the contract promises
    jr @snd_step_amp

@snd_step_live:
    push bc

    ; --- pitch sweep: period += dstep, 16-bit signed ---------------------
    inc hl
    inc hl
    inc hl
    inc hl                              ; -> +4
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = period
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)                           ; BC = dstep      (-> +7)
    ex de,hl
    add hl,bc
    ex de,hl                            ; DE = period + dstep, HL back to +7
    dec hl
    dec hl
    dec hl                              ; -> +4
    ld (hl),e
    inc hl
    ld (hl),d                           ; -> +5

    pop bc

    ; --- decay: vol -= dvol, saturating at silence -----------------------
    dec hl
    dec hl                              ; -> +3, dvol
    ld e,(hl)
    dec hl                              ; -> +2, vol
    ld a,(hl)
    sub e
    jr nc,@snd_step_store
    xor a                               ; underflow: stop at zero, do not wrap
@snd_step_store:
    ld (hl),a
    dec hl
    dec hl                              ; -> +0, as the contract promises

    ;  The accumulator is 8 bits so that a decay can be finer than one PSG
    ;  step; the chip only wants the top nibble.
@snd_step_amp:
    rrca
    rrca
    rrca
    rrca
    and #0F
    scf
    ret


; ----------------------------------------------------------------------------
;  snd_psg_out -- write one PSG register
;
;  In : A = register number, E = value
;  Out: PPI port C left at PSG_INACTIVE, port A still an output
;  Uses: AF, B. C, DE and HL survive, which is what lets snd_update keep the
;        channel number in C and a voice pointer in HL across every call.
;
;  Address then data, with the control lines dropped to PSG_INACTIVE between
;  the two. The drop matters: the PPI's port A latch is wired straight to the
;  PSG's data bus, so changing what is on it while BDIR is still asserted would
;  be a second write with the wrong value.
; ----------------------------------------------------------------------------
snd_psg_out:
    ld b,PPI_PORT_A
    out (c),a                           ; register number onto the data bus
    ld b,PPI_PORT_C
    ld a,PSG_SELECT
    out (c),a                           ; BDIR+BC1 latches it as the address
    xor a                               ; PSG_INACTIVE
    out (c),a
    ld b,PPI_PORT_A
    out (c),e                           ; the value
    ld b,PPI_PORT_C
    ld a,PSG_WRITE
    out (c),a                           ; BDIR alone writes it
    xor a
    out (c),a
    ret


; ----------------------------------------------------------------------------
;  snd_fire -- a weapon discharge (channel A)
;  snd_explosion -- a ship dying (channel B, noise)
;  snd_hit -- a hull taking damage but surviving (channel B, noise)
;  snd_jump_out -- the fleet leaving a system (channel C, tone)
;  snd_jump_in -- the fleet arriving in the next one (channel C, tone)
;
;  In : -
;  Out: the effect owns its channel, unless something louder already does
;  Uses: AF, BC, DE, HL
;
;  Call these from the MAIN LOOP, not from the interrupt: like key_scan they
;  end with an unconditional EI. See snd_start.
; ----------------------------------------------------------------------------
snd_jump_out:
    ld hl,snd_fx_jump_out
    ld de,snd_voice_c
    jr snd_start

snd_jump_in:
    ld hl,snd_fx_jump_in
    ld de,snd_voice_c
    jr snd_start

snd_fire:
    ld hl,snd_fx_fire
    ld de,snd_voice_a
    jr snd_start

snd_explosion:
    ld hl,snd_fx_explosion
    ld de,snd_voice_b
    jr snd_start

snd_hit:
    ld hl,snd_fx_hit
    ld de,snd_voice_b
    ; fall through -- nothing may be inserted between here and snd_start


; ----------------------------------------------------------------------------
;  snd_start -- give a channel to an effect, if the effect outranks it
;
;  In : HL = effect descriptor, DE = voice block
;  Out: the descriptor copied over the voice, or nothing at all
;  Uses: AF, BC, DE, HL
;
;  Explosions and hull hits share channel B, and they do not arrive politely:
;  a ship taking a graze one tick into a neighbour's death would otherwise cut
;  the explosion off after a frame and a half. So a new effect only takes the
;  channel if its priority is at least that of whatever is running -- "at
;  least", not "greater", so that a second shot still retriggers the first.
;
;  Interrupts are off across the copy because snd_update is reading the same
;  eight bytes from the interrupt. Without it an interrupt landing between the
;  timer and the period could play one tick of the new sound at the old pitch.
;  That is the same reasoning, and the same DI...EI shape, as key_scan.
; ----------------------------------------------------------------------------
snd_start:
    di

    ld a,(de)                           ; +0, the running effect's timer
    or a
    jr z,@snd_start_take                ; idle, so the channel is free

    inc de
    ld a,(de)                           ; +1, its priority
    dec de
    ld b,a
    inc hl
    ld a,(hl)                           ; the new effect's priority
    dec hl
    cp b
    jr nc,@snd_start_take

    ei
    ret

@snd_start_take:
    ld bc,SND_VOICE_SIZE                ; a descriptor IS a voice block
    ldir
    ei
    ret


; ============================================================================
;  Effect descriptors
; ============================================================================
;  Layout is SND_VOICE_SIZE bytes, identical to a voice block, so snd_start
;  can LDIR one straight over the other.
;
;      timer, pri, vol, dvol, period, dstep, slow, slowc
;
;  Tone period p on channel A or C is 125000/p Hz. Volume is the 8-bit
;  accumulator, so #FF is PSG 15 and #10 is PSG 1; the decay is chosen to
;  reach zero at about the same STEP the timer does, so the sound fades out
;  instead of being cut off, and the timer is only the backstop.
;
;  The last two bytes are the prescaler. The three battle effects are all
;  short, so all three run at `slow` 1 -- one step a tick, exactly as they did
;  before it existed -- and `slowc` 1 makes the first tick a step. Only the
;  jump needs anything else; see the note at the top of this file.
; ----------------------------------------------------------------------------

;  A short descending zap. 8 ticks = 160 ms. Period 90 -> 410 is roughly
;  1400 Hz down to 300 Hz, which reads as a discharge rather than a beep.
snd_fx_fire:
    defb 8, SND_PRI_FIRE, #FF, 32
    defw 90, 40
    defb 1, 1

;  A ship dying: 24 ticks = 480 ms of noise whose period is swept from 2 to
;  20, i.e. a bright crack collapsing into a rumble, under a slow decay.
snd_fx_explosion:
    defb 24, SND_PRI_EXPLOSION, #FF, 11
    defw #0200, #00C0
    defb 1, 1

;  A hull surviving a hit: 6 ticks = 120 ms, quieter than an explosion and
;  duller (a higher noise period from the start), so the two are told apart by
;  timbre and not only by length.
snd_fx_hit:
    defb 6, SND_PRI_HIT, #E0, 40
    defw #0800, #0100
    defb 1, 1

; ----------------------------------------------------------------------------
;  The jump: one sound going out and one coming in, and they are a PAIR
; ----------------------------------------------------------------------------
;  "One sound for the jump out and one for the jump in." They are the same
;  gesture run in opposite directions -- one sweep across the same span of
;  pitch, up as the fleet dissolves and down as it settles into the next system
;  -- so what a player hears is "left" and "arrived" rather than two unrelated
;  noises. Under a level that only ever falls, because the envelope engine
;  subtracts and has no attack; the direction that is genuinely reversible is
;  the PITCH, and that is what carries the mirror.
;
;      out   period 620 -> 26     pitch RISING,  100 steps x 3 = 300 ticks = 6.0 s
;      in    period  55 -> 712    pitch FALLING, 220 steps x 4 = 880 ticks = 17.6 s
;
;  TEN TIMES THE LENGTH THEY WERE, because the picture is: "θέλω η ταχύτητα του
;  jump in και του jump out να είναι 10 φορές πιο αργή. Και ο ήχος να είναι
;  αντίστοιχα τόσος." Neither length fits a one-byte timer, and the prescaler
;  at the top of this file is what buys them; the two `slow` values here are
;  the smallest that make the timers fit, because `slow` is exactly the
;  coarseness of the sweep. At 3 the out moves 16.7 times a second and at 4 the
;  in moves 12.5 -- a fine enough staircase to read as a glide, where the
;  obvious `slow` 10 with the old 30- and 88-step timers would have moved five
;  times a second and read as an arpeggio.
;
;  THE SPAN IS THE SAME GESTURE, not the same numbers. The endpoints moved
;  because `dstep` is an integer and 660 over 99 steps is 6.67: the out is
;  620 -> 26 at -6 a step where it was 680 -> 20 at -22, and the in is 55 -> 712
;  at +3 where it was 42 -> 658 at +7. Both still cross about four octaves, and
;  the out's audible end (68) and the in's audible start (58) are still within
;  a fifth of each other, which is what test_they_are_one_gesture_run_both_ways
;  holds them to.
;
;  THE LEVELS ARE 200 AND 220 RATHER THAN 255, and that is arithmetic and not
;  taste: `dvol` is an integer too, so a decay that reaches silence exactly as
;  the timer runs out needs vol = dvol * timer. 2 x 100 and 1 x 220. It starts
;  at PSG 12 and 13 instead of 15, which is 6 and 3 dB down -- and over six and
;  seventeen seconds that is the right direction anyway.
;
;  Those are the endpoints of the accumulator; what is AUDIBLE is a little
;  narrower at both ends, and is read off the chip in the last paragraph here.
;  The in stops one step short of 715 because snd_step does not sweep on the
;  tick the timer expires on -- it returns idle instead.
;
;  CHANNEL C, and the choice is already made at the top of this file: section
;  12 gives C "alerts, and music on the menu / JUMP / mission-end screens".
;  It is a tone channel, which is right -- a jump is a drive spooling and not
;  an explosion -- and it is the one channel nothing else in the game has ever
;  used, so the jump can neither be cut short by a laser shot on A nor mute a
;  death on B. Noise underneath the sweep was considered and left alone: it
;  would have to go on B, which is where the deaths are, and it is a second
;  descriptor and a second snd_start for a thing the owner asked for as one
;  sound.
;
;  PRIORITY 4, above all three battle effects. Nothing else uses channel C, so
;  today this is only ever compared against the other half of a jump -- but the
;  number is the honest statement of the rule, and the day C is given the
;  alerts the file header promises, a jump will still win. Both halves share it,
;  so `cp b : jr nc` ("at least", not "greater") lets one retrigger the other.
;
;  WHY THE OUT IS 300 TICKS AND NOT 350. mis_jump runs jfx_vanish to completion
;  and only THEN writes the fleet to the disc -- and fdc_fleet_io holds DI for
;  the whole transfer, measured at 24 emulator frames, during which snd_update
;  does not run and a sound in progress would freeze mid-envelope and resume.
;
;  The vanish's FLOOR is now arithmetic rather than a measurement, which is the
;  one thing the slowdown made easier: it is JFX_VANISH_PASSES whole dwells of
;  JFX_VANISH_DWELL vertical blanks plus the two dark passes, and it cannot be
;  shorter however empty the screen is -- 14 * 23 + 2 = 324 ticks. Measured on
;  mission 1, with a fleet to draw, it is 359. So a 300-tick sound has
;  24 ticks of margin against the shortest vanish there can be, where the
;  30-tick one had five against the shortest one anybody had measured.
;
;  The decay reaches zero at step 100 of 100 and PSG 0 at step 93, so the sound
;  is silent from tick 279 -- 45 ticks before the floor. That is the second
;  net, and it is the same one as before: a frozen channel at amplitude 0 is
;  silence.
;
;  Tone period p is 62500/p Hz -- the AY is clocked at 1 MHz and divides by 16.
;  (The comment above snd_fx_fire says 125000/p, and so does tools/genmusic.py;
;  that is an octave out. Not touched here, because correcting it would move
;  every note in the music by an octave and that is a decision for an ear.)
;
;  The out is audible over steps 1..92 -- 102 Hz to 919 Hz -- and the in over
;  1..203, 1078 Hz back down to 94 Hz. The PITCHES are unchanged by the reveal
;  being halved; only how fast they are walked is. Both are read off the chip's own
;  registers by tests/test_sound.TestTheJump, which samples one step at a time. Neither period ever wraps: 620 - 99*6 =
;  26 and 55 + 219*3 = 712, both well inside the 12 bits the registers have.
snd_fx_jump_out:
    defb 100, SND_PRI_JUMP, 200, 2
    defw 620, -6
    defb 3, 1

snd_fx_jump_in:
    defb 220, SND_PRI_JUMP, 220, 1
    defw 55, 3
    ;  SLOW 2, NOT 4: the reveal was halved ("το jump in να είναι 2 φορές
    ;  γρηγορότερο"), so this is too. It is the PRESCALER that halves and not
    ;  the timer, and the difference is the whole point -- 220 steps at slow 2
    ;  is the same sweep in half the time, where a timer of 110 at slow 4
    ;  would be half the sweep and the sound would stop at the middle of its
    ;  own pitch range. Measured: the reveal is 468 emulator frames, and 220
    ;  steps x 2 is 440 ticks.
    defb 2, 1

;  Priorities. Only ever compared with each other, and only within a channel.
SND_PRI_HIT         equ 1
SND_PRI_FIRE        equ 2
SND_PRI_EXPLOSION   equ 3
SND_PRI_JUMP        equ 4

;  Mixer AND masks, indexed by channel number: each clears the one bit that
;  lets its channel through. Channel B's is the NOISE bit, not the tone bit --
;  that is where section 12's channel assignment actually lives.
snd_mix_mask:
    defb %11111110                      ; A: tone A on
    defb %11101111                      ; B: noise B on, tone B stays muted
    defb %11111011                      ; C: tone C on


; ============================================================================
;  Data
; ============================================================================
;  The three voices must be contiguous and in channel order: snd_update walks
;  them with one pointer and derives the PSG register numbers from the same
;  index it uses for snd_mix_mask.
snd_voice_a:        defs SND_VOICE_SIZE, 0
snd_voice_b:        defs SND_VOICE_SIZE, 0
snd_voice_c:        defs SND_VOICE_SIZE, 0

    assert snd_voice_b == snd_voice_a + SND_CH_B * SND_VOICE_SIZE, "voice B is not where the channel loop expects it"
    assert snd_voice_c == snd_voice_a + SND_CH_C * SND_VOICE_SIZE, "voice C is not where the channel loop expects it"
    assert (SND_MIXER_OFF & %01000000) == 0, "mixer bit 6 would make the PSG port A an output and kill the keyboard"

;  Mixer register R7 as it will be sent this tick, built up across the channel
;  loop. It lives in RAM rather than a register because every register is
;  already spoken for: HL is the voice pointer, C the channel number, B the
;  port, and AF/DE are scratch for snd_psg_out.
snd_mixer:          defb SND_MIXER_OFF
