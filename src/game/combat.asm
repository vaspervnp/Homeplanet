; ============================================================================
;  game/combat.asm -- firing, damage, death and explosions
; ============================================================================
;  Homeplanet.md phase 6: "Πρώτη πραγματική σύγκρουση στόλων".
;
;  Every active ship with a target that is in range and a cooldown at zero
;  fires. A hit takes hull off the target; a hull that runs out clears the
;  entity's active flag and leaves an explosion behind. That is the whole
;  loop -- there are no projectiles in flight, because at 12.5 fps and these
;  ranges a shot would arrive the same frame it left.
;
;  Range is Manhattan distance on the coordinates AFTER a >>8, i.e. on the
;  same +/-128 scale the projection works in. A true distance needs three
;  multiplies and a square root per pair; the sum of the absolute differences
;  costs about thirty T-states and is wrong by at most the usual sqrt(3)
;  factor, which for "is it close enough to shoot" nobody can see.
;
;  Retargeting is round-robin: ONE entity picks a new target per frame. The
;  full search is O(n) over 48 slots, and doing it for everybody every frame
;  would be 48 x 48. A ship keeps its target until it dies or drifts out of
;  range, so the staleness is never visible.
; ----------------------------------------------------------------------------

CBT_RANGE           equ 40              ; camera-scale units, so ~10000 world
CBT_COOLDOWN        equ 6               ; frames between shots
CBT_DAMAGE          equ 24              ; hull points a hit takes off

;  Explosions live for a few frames and grow as they go.
EXPL_MAX            equ 6
EXPL_SIZE           equ 7               ; x, y, z (6) + timer
EXPL_LIFE           equ 6


; ----------------------------------------------------------------------------
;  cbt_init -- no explosions, nobody shooting
;  Uses: AF, B, HL
; ----------------------------------------------------------------------------
cbt_init:
    ld hl,cbt_explosions
    ld b,EXPL_MAX * EXPL_SIZE
    xor a
@cbt_clear:
    ld (hl),a
    inc hl
    djnz @cbt_clear
    ld (cbt_retarget),a
    ld (cbt_kills),a
    ld (cbt_shots),a
    ret


; ----------------------------------------------------------------------------
;  cbt_update -- one frame of combat
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_update:
    call cbt_age_explosions
    call cbt_retarget_one

    xor a
    ld (cbt_index),a
@cbt_ship:
    ld a,(cbt_index)
    call ent_addr
    ld (cbt_ent),hl

    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@cbt_next

    call cbt_fire_if_able

@cbt_next:
    ld hl,cbt_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@cbt_ship
    ret


; ----------------------------------------------------------------------------
;  cbt_fire_if_able -- one ship's turn
;  In : (cbt_ent) -> the shooter
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_fire_if_able:
    ;  Cooldown first: it ticks whether or not there is anything to shoot at.
    ld hl,(cbt_ent)
    ld de,ENT_TIMER
    add hl,de
    ld a,(hl)
    or a
    jr z,@cbt_ready
    dec (hl)
    ret

@cbt_ready:
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(hl)
    cp ENT_MAX
    ret nc                              ; nothing targeted
    ld (cbt_target),a

    call ent_is_active
    ret nc                              ; the target is already wreckage

    call cbt_hostile
    ret nc                              ; never shoot your own side

    call cbt_in_range
    ret nc

    ;  Fire.
    ld hl,(cbt_ent)
    ld de,ENT_TIMER
    add hl,de
    ld (hl),CBT_COOLDOWN

    ld hl,cbt_shots
    inc (hl)
    call snd_fire

    ;  Damage.
    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_HULL
    add hl,de
    ld a,(hl)
    sub CBT_DAMAGE
    jr c,@cbt_destroyed
    or a
    jr z,@cbt_destroyed
    ld (hl),a
    jp snd_hit

@cbt_destroyed:
    ld (hl),0
    ld a,(cbt_target)
    jp cbt_kill


; ----------------------------------------------------------------------------
;  cbt_hostile -- are (cbt_ent) and (cbt_target) on opposite sides?
;  Out: CF set if they are
;  Uses: everything
;
;  Checked at the moment of firing, not only when a target is chosen. A slot
;  index is just a number: a stale one, a recycled one, or a zeroed field on a
;  freshly spawned ship all name SOMETHING, and without this the fleet opens
;  fire on itself. It did.
; ----------------------------------------------------------------------------
cbt_hostile:
    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    ld c,a

    ld hl,(cbt_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    cp c
    jr z,@cbt_same_side
    scf
    ret
@cbt_same_side:
    or a
    ret


; ----------------------------------------------------------------------------
;  cbt_kill -- entity A dies
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_kill:
    ld (cbt_target),a
    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),0                           ; the slot is free again
    pop hl

    call cbt_spawn_explosion            ; HL still points at the position

    ld hl,cbt_kills
    inc (hl)

    ;  Anything that was shooting at it needs to stop.
    xor a
    ld (cbt_scan),a
@cbt_forget:
    ld a,(cbt_scan)
    call ent_addr
    ld de,ENT_TARGET
    add hl,de
    ld a,(hl)
    ld de,cbt_target
    ex de,hl
    cp (hl)
    ex de,hl
    jr nz,@cbt_forget_next
    ld (hl),#FF
@cbt_forget_next:
    ld hl,cbt_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@cbt_forget

    ;  Squadron counts are derived, so one recount and the HUD is right again.
    call squad_refresh
    jp snd_explosion


; ----------------------------------------------------------------------------
;  cbt_spawn_explosion -- leave a mark where a ship was
;  In : HL -> the dead entity's position (six bytes)
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_spawn_explosion:
    ld (cbt_ent),hl

    ld hl,cbt_explosions
    ld b,EXPL_MAX
@cbt_find_slot:
    push hl
    ld de,6
    add hl,de
    ld a,(hl)
    pop hl
    or a
    jr z,@cbt_got_slot
    ld de,EXPL_SIZE
    add hl,de
    djnz @cbt_find_slot
    ret                                 ; all six busy: drop this one

@cbt_got_slot:
    ex de,hl
    ld hl,(cbt_ent)
    ld bc,6
    ldir                                ; position
    ld a,EXPL_LIFE
    ld (de),a                           ; timer
    ret


; ----------------------------------------------------------------------------
;  cbt_age_explosions -- tick every live explosion down
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_age_explosions:
    ld hl,cbt_explosions + 6
    ld b,EXPL_MAX
@cbt_age:
    ld a,(hl)
    or a
    jr z,@cbt_age_next
    dec (hl)
@cbt_age_next:
    ld de,EXPL_SIZE
    add hl,de
    djnz @cbt_age
    ret


; ----------------------------------------------------------------------------
;  cbt_in_range -- is (cbt_target) close enough to (cbt_ent) to shoot?
;  Out: CF set if it is
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_in_range:
    ld a,(cbt_target)
    call ent_addr
    ld (cbt_other),hl

    ld hl,(cbt_ent)
    ld (cbt_a_ptr),hl
    xor a
    ld (cbt_dist),a

    ld a,3
    ld (cbt_axis),a
@cbt_axis_loop:
    ld hl,(cbt_a_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (cbt_a_ptr),hl

    ld hl,(cbt_other)
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld (cbt_other),hl

    ld h,d
    ld l,e
    or a
    sbc hl,bc                           ; difference on this axis
    ;  Take the high byte: the same >>8 the projection uses, so "range" is in
    ;  the units everything else is measured in.
    ld a,h
    or a
    jp p,@cbt_positive
    neg
@cbt_positive:
    ld hl,cbt_dist
    add a,(hl)
    jr c,@cbt_too_far                   ; the sum overflowed a byte: miles away
    ld (hl),a
    cp CBT_RANGE
    jr nc,@cbt_too_far

    ld hl,cbt_axis
    dec (hl)
    jr nz,@cbt_axis_loop
    scf
    ret

@cbt_too_far:
    or a
    ret


; ----------------------------------------------------------------------------
;  cbt_retarget_one -- give ONE ship a fresh target this frame
;
;  Round-robin over the whole table, so every entity gets its turn within 48
;  frames. Ships only need a new target when the old one has died or drifted,
;  and both of those are checked before firing anyway.
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_retarget_one:
    ld hl,cbt_retarget
    ld a,(hl)
    inc (hl)
    ld b,a
    ld a,(hl)
    cp ENT_MAX
    jr c,@cbt_rt_ok
    xor a
    ld (hl),a
@cbt_rt_ok:
    ld a,b
    ld (cbt_index),a

    call ent_addr
    ld (cbt_ent),hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    ret z

    ;  Keep a target that is still alive and still in range.
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(hl)
    cp ENT_MAX
    jr nc,@cbt_need_target
    ld (cbt_target),a
    call ent_is_active
    jr nc,@cbt_need_target
    call cbt_in_range
    ret c

@cbt_need_target:
    call cbt_find_enemy
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(cbt_target)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  cbt_find_enemy -- the nearest entity on the other side, or none
;  In : (cbt_ent) = the searcher
;  Out: (cbt_target) = a slot index, or #FF
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_find_enemy:
    ld hl,(cbt_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    ld (cbt_side),a                     ; the side we are NOT looking for

    ld a,#FF
    ld (cbt_best),a
    xor a
    ld (cbt_scan),a

@cbt_search:
    ld a,(cbt_scan)
    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    pop hl
    bit 0,a
    jr z,@cbt_search_next               ; empty slot

    and ENT_F_ENEMY
    ld hl,cbt_side
    cp (hl)
    jr z,@cbt_search_next               ; same side

    ld a,(cbt_scan)
    ld (cbt_target),a
    call cbt_in_range
    jr nc,@cbt_search_next

    ld a,(cbt_scan)
    ld (cbt_best),a
    jr @cbt_search_done                 ; near enough is good enough

@cbt_search_next:
    ld hl,cbt_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@cbt_search

@cbt_search_done:
    ld a,(cbt_best)
    ld (cbt_target),a
    ret


; ============================================================================
;  State
; ============================================================================
cbt_index:          defb 0
cbt_scan:           defb 0
cbt_retarget:       defb 0
cbt_ent:            defw 0
cbt_other:          defw 0
cbt_a_ptr:          defw 0
cbt_target:         defb #FF
cbt_best:           defb #FF
cbt_side:           defb 0
cbt_axis:           defb 0
cbt_dist:           defb 0

;  Counters the tests and the HUD read.
cbt_shots:          defb 0
cbt_kills:          defb 0

;  x, y, z, timer -- timer 0 means the slot is free.
cbt_explosions:     defs EXPL_MAX * EXPL_SIZE, 0
