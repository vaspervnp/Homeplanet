; ============================================================================
;  demo/phase4.asm -- Phase 4: entities, squadrons, formations
; ============================================================================
;  Homeplanet.md section 13, phase 4: "Στόλος 12 σκαφών κινείται σε σχηματισμό"
;
;  A fleet of interceptors flies in formation while the camera orbits. Every
;  ship is a real entity record (section 7) and belongs to a squadron; the
;  player carves the fleet up with the keyboard and the ships fly to their new
;  formation as they are reassigned. That flight is the point: it is what
;  makes a reassignment legible on screen rather than a number changing in the
;  HUD.
;
;  Controls
;      1-9  select a squadron (only ones with ships in them)
;      d    divide the selection in half
;      m    move one ship to the next number
;      n    move one ship to the previous number
;      c    combine the selection with the next active squadron
;
;  Each squadron has a home position, and ships take numbered slots in a
;  lattice around it. A ship's target is therefore entirely derived from
;  (squadron, slot) -- nothing is stored per ship, so reassigning a ship IS
;  giving it a new destination.
; ----------------------------------------------------------------------------

;  The starting fleet. The enemy comes from the mission table, not from here,
;  so the total on screen varies by mission -- section 6 budgets a frame for
;  24 entities and the later missions push past that.
PHASE4_SHIPS        equ 15

;  World units a ship closes on its slot each frame. Fast enough that a split
;  resolves in a couple of seconds, slow enough to read as flight.
PHASE4_STEP         equ 150

;  How many pre-rendered yaw views a sprite library holds. Section 5.1 asks
;  for eight; section 14's mitigation for "the libraries do not fit" is six,
;  and six is what tools/mkships.py renders. src/main.asm asserts that this
;  number and the art agree -- get them out of step and phase4_blit_body walks
;  off the end of a sprite block into the next tier.
PHASE4_VIEWS        equ 6

;  Screen cache per visible ship (Homeplanet.md section 7).
PHASE4_VIS_SIZE     equ 6
PHASE4_V_SX         equ 0               ; 2 bytes
PHASE4_V_SY         equ 2
PHASE4_V_Z          equ 3
PHASE4_V_VIEW       equ 4
PHASE4_V_CLASSTIER  equ 5           ; (class << 2) | tier

;  Tier descriptor, 8 bytes, indexed by the tier.
PHASE4_T_SIZE       equ 8

;  Consolidation (todo item 3). How many separate stacks the screen may hold
;  at once, and how close two ships have to be to count as one.
;
;  THE DISTANCE IS THE LABEL'S OWN SIZE, and that is not a coincidence: two
;  heads that fail this test are further apart than "+nn" is wide and eight
;  lines tall, so two counts of the same class can never be drawn over each
;  other. Getting that wrong is exactly what the first version did.
PHASE4_HEADS_MAX    equ 12
PHASE4_HEAD_SIZE    equ 4               ; index, x in bytes, y, side-and-class
PHASE4_GRP_DX       equ 3 * TXT_CHAR_W_BYTES
PHASE4_GRP_DY       equ TXT_CHAR_H

;  What makes two ships the same group: the side (bit 7) and the class. NOT
;  the tier in the low two bits -- one stack straddling a tier threshold is
;  still one stack.
PHASE4_GROUP_MASK      equ #FC

;  '+' and two digits.
PHASE4_LABEL_BYTES  equ 3 * TXT_CHAR_W_BYTES

DEMO_TICKS_PER_FRAME equ 4              ; 50 Hz / 4 = 12.5 fps

;  The tactical view stops here; the HUD owns everything below (Homeplanet.md
;  section 5.5 puts it in a 32-pixel strip at the bottom). Clipping the ships
;  out of the strip is what lets the HUD be redrawn only when it changes.
HUD_TOP             equ 168

;  ...and the context bar owns the strip ABOVE this line, by the same bargain:
;  ships are clipped out of it, so it only has to be repainted when the words
;  on it change. One 8-pixel text row and a scanline of air under it.
;
;  The playfield is 10..167 rather than 0..167. That is 158 lines of the 200,
;  and it moves the middle of the visible band from y=84 to y=89 -- CLOSER to
;  the y=100 the projection centres on, not further from it.
CTX_BAR_H           equ 10
CTX_Y               equ 1

;  HUD: two rows of five slots at the bottom of the screen.
HUD_ROW_A_Y         equ 178
HUD_ROW_B_Y         equ 188

;  ...and a THIRD row above them, which cost nothing to find. Section 5.5
;  budgets a 32-pixel strip and HUD_TOP is 168, but the two rows above are at
;  178 and 188 -- so lines 168..177 have been part of the HUD's strip and black
;  since the day it was drawn. The fleet's hull percentage lives there
;  (game/waves.asm); neither existing row had four characters to spare.
;  168 and not 169, which is what it was first and what it looked wrong at.
;  The strip's three rows want the SAME gap between them or they read as two
;  blocks rather than three lines: at 169 the gap to row A is two scanlines and
;  A to B is three, and the hull figure visibly leans on the squadron list. At
;  168 all three gaps are three. The cost is that the glyphs sit hard against
;  the last line of the playfield -- which is the line a sprite is already
;  clipped in half on, so there is nothing there to crowd.
HUD_ROW_C_Y         equ 168
HUD_HP_X            equ 2
HUD_HP_CHARS        equ 9               ; "HULL 100%"
HUD_SAY_X           equ 24

;  Below this the figure goes to ink 3. Section 2 keeps that ink for the thing
;  that wants attention, and a third of a fleet's hull is when the answer to
;  "one more wave or jump now" changes.
HUD_HP_ALARM        equ 33
HUD_X               equ 2
HUD_ENTRY_CHARS     equ 5               ; ">n:cc"
HUD_ENTRY_BYTES     equ HUD_ENTRY_CHARS * 2
HUD_PER_ROW         equ 5

;  The right-hand half of the strip: resources above, the yard below.
HUD_RU_X            equ 54          ; two bytes clear of the squadron list,
                                        ; which ends at 52; four digits then
                                        ; reach 70, where ?HELP starts
HUD_YARD_X          equ 44
HUD_MIS_X           equ 56
;  What is left of row A after the RU figure, one character clear of it.
HUD_HELP_X          equ 70

;  The semantic palette of section 2, by name.
PEN_WHITE           equ 1
PEN_BLUE            equ 2
PEN_RED             equ 3


; ----------------------------------------------------------------------------
;  demo_init
; ----------------------------------------------------------------------------
demo_init:
    ;  First, before anything can draw: the six sprite libraries that do not
    ;  fit in DISC.BIN are still on the disc. If they cannot be read -- no
    ;  drive, or the disc was taken out after RUN" -- lib_init puts the
    ;  bank-4 stand-ins back and the game carries on looking like it did
    ;  before there were eight classes.
    call lib_init
    ;  ...and fall through.


; ----------------------------------------------------------------------------
;  demo_reset -- everything demo_init does except reading the sprite libraries
;
;  Split out for the TUTORIAL, and the split IS that feature's safety argument.
;  `T` on the title screen builds a stage of its own over the top of the
;  campaign's state, and leaving it comes here -- which spawns a fresh fleet,
;  READS FLEET.DAT BACK OFF THE DISC and lays the mission out again, exactly as
;  a cold boot does. So the campaign that comes back is DERIVED rather than
;  remembered, and the only way the tutorial could damage one is by writing the
;  disc. It never does; see game/tutorial.asm.
;
;  lib_init stays above the line because it is the one thing here that is
;  expensive: it spins the drive up and reads LIB_SECTORS into each of three
;  banks, which is a second and a half, and the libraries do not change.
;  Uses: everything
; ----------------------------------------------------------------------------
demo_reset:
    xor a
    ld (phase4_drawn_a),a
    ld (phase4_drawn_b),a
    ld (demo_frames),a
    ld a,(sys_tick_50hz)
    ld (demo_tick0),a

    xor a
    ld (cam_yaw),a
    ld (cam_pitch),a
    call order_init

    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ld a,CTX_BAR_H
    ld (spr_clip_top),a
    ld a,2
    ld (phase4_hud_dirty),a

    call form_init
    call mark_init
    call cbt_init
    call eco_init
    call mis_init
    call ent_clear_all
    call phase4_spawn_fleet
    ;  Spawn the starting fleet first and THEN look for a save: a disc with
    ;  one on it sets mis_saved, and fleet_restore replaces what we just
    ;  spawned. A disc without one leaves both alone, which is how a new game
    ;  starts on mission 1 with sixteen ships.
    call fleet_disc_load
    call fleet_restore
    call mis_setup                      ; the mission places the enemy, not us
    call title_open                     ; ...but the player sees the title first
    jp squad_init


; ----------------------------------------------------------------------------
;  phase4_spawn_fleet -- fill the first PHASE4_SHIPS slots
;
;  They all start on top of the squadron-1 home and fly apart into formation,
;  which doubles as proof that the approach code works at all.
;  Uses: everything
; ----------------------------------------------------------------------------
;  demo_update -- one frame
; ----------------------------------------------------------------------------
demo_update:
    ;  The matrix itself is read by sys_irq, fifty times a second. All this
    ;  does is take the edges that have piled up since the last frame and hand
    ;  them to key_hit -- which is why a keypress shorter than a game frame is
    ;  no longer lost.
    call key_consume

    ;  The tutorial's gate check, and it is HERE rather than on the playing
    ;  path for one specific reason: step 6 is gated on the squadron breakdown
    ;  having been opened AND closed, and while info_shown is set this routine
    ;  returns four branches below without ever reaching the game. A gate called
    ;  from down there would never see the page at all. About thirty T-states
    ;  when the tutorial is not running -- a load, an OR and a RET.
    call tut_update

    ;  The title screen comes before everything, including the first mission's
    ;  briefing -- which mis_init has already opened behind it.
    ld a,(title_shown)
    or a
    jr z,@p4_check_brief
    call title_key
    call title_draw
    jr @p4_static_done

@p4_check_brief:
    ;  While the briefing is up nothing else runs: no orders, no simulation,
    ;  no battle. Section 10 wants a static screen, and static means static.
    ld a,(mis_briefing)
    or a
    jr z,@p4_check_help
    call mis_brief_key
    call phase4_select_list
    call mis_brief_draw
    jr @p4_static_done

    ;  The key list stops the world for the same reason the briefing does, and
    ;  is checked after it so a briefing is never covered by one.
@p4_check_help:
    ld a,(help_shown)
    or a
    jr z,@p4_check_info
    call help_key
    call phase4_select_list
    call help_draw
    jr @p4_static_done

    ;  The squadron breakdown, on the same terms.
@p4_check_info:
    ld a,(info_shown)
    or a
    jr z,@p4_check_menu
    call info_key
    call phase4_select_list
    call info_draw
    jr @p4_static_done

    ;  The orders menu. Choosing an entry injects that entry's key and closes,
    ;  and then we deliberately fall THROUGH into the playing path so
    ;  phase4_commands acts on it in this same frame -- key_consume replaces
    ;  key_hits wholesale at the top of every frame, so an injected edge left
    ;  for the next one would be wiped before anything read it.
@p4_check_menu:
    ld a,(menu_shown)
    or a
    jr z,@p4_playing
    call menu_key
    ld a,(menu_shown)
    or a
    jr z,@p4_playing                    ; finished with: let the order happen
    call phase4_select_list
    call menu_draw

;  Every full-screen page leaves the same way: throw this buffer's dirty list
;  away, because the page painted over all of it and pays that debt with
;  mis_wipe instead. Four copies of that used to be written out, and the fifth
;  thing to add would have gone into three of them.
;
;  THE CONTEXT BAR IS NOTICED HERE BUT NOT DRAWN, and that is not tidiness.
;  A page closes by clearing its own flag inside its `_key` routine, and the
;  frame loop then goes on to draw the page one last time in the SAME frame --
;  so by the time this runs, the context already says "playing" while the
;  screen still holds the briefing. Painting the bar there put it into
;  whichever buffer that frame owned, and the two frames of mis_wipe that
;  follow then cleared it out of the other one with ctx_dirty already spent.
;  The bar was on screen every OTHER frame for the rest of the mission.
;  Setting the flag here and leaving the paint to the first PLAYING frame gets
;  both buffers, after both wipes.
@p4_static_done:
    call phase4_rects_reset
    call ctx_changed
    jp @p4_frame_counted                ; JP: the whole playing path is between

@p4_playing:
    ;  A jump wipe owns the frame: draw the mission, mask it, run nothing.
    ;  The alternative -- an overlay with the battle live behind it -- was
    ;  written first and it is wrong for a reason that has nothing to do with
    ;  how it looks: the reveal is about two seconds long and happens seven
    ;  times a campaign, so a fleet that fights through it is a fleet that has
    ;  fought fourteen seconds the player never saw. Measured: with the freeze
    ;  taken out and nothing else changed, tools/balance.py loses TWO ships in
    ;  mission 4 where it loses none, and arrives at mission 5 with 2730 hull
    ;  against 3024. Two combat tests that assert "nobody has fired yet" also
    ;  opened their mission with six shots gone. A transition must not cost
    ;  game time.
    ld a,(jfx_mode)
    or a
    jr nz,@p4_frozen

    call phase4_commands
    call order_update

    ;  A jump taken this frame has already swept the screen away and put the
    ;  next mission's briefing up, so there is nothing here to draw. Without
    ;  this the rest of the frame lays the NEW mission out over the wipe, the
    ;  flip shows it, and the briefing covers it again one frame later -- two
    ;  hundred milliseconds of the place the player has not arrived at yet.
    ;
    ;  That flash was there before the wipe was; it was simply nobody's
    ;  business what the screen held at that instant. Four bytes.
    ld a,(mis_briefing)
    or a
    jr nz,@p4_static_done

    ;  SPACE freezes the battle but not the orders (Homeplanet.md section 9):
    ;  the player can still re-plan while everything holds station.
    ld a,(order_paused)
    or a
    jr nz,@p4_frozen
    call phase4_fly
    call cbt_update
    call eco_update

    ;  THE TUTORIAL IS NOT A MISSION. No objective to meet, no clock, and no
    ;  attack waves: mis_update would read whichever row of mission_table the
    ;  campaign is on and count the tutorial's own hostile towards its CLEAR,
    ;  and wave_update would start sending Vekhar at a player who is still being
    ;  told what the arrow keys do. The gates run from the top of this routine
    ;  instead. See game/tutorial.asm.
    ld a,(tut_active)
    or a
    jr nz,@p4_no_mission

    call mis_update
    ;  The attack-wave clock, on mis_timer's own tick and immediately after it
    ;  -- including in the sensor view below, which runs the battle at triple
    ;  speed but still advances the mission once. Three minutes is three
    ;  minutes whichever view the player is in.
    call wave_update
@p4_no_mission:
    ;  Sensors run the battle at triple speed (section 9): the view exists for
    ;  the long transits, and there is nothing to look at while they happen.
    ld a,(view_sensors)
    or a
    jr z,@p4_frozen
    call phase4_fly
    call cbt_update
    call eco_update
    call phase4_fly
    call cbt_update
    call eco_update
@p4_frozen:

    call phase4_select_list
    call phase4_erase
    call mis_wipe_screen
    call order_focus
    call cam_build_matrix
    call mark_update
    call phase4_project
    call phase4_sort
    call phase4_group
    ;  The plane and the resource fields go down before the ships, so a ship
    ;  over one hides it rather than the other way round.
    call mark_draw

    ld a,(view_sensors)
    or a
    jr z,@p4_tactical
    call phase4_draw_sensor
    jr @p4_drawn
@p4_tactical:
    call phase4_draw
@p4_drawn:
    ;  ...and the Mothership indicator on top of them, because it is a
    ;  navigation overlay and a ship must not be allowed to cover it.
    call moth_draw
    call phase4_draw_explosions
    call phase4_draw_disc
    call phase4_hud
    ;  The hull readout owns the top row of the HUD's strip and keeps its own
    ;  dirty flag, because it changes every time a shot lands and phase4_hud's
    ;  costs ninety thousand T-states to honour. See game/waves.asm.
    call wave_draw

;  ...and the context bar last of all, for the same reason the HUD is drawn
;  late: it owns its strip outright, and nothing that ran above may be allowed
;  to have the last word on it.
@p4_frame_done:
    call ctx_bar
    ;  ...and the jump wipe on top of everything, because it is the one thing
    ;  on the screen that is allowed to hide the rest of it. About fifty
    ;  T-states -- a load, a compare and a RET, through a CALL -- on every
    ;  frame that is not a transition; see game/jumpfx.asm.
    call jfx_update
@p4_frame_counted:
    ld hl,demo_frames
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  demo_wait_frame -- hold the loop to 12.5 fps
;
;  Returns immediately if the frame already overran, so the rate drops instead
;  of the picture tearing.
; ----------------------------------------------------------------------------
demo_wait_frame:
    ld a,(sys_tick_50hz)
    ld hl,demo_tick0
    sub (hl)
    cp DEMO_TICKS_PER_FRAME
    jr c,demo_wait_frame
    ld a,(sys_tick_50hz)
    ld (demo_tick0),a
    ret


; ----------------------------------------------------------------------------
;  phase4_commands -- read the keyboard and reshape the fleet
;
;  Everything here is EDGE triggered: holding `d` down must divide once, not
;  once every frame until there is nothing left to divide.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_commands:
    ;  `?` puts the key list up. Checked first and returning at once, so no
    ;  other command can act on the same frame the page opens.
    ld a,KEY_SLASH
    call key_hit
    jr nc,@p4_no_help
    call help_open
    ret
@p4_no_help:

    ;  `I` breaks the selected squadron down by class. Same shape as `?`, and
    ;  returning at once for the same reason.
    ld a,KEY_I
    call key_hit
    jr nc,@p4_no_info
    call info_open
    ret
@p4_no_info:

    ;  ESC brings up the orders -- but only when it is not already spoken for.
    ;  order_update reads it as "cancel", and cancelling the move disc or the
    ;  build panel is what the player means while either of those is open.
    ld a,KEY_ESC
    call key_hit
    jr nc,@p4_no_menu
    ld a,(disc_active)
    or a
    jr nz,@p4_no_menu
    ld a,(eco_build_open)
    or a
    jr nz,@p4_no_menu
    call menu_open
    ret
@p4_no_menu:

    ;  `P` hands the cursor keys to the camera and back.
    ld a,KEY_P
    call key_hit
    jr nc,@p4_no_pan
    call order_pan_toggle
@p4_no_pan:

    ;  Number keys. The ids are MATRIX POSITIONS, not a dense enumeration --
    ;  1 and 2 sit in row 8 while 9 and 0 are up in row 4 -- so the id for a
    ;  digit has to come out of key_digit. Walking up from KEY_1 gets you
    ;  ESC, Q, TAB, A and Z, and squadrons 3 to 9 become unreachable.
    ld c,1
@p4_number:
    ld a,c
    call key_digit
    push bc
    call key_hit
    pop bc
    jr nc,@p4_next_number
    ld a,c
    push bc
    call squad_select
    pop bc
@p4_next_number:
    inc c
    ld a,c
    cp SQUAD_MAX + 1
    jr c,@p4_number

    ld a,KEY_D
    call key_hit
    call c,squad_split

    ld a,KEY_M
    call key_hit
    call c,squad_move_next

    ld a,KEY_N
    call key_hit
    call c,squad_move_prev

    ld a,KEY_C
    call key_hit
    call c,squad_combine

    ;  One squadron per class. In bank 4 with the other things that only run
    ;  when the player presses something -- see game/staticscreens.asm.
    ld a,KEY_O
    call key_hit
    call c,squad_by_class

    ld a,KEY_F
    call key_hit
    call c,form_cycle
    ret


; ----------------------------------------------------------------------------
;  phase4_fly -- move every ship towards its formation slot
;
;  Slot numbers are handed out by walking the table in order, so a ship's slot
;  is just its ordinal within its squadron. That means reassigning any ship
;  renumbers the ones after it and the whole formation shuffles up -- which
;  looks right, and costs nothing to maintain.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_fly:
    ld hl,phase4_slot_next
    ld b,SQUAD_MAX + 1
    xor a
@p4_zero_slots:
    ld (hl),a
    inc hl
    djnz @p4_zero_slots

    ;  Stepped rather than indexed. ent_addr is a shift ladder and a call --
    ;  about 120 T-states -- and this is one of the loops that walk the entity
    ;  table every frame; twenty bytes further on is one ADD.
    ;  ...and only the player's region: this flies a ship to its SQUADRON's
    ;  station, mis_make_enemy writes SQUAD_NONE, and the loop below drops
    ;  anything unassigned anyway. Twenty slots that can never answer yes.
    ld hl,entities
    ld (phase4_ent),hl
    ld a,ENT_PLAYER_MAX
    ld (phase4_index),a
@p4_ship_fly:
    ld hl,(phase4_ent)

    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@p4_next_fly

    ;  A ship that has been sent to work has left the formation. Without
    ;  this, phase4_fly drags it back towards its slot exactly as fast as
    ;  eco_update pushes it towards the patch -- both step by PHASE4_STEP --
    ;  and the harvester sits there vibrating while the RU never moves.
    ld hl,(phase4_ent)
    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_HARVEST
    jr z,@p4_next_fly
    ;  ...and a Salvage Corvette out fetching a wreck, which is the same
    ;  journey with a different cargo -- slv_tow_step steps it by PHASE4_STEP
    ;  out of eco_update, exactly as the harvester is stepped.
    cp ENT_ORDER_TOW
    jr z,@p4_next_fly
    ;  Same again for a ship told to attack: cbt_move_enemies now closes it on
    ;  its target, and two systems stepping the same ship by PHASE4_STEP in
    ;  different directions cancel exactly.
    cp ENT_ORDER_ATTACK
    jr z,@p4_next_fly

    ld hl,(phase4_ent)
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    or a
    jr z,@p4_next_fly                   ; unassigned: the Mothership holds station
    cp SQUAD_MAX + 1
    jr nc,@p4_next_fly
    ld (phase4_squad),a

    ;  slot = phase4_slot_next[squad]++
    ld l,a
    ld h,0
    ld de,phase4_slot_next
    add hl,de
    ld a,(hl)
    inc (hl)
    ld (phase4_slotno),a

    call phase4_step_to_slot

@p4_next_fly:
    ld hl,(phase4_ent)
    ld de,ENT_SIZE
    add hl,de
    ld (phase4_ent),hl
    ld hl,phase4_index
    dec (hl)
    jr nz,@p4_ship_fly
    ret


; ----------------------------------------------------------------------------
;  phase4_step_to_slot -- close on (home[squad] + offset[slot]) by one step
;  In : (phase4_ent), (phase4_squad), (phase4_slotno)
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_step_to_slot:
    ld a,(phase4_squad)
    dec a                               ; squadrons are 1-based
    call phase4_times6
    ld de,squad_dest
    add hl,de
    ld (phase4_home_ptr),hl

    ld a,(phase4_squad)
    ld b,a
    ld a,(phase4_slotno)
    ld c,a
    call form_slot_offset               ; the squadron's own shape
    ld (phase4_off_ptr),hl

    ld hl,(phase4_ent)                  ; ENT_X is offset 0
    ld (phase4_coord_ptr),hl

    ld a,3
    ld (phase4_axis),a

@p4_axis:
    ld hl,(phase4_home_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (phase4_home_ptr),hl

    ld hl,(phase4_off_ptr)
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld (phase4_off_ptr),hl

    ld h,d
    ld l,e
    add hl,bc
    ld (phase4_tgt),hl

    ld hl,(phase4_coord_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase4_cur),de

    call phase4_approach                ; HL = the new coordinate

    ex de,hl
    ld hl,(phase4_coord_ptr)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (phase4_coord_ptr),hl

    ld hl,phase4_axis
    dec (hl)
    jr nz,@p4_axis
    ret


; ----------------------------------------------------------------------------
;  phase4_step_toward -- move a position one step towards another, per axis
;  In : HL -> the six bytes to move, DE -> the six bytes to move towards
;  Uses: everything
;
;  ONE of these. A harvester closing on a patch and a Vekhar interceptor
;  closing on its target were the same fifty instructions written out twice,
;  around a phase4_approach that was already shared -- and the two copies had
;  to stay in step over exactly the trap phase4_approach exists to avoid.
; ----------------------------------------------------------------------------
phase4_step_toward:
    ld (phase4_coord_ptr),hl
    ld (phase4_off_ptr),de
    ld a,3
    ld (phase4_axis),a
@p4_toward_axis:
    ld hl,(phase4_off_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (phase4_off_ptr),hl
    ld (phase4_tgt),de

    ld hl,(phase4_coord_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase4_cur),de

    call phase4_approach
    ex de,hl
    ld hl,(phase4_coord_ptr)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (phase4_coord_ptr),hl

    ld hl,phase4_axis
    dec (hl)
    jr nz,@p4_toward_axis
    ret


; ----------------------------------------------------------------------------
phase4_approach:
    ld hl,(phase4_tgt)
    ld de,(phase4_cur)
    or a
    sbc hl,de                           ; how far there is to go
    jp pe,@p4_far                       ; ...if that even fit. Test P/V HERE:
                                        ; the OR below overwrites it.

    ld a,h
    or l
    jr z,@p4_arrive

    bit 7,h
    jr nz,@p4_behind

    ld de,PHASE4_STEP
    or a
    sbc hl,de
    jr c,@p4_arrive                     ; less than a step away: snap
    ld hl,(phase4_cur)
    add hl,de
    ret

@p4_behind:
    ld de,PHASE4_STEP
    add hl,de                           ; distance + step
    bit 7,h
    jr z,@p4_arrive                     ; within a step of the target
    ld hl,(phase4_cur)
    or a
    sbc hl,de
    ret

@p4_arrive:
    ld hl,(phase4_tgt)
    ret

@p4_far:
    ;  Every axis of the world is 16-bit signed, so two points can be 65534
    ;  apart and `target - current` does not fit in the register that is
    ;  holding it. When SBC overflows, the sign bit LIES -- the true sign is
    ;  S XOR P/V -- and a ship at one end of the map reads a target at the
    ;  other end as being behind it and flies away from it, forever.
    ;
    ;  Nothing to check for arrival on this path: overflowing means more than
    ;  32767 away, which is a long way past one step.
    ld de,PHASE4_STEP
    bit 7,h
    jr nz,@p4_far_forward
    ld hl,(phase4_cur)
    or a
    sbc hl,de
    ret
@p4_far_forward:
    ld hl,(phase4_cur)
    add hl,de
    ret


;  HL = A * 6
;  Uses: AF, DE, HL
phase4_times6:
    ld l,a
    ld h,0
    add hl,hl                           ; *2
    ld d,h
    ld e,l
    add hl,hl                           ; *4
    add hl,de                           ; *6
    ret


; ----------------------------------------------------------------------------
;  phase4_select_list -- point at the back buffer's rectangle list
; ----------------------------------------------------------------------------
phase4_select_list:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    jr z,@p4_buffer_a
    ld hl,phase4_rects_b
    ld (phase4_rects),hl
    ld hl,phase4_drawn_b
    ld (phase4_count),hl
    ret
@p4_buffer_a:
    ld hl,phase4_rects_a
    ld (phase4_rects),hl
    ld hl,phase4_drawn_a
    ld (phase4_count),hl
    ret


; ----------------------------------------------------------------------------
;  phase4_erase -- blank every rectangle this buffer is holding
; ----------------------------------------------------------------------------
phase4_erase:
    ld hl,(phase4_count)
    ld a,(hl)
    or a
    jr nz,@p4_have_rects
    jp phase4_rects_reset
@p4_have_rects:
    ld b,a
    ld hl,(phase4_rects)
@p4_rect:
    push bc
    ld a,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld e,(hl)
    inc hl
    push hl
    ld b,a
    xor a
    call scr_fill_rect
    pop hl
    pop bc
    djnz @p4_rect

    ;  The list has been consumed; start an empty one for this frame. Miss
    ;  this and the count only ever grows -- it reached 244 in a 71-slot array
    ;  and was writing rectangles over whatever came after it.
    jp phase4_rects_reset


; ----------------------------------------------------------------------------
;  phase4_rects_reset -- start a fresh dirty list for this frame
;
;  Called once, immediately after the old list has been erased, because FOUR
;  things append to it now -- the reference plane, the ships, the explosions
;  and the move disc -- and whichever drew first used to reset the list and
;  throw the others' rectangles away.
;  Uses: AF, HL
; ----------------------------------------------------------------------------
phase4_rects_reset:
    xor a
    ld (phase4_rect_count),a
    ld hl,(phase4_rects)
    ld (phase4_rect_ptr),hl
    ld hl,(phase4_count)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase4_add_rect -- append one dirty rectangle to this buffer's list
;  In : HL -> x in bytes, y, width in bytes, height in lines
;  Uses: AF, BC, DE, HL
;
;  Six things record rectangles now -- ships, explosions, the move disc, the
;  reference plane, the resource patches and the Mothership indicator -- and
;  every one of them used to carry its own copy of these ten instructions.
;  Thirty bytes each, in a low 16K with a few hundred left.
; ----------------------------------------------------------------------------
phase4_add_rect:
    ld de,(phase4_rect_ptr)
    ld bc,4
    ldir
    ld (phase4_rect_ptr),de
    ld hl,phase4_rect_count
    inc (hl)
    ld a,(hl)
    ld hl,(phase4_count)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase4_project -- project every active entity, cache the survivors
; ----------------------------------------------------------------------------
phase4_project:
    xor a
    ld (phase4_visible),a
    ld hl,phase4_vis
    ld (phase4_vis_ptr),hl
    ld hl,entities
    ld (phase4_ent),hl
    ld a,ENT_MAX
    ld (phase4_index),a

@p4_ship_proj:
    ld hl,(phase4_ent)
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@p4_next_proj

    ld hl,(phase4_ent)                  ; ENT_X is offset 0
    call proj_point
    call c,phase4_cache                 ; test CF before anything clobbers it

@p4_next_proj:
    ld hl,(phase4_ent)
    ld de,ENT_SIZE
    add hl,de
    ld (phase4_ent),hl
    ld hl,phase4_index
    dec (hl)
    jr nz,@p4_ship_proj
    ret


; ----------------------------------------------------------------------------
;  phase4_cache -- append the projected ship to the visible list
; ----------------------------------------------------------------------------
phase4_cache:
    ld hl,(phase4_vis_ptr)

    ld de,(proj_sx)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(proj_sy)
    ld (hl),a
    inc hl
    ld a,(proj_z)
    ld (hl),a
    inc hl

    ;  View: the ship's heading as seen from the camera, in SIXTHS of a turn.
    ;
    ;  This was `rrca` five times and `and 7`, and it stopped being able to be
    ;  when section 14's mitigation took the libraries from eight views to six.
    ;  256/6 is not an integer and there is no shift that divides by six, so
    ;
    ;      view = round(diff * 6 / 256) = (diff * 6 + 128) >> 8
    ;
    ;  which is three `add hl,*` for the multiply and one for the rounding.
    ;
    ;  HAND-COUNTED, the block below goes from 121 T-states to 178: +57 per
    ;  VISIBLE entity, about 1,400 T of a 530,000 T frame, a quarter of one
    ;  percent. (The gate array puts its ~25-30% on both, so the ratio holds.)
    ;  Measured end to end against a build of the previous commit the frame
    ;  rate does not move at all, and demo_wait_frame quantising to 50 Hz ticks
    ;  means it could not have.
    ;
    ;  The obvious alternative -- a lookup table -- is what this change exists
    ;  to avoid. 256 entries is a page, which is most of what six views just
    ;  freed. 32 entries indexed by (diff >> 3) is affordable at 32 bytes and
    ;  no faster than this by the time the index has been built, and it rounds
    ;  TWICE: eight of the 256 headings come out one view away from the one
    ;  the arithmetic picks. Twelve bytes of code that is exact beats a table
    ;  that is nearly right.
    ;
    ;  ROUNDING, not truncation, and that is a repair rather than a
    ;  translation. Taking the top three bits gave the pose the ship had last
    ;  PASSED, not the nearest one -- every ship in the fleet drawn up to 45
    ;  degrees behind its heading, always in the same direction. Six views
    ;  makes that a bias of up to a whole 60-degree step, which is a fleet
    ;  visibly flying crabwise. The `+128` costs four bytes and halves it.
    push hl
    ld hl,(phase4_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    ld hl,cam_yaw
    sub (hl)                            ; A = heading relative to the camera
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; 2x
    add hl,de                           ; 3x -- at most 765, so 16 bits is ample
    add hl,hl                           ; 6x
    ld de,128
    add hl,de
    ld a,h
    cp PHASE4_VIEWS
    jr c,@p4_view_ok
    ;  Everything from 330 degrees up rounds to a full turn, which is view 0.
    xor a
@p4_view_ok:
    pop hl
    ld (hl),a
    inc hl

    ;  Size tier from depth, packed with the class: the blitter needs both to
    ;  name a sprite block, and the design gives this record six bytes.
    push hl
    ld hl,(phase4_ent)
    ld de,ENT_CLASS
    add hl,de
    ld b,(hl)                           ; B = class
    ld a,(proj_z)
    call phase4_tier_for
    call class_apply_bias               ; capital ships draw a tier larger
    ld c,a
    ld a,b
    add a,a
    add a,a
    or c
    ld c,a
    ld hl,(phase4_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    jr z,@p4_friendly
    ld a,#80                            ; bit 7 marks the other side
@p4_friendly:
    or c
    pop hl
    ld (hl),a
    inc hl

    ld (phase4_vis_ptr),hl
    ld hl,phase4_visible
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  phase4_tier_for -- A = the sprite size tier for camera depth A
;  In : A = proj_z, Z_NEAR..Z_FAR
;  Out: A = 2 (24x16), 1 (16x10) or 0 (8x6)
;  Uses: AF, C
;
;  This was a 256-byte page-aligned lookup table, and three instructions. It
;  holds three distinct values with two edges in it, so two compares are the
;  same ~20 T-states and give the low 16K a quarter of a kilobyte back -- which
;  is what the zoom ladder and the grouping pass are built out of. The
;  thresholds are still tools/gentables.py's to decide, and its tier_table()
;  is still the model tests/test_phase3.py checks this against.
; ----------------------------------------------------------------------------
phase4_tier_for:
    ld c,2
    cp TIER_C_MAX_Z
    jr c,@p4_tier_done
    dec c
    cp TIER_B_MAX_Z
    jr c,@p4_tier_done
    dec c
@p4_tier_done:
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  phase4_sort -- order the visible list back to front (Homeplanet.md 5.3)
;
;  Insertion sort over an index array, descending by depth, so the nearest
;  ship is drawn last and ends up on top. Nearly-sorted from frame to frame,
;  which is exactly where insertion sort is O(n).
;
;  AN ENTRY IS TWO BYTES -- the index, and A COPY OF ITS DEPTH beside it. That
;  is the whole of this routine's cost, and it is the reason the fleet's
;  ceiling could move at all.
;
;  It used to be one byte, and every comparison therefore went and fetched the
;  depth out of phase4_vis: `call phase4_order_at` to turn j into a pointer,
;  then `call phase4_z_of`, which calls phase4_vis_addr to multiply the index
;  by six. Hand-counted that is about 390 T-states an iteration, of which the
;  comparison itself is eight. Caching the byte beside the index makes the
;  whole inner step ~104 T -- and this is the ONLY O(n^2) thing in the frame,
;  so it is the term that decides how many ships may exist at once. Measured:
;  73,000 T-states at 24 entities before.
;
;  The cost is ENT_MAX more bytes of the low 16K, and it buys back several
;  times its own weight in slots.
; ----------------------------------------------------------------------------
phase4_sort:
    ld a,(phase4_visible)
    or a
    ret z

    ;  Every entry starts where it is, carrying its own depth.
    ld b,a
    ld hl,phase4_order
    ld de,phase4_vis + 3                ; the depth byte of visible entry 0
    xor a
@p4_fill:
    ld c,a
    ld a,(de)
    ld (hl),c                           ; the index
    inc hl
    ld (hl),a                           ; ...and its depth, cached beside it
    inc hl
    ;  Six INC DEs rather than an ADD HL,BC through the stack: BC is the loop
    ;  counter and the index, and six of these are cheaper than saving it.
    inc de
    inc de
    inc de
    inc de
    inc de
    inc de
    ld a,c
    inc a
    djnz @p4_fill

    ld a,(phase4_visible)
    cp 2
    ret c

    dec a
    ld c,a                              ; keys still to insert
    ld b,1                              ; ...and how far left this one may go
    ld hl,phase4_order + 2

@p4_outer:
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl                              ; DE = the key: E its index, D its depth
    push hl                             ; where it came from
    push bc

@p4_inner:
    dec hl                              ; the depth of the entry before the hole
    ld a,(hl)
    cp d
    jr nc,@p4_settle                    ; at least as far away: the key sits here

    ;  It is nearer than the key, so it moves up into the hole and the hole
    ;  becomes the slot it left.
    ld c,a
    dec hl
    ld a,(hl)
    inc hl
    inc hl
    ld (hl),a
    inc hl
    ld (hl),c
    dec hl
    dec hl
    dec hl
    djnz @p4_inner
    jr @p4_store                        ; ran out of list: the hole is the front

@p4_settle:
    inc hl
@p4_store:
    ld (hl),e
    inc hl
    ld (hl),d

    pop bc
    pop hl
    inc hl
    inc hl                              ; the next key...
    inc b                               ; ...with one more entry to its left
    dec c
    jr nz,@p4_outer
    ret


;  HL = &phase4_order[A]. Two bytes an entry, so the index doubles.
phase4_order_at:
    ld l,a
    ld h,0
    add hl,hl
    ld de,phase4_order
    add hl,de
    ret

;  HL = &phase4_vis[A]
phase4_vis_addr:
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; *2
    add hl,de                           ; *3
    add hl,hl                           ; *6
    ld de,phase4_vis
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  phase4_group -- collapse stacks of the same class into one sprite and a count
;
;  Zooming out far enough to see the whole battle puts a dozen ships inside one
;  8x6 sprite, and a dozen ships drawn on top of each other look exactly like
;  one ship. So above CAM_ZOOM_GROUP_FROM the entities are gathered by screen
;  proximity and each gathering draws once, with "+n" beside it.
;
;  A SHORT LIST OF HEADS, not every pair, and not a screen-space grid either.
;  A grid was written first and looks cheaper -- one map read per entity
;  against a scan -- but it puts a seam every 32 pixels, and a fleet sitting
;  across one comes out as two groups eight pixels apart whose two labels
;  overlap into "++7". Screenshots of it are what killed it.
;
;  So the test is real proximity, against the groups found so far. The
;  threshold IS THE LABEL'S OWN SIZE: two heads that survive it are further
;  apart than "+nn" is wide, so no two labels of one class can ever collide.
;  PHASE4_HEADS_MAX bounds the scan, so the cost is O(n) with a small constant
;  rather than the O(n^2) that phase4_sort already spends 73,000 T-states on;
;  past that many distinct stacks there is nothing left to consolidate anyway.
;
;  The order is walked from the NEAR end, so the entry that keeps its sprite is
;  the nearest of its group -- the largest tier, and the one the painter's
;  algorithm would have left on top.
;
;  Friendly and enemy are never one group: section 2's palette makes white and
;  red mean different things and a count in one ink cannot speak for both.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_group:
    ld a,(phase4_visible)
    or a
    ret z

    ;  Everything draws itself once until something says otherwise.
    ld b,a
    ld hl,phase4_gcount
@p4_grp_init:
    ld (hl),1
    inc hl
    djnz @p4_grp_init

    ;  Only the steps the zoom ladder ADDED consolidate. At the four that were
    ;  always there the picture is byte for byte what it was.
    ld a,(cam_zoom)
    cp CAM_ZOOM_GROUP_FROM
    ret c
    ld a,(view_sensors)
    or a
    ret nz                              ; sensors already draw one dot each

    xor a
    ld (phase4_nheads),a
    ld a,(phase4_visible)
    ld (phase4_grp_left),a
    ld l,a
    ld h,0
    add hl,hl                           ; two bytes an entry: index, then depth
    ld de,phase4_order - 2
    add hl,de
    ld (phase4_grp_ptr),hl              ; the last entry: the nearest ship

@p4_grp_one:
    ld hl,(phase4_grp_ptr)
    ld a,(hl)
    dec hl
    dec hl
    ld (phase4_grp_ptr),hl
    ld (phase4_grp_i),a

    call phase4_head_of
    jr nc,@p4_grp_next                  ; under the HUD: it draws nothing anyway
    call phase4_find_head
    jr nc,@p4_grp_new

    ;  HL -> the head it belongs to. One more behind that sprite, and this
    ;  entry is not drawn at all.
    ld a,(hl)
    ld de,phase4_gcount
    ld l,a
    ld h,0
    add hl,de
    inc (hl)
    ld a,(phase4_grp_i)
    ld l,a
    ld h,0
    add hl,de
    ld (hl),0
    jr @p4_grp_next

@p4_grp_new:
    ld a,(phase4_nheads)
    cp PHASE4_HEADS_MAX
    jr nc,@p4_grp_next                  ; the list is full; it draws itself
    inc a
    ld (phase4_nheads),a
    dec a
    add a,a
    add a,a                             ; PHASE4_HEAD_SIZE apiece
    ld l,a
    ld h,0
    ld de,phase4_heads
    add hl,de
    ld a,(phase4_grp_i)
    ld (hl),a
    inc hl
    ld a,(phase4_grp_x)
    ld (hl),a
    inc hl
    ld a,(phase4_grp_y)
    ld (hl),a
    inc hl
    ld a,(phase4_grp_key)
    ld (hl),a

@p4_grp_next:
    ld hl,phase4_grp_left
    dec (hl)
    jr nz,@p4_grp_one
    ret


; ----------------------------------------------------------------------------
;  phase4_head_of -- where visible entry A is, in the terms grouping compares
;  In : A = an index into phase4_vis
;  Out: CF set -> (phase4_grp_x) x in BYTES, (phase4_grp_y) y, (phase4_grp_key)
;       CF clear -> it is under the HUD and draws nothing
;  Uses: everything
;
;  x in bytes rather than pixels so the compare is eight bits: 320 does not fit
;  a byte, and taking only the low half of sx is the bug this file has already
;  made twice elsewhere.
; ----------------------------------------------------------------------------
phase4_head_of:
    call phase4_vis_addr
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = sx, 0..319
    inc hl
    ld a,(hl)
    cp HUD_TOP
    ret nc                              ; CF clear: spr_clip_bottom owns it
    ld (phase4_grp_y),a
    inc hl
    inc hl
    inc hl
    ld a,(hl)
    and PHASE4_GROUP_MASK               ; side and class; the tier is not identity
    ld (phase4_grp_key),a

    ex de,hl
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (phase4_grp_x),a
    scf
    ret


; ----------------------------------------------------------------------------
;  phase4_find_head -- which group, if any, the pending entry joins
;  In : (phase4_grp_x), (phase4_grp_y), (phase4_grp_key)
;  Out: CF set -> HL -> the head record; CF clear -> it starts its own
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_find_head:
    ld a,(phase4_nheads)
    or a
    ret z                               ; CF is clear: OR A saw to that
    ld b,a
    ld hl,phase4_heads

@p4_head_try:
    push bc
    push hl
    inc hl
    ld a,(phase4_grp_x)
    sub (hl)
    jr nc,@p4_head_dx
    neg
@p4_head_dx:
    cp PHASE4_GRP_DX + 1
    jr nc,@p4_head_no

    inc hl
    ld a,(phase4_grp_y)
    sub (hl)
    jr nc,@p4_head_dy
    neg
@p4_head_dy:
    cp PHASE4_GRP_DY + 1
    jr nc,@p4_head_no

    inc hl
    ld a,(phase4_grp_key)
    cp (hl)
    jr nz,@p4_head_no
    pop hl
    pop bc
    scf
    ret

@p4_head_no:
    pop hl
    ld de,PHASE4_HEAD_SIZE
    add hl,de
    pop bc
    djnz @p4_head_try
    or a
    ret


; ----------------------------------------------------------------------------
;  phase4_draw -- blit the visible ships, far to near
; ----------------------------------------------------------------------------
phase4_draw:
    ld a,(phase4_visible)
    or a
    jr z,@p4_done
    ld (phase4_remaining),a
    xor a
    ld (phase4_order_idx),a

@p4_one:
    ld a,(phase4_order_idx)
    ld l,a
    ld h,0
    add hl,hl                           ; two bytes an entry: index, then depth
    ld de,phase4_order
    add hl,de
    ld a,(hl)
    ld (phase4_grp_i),a

    ld l,a
    ld h,0
    ld de,phase4_gcount
    add hl,de
    ld a,(hl)
    or a
    jr z,@p4_next_draw                  ; consolidated: something nearer stands in
    ld (phase4_grp_n),a

    ld a,(phase4_rect_count)
    ld (phase4_grp_rects),a
    ld a,(phase4_grp_i)
    call phase4_vis_addr
    call phase4_blit_one

    ld a,(phase4_grp_n)
    dec a
    jr z,@p4_next_draw                  ; standing for nobody but itself
    ;  The label widens the sprite's dirty rectangle, so there has to BE one:
    ;  a sprite clipped away entirely wrote nothing, and a count floating
    ;  beside a ship that is not on screen would never be erased either.
    ld a,(phase4_rect_count)
    ld hl,phase4_grp_rects
    cp (hl)
    call nz,phase4_draw_count

@p4_next_draw:
    ld hl,phase4_order_idx
    inc (hl)
    ld hl,phase4_remaining
    dec (hl)
    jr nz,@p4_one

@p4_done:
    ld hl,(phase4_count)
    ld a,(phase4_rect_count)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase4_draw_count -- "+n" beside a consolidated stack
;  In : (phase4_grp_i) = the visible entry that kept its sprite
;       (phase4_grp_n) = how many ships that sprite is standing for
;  Uses: everything
;
;  The count is the WHOLE group, not the hidden remainder: what the player
;  wants off a wide view is how many ships are there, and "+3" beside three
;  ships reads as three.
;
;  It must be covered by a dirty rectangle, which is not optional -- the
;  briefing and the help page both learned that the hard way. Rather than
;  taking a slot of its own it WIDENS the one the blit just wrote, which is
;  free: erasing the gap between ship and label costs a few bytes of fill and
;  a slot per entity in two buffers costs 384 of a low 16K with none to give.
; ----------------------------------------------------------------------------
phase4_draw_count:
    ld a,(phase4_grp_i)
    call phase4_vis_addr
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = sx
    inc hl
    ld a,(hl)
    ld (phase4_grp_y),a
    inc hl
    inc hl
    inc hl
    ld a,(hl)
    ld (phase4_grp_side),a              ; the side is bit 7

    ;  Beside the ship rather than on it: three bytes right of centre clears
    ;  tier B outright and all but a pixel of tier C.
    ex de,hl
    srl h
    rr l
    srl h
    rr l                                ; HL = sx in bytes
    ld a,l
    add a,3
    cp SCR_BYTES_PER_LINE - PHASE4_LABEL_BYTES + 1
    ret nc                              ; no room before the right edge
    ld (phase4_grp_x),a

    ;  ...and half a glyph up, so it sits across the middle of the ship. Out
    ;  of the HUD's strip, which owns everything below HUD_TOP.
    ld a,(phase4_grp_y)
    sub TXT_CHAR_H / 2
    ret c
    cp HUD_TOP - TXT_CHAR_H + 1
    ret nc
    ;  ...and out of the context bar's strip at the other end. txt_draw has no
    ;  vertical clip at all -- it clips at the right-hand edge and nowhere else
    ;  -- so this is the only thing standing between a stack of ships near the
    ;  top of the view and a "+12" written across the bar.
    ld hl,spr_clip_top
    cp (hl)
    ret c
    ld (phase4_grp_y),a

    ;  One digit or two, and no leading space: txt_draw_num pads its field on
    ;  the left, so a fixed width of 2 would draw "+ 3".
    ld a,(phase4_grp_n)
    ld d,1
    cp 10
    jr c,@p4_cnt_width
    inc d
@p4_cnt_width:
    ld a,d
    ld (phase4_grp_d),a
    add a,a
    add a,TXT_CHAR_W_BYTES              ; the '+' as well
    ld (phase4_grp_w),a

    ;  Section 2's palette: a red count belongs to the red ships.
    ld a,(phase4_grp_side)
    and #80
    ld a,PEN_WHITE
    jr z,@p4_cnt_pen
    ld a,PEN_RED
@p4_cnt_pen:
    call txt_set_pen

    ld hl,phase4_grp_plus
    ld a,(phase4_grp_x)
    ld b,a
    ld a,(phase4_grp_y)
    ld c,a
    call txt_draw

    ld a,(phase4_grp_d)
    ld d,a
    ld a,(phase4_grp_x)
    add a,TXT_CHAR_W_BYTES
    ld b,a
    ld a,(phase4_grp_y)
    ld c,a
    ld a,(phase4_grp_n)
    call txt_draw_num

    ld a,PEN_WHITE                      ; nothing inherits an ink
    call txt_set_pen

    ;  The rectangle the blit wrote is the four bytes behind the write pointer.
    ld hl,(phase4_rect_ptr)
    ld de,-4
    add hl,de
    ld (phase4_grp_r),hl

    ;  Its left edge stands: the label starts right of the ship's centre, and
    ;  clipping only ever moves a left edge further left.
    ld a,(hl)
    ld b,a
    inc hl
    inc hl                              ; -> the width
    add a,(hl)
    ld c,a                              ; C = the sprite's right edge
    ld a,(phase4_grp_x)
    ld e,a
    ld a,(phase4_grp_w)
    add a,e                             ; the label's right edge
    cp c
    jr nc,@p4_cnt_right
    ld a,c
@p4_cnt_right:
    sub b
    ld (hl),a

    ld hl,(phase4_grp_r)
    inc hl                              ; -> y
    ld a,(hl)
    ld c,a                              ; C = the sprite's top
    inc hl
    inc hl                              ; -> the height
    add a,(hl)
    ld b,a                              ; B = the sprite's bottom
    ld a,(phase4_grp_y)
    add a,TXT_CHAR_H
    cp b
    jr nc,@p4_cnt_bottom
    ld a,b
@p4_cnt_bottom:
    ld b,a
    ld a,(phase4_grp_y)
    cp c
    jr c,@p4_cnt_top
    ld a,c
@p4_cnt_top:
    ld c,a
    ld a,b
    sub c
    ld (hl),a                           ; the taller height
    ld hl,(phase4_grp_r)
    inc hl
    ld (hl),c                           ; ...from the higher top
    ret


; ----------------------------------------------------------------------------
;  phase4_draw_sensor -- one dot per entity, and nothing else
;
;  Section 9's stripped-back view. The Mothership gets a cross rather than a
;  dot so the fleet's anchor is still findable among them.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_draw_sensor:
    ld a,(phase4_visible)
    or a
    jp z,@p4_sensor_done
    ld (phase4_remaining),a
    xor a
    ld (phase4_index),a

@p4_sensor_one:
    ld a,(phase4_index)
    call phase4_vis_addr

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)                           ; screen y
    ld (phase4_sy),a
    inc hl
    inc hl                              ; skip the depth
    inc hl                              ; skip the view
    ld a,(hl)                           ; (class << 2) | tier
    ld (phase4_sx),de
    rrca
    rrca
    and #3F
    ld (phase4_view),a                  ; reuse: the class

    ld hl,(phase4_sx)
    ld a,(phase4_sy)
    ld c,a
    ld a,(phase4_view)
    or a
    jr nz,@p4_sensor_capital

    ;  A fighter: a single pixel.
    ld a,DISC_INK_TOP
    call mark_dot
    jr @p4_sensor_next

@p4_sensor_capital:
    ld a,DISC_INK_STEM
    call mark_cross

@p4_sensor_next:
    ld hl,phase4_index
    inc (hl)
    ld hl,phase4_remaining
    dec (hl)
    jp nz,@p4_sensor_one

@p4_sensor_done:
    ld hl,(phase4_count)
    ld a,(phase4_rect_count)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase4_blit_one -- draw one visible entity, and leave the window as found
;  In : HL -> a visible-list entry
;  Out: nothing. The body's carry is deliberately NOT passed on; the draw loop
;       does not read it, and class_blit_done would destroy it anyway.
;  Uses: everything
;
;  A wrapper, and it has to be one. class_tier_addr pages this class's sprite
;  library into the #4000 window -- which pages BANK 4 out, and bank 4 holds
;  the mission table, the fleet buffer and the code for every static screen.
;  The body below has two exits, the sprite was clipped away or it was drawn,
;  and both must put bank 4 back -- so the restore lives here, where there is
;  only one of it. See the header of src/game/shipclass.asm.
; ----------------------------------------------------------------------------
phase4_blit_one:
    call phase4_blit_body
    jp class_blit_done

; ----------------------------------------------------------------------------
;  phase4_blit_body -- everything above except putting bank 4 back
;  In : HL -> a visible-list entry
;  Out: nothing meaningful. Whether it drew is read off phase4_rect_count by
;       the caller, which is what phase4_draw_count needs anyway.
;  Uses: everything, and leaves a foreign bank under the window
; ----------------------------------------------------------------------------
phase4_blit_body:
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    ld (phase4_sy),a
    inc hl
    inc hl                              ; skip depth
    ld a,(hl)
    ld (phase4_view),a
    inc hl
    ld a,(hl)                           ; enemy | (class << 2) | tier
    ld (phase4_sx),de

    ld c,a
    and #80
    ld (spr_enemy),a                    ; recolour pen 1 as pen 3 if set
    ld a,c
    and 3
    push af                             ; the tier
    ld a,c
    and #7F
    rrca
    rrca
    and #1F
    ld b,a                              ; B = class
    pop af
    ld c,a                              ; C = tier
    ;  DE = the sprite block for this (class, tier), and the window now holds
    ;  that class's library. HL -> the tier's geometry, which is shared by
    ;  every class because they are all rendered from the same three tiers.
    call class_tier_addr
    ld (phase4_base),de

    ld a,(hl)
    ld (spr_w),a
    inc hl
    ld a,(hl)
    ld (spr_h),a
    inc hl
    ld c,(hl)                           ; half width, pixels
    inc hl
    ld b,(hl)                           ; half height, lines
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase4_blocksz),de

    ld hl,(phase4_sx)
    ld e,c
    ld d,0
    or a
    sbc hl,de
    ld (phase4_left),hl

    ld a,(phase4_sy)
    ld l,a
    ld h,0
    ld e,b
    ld d,0
    or a
    sbc hl,de
    ld (spr_y),hl

    ;  Pre-shift 0 covers sub-byte offsets 0 and 1, pre-shift 1 covers 2 and 3.
    ld hl,(phase4_left)
    ld a,l
    and 3
    rrca
    and 1
    ld (phase4_shift),a

    ld hl,(phase4_left)
    sra h
    rr l
    sra h
    rr l                                ; arithmetic >> 2, keeps negatives sane
    ld (spr_x),hl

    ld a,(phase4_view)
    add a,a
    ld hl,phase4_shift
    add a,(hl)
    or a
    jr z,@p4_no_offset

    ld b,a
    ld hl,0
    ld de,(phase4_blocksz)
@p4_add_block:
    add hl,de
    djnz @p4_add_block
    ld de,(phase4_base)
    add hl,de
    jr @p4_have_block
@p4_no_offset:
    ld hl,(phase4_base)
@p4_have_block:
    ld (spr_src),hl

    call spr_blit
    ret nc

    ld hl,spr_rect
    jp phase4_add_rect


; ----------------------------------------------------------------------------
;  phase4_draw_explosions -- a red mark where each ship died
;
;  Drawn after the ships and in both views: a kill is the one thing the player
;  must not miss, and in the sensor view it is the only thing that happens.
;  The mark does not grow -- it is a cross for a few frames and then it is
;  gone -- which is as much as twenty pixels of drawing buys.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_draw_explosions:
    ld hl,cbt_explosions
    ld (phase4_expl_ptr),hl
    ld a,EXPL_MAX
    ld (phase4_expl_left),a

@p4_expl_one:
    ld hl,(phase4_expl_ptr)
    push hl
    ld de,6
    add hl,de
    ld a,(hl)                           ; timer
    pop hl
    or a
    jr z,@p4_expl_next

    call proj_point
    jr nc,@p4_expl_next

    ld hl,(proj_sx)
    ld a,(proj_sy)
    ld c,a
    ld a,INK_ENEMY
    call mark_cross                     ; ...and the rectangle that erases it

@p4_expl_next:
    ld hl,(phase4_expl_ptr)
    ld de,EXPL_SIZE
    add hl,de
    ld (phase4_expl_ptr),hl
    ld hl,phase4_expl_left
    dec (hl)
    jr nz,@p4_expl_one
    ret


; ----------------------------------------------------------------------------
;  phase4_draw_disc -- the move cursor and its height line
;
;  Two projections: the disc itself, and the point directly below it on the
;  Y=0 reference plane. The line between them is what tells the player how
;  high the order is -- without it a cursor in a 3D void is unreadable, which
;  is the whole problem section 9 is solving.
;
;  The line is drawn at the disc's screen x rather than tracked properly. The
;  two points differ only in world Y, and row 0 of the camera matrix is
;  (cy, 0, sy) -- structurally independent of Y -- so they differ only through
;  the perspective divide. At these distances that is under a pixel.
;
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_draw_disc:
    ld a,(disc_active)
    or a
    ret z

    ;  Where the order sits, and the point directly below it on the plane.
    ld hl,(disc_pos + 0)
    ld (phase4_disc_flat + 0),hl
    ld hl,0
    ld (phase4_disc_flat + 2),hl
    ld hl,(disc_pos + 4)
    ld (phase4_disc_flat + 4),hl

    ld hl,phase4_disc_flat
    call proj_point
    ld a,0
    jr nc,@p4_disc_no_base
    ld a,(proj_sy)
    ld (phase4_disc_by),a
    ld a,1
@p4_disc_no_base:
    ld (phase4_disc_has_base),a

    ld hl,disc_pos
    call proj_point
    ret nc                              ; the order is off screen entirely

    ld hl,(proj_sx)
    ld (phase4_disc_tx),hl
    ld a,(proj_sy)
    ld (phase4_disc_ty),a

    ;  If the base is off screen there is no stem to draw, only the marker.
    ld a,(phase4_disc_has_base)
    or a
    ld a,(phase4_disc_ty)
    ld b,1                              ; a stem of one line: just the marker row
    ld c,a
    jr z,@p4_disc_have_stem

    ;  Smaller screen y is the top of the stem; the difference is its height.
    ld a,(phase4_disc_ty)
    ld b,a
    ld a,(phase4_disc_by)
    cp b
    jr nc,@p4_disc_top_is_upper
    ld c,a                              ; the base is higher up the screen
    ld a,b
    sub c
    ld b,a
    jr @p4_disc_have_stem
@p4_disc_top_is_upper:
    ld c,b
    sub c
    ld b,a

@p4_disc_have_stem:
    inc b                               ; include the last row
    ld hl,(phase4_disc_tx)
    ld a,DISC_INK_STEM
    call mark_bar

    ld hl,(phase4_disc_tx)
    ld a,(phase4_disc_ty)
    ld c,a
    ld a,DISC_INK_TOP
    jp mark_cross                       ; ...and the rectangle that erases it


; ----------------------------------------------------------------------------
;  phase4_hud -- the squadron strip (Homeplanet.md section 5.5)
;
;  Two rows of five: squadrons 1-5 above, 6-9 below. Every slot is drawn every
;  frame whether the squadron exists or not, so the layout never shifts under
;  the player's eye and an emptied squadron blanks itself.
;
;      >3:07     selected, squadron 3, seven ships
;       4:12     not selected
;               (blank -- no such squadron)
;
;  Drawn last, after the ships, so a ship that flies over the strip is
;  overwritten rather than the other way round.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_hud:
    call phase4_hud_changed
    ld hl,phase4_hud_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)                            ; once into each buffer

    ;  The hull row is repainted with us, and this is the only coupling between
    ;  the two. Everything that schedules a mis_wipe marks the HUD dirty, and a
    ;  wipe clears ALL 200 lines -- including the row above this strip, which
    ;  wave_draw owns and which nothing else would ever put back. Setting the
    ;  flag rather than calling it keeps the "once into each buffer" bookkeeping
    ;  in one place.
    ld a,2
    ld (wave_dirty),a

    ld a,1
    ld (phase4_hud_squad),a

    ld a,HUD_ROW_A_Y
    ld (phase4_hud_y),a
    ld a,HUD_X
    ld (phase4_hud_x),a
    ld a,HUD_PER_ROW
    ld (phase4_hud_left),a
    call phase4_hud_row

    ld a,HUD_ROW_B_Y
    ld (phase4_hud_y),a
    ld a,HUD_X
    ld (phase4_hud_x),a
    ld a,SQUAD_MAX - HUD_PER_ROW
    ld (phase4_hud_left),a
    call phase4_hud_row

    ; --- resources (section 5.5) ------------------------------------------
    ld hl,phase4_hud_ru_label
    ld b,HUD_RU_X
    ld c,HUD_ROW_A_Y
    call phase4_hud_label
    ;  All sixteen bits, in four digits. It used to be `ld a,(eco_ru)` into a
    ;  three-digit field, with a comment saying RU never goes near 65535 --
    ;  true when the only things to buy cost 35 and 40. All eight classes
    ;  landing made the Destroyer buyable at 250, so a player has to save past
    ;  255 to afford one, and the low byte read 0 exactly when they got there.
    ld hl,(eco_ru)
    ld b,HUD_RU_X + 3 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_A_Y
    call txt_draw_num4

    ;  The way out of not knowing the keys. Five characters is all the strip
    ;  has left after the RU figure -- the last glyph starts at byte 78 of 80.
    ld hl,phase4_hud_help
    ld b,HUD_HELP_X
    ld c,HUD_ROW_A_Y
    call phase4_hud_label

    ; --- the mission -------------------------------------------------------
    ;  Its number and whether the jump is open. Twelve characters of name
    ;  would not fit beside the squadron list, so the name lives on the
    ;  briefing screen the design asks for and this is the reminder.
    ld hl,phase4_hud_mis_label
    ld b,HUD_MIS_X
    ld c,HUD_ROW_B_Y
    call phase4_hud_label
    ld a,(mis_index)
    inc a
    ld b,HUD_MIS_X + 2 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_B_Y
    ld d,1
    call txt_draw_num

    ld a,(mis_complete)
    or a
    ld hl,phase4_hud_blank + 1          ; four spaces: no jump yet
    jr z,@p4_mis_show
    ld hl,phase4_hud_jump               ; the jump is available
    ld a,PEN_RED                        ; ...and section 2 makes 3 the ink
    call txt_set_pen                    ; that means "look at this"
@p4_mis_show:
    ld b,HUD_MIS_X + 4 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_B_Y
    call txt_draw
    ld a,PEN_WHITE
    call txt_set_pen

    ; --- the yard ---------------------------------------------------------
    ;  '*' while a ship is on the slipway, '>' while the panel is open and
    ;  offering one, blank otherwise.
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,@p4_yard_idle
    ld c,a
    ld a,'*'
    jr @p4_yard_show
@p4_yard_idle:
    ld a,(eco_build_open)
    or a
    jr z,@p4_yard_blank
    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld c,(hl)
    ld a,'>'

@p4_yard_show:
    ld (phase4_yard_text),a
    ld a,c
    add a,a
    add a,a                             ; four bytes a tag: marker + 3 letters
    ld l,a
    ld h,0
    ld de,class_tag
    add hl,de
    ld de,phase4_yard_text + 1
    ld bc,3
    ldir

    ;  ...and how many orders are waiting behind it. Section 5.5 asks this
    ;  strip for "Πόροι (RU) και ουρά κατασκευής" and only the first half of
    ;  that was ever here; a player cannot manage a queue they cannot see.
    ;
    ;  One character, because that is what the row has to spare between the
    ;  tag and M n JUMP -- and one is enough BY CONSTRUCTION rather than by
    ;  luck: the count is of orders WAITING, the slipway holds the tenth, so
    ;  it can never exceed ECO_QUEUE_WAIT = 9. A blank rather than a '0' when
    ;  the line is empty, so a yard building one ship reads exactly as it read
    ;  before there was a queue at all.
    ld a,(eco_queue_len)
    or a
    ld a,' '
    jr z,@p4_yard_depth
    ld a,(eco_queue_len)
    add a,'0'
@p4_yard_depth:
    ld (phase4_yard_text + 4),a

    ld hl,phase4_yard_text
    ld b,HUD_YARD_X
    ld c,HUD_ROW_B_Y
    jp txt_draw

@p4_yard_blank:
    ld hl,phase4_hud_blank              ; five spaces: nothing on the slipway
    ld b,HUD_YARD_X
    ld c,HUD_ROW_B_Y
    jp txt_draw


; ----------------------------------------------------------------------------
;  phase4_hud_changed -- has anything the HUD shows moved?
;
;  Compares the counts and the selection against a shadow copy rather than
;  having every command remember to flag itself. Ships will start dying later
;  and that changes the counts with nobody pressing anything.
;
;  Sets the dirty counter to 2, not 1: there are two screen buffers and the
;  strip has to be redrawn into each of them.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_hud_changed:
    ld hl,squad_count
    ld de,phase4_hud_shadow
    ld b,SQUAD_MAX + 1
@p4_hud_cmp:
    ld a,(de)
    cp (hl)
    jr nz,@p4_hud_diff
    inc hl
    inc de
    djnz @p4_hud_cmp

    ld a,(squad_sel)
    ld hl,phase4_hud_shadow_sel
    cp (hl)
    jr nz,@p4_hud_diff

    ;  Resources and the yard live in the same strip. The build TIMER is
    ;  deliberately not compared: it changes every frame while a ship is on
    ;  the slipway, and redrawing the strip for a countdown nobody is reading
    ;  would undo the whole point of the dirty flag.
    ld hl,(eco_ru)
    ld de,(phase4_hud_shadow_ru)
    or a
    sbc hl,de
    jr nz,@p4_hud_diff
    ld a,(eco_build_class)
    ld hl,phase4_hud_shadow_yard
    cp (hl)
    jr nz,@p4_hud_diff
    call phase4_yard_key
    ld hl,phase4_hud_shadow_pick
    cp (hl)
    jr nz,@p4_hud_diff
    ld a,(mis_index)
    add a,a
    ld hl,mis_complete
    add a,(hl)
    ld hl,phase4_hud_shadow_mis
    cp (hl)
    ret z

@p4_hud_diff:
    ld hl,squad_count
    ld de,phase4_hud_shadow
    ld bc,SQUAD_MAX + 1
    ldir
    ld a,(squad_sel)
    ld (phase4_hud_shadow_sel),a
    ld hl,(eco_ru)
    ld (phase4_hud_shadow_ru),hl
    ld a,(eco_build_class)
    ld (phase4_hud_shadow_yard),a
    call phase4_yard_key
    ld (phase4_hud_shadow_pick),a
    ld a,(mis_index)
    add a,a
    ld hl,mis_complete
    add a,(hl)
    ld (phase4_hud_shadow_mis),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  phase4_yard_key -- everything about the yard that the strip DRAWS, in a byte
;  Out: A
;  Uses: AF, HL
;
;  The panel's marker, the class it is offering and how many orders are waiting
;  all land in one row of five characters, so one shadow byte can watch all
;  three. The depth goes in the high nibble because it can reach nine and the
;  other two together cannot reach sixteen; four RRCAs on a value below ten is
;  a nibble swap and costs four bytes.
;
;  The build TIMER is deliberately still not in here, for the reason
;  phase4_hud_changed gives: it moves every frame and nobody reads it.
; ----------------------------------------------------------------------------
phase4_yard_key:
    ld a,(eco_queue_len)
    rrca
    rrca
    rrca
    rrca                                ; << 4
    ld hl,eco_build_open
    add a,(hl)
    add a,(hl)                          ; the panel's marker: '>' or nothing
    ld hl,eco_build_pick
    add a,(hl)
    ret


;  A caption in ink 2 and the pen put back to 1 afterwards: chrome is blue and
;  values are white, and nothing may inherit an ink.
;  In : HL -> the text, B = x in bytes, C = y
phase4_hud_label:
    push hl
    push bc
    ld a,PEN_BLUE
    call txt_set_pen
    pop bc
    pop hl
    call txt_draw
    ld a,PEN_WHITE
    jp txt_set_pen


phase4_hud_row:
@p4_entry:
    call phase4_hud_entry

    ld hl,phase4_hud_x
    ld a,(hl)
    add a,HUD_ENTRY_BYTES
    ld (hl),a
    ld hl,phase4_hud_squad
    inc (hl)

    ld hl,phase4_hud_left
    dec (hl)
    jr nz,@p4_entry
    ret


phase4_hud_entry:
    ld a,(phase4_hud_squad)
    call squad_count_of
    ld (phase4_hud_n),a
    or a
    jr nz,@p4_active

    ;  No such squadron: blank the whole slot so nothing stale survives.
    ld hl,phase4_hud_blank
    ld a,(phase4_hud_x)
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    jp txt_draw

@p4_active:
    ;  ">" if this is the selection, otherwise a space.
    ld a,(phase4_hud_squad)
    ld hl,squad_sel
    cp (hl)
    ld a,' '
    jr nz,@p4_not_selected
    ld a,'>'
@p4_not_selected:
    ld (phase4_hud_text + 0),a

    ;  Ink 2 for the squadrons that are not selected. The palette is semantic
    ;  (section 2) and 2 is the shading ink, so the selection is the only white
    ;  entry in the row -- the eye finds it without reading a digit.
    ld a,(phase4_hud_squad)
    ld hl,squad_sel
    cp (hl)
    ld a,PEN_WHITE
    jr z,@p4_entry_pen
    ld a,PEN_BLUE
@p4_entry_pen:
    call txt_set_pen

    ld a,(phase4_hud_squad)
    add a,'0'
    ld (phase4_hud_text + 1),a

    ld hl,phase4_hud_text
    ld a,(phase4_hud_x)
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    call txt_draw

    ;  The count goes in the last two columns of the slot.
    ld a,(phase4_hud_x)
    add a,3 * TXT_CHAR_W_BYTES
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    ld d,2
    ld a,(phase4_hud_n)
    call txt_draw_num
    ld a,PEN_WHITE                      ; nothing inherits an ink
    jp txt_set_pen


; ============================================================================
;  Data
; ============================================================================

phase4_rects:       defw 0
phase4_count:       defw 0
phase4_rect_ptr:    defw 0
phase4_rect_count:  defb 0

phase4_ent:         defw 0
phase4_vis_ptr:     defw 0
phase4_index:       defb 0
phase4_remaining:   defb 0
phase4_visible:     defb 0
phase4_order_idx:   defb 0

phase4_squad:       defb 0
phase4_slotno:      defb 0
phase4_axis:        defb 0
phase4_home_ptr:    defw 0
phase4_off_ptr:     defw 0
phase4_coord_ptr:   defw 0
phase4_cur:         defw 0
phase4_tgt:         defw 0

phase4_sx:          defw 0
phase4_sy:          defb 0
phase4_view:        defb 0
phase4_shift:       defb 0
phase4_left:        defw 0
phase4_base:        defw 0
phase4_blocksz:     defw 0

phase4_grp_ptr:     defw 0
phase4_grp_left:    defb 0
phase4_grp_i:       defb 0
phase4_grp_key:     defb 0
phase4_grp_side:    defb 0
phase4_grp_n:       defb 0
phase4_grp_x:       defb 0
phase4_grp_y:       defb 0
phase4_grp_w:       defb 0
phase4_grp_d:       defb 0
phase4_grp_r:       defw 0
phase4_grp_rects:   defb 0
phase4_grp_plus:    defb "+",0

;  phase4_sort keeps its whole working set in registers and on the stack now.
;  The five bytes of state it used to need went with the five memory reads a
;  comparison used to cost.

phase4_expl_ptr:    defw 0
phase4_expl_left:   defb 0
phase4_disc_flat:   defs 6, 0
phase4_disc_tx:     defw 0
phase4_disc_ty:     defb 0
phase4_disc_by:     defb 0
phase4_disc_has_base: defb 0

phase4_hud_squad:   defb 0
phase4_hud_x:       defb 0
phase4_hud_y:       defb 0
phase4_hud_left:    defb 0
phase4_hud_n:       defb 0
phase4_hud_dirty:   defb 0
phase4_hud_shadow:  defs SQUAD_MAX + 1, #FF
phase4_hud_shadow_sel: defb #FF
phase4_hud_shadow_ru:  defw #FFFF
phase4_hud_shadow_yard: defb #FE
phase4_hud_shadow_pick: defb #FE
phase4_hud_shadow_mis:  defb #FE

phase4_hud_ru_label: defb "RU ",0
phase4_hud_help:     defb "?HELP",0
phase4_hud_mis_label: defb "M",0
phase4_hud_jump:     defb "JUMP",0
phase4_yard_text:    defb " XXX ",0      ; marker, tag, and the queue's depth
phase4_hud_text:    defb " 0:",0        ; the marker and digit are patched in

;  ONE run of spaces, read from three lengths in. A five-character blank, a
;  four and another four were sixteen bytes of nothing written out three times.
phase4_hud_blank:   defb "     ",0


demo_tick0:         defb 0
demo_frames:        defb 0

phase4_slot_next:   defs SQUAD_MAX + 1, 0

phase4_drawn_a:     defb 0
phase4_drawn_b:     defb 0

;  The groups found this frame: index into phase4_vis, x in bytes, y, key.
phase4_heads:       defs PHASE4_HEADS_MAX * PHASE4_HEAD_SIZE, 0
phase4_nheads:      defb 0

;  How many ships each visible entry draws for: 0 = consolidated away and not
;  drawn at all, 1 = itself, n = itself and n-1 behind it.


;  Ships, explosions, the reference plane, the move disc. A consolidated
;  group's "+n" gets no slot of its own: phase4_draw_count WIDENS the sprite's
;  rectangle to cover it instead. Over-erasing costs nothing -- the rectangle
;  is cleared and redrawn either way -- and a slot per entity in two buffers
;  is 384 bytes of a low 16K that has none to spare.
;  ...and the resource patches, the move disc and the Mothership indicator.
;  The last two are TWO rectangles each: a height bar and the marker on top of
;  it, recorded through the same mark_bar / mark_cross the rest of them use.
;  One combined rectangle would have been a third way of doing it.
;  ...and the fifth WAS the jump wipe's line, which recorded one so that the
;  ordinary erase would rub it out when it moved. The wipe is one short bar per
;  ship now and records nothing: a bar is rubbed out by the masking pass that
;  drew it, which repaints its ship's whole band from both ends every step. The
;  slot is slack and is left here deliberately -- phase4_add_rect does not
;  check this bound, it appends and increments, so a slot that is not here is
;  four bytes written past the end of the array.
PHASE4_RECT_SLOTS        equ ENT_MAX + EXPL_MAX + GRID_POINTS + MARK_PATCHES + 5
;  The two lists themselves are in src/main.asm, above code_end: they are read
;  only as far as phase4_drawn_a / phase4_drawn_b say, and those two DO start
;  at zero in the image, so the 650 bytes behind them never needed carrying.



