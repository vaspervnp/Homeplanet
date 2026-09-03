; ============================================================================
;  game/minigame.asm -- the vortex chase, and what it costs to lose it
; ============================================================================
;  "Προσθέστε το μίνι παιχνίδι ανάμεσα στα άλματα, με την εξής προϋπόθεση: αν
;  δεν καταφέρουμε να εξουδετερώσουμε τον εχθρό κατά τη διάρκεια του μίνι
;  παιχνιδιού, τότε επιβάλλεται ποινή απώλειας του 10% έως 50% του στόλου μας
;  λόγω αιφνιδιαστικής επίθεσης."
;
;  A Vekhar interceptor follows the fleet into the jump. You chase it down a
;  receding shaft with the cursor keys; catch it and it is gone, let the tunnel
;  run out and it reaches their fleet first and tells them where you are
;  coming out. The ambush costs between a tenth and a half of the fleet.
;
;  minigame.md is the design this is built from and three of its decisions have
;  moved. What follows is only what CHANGED and why; the rest of the reasoning
;  is in that file.
;
;  ON THE JUMP, AND NOT ONCE PER CAMPAIGN
;  --------------------------------------
;  The design put the chase on a fleeing enemy at one named mission and
;  explicitly rejected the jump, on the grounds that twenty jumps is twenty
;  minigames and a minigame you must play twenty times stops being one by the
;  third. The owner has asked for the jump, and that objection is real, so it
;  is answered with MG_EVERY rather than ignored: the chase happens on the jump
;  out of every MG_EVERY'th mission and nowhere else. At 4 that is four chases
;  in a campaign of twenty -- often enough that the second one is played with
;  what the first one taught, rare enough that it is still an event. It is ONE
;  constant and nothing else in this file knows the number.
;
;  WHERE ON THE JUMP PATH, WHICH DECIDES WHETHER THE PENALTY IS REAL
;  ----------------------------------------------------------------
;  Between jfx_vanish and fleet_save, and the second half of that is the whole
;  point. fleet_save is what carries the fleet into the next mission and
;  fleet_disc_save is what puts it on the disc a few instructions later -- so a
;  penalty applied HERE is a penalty that survives the power going off, and one
;  applied after mis_setup would be undone by the next boot. Section 1's
;  premise is that what is lost is lost.
;
;  After jfx_vanish because the vanish is the fleet entering the jump, and
;  because it leaves the playfield black in both buffers, which is exactly the
;  canvas this wants. This file gives it back the same way on its way out.
;
;  mis_jump_now stays ATOMIC either way -- it runs its own loop to completion,
;  as jfx_vanish does -- which a dozen tests and both measuring tools depend
;  on: `J` still means "mis_index has moved by the time you can look".
;
;  WHAT CHOOSES THE 10% TO 50%, AND WHY IT IS NOT A ROLL
;  ----------------------------------------------------
;  This project's rule is that a coin toss is not something a player can act
;  on -- it is why wrecks are deterministic and why cbt_prey_bias is a bias
;  rather than a die. So the percentage is HOW CLOSE THE CHASE GOT:
;
;      frac = MG_FRAC_MIN + whatever was left of mini_dist
;
;  and the two constants are chosen so that is an ADD and nothing else.
;  MG_DIST0 is 102 and MG_FRAC_MAX - MG_FRAC_MIN is 102, so a chase that ended
;  with the distance untouched pays 128/256 -- exactly a half -- and one that
;  ended a hair short pays 26/256, which is 10.2%. No divide, no table, and the
;  number the player is being charged is the number they watched on the screen.
;
;  WHICH SHIPS: THE WOUNDED, AND THAT IS THE ONLY RULE THAT GIVES THE PLAYER
;  SOMETHING TO DO ABOUT IT
;  ------------------------------------------------------------------------
;  A surprise attack finishes what the last battle started. It is deterministic
;  like everything else here, it is legible -- the `I` page already prints hull
;  per class -- and unlike "the first k slots" or "a random k" it COMPOSES with
;  the two keys that already exist: `E` mends and `Y` breaks up, and both are
;  now worth pressing before a jump that has a chase in it. A positional rule
;  would be arbitrary and a random one would be unactionable; either way the
;  player would have nothing to do but suffer it.
;
;  The honest cost of the rule is that killing off the worst-damaged ships
;  RAISES the fleet's hull percentage, exactly as game/waves.asm says of any
;  loss measured against the current roster. The squadron counts fall, which is
;  the reading that matters here.
;
;  THE MOTHERSHIP IS EXCLUDED BY CLASS, NOT BY moth_slot
;  ----------------------------------------------------
;  Section 8 makes losing it the end of the campaign, and ending a campaign
;  through a minigame the player may not have understood is the harshest
;  failure available. moth_slot is an index and fleet_restore moves what it
;  points at -- "never trust a slot index" -- so the test is ENT_CLASS, which
;  is the same test slv_deliver and squad_recycle make for the same reason.
;
;  WHAT IT DRAWS, AND WHY IT IS RECTANGLES
;  ---------------------------------------
;  minigame.md wanted the rings to come out of planet_span_right/left, and they
;  cannot: those walk ONE ellipse whose half-widths are title_planet_hw shifted
;  up twice, and a ring at an arbitrary radius would need that table scaled per
;  row -- a multiply a row, in a file that has about four hundred bytes.
;
;  What this machine actually has is two primitives: a whole-byte horizontal
;  fill (scr_fill_rect) and a one-pixel vertical line (gfx_vline). Four of them
;  are a rectangle, exactly, with no table and no multiply -- and a rectangle
;  is UNBROKEN, which is the answer to the risk minigame.md wrote down: five
;  concentric outlines all growing together at the same rate read as motion,
;  where five rings of scattered dots would have read as the noise it predicted.
;
;  IN BANK 4, by the rule in game/shipclass.asm: it runs with the world
;  stopped, from inside mis_jump_now, and nothing here can run between
;  class_tier_addr and class_blit_done. THE BLIT IS THE ONE THING IT CANNOT DO
;  ITSELF -- class_tier_addr pages bank 4 out and this code IS bank 4 -- so the
;  geometry is worked out here, out of class_geom and class_sprite, which are
;  both in the low 16K, and the paging is left to spr_blit_banked. Exactly the
;  road title_draw_ships had to take when the libraries repacked 3+3+2.
;
;  Its seven bytes of state are in the LOW 16K, above code_end where they cost
;  address space and no DISC.BIN, so tests can read them with read_ram while
;  the chase is running -- which they have to, because the blit pages a sprite
;  bank in several times a step and read_bank4 would have to run a frame to get
;  past it. See src/main.asm.
; ----------------------------------------------------------------------------

;  HOW OFTEN. See the head of this file: this is the whole of the answer to
;  minigame.md's objection to putting it on the jump, and it is one number.
;  The chase runs on the jump out of missions MG_EVERY, 2*MG_EVERY, ... so at 4
;  that is missions 4, 8, 12 and 16 -- mission 20 lands rather than jumping.
MG_EVERY            equ 4

;  How long the tunnel is, in steps, and how long a step is in 50 Hz TICKS.
;
;  TICKS AND NOT FRAMES. This file records four separate occasions on which a
;  constant in game frames turned out to be a constant in seconds only against
;  a frame rate somebody once looked at, so mini_wait holds each step to a
;  whole number of vertical blanks whatever the drawing cost -- and the tunnel
;  is therefore MG_STEPS * MG_STEP_TICKS / 50 seconds, 14.4, by arithmetic
;  rather than by measurement.
MG_STEPS            equ 80
MG_STEP_TICKS       equ 7

;  The closing distance: where it starts, how fast it falls while the enemy is
;  lined up, and how fast it opens again while it is not.
;
;  MG_DIST0 IS 102 BECAUSE THE PENALTY IS AN ADD. See the head of this file.
;  What it costs in play: to reach zero from 102 in MG_STEPS steps the player
;  has to be lined up for f of them, where 120*(2f - (1-f)) = 102, so f = 0.62.
;  Two thirds of a fifteen-second chase, and the rest of it is recoverable
;  because the distance is capped rather than lost.
MG_DIST0            equ 102
MG_CLOSE            equ 3
MG_OPEN             equ 1

;  ...and 10% to 50% of the fleet, as 256ths, so the count is one mul_u8 and a
;  shift -- the same arithmetic wave_frac_of does for a repair's price.
MG_FRAC_MIN         equ 26              ; 26/256 = 10.2%
MG_FRAC_MAX         equ 128             ; 128/256 = 50.0% exactly

;  How near the middle of the tunnel the enemy has to be for the distance to
;  fall. It is drawn at half a unit a pixel, so twenty units is ten pixels
;  either side of the vanishing point -- a little over one tier A sprite.
MG_LOCK             equ 22

;  The lateral axis. It is 0..255 with 128 the middle of the tunnel, and both
;  ships live on it; nothing else about this game is two-dimensional.
MG_X_MID            equ 128
MG_X_MIN            equ 40
MG_X_MAX            equ 216

;  How far the cursor keys move you in one step. IT HAS TO BEAT THE ENEMY'S
;  fastest drift or the chase is unwinnable rather than hard: the drift below
;  peaks at 40*3*2*pi/256 + 16*3*3*2*pi/256 = 6.5 units a step.
MG_STEER            equ 8

;  The enemy's drift: two sines, because ONE is a metronome. A single sine is
;  learned in one pass and held for the rest of the chase; a fundamental and
;  its third harmonic, a quarter its size and out of phase, still reads as a
;  weave a player can follow and cannot simply park on. cam_sin is folded from
;  one quadrant and runs four times a frame in the game, so twice a step here
;  is nothing.
MG_SPIN             equ 3               ; how far the angle turns in one step
MG_AMP1             equ 40
MG_AMP2             equ 16
MG_PHASE2           equ 40

;  THE SHAFT. Five rectangles walking outward through a ladder of half-widths,
;  three apart, so each of them takes the whole ladder -- fifteen steps, about
;  two seconds -- to come from the far end to the near one.
MG_RINGS            equ 5
MG_LADDER           equ 15
MG_SPACING          equ 3

;  Ink 2, which is what section 2 means by scenery: the stars, the reference
;  grid and the world are all in it and the vortex is the same kind of thing.
;  Ink 1 is the fleet and the text and a white shaft would read as something of
;  ours; ink 3 is the alarm ink and is spent below on the one line that is one.
MG_INK              equ SOLID_INK_2
MG_PEN              equ 2

;  The middle of the visible band -- the same line the projection centres on,
;  so the vanishing point is where the game already puts the middle of the
;  world. Not the middle of the screen; see PROJ_CENTRE_Y.
MG_CX               equ 160
MG_CY               equ PROJ_CENTRE_Y

;  Your own ship, low and centre and fixed. The tunnel swings and the enemy
;  moves; you do not, which is what makes "put it in the middle" the whole of
;  the instruction.
MG_SHIP_Y           equ 130

;  Which yaw view both ships are drawn in. They are both running the same way
;  and are both seen from behind.
MG_VIEW             equ 0

;  Where the enemy sits between tiers, on the way in. Two compares, exactly as
;  phase4_tier_for does it, rather than 102 bytes of table.
MG_TIER_FAR         equ 68
MG_TIER_MID         equ 34

;  The words, and where they go. MG_TEXT_Y is above the widest ring (the shaft
;  reaches MG_CY +/- 46) and MG_LOST_Y is below it.
MG_TEXT_Y           equ 16
MG_LOST_Y           equ 152

;  The band the chase actually redraws every step: the shaft is MG_CY +/- 46
;  and the two ships hang a few lines below it, so everything that MOVES is
;  inside this and nothing outside it has to be cleared. It matters because the
;  clear IS the cost of a step -- 106 lines against the playfield's 158 is a
;  third off the only thing in this file that touches eight thousand bytes.
;  src/main.asm asserts both ends of it against the shaft and the sprites.
MG_BODY_Y           equ 30
MG_BODY_H           equ 118

;  Where each of the four lines starts, so that each is centred: a line of n
;  characters begins at (SCR_BYTES_PER_LINE - n * TXT_CHAR_W_BYTES) / 2. There
;  is no centring in txt_draw and one screen does not justify inventing it, so
;  these are worked out by hand and src/main.asm checks every one of them
;  against the length of its own string in bank 7.
MG_RUN_X            equ 6
MG_WON_X            equ 21
MG_LOST_X           equ 8
MG_TOLL_X           equ 27
MG_TOLL_NUM_X       equ MG_TOLL_X + 22

;  How long the result stays on the screen, in ticks. Two seconds: long enough
;  to read nine words, short enough that a jump does not become a cutscene.
MG_HOLD             equ 100

;  Which of the four strings in mini_words is being said.
;  The intro page: four lines and a prompt, (x, y) each, centred by hand --
;  x is (SCR_BYTES_PER_LINE - n * TXT_CHAR_W_BYTES) / 2 and src/main.asm checks
;  every one against its string. Sixteen lines apart, and the prompt further
;  down where the game's other pages put theirs.
MG_INTRO_1_X        equ 8
MG_INTRO_2_X        equ 5
MG_INTRO_3_X        equ 5
MG_INTRO_4_X        equ 6
MG_INTRO_GO_X       equ 27
MG_INTRO_Y          equ 48
MG_INTRO_STEP       equ 16
MG_INTRO_GO_Y       equ 128
MG_INTRO_LINES      equ 4

MG_MSG_RUN          equ 0
MG_MSG_WON          equ 1
MG_MSG_LOST         equ 2
MG_MSG_TOLL         equ 3


; ----------------------------------------------------------------------------
;  mini_maybe -- run the chase, if this is one of the jumps that has one
;  Uses: everything
;
;  mis_index is 0-based and has NOT been advanced yet, so A is the number of
;  the mission being left. The modulo is repeated subtraction because there is
;  no divide in this project and MG_EVERY is meant to be tunable to any number
;  rather than to a power of two.
; ----------------------------------------------------------------------------
mini_maybe:
    ld a,(mis_index)
    inc a
@mg_every:
    sub MG_EVERY
    jr z,mini_run
    jr nc,@mg_every
    ret


; ----------------------------------------------------------------------------
;  mini_run -- the chase, from a black screen to a black screen
;  Uses: everything
;
;  IT RUNS ITS OWN LOOP, with its own vertical blank and its own page flip,
;  exactly as jfx_vanish does and for the same two reasons: there is nothing
;  else left to run, and mis_jump_now has to stay atomic. It also means this
;  costs the frame loop NOTHING -- there is no branch in demo_update to reach
;  it, which matters because demo_update is in the low 16K and the low 16K has
;  thirty spare bytes.
; ----------------------------------------------------------------------------
mini_run:
    ld a,1
    ld (mini_active),a
    ld a,MG_X_MID
    ld (mini_x),a
    ld (mini_ex),a
    xor a
    ld (mini_theta),a
    ld (mini_phase),a
    ld (mini_lost),a
    ld (mini_msg),a                     ; MG_MSG_RUN
    ld (mini_frac),a
    ld a,MG_DIST0
    ld (mini_dist),a
    ld a,MG_STEPS
    ld (mini_left),a
    ld a,(sys_tick_50hz)
    ld (mini_t0),a

    ;  THE VIEWPORT IS THE BAND THE STEP REDRAWS, not the playfield. gfx_vline
    ;  and spr_blit both clip against these two, so pointing them here is what
    ;  lets the shaft be wider than the screen is tall without a line of its own
    ;  clipping code -- and it guarantees that nothing is ever drawn outside the
    ;  rectangle the next step blacks. Put back at the end, which is the same
    ;  contract title_draw_ships has.
    ld a,MG_BODY_Y
    ld (spr_clip_top),a
    ld a,MG_BODY_Y + MG_BODY_H
    ld (spr_clip_bottom),a

    ;  THE FIRST TIME, SAY WHAT THIS IS. "Πριν παίξει πρώτη φορά το minigame
    ;  να δείχνεις τα πλήκτρα που χρειάζονται και να ξεκινάει με enter." A
    ;  player who has just watched their fleet swept away and is dropped into
    ;  a tunnel with a red ship in it has no way of knowing that the arrow keys
    ;  are live, that closing is the point, or that losing costs ships -- and
    ;  the first chase is the one where they pay for not knowing. Once a
    ;  campaign: after that it is a mechanic they have met, and a page in front
    ;  of every jump would make four events into four interruptions.
    call mini_intro

    ;  Both buffers, all two hundred lines: the mission's own chrome is still
    ;  standing in the two strips and none of it is true any more.
    call mini_blank
    call mini_say
    call mini_show
    call mini_blank
    call mini_say
    call mini_show

@mg_step:
    call mini_enemy
    call mini_steer
    call mini_close
    jr c,@mg_caught
    call mini_draw
    call mini_wait

    ld hl,mini_phase
    inc (hl)
    ld a,(hl)
    cp MG_LADDER
    jr c,@mg_phase_ok
    ld (hl),0
@mg_phase_ok:
    ld hl,mini_theta
    ld a,(hl)
    add a,MG_SPIN
    ld (hl),a

    ld hl,mini_left
    dec (hl)
    jr nz,@mg_step

    ;  The tunnel ran out with it still ahead of us.
    call mini_penalty
    call snd_hit
    ld a,MG_MSG_LOST
    jr @mg_over

@mg_caught:
    call snd_explosion
    ld a,MG_MSG_WON

@mg_over:
    ld (mini_msg),a
    ;  ONCE INTO EACH BUFFER. The display page-flips and nothing is going to
    ;  redraw this: a result painted into one of them would be on the screen
    ;  every other frame, which is the bug the context bar shipped.
    call mini_draw
    call mini_say
    call mini_show
    call mini_draw
    call mini_say
    call mini_show
    ld a,MG_HOLD
    call mini_hold

    ;  ...and give the screen back the way jfx_vanish handed it over, black in
    ;  both buffers, so nothing of the chase is behind the briefing that
    ;  mis_jump_now is about to put up.
    ld a,2
    ld (mini_left),a
@mg_dark:
    call mini_blank
    call mini_show
    ld hl,mini_left
    dec (hl)
    jr nz,@mg_dark

    ld a,CTX_BAR_H                      ; ...and the viewport back to the game's
    ld (spr_clip_top),a
    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    xor a
    ld (mini_active),a
    ret


; ----------------------------------------------------------------------------
;  mini_show -- put the buffer just drawn on the screen
;  Uses: everything
; ----------------------------------------------------------------------------
mini_show:
    call scr_wait_vsync
    jp scr_flip


; ----------------------------------------------------------------------------
;  mini_hold -- A vertical blanks, doing nothing
;  Uses: everything
; ----------------------------------------------------------------------------
mini_hold:
    ld (mini_holdc),a
@mg_holding:
    call scr_wait_vsync
    ld hl,mini_holdc
    dec (hl)
    jr nz,@mg_holding
    ret


; ----------------------------------------------------------------------------
;  mini_wait -- show this step, then hold the rest of its MG_STEP_TICKS
;  Uses: everything
;
;  The period is measured against sys_tick_50hz rather than counted in blanks
;  after the drawing, so it is MG_STEP_TICKS whatever the drawing cost -- and
;  it self-corrects rather than drifting if a step ever overruns. That is the
;  difference between a tunnel that is 14.4 seconds and one that is "however
;  long five rectangles and two sprites happen to take today".
; ----------------------------------------------------------------------------
mini_wait:
    call scr_wait_vsync
    call scr_flip
@mg_pace:
    ld a,(sys_tick_50hz)
    ld hl,mini_t0
    sub (hl)                            ; the byte wrap is the right answer
    cp MG_STEP_TICKS
    jr nc,@mg_paced
    call scr_wait_vsync
    jr @mg_pace
@mg_paced:
    ld a,(sys_tick_50hz)
    ld (mini_t0),a
    ret


; ----------------------------------------------------------------------------
;  mini_steer -- the cursor keys move you along the lateral axis
;  Uses: AF, HL
;
;  key_down and NOT key_hit. Every command in the rest of the game is
;  edge-triggered, because holding `d` must divide a squadron once and not once
;  a frame -- steering is the one thing in this project that wants the opposite,
;  and key_state is kept live by the 50 Hz scan whether or not anything has
;  called key_consume. So this needs no key_consume at all, which is just as
;  well: demo_update owns that call and demo_update is not running.
; ----------------------------------------------------------------------------
mini_steer:
    ld a,KEY_CUR_LEFT
    call key_down
    jr nc,@mg_not_left
    ld a,(mini_x)
    sub MG_STEER                        ; cannot borrow: x is never below MIN
    cp MG_X_MIN
    jr nc,@mg_steered
    ld a,MG_X_MIN
    jr @mg_steered

@mg_not_left:
    ld a,KEY_CUR_RIGHT
    call key_down
    ret nc
    ld a,(mini_x)
    add a,MG_STEER
    cp MG_X_MAX + 1
    jr c,@mg_steered
    ld a,MG_X_MAX
@mg_steered:
    ld (mini_x),a
    ret


; ----------------------------------------------------------------------------
;  mini_enemy -- where it has drifted to this step
;  Uses: everything
;
;  128 + (sin(t) * A1 + sin(3t + p) * A2) >> 7, which is +/- 54 and therefore
;  always inside the range the player's own axis can reach. See MG_SPIN.
; ----------------------------------------------------------------------------
mini_enemy:
    ld a,(mini_theta)
    call cam_sin
    ld b,a
    ld c,MG_AMP1
    call cam_mul7                       ; A = (B * C) >> 7, both signed
    ld e,a

    ld a,(mini_theta)
    ld b,a
    add a,a
    add a,b                             ; three times the angle...
    add a,MG_PHASE2                     ; ...and out of step with it
    push de                             ; cam_sin loads DE with the table base
    call cam_sin
    ld b,a
    ld c,MG_AMP2
    call cam_mul7
    pop de

    add a,e
    add a,MG_X_MID
    ld (mini_ex),a
    ret


; ----------------------------------------------------------------------------
;  mini_close -- one step of the distance rule
;  Out: CF set = the enemy is caught
;  Uses: AF, HL
; ----------------------------------------------------------------------------
mini_close:
    ld a,(mini_ex)
    ld hl,mini_x
    sub (hl)
    jr nc,@mg_gap
    neg
@mg_gap:
    cp MG_LOCK
    jr nc,@mg_opening

    ld a,(mini_dist)
    sub MG_CLOSE
    jr c,@mg_zero
    jr z,@mg_zero
    ld (mini_dist),a
    or a                                ; CF clear: still ahead of us
    ret
@mg_zero:
    xor a
    ld (mini_dist),a
    scf
    ret

@mg_opening:
    ;  Capped rather than lost, so a bad opening is recoverable. It is what
    ;  keeps the chase a thing to be played rather than a thing to be failed in
    ;  the first three seconds.
    ld a,(mini_dist)
    add a,MG_OPEN
    cp MG_DIST0 + 1
    jr c,@mg_opened
    ld a,MG_DIST0
@mg_opened:
    ld (mini_dist),a
    or a
    ret


; ----------------------------------------------------------------------------
;  mini_penalty -- the ambush, once the tunnel has run out
;  Out: (mini_frac) what it cost as a 256th, (mini_lost) how many ships
;  Uses: everything
; ----------------------------------------------------------------------------
mini_penalty:
    ld a,(mini_dist)
    add a,MG_FRAC_MIN                   ; ...and that is the whole map
    ld (mini_frac),a

    call mini_count
    or a
    ret z                               ; nothing but the Mothership left

    ld h,a
    ld a,(mini_frac)
    ld l,a
    call mul_u8                         ; HL = ships * frac
    ld de,128
    add hl,de                           ; round to the nearest 256th
    ld a,h
    or a
    ret z                               ; a fleet too small to round to one
    ld (mini_want),a

@mg_kill:
    call mini_weakest
    jr nc,@mg_killed                    ; ...ran out of ships to take
    ld (hl),0                           ; every flag: the slot is free again
    ld hl,mini_lost
    inc (hl)
    ld hl,mini_want
    dec (hl)
    jr nz,@mg_kill

@mg_killed:
    ;  squad_count is DERIVED, so the counts, the HUD and the selection falling
    ;  back to something that exists all follow from one call.
    jp squad_refresh


; ----------------------------------------------------------------------------
;  mini_count -- how many ships the ambush is allowed to take
;  Out: A
;  Uses: everything
;
;  The player's region only, and never the Mothership -- by CLASS, because
;  fleet_restore moves what moth_slot points at. ENT_CLASS and ENT_HULL are the
;  two bytes immediately before ENT_FLAGS, which src/main.asm already asserts
;  for wave_health's sake, so a live slot reaches both with two DECs.
; ----------------------------------------------------------------------------
mini_count:
    ld hl,entities + ENT_FLAGS
    ld b,ENT_PLAYER_MAX
    ld c,0
@mg_count:
    ld a,(hl)
    and ENT_F_ACTIVE
    jr z,@mg_count_next
    push hl
    dec hl
    dec hl
    ld a,(hl)                           ; ENT_CLASS
    pop hl
    cp CLASS_MOTHERSHIP
    jr z,@mg_count_next
    inc c
@mg_count_next:
    ld de,ENT_SIZE
    add hl,de
    djnz @mg_count
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  mini_weakest -- the most damaged ship the ambush may take
;  Out: CF set -> HL points at its ENT_FLAGS; CF clear -> there is none
;  Uses: everything
;
;  A scan per casualty rather than a sort: k is at most half of fifty-six and
;  the world is stopped, so the whole thing is a few thousand T-states on a
;  screen that has nothing else to do -- and it is thirty bytes against a sort's
;  hundred, in a bank whose every byte costs DISC.BIN one.
; ----------------------------------------------------------------------------
mini_weakest:
    ld hl,entities + ENT_FLAGS
    ld b,ENT_PLAYER_MAX
    ld c,255                            ; the least hull seen so far
    ld de,0                             ; ...and which slot had it
@mg_weak:
    ld a,(hl)
    and ENT_F_ACTIVE
    jr z,@mg_weak_next
    push hl
    dec hl
    dec hl
    ld a,(hl)                           ; ENT_CLASS
    cp CLASS_MOTHERSHIP
    jr z,@mg_weak_pop
    ;  Hull at or below the best so far. AT, not below: the first version was
    ;  `cp c` against a C that starts at 255, so a fleet of interceptors -- all
    ;  of them at exactly 255 -- never produced a candidate at all and the
    ;  ambush took nothing. Comparing the other way makes the FIRST reading a
    ;  hit by construction, and ties then keep the LATER slot, which is the
    ;  newest-built ship of an undamaged fleet.
    inc hl                              ; -> ENT_HULL
    ld a,c
    cp (hl)
    jr c,@mg_weak_pop                   ; healthier than the best so far
    ld c,(hl)
    pop hl
    ld d,h
    ld e,l
    jr @mg_weak_next
@mg_weak_pop:
    pop hl
@mg_weak_next:
    push de
    ld de,ENT_SIZE
    add hl,de
    pop de
    djnz @mg_weak

    ld a,d
    or e
    ret z                               ; CF clear with it
    ex de,hl
    scf
    ret


; ----------------------------------------------------------------------------
;  mini_clear -- the playfield, black. The strips are not ours.
;  Uses: everything
; ----------------------------------------------------------------------------
mini_clear:
    ld b,0
    ld c,MG_BODY_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,MG_BODY_H
    xor a
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  mini_blank -- all two hundred lines, at each end of the chase
;  Uses: everything
;
;  THE STRIPS HAVE TO GO, and only at the ends. The context bar was left saying
;  "JUMPING 1 ESC CANCEL" over the whole chase and the HUD was left offering
;  RU, M 4 and JUMP -- instruments of a mission that is already behind the
;  fleet, and a key list that is wrong. That is the game-over screen's argument
;  arriving at a different screen.
;
;  Once at each end rather than every step, because 200 lines against 158 is a
;  quarter more work on a step that is already the whole of the frame. Nothing
;  redraws either strip while the chase runs, so black stays black -- and the
;  briefing that follows schedules mis_wipe, which clears all two hundred lines
;  and marks the HUD dirty, so both come back by themselves.
; ----------------------------------------------------------------------------
mini_blank:
    ld bc,#0000
    ld d,SCR_BYTES_PER_LINE
    ld e,SCR_HEIGHT_PX
    xor a
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  mini_draw -- one whole frame of it
;  Uses: everything
;
;  EVERYTHING, EVERY STEP. There are no dirty rectangles here and there must
;  not be: phase4's two lists belong to the mission that is paused underneath.
;  Redrawing 158 lines is affordable precisely because nothing else is running.
; ----------------------------------------------------------------------------
mini_draw:
    call mini_clear
    call mini_rings
    jp mini_ships


; ----------------------------------------------------------------------------
;  mini_say -- the line at the top, and the ambush's toll under it
;  Uses: everything
;
;  ONCE PER BUFFER AND NOT ONCE PER STEP, which is why it is not in mini_draw.
;  Thirty-four glyphs is five hundred screen bytes through txt_draw's pen map,
;  about a whole 50 Hz tick, on a line that does not change for the length of
;  the chase -- so the step's clear stops short of this band and the words
;  simply stay where they were put. The result overwrites the prompt, so this
;  blacks its own band first.
; ----------------------------------------------------------------------------
mini_say:
    ld b,0
    ld c,CTX_BAR_H
    ld d,SCR_BYTES_PER_LINE
    ld e,MG_BODY_Y - CTX_BAR_H
    xor a
    call scr_fill_rect

    ;  Ink 3 on the one line that is an alarm, and section 2's ink 1 -- the
    ;  game's own voice -- on the other two. Put back on the way out, which is
    ;  the contract txt_set_pen has everywhere.
    ld a,(mini_msg)
    cp MG_MSG_LOST
    ld a,1
    jr nz,@mg_pen
    ld a,3
@mg_pen:
    call txt_set_pen

    ld hl,mini_words
    ld a,(mini_msg)
    call bank7_fetch                    ; ...and it puts bank 4 back itself
    ld a,(mini_msg)
    ld e,a
    ld d,0
    ld hl,mini_msg_x
    add hl,de
    ld b,(hl)
    ld c,MG_TEXT_Y
    ld hl,bank7_line
    call txt_draw

    ;  ...and what it cost, when it cost anything. A penalty that is computed
    ;  and never shown is not a penalty, which is the third time this project
    ;  has written that down.
    ld a,(mini_msg)
    cp MG_MSG_LOST
    jr nz,@mg_no_toll
    ld hl,mini_words
    ld a,MG_MSG_TOLL
    call bank7_fetch
    ld hl,bank7_line
    ld b,MG_TOLL_X
    ld c,MG_LOST_Y
    call txt_draw
    ld a,(mini_lost)
    ld b,MG_TOLL_NUM_X
    ld c,MG_LOST_Y
    ld d,2
    call txt_draw_num
@mg_no_toll:
    ld a,1
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  mini_intro -- the page that says what the chase is, before the first one
;  Uses: everything
;
;  Drawn into BOTH buffers, because the display page-flips and a page painted
;  once alternates with whatever the other buffer holds -- the same obligation
;  every stopped-world screen in this game carries. Then it waits for ENTER.
;
;  key_hit reads key_hits, and key_hits is only refreshed by key_consume at the
;  top of demo_update -- which is not running: this is a private loop, like
;  the vanish's. So the loop calls key_consume itself, once a blank, and once
;  BEFORE it starts so that an edge left over from before the jump cannot
;  dismiss the page unread. (mini_steer has no such problem: it reads key_down,
;  and key_state is kept live by the 50 Hz scan regardless.)
;
;  mini_t0 is retaken on the way out. mini_wait paces the first step against
;  it, and a player who read the page for ten seconds would otherwise get a
;  first step that ended the instant it began.
; ----------------------------------------------------------------------------
mini_intro:
    ld hl,mini_shown
    ld a,(hl)
    or a
    ret nz                              ; met it already this campaign
    ld (hl),1

    ;  The flush comes BEFORE the drawing, not between it and the wait. Its
    ;  job is the edge left over from before the jump -- seven seconds of
    ;  vanish with no key_consume running, so an ENTER pressed anywhere in them
    ;  would open this page and shut it in the same frame. Put after the two
    ;  buffers are painted it also ate a press that landed DURING the painting,
    ;  which is a few frames and which the test fixture hit every time: the
    ;  page then waited for a second press that never came.
    call key_consume

    call mini_blank
    call mini_intro_page
    call mini_show
    call mini_blank
    call mini_intro_page
    call mini_show

@mg_intro_wait:
    call scr_wait_vsync
    call key_consume
    ld a,KEY_ENTER
    call key_hit
    jr nc,@mg_intro_wait

    ld a,(sys_tick_50hz)
    ld (mini_t0),a
    ret

;  The four lines in ink 1, walked on the cursor; then the prompt in ink 2,
;  which is what the context bar means by "a key". Pen back to 1 on the way
;  out, which is txt_set_pen's contract everywhere.
mini_intro_page:
    ld hl,mini_intro_words
    ld de,mini_intro_xy
    ld (mini_ip),de
    ld a,MG_INTRO_LINES
    ld (mini_idx),a
@mg_intro_line:
    xor a
    call bank7_fetch                    ; the string, and HL just past it
    push hl
    ld hl,(mini_ip)
    ld b,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld (mini_ip),hl
    ld hl,bank7_line
    call txt_draw
    pop hl
    ld a,(mini_idx)
    dec a
    ld (mini_idx),a
    jr nz,@mg_intro_line

    ld a,2
    call txt_set_pen
    xor a
    call bank7_fetch                    ; the prompt is the next string
    ld hl,bank7_line
    ld b,MG_INTRO_GO_X
    ld c,MG_INTRO_GO_Y
    call txt_draw
    ld a,1
    jp txt_set_pen

mini_intro_xy:
    defb MG_INTRO_1_X, MG_INTRO_Y
    defb MG_INTRO_2_X, MG_INTRO_Y + MG_INTRO_STEP
    defb MG_INTRO_3_X, MG_INTRO_Y + 2 * MG_INTRO_STEP
    defb MG_INTRO_4_X, MG_INTRO_Y + 3 * MG_INTRO_STEP


; ----------------------------------------------------------------------------
;  mini_rings -- the shaft: five rectangles walking outward together
;  Uses: everything
; ----------------------------------------------------------------------------
mini_rings:
    ;  The mouth swings AGAINST the steering, which is what banking looks like
    ;  from inside. A quarter of a pixel a unit, so the whole axis is +/- 22
    ;  pixels -- which keeps every edge of the widest ring on the screen with
    ;  the arithmetic in single bytes, and the swing is a garnish anyway: what
    ;  the player is reading is where the enemy sits against the middle.
    ld a,(mini_x)
    sub MG_X_MID
    sra a
    sra a
    ld b,a
    ld a,MG_CX
    sub b
    ld (mini_cx),a

    ld a,(mini_phase)
    ld (mini_idx),a
    ld a,MG_RINGS
    ld (mini_ring_n),a
@mg_ring:
    ld a,(mini_idx)
    ld e,a
    ld d,0
    ld hl,mini_ladder
    add hl,de
    ld a,(hl)
    call mini_ring

    ld a,(mini_idx)
    add a,MG_SPACING
    cp MG_LADDER
    jr c,@mg_ring_wrapped
    sub MG_LADDER
@mg_ring_wrapped:
    ld (mini_idx),a
    ld hl,mini_ring_n
    dec (hl)
    jr nz,@mg_ring
    ret


; ----------------------------------------------------------------------------
;  mini_ring -- one rectangle of the shaft
;  In : A = its half width in pixels
;  Uses: everything
;
;  Three quarters as tall as it is wide, because a Mode 1 pixel is about 0.83
;  of a scanline on a 4:3 display -- the same correction the title screen's
;  planet makes with TITLE_PLANET_RX against RY, and without it the shaft reads
;  as a tall slot rather than as a way through.
;
;  NOTHING HERE CLIPS. scr_fill_rect honours no bound at all and gfx_vline only
;  clips in Y, so the whole of this rests on the ladder's largest entry and the
;  swing of the mouth keeping every edge on the screen. src/main.asm asserts
;  both ends of that rather than leaving it to the eye.
; ----------------------------------------------------------------------------
mini_ring:
    ld (mini_hwr),a
    srl a
    ld b,a
    srl a
    add a,b                             ; hw/2 + hw/4
    ld (mini_hhr),a

    ;  The two sides, in pixels. Single bytes, which is what the swing above is
    ;  bounded for: the rightmost edge any ring can have is 244.
    ld hl,mini_hwr
    ld a,(mini_cx)
    sub (hl)
    ld (mini_lx),a
    srl a
    srl a
    ld (mini_bx),a                      ; ...and the top and bottom in BYTES
    ld a,(hl)
    srl a                               ; 2*hw pixels is hw/2 bytes
    ld (mini_bw),a

    ld hl,mini_hhr
    ld a,MG_CY
    sub (hl)
    ld (mini_ty),a
    call mini_hedge
    ld hl,mini_hhr
    ld a,MG_CY
    add a,(hl)
    ld (mini_ty),a
    call mini_hedge

    ;  ...and the two sides, one pixel wide, which is the only vertical line
    ;  this machine has.
    ;
    ;  HL RELOADED, because mini_hedge is a `jp scr_fill_rect` and that is
    ;  "uses everything". Reading the half height through a pointer the fill
    ;  had already scribbled on gave gfx_vline a random length at a random y,
    ;  and the shaft came out as a stack of horizontal bars with no sides at
    ;  all -- which the screenshot showed and no test would have.
    ld hl,mini_hhr
    ld a,(hl)
    add a,a
    ld b,a
    ld a,MG_CY
    sub (hl)
    ld c,a
    ld a,(mini_lx)
    ld l,a
    ld h,0
    ld a,MG_PEN
    push bc
    call gfx_vline
    pop bc
    ;  ...and the right-hand side in SIXTEEN bits, which is the one place in
    ;  this file that needs them: cx + hw reaches 258 at the widest ring, and
    ;  everything else here is bounded under 256 on purpose.
    ld a,(mini_cx)
    ld l,a
    ld h,0
    ld a,(mini_hwr)
    ld e,a
    ld d,0
    add hl,de
    ld a,MG_PEN
    jp gfx_vline


;  One horizontal edge, at (mini_bx, mini_ty) for (mini_bw) bytes.
;
;  SKIPPED IF IT IS OUTSIDE THE BAND THE STEP CLEARS, which is the whole of the
;  clipping this file does in Y: scr_fill_rect honours no bound at all, and a
;  row drawn above MG_BODY_Y would never be erased by anything. The compare is
;  unsigned and that is deliberate -- the top edge of the widest ring is
;  MG_CY - 102, which is negative, and a negative byte is a very large one, so
;  one CP catches both ends.
;
;  The SIDES need no such test: gfx_vline clips against spr_clip_top and
;  spr_clip_bottom, and mini_run points those at this same band for the length
;  of the chase.
mini_hedge:
    ld a,(mini_ty)
    sub MG_BODY_Y
    cp MG_BODY_H
    ret nc
    ld a,(mini_bx)
    ld b,a
    ld a,(mini_ty)
    ld c,a
    ld a,(mini_bw)
    ld d,a
    ld e,1
    ld a,MG_INK
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  mini_ships -- theirs, ahead and coming closer; ours, low and centre
;  Uses: everything
; ----------------------------------------------------------------------------
mini_ships:
    ;  Theirs. How far off the middle of the tunnel it is drawn is the same
    ;  number the distance rule reads, halved -- so "line it up in the middle"
    ;  is the whole of the instruction and the screen cannot disagree with the
    ;  arithmetic.
    ;  ...unless it is not there there any more. dist zero is the kill, and a red
    ;  ship still on the screen under THE VEKHAR IS GONE is the picture saying
    ;  the opposite of the words.
    ld a,(mini_dist)
    or a
    jr z,@mg_ours

    ld a,1
    ld (spr_enemy),a                    ; pen 1 becomes pen 3 in the blitter
    ld a,(mini_ex)
    ld hl,mini_x
    sub (hl)
    sra a
    add a,MG_CX
    ld e,a                              ; E = where on the screen, 72..248

    ;  ...and how far down the shaft, which is the distance itself: it comes
    ;  down towards you as you close, and grows a size at each threshold.
    ld hl,mini_dist
    ld a,MG_DIST0
    sub (hl)
    srl a
    srl a
    add a,MG_CY
    ld c,a

    ld a,(hl)
    ld b,0
    cp MG_TIER_FAR + 1
    jr nc,@mg_tiered
    inc b
    cp MG_TIER_MID + 1
    jr nc,@mg_tiered
    inc b
@mg_tiered:
    call mini_blit

    ;  Ours, at the near end, at the largest tier there is.
@mg_ours:
    xor a
    ld (spr_enemy),a
    ld e,MG_CX
    ld c,MG_SHIP_Y
    ld b,CLASS_TIERS - 1
    ;  ...and fall into mini_blit


; ----------------------------------------------------------------------------
;  mini_blit -- one interceptor, centred on (DE, C), at tier B
;  In : B = tier, DE = centre x in pixels (signed), C = centre y
;  Uses: everything
;
;  IT DOES NOT CALL class_tier_addr, and it must not: that routine pages bank 4
;  out and this file IS bank 4. class_geom, class_sprite and class_bank are all
;  in the low 16K -- src/main.asm asserts it, because the blitter reads them
;  with a foreign bank up -- so the geometry is worked out here with the window
;  at rest and spr_blit_banked does the one thing that has to happen from down
;  there. The placement arithmetic is phase4_blit_body's, instruction for
;  instruction, so a ship cannot come out somewhere its own game would not put
;  it.
; ----------------------------------------------------------------------------
mini_blit:
    ld a,c
    ld (mini_sy),a
    ld a,e
    ld (mini_sx),a

    ld l,b
    ld h,0
    push hl                             ; the tier, for the sprite address
    ld c,l
    ld b,h
    add hl,hl                           ; * 2
    add hl,bc                           ; * 3
    add hl,hl                           ; * 6 = CLASS_GEOM_SIZE
    ld bc,class_geom
    add hl,bc

    ld a,(hl)
    ld (spr_w),a
    inc hl
    ld a,(hl)
    ld (spr_h),a
    inc hl
    ld c,(hl)                           ; half width, pixels
    inc hl
    ld b,(hl)                           ; half height, lines

    ;  x = (centre - half width) >> 2. In single bytes, and it cannot borrow:
    ;  the leftmost either ship can be drawn at is 72 - 14.
    ld a,(mini_sx)
    sub c
    srl a
    srl a
    ld l,a
    ld h,0
    ld (spr_x),hl

    ld a,(mini_sy)
    sub b
    ld l,a
    ld h,0
    ld (spr_y),hl

    ;  The interceptor's row of class_sprite, which is the first one, and view
    ;  MG_VIEW at pre-shift 0.
    pop hl
    add hl,hl
    ld de,class_sprite
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (spr_src),de

    ld a,(class_bank)
    jp spr_blit_banked


; ============================================================================
;  Data and scratch
; ============================================================================
;  THE LADDER. Half widths in pixels, 9 to 76, each about 1.16 times the one
;  before it -- so a ring that appears at the far end takes the whole fifteen
;  steps to reach the near one and grows the way something approaching at a
;  constant speed does. Geometric and not linear: linear is what a corridor of
;  evenly spaced hoops looks like, which is nothing at all.
;
;  IT RUNS PAST THE VIEWER RATHER THAN STOPPING, and that is what the top of
;  the ladder is for. At 62 the largest ring was 124 pixels of 320 -- a small
;  window in the middle of a black screen -- and worse, a ring simply VANISHED
;  when it got there, in the middle of the picture, which reads as a fault
;  rather than as motion. At 137 the mouth is 274 pixels wide and 205 lines
;  tall: its top and bottom leave the band the step redraws at rung 12, so the
;  last three rungs are two vertical lines sweeping outwards, and the ring
;  leaves at the EDGES of the picture the way something you have flown through
;  does. This project has a section called "Using the width of the screen"; it
;  applies to a screen with one thing on it too.
;
;  137 EXACTLY, AND NOT MORE, because nothing here clips in X: the mouth swings
;  to 182 and gfx_vline takes an x it trusts, so 182 + 137 is 319 and one more
;  would be drawn on the next scanline down. src/main.asm asserts both ends.
mini_ladder:
    defb 9, 11, 13, 16, 20, 24, 29, 35, 43, 52, 63, 76, 93, 113, 137
mini_ladder_end:

;  The columns, indexed by mini_msg. See the equates at the head of the file.
mini_msg_x:
    defb MG_RUN_X, MG_WON_X, MG_LOST_X, MG_TOLL_X
mini_msg_x_end:

;  ...and its working state is declared AFTER bank4_end, in src/main.asm, for
;  the reason fleet_block and class_standin are: it starts at nothing and
;  uninitialised bank storage costs DISC.BIN nothing at all. The seven bytes a
;  test has to watch while the chase runs are in the low 16K, and are there for
;  a different reason -- see the head of this file.
