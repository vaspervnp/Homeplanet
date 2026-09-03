; ============================================================================
;  game/campaignrun.asm -- running the campaign, IN BANK 4
; ============================================================================
;  Split out of game/mission.asm, which keeps the descriptor layout and the
;  state. Setting a mission up, checking whether it has been won or lost,
;  jumping, and packing the survivors into the bank between missions.
;
;  Legal here because none of it runs while another bank is paged in:
;  mis_setup and mis_jump are reached from demo_init and from a keypress,
;  mis_update from demo_update's playing path, and mis_wipe_screen from the
;  same frame before anything is blitted. game/ordercmd.asm has the argument
;  and where the space came from.
;
;  fleet_save and fleet_restore are the two that would be a bug anywhere else:
;  the block they copy IS in bank 4, so this is the only bank the window can
;  be holding while they run. They then hand it to src/sys/fdc.asm, which
;  stays in the low 16K -- lib_load reads sectors INTO the window and the
;  controller code cannot be the thing being paged out.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  mis_init -- start the campaign at mission 1
;  Uses: everything
; ----------------------------------------------------------------------------
mis_init:
    xor a
    ld (mis_index),a
    ld (mis_complete),a
    ld (mis_leave_ok),a
    ld (mis_failed),a
    ld (mis_won),a
    ld (jump_secs),a                    ; ...and no jump is being counted down
    ld (jfx_no_arrival),a               ; uninitialised bank RAM until now
    ld (mis_saved),a                    ; nothing banked yet
    ld (campaign_unlocks),a             ; ...and nothing reverse-engineered
    ld hl,0
    ld (mis_timer),hl
    ;  ...and the mark the delta is measured from, or the first frame of the
    ;  mission adds up to five seconds of somebody else's time.
    ld a,(sys_tick_50hz)
    ld (mis_tick_last),a
    jp mis_brief_open


; ----------------------------------------------------------------------------
;  mis_brief_open -- hold the mission on its briefing screen
;  Uses: AF, HL
; ----------------------------------------------------------------------------
mis_brief_open:
    ld a,1
    ld (mis_briefing),a
    ret


; ----------------------------------------------------------------------------
;  mis_brief_draw -- the static screen: name, three lines, and a prompt
;
;  Drawn into the back buffer like everything else, and drawn EVERY frame
;  rather than once -- it is a page-flipping display, so a screen painted once
;  would flicker between the briefing and whatever the other buffer holds.
;  Uses: everything
; ----------------------------------------------------------------------------
;  mis_brief_key -- ENTER dismisses the briefing
;  Uses: everything
; ----------------------------------------------------------------------------
mis_brief_key:
    ld a,KEY_ENTER
    call key_hit
    ret nc
    xor a
    ld (mis_briefing),a

    ;  The briefing paints the whole tactical area and records no dirty
    ;  rectangle for any of it, so nothing would ever erase the text -- it sat
    ;  under the battle for the rest of the mission. Wipe it explicitly, once
    ;  into each of the two buffers.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a

    ;  ...and the mission appears from behind the same line that took the last
    ;  one away -- but only if a jump is what put this briefing up. That test
    ;  is jfx_reveal_open's, because the note is left by the vanish; this
    ;  routine is the one place every briefing in the game is dismissed and it
    ;  has never had to know which door it came in by.
    jp jfx_reveal_open


; ----------------------------------------------------------------------------
;  mis_wipe_screen -- clear the back buffer after a full-screen page closes
;
;  Called for two frames, which is one per screen buffer. Cheaper and clearer
;  than making the briefing record eighty rectangles it will never look at
;  again.
;
;  ALL 200 lines, including the strip the HUD owns, and whoever schedules the
;  wipe marks the HUD dirty so it comes straight back. Wiping only as far as
;  spr_clip_bottom left the title screen's credit line -- which sits at y=186,
;  inside that strip -- on the screen for the rest of the game: the HUD does
;  not clear its strip, it draws labels onto it, so anywhere it happened not
;  to put a glyph the old pixels stayed. Two HUD redraws per screen change is
;  nothing; a permanent smear across the bottom of the game is not.
;  Uses: everything
; ----------------------------------------------------------------------------
mis_wipe_screen:
    ld hl,mis_wipe
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ld bc,#0000
    ld a,SCR_HEIGHT_PX
    ld e,a
    ld d,SCR_BYTES_PER_LINE
    xor a
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  mis_descriptor -- HL -> the current mission's descriptor
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
mis_descriptor:
    ld a,(mis_index)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; * 4
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl                           ; * 16
    add hl,de                           ; * 20 = MIS_SIZE
    ld de,mission_table
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  mis_setup -- lay out the current mission around whatever fleet survives
;
;  The player's ships are NOT rebuilt here: they are already in the entity
;  table, either freshly spawned for mission 1 or restored from the bank. Only
;  the enemy and the resources are the mission's to place.
;  Uses: everything
; ----------------------------------------------------------------------------
mis_setup:
    ;  mis_leave_ok as well, and it matters: mis_update recomputes it every
    ;  frame, but the first frame of a new mission comes after a briefing and
    ;  a screen wipe, and a stale 1 carried across from the mission just left
    ;  would offer JUMP over the top of a picket that has only just spawned.
    xor a
    ld (mis_complete),a
    ld (mis_leave_ok),a
    ld (mis_failed),a
    ld (mis_won),a
    ld (jump_secs),a                    ; the countdown that brought us here
    ld (eco_repaired),a                 ; one repair per mission
    ;  ...and the base is not left half-mended across a jump with the yard shut.
    ;  moth_fixing halts production, so a flag carried into the next mission
    ;  would quietly stop the slipway there and nothing would say why.
    ld (moth_fixing),a
    ld hl,0
    ld (mis_timer),hl
    ;  ...and the mark the delta is measured from, or the first frame of the
    ;  mission adds up to five seconds of somebody else's time.
    ld a,(sys_tick_50hz)
    ld (mis_tick_last),a

    ;  The attack-wave clock runs off mis_timer, which has just gone back to
    ;  zero, so the minute is per MISSION by construction. wave_init is
    ;  in the low 16K with the rest of the frame loop's simulation.
    call wave_init

    ;  Clear out whatever the last mission left behind. That includes every
    ;  wreck and the derelict itself, which carry ENT_F_ENEMY -- so the
    ;  derelict is PLACED afresh each mission rather than carried, and it is
    ;  placed BEFORE the picket so it takes the lowest hostile slot. That is
    ;  what makes slv_find_wreck, which returns the first hull by index and not
    ;  the nearest, send the first corvette at the derelict rather than at
    ;  whatever the fight has left lying about.
    call mis_clear_enemies
    call mis_spawn_derelict

    call mis_descriptor
    ld (mis_desc),hl

    ; --- the enemy ---------------------------------------------------------
    ld de,MIS_ENEMY_COUNT
    add hl,de
    ld a,(hl)
    ld (mis_left),a
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (mis_src),de

    ld a,(mis_left)
    or a
    jr z,@mis_no_enemies
@mis_enemy:
    ;  Theirs, and it cannot fail in practice: mis_clear_enemies has just
    ;  freed the whole hostile region, and no row of mission_table asks for
    ;  more than ENT_ENEMY_MAX. The branch stays because "place what fits" is
    ;  a better answer than walking off the end of the table if one ever does,
    ;  and tests/test_campaign.TestEveryPicketFits is what says one never will.
    call ent_find_free_theirs
    jr nc,@mis_no_enemies               ; no room: place what fits

    call ent_addr
    push hl
    ld hl,(mis_src)
    pop de
    ld bc,MIS_ENEMY_CLASS
    ldir

    ;  LDIR left HL on the seventh byte of the row, which is the class. Take it
    ;  before mis_src is advanced past it, and carry it over ent_addr on the
    ;  stack -- ent_addr's argument is A.
    ld a,(hl)
    inc hl
    ld (mis_src),hl

    push af
    ld a,(ent_index)
    call ent_addr
    pop af
    call mis_make_enemy

    ld hl,mis_left
    dec (hl)
    jr nz,@mis_enemy
@mis_no_enemies:

    ; --- the resources -----------------------------------------------------
    ld hl,(mis_desc)
    ld de,MIS_PATCH_COUNT
    add hl,de
    ld a,(hl)
    ld (mis_left),a
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)

    ld hl,eco_patches
    ld b,ECO_PATCH_COUNT * ECO_PATCH_SIZE
    xor a
@mis_wipe_patch:
    ld (hl),a
    inc hl
    djnz @mis_wipe_patch

    ld a,(mis_left)
    or a
    ret z
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; count * ECO_PATCH_SIZE
    ld c,l
    ld b,h
    ld hl,eco_patches
    ex de,hl
    ldir                                ; from the descriptor into the patches
    ret


; ----------------------------------------------------------------------------
;  mis_spawn_derelict -- the dead Vekhar frigate, if this mission has one
;  Uses: everything
;
;  A hull, not a ship: ACTIVE + ENEMY + DISABLED, which is byte for byte what
;  slv_make_wreck produces. Everything that follows is therefore already
;  written and already tested -- it does not count towards a CLEAR objective
;  (mis_count_enemies' mask), is not shot at or targeted (cbt_target_flying,
;  cbt_find_enemy), does not fire or close (cbt_update, cbt_move_enemies), is
;  not part of the fleet's hull (wave_health sums ACTIVE-and-not-ENEMY), is
;  never carried between missions (fleet_save takes the same set), and a
;  Salvage Corvette can already reach it. Not one of those is a line of code
;  here, and that is the whole argument for making the derelict a WRECK rather
;  than a new kind of entity.
;
;  The one thing it does cost is a place in slv_survey's count, so a mission
;  with a derelict still adrift allows SLV_WRECK_MAX - 1 combat wrecks rather
;  than SLV_WRECK_MAX. That is correct rather than tolerated: the cap is the
;  frame budget, and a derelict is as much of an entity as any other hull.
;
;  It is CLASS_FRIGATE and that is the mechanic, not the decoration. slv_deliver
;  reads the delivered hull's class to decide what the yard pays, and it is the
;  same byte that decides what the yard has learned.
; ----------------------------------------------------------------------------
;  ...AND THERE ARE TWO OF THEM NOW, so this is a table rather than a pair of
;  compares: a Vekhar frigate in missions 4-6 and a Vekhar DESTROYER in 9-11.
;  One row is (from, until, class, the unlock it grants), and it is the SAME
;  table slv_deliver reads to decide what the yard has learned -- so "what is
;  adrift" and "what towing it teaches" cannot come to disagree, which they
;  would the first time a third one was added to one list and not the other.
;
;  The loop does not know the ranges do not overlap; src/main.asm asserts that
;  separately, because there is one derelict_pos and two adrift at once would
;  be two hulls at the same point.
DERELICT_REC        equ 4
DERELICT_KINDS      equ 2

derelict_table:
    defb MIS_DERELICT_FROM,   MIS_DERELICT_UNTIL,   CLASS_FRIGATE,   CAMP_UNLOCK_FRIGATE
    defb MIS_DEST_WRECK_FROM, MIS_DEST_WRECK_UNTIL, CLASS_DESTROYER, CAMP_UNLOCK_DESTROYER
derelict_table_end:

mis_spawn_derelict:
    ld hl,derelict_table
    ld b,DERELICT_KINDS
@mis_derelict_kind:
    push bc
    push hl
    call mis_derelict_wanted
    pop hl
    pop bc
    jr c,@mis_derelict_place
    ld de,DERELICT_REC
    add hl,de
    djnz @mis_derelict_kind
    ret

@mis_derelict_place:
    ;  HL is the row that wants placing; its class is the third byte.
    inc hl
    inc hl
    ld a,(hl)
    push af

    ;  Theirs. mis_clear_enemies has just freed the whole hostile region, so
    ;  this cannot fail -- and if a later mission ever made it fail, the answer
    ;  is the same "place what fits" the picket takes.
    call ent_find_free_theirs
    jr c,@mis_derelict_room
    pop af
    ret
@mis_derelict_room:

    call ent_addr
    push hl
    ex de,hl
    ld hl,derelict_pos
    ld bc,6
    ldir
    pop hl

    ;  Squadron, order and target come out right for free, and the class does
    ;  now that mis_make_enemy takes one; the two fields that do not are
    ;  overwritten below.
    pop af
    call mis_make_enemy

    ld a,(ent_index)
    call ent_addr
    push hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),0                           ; it was destroyed a long time ago
    pop hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED
    ret


; ----------------------------------------------------------------------------
;  mis_derelict_wanted -- should this row's hull be adrift in this mission?
;  In : HL -> a derelict_table row
;  Out: CF set if it should be placed. HL is not preserved.
;  Uses: AF, HL
;
;  EVERY EXIT GOES THROUGH ONE OF TWO LABELS, deliberately. `cp` sets CF when
;  A is BELOW the operand, so "too early" and "place it" would otherwise both
;  leave CF set on a `ret c` -- and the Destroyer's hull would be adrift in
;  mission 1, which is a thing a range check is supposed to make impossible.
; ----------------------------------------------------------------------------
mis_derelict_wanted:
    push hl
    inc hl
    inc hl
    inc hl
    ld a,(hl)                           ; the unlock this hull grants
    ld hl,campaign_unlocks
    and (hl)
    pop hl
    jr nz,@mis_der_no                   ; learned already; there is only one

    ld a,(mis_index)
    cp (hl)                             ; from
    jr c,@mis_der_no                    ; too early for this one
    inc hl
    cp (hl)                             ; until, inclusive
    jr c,@mis_der_yes
    jr z,@mis_der_yes
@mis_der_no:
    or a                                ; CF clear: not this mission
    ret
@mis_der_yes:
    scf
    ret


; ----------------------------------------------------------------------------
;  mis_derelict_unlock -- what towing a hull of class A home teaches the yard
;  In : A = the delivered hull's class
;  Out: A = the unlock mask, 0 if that class teaches nothing.
;       CF set if there is one.
;  Uses: AF, B, DE, HL
;
;  THE SAME TABLE mis_spawn_derelict places from, and that is the point rather
;  than thrift: "there is a dead Destroyer adrift from mission 9" and "towing a
;  Destroyer hull home unlocks the Destroyer" are one fact, and two lists would
;  disagree the first time a third capital ship was added to one of them.
;
;  Keyed on the CLASS and not on "was that the derelict", which is the older
;  decision this inherits: no slot index to go stale, and it stays true the day
;  campaign.asm fields a live frigate that the fleet shoots down.
; ----------------------------------------------------------------------------
mis_derelict_unlock:
    ld hl,derelict_table + 2            ; the class byte of the first row
    ld de,DERELICT_REC
    ld b,DERELICT_KINDS
@mis_unlock_row:
    cp (hl)
    jr z,@mis_unlock_found
    add hl,de
    djnz @mis_unlock_row
    xor a                               ; CF clear too
    ret
@mis_unlock_found:
    inc hl
    ld a,(hl)
    scf
    ret
;  In : HL -> the entity, A = class
;  Uses: everything
;
;  THE HULL STAYS FLAT AT 200 whatever the class is, and that is deliberate
;  rather than unfinished. class_hull is 255 for five of the eight classes, so
;  reading it here would make almost every enemy identical anyway; what makes a
;  Vekhar frigate hard to kill is the COLUMN under it in cbt_damage_matrix, and
;  that is already true without spending a byte here. 200 is also the handicap
;  the picket has always carried against the player's 255, and keeping it flat
;  means the class column changes WHO the enemy is without quietly changing how
;  much of it there is to shoot through.
; ----------------------------------------------------------------------------
mis_make_enemy:
    ld c,a                              ; the class, until its field is reached
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE + ENT_F_ENEMY
    pop hl
    push hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),200
    pop hl
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld (hl),c
    pop hl
    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld (hl),SQUAD_NONE
    pop hl
    push hl
    ld de,ENT_TARGET
    add hl,de
    ld (hl),ENT_NO_TARGET
    pop hl
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_IDLE
    ret


; ----------------------------------------------------------------------------
;  mis_clear_enemies -- free every hostile slot
;  Uses: everything
; ----------------------------------------------------------------------------
mis_clear_enemies:
    xor a
    ld (mis_scan),a
@mis_clear:
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    jr z,@mis_clear_next
    ld (hl),0
@mis_clear_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@mis_clear
    ret


; ----------------------------------------------------------------------------
;  mis_update -- has the mission been won or lost?
;
;  Called once per game frame. Losing takes precedence: if the Mothership is
;  gone the campaign is over whatever else happened, because the whole colony
;  is aboard it (section 8).
;  Uses: everything
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  mis_update_frame -- the mission clock, the spool and the wave clock
;  Out: CF set if a jump has just opened a briefing and this frame must STOP
;  Uses: everything
;
;  A JUMP CAN HAPPEN INSIDE mis_update. The spool lives there, so when the
;  count reaches zero mis_jump_now runs from inside it: it sweeps the fleet
;  away, lays the next mission out and opens its briefing, and then returns
;  into the middle of a PLAYING frame -- which would go on to project, sort
;  and draw the mission the player has not been shown yet, over the top of the
;  black the sweep just left, with the context bar still on it.
;
;  `J` used to be read in phase4_commands, ABOVE all this, so the briefing
;  branch at the top of demo_update caught a jump on the very next frame and
;  nothing drew. Moving the jump into the clock moved it past that guard.
;  This is the guard, at the one place a jump can now arrive from.
;
;  wave_update is inside the same wrapper rather than beside it because it must
;  not run either: the mission it would be clocking is over.
; ----------------------------------------------------------------------------
mis_update_frame:
    call mis_update
    ld a,(mis_briefing)
    or a
    scf
    ret nz
    call wave_update
    or a                                ; CF clear: carry on with the frame
    ret


mis_update:
    ;  REAL TIME, not frames: how many 50 Hz ticks have gone by since the last
    ;  game frame. See the note over MIS_SURVIVE_TICKS in game/mission.asm for
    ;  why, and for why it is the DELTA rather than sys_tick_50hz itself.
    ld a,(sys_tick_50hz)
    ld hl,mis_tick_last
    ld c,(hl)
    ld (hl),a
    sub c                               ; ticks elapsed, and the wrap is right
    ld e,a
    ld d,0
    ld hl,(mis_timer)
    add hl,de
    ld (mis_timer),hl

    ;  Lost?
    ld a,(moth_slot)
    call ent_is_active
    jr c,@mis_alive
    ld a,1
    ld (mis_failed),a
    ret
@mis_alive:

    ;  EVERY FRAME, and before the exit below. Whether the jump is available
    ;  is not a property of having won -- a wave landing after the objective
    ;  was met takes it away again -- so it cannot be folded into
    ;  mis_complete, which is latched.
    call mis_gate

    ;  ...and the spool, AFTER mis_gate so it sees this frame's answer, and
    ;  before the "already won" exit below -- the countdown runs precisely in
    ;  the state that exit returns from.
    call mis_jump_tick

    ld a,(mis_complete)
    or a
    ret nz                              ; already won; waiting for the jump

    call mis_descriptor
    ld de,MIS_OBJECTIVE
    add hl,de
    ld a,(hl)

    cp MIS_OBJ_CLEAR
    jr z,@mis_check_clear
    cp MIS_OBJ_SURVIVE
    jr z,@mis_check_survive

    ;  MIS_OBJ_ARRIVE: getting here IS the objective. Explicitly, because
    ;  falling through into the survive check instead made "nothing to do"
    ;  quietly mean "wait two hundred ticks doing nothing".
    jr @mis_won

@mis_check_survive:
    ld hl,(mis_timer)
    ld de,MIS_SURVIVE_TICKS
    or a
    sbc hl,de
    ret c
    jr @mis_won

@mis_check_clear:
    call mis_count_enemies
    or a
    ret nz

@mis_won:
    ld a,1
    ld (mis_complete),a
    ret


; ----------------------------------------------------------------------------
;  mis_gate -- may the player leave right now?
;  Out: (mis_leave_ok) = 0 or 1
;  Uses: everything
;
;  Three things, and the first is the mission's own objective:
;
;      the objective is met                  (mis_complete)
;      WAVE_BEFORE_JUMP waves have come      (wave_count)
;      nothing hostile is still flying       (mis_count_hostiles)
;
;  The second and third are the rule the owner asked for: a mission cannot be
;  left before its third wave, and cannot be left with an enemy on the board.
;
;  WRECKS DO NOT COUNT AND THAT IS NOT A DETAIL. A crippled hull carries
;  ACTIVE and ENEMY and is not going anywhere, and the DERELICT is one of them
;  for the whole of missions 4 to 6 -- counting it would make those three
;  missions impossible to leave at all, which is the same trap ENT_F_WAVE and
;  ENT_F_DISABLED have each been folded into mis_count_enemies' mask to avoid.
;  Third time. See game/salvage.asm.
; ----------------------------------------------------------------------------
mis_gate:
    xor a
    ld (mis_leave_ok),a

    ld a,(mis_complete)
    or a
    ret z

    ld a,(wave_count)
    cp WAVE_BEFORE_JUMP
    ret c

    call mis_count_hostiles
    or a
    ret nz

    ;  ...and the drive has to be paid for. Asked here rather than at the key
    ;  so that the HUD's JUMP never offers what ENTER would refuse.
    ;
    ;  EXCEPT ON THE LAST ONE, where the key is LAND and not JUMP: the fleet is
    ;  not travelling anywhere, it has arrived. Charging for it would let a
    ;  player who cleared the final board be refused the ending because they
    ;  had spent the treasury on the fleet that cleared it -- which is the
    ;  worst possible moment for this game to say no.
    call mis_is_last
    jr c,@mis_gate_open
    call mis_jump_fare
    ld hl,(eco_ru)
    or a
    sbc hl,de
    ret c

@mis_gate_open:
    ld a,1
    ld (mis_leave_ok),a
    ret


; ----------------------------------------------------------------------------
;  mis_leave_word -- what the HUD's fourth field says about leaving
;  Out: HL -> the string, CF set if it names a key that works right now
;  Uses: AF, HL
;
;  Blank, JUMP, or LAND on the last mission. All three in one place because
;  they are one question, and IN BANK 4 because asking it in the low 16K cost
;  a whole page -- see the call site in src/demo/phase4.asm.
;
;  JUMP and LAND are the same four characters, which is most of why the ending
;  is a different WORD rather than a different field: the position was measured
;  for four and src/main.asm asserts the two stay equal.
; ----------------------------------------------------------------------------
mis_leave_word:
    ld hl,phase4_hud_blank + 1          ; four spaces: no way out yet
    ld a,(mis_leave_ok)
    or a
    ret z                               ; CF clear, from the OR
    ld hl,mis_word_jump
    call mis_is_last
    jr nc,@mis_word_done
    ld hl,mis_word_land
@mis_word_done:
    scf
    ret

mis_word_jump:      defb "JUMP",0
mis_word_jump_end:
mis_word_land:      defb "LAND",0
mis_word_land_end:


; ----------------------------------------------------------------------------
;  mis_is_last -- CF set if the mission being played is the final one
;  Uses: AF
;
;  One place that knows which mission the campaign ends at, read by the gate,
;  by mis_jump and by the HUD's label. Three copies of `cp MIS_COUNT - 1` would
;  be three chances for the key, the word on the screen and the fare to
;  disagree about where the ending is.
; ----------------------------------------------------------------------------
mis_is_last:
    ld a,(mis_index)
    cp MIS_COUNT - 1
    jr z,@mis_last_yes
    ;  NOT `ret nz`. CP sets CARRY when A is BELOW the operand, so every
    ;  mission before the last would return with the flag SET -- which reads as
    ;  "this is the last one". The HUD said LAND in mission 1 and mis_gate
    ;  waived the fare for the whole campaign.
    ;
    ;  This is the SECOND time in three days: mis_derelict_wanted, forty lines
    ;  up, carries a paragraph about the same trap, and it was written by me.
    ;  A routine whose answer IS the carry flag has to set the flag on every
    ;  exit deliberately; there is no such thing as falling out of one.
    or a
    ret
@mis_last_yes:
    scf
    ret


; ----------------------------------------------------------------------------
;  mis_jump_fare -- what it costs to leave the mission being played
;  Out: DE = the fare
;  Uses: AF, DE, HL
;
;  A column in campaign.asm rather than an equate, because the flat thousand it
;  replaced was almost exactly the income of a peaceful mission and the
;  campaign went bankrupt at 5. game/mission.asm carries the measurement.
; ----------------------------------------------------------------------------
mis_jump_fare:
    ld a,(mis_index)
    ld l,a
    ld h,0
    add hl,hl
    ld de,mission_fare
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ret


; ----------------------------------------------------------------------------
;  mis_count_hostiles -- everything of theirs that is still FLYING
;  Out: A = how many
;  Uses: everything
;
;  The twin of mis_count_enemies below, and the difference is one bit: this
;  one counts WAVE ships as well. That routine answers "is the mission's own
;  picket dead", which is what a CLEAR objective asks; this one answers "is
;  there an enemy on the board", which is what leaving asks.
; ----------------------------------------------------------------------------
mis_count_hostiles:
    ld hl,entities + ENT_PLAYER_MAX * ENT_SIZE + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_ENEMY_MAX
    ld c,0
@mis_hostile_one:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED
    cp ENT_F_ACTIVE + ENT_F_ENEMY
    jr nz,@mis_hostile_next
    inc c
@mis_hostile_next:
    add hl,de
    djnz @mis_hostile_one
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  mis_count_enemies -- A = how many of the MISSION'S hostiles are left alive
;  Uses: everything
; ----------------------------------------------------------------------------
;  Attack waves are excluded, and that is a design decision rather than an
;  optimisation: a CLEAR objective is the picket the mission placed, and the
;  waves are pressure to leave once it is dead. Count them and the objective
;  can never be met again, `J` is never offered, and the player is trapped in
;  the mission the waves exist to push them out of. ENT_F_WAVE is folded into
;  the mask below and costs nothing -- a wave ship's flags no longer equal
;  ACTIVE+ENEMY, so the compare rejects it.
;
;  ENT_F_DISABLED is in the mask for the SAME reason and it is the same trap.
;  A wreck is a hull the player has already destroyed; it is still in the table
;  because a Salvage Corvette has to be able to reach it, and counting it would
;  make a CLEAR mission uncompletable the moment the fleet crippled the last
;  hostile -- so `J` would never be offered and building a corvette would
;  silently trap the player in the mission. One more bit in an `and` that was
;  already there.
; ----------------------------------------------------------------------------
mis_count_enemies:
    ;  The hostile region only, which is where every hostile is by
    ;  construction -- ent_find_free_theirs and mis_setup are the only things
    ;  that place one.
    ld a,ENT_PLAYER_MAX
    ld (mis_scan),a
    xor a
    ld (mis_left),a
@mis_count:
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_WAVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE + ENT_F_ENEMY
    jr nz,@mis_count_next
    ld hl,mis_left
    inc (hl)
@mis_count_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@mis_count
    ld a,(mis_left)
    ret


; ----------------------------------------------------------------------------
;  mis_jump -- the J key: leave for the next mission
;
;  Refused unless the objective is met. Section 9 says the jump is available
;  "όταν επιτρέπεται", and this is what decides that.
;  Out: CF set if the jump happened
;  Uses: everything
; ----------------------------------------------------------------------------
mis_jump:
    ;  THE TUTORIAL'S `J` NEVER GETS PAST THIS LINE, and the check is here
    ;  rather than in order_update because there are two doors into this
    ;  routine: the key itself, and the orders menu, which INJECTS that key.
    ;  Everything below writes the campaign -- fleet_save, mis_index,
    ;  fleet_disc_save, mis_setup -- so a tutorial that reached it would
    ;  destroy a game in progress from the title screen. See game/tutorial.asm.
    ld a,(tut_active)
    or a
    jp nz,tut_jump

    ;  mis_leave_ok, not mis_complete: the objective being met is only the
    ;  first of the three things mis_gate asks. It is recomputed every frame,
    ;  so a wave that lands after the objective was met closes this again.
    ld a,(mis_leave_ok)
    or a
    jr z,@mis_no_jump

    ;  ...AND `J` DOES NOT JUMP. IT ANNOUNCES. The drive spools for ten
    ;  seconds with the battle still running, and ESC calls it off -- see
    ;  mis_jump_tick. Pressing it again while it runs does nothing rather than
    ;  restarting the count, because a key that resets its own timer is one a
    ;  panicking player can hold down for ever.
    ld a,(jump_secs)
    or a
    jr nz,@mis_no_jump                  ; already spooling
    ld a,JUMP_COUNT_SECS
    ld (jump_secs),a
    xor a
    ld (jump_ticks),a
    ld a,(sys_tick_50hz)
    ld (jump_last),a
    ;  NO SOUND HERE, and that was a mistake I made and backed out. snd_jump_out
    ;  belongs to the VANISH and its length is measured against it: thirty ticks
    ;  against a sweep whose floor is 324 emulator frames, chosen so the decay
    ;  reaches silence before fdc.asm's DI stalls the machine for the disc
    ;  write. Firing it here as well played it twice and left the wipe itself
    ;  silent. improvements.md section 8 says a tick per second would be the
    ;  obvious addition to the spool and is a separate decision; it is still
    ;  separate.
    scf
    ret

@mis_no_jump:
    or a
    ret


; ----------------------------------------------------------------------------
;  mis_jump_cancel -- ESC, or the way out closing under the countdown
;  Uses: AF
; ----------------------------------------------------------------------------
mis_jump_cancel:
    xor a
    ld (jump_secs),a
    ret


; ----------------------------------------------------------------------------
;  mis_jump_tick -- one game frame of the spool. Called from mis_update.
;  Uses: everything
;
;  IT IS IN mis_update, which is what buys two behaviours for nothing:
;  demo_update skips mis_update while order_paused, so SPACE stops the
;  countdown along with the battle -- a tactical pause that let it run would be
;  a pause that jumps you out of the mission -- and mis_gate has just been
;  re-asked this frame, so mis_leave_ok is current.
;
;  IT CANCELS ITSELF IF THE WAY OUT CLOSES. A wave landing mid-count shuts
;  mis_gate, and counting down to a refusal would spend ten seconds and then
;  say nothing. Stopping is the honest answer and the bar shows it happen.
; ----------------------------------------------------------------------------
mis_jump_tick:
    ld a,(jump_secs)
    or a
    ret z

    ld a,(mis_leave_ok)
    or a
    jr z,mis_jump_cancel                ; a wave closed the door

    ;  Ticks since the last game frame; the byte wrap is right.
    ld a,(sys_tick_50hz)
    ld hl,jump_last
    ld c,(hl)
    ld (hl),a
    sub c
    ld hl,jump_ticks
    add a,(hl)
    ld (hl),a
    cp 50
    ret c                               ; not a whole second yet
    sub 50
    ld (hl),a

    ld hl,jump_secs
    dec (hl)
    ret nz                              ; still counting

    ;  Zero. The drive goes.
    jp mis_jump_now


; ----------------------------------------------------------------------------
;  mis_jump_now -- the jump itself, once the countdown has run out
;  Uses: everything
; ----------------------------------------------------------------------------
mis_jump_now:
    ;  THE LAST MISSION LANDS INSTEAD OF JUMPING. This used to refuse -- the
    ;  campaign simply had no twenty-first row -- so a player who fought
    ;  through all twenty was left flying around a cleared board with a key
    ;  that did nothing. A journey that is computed to be over and never says
    ;  so is not an ending, which is the same thing the defeat screen was
    ;  written to fix and is now the third time this file has recorded it.
    call mis_is_last
    jr c,@mis_land

    ;  Pay for the drive. AFTER the two refusals above and before anything
    ;  else moves, so a refused jump is never charged for -- mis_gate has
    ;  already checked the treasury covers it, and nothing has run between.
    ;
    ;  It is the fare of the mission being LEFT, and the increment above went
    ;  into A rather than into mis_index -- which is not written until further
    ;  down -- so mis_jump_fare reads the right row.
    call mis_jump_fare
    ld hl,(eco_ru)
    or a
    sbc hl,de
    ld (eco_ru),hl

    ;  The wipe goes FIRST, before a single byte of state has moved, so what
    ;  the line sweeps away is the mission the player is leaving. It runs to
    ;  completion here rather than across the next few frames -- see the header
    ;  of game/jumpfx.asm -- which is what keeps this routine atomic: `J` still
    ;  means "mis_index has moved by the time you can look".
    ;
    ;  It also covers the disc write below, which spins the drive up for about
    ;  a third of a second with nothing to show for it.
    call jfx_vanish

    call fleet_save                     ; what survives starts the next one
    ld a,(mis_index)
    inc a
    ld (mis_index),a
    ;  And out to the disc, so it survives the power going off too. The
    ;  mission index is stamped in by fleet_disc_save, so it has to happen
    ;  after the increment: what is saved is where the player is going, not
    ;  the mission they have just finished.
    call fleet_disc_save
    call fleet_restore
    call mis_setup
    call mis_brief_open                 ; every mission opens on its briefing
    scf
    ret

@mis_land:
    ;  THE VANISH RUNS, and the arrival does not. jfx_vanish erases the fleet
    ;  where it stands, which is the right gesture for a fleet setting down --
    ;  and it must NOT arm the reveal, because there is no next mission to be
    ;  revealed and the flag would fire over the victory page. jfx_land is
    ;  jfx_vanish without that.
    call jfx_land

    ;  ...and that is the whole of it. mis_index is NOT advanced -- there is no
    ;  twentieth-first row -- and the save is NOT written, because over_key
    ;  erases it on the way out and writing it here would only be undone. The
    ;  campaign is finished, not suspended.
    ld a,1
    ld (mis_won),a
    scf
    ret


; ============================================================================
;  Fleet persistence (Homeplanet.md section 10: FLEET.DAT, about 1 KB)
; ============================================================================
;  The whole entity table, hostiles excluded, packed into bank 4. The record
;  is already the save format -- that is what section 7's twenty bytes are for
;  -- so this is a copy with a filter rather than a serialiser.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  fleet_save -- bank whatever is still flying
;  Uses: everything
; ----------------------------------------------------------------------------
fleet_save:
    ld hl,fleet_buffer
    ld (fleet_ptr),hl
    xor a
    ld (fleet_count),a
    ld (mis_scan),a

@fleet_store:
    ld a,(mis_scan)
    call ent_addr
    ld (fleet_src),hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@fleet_store_next             ; empty, or theirs

    ;  Thirteen bytes of twenty, in the three runs game/entity.asm describes.
    ld hl,(fleet_src)
    ld de,(fleet_ptr)
    ld bc,FLEET_REC_A_LEN
    ldir                                ; x, y, z, yaw
    inc hl
    inc hl                              ; pitch and speed: nothing reads either
    ld bc,FLEET_REC_B_LEN
    ldir                                ; class, hull, flags, squad, order
    inc hl                              ; the target: a slot index does not keep
    ldi                                 ; the hold
    ld (fleet_ptr),de
    ld hl,fleet_count
    inc (hl)

@fleet_store_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    ;  ENT_PLAYER_MAX and not ENT_MAX. The filter above already rejects
    ;  hostiles, so walking the whole table gave the same answer -- it just
    ;  walked twenty slots that cannot hold one of ours to find out.
    cp ENT_PLAYER_MAX
    jr c,@fleet_store

    ld a,1
    ld (mis_saved),a
    ret


; ----------------------------------------------------------------------------
;  fleet_restore -- put the banked fleet back into the entity table
;
;  Does nothing if nothing was ever saved, so mission 1 keeps the fleet it was
;  given rather than being emptied by a restore of nothing.
;  Uses: everything
; ----------------------------------------------------------------------------
fleet_restore:
    ld a,(mis_saved)
    or a
    ret z

    call ent_clear_all

    ld hl,fleet_buffer
    ld (fleet_ptr),hl
    ld a,(fleet_count)
    or a
    ret z
    ld (mis_left),a

    xor a
    ld (mis_scan),a
@fleet_load:
    ld a,(mis_scan)
    call ent_addr
    ex de,hl
    ld hl,(fleet_ptr)
    ld bc,FLEET_REC_A_LEN
    ldir                                ; x, y, z, yaw
    inc de
    inc de                              ; pitch and speed stay as cleared
    ld bc,FLEET_REC_B_LEN
    ldir                                ; class, hull, flags, squad, order

    ;  ENT_TARGET, and it is WRITTEN rather than left. ent_clear_all does put
    ;  ENT_NO_TARGET in every slot, so this is belt and braces -- but a zeroed
    ;  target names slot 0, which is a real ship, and this project has already
    ;  had a fleet open fire on its own Mothership over exactly that.
    ld a,ENT_NO_TARGET
    ld (de),a
    inc de
    ldi                                 ; the hold
    ld (fleet_ptr),hl

    ;  The fleet packs down as ships are lost, so the Mothership almost never
    ;  lands back in the slot it left -- after two losses it comes home to 13,
    ;  not 15. Follow it. moth_slot is what the defeat check reads, and a
    ;  stale one points at whatever the NEXT mission spawns into that slot:
    ;  an enemy interceptor, whose death then reads as losing the colony.
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    cp CLASS_MOTHERSHIP
    jr nz,@fleet_load_next
    ld a,(mis_scan)
    ld (moth_slot),a

@fleet_load_next:
    ld hl,mis_scan
    inc (hl)
    ld hl,mis_left
    dec (hl)
    jr nz,@fleet_load

    ;  Squadron counts are derived, so one recount and the HUD is right.
    jp squad_refresh
