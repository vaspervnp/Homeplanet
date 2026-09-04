; ============================================================================
;  retaliate.asm -- AUTO RESPONSE: a squadron that is shot at shoots back, once
; ============================================================================
;  "Aν επιτεθεί εχθρός σε squadron, αμέσως το squadron μπαίνει σε attack mode."
;  ...and then: "Η αυτόματη επίθεση να είναι μπόνους και να μπορεί να
;  χρησιμοποιηθεί μόνο μία φορά με το Α, όπως η απλή επίθεση, σε κάθε πίστα."
;
;  So it is a BONUS, armed by the player and spent by the enemy. Press A with
;  nothing hostile flying and, if the mission's one response is still unused,
;  it is ARMED and the HUD's message row says AUTO RESPONSE ON; the first hit
;  an enemy then lands on any ship of a squadron puts every IDLE ship in that
;  squadron under ENT_ORDER_ATTACK with the shooter as the target -- byte for
;  byte what `A` with that target picked would have written -- and the
;  response is USED for the rest of the mission. Press A with nothing hostile
;  flying after that and the row says AUTO RESPONSE USED. With something
;  hostile flying, A is the attack order it has always been, and nothing here
;  is consulted. mis_setup clears both flags, so "once a mission" is true by
;  construction.
;
;  "In battle" is mis_count_hostiles, the same predicate the jump gate and
;  the repair ask: wave ships count, wrecks do not.
;
;  Everything downstream of the response is the attack order's own machinery:
;  cbt_move_enemies closes the squadron, cbt_fire_if_able re-acquires when the
;  shooter dies and SPENDS the order when nothing is left, so it comes home by
;  itself. Only IDLE ships -- a harvester keeps mining, a corvette keeps
;  towing, a GUARD ship holds, a ship already attacking keeps its target. The
;  Mothership is never ordered (its ENT_SQUAD is SQUAD_NONE and the victim's
;  squadron never is) and a hit ON the Mothership answers nothing: it is not a
;  squadron. Not in the tutorial, where step 14 teaches that A attacks.
;
;  IN BANK 4, called from the low 16K's cbt_fire_if_able -- legal by the
;  narrow rule, because nothing pages bank 4 out during the simulation -- and
;  from order_update's A. The armed check is the first thing cbt_retaliate
;  does, so on every hit of an ordinary mission it is a load and a RET.
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
    ld a,(auto_armed)
    or a
    ret z                               ; not armed: the ordinary game
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
    ;  ...and the response is SPENT by the first ship it orders. Not on the
    ;  hit: a hit on a squadron with nothing idle in it would use the bonus
    ;  up for nothing.
    xor a
    ld (auto_armed),a
    inc a
    ld (auto_used),a
    jr @cbt_ret_next
@cbt_ret_empty:
    inc hl                              ; ...so every path leaves HL at ORDER
@cbt_ret_next:
    add hl,de
    djnz @cbt_ret_slot
    ret


; ----------------------------------------------------------------------------
;  order_attack_key -- A: the attack order in a fight, the bonus out of one
;  Out: CF set if the attack order should NOT be issued (handled here)
;  Uses: everything
;
;  Out of a fight there is nothing to attack, so A is the bonus's key: it arms
;  the response and says so, or says it has been used. In a fight it is the
;  attack order and this returns with carry clear before touching anything.
; ----------------------------------------------------------------------------
order_attack_key:
    call mis_count_hostiles
    or a
    ret nz                              ; in a fight: A attacks, as always (CF clear)
    ld a,(auto_used)
    or a
    ld a,WAVE_MSG_AUTO_USED
    jr nz,@auto_say
    ld a,1
    ld (auto_armed),a
    ld a,WAVE_MSG_AUTO_ON
@auto_say:
    ld (wave_msg),a
    ld a,WAVE_SAY_FRAMES
    ld (wave_say),a
    scf
    ret


; ----------------------------------------------------------------------------
;  cbt_prey_roll -- this frame's coin: does the unarmed bias apply?
;  Uses: AF, HL
;
;  "make enemies attack unarmed ships 50% of the time." cbt_prey_bias pushes a
;  harvester or a corvette CBT_UNARMED_BIAS further off than it is, so an
;  escort in reach takes the shot; that made the miners safe as long as
;  anything armed was near, which was the whole design and then too much of
;  it. The mask is one bit of sys_rand widened to a byte, and the search ANDs
;  the class's bias with it. Once a frame from cbt_update, in bank 4 because
;  the low 16K had eleven bytes of slack and the call is three of them.
; ----------------------------------------------------------------------------
cbt_prey_roll:
    call sys_rand
    rlca                                ; bit 7 into the carry
    sbc a,a                             ; #FF if it was set, 0 if not
    ld (cbt_prey_mask),a
    ret
