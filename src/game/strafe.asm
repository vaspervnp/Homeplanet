; ============================================================================
;  game/strafe.asm -- W: a strafing run (future.md item 3), in bank 4
; ============================================================================
;  `A` is a commitment: the squadron closes on its target and stays there
;  until nothing is left to shoot at. `W` is a PASS: the armed ships of the
;  selection close, fire for CBT_STRAFE_FRAMES frames of contact, and then
;  the order spends itself and phase4_fly takes them home -- hit and withdraw,
;  which is a tactic rather than a commitment, and it is what lets the balance
;  triangle's "hit the frigate with the bombers and get out" be said in one
;  key.
;
;  IT IS THE ATTACK ORDER WITH A BUDGET. ENT_ORDER_STRAFE sits above HARVEST,
;  so phase4_fly steps over it; cbt_move_enemies closes it exactly as it
;  closes ATTACK; cbt_retarget_one is allowed to re-point it, because a pass
;  hits whatever is nearest and that is the point of a pass; and
;  cbt_fire_if_able spends it when nothing is left, as it spends ATTACK. The
;  budget is ENT_LOAD -- a fighter has no hold -- and it counts down only on
;  frames the ship is IN RANGE of its target: the flight out is not the run.
;
;  ONLY ARMED SHIPS. A harvester or a corvette in the selection keeps doing
;  what it was doing: cbt_prey_bias is nonzero for exactly the classes that
;  cannot fight, so that table is the test, and a miner's hold (which IS
;  ENT_LOAD) is never overwritten by a budget.
; ----------------------------------------------------------------------------

;  Frames of contact before the run is over: four volleys at CBT_COOLDOWN 6.
CBT_STRAFE_FRAMES   equ 24


; ----------------------------------------------------------------------------
;  order_strafe -- the W key
;  Uses: everything
; ----------------------------------------------------------------------------
order_strafe:
    ld a,(tut_active)
    or a
    ret nz                              ; the stage teaches A; W is not on it
    call order_have_squadron
    ret nc
    ld hl,entities + ENT_FLAGS
    ld b,ENT_PLAYER_MAX
@strafe_one:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    jr nz,@strafe_next
    inc hl                              ; ENT_SQUAD, next door
    ld a,(squad_sel)
    cp (hl)
    dec hl
    jr nz,@strafe_next
    ;  Armed? ENT_CLASS is two below ENT_FLAGS.
    dec hl
    dec hl
    ld a,(hl)
    inc hl
    inc hl
    push hl
    push bc
    ld c,a
    ld b,0
    ld hl,cbt_prey_bias
    add hl,bc
    ld a,(hl)
    pop bc
    pop hl
    or a
    jr nz,@strafe_next                  ; unarmed: it keeps its own order
    push hl
    ld de,ENT_ORDER - ENT_FLAGS
    add hl,de
    ld (hl),ENT_ORDER_STRAFE
    ld de,ENT_LOAD - ENT_ORDER
    add hl,de
    ld (hl),CBT_STRAFE_FRAMES
    pop hl
@strafe_next:
    ld de,ENT_SIZE
    add hl,de
    djnz @strafe_one
    ret


; ----------------------------------------------------------------------------
;  strafe_tick -- once a frame, from the top of cbt_update: spend the budgets
;  Uses: everything
;
;  Walks the player's region for ships under STRAFE with a target, and takes a
;  frame off the budget of each one that is in range of it. At zero the order
;  is IDLE -- spent, not replaced, for the reason cbt_fire_if_able gives --
;  and phase4_fly flies the ship home on the next frame. cbt_ent and
;  cbt_target are combat's own scratch and are free here: this runs before
;  the loop that owns them.
; ----------------------------------------------------------------------------
strafe_tick:
    ld hl,entities
    ld (strafe_walk),hl
    ld a,ENT_PLAYER_MAX
    ld (strafe_left),a
@strafe_tick_one:
    ld hl,(strafe_walk)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    jr nz,@strafe_tick_next
    ld de,ENT_ORDER - ENT_FLAGS
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_STRAFE
    jr nz,@strafe_tick_next
    inc hl                              ; ENT_TARGET
    ld a,(hl)
    cp ENT_MAX
    jr nc,@strafe_tick_next             ; nothing picked yet: the flight out
    ld (cbt_target),a
    ld hl,(strafe_walk)
    ld (cbt_ent),hl
    call cbt_target_flying
    jr nc,@strafe_tick_next
    call cbt_in_range
    jr nc,@strafe_tick_next             ; closing: the run has not begun
    ld hl,(strafe_walk)
    ld de,ENT_LOAD
    add hl,de
    dec (hl)
    jr nz,@strafe_tick_next
    ld de,ENT_ORDER - ENT_LOAD
    add hl,de
    ld (hl),ENT_ORDER_IDLE              ; the pass is over: home
@strafe_tick_next:
    ld hl,(strafe_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (strafe_walk),hl
    ld hl,strafe_left
    dec (hl)
    jr nz,@strafe_tick_one
    ret
