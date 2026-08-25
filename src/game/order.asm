; ============================================================================
;  game/order.asm -- camera control and the move disc (Homeplanet.md section 9)
; ============================================================================
;  Controlling a 3D fleet from a keyboard is the hardest part of the design.
;  The answer the document settles on is orders PER SQUADRON, never per ship,
;  and a cursor that moves on the Y=0 reference plane with a vertical line
;  showing its height -- Homeworld's move disc, which costs about twenty
;  pixels to draw.
;
;  Key assignment
;  --------------
;  Section 9 puts the move order on `M` and docking on `D`, but those keys now
;  belong to the squadron commands. So:
;
;      ENTER   open the move disc; ENTER again confirms, ESC cancels
;      R       return to the Mothership (was `D`)
;
;  ENTER doing both the opening and the confirming is not a compromise: the
;  document already had it as the confirm key, and a mode you enter and leave
;  with the same key is one less thing to remember.
;
;  While the disc is open the cursor keys drive IT, not the camera. That is
;  the document's intent and it is why the disc is a mode at all.
;
;  Disc movement is camera-relative, so "up" always means away from you. The
;  camera's yaw is rounded to one of eight octants and the step vector comes
;  out of a table -- no multiplies, and at 45 degrees of granularity the
;  difference from a true rotation is not perceptible on a 320-pixel screen.
; ----------------------------------------------------------------------------

CAM_YAW_STEP        equ 8               ; 256/8 = the 32 yaw steps of section 4.3
CAM_PITCH_STEP      equ 4               ; 16 steps
CAM_PITCH_MAX       equ 53              ; +/-75 degrees

DISC_STEP           equ 1600            ; world units per frame held
DISC_STEP_DIAG      equ 1131            ; the same length at 45 degrees
DISC_LIMIT          equ 30000           ; keep well inside the 16-bit world

;  Ink used to draw the disc and its height line.
DISC_INK_TOP        equ 1               ; the disc itself: friendly white
DISC_INK_STEM       equ 2               ; the line down to the plane


; ----------------------------------------------------------------------------
;  order_init -- give every squadron a starting station
;  Uses: everything
; ----------------------------------------------------------------------------
order_init:
    ld hl,order_home
    ld de,squad_dest
    ld bc,SQUAD_MAX * 6
    ldir
    xor a
    ld (disc_active),a
    ld (order_paused),a
    ld (sel_mothership),a
    ld (view_sensors),a
    ld a,ORDER_NO_TARGET
    ld (order_target),a
    ld a,1
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
    call order_camera
    jr @ord_shared
@ord_disc_has_cursors:
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
    call c,order_select_mothership

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

    ld a,KEY_B
    call key_hit
    jr nc,@ord_no_build
    ld hl,eco_build_open
    ld a,(hl)
    xor 1
    ld (hl),a
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
    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0
    push hl
    call order_dest_addr
    ex de,hl
    pop hl
    ld bc,6
    ldir
    ret


; ----------------------------------------------------------------------------
;  order_target_step -- `,` and `.` walk the target through live entities
;  In : A = +1 to go forward, -1 to go back
;  Out: (order_target) = an active entity index, or ORDER_NO_TARGET
;  Uses: everything
;
;  Wraps, and skips empty slots, so the player never has to know that the
;  entity table is sparse.
; ----------------------------------------------------------------------------
ORDER_NO_TARGET     equ #FF

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
    call ent_is_active
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
    ret


; ----------------------------------------------------------------------------
;  order_select_mothership -- the `0` key
;  Uses: AF
; ----------------------------------------------------------------------------
order_select_mothership:
    ld a,1
    ld (sel_mothership),a
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
;  order_zoom -- Z closer, X further, four steps (section 4.3)
;  Uses: everything
; ----------------------------------------------------------------------------
order_zoom:
    ld a,KEY_Z
    call key_hit
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
    ret nc
    ld hl,cam_zoom
    ld a,(hl)
    cp CAM_ZOOM_STEPS - 1
    ret nc
    inc (hl)
    ; fall through

; ----------------------------------------------------------------------------
;  order_apply_zoom -- cam_dist = cam_zoom_dist[cam_zoom]
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
order_apply_zoom:
    ld a,(cam_zoom)
    add a,a                             ; a table of words
    ld l,a
    ld h,0
    ld de,cam_zoom_dist
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (cam_dist),de
    ret


; ----------------------------------------------------------------------------
;  order_disc_open -- start a move order at the squadron's current station
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_open:
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
    call order_dest_addr
    ex de,hl                            ; DE -> squad_dest[selection]
    ld hl,disc_pos
    ld bc,6
    ldir
    xor a
    ld (disc_active),a
    ret


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
    ld hl,disc_pos + 2                  ; the Y axis
    ld de,DISC_STEP
    call order_add_clamped
@ord_disc_no_rise:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld hl,disc_pos + 2
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
    ld hl,disc_pos + 0                  ; X
    call order_add_clamped
    pop hl

    ld e,(hl)
    inc hl
    ld d,(hl)
    call order_maybe_negate
    ld hl,disc_pos + 4                  ; Z
    jp order_add_clamped


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


; ============================================================================
;  State
; ============================================================================

;  Where each squadron is stationed. A move order rewrites the entry for the
;  selected squadron and the formation follows, so this is the ONLY thing an
;  order changes -- no per-ship destinations to keep in step.
squad_dest:         defs SQUAD_MAX * 6, 0

disc_active:        defb 0
disc_pos:           defs 6, 0
disc_octant:        defb 0
disc_sign:          defb 0
disc_negate:        defb 0

order_paused:       defb 0

;  Set when the player has selected the Mothership with `0` rather than a
;  squadron. Kept separate from squad_sel: the Mothership is not squadron
;  zero, it is not in a squadron at all.
sel_mothership:     defb 0

;  0 = the tactical view, 1 = sensors.
view_sensors:       defb 0
VIEW_FAST_FORWARD   equ 3               ; simulation steps per frame in sensors

;  Which entity `,` and `.` have walked to, and the order waiting to be
;  written into the squadron's records.
order_target:       defb ORDER_NO_TARGET
order_step:         defb 0
order_pending:      defb 0
order_index:        defb 0
moth_slot:          defb 0

;  Where the Mothership sits. It does not fly to formations; the fleet forms
;  up around it.
order_mothership_pos:
    defw 0, 0, 0

;  The camera's "right" direction on the Y=0 plane, per octant of yaw, already
;  scaled to one frame's movement. Forward is the entry two octants on.
order_octant_step:
    defw  DISC_STEP,           0
    defw  DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw  0,                   DISC_STEP
    defw -DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw -DISC_STEP,           0
    defw -DISC_STEP_DIAG,     -DISC_STEP_DIAG
    defw  0,                  -DISC_STEP
    defw  DISC_STEP_DIAG,     -DISC_STEP_DIAG

;  Starting stations. Squadron 1 sits in the middle of the battle and the rest
;  fan out around it, spread in Z as well as X so ships sit at genuinely
;  different depths and so at different sprite tiers.
order_home:
    defw      0,  2000,      0           ; 1
    defw -18000, -3000,   8000           ; 2
    defw  18000,  3000,  -8000           ; 3
    defw -12000, -2000,  16000           ; 4
    defw  12000,  2500, -16000           ; 5
    defw  -6000, -3000, -12000           ; 6
    defw   6000,  2000,  12000           ; 7
    defw -24000, -2500,   4000           ; 8
    defw  24000,  3000,  -4000           ; 9
