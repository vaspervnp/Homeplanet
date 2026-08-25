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

;  Homeplanet.md section 8's balance triangle:
;      Interceptor -> Bomber -> Frigate -> Interceptor
;
;  A matrix, not a single damage number, because the whole point is that a
;  class is defined by what it is good against. Rows are the shooter, columns
;  the target; the value is hull points a hit takes off.
;
;  Only the three classes that exist have real rows. The rest of section 8
;  arrives with its art, and this table is where its numbers go -- keeping the
;  matrix square from the start means adding a class is adding a row and a
;  column rather than rewriting how damage works.
CBT_DAMAGE_BASE     equ 24

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
    call cbt_move_enemies

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
;  cbt_move_enemies -- the Vekhar close on what they are shooting at
;
;  They have no formations and no orders: an enemy simply flies at its target
;  until it is inside weapons range, then holds. That is enough to make a
;  battle happen instead of waiting to be come to -- and it means a fleet that
;  sits still still gets a fight.
;
;  Only enemies. The player's ships are steered by their squadron's station,
;  and two systems moving the same ship by the same step cancel exactly, which
;  is a lesson the harvesters already taught.
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_move_enemies:
    xor a
    ld (cbt_scan),a
@cbt_move_one:
    ld a,(cbt_scan)
    call ent_addr
    ld (cbt_ent),hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    bit 0,a
    jr z,@cbt_move_next                 ; empty slot
    and ENT_F_ENEMY
    jr nz,@cbt_move_go                  ; theirs: always closes

    ;  Ours closes only when the player said so. `A` used to set a target and
    ;  nothing else, so an attacking squadron aimed from wherever its station
    ;  happened to be while the Vekhar -- who always close -- massed on it. A
    ;  fleet that cannot concentrate loses an even fight, and it did: eight
    ;  against eight with identical hulls went 8-0 to them.
    ld hl,(cbt_ent)
    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_ATTACK
    jr nz,@cbt_move_next

@cbt_move_go:
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(hl)
    cp ENT_MAX
    jr nc,@cbt_move_next                ; nothing to close on
    ld (cbt_target),a

    call ent_is_active
    jr nc,@cbt_move_next

    ;  Already close enough to shoot? Then hold station and shoot.
    call cbt_in_range
    jr c,@cbt_move_next

    ld a,(cbt_target)
    call ent_addr
    ld (cbt_move_dst),hl
    ld hl,(cbt_ent)
    ld (phase4_coord_ptr),hl

    ld a,3
    ld (cbt_axis),a
@cbt_move_axis:
    ld hl,(cbt_move_dst)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (cbt_move_dst),hl
    ld (phase4_tgt),de

    ld hl,(phase4_coord_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase4_cur),de
    dec hl

    push hl
    call phase4_approach
    ex de,hl
    pop hl
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (phase4_coord_ptr),hl

    ld hl,cbt_axis
    dec (hl)
    jr nz,@cbt_move_axis

@cbt_move_next:
    ld hl,cbt_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jp c,@cbt_move_one
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
    jr nc,@cbt_reacquire                ; nothing targeted
    ld (cbt_target),a

    call ent_is_active
    jr c,@cbt_aimed                     ; the target is still flying

    ;  The target is wreckage. Find another NOW rather than waiting for the
    ;  round-robin in cbt_retarget_one, which only reaches this ship once
    ;  every ENT_MAX frames.
    ;
    ;  Waiting punished exactly the thing a fleet is supposed to do. Ships
    ;  that are close together all pick the same nearest enemy, so a kill
    ;  left the WHOLE squadron with a dead target and idle for up to 48
    ;  frames, while the Vekhar -- strung out, each aiming at a different
    ;  ship -- lost only the few that had been aiming at it. Eight against
    ;  eight with identical hulls went 8-0 to them because of it.
@cbt_reacquire:
    call cbt_find_enemy
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(cbt_target)
    ld (hl),a
    cp ENT_MAX
    ret nc                              ; there is genuinely nobody left

@cbt_aimed:

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

    ;  Damage, from the balance matrix.
    call cbt_damage_for
    ld (cbt_damage),a
    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_HULL
    add hl,de
    ld a,(hl)
    ld c,a
    ld a,(cbt_damage)
    ld b,a
    ld a,c
    sub b
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
;  cbt_damage_for -- what (cbt_ent) does to (cbt_target)
;  Out: A = hull points
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_damage_for:
    ld hl,(cbt_ent)
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    cp CLASS_COUNT
    jr c,@cbt_shooter_ok
    xor a
@cbt_shooter_ok:
    add a,a
    add a,a                             ; CLASS_COUNT columns, rounded to 4
    ld c,a

    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    cp CLASS_COUNT
    jr c,@cbt_target_ok
    xor a
@cbt_target_ok:
    add a,c
    ld l,a
    ld h,0
    ld de,cbt_damage_matrix
    add hl,de
    ld a,(hl)
    ret


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
;  cbt_distance -- how far (cbt_target) is from (cbt_ent)
;  Out: A = Manhattan distance on the >>8 coordinates, saturating at 255
;  Uses: everything
;
;  Separate from the range test because targeting needs the NUMBER, not a
;  yes/no. An enemy that could only acquire targets already inside weapons
;  range could never acquire one at all: it needs a target to fly towards, and
;  it needs to fly to get in range. The picket sat at its spawn point forever.
; ----------------------------------------------------------------------------
cbt_distance:
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
    jr c,@cbt_saturate
    ld (hl),a

    ld hl,cbt_axis
    dec (hl)
    jr nz,@cbt_axis_loop
    ld a,(cbt_dist)
    ret

@cbt_saturate:
    ld a,255
    ld (cbt_dist),a
    ret


; ----------------------------------------------------------------------------
;  cbt_in_range -- is (cbt_target) close enough to (cbt_ent) to shoot?
;  Out: CF set if it is
;  Uses: everything
; ----------------------------------------------------------------------------
cbt_in_range:
    call cbt_distance
    cp CBT_RANGE
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

    ;  A target the PLAYER chose is not the AI's to overwrite. `A` and `G`
    ;  would otherwise last until the round-robin came round to that ship and
    ;  quietly pointed it somewhere else -- which made the order look like it
    ;  had done nothing. A dead target still falls through to a fresh search
    ;  above, so this cannot strand a ship.
    ld hl,(cbt_ent)
    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_ATTACK
    ret z
    cp ENT_ORDER_GUARD
    ret z

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
;  cbt_find_enemy -- the NEAREST entity on the other side, or none
;  In : (cbt_ent) = the searcher
;  Out: (cbt_target) = a slot index, or #FF
;  Uses: everything
;
;  At ANY distance, not just within weapons range: this is what an enemy flies
;  towards, and it has to be able to pick something before it can close on it.
;  Firing checks the range separately.
;
;  One entity does this per frame (see cbt_retarget_one), so the O(n) sweep
;  costs a frame's worth of work spread over the whole table.
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
    ld (cbt_best_dist),a                ; nothing found yet is "infinitely far"
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
    call cbt_distance
    ld hl,cbt_best_dist
    cp (hl)
    jr nc,@cbt_search_next              ; something closer is already held
    ld (hl),a
    ld a,(cbt_scan)
    ld (cbt_best),a

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
cbt_best_dist:      defb #FF
cbt_side:           defb 0
cbt_axis:           defb 0
cbt_dist:           defb 0

;  Counters the tests and the HUD read.
cbt_damage:         defb 0
cbt_move_dst:       defw 0
cbt_shots:          defb 0
cbt_kills:          defb 0

;  x, y, z, timer -- timer 0 means the slot is free.
cbt_explosions:     defs EXPL_MAX * EXPL_SIZE, 0

;  Rows are the shooter, columns the target, four columns a row so the index
;  is a shift rather than a multiply.
;
;                    vs INT   vs MTH   vs HAR    --
cbt_damage_matrix:
    defb  24,      10,      40,      0           ; interceptor: anti-fighter
    defb  40,      24,      40,      0           ; mothership:  heavy guns
    defb   4,       2,       4,      0           ; harvester:   barely armed
