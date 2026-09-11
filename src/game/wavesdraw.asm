; ============================================================================
;  game/wavesdraw.asm -- the hull row, in bank 4
; ============================================================================
;  The DRAWING half of game/waves.asm. The equates, every byte of state and the
;  whole of the simulation stay in the low 16K; this is the pen work and the
;  four strings it needs.
;
;  Same split as order.asm/ordercmd.asm and squadinfo.asm/squadinforun.asm, and
;  it went across for the same reason those did: the low 16K ran out. Adding
;  the Mothership's own figure to this row took `free:` from 524 to 268, and
;  the floor is about 450 -- tests/test_sound.py puts 384 bytes of stub above
;  LOW_END and the harness another 0x60, so a dozen test classes that have
;  nothing to do with waves start failing below it. The bill arrives in units
;  of 256, because gen/tables.asm is page-aligned.
;
;  IT IS LEGAL HERE BY THE NARROW TEST AND NOT BY THE LOOSE ONE. "Does it run
;  while the game is stopped" would say no -- this runs once every game frame.
;  The rule is "can it run between class_tier_addr and class_blit_done", and
;  nothing here can: wave_draw is called from the HUD's own point in the frame,
;  after every blit is finished and with bank 4 back at rest. game/ctxbar.asm
;  and gfx/markproj.asm are the other two that live here on that reasoning.
;
;  CODE MOVES FOR FREE AND DATA COSTS A HUNDRED CALL SITES, so wave_pct,
;  wave_moth_pct, wave_dirty and the two shadows all stayed down there: half
;  the suite reads them with read_ram, and a variable in the bank has to be
;  read with read_bank4 instead.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  wave_draw -- one frame of the two hull bars
;  Uses: everything
;
;  HULL and BASE are BARS on the top strip's first line now (hud2.md, and
;  game/huddraw.asm for the strip), and this draws exactly those two: their
;  captions, the treasury and the mission beside them are hud_draw's, on its
;  own shadow, and the message row's word is the context bar's, on the bottom
;  text line. wave_dirty is the bars' flag -- set here when a percentage
;  moves, and by hud_draw whenever it has blanked the strip under them.
; ----------------------------------------------------------------------------
wave_draw:
    call unlock_banner                  ; the centre-screen unlock line, if one is up
    call shot_draw                      ; this frame's tracers, over the ships
    call pilot_reticle                  ; ...and the reticle, while a ship is flown
    call pilot_scanner                  ; ...and the scanner beside it
    call wave_marker                    ; ...and where INCOMING is coming from

    call wave_changed
    ld hl,wave_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ld a,(wave_pct)
    ld b,HUD_BAR_X
    call hud_bar
    ld a,(wave_moth_pct)
    ld b,HUD_MOTH_BAR_X
    call hud_bar

    ;  The tutorial owns the strip's SECOND line while it runs, and its
    ;  instruction is repainted on this same flag: tut_enter and every step
    ;  change set wave_dirty, and hud_draw sets it whenever it has blanked the
    ;  strip. One flag for the line whoever is drawing there, which is what
    ;  makes the coupling with mis_wipe free. See game/tutorialrun.asm.
    ld a,(tut_active)
    or a
    jp nz,tut_draw
    ret


; ----------------------------------------------------------------------------
;  wave_changed -- has anything in the row moved?
;  Uses: everything
;
;  Two shadows and the same shape as phase4_hud_changed, for the same reason:
;  hull falls with nobody pressing anything. The message row's word used to
;  be compared here too; it is the context bar's now (ctx_classify folds
;  wave_saying into ctx_sub), so the bars repaint for the hull and nothing else.
; ----------------------------------------------------------------------------
wave_changed:
    ld a,(wave_pct)
    ld hl,wave_pct_shadow
    cp (hl)
    jr nz,@wave_hp_diff

    ;  ...and the Mothership's, which moves on its own: a wave that goes
    ;  straight for it can take a fifth of its hull without the fleet's average
    ;  moving a whole point.
    ld a,(wave_moth_pct)
    ld hl,wave_moth_shadow
    cp (hl)
    ret z

@wave_hp_diff:
    ld a,(wave_pct)
    ld (wave_pct_shadow),a
    ld a,(wave_moth_pct)
    ld (wave_moth_shadow),a
    ld a,2                              ; once into each screen buffer
    ld (wave_dirty),a
    ret



; ----------------------------------------------------------------------------
;  wave_say_unlock -- put "the yard has learned a class" on the message row
;  In : A = the unlock mask that was just set -- ONE bit
;  Uses: AF, B
;
;  THE BIT NUMBER IS THE MESSAGE NUMBER, plus one for INCOMING at 0. So the
;  list of things that can be unlocked and the list of words saying so are one
;  list in one order, and adding a third capital ship is a bit, a derelict_table
;  row and a string -- with nothing to keep in step by hand. The alternative,
;  a message index carried in derelict_table beside the mask, is a second
;  number meaning the same thing.
;
;  The shift is four instructions against a table of eight bytes, and it cannot
;  spin: A is non-zero by the time it gets here (mis_derelict_unlock returns
;  carry clear for a class that teaches nothing, and slv_deliver branches on
;  that), and the guard at the top makes that true rather than merely likely.
;
;  PRESERVES HL, and that is not politeness: its one caller is inside
;  slv_deliver, between the entity pointer being taken and ENT_FLAGS being
;  cleared through it. Two bytes of state, so there is nothing else to save.
;
;  IN BANK 4 with the rest of this row's drawing, and it had to be. Written in
;  waves.asm first, beside the state it writes -- twelve bytes, which took the
;  low 16K over a page boundary and `free:` from 484 to 228, well under the
;  ~450 the tests need for their scratch. The bill comes in units of 256 and
;  the split is the standing answer: state in the low 16K where read_ram can
;  see it, code in the bank. slv_deliver is bank 4 code already, so this is a
;  call between two routines that are both here.
;
;  IT OVERWRITES AN INCOMING THAT IS STILL UP, which is the one judgement in
;  here. A threat outranks good news -- but this fires ONCE IN A CAMPAIGN and
;  INCOMING fires every wave, so the player loses at worst a few seconds of a
;  warning that will be repeated inside a minute, against never being told at
;  all that the thing they have spent three missions towing has worked. The
;  hull was also delivered by a corvette they sent, so they are looking at the
;  fleet rather than at the horizon.
; ----------------------------------------------------------------------------
wave_say_unlock:
    or a
    ret z                               ; a class that teaches nothing
    ld b,0
@wave_unlock_bit:
    inc b
    rrca
    jr nc,@wave_unlock_bit
    ld a,b                              ; bit 0 -> message 1, bit 1 -> 2
    ld (wave_msg),a
    call ban_say                        ; ...and across the middle of the view
    ld a,WAVE_SAY_FRAMES
    ld (wave_say),a
    ret


; ----------------------------------------------------------------------------
;  wave_saying -- what the message row is saying, as ONE byte
;  Out: A = 0 when quiet, else the message number plus one
;  Uses: AF
;
;  ONE shadow byte for both halves of the state, and that is what it is for.
;  The countdown ticks every frame, so comparing it as a number would repaint
;  the row forty times a message; comparing it as a yes/no was right while
;  there was one message and became a hole the moment there were two -- an
;  unlock landing while INCOMING is still up does not change the yes/no, so the
;  row would go on saying INCOMING until the countdown ran out. Plus one is
;  what keeps message 0 distinct from silence.
; ----------------------------------------------------------------------------
wave_saying:
    ld a,(wave_say)
    or a
    ret z
    ld a,(wave_msg)
    inc a
    ret


;  (HULL and BASE are captions on the top strip, in game/huddraw.asm)
;  Indexed by wave_msg, so the ORDER here is WAVE_MSG_*: message n+1 is the
;  class unlocked by bit n of campaign_unlocks. Every one must fit between
;  HUD_SAY_X and HUD_MOTH_X -- eighteen characters -- and src/main.asm asserts
;  each of them separately, because txt_draw clips at the screen edge and would
;  happily write over the top of the Mothership's hull figure.
;
;  "YARD:" AND NOT "UNLOCKED", and the Destroyer is why. DESTROYER UNLOCKED is
;  eighteen characters exactly: it clears the assert, and it ends on the very
;  byte BASE begins at, so the two words touch with no gap at all. The yard is
;  what has learned the class and it is where the player goes to use it, so the
;  prefix says who is talking in five characters instead of eight -- and both
;  messages then read the same way, which "FRIGATE UNLOCKED" beside "YARD:
;  DESTROYER" would not have.
;  (wave_say_text is in BANK 7 now, in game/screentext.asm)


; ----------------------------------------------------------------------------
;  mus_battle -- hold the tune while there is shooting, let it back afterwards
;  Uses: AF, HL
;
;  "H μουσική μέσα στο παιχνίδι να είναι ολόκληρη όπως και στο μενού. Όταν
;  γίνεται επίθεση να σταματάει." A fight is SHOTS: cbt_shots moving. Every
;  shot rearms MUS_QUIET_FRAMES of silence, so the tune comes back a few
;  seconds after the last one, and it does not restart -- mus_update goes on
;  advancing the three streams while mus_held is set and mus_write_block
;  writes an idle block instead of the note, so it comes back in time with
;  itself. The transition IN zeroes the three voices' timers, because a note
;  already sounding would otherwise ring for the rest of its MUS_TIMER; and it
;  gives channel B back to the noise generator, because that is where the
;  explosions are. Bank 4 code called once a frame from mus_update, which is
;  the low 16K and had no page to spare.
; ----------------------------------------------------------------------------
MUS_QUIET_FRAMES    equ 30              ; ~4-6 s of no shooting before it returns

mus_battle:
    ;  A fight is a SHOT or a DEATH -- the two counters cbt_update keeps,
    ;  folded into one byte so one shadow sees both. A death without a shot
    ;  is the ambush's toll, and an explosion under the harmony would be a
    ;  tone: B has to be the noise voice by then.
    ld a,(cbt_shots)
    ld hl,cbt_kills
    add a,(hl)
    ld hl,mus_shots_seen
    cp (hl)
    ld (hl),a
    jr z,@mus_no_shot
    ld a,MUS_QUIET_FRAMES
    ld (mus_quiet),a
    jr @mus_battle_state
@mus_no_shot:
    ld hl,mus_quiet
    ld a,(hl)
    or a
    jr z,@mus_battle_state
    dec (hl)
@mus_battle_state:
    ld a,(mus_quiet)
    or a
    ld hl,mus_held
    jr z,@mus_calm
    ;  a fight: hold, and on the way in silence what is sounding
    ld a,(hl)
    or a
    ret nz                              ; already held
    ld (hl),1
    ld a,SND_MIX_B_NOISE
    ld (snd_mix_mask_b),a
    xor a
    ld (snd_voice_a),a
    ld (snd_voice_b),a
    ld (snd_voice_c),a
    ret
@mus_calm:
    ld (hl),0
    ;  B goes back to being a TONE voice for the harmony once nothing is
    ;  sounding on it -- snd_start_b took it for the noise generator, and an
    ;  explosion is not always inside a fight (the ambush's toll, for one).
    ;  Every frame, because it is two loads and a compare.
    ld a,(mus_solo)
    or a
    ret nz                              ; solo keeps B for the noise
    ld a,(snd_voice_b)                  ; +0 timer: an effect still on it
    or a
    ret nz
    ld a,SND_MIX_B_TONE
    ld (snd_mix_mask_b),a
    ret


; ----------------------------------------------------------------------------
;  wave_marker -- a red cross where the wave is arriving, while INCOMING is up
;  Uses: everything
;
;  future.md item 2. The item was written as "the seconds between INCOMING and
;  arrival", and there are none: wave_send places the ships and says the word
;  in one call. What there IS is WAVE_SAY_FRAMES of the word on the HUD with a
;  wave three thousand units out closing on the base, and a player who does not
;  know which way to look. So for as long as the row says INCOMING this puts a
;  cross in the alarm ink at the wave's arrival point -- the Mothership plus
;  WAVE_RADIUS along the bearing, the point wave_place jitters each ship about
;  -- ON the point when it projects, and on the border of the view in its
;  direction when it does not, through the Mothership indicator's own
;  moth_border. Recomputed every frame it is up: one proj_point, forty times
;  a wave. The Mothership's marker is saved and put back around the borrowed
;  call, because moth_update only recomputes it when the camera moves.
; ----------------------------------------------------------------------------
wave_marker:
    ld a,(wave_say)
    or a
    ret z                               ; nothing on the message row
    ld a,(wave_msg)
    or a                                ; WAVE_MSG_INCOMING
    ret nz                              ; ...or something else is
    ld a,(wavem_fixed)
    or a
    jr nz,@wave_marker_point            ; a raid: the point is already the wreck's
    ld a,(moth_slot)
    call ent_is_active
    ret nc
    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0
    ld de,wave_point
    ld bc,6
    ldir
    ld a,(wave_bearing)
    ld c,WAVE_RADIUS
    call wave_offset                    ; HL = sin(bearing) * R
    ld de,(wave_point)
    add hl,de
    ld (wave_point),hl
    ld a,(wave_bearing)
    add a,TRIG_QUARTER                  ; the cosine
    ld c,WAVE_RADIUS
    call wave_offset
    ld de,(wave_point + 4)
    add hl,de
    ld (wave_point + 4),hl

@wave_marker_point:
    ld hl,wave_point
    ld (mark_src),hl
    call proj_point
    jr nc,@wave_marker_off
    ld hl,(proj_sx)
    ld a,(proj_sy)
    ld c,a
    jr @wave_marker_draw

@wave_marker_off:
    ld hl,moth_x
    ld de,wavem_save
    ld bc,4
    ldir                                ; the Mothership's marker, kept
    xor a
    ld (moth_bar),a                     ; so "no bearing" reads as none
    call moth_border
    ld a,(moth_bar)
    ld b,a
    ld hl,(moth_x)
    ld a,(moth_y)
    ld c,a
    push bc
    push hl
    ld hl,wavem_save
    ld de,moth_x
    ld bc,4
    ldir                                ; ...and put back
    pop hl
    pop bc
    ld a,b
    or a
    ret z                               ; straight along the view axis: no answer
@wave_marker_draw:
    ld a,PEN_RED
    jp mark_cross                       ; ...and its rectangle, so it is erased


; ----------------------------------------------------------------------------
wave_init:
    ld hl,WAVE_FIRST_TICKS
    ld (wave_next),hl
    xor a
    ld (wave_count),a
    ld (wave_size),a
    ld (wave_say),a
    ;  The readout must be right on the first frame of the mission, not on the
    ;  second: mis_setup has just changed the fleet.
    jp wave_health
