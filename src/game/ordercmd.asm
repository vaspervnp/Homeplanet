; ============================================================================
;  game/ordercmd.asm -- section 9's control surface, IN BANK 4
; ============================================================================
;  Everything the player's keys do to the camera, the selection and the move
;  disc. Split out of game/order.asm, which keeps the equates and the
;  variables; see the note at the bottom of that file for why the data did not
;  come with it.
;
;  WHY IT IS IN THE BANK
;  ---------------------
;  Bank 4 is the resting state of the #4000 window (game/shipclass.asm has the
;  one rule), so #4000-#7FFF is ordinary executable RAM for all but the few
;  hundred T-states a sprite blit spends with another bank paged in. None of
;  this runs then: order_update is called from demo_update's playing path,
;  before anything is drawn, and everything below it is reached from there or
;  from demo_init.
;
;  What put it here is section 14's other half. Rendering six yaw views
;  instead of eight took the interceptor and frigate libraries from 11520
;  bytes to 8640 and gave bank 4 2880 bytes it did not have -- and bank 4 had
;  NINE. The low 16K is the binding constraint on this project, not the bank,
;  so the freed space is only worth anything once something moves into it.
;  This is the largest thing that could: a kilobyte of code that runs on a
;  keypress and has no business competing with the frame loop.
;
;  The rule that decides what may follow it is the one the help page and the
;  title screen already follow: anything that only runs while the game is
;  stopped, or only when a key goes down, belongs in the bank.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  order_init -- give every squadron a starting station
;  Uses: everything
; ----------------------------------------------------------------------------
order_init:
    ld hl,order_home                    ; in bank 7, so:
    ld de,squad_dest
    ld bc,SQUAD_MAX * 6
    call bank7_copy
    xor a
    ld (disc_active),a
    ld (order_paused),a
    ld (sel_mothership),a
    ld (view_sensors),a
    ld a,ORDER_NO_TARGET
    ld (order_target),a
    ld a,CAM_ZOOM_DEFAULT
    ld (cam_zoom),a
    jp order_apply_zoom


; ----------------------------------------------------------------------------
;  order_update -- one frame of input
;  Uses: everything
; ----------------------------------------------------------------------------
order_update:
    ;  Cursor keys belong to whichever thing is in charge.
    ld a,(disc_active)
    or a
    jr nz,@ord_disc_has_cursors
    ld a,(pan_active)
    or a
    jr nz,@ord_pan_has_cursors
    call order_camera
    jr @ord_shared
@ord_disc_has_cursors:
    ld hl,disc_pos
    ld (disc_target),hl
    call order_disc_move
    jr @ord_shared
@ord_pan_has_cursors:
    ;  Panning IS the move disc's movement, pointed at the camera offset
    ;  instead of at a destination -- same octant rounding, so "right" is
    ;  right on screen here too.
    ld hl,cam_pan
    ld (disc_target),hl
    call order_disc_move

@ord_shared:
    call order_zoom

    ld a,KEY_SPACE
    call key_hit
    jr nc,@ord_no_pause
    ld hl,order_paused
    ld a,(hl)
    xor 1
    ld (hl),a
@ord_no_pause:

    ld a,KEY_ENTER
    call key_hit
    jr nc,@ord_no_enter
    ld a,(eco_build_open)
    or a
    jr z,@ord_enter_disc
    call eco_queue                      ; the panel owns ENTER while it is up
    jr @ord_no_enter
@ord_enter_disc:
    ld a,(disc_active)
    or a
    jr nz,@ord_confirm
    call order_disc_open
    jr @ord_no_enter
@ord_confirm:
    call order_disc_confirm
@ord_no_enter:

    ld a,KEY_0
    call key_hit
    call c,order_centre

    ;  TAB is what section 9 asks for. `S` does the same thing because the
    ;  emulator's keymap has no TAB entry at all, so the TAB binding cannot be
    ;  pressed in a test and is unverified -- it is right per the hardware
    ;  matrix, but nothing here proves it.
    ld a,KEY_TAB
    call key_hit
    call c,order_toggle_view

    ld a,KEY_S
    call key_hit
    call c,order_toggle_view

    ld a,KEY_R
    call key_hit
    call c,order_dock

    ld a,KEY_J
    call key_hit
    call c,mis_jump                     ; refused unless the objective is met

    ld a,KEY_H
    call key_hit
    call c,eco_set_harvest

    ;  RU into hull. The other thing the treasury buys, and the only thing in
    ;  the game that puts hull back -- see eco_repair_cost for what it costs
    ;  and why the multiplier is two.
    ld a,KEY_E
    call key_hit
    call c,eco_repair

    ;  ...and its opposite: hull back into RU. Destructive, and on one key
    ;  because the SQUADRON is the selection -- `O` splits the fleet by class
    ;  in one press, so "scrap the scouts" is two keystrokes.
    ld a,KEY_Y
    call key_hit
    call c,eco_recycle_key

    ;  ...and its sibling: the corvettes go and fetch the wrecks. Two work
    ;  orders, two keys, for the reason section 9 gives H its "(harvesters)" --
    ;  a player who wants the mining kept going while the salvage ships stay in
    ;  the line has to be able to say so.
    ld a,KEY_T
    call key_hit
    call c,slv_set_tow

    ld a,KEY_B
    call key_hit
    jr nc,@ord_no_build
    ld hl,eco_build_open
    ld a,(hl)
    xor 1
    ld (hl),a
    or a
    jr z,@ord_no_build

    ;  OPENING IT LANDS ON A CLASS THE YARD WILL TAKE. The pick is a byte that
    ;  survives between openings and starts at the cheapest class, and what is
    ;  allowed moves under it -- a mission is reached, a derelict is towed
    ;  home, the last harvester dies. Without this the panel can open showing
    ;  something ENTER then refuses, which reads as a broken key rather than as
    ;  a rule. eco_pick_step walks to the next allowed class and stops, and it
    ;  is asked to step FORWARD so the answer is the cheapest one at or after
    ;  where the player left the list.
    ld a,(eco_build_pick)
    dec a                               ; ...so a legal pick steps back onto
    ld (eco_build_pick),a               ;    itself rather than past itself
    ld a,1
    call eco_pick_step
@ord_no_build:

    ;  While the build panel is open, `,` and `.` pick a class instead of
    ;  walking the target. One pair of keys, two meanings, decided by the mode
    ;  the player can see on screen.
    ld a,(eco_build_open)
    or a
    jr z,@ord_target_keys

    ld a,KEY_PERIOD
    call key_hit
    jr nc,@ord_no_pick_next
    ld a,1
    call eco_pick_step
@ord_no_pick_next:
    ld a,KEY_COMMA
    call key_hit
    jr nc,@ord_no_pick_prev
    ld a,-1
    call eco_pick_step
@ord_no_pick_prev:
    jr @ord_after_target_keys

@ord_target_keys:
    ld a,KEY_PERIOD
    call key_hit
    jr nc,@ord_no_next_target
    ld a,1
    call order_target_step
@ord_no_next_target:

    ld a,KEY_COMMA
    call key_hit
    jr nc,@ord_no_prev_target
    ld a,-1
    call order_target_step
@ord_no_prev_target:
@ord_after_target_keys:

    ld a,KEY_A
    call key_hit
    jr nc,@ord_no_attack
    ;  Out of a fight A is the AUTO RESPONSE's key -- game/retaliate.asm --
    ;  and comes back with carry set once it has armed it or said it is used.
    call order_attack_key
    jr c,@ord_no_attack
    ld a,ENT_ORDER_ATTACK
    call order_issue
@ord_no_attack:

    ld a,KEY_G
    call key_hit
    jr nc,@ord_no_guard
    ld a,ENT_ORDER_GUARD
    call order_issue
@ord_no_guard:

    ld a,KEY_ESC
    call key_hit
    jr nc,@ord_no_esc
    xor a
    ld (disc_active),a
    ld (eco_build_open),a
    ld (eco_recycle_armed),a            ; ...and the armed RECYCLE, same as both
    ;  ...AND IT CALLS OFF A JUMP. This is what makes the countdown a mechanic
    ;  rather than a delay: ten seconds of live battle that you can still back
    ;  out of, because something arrived. ESC and not `J` again, because you
    ;  cancel in response to the board and ESC already means "get me out of
    ;  this mode" for the disc and the panel.
    ld (jump_secs),a
@ord_no_esc:
    jp order_focus


; ----------------------------------------------------------------------------
;  order_dock -- the `R` key: station the squadron on the Mothership
;
;  Section 9 calls this `D`, which the squadron commands took. This one is
;  fully live: docking is just a move order whose destination happens to be
;  wherever the Mothership is.
;  Uses: everything
; ----------------------------------------------------------------------------
order_dock:
    call order_have_squadron
    ret nc                              ; the Mothership is already home
    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0
    push hl
    call order_dest_addr
    ex de,hl
    pop hl
    ld bc,6
    ldir
    jp order_release_attack


; ----------------------------------------------------------------------------
;  order_release_attack -- a movement order ENDS an attack order
;  Uses: everything
;
;  Reported as "χάνω τυχαία τον στόλο ... τον βλέπω, τον επιλέγω, αλλά δεν
;  απαντάει στις εντολές", and it was all three of those things at once.
;
;  phase4_fly SKIPS a ship under ENT_ORDER_ATTACK, deliberately, so that
;  cbt_move_enemies can close it on its target without the two of them stepping
;  it by PHASE4_STEP in opposite directions and cancelling. The consequence
;  nobody had followed through is that while the order stands, `R`, `F` and the
;  move disc are not merely ineffective -- they are SILENTLY ineffective. The
;  station is written, the formation is changed, the disc is confirmed, and not
;  one ship moves. Nothing on screen says why, and the only key that ever got a
;  squadron back was `G`, which is not something a player would guess.
;
;  Measured on the build this was reported against: one hostile alive at 7500
;  units, press `A`, and TWELVE OF SIXTEEN ships fly out to it while four stay
;  behind -- the squadron spread from 0 to 7500 units apart. `R` and then `F`
;  moved neither group. `G` brought them home. The four that stayed are the
;  "τυχαία": cbt_distance saturates at 255, so at that range whether a
;  particular ship finds the enemy at all turns on a few hundred world units of
;  where its formation slot happened to put it, and one order tears the
;  squadron in half.
;
;  So: telling a squadron where to BE is a new order, and it replaces the old
;  one. IDLE and not GUARD, for the reason cbt_fire_if_able gives where it
;  spends the order itself -- cbt_retarget_one returns early for GUARD, so a
;  ship dropped into it stops being re-pointed at nearer targets.
;
;  ONLY ATTACK, and that guard is the same one cbt_fire_if_able needs: a
;  harvester in the selection is carrying ENT_ORDER_HARVEST, and a `R` that
;  cleared orders unconditionally would send the miners home and stop the
;  economy every time the player docked.
;
;  ENT_PLAYER_MAX and not ENT_MAX: a hostile carries SQUAD_NONE and could never
;  match the selection, so the hostile region is twenty slots of asking.
; ----------------------------------------------------------------------------
order_release_attack:
    xor a
    ld (order_index),a
@ord_rel_one:
    ld a,(order_index)
    call ent_addr

    push hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    pop hl
    jr z,@ord_rel_next

    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    pop hl
    jr nz,@ord_rel_next

    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_ATTACK
    jr nz,@ord_rel_next
    ld (hl),ENT_ORDER_IDLE

@ord_rel_next:
    ld hl,order_index
    inc (hl)
    ld a,(hl)
    cp ENT_PLAYER_MAX
    jr c,@ord_rel_one
    ret


; ----------------------------------------------------------------------------
;  order_target_step -- `,` and `.` walk the target through HOSTILE entities
;  In : A = +1 to go forward, -1 to go back
;  Out: (order_target) = a hostile entity index, or ORDER_NO_TARGET
;  Uses: everything
;
;  Wraps, and skips empty slots, so the player never has to know that the
;  entity table is sparse.
;
;  AND IT SKIPS OUR OWN SHIPS, WHICH IS A REPAIR RATHER THAN A REFINEMENT.
;  This walked every FLYING entity, and the fleet is fifty-six of the
;  seventy-six slots -- so the target landed on one of ours as a matter of
;  course, and from a fresh mission the very first press of `.` put it on slot
;  0. `A` then wrote that friendly index into every ship of the selection and
;  the whole squadron stopped: phase4_fly skips an attacking ship, and with the
;  target flying and inside CBT_RANGE -- it is in the same formation --
;  cbt_move_enemies holds station and cbt_fire_if_able used to return at
;  cbt_hostile without ever reconsidering. Reported as "χάνει το attack κάποιες
;  φορές. Αντί να επιτίθενται κάθονται κάπου τα squadrons και αφήνουν να τα
;  χτυπάνε", and measured: press `.`, then `A`, and fifteen of sixteen ships
;  never moved once in 1800 frames while the fleet was shot down to eight.
;
;  cbt_fire_if_able re-acquires now instead of returning, so a bad index can no
;  longer strand anything whatever writes it -- that is the net, and it is the
;  one that has to hold. This is the other half, and it is the half a PLAYER
;  meets: the picker exists to choose something to attack, and offering your
;  own fleet is offering an order that cannot be carried out. Same reasoning
;  that makes the build panel step OVER a class it cannot offer rather than
;  showing it and refusing.
;
;  With nothing hostile on the board it now settles on ORDER_NO_TARGET, which
;  is honest -- and `A` with no target is the case that already worked, because
;  cbt_fire_if_able finds the nearest enemy for itself.
; ----------------------------------------------------------------------------

order_target_step:
    ld (order_step),a
    ld a,(order_target)
    cp ENT_MAX
    jr c,@ord_tgt_from
    xor a
    dec a                               ; start one before slot 0 going forward
@ord_tgt_from:
    ld c,a
    ld b,ENT_MAX                        ; give up after a full lap

@ord_tgt_try:
    ld a,(order_step)
    add a,c
    cp ENT_MAX
    jr c,@ord_tgt_in_range
    or a
    jr z,@ord_tgt_in_range
    bit 7,a
    jr z,@ord_tgt_wrap_low
    ld a,ENT_MAX - 1                    ; walked off the bottom
    jr @ord_tgt_in_range
@ord_tgt_wrap_low:
    xor a                               ; walked off the top
@ord_tgt_in_range:
    ld c,a
    push bc
    call ent_is_flying
    call c,@ord_tgt_theirs              ; ...and it has to be one of THEIRS
    pop bc
    jr c,@ord_tgt_found
    djnz @ord_tgt_try

    ld a,ORDER_NO_TARGET
    ld (order_target),a
    ret

@ord_tgt_found:
    ld a,c
    ld (order_target),a
    ret


;  CF set if slot C is on the Vekhar side. Only reached for a slot ent_is_flying
;  has already passed, so the pair of them is the whole of "something we may be
;  told to attack" -- active, not wreckage, and not us.
;
;  It re-derives the record from C rather than using the HL ent_is_flying
;  happens to leave on the flags byte. That HL is not in its Out: line, and
;  this file's rule is that the register contract is the only thing standing
;  between you and the next scr_line_addr. It runs on a keypress, so the second
;  ent_addr costs nothing anybody can measure.
@ord_tgt_theirs:
    ld a,c
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    ret z                               ; ours: CF is clear from the AND
    scf
    ret


; ----------------------------------------------------------------------------
;  order_issue -- give every ship in the selection an order
;  In : A = the ENT_ORDER_* code
;  Out: -
;  Uses: everything
;
;  The order and its target land in the entity records; NOTHING ACTS ON THEM
;  YET. Combat is phase 6. This is here so the control surface of section 9 is
;  complete and so the records carry what phase 6 will need, not because
;  pressing A does anything you can see.
; ----------------------------------------------------------------------------
order_issue:
    ld (order_pending),a
    xor a
    ld (order_index),a
@ord_issue_one:
    ld a,(order_index)
    call ent_addr

    ;  ACTIVE FIRST, AND THIS IS A REPAIR RATHER THAN TIDINESS. A dead ship's
    ;  record keeps every byte it had, ENT_SQUAD included -- nothing clears it,
    ;  because nothing needs to while the slot is empty. So this loop, which
    ;  asked only about the squadron, wrote the order into every EMPTY slot of
    ;  the selection as well: press `A` after losing a ship and the hole it
    ;  left is carrying ENT_ORDER_ATTACK.
    ;
    ;  That is a landmine rather than a bug on its own -- until the yard builds
    ;  into that slot, and the ship comes out of the Mothership already
    ;  attacking. phase4_fly SKIPS an attacking ship on purpose, so the new
    ;  ship never joins the formation and ignores every move and formation
    ;  order the player gives; and it only shows when a hostile is alive to
    ;  keep the order from being spent, which since the attack waves is most
    ;  of a mission. Reported as "χάνονται οι σχηματισμοί ... μόνο τα
    ;  καινούρια σκάφη".
    ;
    ;  eco_spawn_built writing ENT_ORDER_IDLE is the other half and the one
    ;  that makes it impossible; this half stops the order being planted at
    ;  all. An order issued to a slot with no ship in it cannot mean anything.
    push hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    pop hl
    jr z,@ord_issue_next

    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    pop hl
    jr nz,@ord_issue_next

    push hl
    ld de,ENT_ORDER
    add hl,de
    ld a,(order_pending)
    ld (hl),a
    pop hl
    ld de,ENT_TARGET
    add hl,de
    ld a,(order_target)
    ld (hl),a

@ord_issue_next:
    ld hl,order_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@ord_issue_one
    ret


; ----------------------------------------------------------------------------
;  order_toggle_view -- the TAB key
;
;  Section 9: the sensor view is "fully stripped back -- only dots, link lines
;  and the edges of the map. Very cheap to draw, so a longer range and faster
;  time (fast-forward x3) are allowed there."
;
;  The cheapness is the point. A dot per entity instead of a masked sprite is
;  most of a frame back, and that is what pays for running the simulation
;  three times as fast while the fleet is in transit.
;  Uses: AF, HL
; ----------------------------------------------------------------------------
order_toggle_view:
    ld hl,view_sensors
    ld a,(hl)
    xor 1
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  order_focus -- point the camera at whatever is selected
;
;  Section 4.3: the camera orbits "the Mothership or the selected squadron".
;  Without this, selecting a squadron does nothing you can see -- the view
;  stays wherever it was and the player has to fly to their own fleet.
;
;  It follows the squadron's STATION rather than the ships' centre of mass, so
;  the view settles the instant an order is given instead of drifting along
;  behind the formation.
;  Uses: everything
; ----------------------------------------------------------------------------
order_focus:
    ld a,(sel_mothership)
    or a
    jr z,@ord_focus_squadron

    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0
    jr @ord_focus_copy

@ord_focus_squadron:
    call order_dest_addr

@ord_focus_copy:
    ld de,cam_focus_x
    ld bc,6
    ldir

    ;  ...and then wherever the player has dragged the view to. The camera
    ;  still FOLLOWS the selection; the pan is an offset from it, so a
    ;  squadron that flies on stays the same distance off centre.
    ld hl,cam_pan
    ld de,cam_focus_x
    ld b,3
@ord_focus_pan:
    push bc
    ld a,(de)
    add a,(hl)
    ld c,a
    inc hl
    inc de
    ld a,(de)
    adc a,(hl)
    ld (de),a
    dec de
    ld a,c
    ld (de),a
    inc hl
    inc de
    inc de
    pop bc
    djnz @ord_focus_pan
    ret


; ----------------------------------------------------------------------------
;  order_select_mothership -- the `0` key
;  Uses: AF
; ----------------------------------------------------------------------------
;  IT IS A SELECTION NOW, not only a camera. "Να μπορώ να επιλέξω το 0 και να
;  αποεπιλέγονται όλα τα άλλα" -- so squad_sel goes to SQUAD_NONE and the HUD
;  shows no squadron in white, which is what "all the others deselected" looks
;  like on the screen. squad_select clears sel_mothership on the way back, so
;  the two are never both true.
;
;  The Mothership's own ENT_SQUAD is SQUAD_NONE, so every order that walks the
;  selection by comparing ENT_SQUAD now finds exactly the Mothership and
;  nothing else -- which is the whole of what was asked, for one store.
order_select_mothership:
    ld a,1
    ld (sel_mothership),a
    xor a
    ld (squad_sel),a
    ret


; ----------------------------------------------------------------------------
;  order_have_squadron -- CF set if a real squadron is selected
;  Uses: AF
;
;  THE MOTHERSHIP IS NOT A SQUADRON, and the orders that tell a squadron where
;  to BE do not apply to it: it holds station, that is what it is for, and
;  order_home has no row for squadron 0.
;
;  That last part is not a matter of taste. order_dest_addr is
;  `squad_dest[squad_sel - 1]`, so at SQUAD_NONE it computes 255 * 6 and writes
;  six bytes fifteen hundred past the end of the table -- a move order given
;  with `0` selected would corrupt whatever happens to follow it. The guard is
;  here rather than inside order_dest_addr because the callers have to do
;  something sensible with the answer, and "do nothing" is only sensible where
;  the player can see why.
; ----------------------------------------------------------------------------
order_have_squadron:
    ld a,(squad_sel)
    or a
    ret z                               ; CF clear: nothing to send anywhere
    scf
    ret


; ----------------------------------------------------------------------------
;  order_camera -- cursor keys orbit, within the pitch limits
;  Uses: everything
; ----------------------------------------------------------------------------
order_camera:
    ld a,KEY_CUR_LEFT
    call key_down
    jr nc,@ord_no_left
    ld hl,cam_yaw
    ld a,(hl)
    sub CAM_YAW_STEP
    ld (hl),a
@ord_no_left:

    ld a,KEY_CUR_RIGHT
    call key_down
    jr nc,@ord_no_right
    ld hl,cam_yaw
    ld a,(hl)
    add a,CAM_YAW_STEP
    ld (hl),a
@ord_no_right:

    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_no_up
    ld a,(cam_pitch)
    add a,CAM_PITCH_STEP
    call order_clamp_pitch
    ld (cam_pitch),a
@ord_no_up:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld a,(cam_pitch)
    sub CAM_PITCH_STEP
    call order_clamp_pitch
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  order_clamp_pitch -- hold a signed pitch inside +/-CAM_PITCH_MAX
;  In/Out: A
;  Uses: AF, B
;
;  Biasing by the limit turns the two-sided signed test into one unsigned
;  range check: anything valid lands in 0..2*MAX once shifted up.
; ----------------------------------------------------------------------------
order_clamp_pitch:
    ld b,a
    add a,CAM_PITCH_MAX
    cp CAM_PITCH_MAX * 2 + 1
    jr c,@ord_pitch_ok
    bit 7,b
    jr nz,@ord_pitch_low
    ld b,CAM_PITCH_MAX
    jr @ord_pitch_ok
@ord_pitch_low:
    ld b,-CAM_PITCH_MAX
@ord_pitch_ok:
    ld a,b
    ret


; ----------------------------------------------------------------------------
;  order_zoom -- Z or + closer, X or - further, twelve steps (section 4.3)
;
;  Two pairs of keys, one pair of commands. `+` is not a key on this machine:
;  it is SHIFT + `;`, and the matrix reports only the physical key, so
;  KEY_PLUS is the `;` position -- see the note beside it in sys/keyboard.asm.
;  Uses: everything
; ----------------------------------------------------------------------------
order_zoom:
    ld a,KEY_Z
    call key_hit
    jr c,@ord_zoom_in
    ld a,KEY_PLUS
    call key_hit
@ord_zoom_in:
    jr nc,@ord_no_in
    ld hl,cam_zoom
    ld a,(hl)
    or a
    jr z,@ord_no_in
    dec (hl)
    call order_apply_zoom
@ord_no_in:

    ld a,KEY_X
    call key_hit
    jr c,@ord_zoom_out
    ld a,KEY_MINUS
    call key_hit
@ord_zoom_out:
    ret nc
    ld hl,cam_zoom
    ld a,(hl)
    cp CAM_ZOOM_STEPS - 1
    ret nc
    inc (hl)
    ; fall through

; ----------------------------------------------------------------------------
;  order_apply_zoom -- put cam_zoom_table[cam_zoom] into force
;  Uses: AF, DE, HL
;
;  Two bytes of it are cam_dist. The other eighteen are Z80 INSTRUCTIONS,
;  copied into the middle of two routines:
;
;    * proj_scale -- its range check, its shift ladder and its tail. That is
;      where the ZOOM happens, and ZOOM_STEPS in tools/gentables.py says why
;      cam_dist alone cannot do it.
;    * proj_mag, inside proj_offset -- six bytes that spread the projected
;      picture across the width of the screen at the long cam_dists, where
;      PROJ_K's 45-degree field of view leaves the outer half unreachable.
;
;  Five LDIRs because the five runs are separated by instructions that never
;  change. Nothing in the interrupt handler goes near either routine, so there
;  is no window to guard.
;
;  cam_zoom_table IS IN BANK 7 and every one of the six runs therefore comes
;  down through bank7_copy, which does the paging from the low 16K -- this file
;  is bank 4 code and cannot page a bank in for itself. It went across when the
;  vortex chase needed the room: 240 bytes of DISC.BIN for five `ldir`s
;  becoming five `call`s, which is the best ratio this project has ever had out
;  of that lever. Nothing else reads the table, and the destinations were
;  already in the low 16K, which is what made it a one-routine change.
;
;  It runs on a keypress and from demo_init, never during a blit, so the window
;  is at rest at every call and bank7_copy puts bank 4 back before it returns.
;  Uses BC as well now, which no caller minds: order_zoom falls into this and
;  demo_init is "uses everything".
; ----------------------------------------------------------------------------
order_apply_zoom:
    ;  NOT WITHOUT A DISC. The table is in bank 7 and bank 7 is read off the
    ;  disc, so on a machine that could not read one it is a bank of whatever
    ;  powered up -- and unlike every other thing over there, this one is not
    ;  words on a screen: it is patched into proj_scale and proj_mag, and a
    ;  record of zeroes makes proj_deltas reject every entity in the game.
    ;  Nothing is drawn at all, which is a far worse failure than the stand-in
    ;  blocks class_use_fallback exists to give.
    ;
    ;  Returning here leaves the step the image was ASSEMBLED with, and
    ;  src/main.asm asserts that that is ZOOM_DEFAULT's -- so a machine with no
    ;  disc plays at exactly the step the game starts on and Z and X do
    ;  nothing. That is the right shape of degradation for a machine that has
    ;  no ship art either.
    ld a,(lib_ok)
    or a
    ret z

    ld a,(cam_zoom)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; HL = 4n
    ld d,h
    ld e,l                              ; DE = 4n
    add hl,hl
    add hl,hl                           ; HL = 16n
    add hl,de                           ; HL = 20n, CAM_ZOOM_RECORD apiece
    ld de,cam_zoom_table
    add hl,de

    ld de,cam_dist
    ld bc,2
    call bank6_copy
    ;  BC IN FULL EVERY TIME. The five LDIRs used to lean on B being left at
    ;  zero by the one before, and bank7_copy does not leave it there -- it
    ;  ends by writing the gate array, which is an `out (c),c` with #7F in B.
    ;  A `ld c,4` after one of these asks for #7F04 bytes.
    ld de,proj_zoom_check
    ld bc,4
    call bank6_copy
    ld de,proj_zoom_shl
    ld bc,4
    call bank6_copy
    ld de,proj_zoom_shr
    ld bc,2
    call bank6_copy
    ld de,proj_zoom_mul
    ld bc,2
    call bank6_copy
    ld de,proj_mag
    ld bc,6
    jp bank6_copy


; ----------------------------------------------------------------------------
;  order_disc_open -- start a move order at the squadron's current station
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_open:
    ;  Refused rather than opened-and-unconfirmable: a disc the player can
    ;  drive and not confirm reads as a broken ENTER key.
    call order_have_squadron
    ret nc
    call order_dest_addr                ; HL -> squad_dest[selection]
    ld de,disc_pos
    ld bc,6
    ldir
    ld a,1
    ld (disc_active),a
    ret


; ----------------------------------------------------------------------------
;  order_disc_confirm -- hand the disc position to the selected squadron
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_confirm:
    call order_have_squadron
    ret nc
    call order_dest_addr
    ex de,hl                            ; DE -> squad_dest[selection]
    ld hl,disc_pos
    ld bc,6
    ldir
    xor a
    ld (disc_active),a
    jp order_release_attack


; ----------------------------------------------------------------------------
;  order_dest_addr -- HL = &squad_dest[squad_sel]
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
order_dest_addr:
    ld a,(squad_sel)
    dec a                               ; squadrons are 1-based
    call phase4_times6
    ld de,squad_dest
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  order_disc_move -- cursor keys drive the disc across the reference plane
;
;  SHIFT swaps up/down from "away and towards" to "higher and lower", which is
;  the one piece of 3D the player has to steer by hand. The vertical line down
;  to Y=0 is what makes that legible; see order_draw_disc.
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_move:
    ;  Round the camera yaw to one of eight octants: +16 to round rather than
    ;  truncate, then take the top three bits.
    ld a,(cam_yaw)
    add a,16
    rrca
    rrca
    rrca
    rrca
    rrca
    and 7
    ld (disc_octant),a

    ld a,KEY_SHIFT
    call key_down
    jr c,@ord_vertical

    ld a,KEY_CUR_RIGHT
    call key_down
    jr nc,@ord_disc_no_right
    ld a,(disc_octant)
    call order_disc_step_plus
@ord_disc_no_right:

    ld a,KEY_CUR_LEFT
    call key_down
    jr nc,@ord_disc_no_left
    ld a,(disc_octant)
    call order_disc_step_minus
@ord_disc_no_left:

    ;  Forward is right turned a quarter turn, which in octants is +2.
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_disc_no_fwd
    ld a,(disc_octant)
    add a,2
    and 7
    call order_disc_step_plus
@ord_disc_no_fwd:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld a,(disc_octant)
    add a,2
    and 7
    jp order_disc_step_minus

@ord_vertical:
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_disc_no_rise
    call order_target_y                 ; the Y axis
    ld de,DISC_STEP
    call order_add_clamped
@ord_disc_no_rise:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    call order_target_y
    ld de,-DISC_STEP
    jp order_add_clamped


; ----------------------------------------------------------------------------
;  order_disc_step_plus / _minus -- move the disc along octant direction A
;  In : A = octant 0..7
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_step_plus:
    ld (disc_sign),a
    xor a
    ld (disc_negate),a
    jr order_disc_step

order_disc_step_minus:
    ld (disc_sign),a
    ld a,1
    ld (disc_negate),a

order_disc_step:
    ld a,(disc_sign)
    add a,a
    add a,a                             ; four bytes an entry: dx, dz
    ld l,a
    ld h,0
    ld de,order_octant_step
    add hl,de

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    push hl
    call order_maybe_negate
    ld hl,(disc_target)                 ; X
    call order_add_clamped
    pop hl

    ld e,(hl)
    inc hl
    ld d,(hl)
    call order_maybe_negate
    ld hl,(disc_target)
    ld bc,4
    add hl,bc                           ; Z
    jp order_add_clamped


;  order_target_y -- HL -> the Y word of whatever is being moved
;  Uses: AF, BC, HL
; ----------------------------------------------------------------------------
order_target_y:
    ld hl,(disc_target)
    ld bc,2
    add hl,bc
    ret


; ----------------------------------------------------------------------------
;  order_pan_toggle -- the `P` key: hand the cursor keys to the camera
;  Uses: AF, HL
; ----------------------------------------------------------------------------
order_pan_toggle:
    ld hl,pan_active
    ld a,(hl)
    xor 1
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  order_centre -- the `0` key and the menu: back to the Mothership
;
;  Clearing the pan is the whole point. Without it "centre" would put the
;  camera wherever the player had wandered to, offset from the Mothership by
;  however far they had panned -- which is exactly the state they pressed it
;  to get out of.
;  Uses: AF, B, HL
; ----------------------------------------------------------------------------
order_centre:
    ld hl,cam_pan
    ld b,6
    xor a
@ord_centre_clear:
    ld (hl),a
    inc hl
    djnz @ord_centre_clear
    ld (pan_active),a                   ; and give the cursor keys back
    jp order_select_mothership


; ----------------------------------------------------------------------------
;  DE = -DE if (disc_negate)
;  Uses: AF, DE
order_maybe_negate:
    ld a,(disc_negate)
    or a
    ret z
    ld a,e
    cpl
    ld e,a
    ld a,d
    cpl
    ld d,a
    inc de
    ret


; ----------------------------------------------------------------------------
;  order_add_clamped -- (HL) += DE, held inside +/-DISC_LIMIT
;  In : HL -> a 16-bit signed world coordinate, DE = the delta
;  Uses: AF, BC, DE, HL
;
;  Clamped rather than allowed to wrap: the world is 16-bit signed, and a disc
;  that walks off the positive edge and reappears at the negative one would be
;  a very confusing thing to have happen while you are holding a cursor key.
; ----------------------------------------------------------------------------
order_add_clamped:
    ld c,(hl)
    inc hl
    ld b,(hl)
    dec hl
    push hl
    ld h,b
    ld l,c
    add hl,de

    ;  Past the positive limit?
    ld bc,DISC_LIMIT
    ld a,h
    bit 7,a
    jr nz,@ord_check_low
    or a
    sbc hl,bc
    add hl,bc
    jr c,@ord_store                     ; below the limit
    ld hl,DISC_LIMIT
    jr @ord_store

@ord_check_low:
    ld bc,-DISC_LIMIT
    or a
    sbc hl,bc
    add hl,bc
    jr nc,@ord_store                    ; at or above the negative limit
    ld hl,-DISC_LIMIT

@ord_store:
    ex de,hl
    pop hl
    ld (hl),e
    inc hl
    ld (hl),d
    ret
