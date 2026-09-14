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
    call hud_squad_health               ; the HULL bar's own reading, if it is due
    call unlock_banner                  ; the centre-screen unlock line, if one is up
    call shot_draw                      ; this frame's tracers, over the ships
    call pilot_reticle                  ; ...and the reticle, while a ship is flown
    call pilot_arrow                    ; ...and the way to its enemy, or the enemy's strength
    call wave_marker                    ; ...and where INCOMING is coming from
    ld ix,hud_alarm_frame               ; ...and the squadron alarm's blink, EVERY frame:
    ld a,GA_BANK_5                      ; bank 5, game/hudmarks.asm
    call bankn_call

    call wave_changed
    ld hl,wave_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ;  The SELECTED SQUADRON's bar -- or, on the enemy's turn (bit 7 of
    ;  hud_bar_val, see hud_phase), the enemy's strength in a RED trough
    ;  under ENM: "Όταν ήμαστε σε μάχη, το Hull να εναλάσσεται κάθε 2
    ;  δευτερόλεπτα με την δύναμη του εχθρού. Να δείχνει ΕΝΜ και την μπάρα
    ;  με κόκκινο αντί για μπλε." rlca : sbc a,a is #FF for bit 7 and 0
    ;  otherwise, and SOLID_INK_2 OR #FF is SOLID_INK_3: no branch.
    ld a,(hud_bar_val)
    rlca
    sbc a,a
    or SOLID_INK_2
    ld c,a                              ; the trough: chrome, or the alarm ink
    ld a,(hud_bar_val)
    and #7F
    ld b,HUD_BAR_X
    call hud_fill_ink
    call hud_bar
    ld a,(wave_moth_pct)
    ld b,HUD_MOTH_BAR_X
    ld c,SOLID_INK_2
    call hud_fill_ink
    call hud_bar
    ;  ...and the caption, HULL or ENM, over the first: hud_draw's HULL is
    ;  under whichever this paints, and both are four cells.
    ld hl,hud_hp_label
    ld a,(hud_bar_val)
    add a,a                             ; CF = bit 7
    jr nc,@wd_caption
    ld hl,hud_en_label
@wd_caption:
    ld b,HUD_HP_X
    ld c,CTX_Y
    call phase4_hud_label

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
    ld a,(hud_bar_val)                  ; the bar's figure AND whose turn it is; wave_pct_shadow is its shadow
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
    ld a,(hud_bar_val)
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
    dec a                               ; #FF: no squadron, so the HULL bar re-reads
    ld (hud_sq_sel),a
    jp wave_health


; ----------------------------------------------------------------------------
;  hud_squad_health -- (hud_sq_pct) = the SELECTED squadron's hull, 0..100,
;                      (hud_en_pct) = the ENEMY's, and then hud_phase
;  Uses: everything
;
;  "Το Hull πρέπει να δείχνει την κατάσταση του επιλεγμένου squadron." The
;  fleet's average is what the waves are sized on and what wave_pct still
;  holds; the bar under HULL is the squadron the player is looking at, which
;  is the one whose damage is a decision -- repair it, recycle it, or send it
;  in again. With the base selected (SQUAD_NONE) it is the fleet's: BASE
;  beside it already says the Mothership's own.
;
;  Re-read on the frame wave_health has just walked the fleet -- wave_tick is
;  left at WAVE_READ_EVERY on that frame and nothing else -- and whenever the
;  selection has moved, so a number key changes the bar on its own frame
;  rather than up to four later. The walk is hud_walk, wave_health's loop with
;  the fold as a parameter: hud_sq_fold asks the squadron byte, hud_en_fold
;  asks for a FLYING hostile (ENEMY and not DISABLED, mis_count_hostiles'
;  own test, so a wreck adrift counts for nothing either way), and both FOLD
;  THROUGH wave_hp_add into wave_hull/wave_full, which are the fleet's: they
;  are saved on the stack and put back, so wave_send's reading is untouched.
;  The enemy's is read on the same frames, twenty slots, so the bar under ENM
;  moves as the fight goes -- it is the mirror of HULL, hull over full, not a
;  headcount.
; ----------------------------------------------------------------------------
hud_squad_health:
    ld a,(wave_tick)
    cp WAVE_READ_EVERY
    jr z,@hsq_read
    ld a,(squad_sel)
    ld hl,hud_sq_sel
    cp (hl)
    jr nz,@hsq_read
    jr hud_phase                        ; nothing new to read: the turn still ticks
@hsq_read:
    ld a,(squad_sel)
    ld (hud_sq_sel),a
    ld hl,(wave_hull)
    push hl
    ld hl,(wave_full)
    push hl
    cp SQUAD_NONE
    ld a,(wave_pct)
    jr z,@hsq_store                     ; the base selected: the whole fleet's
    ld hl,entities + ENT_FLAGS
    ld b,ENT_PLAYER_MAX
    ld de,hud_sq_fold
    call hud_walk
@hsq_store:
    ld (hud_sq_pct),a
    ld hl,entities + ENT_PLAYER_MAX * ENT_SIZE + ENT_FLAGS
    ld b,ENT_ENEMY_MAX
    ld de,hud_en_fold
    call hud_walk
    ld (hud_en_pct),a
    pop hl
    ld (wave_full),hl
    pop hl
    ld (wave_hull),hl
    ;  ...and fall into hud_phase

; ----------------------------------------------------------------------------
;  hud_phase -- whose turn the HULL bar is: (hud_bar_val) = the percentage to
;               draw, bit 7 set on the ENEMY's
;  Uses: AF, C, HL
;
;  "Όταν ήμαστε σε μάχη, το Hull να εναλάσσεται κάθε 2 δευτερόλεπτα με την
;  δύναμη του εχθρού." A fight is something hostile FLYING -- cbt_hostiles,
;  the count cbt_prey_roll takes at the top of every cbt_update, the jump
;  gate's and V's own predicate -- and the turn flips every HUD_PHASE_TICKS
;  of the 50 Hz tick, counted from hud_phase_tick and stepped by the period
;  rather than reset, so the turns are two seconds each whatever the frame
;  rate. Out of a fight it is HULL, always; the clock free-runs, so a fight
;  may open on either turn, which is a second of ENM at most. The value is
;  rebuilt every frame from whichever reading is current, so the bar follows
;  the hull under HULL and the enemy under ENM; wave_changed compares this
;  byte, and the bit is what makes the flip itself a repaint.
; ----------------------------------------------------------------------------
hud_phase:
    ld hl,hud_phase_tick
    ld a,(sys_tick_50hz)
    sub (hl)
    cp HUD_PHASE_TICKS
    ld a,(hud_bar_val)                  ; the flags survive the load
    jr c,@hp_keep
    ld c,a
    ld a,(hl)
    add a,HUD_PHASE_TICKS               ; the period is up: step the clock, not reset it
    ld (hl),a
    ld a,c
    xor #80                             ; ...and it is the other's turn
@hp_keep:
    ld c,a
    ld a,(cbt_hostiles)
    or a
    ld a,c
    jr nz,@hp_fight
    xor a                               ; no fight: HULL
@hp_fight:
    and #80
    ld c,a                              ; Z: HULL's turn
    ld a,(hud_sq_pct)
    jr z,@hp_val
    ld a,(hud_en_pct)
@hp_val:
    or c
    ld (hud_bar_val),a
    ret

;  hud_walk -- hull over full across a run of slots, through a fold
;  In : HL -> the first slot's ENT_FLAGS, B = slots, DE = the fold to call
;       for an ACTIVE one (HL -> its flags; it keeps HL, DE and B)
;  Out: A = 100 * hull / full over what the fold accepted
;  Uses: everything
;
;  The fold is the CALL's own operand, patched in: one loop for two readings
;  and no branch inside it. Self-modifying, like scr_fill_rect's fill byte.
hud_walk:
    ld (@hw_fold),de
    push hl
    ld hl,0
    ld (wave_hull),hl
    ld (wave_full),hl
    pop hl
    ld de,ENT_SIZE
@hw_one:
    ld a,(hl)
    and ENT_F_ACTIVE
@hw_fold equ $ + 1
    call nz,0                           ; the fold: patched above
    add hl,de
    djnz @hw_one
    ld hl,(wave_hull)
    ld de,(wave_full)
    jp wave_pct_of

;  In : HL -> a live ship's ENT_FLAGS byte
;  Out: HL, DE and B as they were, like wave_hp_add
;  Uses: AF, C
;  The player's region holds nothing hostile (the partition), so the squadron
;  byte is the whole question.
hud_sq_fold:
    inc hl
    ld a,(hl)                           ; ENT_SQUAD is the byte after the flags
    dec hl
    ld c,a
    ld a,(squad_sel)
    cp c
    ret nz
    jp wave_hp_add

;  ...and the hostile region's: a FLYING hostile, wrecks not.
hud_en_fold:
    ld a,(hl)
    and ENT_F_ENEMY + ENT_F_DISABLED
    cp ENT_F_ENEMY
    ret nz
    jp wave_hp_add

; ----------------------------------------------------------------------------
;  hud_fill_ink -- what a bar's fill is drawn in
;  In : A = the percentage, C = the trough's ink
;  Out: (hud_bar_fill) = SOLID_INK_1, or SOLID_INK_3 below HUD_HP_ALARM on a
;       chrome trough; A, B, C as they were
;  Uses: F
;
;  The alarm ink is for OUR hull, and on the enemy's turn the trough is
;  already that ink: a red fill on a red trough is no fill at all, so the
;  enemy's is white whatever it reads -- the trough says whose it is. The
;  decision was hud_bar's, in the low 16K, which is at its page; here it is
;  bank code and eight bytes cheaper down there.
; ----------------------------------------------------------------------------
hud_fill_ink:
    push af
    cp HUD_HP_ALARM
    ld a,SOLID_INK_1
    jr nc,@hf_store
    ld a,c
    cp SOLID_INK_2
    ld a,SOLID_INK_1
    jr nz,@hf_store                     ; the enemy's turn: white
    ld a,SOLID_INK_3
@hf_store:
    ld (hud_bar_fill),a
    pop af
    ret

hud_sq_pct:         defb 100            ; what the HULL bar draws on its turn
hud_en_pct:         defb 0              ; ...and the ENM bar on its
hud_sq_sel:         defb #FF            ; the selection it was read for
