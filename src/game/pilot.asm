; ============================================================================
;  game/pilot.asm -- V: fly one ship yourself (future.md item 1), in bank 4
; ============================================================================
;  Press V on a selected squadron and its lead ship -- the first one flying,
;  in slot order -- is yours: the cursor keys steer it, SPACE fires its gun,
;  the camera rides behind it, and the rest of the squadron goes on doing what
;  it was ordered to. V again, or the ship's death, hands it back.
;
;  IT IS AN ENTITY LIKE ANY OTHER, under an order the AI does not own. That is
;  the whole design: ENT_ORDER_PILOT is one more value phase4_fly steps over --
;  the same skip a harvester, a tow and an attack already get -- so nothing
;  drags it back to its formation slot; cbt_move_enemies only ever moves the
;  enemy and ATTACK, so nothing closes it on a target; cbt_retarget_one keeps
;  giving it the nearest hostile, which is what a pilot's auto-aim wants; and
;  cbt_fire_if_able is what actually fires, so the gun, the cooldown and the
;  damage matrix are the ship's own.
;
;  WHICH WAY IS FORWARD. tools/mkships.py renders view 0 nose-on and view 90
;  degrees "broadside-to-the-right", and the camera matrix is Rx(pitch).Ry(yaw)
;  with the view axis at cam_yaw c along world (-sin c, cos c). Put together, a
;  ship with ENT_YAW y has its nose along world (sin y, -cos y), whatever the
;  camera is doing -- and a camera at y + 128 looks along exactly that vector,
;  which is what a chase camera IS. So the yaw view drawn is 3, tail-on, and
;  LEFT is yaw INCREASING: at view 3 the nose swings to camera -x as the view
;  angle grows. (order_camera's LEFT takes cam_yaw the other way; that is an
;  orbit, and the world swinging right as you turn left is what turning left
;  looks like from behind.)
;
;  THE GUN IS HELD BY ITS OWN COOLDOWN. cbt_fire_if_able fires when ENT_TIMER
;  is zero, so the pilot writes a 1 into a timer that has reached zero and the
;  battle's own decrement takes it back to zero by the next frame -- the ship
;  is always ready and never fires. SPACE leaves the zero where it is for one
;  frame, and the ship fires if anything hostile is in range, exactly as it
;  would have on its own. A real cooldown after a shot counts down untouched,
;  so hammering SPACE is one shot per CBT_COOLDOWN: the pilot picks the fight,
;  the gun is the gun.
;
;  WHAT V DOES NOT DO. It does not pause -- SPACE is the trigger while a ship
;  is being flown, and pausing means V first, which the bar says. It refuses
;  the Mothership, which holds station and is not a squadron, and it refuses
;  the tutorial, which teaches SPACE as the pause. It is ended by pilot_end
;  before a jump saves the fleet, or fleet_save would carry the order into a
;  mission whose slots have been packed down and pilot_slot would name a ship
;  that is not the one -- "never trust a slot index", the third time.
; ----------------------------------------------------------------------------

;  256ths of a turn per frame a cursor key is held: a full circle in about six
;  seconds at the measured seven frames a second.
PILOT_TURN          equ 6
;  HALF the distance flown a frame, because cam_mul7's product has to stay
;  inside a signed byte and 127 * 150 does not. 200 a frame against
;  PHASE4_STEP's 150: a pilot flies harder than the autopilot, which is what
;  makes flying it worth the player's hands -- it can pick, and leave, a fight
;  the AI would have to sit in.
PILOT_STEP_HALF     equ 100
;  Height per frame UP or DOWN is held: the world is planar and a wave's band
;  is a few hundred units either side of it (WAVE_RISE), so this is enough.
PILOT_CLIMB         equ 100
;  What the timer is parked at while the pilot's finger is off the trigger.
PILOT_HOLD          equ 1
;  How close, in camera units, is a collision: 4 is 256 world units. The two
;  close at up to 350 a frame, so anything smaller could pass through a ship
;  between one frame and the next.
PILOT_RAM_DIST      equ 4


; ----------------------------------------------------------------------------
;  pilot_toggle -- the V key
;  Uses: everything
; ----------------------------------------------------------------------------
pilot_toggle:
    ld a,(tut_active)
    or a
    ret nz                              ; the stage teaches SPACE as the pause
    ld a,(pilot_slot)
    cp ENT_MAX
    jr c,pilot_end                      ; flying one already: hand it back
    call order_have_squadron
    ret nc                              ; the Mothership is not flown

    ;  The lead ship: the first flying one of the selection, walking the
    ;  flags byte the way wave_health does, with the squadron beside it.
    assert ENT_SQUAD == ENT_FLAGS + 1, "pilot_toggle reads the squadron with an INC"
    ld hl,entities + ENT_FLAGS
    ld c,0                              ; the slot
    ld b,ENT_PLAYER_MAX
@pilot_find:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    jr nz,@pilot_next
    inc hl
    ld a,(squad_sel)
    cp (hl)
    dec hl
    jr nz,@pilot_next

    ld a,c
    ld (pilot_slot),a
    ld de,ENT_ORDER - ENT_FLAGS
    add hl,de
    ld (hl),ENT_ORDER_PILOT
    ret

@pilot_next:
    ld de,ENT_SIZE
    add hl,de
    inc c
    djnz @pilot_find
    ret                                 ; nothing flying in it: nothing happens


; ----------------------------------------------------------------------------
;  pilot_end -- hand the ship back to its squadron
;  Uses: AF, DE, HL
;
;  IDLE and not GUARD, for the reason cbt_fire_if_able gives where it spends
;  an attack order: IDLE is the state the fleet starts in, and phase4_fly flies
;  an idle ship home. Only if the order is still PILOT -- the frame V was
;  pressed in may also have given it A or G, and those are the player's.
;  Safe to call when nothing is being flown, which is how mis_jump_now and
;  pilot_frame's "is it still there" both use it.
; ----------------------------------------------------------------------------
pilot_end:
    ld a,(pilot_slot)
    cp ENT_MAX
    ret nc
    call ent_addr
    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_PILOT
    jr nz,@pilot_end_slot
    ld (hl),ENT_ORDER_IDLE
@pilot_end_slot:
    ld a,ENT_NO_TARGET
    ld (pilot_slot),a
    ret


; ----------------------------------------------------------------------------
;  pilot_frame -- once a game frame while a ship is being flown
;  Uses: everything
;
;  From order_update, in the slot the cursor keys' owner takes -- so it runs
;  BEFORE phase4_fly and cbt_update, which is what lets the order be
;  re-asserted under whatever A, G, R or H wrote this frame and the timer be
;  parked before the battle looks at it. And it runs while the game is paused,
;  as every order does: the camera still rides the ship, and the ship itself
;  holds still with the rest of the battle.
; ----------------------------------------------------------------------------
pilot_frame:
    ld a,(pilot_slot)
    call ent_addr
    ld (pilot_ent),hl

    ;  Still ours, still flying? A death frees the slot and a recycle does
    ;  too, and the camera then falls back to the squadron's station.
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    jr nz,pilot_end

    ;  The order, again. order_issue writes A and G into every active ship of
    ;  the selection and this one is in it; one frame under ATTACK is a step
    ;  towards its target, which is harmless, and re-asserting is cheaper
    ;  than teaching four order routines to step over a slot.
    ld de,ENT_ORDER - ENT_FLAGS
    add hl,de
    ld (hl),ENT_ORDER_PILOT

    ld a,(order_paused)
    or a
    jp nz,@pilot_camera                 ; frozen with the battle: only the camera

    ; --- steer ------------------------------------------------------------
    ld a,KEY_CUR_LEFT
    call key_down                       ; AF, HL -- so HL is reloaded below
    jr nc,@pilot_no_left
    ld hl,(pilot_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    add a,PILOT_TURN
    ld (hl),a
@pilot_no_left:
    ld a,KEY_CUR_RIGHT
    call key_down
    jr nc,@pilot_no_right
    ld hl,(pilot_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    sub PILOT_TURN
    ld (hl),a
@pilot_no_right:

    ; --- fly: always forward, along (sin y, -cos y) ------------------------
    ld hl,(pilot_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    push af
    ld hl,(pilot_ent)                   ; ENT_X is offset 0
    call pilot_along                    ; x += step * sin y
    pop af
    add a,TRIG_QUARTER * 3              ; sin(y + 192) is -cos y
    ld hl,(pilot_ent)
    ld de,ENT_Z
    add hl,de
    call pilot_along                    ; z -= step * cos y

    ; --- ramming ------------------------------------------------------------
    ;  Into a hostile, and both pay the pilot's hull: future.md item 7. It is
    ;  how a fighter kills a frigate it cannot outgun, and it costs the ship.
    call pilot_ram
    ret c                               ; ...it did: there is nothing left to fly

    ; --- climb and dive ---------------------------------------------------
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@pilot_no_up
    ld hl,(pilot_ent)
    ld de,ENT_Y
    add hl,de
    ld de,PILOT_CLIMB
    call order_add_clamped
@pilot_no_up:
    ld a,KEY_CUR_DOWN
    call key_down
    jr nc,@pilot_no_down
    ld hl,(pilot_ent)
    ld de,ENT_Y
    add hl,de
    ld de,-PILOT_CLIMB
    call order_add_clamped
@pilot_no_down:

    ; --- the trigger --------------------------------------------------------
    ;  See the header: a zero timer is a ready gun, and it is left at zero
    ;  for the one frame SPACE is down so the battle fires it.
    ld hl,(pilot_ent)
    ld de,ENT_TIMER
    add hl,de
    ld a,(hl)
    or a
    jr nz,@pilot_camera                 ; cooling down: the clock has it
    push hl
    ld a,KEY_SPACE
    call key_hit
    pop hl
    jr c,@pilot_camera                  ; fire: cbt_fire_if_able sees the zero
    ld (hl),PILOT_HOLD

    ; --- the camera, behind it ------------------------------------------------
@pilot_camera:
    ld hl,(pilot_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    add a,TRIG_STEPS / 2                ; view 3: tail-on, looking where it looks
    ld (cam_yaw),a
    ret


; ----------------------------------------------------------------------------
;  pilot_ram -- is the flown ship inside PILOT_RAM_DIST of a hostile?
;  Out: CF set if it was, and the collision has happened: both hulls have
;       paid, the dead are dead, and the ship has been handed back
;  Uses: everything
;
;  Only the hostile region, and only a hostile that is FLYING: a wreck is a
;  hull adrift and the derelict is one for three missions, and flying into
;  either would be a cheap way to lose a ship. The enemy takes the pilot's
;  hull off its own, whole or not at all, and the pilot's hull goes to zero:
;  the damage is what the ship had, so a fresh ship is the heavier weapon.
; ----------------------------------------------------------------------------
pilot_ram:
    ld hl,entities + ENT_PLAYER_MAX * ENT_SIZE
    ld (pilot_scan),hl
    ld a,ENT_PLAYER_MAX
    ld (pilot_scan_slot),a
    ld b,ENT_ENEMY_MAX
@pilot_ram_one:
    push bc
    ld hl,(pilot_scan)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED
    cp ENT_F_ACTIVE + ENT_F_ENEMY
    jr nz,@pilot_ram_next
    ld de,(pilot_scan)
    ld hl,(pilot_ent)
    call dist_manhattan                 ; A = how far, in camera units
    cp PILOT_RAM_DIST
    jr c,@pilot_crash
@pilot_ram_next:
    ld hl,(pilot_scan)
    ld de,ENT_SIZE
    add hl,de
    ld (pilot_scan),hl
    ld hl,pilot_scan_slot
    inc (hl)
    pop bc
    djnz @pilot_ram_one
    or a                                ; CF clear: nothing hit
    ret

@pilot_crash:
    pop bc
    ;  The hostile takes the pilot's hull...
    ld hl,(pilot_ent)
    ld de,ENT_HULL
    add hl,de
    ld b,(hl)
    ld hl,(pilot_scan)
    add hl,de
    ld a,(hl)
    sub b
    jr c,@pilot_ram_kills
    jr z,@pilot_ram_kills
    ld (hl),a
    jr @pilot_ram_me
@pilot_ram_kills:
    ld (hl),0
    ld a,(pilot_scan_slot)
    call cbt_kill                       ; the explosion, the count, a wreck maybe
@pilot_ram_me:
    ;  ...and the pilot's ship is gone: hull to zero and the same exit every
    ;  other death takes, so the explosion and the sound are the usual ones.
    ld a,(pilot_slot)
    call ent_addr
    ld de,ENT_HULL
    add hl,de
    ld (hl),0
    ld a,(pilot_slot)
    call cbt_kill
    call pilot_end                      ; the camera goes back to the station
    scf
    ret


; ----------------------------------------------------------------------------
;  pilot_along -- (HL) += 2 * ((sin A * PILOT_STEP_HALF) >> 7), clamped
;  In : A = an angle in 256ths of a turn, HL -> a world coordinate
;  Uses: everything
;
;  cam_mul7 is a signed byte times a signed byte, so the step is carried as a
;  half and doubled after: a full step of 200 is 127 * 200 = 25400, whose
;  double does not fit the sixteen bits cam_mul7 shifts through.
;  order_add_clamped is the disc's own add, and it holds the ship inside
;  DISC_LIMIT the way it holds the disc -- a ship flown off the edge of a
;  16-bit world would come back in on the other side.
; ----------------------------------------------------------------------------
pilot_along:
    push hl
    call cam_sin                        ; A = sin, -127..127
    ld b,a
    ld c,PILOT_STEP_HALF
    call cam_mul7                       ; A = (sin * half) >> 7
    ld l,a
    rla
    sbc a,a
    ld h,a                              ; HL = A, sign-extended
    add hl,hl                           ; ...doubled: the whole step
    ex de,hl
    pop hl
    jp order_add_clamped
