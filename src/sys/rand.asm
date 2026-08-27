; ============================================================================
;  sys/rand.asm -- pseudo-random numbers, and the habit they must not have
; ============================================================================
;  A 16-bit xorshift: eight instructions, and no state but the word itself.
;  The title screen's starfield already used one, and the attack waves need
;  exactly the same generator with exactly the opposite habit -- so the STEP
;  lives here and is shared, and the STATE does not and must not be.
;
;  WHY THE STATE IS NOT SHARED
;  ---------------------------
;  title_draw_stars reseeds to a constant at the top of EVERY frame. That is
;  deliberate and it is the whole reason the starfield can be generated rather
;  than stored: the same forty stars land in the same forty places every frame,
;  so the field is as still as a table would have been. A wave generator that
;  restarted like that would send the same wave, at the same spacing, in every
;  mission of every campaign -- which is not randomness, it is a fixed script
;  with extra arithmetic. So sys_rand_step takes the word in HL and hands it
;  back, and each caller keeps its own.
;
;  WHERE THE SEED COMES FROM
;  -------------------------
;  sys_rng starts at a fixed constant, so a machine nobody touches is
;  reproducible. The FIRST key the player presses stirs sys_tick_50hz into it.
;  That counter free-runs at 50 Hz and wraps every 5.12 seconds, so the moment
;  of a human pressing a key is worth most of eight bits and costs one load to
;  read. key_consume is where the stir happens because it is the one place in
;  the game that already knows a key went down; sys_rand_seeded makes it happen
;  once and never again.
;
;  HOW A TEST PINS IT
;  ------------------
;  That "once and never again" is what makes the suite deterministic rather
;  than merely repeatable. Every harness.boot_quick presses SPACE past the
;  title and ENTER past the briefing, so by the time a test is handed the
;  machine the stir has already been spent -- and a test that then writes
;  SYS_RNG owns the sequence for the rest of the run. harness.pin_rng is that
;  write, and tests/test_waves.py is what it is for.
; ----------------------------------------------------------------------------

;  Never zero, and nothing may ever make it zero: the recurrence below has zero
;  as a fixed point, and a dead generator is a campaign that sends one wave
;  size forever while every test still passes.
SYS_RAND_SEED       equ #7C4D


; ----------------------------------------------------------------------------
;  sys_rand -- A = the next byte of the game's sequence
;  Uses: AF, HL
; ----------------------------------------------------------------------------
sys_rand:
    ld hl,(sys_rng)
    call sys_rand_step
    ld (sys_rng),hl
    ret


; ----------------------------------------------------------------------------
;  sys_rand_step -- advance a xorshift word
;  In : HL = the state, which must not be zero
;  Out: HL = the next state, A = its high byte
;  Uses: AF, HL
; ----------------------------------------------------------------------------
sys_rand_step:
    ld a,h
    rra
    ld a,l
    rra
    xor h
    ld h,a
    ld a,l
    rra
    ld a,h
    rra
    xor l
    ld l,a
    xor h
    ld h,a
    ret


; ----------------------------------------------------------------------------
;  sys_rand_stir -- fold the clock into the seed, once, at the first keypress
;  Uses: AF, HL
;
;  Called from key_consume with the frame's edges already in hand. Does nothing
;  after the first time, which is the property the tests are built on.
; ----------------------------------------------------------------------------
sys_rand_stir:
    ld hl,sys_rand_seeded
    ld a,(hl)
    or a
    ret nz
    ld (hl),1

    ld hl,(sys_rng)
    ld a,(sys_tick_50hz)
    xor l
    ld l,a
    or h
    jr nz,@sys_rand_live
    ld hl,SYS_RAND_SEED                 ; the recurrence dies at zero
@sys_rand_live:
    ld (sys_rng),hl
    ;  One step, so the byte that just went into L is spread across both
    ;  halves before anybody asks for a number.
    jp sys_rand


; ============================================================================
;  State
; ============================================================================
sys_rng:            defw SYS_RAND_SEED
sys_rand_seeded:    defb 0
