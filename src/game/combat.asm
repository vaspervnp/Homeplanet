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
;  Range is Manhattan distance on the coordinates AFTER a >>WORLD_SHIFT, i.e.
;  in the same camera units the projection works in. A true distance needs
;  three multiplies and a square root per pair; the sum of the absolute
;  differences costs about thirty T-states and is wrong by at most the usual
;  sqrt(3) factor, which for "is it close enough to shoot" nobody can see.
;
;  Retargeting is round-robin: ONE entity picks a new target per frame. The
;  full search is O(n) over 48 slots, and doing it for everybody every frame
;  would be 48 x 48. A ship keeps its target until it dies or drifts out of
;  range, so the staleness is never visible.
; ----------------------------------------------------------------------------

CBT_RANGE           equ 40              ; camera-scale units, so ~2500 world
CBT_COOLDOWN        equ 6               ; frames between shots

;  Damage comes from cbt_damage_matrix -- eight classes square, section 8's
;  balance triangle written out. It lives in game/classdata.asm with the rest
;  of the per-class data, which is in bank 4; cbt_damage_for reads it with the
;  window at its resting state, which is the only state cbt_update ever runs
;  in. See the header of game/shipclass.asm for what "resting state" means.

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
    call cbt_prey_roll                  ; bank 4: this frame's coin for the unarmed
    call cbt_age_explosions
    call cbt_retarget_one
    call cbt_move_enemies

    ;  A walk, not an index: ent_addr costs about 120 T-states and there are
    ;  six of these 48-slot loops in a frame. cbt_walk is its OWN pointer
    ;  because cbt_ent does not survive the body -- cbt_spawn_explosion writes
    ;  through it when something dies.
    ld hl,entities
    ld (cbt_walk),hl
    ld a,ENT_MAX
    ld (cbt_index),a
@cbt_ship:
    ld hl,(cbt_walk)
    ld (cbt_ent),hl

    ;  Active AND not a wreck. A crippled hull keeps every field it had --
    ;  including the target it was aiming at and the side it was on -- so
    ;  without this a wreck would go on shooting at the fleet that crippled it,
    ;  which is the one thing a wreck must not do.
    ;
    ;  Two BITs and not one masked compare, which is the same lesson
    ;  cbt_find_enemy learned the expensive way: thirty-two of the forty-eight
    ;  slots are empty, and the compare version made every one of them pay for
    ;  a question only the sixteen live ones can answer. This way an empty slot
    ;  costs exactly what it always did.
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@cbt_next                      ; empty: out on the first test
    bit 2,(hl)                          ; ENT_F_DISABLED
    jr nz,@cbt_next                     ; a wreck does not take a turn

    call cbt_fire_if_able

@cbt_next:
    ld hl,(cbt_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (cbt_walk),hl
    ld hl,cbt_index
    dec (hl)
    jr nz,@cbt_ship
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
    ld hl,entities
    ld (cbt_walk),hl
    ld a,ENT_MAX
    ld (cbt_scan),a
@cbt_move_one:
    ld hl,(cbt_walk)
    ld (cbt_ent),hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    bit 0,a
    jr z,@cbt_move_next                 ; empty slot
    bit 2,a                             ; ENT_F_DISABLED
    jr nz,@cbt_move_next                ; a wreck drifts; only a tow moves it
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

    call cbt_target_flying
    jr nc,@cbt_move_next

    ;  Already close enough to shoot? Then hold station and shoot.
    call cbt_in_range
    jr c,@cbt_move_next

    ld a,(cbt_target)
    call ent_addr
    ex de,hl
    ld hl,(cbt_ent)
    call phase4_step_toward

@cbt_move_next:
    ld hl,(cbt_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (cbt_walk),hl
    ld hl,cbt_scan
    dec (hl)
    jp nz,@cbt_move_one
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

    call cbt_target_flying
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
    jr c,@cbt_aimed

    ;  There is genuinely nobody left, so an ATTACK order is SPENT. Nothing
    ;  else was ever going to clear it: phase4_fly skips an attacking ship on
    ;  purpose, so that cbt_move_enemies can close it without the two of them
    ;  cancelling, and with no target cbt_move_enemies declines to move it
    ;  either. The ship was steered by nobody and stopped dead wherever the
    ;  last enemy happened to die -- and fleet_save carried those coordinates
    ;  into the next mission, so the fleet began it scattered thousands of
    ;  units from a Mothership that eight fresh hostiles then spawned on.
    ;
    ;  IDLE and not GUARD, though GUARD is also "hold station and shoot":
    ;  cbt_retarget_one returns early for GUARD, so a ship dropped into it
    ;  would keep the first target it happened to pick up next and never be
    ;  re-pointed at a nearer one when that target drifted out of range. IDLE
    ;  is the state mis_spawn_enemy and the fleet both start in, so the order
    ;  is spent rather than replaced by one the player never gave.
    ;
    ;  Only ATTACK. A harvester reaches here every frame of every mission
    ;  whose enemies are all dead -- which is most of them, at the end -- and
    ;  clearing unconditionally would take ENT_ORDER_HARVEST off it and stop
    ;  the economy.
    assert ENT_ORDER == ENT_TARGET - 1, "the dec below walks ENT_TARGET back to ENT_ORDER"
    dec hl
    ld a,(hl)
    cp ENT_ORDER_ATTACK
    ret nz
    ld (hl),ENT_ORDER_IDLE
    ret

@cbt_aimed:

    ;  Never shoot your own side -- and RE-AIM rather than return, which is
    ;  the whole of "χάνει το attack κάποιες φορές. Αντί να επιτίθενται
    ;  κάθονται κάπου τα squadrons και αφήνουν να τα χτυπάνε".
    ;
    ;  A `ret nc` here is a ship that nothing steers, for the rest of the
    ;  mission. All three of the things that could move it decline at once,
    ;  each of them correctly: phase4_fly skips a ship under ENT_ORDER_ATTACK
    ;  on purpose; cbt_move_enemies finds the target flying and already inside
    ;  CBT_RANGE, because it is in the same formation, so it holds station;
    ;  and cbt_retarget_one returns early for ATTACK precisely so that a target
    ;  the player chose is not the AI's to overwrite. Only this routine ever
    ;  reconsiders a target, and this was the one exit that left without doing
    ;  it -- so the order was never spent and the ship never came home.
    ;
    ;  It got a friendly index the ordinary way: `,` and `.` walked
    ;  order_target over every FLYING entity, and the fleet is fifty-six of the
    ;  seventy-six slots. From a fresh mission the FIRST press of `.` lands on
    ;  slot 0. Measured on the build this was reported against: press `.`, then
    ;  `A`, and fifteen of sixteen ships never moved once in 1800 frames while
    ;  the fleet was shot down to eight.
    ;
    ;  order_target_step will not offer one of ours any more, which is where a
    ;  player should meet this rule. This is the net underneath it, and it is
    ;  the one that has to hold: ENT_TARGET is a slot index, and a stale one, a
    ;  recycled one and a mistaken one all name SOMETHING. That is the same
    ;  argument that put cbt_hostile at the moment of FIRING rather than only
    ;  at the moment of choosing -- this is that argument finished.
    call cbt_hostile
    jr nc,@cbt_reacquire

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
    ;  ...and the victim's squadron answers. Both exits, because a ship shot
    ;  dead is an attack on its squadron exactly as a ship shot is; see
    ;  game/retaliate.asm, in bank 4, for what it does and does not touch.
    call cbt_retaliate
    jp snd_hit

@cbt_destroyed:
    ld (hl),0
    call cbt_retaliate                  ; before the kill: it reads the victim's squadron
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
    add a,a
    add a,a                             ; * CLASS_COUNT, which is 8
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
;  cbt_target_flying -- is (cbt_target) an entity that can still fight?
;  Out: CF set if it is ACTIVE and not a wreck
;  Uses: AF, DE, HL
;
;  ent_is_active with one more bit, and it replaced ent_is_active at all three
;  of combat's call sites rather than being a second test beside it. A crippled
;  hull keeps every field it had, so "still there" and "still a ship" stopped
;  being the same question the day ENT_F_DISABLED got its first writer.
;
;  Reading it as NOT flying is what makes the rest fall out for free:
;  cbt_fire_if_able treats it exactly as it treats a target that has just been
;  destroyed -- re-acquire on the spot, and if there is nothing left anywhere,
;  spend the ATTACK order and let the fleet come home. Without that a squadron
;  that had shot the last enemy into a wreck would sit over it for the rest of
;  the mission, which is the bug CLAUDE.md spent a section on.
; ----------------------------------------------------------------------------
cbt_target_flying:
    ld a,(cbt_target)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    jr nz,@cbt_not_flying
    scf
    ret
@cbt_not_flying:
    or a                                ; A is 0 or ENT_F_DISABLED; CF clear
    ret


; ----------------------------------------------------------------------------
;  cbt_kill -- entity A dies
;  Uses: everything
;
;  ...or is CRIPPLED rather than destroyed, if the player has a Salvage
;  Corvette flying to come and get it. slv_make_wreck is the whole of that
;  decision and it is in bank 4; CF set means the slot is still ACTIVE and now
;  carries ENT_F_DISABLED, so the `ld (hl),0` below must not run.
;
;  Everything after it happens either way, and each for its own reason. The
;  explosion, because the ship WAS destroyed -- what is left is not a ship.
;  cbt_kills, because a kill is a kill and half the suite counts them. The
;  forget loop, because a wreck must stop being anybody's target the instant it
;  becomes one, and cbt_target_flying is the second net rather than the first.
; ----------------------------------------------------------------------------
cbt_kill:
    ld (cbt_target),a
    call slv_make_wreck                 ; CF: it is a wreck, not an empty slot

    ;  PUSHED, because the flag cannot be tested where it is wanted: ent_addr
    ;  is a shift ladder and `add hl,hl` writes the carry. This is the trap in
    ;  CLAUDE.md's own hard rules -- "a routine that returns a flag must have
    ;  that flag tested immediately" -- and the first version of this walked
    ;  straight into it, so every wreck was freed as an ordinary kill and
    ;  fifteen tests said so at once.
    push af
    ld a,(cbt_target)
    call ent_addr
    pop af
    jr c,@cbt_wrecked
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),0                           ; the slot is free again
    pop hl
@cbt_wrecked:

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
;  dist_manhattan -- how far apart two world positions are, in camera units
;  In : HL -> six bytes of position, DE -> six bytes of position
;  Out: A = (|dx| + |dy| + |dz|) >> WORLD_SHIFT, saturating at 255
;  Uses: everything
;
;  ONE of these, not two. Combat and the economy both need it -- CBT_RANGE and
;  ECO_HARVEST_RANGE are both in camera units -- and each used to carry its own
;  copy of the P/V test, the negate, the shift and the saturate: ninety bytes
;  of the low 16K, written out twice, for the same twenty instructions.
;
;  Manhattan rather than Euclidean: a true distance is three multiplies and a
;  square root per pair, and for "is it close enough to shoot" the sqrt(3)
;  error is not something anyone can see.
;
;  It shifts by SIX, not eight, and it has to: both ranges are tuned, and with
;  every authored position four times smaller the old shift would have made
;  every weapon and every harvester reach four times as far.
; ----------------------------------------------------------------------------
dist_manhattan:
    ld (cbt_a_ptr),hl
    ld (cbt_other),de
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

    ;  If that did not fit, the sign bit lies and the magnitude is over 32767
    ;  either way -- which saturates. Test P/V immediately; the next
    ;  instruction that touches the flags destroys it.
    jp pe,@cbt_saturate

    bit 7,h
    jr z,@cbt_positive
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
@cbt_positive:
    ld a,h
    cp PROJ_V_BIAS * 2                  ; >= 16384 would shift past a byte
    jr nc,@cbt_saturate
    add hl,hl
    add hl,hl
    ld a,h

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
    ret


; ----------------------------------------------------------------------------
;  cbt_distance -- how far (cbt_target) is from (cbt_ent)
;  Out: A = Manhattan distance in camera units, saturating at 255
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
    ex de,hl
    ld hl,(cbt_ent)
    jp dist_manhattan


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
    ;  Active AND not a wreck, for the same reason cbt_update's loop tests both.
    ;  A wreck cannot fire, so a target in its ENT_TARGET does nothing today --
    ;  but the round-robin was cheerfully handing it one, which is a loaded gun
    ;  waiting for somebody to add a fifth thing that reads that field. Seen in
    ;  the emulator, not reasoned about: the wreck's target went 255, then back
    ;  to the ship that had just crippled it, three frames later.
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_DISABLED
    cp ENT_F_ACTIVE
    ret nz

    ;  Keep a target that is still alive and still in range.
    ld hl,(cbt_ent)
    ld de,ENT_TARGET
    add hl,de
    ld a,(hl)
    cp ENT_MAX
    jr nc,@cbt_need_target
    ld (cbt_target),a
    call cbt_target_flying
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
;  THIS IS THE MOST EXPENSIVE LOOP IN THE GAME THAT IS NOT A BLIT, and it was
;  costing about eight times what it had to. Two things, both of which the
;  entity table's own layout had already made available:
;
;  IT SEARCHES ONE REGION, NOT THE TABLE. The two sides are disjoint BY INDEX
;  (game/entity.asm), so a friendly ship looking for a hostile has twenty slots
;  to look at and not seventy-six, and every slot it used to reject on the side
;  compare it now never reads. The old sweep was written before the partition
;  existed and nobody went back to it.
;
;  IT STEPS A POINTER ALONG THE FLAGS BYTE. It used to `call ent_addr` per
;  slot -- a shift ladder and a call, about 120 T-states -- to reach a byte
;  eleven along from a record twenty further on than the last one. The same
;  find as the six loops CLAUDE.md records, arriving in the one place where it
;  is multiplied by the number of ships doing the searching.
;
;  Together: an empty slot goes from ~250 T-states to ~65, and a friendly
;  ship's whole search from ~19,000 T to ~1,300. That matters because of when
;  it runs -- once the picket is dead EVERY live ship reaches @cbt_reacquire
;  every frame, so this is multiplied by the fleet, and it is what made
;  cbt_update half the frame at sixteen ships. It is also what made doubling
;  ENT_PLAYER_MAX affordable: the old sweep was O(fleet x table), so it grew
;  with the SQUARE of the ceiling.
; ----------------------------------------------------------------------------
cbt_find_enemy:
    ld hl,(cbt_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    xor ENT_F_ENEMY                     ; ...so this is the side we ARE after,
    ld (cbt_side),a                     ; and a wreck's extra bit cannot match it

    ld a,#FF
    ld (cbt_best),a
    ld (cbt_best_dist),a                ; nothing found yet is "infinitely far"

    ;  Which region holds that side. HL walks the FLAGS byte, C is the slot
    ;  number that goes with it, B is how many are left.
    ;
    ;  RELOADED, not left in A: the two stores above put #FF there, so testing
    ;  the accumulator here sends EVERY searcher into the hostile region --
    ;  where an enemy finds nothing on the side compare and so never targets
    ;  anything again.
    ld a,(cbt_side)
    or a
    jr nz,@cbt_hunt_theirs

    ld hl,entities + ENT_FLAGS
    ld c,0
    ld b,ENT_PLAYER_MAX
    jr @cbt_search

@cbt_hunt_theirs:
    ld hl,entities + ENT_PLAYER_MAX * ENT_SIZE + ENT_FLAGS
    ld c,ENT_PLAYER_MAX
    ld b,ENT_ENEMY_MAX

@cbt_search:
    ld a,(hl)

    ;  THE EMPTY TEST STAYS IN FRONT, AND THAT IS THE WHOLE PERFORMANCE STORY
    ;  OF THIS FILE. Most of a region is empty most of the time, and this is
    ;  the path those slots take.
    ;
    ;  The wreck test was first written as a second `bit` after it, then as one
    ;  masked compare with the empty test folded in; the second version reads
    ;  better and cost sixteen T-states here, which took the frame rate from
    ;  5.00 to 4.85 over a thousand frames. That is not the demo_wait_frame
    ;  tick boundary CLAUDE.md warns about -- it was measured against a
    ;  worktree build of HEAD and then attributed with a stub around this
    ;  routine.
    ;
    ;  So it is folded into the SIDE compare instead, where there was already
    ;  an `and` and a `cp`: cbt_side is the side we are after, a wreck's flags
    ;  carry a bit that is not in it, and the mask lets that bit through so the
    ;  compare fails. One more bit in an immediate, and nothing else.
    bit 0,a
    jr z,@cbt_search_next               ; empty slot: the common case
    and ENT_F_ENEMY + ENT_F_DISABLED
    ld e,a
    ld a,(cbt_side)
    cp e
    jr nz,@cbt_search_next              ; ours, or wreckage

    ;  A candidate, which is rare enough to pay for the spill.
    push bc
    push hl
    ld a,c
    ld (cbt_target),a
    call cbt_distance

    ;  ...and then push an UNARMED candidate away, so that a warship prefers
    ;  something that can shoot back while there is one to be had.
    ;
    ;  Section 8 says the harvester is "αργό, άοπλο, χρειάζεται προστασία" --
    ;  it is MEANT to be vulnerable. What it was instead is a free kill: the
    ;  search takes the nearest target, harvesters fly out to patches alone by
    ;  design, so every picket in the campaign peeled off and killed the
    ;  economy first. Measured with tools/balance.py: the harvesters are gone
    ;  by mission 3 and the treasury reaches zero at mission 5, after which the
    ;  fleet cannot be replaced and the campaign ends at 7. The ships were
    ;  never the thing that lost.
    ;
    ;  A BIAS AND NOT AN EXCLUSION. If nothing armed is anywhere in the region
    ;  every candidate carries the same penalty, so the miner is still picked
    ;  and still dies -- "needs protection" stays true, it just stops meaning
    ;  "is the first thing shot at".
    ;
    ;  HL is on the stack; ENT_CLASS is the two bytes in front of ENT_FLAGS,
    ;  which is section 7's record layout being convenient rather than designed
    ;  and is asserted in src/main.asm for wave_health's sake already.
    pop hl
    push hl
    dec hl
    dec hl                              ; -> ENT_CLASS
    ld e,(hl)
    ld d,0
    ld hl,cbt_prey_bias
    add hl,de
    ;  ...HALF THE TIME. "make enemies attack unarmed ships 50% of the time":
    ;  cbt_prey_mask is #FF or 0 for the frame, rolled by cbt_prey_roll, and
    ;  ANDed with the class's bias here -- so on the frames it is 0 an unarmed
    ;  ship is simply the nearest target it is, and on the others the escort
    ;  takes the shot as before. Per FRAME, not per search, because the roll
    ;  is bank 4 code and this loop is the low 16K's busiest.
    ld d,a
    ld a,(cbt_prey_mask)
    and (hl)
    add a,d
    jr nc,@cbt_prey_fits
    ld a,255                            ; cbt_distance saturates; so does this
@cbt_prey_fits:

    ld hl,cbt_best_dist
    cp (hl)
    jr nc,@cbt_no_nearer                ; something closer is already held
    ld (hl),a
    pop hl
    pop bc
    ld a,c
    ld (cbt_best),a
    jr @cbt_search_next
@cbt_no_nearer:
    pop hl
    pop bc

@cbt_search_next:
    ld de,ENT_SIZE
    add hl,de
    inc c
    djnz @cbt_search

    ld a,(cbt_best)
    ld (cbt_target),a
    ret


; ----------------------------------------------------------------------------
;  How much further away an unarmed ship LOOKS to a warship picking a target.
;
;  In the low 16K with the rest of the frame loop, because cbt_find_enemy reads
;  it and that is the innermost non-blit loop in the game.
;
;  The two entries that are not zero are the two classes whose damage row in
;  cbt_damage_matrix is noise -- the harvester's 4/2/4 and the corvette's 6/3/8
;  against an interceptor's 24. Everything else, the scout included, can hurt
;  you and is fair game at face value.
;
;  CBT_UNARMED_BIAS is 96 against a CBT_RANGE of 40, so an escort anywhere within
;  a couple of weapons' reach of its miner takes the shot instead. It is not
;  larger because cbt_distance saturates at 255: a penalty near that flattens
;  every unarmed ship to "infinitely far" and they would stop being targets at
;  all rather than being poor ones.
; ----------------------------------------------------------------------------
CBT_UNARMED_BIAS    equ 96              ; ...applied on half the frames; see cbt_prey_mask

cbt_prey_bias:
    defb 0                              ; interceptor
    defb 0                              ; mothership -- the prize, never a bias
    defb CBT_UNARMED_BIAS                ; harvester: unarmed
    defb 0                              ; scout
    defb 0                              ; bomber
    defb 0                              ; frigate
    defb CBT_UNARMED_BIAS                ; salvage corvette: unarmed
    defb 0                              ; destroyer
cbt_prey_bias_end:

    assert cbt_prey_bias_end - cbt_prey_bias == CLASS_COUNT, "cbt_prey_bias is not one byte a class"


; ============================================================================
;  State
; ============================================================================
cbt_index:          defb 0
cbt_scan:           defb 0
cbt_retarget:       defb 0
cbt_ent:            defw 0
cbt_other:          defw 0
cbt_a_ptr:          defw 0
cbt_walk:           defw 0
cbt_target:         defb #FF
cbt_best:           defb #FF
cbt_best_dist:      defb #FF
;  The side a target must be on -- the OPPOSITE of the searcher's -- as an
;  ENT_F_ENEMY bit. cbt_find_enemy masks ENT_F_DISABLED in beside it, so a
;  wreck can never compare equal to it. 
cbt_side:           defb 0
cbt_axis:           defb 0
cbt_dist:           defb 0

;  Counters the tests and the HUD read.
cbt_damage:         defb 0
cbt_shots:          defb 0
cbt_kills:          defb 0

;  x, y, z, timer -- timer 0 means the slot is free.
cbt_explosions:     defs EXPL_MAX * EXPL_SIZE, 0

;  The balance triangle's damage matrix is in game/classdata.asm, in bank 4
;  with the rest of the per-class data -- cbt_damage_for reads it with bank 4
;  under the window, which is where the window rests.
