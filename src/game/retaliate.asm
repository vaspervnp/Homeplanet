; ============================================================================
;  retaliate.asm -- a squadron that is shot at shoots back
; ============================================================================
;  "Aν επιτεθεί εχθρός σε squadron, αμέσως το squadron μπαίνει σε attack mode."
;
;  Until this, a squadron holding station under fire held station: the ships
;  fired at whatever was in CBT_RANGE, but nothing closed on the attacker, so
;  a wave that came in on a formation's edge picked the ships off one by one
;  while the rest sat a formation-width away out of range -- item 3 of "A
;  fleet has to be able to concentrate", arriving without the player having
;  pressed A. Now the first hit on any ship of a squadron puts every IDLE ship
;  in it under ENT_ORDER_ATTACK with the shooter as the target, which is
;  exactly what `A` with that target picked would have written. Everything
;  downstream is the attack order's own machinery: cbt_move_enemies closes
;  them, cbt_fire_if_able re-acquires when the shooter dies and SPENDS the
;  order when nothing is left, so the squadron comes home by itself.
;
;  Only IDLE ships. A harvester keeps mining and a corvette keeps towing --
;  an `R` that emptied the fields each time a shot landed would stop the
;  economy, which is the same argument order_release_attack makes -- a GUARD
;  ship was told to hold and holds, and a ship already ATTACKING keeps the
;  target the player or a previous hit gave it. The Mothership is never
;  ordered: its ENT_SQUAD is SQUAD_NONE and the victim's squadron is never
;  that, so the compare excludes it for nothing. And a hit ON the Mothership
;  answers nothing, for the same reason the orders that tell a squadron where
;  to be do not apply to it: it is not a squadron. The fleet defends it by
;  being stationed on it.
;
;  Not in the tutorial. Step 14 is the lesson that `A` attacks, and a stage
;  that gave the order for the player would be teaching a key that was never
;  pressed.
;
;  IN BANK 4, called from the low 16K's cbt_fire_if_able -- legal by the
;  narrow rule, because nothing pages bank 4 out during the simulation. It
;  runs once per HIT on a friendly ship, not per frame, and a 56-slot walk at
;  ~60 T a slot is ~3,400 T -- a hit costs a snd_fire and a damage lookup
;  already, and hits are rate-limited by CBT_COOLDOWN per shooter.
;
;  THE SHOOTER'S SLOT IS ARITHMETIC ON cbt_index, which counts DOWN from
;  ENT_MAX and is decremented after the slot is done, so while cbt_ent is
;  slot k it reads ENT_MAX - k. That is the only thing here that reaches into
;  cbt_update's loop state; the assert below is its guard.
; ----------------------------------------------------------------------------

    assert ENT_SQUAD == ENT_FLAGS + 1, "the walk below steps FLAGS -> SQUAD with an INC"
    assert ENT_ORDER == ENT_SQUAD + 1, "the walk below steps SQUAD -> ORDER with an INC"
    assert ENT_TARGET == ENT_ORDER + 1, "the walk below steps ORDER -> TARGET with an INC"
    assert ENT_F_ENEMY == %00000010, "cbt_retaliate tests bit 1 for ENEMY"
    assert ENT_ORDER_IDLE == 0, "cbt_retaliate tests IDLE with OR A"
    assert SQUAD_NONE == 0, "cbt_retaliate tests SQUAD_NONE with OR A"

; ----------------------------------------------------------------------------
;  cbt_retaliate -- (cbt_ent) has just hit (cbt_target): answer it
;  In : (cbt_ent) = the shooter's record, (cbt_target) = the victim's slot,
;       (cbt_index) = cbt_update's countdown for the shooter
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_retaliate:
    ld a,(tut_active)
    or a
    ret nz

    ld hl,(cbt_ent)
    ld de,ENT_FLAGS
    add hl,de
    bit 1,(hl)                          ; ENT_F_ENEMY
    ret z                               ; our own shot: nothing to answer

    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    or a
    ret z                               ; SQUAD_NONE: the Mothership
    ld c,a                              ; the squadron that was hit

    ld a,(cbt_index)
    neg
    add a,ENT_MAX                       ; the shooter's slot
    ld (cbt_avenge),a

    ld hl,entities + ENT_FLAGS
    ld b,ENT_PLAYER_MAX
    ld de,ENT_SIZE - 2                  ; ORDER of this record -> FLAGS of the next
@cbt_ret_slot:
    ld a,(hl)
    and ENT_F_ACTIVE | ENT_F_DISABLED
    cp ENT_F_ACTIVE
    inc hl                              ; SQUAD -- 16-bit INC leaves the flags alone
    jr nz,@cbt_ret_empty
    ld a,(hl)
    cp c
    inc hl                              ; ORDER
    jr nz,@cbt_ret_next
    ld a,(hl)
    or a
    jr nz,@cbt_ret_next                 ; working, holding or already attacking
    ld (hl),ENT_ORDER_ATTACK
    inc hl                              ; TARGET
    ld a,(cbt_avenge)
    ld (hl),a
    dec hl
    jr @cbt_ret_next
@cbt_ret_empty:
    inc hl                              ; ...so every path leaves HL at ORDER
@cbt_ret_next:
    add hl,de
    djnz @cbt_ret_slot
    ret
