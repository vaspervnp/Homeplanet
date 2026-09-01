; ============================================================================
;  game/tutorialrun.asm -- the tutorial stage, IN BANK 4
; ============================================================================
;  Split out of game/tutorial.asm, which keeps the equates and the state the
;  frame loop and the tests read. Read the head of that file first: it says
;  what this is and, more importantly, what it is not.
;
;  WHY IT IS IN THE BANK
;  ---------------------
;  tut_enter runs from a keypress on the title screen; tut_draw runs once a
;  frame, at the very end, from wave_draw; tut_update runs once a frame at the
;  very top of demo_update. None of them can be reached from between
;  class_tier_addr and class_blit_done, which is the narrow test in
;  game/shipclass.asm and the only one that matters. The same argument that
;  puts game/ctxbar.asm here.
;
;  A STEP IS A ROW
;  ---------------
;  tut_table is TUT_STEPS rows of (gate, entry act), both addresses, and
;  tut_text is TUT_STEPS zero-terminated strings back to back walked by
;  str_index -- the same shape mission_text and menu_entries already have.
;  Adding a step is a row and a string.
;
;      GATE   called every frame while the step is showing. CF set means the
;             player has done the thing and the tutorial moves on. It is
;             called on the step's FIRST frame too, with (tut_fresh) set, so
;             that a gate which needs a reference reading can take its own --
;             tut_update clears the flag afterwards, so a gate never has to.
;      ACT    called once, on that first frame, before the gate. Two steps use
;             one: the fight needs a hostile to exist and the last step needs
;             mis_complete set so the HUD offers JUMP the way a real mission
;             does.
;
;  WHY THE GATES ARE WRITTEN THE WAY THEY ARE
;  ------------------------------------------
;  A gate that says "the key was pressed" teaches nothing and passes for the
;  wrong reason -- which is the failure mode a gated tutorial has, and it is
;  the same blind spot as every test in this project that counted. So each
;  gate watches the EFFECT: the yaw has moved, the station has moved, RU has
;  gone up, the hostile is gone. Doing the wrong thing (cancelling the disc
;  with ESC rather than confirming it with ENTER; pressing `0` without having
;  panned first) leaves the gate exactly where it was, and there is a test for
;  each of those as well as for the right thing.
; ----------------------------------------------------------------------------

;  Where the tutorial's own hostile arrives. The same +z the campaign's every
;  picket sits on and the same distance as mission 3's, which is known to be
;  drawn at the zoom every stage opens on -- see the note above derelict_pos
;  in game/campaign.asm for what happens when that is assumed rather than
;  measured. It is far enough out that cbt_move_enemies takes about thirty
;  game frames to close, which is the room the player needs to press `A`.
TUT_ENEMY_Z         equ 5000

;  ...and the pitch the stage opens on. See tut_enter for why it is not zero.
;  Well inside CAM_PITCH_MAX, and about 34 degrees, which is enough for the
;  Y=0 lattice to read as a plane and for two formations at different heights
;  to be told apart.
TUT_PITCH           equ 24

;  ...and how tough the one hostile is. See tut_a_enemy.
TUT_ENEMY_HULL      equ 120


; ----------------------------------------------------------------------------
;  tut_enter -- `T` on the title screen
;
;  Sets up a world of its own. Everything it writes is rebuilt from scratch by
;  demo_reset on the way out, and NOTHING it writes is the campaign's: not
;  mis_index, not fleet_count, not fleet_buffer, not campaign_unlocks, and
;  above all not the disc.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_enter:
    ;  Off the title, paying the same debt title_key pays: the screen has been
    ;  painted with no dirty rectangle recorded for any of it, so two frames of
    ;  wipe, one per buffer, and the HUD has to be put back after them.
    xor a
    ld (title_shown),a
    ld a,2
    ld (mis_wipe),a
    ld (phase4_hud_dirty),a

    ;  ...and out from behind the first mission's briefing, which mis_init
    ;  opened at boot and which the title has been sitting in front of. Without
    ;  this the tutorial would come up under a briefing for a mission it is not.
    xor a
    ld (mis_briefing),a
    ld (mis_complete),a
    ld (mis_leave_ok),a
    ld (mis_failed),a
    ld hl,0
    ld (mis_timer),hl

    ld a,1
    ld (tut_active),a
    ld (tut_fresh),a
    xor a
    ld (tut_step),a
    ld (tut_flags),a

    ;  The subsystems, in demo_init's own order and for demo_init's own
    ;  reasons. mis_init is NOT among them: it is the campaign's.
    ;
    ;  A CAMERA THAT IS ALREADY TILTED is the one place the tutorial
    ;  deliberately does not open the way a mission does. demo_init starts at
    ;  pitch 0, where the reference plane is edge-on and the whole world -- the
    ;  Y=0 lattice, both formations, the fields -- collapses into a single
    ;  horizontal line, because the content of this game is essentially planar.
    ;  A mission recovers the moment the player touches an arrow key; a tutorial
    ;  whose first instruction IS "arrow keys turn the view" has to look like a
    ;  place before it asks anybody to look around it.
    xor a
    ld (cam_yaw),a
    ld a,TUT_PITCH
    ld (cam_pitch),a
    call order_init
    call tut_stations                   ; ...over the top of order_home's
    call form_init
    call cbt_init
    call eco_init
    call mark_init                      ; the patches have moved; recache
    call tut_spawn
    call tut_patches

    ;  The line has to be painted into both buffers before anything else
    ;  happens. wave_dirty is row C's flag whoever is drawing there -- see
    ;  tut_draw.
    ld a,2
    ld (wave_dirty),a
    jp squad_init


; ----------------------------------------------------------------------------
;  tut_exit -- back to the title screen, with the campaign put back
;
;  It does NOT restore a snapshot. demo_reset is everything demo_init does
;  except loading the sprite libraries, which includes fleet_disc_load -- so
;  the campaign that comes back is READ OFF THE DISC, exactly as it would be
;  on a cold boot. That is the whole safety argument in one CALL: a tutorial
;  that never writes the disc cannot damage a campaign that is derived from it.
;
;  There is deliberately NO jump wipe here, and it is not an oversight.
;  jfx_vanish takes seven seconds and leaves jfx_armed set, which arms the
;  REVEAL on the next briefing dismissed -- and the next briefing is mission
;  one's, which demo_reset is about to open. The player would sit through
;  seventeen seconds of a mission being uncovered that they had not jumped to.
;  There is nothing to sweep away either: title_draw clears all 200 lines on
;  its first frame.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_exit:
    xor a
    ld (tut_active),a
    jp demo_reset


; ----------------------------------------------------------------------------
;  tut_jump -- what `J` means while the tutorial is running
;
;  mis_jump's first instruction comes here, so this covers every door into it:
;  order_update's own KEY_J, and the orders menu, which INJECTS that key.
;
;  Refused unless the tutorial is on its last step, which is exactly what
;  mis_jump does with an objective that has not been met -- so `J` behaves the
;  way the thing it is teaching behaves, and the HUD's JUMP appears at the same
;  moment, because tut_a_ready sets mis_complete.
;  Out: CF clear -- nothing here is a jump
;  Uses: everything
; ----------------------------------------------------------------------------
tut_jump:
    ld a,(tut_step)
    cp TUT_STEPS - 1
    jr z,tut_exit
    or a
    ret


; ----------------------------------------------------------------------------
;  tut_update -- one frame of the tutorial
;
;  Called from the VERY TOP of demo_update, before the static-screen branches,
;  and that is load-bearing rather than tidy: step 6 is gated on the squadron
;  breakdown having been opened and closed, and while info_shown is set
;  demo_update returns long before it reaches the playing path. A gate called
;  from down there would never see the page at all.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_update:
    ld a,(tut_active)
    or a
    ret z

    ;  The entry act, once. It runs BEFORE the gate, so a gate that takes a
    ;  reference reading takes it of the world the act has already made.
    ld a,(tut_fresh)
    or a
    call nz,tut_act

    call tut_gate

    ;  Spent whether the gate used it or not, so a gate that does not need a
    ;  reference does not have to remember to clear it.
    push af
    xor a
    ld (tut_fresh),a
    pop af
    ret nc

    ;  ...and on. The chime is the feedback: the line changes and the counter
    ;  moves, but a player looking at their fleet rather than at the strip
    ;  would miss both.
    ld hl,tut_step
    inc (hl)
    ld a,1
    ld (tut_fresh),a
    xor a
    ld (tut_flags),a
    ld a,2
    ld (wave_dirty),a
    ld hl,snd_fx_tut
    ld de,snd_voice_c
    jp snd_start


;  HL = the current step's row of tut_table.
;  Uses: AF, DE, HL
tut_row:
    ld a,(tut_step)
    add a,a
    add a,a                             ; TUT_STEP_SIZE
    ld l,a
    ld h,0
    ld de,tut_table
    add hl,de
    ret


;  Call this step's gate. Out: CF set if the step is satisfied.
tut_gate:
    call tut_row
    jr tut_call

;  Call this step's entry act.
tut_act:
    call tut_row
    inc hl
    inc hl

;  ...through the address at HL. There is no JP (DE), which is why both of the
;  above end up here rather than each building their own.
tut_call:
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    jp (hl)


; ============================================================================
;  The gates
; ============================================================================
;  Every one of them returns CF set when the step is satisfied, and is called
;  once a frame including the step's first. Uses: everything.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  tut_ref -- the common shape: "this byte is not what it was"
;  In : A = the current reading
;  Out: CF set if it differs from the reference; on the step's first frame it
;       BECOMES the reference and CF is clear
;  Uses: AF, HL
; ----------------------------------------------------------------------------
tut_ref:
    ld hl,tut_fresh
    bit 0,(hl)
    jr z,@tut_ref_cmp
    ld (tut_mark),a
    or a
    ret
@tut_ref_cmp:
    ld hl,tut_mark
    cp (hl)
    scf
    ret nz
    or a
    ret


; ----------------------------------------------------------------------------
;  tut_toggle -- "it happened, and then it stopped happening"
;  In : A = a flag that goes non-zero while the thing is true
;  Out: CF set once the flag has been seen set and is now clear
;  Uses: AF, HL
;
;  Three steps want exactly this and would otherwise be three copies of it:
;  the sensor view toggled and toggled back, `I` opened and closed, SPACE
;  paused and resumed. Requiring the RETURN is the point -- a tutorial that
;  advanced on the way in would leave the player on a page or in a pause with
;  a new instruction they cannot see the world of.
; ----------------------------------------------------------------------------
tut_toggle:
    or a
    jr z,@tut_tog_off
    ld hl,tut_flags
    set 0,(hl)
    or a                                ; CF clear: not yet
    ret
@tut_tog_off:
    ld a,(tut_flags)
    rra                                 ; bit 0 -> carry, which IS the answer
    ret


;  --- 1. the cursor keys orbit the camera ------------------------------------
;  A quarter turn, measured as a CIRCULAR distance: yaw is 256ths of a turn and
;  wraps, so a plain subtract would call 250 and 6 a long way apart.
tut_g_look:
    ld a,(cam_yaw)
    ld hl,tut_fresh
    bit 0,(hl)
    jr z,@tut_look_cmp
    ld (tut_mark),a
    or a
    ret
@tut_look_cmp:
    ld hl,tut_mark
    sub (hl)
    bit 7,a
    jr z,@tut_look_far
    neg
@tut_look_far:
    cp TUT_YAW_TURN
    ccf                                 ; CP sets CF when BELOW; we want above
    ret


;  --- 2. Z and X zoom, and the step has to move BOTH ways ---------------------
;  Both, because zooming one way and stopping teaches half of it -- and the
;  game opens on step 5 of twelve, so both directions are always available.
tut_g_zoom:
    ld a,(cam_zoom)
    ld hl,tut_fresh
    bit 0,(hl)
    jr z,@tut_zoom_cmp
    ld (tut_mark),a
    or a
    ret
@tut_zoom_cmp:
    ld hl,tut_mark
    cp (hl)
    jr z,@tut_zoom_test
    ld a,TUT_F_B                        ; a larger step number: zoomed OUT
    jr nc,@tut_zoom_latch
    ld a,TUT_F_A                        ; ...and a smaller one: zoomed IN
@tut_zoom_latch:
    ld hl,tut_flags
    or (hl)
    ld (hl),a
@tut_zoom_test:
    ld a,(tut_flags)
    and TUT_F_A + TUT_F_B
    cp TUT_F_A + TUT_F_B
    scf
    ret z
    or a
    ret


;  --- 3. P pans, and 0 brings the view back ----------------------------------
;  order_centre is the ONLY thing that zeroes cam_pan, and it is what `0` and
;  the menu's CENTRE ON BASE both call -- so "panned away, then home again" is
;  exactly this and needs no key to be watched. Pressing `0` without having
;  panned first leaves the latch clear and the step where it was.
tut_g_pan:
    ld hl,cam_pan
    ld b,6
    xor a
@tut_pan_or:
    or (hl)
    inc hl
    djnz @tut_pan_or
    or a
    jr z,@tut_pan_home

    ld hl,tut_flags
    set 0,(hl)
    or a
    ret

@tut_pan_home:
    ld a,(tut_flags)
    bit 0,a
    jr z,@tut_pan_no
    ld a,(sel_mothership)
    or a
    jr z,@tut_pan_no
    scf
    ret
@tut_pan_no:
    or a
    ret


;  --- 4. S is the sensor view ------------------------------------------------
tut_g_view:
    ld a,(view_sensors)
    jp tut_toggle


;  --- 5. 1 to 9 select a squadron --------------------------------------------
;  THE TUTORIAL'S FLEET IS TWO SQUADRONS FROM THE FIRST FRAME, and it has to
;  be: squad_select refuses a squadron with no ships in it, so on a one-
;  squadron fleet -- which is what the campaign starts with and what
;  improvements.md's Act 2 asked for -- this step could not be satisfied at
;  all until `d` had been taught four steps later. See tut_fleet.
tut_g_squad:
    ld a,(squad_sel)
    jp tut_ref


;  --- 6. I says what the squadron is made of ---------------------------------
tut_g_info:
    ld a,(info_shown)
    jp tut_toggle


;  --- 7. ENTER opens the move disc, the arrows drive it, ENTER confirms ------
;  The gate is that the STATION MOVED, which is what confirming does and what
;  cancelling does not -- so ESC out of the disc correctly leaves the step
;  standing. That is the whole reason it is not "disc_active went 1 then 0".
;
;  improvements.md wanted the ships to have ARRIVED as well. They are not
;  waited for: PHASE4_STEP is 150 world units a frame and DISC_LIMIT is 30000,
;  so a player who drove the disc to the edge of the map would watch a
;  formation fly for three minutes with one line of text on the screen. The
;  order being issued is the thing being taught; the flight is visible either
;  way, and the next step does not hide it.
tut_g_move:
    ld a,(tut_fresh)
    or a
    jr z,@tut_move_run
    call order_dest_addr
    ld de,tut_ref6
    ld bc,6
    ldir
    or a
    ret

@tut_move_run:
    ld a,(disc_active)
    or a
    jr z,@tut_move_shut
    ld hl,tut_flags
    set 0,(hl)
    or a
    ret

@tut_move_shut:
    ld a,(tut_flags)
    bit 0,a
    jr z,@tut_move_no
    call order_dest_addr
    ld de,tut_ref6
    ld b,6
@tut_move_cmp:
    ld a,(de)
    cp (hl)
    jr nz,@tut_move_yes
    inc hl
    inc de
    djnz @tut_move_cmp
@tut_move_no:
    or a
    ret
@tut_move_yes:
    scf
    ret


;  --- 8. F cycles the formation ----------------------------------------------
tut_g_form:
    ld a,(squad_sel)
    ld l,a
    ld h,0
    ld de,squad_form
    add hl,de
    ld a,(hl)
    jp tut_ref


;  --- 9. d divides and c combines --------------------------------------------
;  Counted rather than watched, because the fleet already HAS two squadrons and
;  "two, then one" is therefore not what happens. What happens is that the
;  number of squadrons with ships in them goes up and then comes back to what
;  it was, which is true whatever the fleet was carved into first.
tut_g_split:
    call tut_squads
    ld hl,tut_fresh
    bit 0,(hl)
    jr z,@tut_split_cmp
    ld (tut_mark),a
    or a
    ret
@tut_split_cmp:
    ld hl,tut_mark
    cp (hl)
    jr z,@tut_split_test
    jr c,@tut_split_test                ; fewer than we began with: not it
    ld hl,tut_flags
    set 0,(hl)
    or a
    ret
@tut_split_test:
    ld a,(tut_flags)
    rra
    ret


;  A = how many squadrons have ships in them. squad_count is derived, so this
;  is the same reading squad_refresh has just taken.
;  Uses: AF, BC, HL
tut_squads:
    ld hl,squad_count + 1
    ld b,SQUAD_MAX
    ld c,0
@tut_sq_one:
    ld a,(hl)
    or a
    jr z,@tut_sq_next
    inc c
@tut_sq_next:
    inc hl
    djnz @tut_sq_one
    ld a,c
    ret


;  --- 10. R stations the squadron on the Mothership --------------------------
;  order_dock is the only thing in the game that makes a squadron's station
;  equal to the Mothership's position exactly, so the equality IS the order.
;  It cannot already be true here: step 7 has just required that station to be
;  moved, and it was never the origin to begin with.
tut_g_dock:
    call order_dest_addr
    push hl
    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0 -- and it eats DE
    pop de
    ld b,6
@tut_dock_cmp:
    ld a,(de)
    cp (hl)
    jr nz,@tut_dock_no
    inc hl
    inc de
    djnz @tut_dock_cmp
    scf
    ret
@tut_dock_no:
    or a
    ret


;  --- 11. H sends the harvesters to work -------------------------------------
;  RU going UP, which is the whole loop rather than the keypress: fly out, fill
;  a hold, fly back, and be paid at the Mothership. About nine seconds at the
;  distances tut_patches uses.
tut_g_mine:
    ld hl,(eco_ru)
    ld a,(tut_fresh)
    or a
    jr z,@tut_mine_cmp
    ld (tut_mark),hl
    or a
    ret
@tut_mine_cmp:
    ld de,(tut_mark)
    or a
    sbc hl,de
    jr c,@tut_mine_no
    jr z,@tut_mine_no
    scf
    ret
@tut_mine_no:
    or a
    ret


;  --- 12. B opens the yard, ENTER buys ---------------------------------------
;  The panel has to have been OPENED during this step and SHUT again, and there
;  has to be an order outstanding. Shutting it is not decoration: `,` and `.`
;  belong to the panel while it is up and to the target list while it is down,
;  which is the confusion the context bar exists to end -- and step 13 is about
;  the second of those two meanings.
tut_g_build:
    ld a,(eco_build_open)
    or a
    jr z,@tut_build_shut
    ld hl,tut_flags
    set 0,(hl)
    or a
    ret

@tut_build_shut:
    ld a,(tut_flags)
    bit 0,a
    jr z,@tut_build_no
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr c,@tut_build_yes                 ; something is on the slipway
    ld a,(eco_queue_len)
    or a
    jr nz,@tut_build_yes
@tut_build_no:
    or a
    ret
@tut_build_yes:
    scf
    ret


;  --- 13. , and . step the target --------------------------------------------
;  order_target_step is the only writer of order_target, so a change is the
;  keypress and nothing else -- and with the build panel still open those keys
;  pick a class instead, which is exactly what this step is teaching apart.
tut_g_target:
    ld a,(order_target)
    jp tut_ref


;  --- 14. A attacks, and spends itself ---------------------------------------
;  Two halves, and both are needed. "The hostile is gone" on its own passes for
;  a fleet that shot it down without an order ever being given -- the ships
;  acquire and fire by themselves once it is in range. "An attack order was
;  given" on its own is the keypress, which teaches nothing. Together they are
;  the sentence: you pointed the squadron at it, and it is gone.
;
;  THE KEY IS WATCHED AS WELL AS THE ORDER, AND THAT IS A STALL FIX RATHER THAN
;  BELT AND BRACES. An attack order SPENDS ITSELF the moment cbt_fire_if_able
;  re-acquires and finds nothing left to shoot at -- which, when the hostile is
;  already dead, is inside the very frame `A` was pressed in: order_update sets
;  ENT_ORDER_ATTACK and cbt_update clears it again, both after this routine has
;  run and both before it runs next. So the fleet scan alone can NEVER see it.
;  Four interceptors kill a 200-hull hostile in about three seconds of contact,
;  so a player slow to press `A` would have been stuck on this step for good.
;
;  key_hit is not destructive and tut_update runs immediately after
;  key_consume, so this reads the same edge phase4_commands is about to act on.
tut_g_fight:
    ld a,KEY_A
    call key_hit
    jr c,@tut_fight_seen
    call tut_attacking
    jr nc,@tut_fight_left
@tut_fight_seen:
    ld hl,tut_flags
    set 0,(hl)
@tut_fight_left:
    ld a,(tut_flags)
    bit 0,a
    jr z,@tut_fight_no
    call mis_count_enemies
    or a
    jr nz,@tut_fight_no
    scf
    ret
@tut_fight_no:
    or a
    ret


;  CF set if anything in the FLEET is under an attack order.
;  Uses: everything
;
;  The pointer walks the ENT_FLAGS byte and steps by ENT_SIZE, the way
;  wave_health and ent_room_ours do, and reaches ENT_ORDER with two INCs
;  rather than an `ld bc,offset` -- BC cannot be spared, because B is the loop
;  counter. src/main.asm asserts the two fields are that far apart.
tut_attacking:
    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_PLAYER_MAX
@tut_atk_one:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@tut_atk_next                 ; empty, or theirs
    push hl
    inc hl
    inc hl                              ; ENT_ORDER, two bytes past the flags
    ld a,(hl)
    pop hl
    cp ENT_ORDER_ATTACK
    jr nz,@tut_atk_next
    scf
    ret
@tut_atk_next:
    add hl,de                           ; ...which writes the carry, so the
    djnz @tut_atk_one                   ; OR below is not optional
    or a
    ret


;  --- 15. SPACE is the tactical pause ----------------------------------------
;  Taught HERE and not in Act 1, deliberately: a pause means nothing until
;  there is something to pause.
tut_g_pause:
    ld a,(order_paused)
    jp tut_toggle


;  --- 16. J leaves ------------------------------------------------------------
;  Terminal. `J` does not come through here at all -- it comes through
;  tut_jump, which is where mis_jump's first instruction sends it.
tut_g_never:
    or a
    ret


; ============================================================================
;  The entry acts
; ============================================================================
tut_a_none:
    ret


;  ONE hostile, alone and no tougher than ours, arriving as Act 4 opens. It is
;  THEIRS by index -- ent_find_free_theirs, slot ENT_PLAYER_MAX up -- because
;  the entity table is partitioned and a spawn has to say which side it is on.
;  Uses: everything
tut_a_enemy:
    call ent_find_free_theirs
    ret nc
    call ent_addr
    push hl
    ex de,hl
    ld hl,tut_enemy_pos
    ld bc,6
    ldir
    pop hl
    push hl
    call mis_make_enemy

    ;  ...and then softer than mis_make_enemy's 200, which is the picket's hull
    ;  and is what four interceptors take the best part of a minute to grind
    ;  down. improvements.md asks for one hostile "no tougher than ours", and
    ;  the number that matters is not how long it survives but how long it
    ;  SHOOTS: at 200 it took two ships out of the tutorial's own six before it
    ;  died, which is a lesson in losing rather than in attacking. 120 is
    ;  WAVE_HULL_MIN, it is under half an interceptor's, and it still takes
    ;  about thirty game frames to close -- which is the room the player needs
    ;  to press `A` while it is alive.
    pop hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),TUT_ENEMY_HULL
    ret


;  The last step. mis_leave_ok is what the HUD reads to put JUMP up in ink 3,
;  so the key the player is about to be told about announces itself in exactly
;  the place a real mission announces it.
;
;  BOTH BYTES, and the tutorial is the one place they have to be written by
;  hand. mis_gate computes mis_leave_ok every frame from three things -- the
;  objective, three waves, and an empty board -- and the tutorial skips
;  mis_update entirely, so nothing here would ever set it. The stage has no
;  waves and never will; the rule it is teaching is which KEY leaves, not what
;  a real mission charges for leaving.
tut_a_ready:
    ld a,1
    ld (mis_complete),a
    ld (mis_leave_ok),a
    ret


; ============================================================================
;  The stage
; ============================================================================

; ----------------------------------------------------------------------------
;  tut_stations -- squadrons 1 and 2, either side of the Mothership
;
;  order_init has just seeded all nine out of order_home, which fans them up to
;  six thousand units apart -- fine for a restored campaign and much too far
;  for two squadrons the player is meant to see at once.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_stations:
    ld hl,tut_home
    ld de,squad_dest
    ld bc,2 * 6
    ldir
    ret


; ----------------------------------------------------------------------------
;  tut_patches -- two resource fields, close enough to be worth mining
;  Uses: everything
;
;  All four slots are written, the two unused ones with zeroes: a patch with no
;  stock is not drawn and is not mined, which is how mis_setup disposes of the
;  same question.
; ----------------------------------------------------------------------------
tut_patches:
    ld hl,tut_patch_data
    ld de,eco_patches
    ld bc,ECO_PATCH_COUNT * ECO_PATCH_SIZE
    ldir
    ret


; ----------------------------------------------------------------------------
;  tut_spawn -- the tutorial's fleet
;
;  Small on purpose: improvements.md asks for "few enough that a formation
;  reads". The Mothership takes slot 0 and moth_slot follows it, because half
;  the game reads that byte and a stale one is the bug CLAUDE.md records
;  against fleet_restore.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_spawn:
    call ent_clear_all

    xor a
    ld (moth_slot),a
    call ent_addr                       ; slot 0, and ent_clear_all left it at
    ld de,phase4_moth_fields            ; the origin, which is where it belongs
    call phase4_set_fields

    ld hl,tut_fleet
    ld (tut_ptr),hl
    ld a,1
    ld (tut_slot),a

@tut_ship:
    ld hl,(tut_ptr)
    ld a,(hl)
    ld (tut_class),a
    inc hl
    ld a,(hl)
    ld (tut_squad),a
    inc hl
    ld (tut_ptr),hl

    ;  It starts on its squadron's station and flies out into the formation,
    ;  exactly as phase4_spawn_fleet's does.
    ld a,(tut_squad)
    dec a
    call phase4_times6
    ld de,squad_dest
    add hl,de
    ld (tut_src),hl

    ld a,(tut_slot)
    call ent_addr
    push hl
    ex de,hl
    ld hl,(tut_src)
    ld bc,6
    ldir
    pop hl

    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE
    pop hl
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(tut_class)
    ld (hl),a
    pop hl
    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld a,(tut_squad)
    ld (hl),a
    pop hl
    ld de,ENT_HULL
    add hl,de
    ld a,(tut_class)
    ld c,a
    ld b,0
    push hl
    ld hl,class_hull
    add hl,bc
    ld a,(hl)
    pop hl
    ld (hl),a

    ld hl,tut_slot
    inc (hl)
    ld a,(hl)
    cp TUT_SHIPS + 1
    jr c,@tut_ship
    ret


; ============================================================================
;  The line on the screen
; ============================================================================

; ----------------------------------------------------------------------------
;  tut_draw -- one frame of the instruction row
;
;  Reached from wave_draw, which hands row C over whole while the tutorial is
;  running. IT IS THE WHOLE ROW AND NOT A SHARE OF IT, and that is arithmetic
;  rather than appetite: the row is 80 BYTES, which is forty characters in a
;  font that is two bytes wide, and "HULL 100%" plus INCOMING already occupy
;  bytes 2 to 40 of it. improvements.md called the row "80 characters wide and
;  free"; it is neither.
;
;  What is given up is the fleet's hull percentage, for as long as the tutorial
;  runs. That is the right thing to give up: the tutorial's fleet is not at
;  risk -- there is one hostile in it, and mis_update is not even called, so
;  nothing can be lost -- and a number the player has no decision to make about
;  is not worth a line of instruction.
;
;  wave_dirty is row C's dirty flag whoever owns the row, which is what makes
;  the coupling with mis_wipe free: phase4_hud already sets it to 2 whenever
;  the strip is repainted, and everything that schedules a wipe marks the HUD
;  dirty. A flag of its own would have been a second thing for mis_wipe to
;  know about.
;  Uses: everything
; ----------------------------------------------------------------------------
tut_draw:
    ld hl,wave_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)                            ; once into each screen buffer

    ;  Blank the row. Nothing else writes here while the tutorial is up -- the
    ;  tactical view is clipped out at spr_clip_bottom and the other two HUD
    ;  rows are below it -- so this is the whole erase.
    ld b,0
    ld c,HUD_ROW_C_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,TXT_CHAR_H
    xor a
    call scr_fill_rect

    ld a,(tut_step)
    cp TUT_STEPS
    ret nc

    ld hl,tut_text
    call str_index                      ; the walker ctx_class_name uses
    ld b,TUT_TEXT_X
    ld c,HUD_ROW_C_Y
    call txt_draw

    ;  n/16 at the right-hand end, in ink 2. It is chrome in exactly the sense
    ;  RU and HULL are -- a caption on a value rather than the value -- and it
    ;  is here because a step that advances silently looks like a step that did
    ;  not: the text changes, but only if the player was reading it.
    ld a,PEN_BLUE
    call txt_set_pen
    ld a,(tut_step)
    inc a
    ld b,TUT_NUM_X
    ld c,HUD_ROW_C_Y
    ld d,2
    call txt_draw_num
    ld hl,tut_of_text
    ld b,TUT_OF_X
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE                      ; nothing inherits an ink
    jp txt_set_pen


; ============================================================================
;  The steps
; ============================================================================
;  A gate and an entry act apiece. src/main.asm asserts that there are
;  TUT_STEPS of them and that TUT_STEPS is the number printed on the screen.
; ----------------------------------------------------------------------------
tut_table:
    ;  --- Act 1: looking. No enemies; nothing can go wrong. -----------------
    defw tut_g_look,    tut_a_none
    defw tut_g_zoom,    tut_a_none
    defw tut_g_pan,     tut_a_none
    defw tut_g_view,    tut_a_none
    ;  --- Act 2: the fleet --------------------------------------------------
    defw tut_g_squad,   tut_a_none
    defw tut_g_info,    tut_a_none
    defw tut_g_move,    tut_a_none
    defw tut_g_form,    tut_a_none
    defw tut_g_split,   tut_a_none
    defw tut_g_dock,    tut_a_none
    ;  --- Act 3: the economy ------------------------------------------------
    defw tut_g_mine,    tut_a_none
    defw tut_g_build,   tut_a_none
    ;  --- Act 4: the fight --------------------------------------------------
    defw tut_g_target,  tut_a_enemy
    defw tut_g_fight,   tut_a_none
    defw tut_g_pause,   tut_a_none
    ;  --- Act 5: leaving ----------------------------------------------------
    defw tut_g_never,   tut_a_ready
tut_table_end:


; ============================================================================
;  The words
; ============================================================================
;  TUT_STEPS strings back to back, walked by str_index, so the order in the
;  file is the order on the screen. Every one has to fit TUT_TEXT_CHARS:
;  txt_draw clips at the SCREEN edge and says nothing, so a long line is
;  silently written over the step counter. src/main.asm has the gross check and
;  tests/test_tutorial.TestTheWords has the exact one, per string.
; ----------------------------------------------------------------------------
;  Immediately before tut_text, so main.asm can measure it.
tut_of_text:
    defb "/16",0

tut_text:
    defb "ARROW KEYS TURN THE VIEW",0
    defb "Z AND X ZOOM IN AND OUT",0
    defb "P PANS  THEN 0 COMES BACK",0
    defb "S SWITCHES TO THE SENSORS",0
    defb "PRESS 1 OR 2 TO PICK A SQUADRON",0
    defb "I SHOWS WHAT IT IS MADE OF",0
    defb "ENTER ARROWS ENTER TO MOVE IT",0
    defb "F CHANGES THE FORMATION",0
    defb "D DIVIDES IT AND C JOINS IT",0
    defb "R SENDS IT HOME TO THE BASE",0
    defb "H SENDS HARVESTERS OUT TO MINE",0
    defb "B OPENS THE YARD  ENTER BUYS",0
    defb "ESC SHUTS IT   , . PICK A TARGET",0
    defb "A ATTACKS WHAT YOU PICKED",0
    defb "SPACE STOPS THE BATTLE",0
    defb "J LEAVES WHEN THE JOB IS DONE",0
tut_text_end:


; ============================================================================
;  The stage's own data
; ============================================================================

;  Squadrons 1 and 2, either side of the Mothership at the origin. Three ships
;  in Loose is FORM_SPACING * 4 = 2200 units across, so 3000 apart is a clear
;  gap between two squadrons that are both on the screen at once.
tut_home:
    defw  -3000,  500,  -600
    defw   3000, -500,   600

;  Class and squadron. TWO SQUADRONS FROM THE FIRST FRAME -- see tut_g_squad --
;  and a harvester in EACH of them, so that `H` works whichever one the player
;  has selected by the time Act 3 comes round.
tut_fleet:
    defb CLASS_INTERCEPTOR, 1
    defb CLASS_INTERCEPTOR, 1
    defb CLASS_HARVESTER,   1
    defb CLASS_INTERCEPTOR, 2
    defb CLASS_INTERCEPTOR, 2
    defb CLASS_HARVESTER,   2
tut_fleet_end:

;  Two fields, near enough that a hold is fetched in about nine seconds, and
;  two empty slots. Eight bytes a patch: x, y, z, stock.
tut_patch_data:
    defw  -1800,   0,  2200
    defw 3000
    defw   1800,   0,  2200
    defw 3000
    defw      0,   0,     0
    defw 0
    defw      0,   0,     0
    defw 0

tut_enemy_pos:
    defw      0,   0,  TUT_ENEMY_Z

;  A short rising chime, on voice C: six steps at slow 2 is 240 ms, and the
;  period falling from 500 to 250 is about 250 Hz up to 500 Hz. RISING, which
;  is what tells it apart from snd_fx_fire and snd_fx_hit -- both of those fall
;  -- and the lowest priority there is, so nothing in a fight is interrupted by
;  a tutorial step being ticked off.
snd_fx_tut:
    defb 6, SND_PRI_HIT, #C0, 24
    defw 500, -50
    defb 2, 1


; ============================================================================
;  Scratch
; ============================================================================
;  In the bank with the code, unlike game/tutorial.asm's: nothing reads these
;  but tut_spawn, and no test has any business watching them.
tut_ptr:            defw 0
tut_src:            defw 0
tut_slot:           defb 0
tut_class:          defb 0
tut_squad:          defb 0
