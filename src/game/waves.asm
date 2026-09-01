; ============================================================================
;  game/waves.asm -- the pressure to leave, and the number that says if you can
; ============================================================================
;  Two things that look like two features and are one:
;
;      *  after a minute in a mission the Vekhar start arriving, in waves
;         of random size at random spacing, and they never stop;
;      *  the fleet's hull, as a percentage, at the top of the HUD strip.
;
;  They are one file because they are one number. A wave is sized against the
;  fleet's HULL -- not its headcount -- and the readout is that same hull
;  against what the same ships would have undamaged. One walk of the entity
;  table a frame feeds both, and the player can see the figure the game is
;  measuring them by.
;
;  WHY THE WAVES EXIST
;  -------------------
;  Section 10's campaign is about a fleet that only ever shrinks, and section 1
;  says the same thing in prose: what is lost is lost. But nothing made staying
;  cost anything. Once the picket was dead a mission was a room with the lights
;  on -- mine the fields dry, build what the RU will buy, jump when you feel
;  like it -- and `J` was a formality rather than a decision. The waves are what
;  put a price on the second hour of a mission that was won in the first ten
;  minutes.
;
;  WHY THE WAVE IS SIZED ON HULL
;  -----------------------------
;  The requirement is not "waves are hard", it is "the player still wins seven
;  times in ten", and that has to hold for a fleet that has already lost half
;  of itself by mission 7. So the wave cannot be an absolute number; it has to
;  be a fraction of what the player still has.
;
;  Of the things that could stand for "what the player still has", HULL is the
;  honest one and headcount is not. Headcount says a fleet of fifteen ships at
;  twenty hull each is as strong as fifteen fresh ones -- it is not, it dies to
;  the first volley. Summed hull falls when a ship is lost AND when a ship is
;  hurt, which are exactly the two ways a fleet becomes less able to take a
;  wave, and it needs no second table: it is one byte per entity, already
;  there. Divided by 256 it reads directly as "ships' worth of fleet left",
;  because an interceptor's hull is 255.
;
;  What it does NOT capture is the balance triangle: a harvester counts nearly
;  as much as an interceptor and shoots for 4 rather than 24. That is a real
;  approximation and it errs towards a wave that is too big for a fleet of
;  harvesters -- which no script and no sane player fields. tools/waverate.py
;  is what says whether the approximation holds, and it is measured, not
;  argued.
;
;  WHAT A WAVE DOES NOT DO
;  -----------------------
;  It does not stop the objective completing. A CLEAR mission asks for the
;  original picket and nothing else: ENT_F_WAVE marks the arrivals and
;  mis_count_enemies ignores them. The alternative -- counting them -- makes a
;  CLEAR mission uncompletable the moment the first wave lands, so `J` is never
;  offered and "loitering costs you" becomes "loitering traps you", which is
;  the opposite of the point.
;
;  They DO keep coming after the objective is met, and that is the whole
;  mechanism: the reason to jump is that staying is now expensive.
;
;  The clock is mis_timer, which mis_setup zeroes, so it resets on every jump
;  by construction -- the minute is per mission, not per campaign. And
;  because demo_update skips mis_update while order_paused is set, SPACE stops
;  the clock along with the battle, which is what a tactical pause is for.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  The clock, in GAME frames, because that is what mis_timer counts.
;
;  The design targets 12.5 fps and the game measures 7.1 (see the frame budget
;  in CLAUDE.md), so a wall-clock figure has to be converted at the rate the
;  machine actually runs at, not the one it aims at.
;
;  THE RATE IS RE-MEASURED EVERY TIME ONE OF THESE MOVES, and it has to be: it
;  was 5.0 when this file was written and 600 meant two minutes, and the work
;  that doubled the fleet took it to 7.1 -- so the same 600 had quietly become
;  a minute and a half without a line of this file changing. A constant in
;  game frames is a constant in SECONDS only against a rate somebody looked at.
;
;      DEMO_FRAMES over 1000 emulator frames, mission 1, this build: 7.10 fps
;
;  ONE MINUTE, on the design owner's instruction: "τα κύμματα επίθεσης να
;  αρχίζουν 1 λεπτό μετά την είσοδο στην πίστα". 60 * 7.1 = 426.
;
;  It is honest to a few per cent and no better: the frame rate falls as the
;  entity count rises, so a minute with a wave already on screen is nearer a
;  minute and a quarter. Making it exact would mean a second counter on
;  sys_tick_50hz, and mis_timer is already a word that already resets in
;  exactly the right place.
;
;  This is the third cut. It was three minutes, then two on the design owner's
;  instruction, and one now -- and the ones after the first are three times as
;  often as they first were. What that buys is that the loiter is no longer a
;  sequence of separate fights: the old spacing was 60 to 238 seconds and a
;  wave takes 20 to 40 to resolve, so one was always dead before the next
;  arrived. See the note on wave_next below.
; ----------------------------------------------------------------------------
WAVE_FIRST_FRAMES   equ 426             ; 1 minute at the measured 7.1 fps

;  HOW MANY WAVES A MISSION HAS TO SEE BEFORE IT MAY BE LEFT.
;
;  This inverts what the waves were for and the inversion is deliberate. They
;  were the price of STAYING -- "loitering costs you", so that `J` was a
;  decision rather than a formality. They are now the price of LEAVING, which
;  makes a mission a siege: clear what the mission put there, hold the ground
;  while three waves come at it, and only then go.
;
;  What it costs is the decision. There is nothing to weigh any more: you jump
;  when you are allowed to, and you are allowed when the board is clear and
;  the third wave is dead. What it buys is that no mission can be walked out
;  of -- see mis_gate in game/campaignrun.asm for the other half of the rule.
WAVE_BEFORE_JUMP    equ 3
WAVE_GAP_MIN        equ 100             ; ...and 14 to about 54 seconds after

;  The spacing is WAVE_GAP_MIN + 1.125 * a random byte, which reaches 386. It
;  was WAVE_GAP_MIN 300 + 3.5r, reaching 1192, and both ends are a third of
;  what they were: 300 -> 100 and 1192 -> 397, which 386 is within three per
;  cent of. The MEAN is the number that matters for "three times as often" and
;  it goes 746 -> 243, a factor of 3.07.
;
;  1.125 is three shifts and an add, against 3.5's two adds, a shift and an
;  add -- so the replacement is no dearer than the thing it replaces, which is
;  the whole reason 3.5 was picked over a multiply in the first place. A plain
;  r would have been cheaper still and gives a mean of 227, a factor of 3.3,
;  which is further from the three that was asked for than an `srl` is worth.

;  How many ships one wave may ever field, whatever the arithmetic says. The
;  entity table is 48 slots and the later missions already field twelve
;  hostiles; a wave that filled the table would cost the frame rate far more
;  than it cost the fleet.
WAVE_MAX            equ 8

;  Where they arrive. cam_sin returns +/-127, so the radius is 127 * this in
;  world units -- about 6100, which is beyond the picket at 5000 and well
;  inside the 8191 the projection can see. Close enough to be seen coming and
;  far enough to be seen coming FROM somewhere.
WAVE_RADIUS         equ 48
WAVE_RISE           equ 4               ; +/-508 world units of height
WAVE_ARC            equ 31              ; 45 degrees of jitter about the bearing

;  A wave ship's hull, randomised: this is the "strength" half of "random in
;  number and strength". The picket's is a flat 200, so a wave runs from
;  noticeably softer to slightly tougher than the mission's own garrison.
WAVE_HULL_MIN       equ 120
WAVE_HULL_SPAN      equ 127             ; masked, so 120..247

;  How long INCOMING stays up: game frames, so about eight seconds.
WAVE_SAY_FRAMES     equ 40

;  Game frames between readings of the fleet's hull. See wave_update.
WAVE_READ_EVERY     equ 4


; ----------------------------------------------------------------------------
;  wave_init -- a fresh mission: the clock back to a minute, no waves sent
;  Uses: everything
;
;  Called from mis_setup, which is the one path every mission arrives through
;  -- demo_init for the first and mis_jump for the rest.
; ----------------------------------------------------------------------------
wave_init:
    ld hl,WAVE_FIRST_FRAMES
    ld (wave_next),hl
    xor a
    ld (wave_count),a
    ld (wave_size),a
    ld (wave_say),a
    ;  The readout must be right on the first frame of the mission, not on the
    ;  second: mis_setup has just changed the fleet.
    jp wave_health


; ----------------------------------------------------------------------------
;  wave_update -- one game frame of the clock
;
;  Called from demo_update's playing path, straight after mis_update, so it
;  shares mis_timer's tick exactly -- including the sensor view, which runs the
;  battle at triple speed but still calls mis_update once.
;  Uses: everything
; ----------------------------------------------------------------------------
wave_update:
    ;  The walk below is about 5,000 T-states and this is a 530,000 T frame, so
    ;  a reading every frame is very nearly one per cent of it -- measured, 5.00
    ;  fps became 4.85 over two thousand frames, which is a real regression and
    ;  not the tick-boundary quantisation CLAUDE.md warns about. One reading in
    ;  four is a quarter of that.
    ;
    ;  Nothing is lost. The READOUT is a percentage: at five game frames a
    ;  second, a figure that moves five times a second and one that moves once
    ;  are the same figure to a human eye. The WAVE does not read this at all
    ;  -- wave_send takes its own reading at the moment it sizes the wave, so
    ;  the number it scales against is never stale by even one frame.
    ;
    ;  Every fourth frame rather than "when something changed", deliberately:
    ;  the things that move the fleet's hull are combat, a ship dying, a ship
    ;  being BUILT and a mission being set up, and a trigger that had to list
    ;  all four would be wrong the first time a fifth was added. A counter
    ;  cannot be wrong about anything.
    ld hl,wave_tick
    dec (hl)
    jr nz,@wave_no_reading
    ld (hl),WAVE_READ_EVERY
    call wave_health
@wave_no_reading:

    ld hl,wave_say
    ld a,(hl)
    or a
    jr z,@wave_said
    dec (hl)
@wave_said:

    ;  The colony is gone; nothing else matters and nothing else should happen.
    ld a,(mis_failed)
    or a
    ret nz

    ld hl,(mis_timer)
    ld de,(wave_next)
    or a
    sbc hl,de
    ret c                               ; not due
    jp wave_send


; ----------------------------------------------------------------------------
;  wave_health -- one walk of the table, and everything else reads the result
;  Out: (wave_hull) = hull flying under the player's flag
;       (wave_full) = what that would be with nothing damaged
;       (wave_pct)  = the one against the other, 0..100
;  Uses: everything
;
;  THE POINTER WALKS THE FLAGS BYTE, not the record, and that is the whole
;  reason this is affordable. Stepping the record base means an `ld de,offset`
;  and an `add hl,de` for every field on every slot, and the first version of
;  this reloaded the base out of memory four times a slot as well: 174
;  T-states on an EMPTY slot, and there are usually thirty of those. Starting
;  at entities+ENT_FLAGS and stepping by ENT_SIZE makes the common case
;  `ld a,(hl)` and a compare -- 57 T -- and ENT_HULL and ENT_CLASS are the two
;  bytes immediately BEFORE the flags, so a live slot reaches them with two
;  DECs and no arithmetic at all.
;
;  That the three fields are adjacent in section 7's record is luck rather than
;  design, so src/main.asm asserts it: move ENT_CLASS and this walks off into
;  ENT_SPEED without a word.
;
;  class_hull is in bank 4. That is legal here and only here because the window
;  is at its resting state for the whole of demo_update's simulation -- see the
;  one rule in game/shipclass.asm.
; ----------------------------------------------------------------------------
wave_health:
    ld hl,0
    ld (wave_hull),hl
    ld (wave_full),hl

    ;  ENT_PLAYER_MAX and not ENT_MAX: this sums ACTIVE-and-not-ENEMY, and by
    ;  the partition in game/entity.asm one of ours cannot be in the hostile
    ;  region at all. The compare rejected those slots and the walk still paid
    ;  for reading them.
    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_PLAYER_MAX
@wave_hp_one:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    call z,wave_hp_add                  ; ours, and flying
    add hl,de
    djnz @wave_hp_one
    jp wave_percent


; ----------------------------------------------------------------------------
;  wave_hp_add -- fold one live friendly ship into the two totals
;  In : HL -> its ENT_FLAGS byte
;  Out: HL, DE and B all as they were -- the loop above is holding all three
;  Uses: AF, C
; ----------------------------------------------------------------------------
wave_hp_add:
    push hl
    dec hl
    ld c,(hl)                           ; ENT_HULL is the byte before the flags
    dec hl
    ld l,(hl)                           ; ...and ENT_CLASS the one before that
    ld h,0
    push de
    ld de,class_hull
    add hl,de
    ld a,(hl)                           ; what this class has undamaged

    ;  HL += A without a spare register pair: B is the loop counter and DE is
    ;  the stride, so the usual `ld b,0 : add hl,bc` is not available.
    ;  add/ld/adc/sub/ld is the branchless form of it and is four bytes shorter.
    ld hl,(wave_full)
    add a,l
    ld l,a
    adc a,h
    sub l
    ld h,a
    ld (wave_full),hl

    ld a,c
    ld hl,(wave_hull)
    add a,l
    ld l,a
    adc a,h
    sub l
    ld h,a
    ld (wave_hull),hl

    pop de
    pop hl
    ret


; ----------------------------------------------------------------------------
;  wave_percent -- (wave_pct) = 100 * (wave_hull) / (wave_full)
;  Uses: everything
;
;  The only division in the game, and it is eight steps of a restoring divide
;  followed by one quarter-square multiply.
;
;  There is no general divide here and there should not be: txt_draw_num
;  divides by ten with repeated subtraction and txt_draw_num4 subtracts powers
;  of ten, because in both cases the divisor is a constant. This one is not --
;  the denominator is whatever fleet the player has -- so it is done properly
;  and it is done once a frame.
;
;  The shape: shift the numerator up eight times, subtracting the denominator
;  where it fits, which gives C = floor(256 * hull / full). Then the scale to
;  hundredths is (C * 100) >> 8, taken out of mul_u8's high byte for free. Both
;  operands fit sixteen bits and stay there -- HL is left below DE at the top of
;  every step, and DE is at most ENT_MAX * 255 = 12240, so the doubling cannot
;  run out of register.
; ----------------------------------------------------------------------------
wave_percent:
    ld hl,(wave_hull)
    ld de,(wave_full)
    call wave_pct_of
    ld (wave_pct),a
    ret


; ----------------------------------------------------------------------------
;  wave_pct_of -- A = 100 * HL / DE, clamped to 0..100
;  In : HL = the part, DE = the whole
;  Out: A
;  Uses: everything
;
;  Split out of wave_percent when game/squadinfo.asm wanted the same sum over
;  one squadron rather than over the whole fleet. It takes its operands in
;  registers and RETURNS the answer, deliberately: wave_hull and wave_full are
;  the FLEET's, wave_pct is what the HUD's third row draws, and a page that
;  borrowed the three to work out a squadron's figure would leave the fleet's
;  percentage reading the squadron's until the next wave_update -- which, on a
;  page that stops the world, is for as long as the page is up.
; ----------------------------------------------------------------------------
wave_pct_of:
    ld a,d
    or e
    jr z,@wave_pct_nothing              ; nothing to be a fraction of

    or a
    sbc hl,de
    jr c,@wave_pct_divide
    ld a,100                            ; nothing damaged
    ret

@wave_pct_nothing:
    xor a
    ret

@wave_pct_divide:
    add hl,de                           ; HL = hull again, and HL < DE
    call wave_frac_bits
    ld h,a
    ld l,100
    call mul_u8
    ld a,h                              ; (C * 100) >> 8
    ret


; ----------------------------------------------------------------------------
;  wave_frac_of -- A = 256ths of DE that HL is, saturating at 255
;  In : HL over DE
;  Out: A = floor(256 * HL / DE), or 255 if HL >= DE, or 0 if DE = 0
;  Uses: everything
;
;  The middle of wave_pct_of, given a name because the repair price wants the
;  fraction itself rather than a percentage of it -- `eco_repair_cost` is
;  2 x the class price x how damaged the ship is, and 256ths multiply into a
;  byte-wide answer where hundredths would need a second divide.
;
;  Same split, same reason, as wave_pct_of being lifted out of wave_percent:
;  the caller that wants the number is not the caller that owns the globals.
;
;  IT SATURATES AT 255 AND wave_pct_of DOES NOT USE THAT PATH. 256 does not fit
;  a byte, so "all of it" has to be 255 -- and (255 * 100) >> 8 is 99, not 100,
;  which would put the HUD's fleet readout at 99% with nothing damaged. That is
;  why wave_pct_of keeps its own `HL >= DE` case above rather than being three
;  lines on top of this one.
; ----------------------------------------------------------------------------
wave_frac_of:
    ld a,d
    or e
    ret z                               ; nothing to be a fraction of; A = 0
    or a
    sbc hl,de
    jr c,@wave_frac_go
    ld a,255                            ; all of it, or more than all of it
    ret
@wave_frac_go:
    add hl,de                           ; HL = the numerator again, and HL < DE
;  ...and fall through.

;  The eight restoring-divide steps themselves. HL < DE on entry, which is what
;  keeps the doubling below inside sixteen bits.
wave_frac_bits:
    ld c,0                              ; the quotient, eight fractional bits
    ld b,8
@wave_frac_bit:
    sla c
    add hl,hl
    or a
    sbc hl,de
    jr c,@wave_frac_zero
    inc c
    jr @wave_frac_step
@wave_frac_zero:
    add hl,de                           ; it did not fit; put it back
@wave_frac_step:
    djnz @wave_frac_bit
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  wave_send -- a wave lands, and the next one is scheduled
;  Uses: everything
; ----------------------------------------------------------------------------
wave_send:
    ;  When the next one comes. WAVE_GAP_MIN + 1.125 * a random byte: twenty
    ;  seconds to a little over a minute, drawn afresh every time, so the
    ;  player cannot learn the rhythm and hold station until just before the
    ;  next one.
    ;
    ;  At this spacing a wave can land while the last one is still flying, and
    ;  that is the substance of the change rather than a side effect: the old
    ;  gap was longer than any fight, so three waves were three separate
    ;  fights. tools/waverate.py's default protocol forces each wave and waits
    ;  for the fleet to come home, so it measures the old shape whatever this
    ;  number says -- its --overlap mode is the one that sees this.
    call sys_rand
    ld l,a
    ld h,0
    ld d,h
    ld e,l                              ; DE = r
    srl e
    srl e
    srl e                               ; DE = r >> 3, D being zero
    add hl,de                           ; 1.125r
    ld de,WAVE_GAP_MIN
    add hl,de
    ld de,(mis_timer)
    add hl,de
    ld (wave_next),hl

    ;  How many. The fleet's hull over 256 is how many ships' worth of fleet is
    ;  left; the wave is between a sixteenth and a quarter of it, plus one so
    ;  that even a fleet down to nothing is still being pressed.
    ;
    ;  A sixteenth to a QUARTER, and the first thing tried was an eighth to a
    ;  half. tools/waverate.py put that at 71% over seven mission-trials, which
    ;  is the floor and no margin, and the losses were all the same shape: a
    ;  wave arrives on top of the Mothership, every ship in it picks the nearest
    ;  target -- which is the Mothership, because that is what the fleet is
    ;  stationed on -- and seven interceptors take 255 hull off at ten a hit
    ;  faster than fifteen of ours can kill seven of theirs. The mechanism is
    ;  the same concentration argument CLAUDE.md makes for the player's fleet,
    ;  running the other way.
    ld hl,(wave_hull)
    ld c,h                              ; ships' worth, 0..47
    call sys_rand
    and 3
    inc a                               ; 1..4 sixteenths
    ld h,a
    ld l,c
    call mul_u8
    ;  ROUNDED, not truncated, and for the reason phase4_cache's view index is:
    ;  a plain >>4 gives a small fleet the same answer whatever it rolls. Half
    ;  a fleet is three ships' worth, three times four is twelve, and twelve
    ;  shifted down four is zero for every multiplier there is -- so the late
    ;  campaign, which is the whole reason the wave is scaled at all, would get
    ;  a wave of exactly one ship every time and the randomness would quietly
    ;  stop existing at the end where it matters most.
    ld de,8
    add hl,de
    ld a,l                              ; at most 47 * 4 + 8, so H is zero
    rrca
    rrca
    rrca
    rrca
    and #0F                             ; >> 4
    inc a
    cp WAVE_MAX + 1
    jr c,@wave_have_n
    ld a,WAVE_MAX
@wave_have_n:
    ld (wave_size),a
    ld (wave_left),a

    ;  How strong. One hull for the whole wave rather than one per ship: it is
    ;  a formation that was sent, and a wave the player can read as "that one
    ;  was soft" is a wave they can make a decision about.
    call sys_rand
    and WAVE_HULL_SPAN
    add a,WAVE_HULL_MIN
    ld (wave_ship_hull),a

    ;  ...and from where. ONE bearing for the whole wave, so it arrives as an
    ;  attack from a direction rather than as ships appearing all round the
    ;  fleet at once. Each ship is jittered inside WAVE_ARC of it.
    call sys_rand
    ld (wave_bearing),a

@wave_ship:
    ;  THEIRS, and this is the whole point of the partition. It used to be the
    ;  first free slot from zero, so a player who had built a fleet up to the
    ;  table's edge stopped receiving waves altogether -- the pressure that
    ;  makes `J` a decision switched itself off, silently, for the player who
    ;  had done best. The hostile region cannot be taken by the fleet now, so
    ;  the only thing that can turn a wave away is other hostiles.
    call ent_find_free_theirs
    jr nc,@wave_full_table              ; no slots: the fleet got lucky
    call ent_addr
    ld (wave_ent),hl

    call wave_place

    ;  A Vekhar interceptor like any other, and then the two things that make
    ;  it a wave ship: the flag mis_count_enemies looks past, and its own hull.
    ld hl,(wave_ent)
    call mis_make_enemy
    ld hl,(wave_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    or ENT_F_WAVE
    ld (hl),a
    ld hl,(wave_ent)
    ld de,ENT_HULL
    add hl,de
    ld a,(wave_ship_hull)
    ld (hl),a

    ld hl,wave_left
    dec (hl)
    jr nz,@wave_ship

@wave_full_table:
    ld hl,wave_count
    inc (hl)
    ld a,WAVE_SAY_FRAMES
    ld (wave_say),a
    ret


; ----------------------------------------------------------------------------
;  wave_place -- put the ship at (wave_ent) on the shell around the Mothership
;  Uses: everything
;
;  Around the MOTHERSHIP rather than around the selected squadron, because the
;  Mothership is what the player must not lose and a wave that always arrived
;  where the camera happened to be looking would be a different mechanic.
; ----------------------------------------------------------------------------
wave_place:
    ld a,(moth_slot)
    call ent_addr
    ld (wave_moth),hl

    call sys_rand
    and WAVE_ARC
    ld hl,wave_bearing
    add a,(hl)
    ld (wave_angle),a

    ld c,WAVE_RADIUS
    call wave_offset
    ld c,ENT_X
    call wave_store

    ld a,(wave_angle)
    add a,64                            ; a quarter turn on: the cosine
    ld c,WAVE_RADIUS
    call wave_offset
    ld c,ENT_Z
    call wave_store

    ;  Facing the fleet. Nothing requires it -- the mission table's own
    ;  hostiles inherit whatever yaw the slot last held -- but a wave that
    ;  arrives already pointing the wrong way reads as debris, not as an
    ;  attack, and phase4_cache draws the view straight off this byte.
    ld a,(wave_angle)
    add a,128
    ld hl,(wave_ent)
    ld de,ENT_YAW
    add hl,de
    ld (hl),a

    ;  Height: a shallow band. The content of this game is essentially planar
    ;  -- section 4.1's reference plane, the formations, the resource fields --
    ;  so a wave that came in from directly above would never be seen at all.
    call sys_rand
    ld b,a
    ld c,WAVE_RISE
    call mul_s8u8
    ld c,ENT_Y
    ; ...and fall through


; ----------------------------------------------------------------------------
;  wave_store -- one axis of the arrival position
;  In : HL = the offset from the Mothership, C = the field offset (ENT_X/Y/Z)
;  Uses: everything
; ----------------------------------------------------------------------------
wave_store:
    ld b,0
    push hl
    ld hl,(wave_moth)
    add hl,bc
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = where the Mothership is
    pop hl
    add hl,de
    push hl
    ld hl,(wave_ent)
    add hl,bc
    pop de
    ld (hl),e
    inc hl
    ld (hl),d
    ret


; ----------------------------------------------------------------------------
;  wave_offset -- HL = sin(A) * C, in world units
;  In : A = angle, C = scale
;  Uses: everything
;
;  BC is pushed because cam_sin clobbers C, which is exactly the sort of thing
;  the register contracts in this project exist to say out loud.
; ----------------------------------------------------------------------------
wave_offset:
    push bc
    call cam_sin
    pop bc
    ld b,a
    jp mul_s8u8


; ============================================================================
;  The readout
; ============================================================================
;  A third HUD row, at the TOP of the strip. Section 5.5 budgets thirty-two
;  pixels for the HUD and only twenty were ever used -- the two rows of
;  squadron counts sit at 178 and 188, and 168..177 has been black since the
;  strip was drawn. Neither existing row had four characters to spare: row A
;  runs squadrons to byte 51, RU to 67 and ?HELP to 79, and row B runs
;  squadrons to 41, the yard to 51 and M n JUMP to 71. So the number went where
;  there was room for it rather than where something else had to be cut, and it
;  landed in the most prominent line of the strip, which is where the most
;  important number in the game belongs.
;
;  IT HAS ITS OWN DIRTY FLAG, and that is the point rather than tidiness. The
;  percentage moves every time a shot lands. Flagging phase4_hud_dirty would
;  repaint the whole strip -- about ninety thousand T-states, twice, once per
;  buffer -- several times a second in a battle, and undo the entire bargain
;  that makes the HUD affordable. This is nine characters.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  wave_draw -- one frame of the hull readout
;  Uses: everything
; ----------------------------------------------------------------------------
wave_draw:
    ;  The tutorial owns this row outright while it is running, and wave_dirty
    ;  goes with it -- one dirty flag for row C whoever is drawing there, which
    ;  is what makes the coupling with phase4_hud and mis_wipe free. The row is
    ;  eighty BYTES, which is forty characters, and HULL nnn% and INCOMING
    ;  already take the first twenty of them; there is no sharing it with a line
    ;  of instruction. See game/tutorialrun.asm.
    ld a,(tut_active)
    or a
    jp nz,tut_draw

    call wave_changed
    ld hl,wave_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ;  Blank the row first. This is the only thing that ever writes here -- the
    ;  tactical view is clipped out at spr_clip_bottom and the other two HUD
    ;  rows are below it -- so this is the whole erase, with no dirty rectangle
    ;  to record and nothing to co-ordinate with.
    ld b,0
    ld c,HUD_ROW_C_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,TXT_CHAR_H
    xor a
    call scr_fill_rect

    ld hl,wave_hp_label
    ld b,HUD_HP_X
    ld c,HUD_ROW_C_Y
    call phase4_hud_label               ; chrome is ink 2, and puts the pen back

    ;  The figure, and its ink. Section 2 keeps ink 3 for the thing that wants
    ;  attention, and a fleet down to a third of its hull is the clearest case
    ;  of that in the game: it is the moment the answer to "one more wave or
    ;  jump now" changes.
    ld a,(wave_pct)
    cp HUD_HP_ALARM
    ld a,PEN_WHITE
    jr nc,@wave_hp_pen
    ld a,PEN_RED
@wave_hp_pen:
    call txt_set_pen

    ld a,(wave_pct)
    ld b,HUD_HP_X + 5 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    ld d,3
    call txt_draw_num
    ld hl,wave_hp_sign
    ld b,HUD_HP_X + 8 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE                      ; nothing inherits an ink
    call txt_set_pen

    ;  ...and, for a few seconds after one lands, why the shooting started. A
    ;  wave arrives six thousand units out and the player may be looking the
    ;  other way; without this the first they know of it is a hull figure
    ;  falling for no reason they can see.
    ld a,(wave_say)
    or a
    ret z
    ld a,PEN_RED
    call txt_set_pen
    ld hl,wave_say_text
    ld b,HUD_SAY_X
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  wave_changed -- has anything in the row moved?
;  Uses: everything
;
;  Two shadows and the same shape as phase4_hud_changed, for the same reason:
;  hull falls with nobody pressing anything. The INCOMING countdown is compared
;  as a yes/no rather than as a number, because it ticks every frame and only
;  its two transitions are worth a repaint.
; ----------------------------------------------------------------------------
wave_changed:
    ld a,(wave_pct)
    ld hl,wave_pct_shadow
    cp (hl)
    jr nz,@wave_hp_diff

    ld a,(wave_say)
    or a
    jr z,@wave_hp_quiet
    ld a,1
@wave_hp_quiet:
    ld hl,wave_say_shadow
    cp (hl)
    ret z

@wave_hp_diff:
    ld a,(wave_pct)
    ld (wave_pct_shadow),a
    ld a,(wave_say)
    or a
    jr z,@wave_hp_quiet2
    ld a,1
@wave_hp_quiet2:
    ld (wave_say_shadow),a
    ld a,2                              ; once into each screen buffer
    ld (wave_dirty),a
    ret


; ============================================================================
;  State
; ============================================================================
;  All of it in the low 16K with the rest of the frame loop's simulation, and
;  deliberately so: game/combat.asm and game/economy.asm stayed down here for
;  the reason CLAUDE.md gives -- having the per-frame simulation in one place is
;  worth more than the bytes, and the low 16K has them now while bank 4 has 299.
; ----------------------------------------------------------------------------
wave_next:          defw WAVE_FIRST_FRAMES
wave_count:         defb 0              ; waves sent this mission
wave_size:          defb 0              ; ships in the last one
wave_say:           defb 0              ; frames of INCOMING left
wave_left:          defb 0
wave_ship_hull:     defb 0
wave_bearing:       defb 0
wave_angle:         defb 0
wave_ent:           defw 0
wave_moth:          defw 0
wave_tick:          defb 1              ; frames until the next hull reading

;  The fleet, as the rest of the file measures it.
wave_hull:          defw 0
wave_full:          defw 0
wave_pct:           defb 100

wave_dirty:         defb 0
;  #FF so the first frame is always a change and demo_init has nothing to do.
wave_pct_shadow:    defb #FF
wave_say_shadow:    defb #FF

wave_hp_label:      defb "HULL",0
wave_hp_sign:       defb "%",0
wave_say_text:      defb "INCOMING",0
wave_say_text_end:
