; ============================================================================
;  economyrun.asm -- section 7's economy, the code half (bank 4)
; ============================================================================
;  Its equates and every byte of its state are in game/economy.asm, in the low
;  16K. The split is game/order.asm's: DATA down there because eco_ru,
;  eco_patches, eco_build_class and eco_queue_len are watched by half the test
;  suite with read_ram, CODE up here because bank 4 has thousands of bytes
;  free and the low 16K is paying for a fleet twice the size.
;
;  CLAUDE.md named this file and game/combat.asm as the two that would go
;  across "if it gets desperate again", and said the line was deliberate
;  rather than forced -- the per-frame simulation was worth keeping in one
;  place. Doubling ENT_PLAYER_MAX is what made it desperate again.
;
;  IT IS LEGAL BY THE NARROW RULE IN game/shipclass.asm, and eco_update runs
;  from inside the frame loop, so the rule is the only thing that matters
;  here: can any of this be reached from between class_tier_addr and
;  class_blit_done? Nothing here draws. game/salvage.asm is already in the
;  bank on exactly the same argument, and eco_update is what calls it.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  eco_init
;  Uses: everything
; ----------------------------------------------------------------------------
eco_init:
    ld hl,ECO_START_RU
    ld (eco_ru),hl

    ;  The patches themselves are NOT seeded here. mis_setup wipes all four
    ;  and copies the mission's own layout over them before the first frame,
    ;  every mission including the first, so a starting set in bank 4 was
    ;  thirty-two bytes and an LDIR that nothing ever read.

    xor a
    ld (eco_build_open),a
    ld (eco_build_timer),a
    ld (eco_build_pick),a
    ld (eco_queue_len),a                ; ...and nothing waiting behind it
    ld a,#FF
    ld (eco_build_class),a              ; nothing under construction
    ret


; ----------------------------------------------------------------------------
;  eco_update -- one frame of the economy
;  Uses: everything
; ----------------------------------------------------------------------------
eco_update:
    call eco_run_workers
    jp eco_run_yard


; ----------------------------------------------------------------------------
;  eco_run_workers -- one step for every ship that has been sent to WORK
;
;  A harvester: outbound with an empty hold, mining while it sits on a patch,
;  homebound when full, and paid out when it reaches the Mothership. A Salvage
;  Corvette: outbound to a crippled enemy hull, homebound dragging it, and paid
;  out for the hull at the same door. Two cargoes, one journey, one loop.
;
;  IT IS ONE WALK BECAUSE IT WAS ALREADY ONE WALK. Six loops in this game used
;  to step all 48 slots with ent_addr and CLAUDE.md spends a section on what
;  that cost; a seventh, added for a class the player may not even own, would
;  have been ~2,700 T-states a frame to ask a question this one is already
;  standing next to the answer to. Dispatching on ENT_ORDER here is one more
;  compare on the path where neither matches.
;  Uses: everything
; ----------------------------------------------------------------------------
eco_run_workers:
    ;  The player's region only. Harvesters and Salvage Corvettes are bought
    ;  from the yard, so ent_find_free_ours is the only thing that ever placed
    ;  one and the partition says where that can be.
    ld hl,entities
    ld (eco_walk),hl
    ld a,ENT_PLAYER_MAX
    ld (eco_index),a
@eco_ship:
    ld hl,(eco_walk)
    ld (eco_ent),hl

    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@eco_next

    ld hl,(eco_ent)
    ld de,ENT_ORDER
    add hl,de
    ld a,(hl)
    cp ENT_ORDER_HARVEST
    jr z,@eco_mine
    cp ENT_ORDER_TOW
    jr nz,@eco_next
    call slv_tow_step                   ; bank 4; the window is at rest here
    jr @eco_next
@eco_mine:
    call eco_harvester_step

@eco_next:
    ld hl,(eco_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (eco_walk),hl
    ld hl,eco_index
    dec (hl)
    jr nz,@eco_ship
    ret


; ----------------------------------------------------------------------------
;  eco_harvester_step -- one harvester's turn
;  In : (eco_ent)
;  Uses: everything
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  @eco_h_no_work -- there is nothing useful to mine, so SPEND THE ORDER
;
;  This used to be a bare `ret nc` and that was a real bug, of a shape this
;  project has met twice before. phase4_fly SKIPS ENT_ORDER_HARVEST -- it has
;  to, or it and eco_update would step the same ship in two directions and
;  cancel exactly -- so a harvester with no work is steered by NOBODY. It stops
;  dead wherever it happened to be, stays there for the rest of the mission,
;  and fleet_save carries those coordinates into the next one.
;
;  Dropping it to IDLE hands it back to phase4_fly, which flies it to its
;  station. Exactly what cbt_fire_if_able does when an attack order's
;  re-acquire comes back ENT_NO_TARGET, and for exactly the same reason.
;
;  IDLE and not GUARD, also for the same reason: cbt_retarget_one returns early
;  for GUARD, so a ship dropped there keeps whatever target it picks up next
;  and is never re-pointed at a nearer one. IDLE is the state the fleet starts
;  in, so the order is SPENT rather than replaced by one the player never gave.
;
;  No guard on the order byte is needed and none is wanted: eco_run_workers
;  dispatches here only for ENT_ORDER_HARVEST. Clearing unconditionally would
;  take ENT_ORDER_TOW with it and stop the salvage.
; ----------------------------------------------------------------------------
@eco_h_no_work:
    ld hl,(eco_ent)
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_IDLE
    ret


eco_harvester_step:
    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld a,(hl)                           ; the hold
    cp ECO_LOAD_MAX
    jr nc,@eco_homebound

    ;  THE TREASURY IS FULL. eco_earn saturates at ECO_RU_MAX, so mining on
    ;  would drain a FINITE patch for income that is thrown away the moment it
    ;  arrives. Stop, and go home -- and note this is checked outbound only, so
    ;  a harvester already carrying a hold still delivers it.
    ld hl,(eco_ru)
    ld de,ECO_RU_MAX
    or a
    sbc hl,de
    jr nc,@eco_h_no_work                ; eco_ru >= the ceiling

    ;  Outbound: find a patch with something left in it and close on it.
    call eco_nearest_patch
    jr nc,@eco_h_no_work                ; everything is mined out
    ld (eco_patch_ptr),hl

    call eco_at_target
    ret nc                              ; still flying

    ;  In contact: mine.
    ld hl,(eco_patch_ptr)
    ld de,6
    add hl,de
    ld c,(hl)
    inc hl
    ld b,(hl)                           ; BC = stock
    ld a,b
    or c
    ret z

    ;  Take the rate, or whatever is left if that is less. Without the clamp
    ;  the last scoop takes a patch below zero, and a 16-bit stock wraps to
    ;  65534 -- an exhausted field turns into an inexhaustible one.
    ld a,b
    or a
    jr nz,@eco_full_rate
    ld a,c
    cp ECO_LOAD_RATE
    jr c,@eco_have_amount
@eco_full_rate:
    ld a,ECO_LOAD_RATE
@eco_have_amount:
    ld (eco_amount),a

    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld a,(eco_amount)
    add a,(hl)
    ld (hl),a

    ld hl,(eco_patch_ptr)
    ld de,6
    add hl,de
    push hl
    ld c,(hl)
    inc hl
    ld b,(hl)
    ld a,(eco_amount)
    ld e,a
    ld d,0
    ld h,b
    ld l,c
    or a
    sbc hl,de
    ex de,hl
    pop hl
    ld (hl),e
    inc hl
    ld (hl),d
    ret


@eco_homebound:
    ;  Full: head for the Mothership and cash in on arrival.
    ld a,(moth_slot)
    call ent_addr
    ld (eco_patch_ptr),hl               ; the same "fly at this" machinery
    call eco_at_target
    ret nc

    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld c,(hl)
    ld (hl),0                           ; hold emptied
    ;  ...and fall through into eco_earn.


; ----------------------------------------------------------------------------
;  eco_earn -- C resource units arrive at the Mothership
;  In : C = the amount, 0..255
;  Uses: AF, BC, DE, HL
;
;  The ONLY place RU is ever earned, which is what makes it the only place the
;  ceiling has to be applied. It was inside the harvester's payout until the
;  Salvage Corvette turned up with a second cargo to cash in at the same door;
;  splitting it costs nothing at all, because eco_harvester_step falls straight
;  through into it.
;
;  The add cannot itself overflow -- HL is at most ECO_RU_MAX and C is one byte
;  -- so a plain 16-bit compare is enough.
; ----------------------------------------------------------------------------
eco_earn:
    ld b,0
    ld hl,(eco_ru)
    add hl,bc
    ld de,ECO_RU_MAX
    push hl
    or a
    sbc hl,de
    pop hl
    jr c,@eco_ru_store
    ex de,hl                            ; at or over the ceiling: sit on it
@eco_ru_store:
    ld (eco_ru),hl
    ret


; ----------------------------------------------------------------------------
;  eco_at_target -- close on (eco_patch_ptr) and say whether we have arrived
;  In : (eco_ent), (eco_patch_ptr) -> six bytes of position
;  Out: CF set if within ECO_HARVEST_RANGE
;  Uses: everything
; ----------------------------------------------------------------------------
eco_at_target:
    ld hl,(eco_ent)
    ld de,(eco_patch_ptr)
    call phase4_step_toward
    jp eco_range_check


; ----------------------------------------------------------------------------
;  eco_range_check -- is (eco_ent) close enough to (eco_patch_ptr) to work?
;  Out: CF set if within ECO_HARVEST_RANGE
;  Uses: everything
;
;  The distance itself is combat's, because there is only one of them now: see
;  dist_manhattan in game/combat.asm. This one lost its early exit on the first
;  axis that was already too far, which is a few dozen T-states per harvester
;  per frame against ninety bytes of the low 16K.
; ----------------------------------------------------------------------------
eco_range_check:
    ld hl,(eco_patch_ptr)
    ex de,hl
    ld hl,(eco_ent)
    call dist_manhattan
    cp ECO_HARVEST_RANGE
    ret


; ----------------------------------------------------------------------------
;  eco_nearest_patch -- any patch that still has stock
;  Out: CF set and HL -> the patch, or CF clear if all four are empty
;  Uses: everything
;
;  "Nearest" is a lie for now: it takes the first with anything left. With
;  four patches and harvesters that fly at a fixed speed the difference is
;  small, and a real search is three subtractions a patch per harvester per
;  frame.
; ----------------------------------------------------------------------------
eco_nearest_patch:
    ld hl,eco_patches
    ld b,ECO_PATCH_COUNT
@eco_patch_try:
    push hl
    ld de,6
    add hl,de
    ld a,(hl)
    inc hl
    or (hl)
    pop hl
    jr nz,@eco_patch_found
    ld de,ECO_PATCH_SIZE
    add hl,de
    djnz @eco_patch_try
    or a
    ret
@eco_patch_found:
    scf
    ret


; ----------------------------------------------------------------------------
;  eco_run_yard -- advance whatever the Mothership is building
;  Uses: everything
;
;  A finished ship leaves the slipway empty and the NEXT frame takes the next
;  order off the queue, rather than this one doing both. One game frame of
;  slack at 5 fps is a fifth of a second nobody can see, and it keeps
;  eco_start_build with exactly one caller inside the frame loop -- the
;  alternative is two places that know how to put a hull on the slipway, which
;  is the shape of every "two systems writing the same thing" bug in this file.
; ----------------------------------------------------------------------------
eco_run_yard:
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,eco_queue_pop                 ; the slipway is free: take the next one

    ld hl,eco_build_timer
    ld a,(hl)
    or a
    jr z,@eco_launch
    dec (hl)
    ret

@eco_launch:
    call eco_spawn_built
    ld a,#FF
    ld (eco_build_class),a
    ret


; ----------------------------------------------------------------------------
;  eco_queue_pop -- the head of the waiting line goes on the empty slipway
;  Uses: everything
; ----------------------------------------------------------------------------
eco_queue_pop:
    ld a,(eco_queue_len)
    or a
    ret z                               ; nothing waiting

    dec a
    ld (eco_queue_len),a
    ld a,(eco_queue_squad)              ; ...and who it was ordered for
    ld c,a
    ld a,(eco_queue_buf)                ; the oldest order, and it goes first
    call eco_start_build

    ;  Shuffle the rest down, both arrays. Nine bytes at worst, once a ship,
    ;  against a head index that every reader of the queue would then have to
    ;  know about.
    ld a,(eco_queue_len)
    or a
    ret z
    ld c,a
    ld b,0
    push bc
    ld hl,eco_queue_buf + 1
    ld de,eco_queue_buf
    ldir
    pop bc
    ld hl,eco_queue_squad + 1
    ld de,eco_queue_squad
    ldir
    ret


; ----------------------------------------------------------------------------
;  eco_start_build -- class A goes on the slipway, with its own build time
;  In : A = the class, C = the squadron that ordered it
;  Uses: everything
;
;  THE SQUADRON TRAVELS WITH THE ORDER and is not read from squad_sel here.
;  That is the whole of what "a ship joins the squadron that ordered it" means:
;  by the time a hull comes off the slipway the player may have selected
;  something else four times over.
;
;  eco_class_frames is in bank 4, which is legal here for the reason
;  game/shipclass.asm gives: both callers run with the window at rest.
; ----------------------------------------------------------------------------
eco_start_build:
    ld (eco_build_class),a
    ld a,c
    ld (eco_build_squad),a
    ld a,(eco_build_class)
    ld l,a
    ld h,0
    ld de,eco_class_frames
    add hl,de
    ld a,(hl)
    ld (eco_build_timer),a
    ret


; ----------------------------------------------------------------------------
;  eco_spawn_built -- a finished ship appears at the Mothership
;  Uses: everything
; ----------------------------------------------------------------------------
eco_spawn_built:
    ;  Ours. It should never fail now -- eco_queue counts the room before it
    ;  takes the money, so the slot this launch needs was reserved by
    ;  arithmetic at the moment the order was placed. Something the player did
    ;  not pay for can still fill it (nothing does today), so the guard stays.
    call ent_find_free_ours
    ret nc                              ; no room in the fleet; the RU is spent

    ld (eco_new_slot),a
    call ent_addr
    ld (eco_ent),hl

    ;  Position: on the Mothership.
    push hl
    ld a,(moth_slot)
    call ent_addr
    pop de
    ld bc,6
    ldir

    ld hl,(eco_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE
    ld hl,(eco_ent)
    ld de,ENT_CLASS
    add hl,de
    ld a,(eco_build_class)
    ld (hl),a
    ld hl,(eco_ent)
    ld de,ENT_HULL
    add hl,de
    ld a,(eco_build_class)
    push hl
    ld l,a
    ld h,0
    ld de,class_hull
    add hl,de
    ld a,(hl)
    pop hl
    ld (hl),a
    ld hl,(eco_ent)
    ld de,ENT_TARGET
    add hl,de
    ld (hl),ENT_NO_TARGET

    ;  ...AND THE ORDER, which this did not write and had to. A slot keeps
    ;  every byte the ship that died in it left behind, and order_issue used to
    ;  put ENT_ORDER_ATTACK into the empty ones -- so a replacement built after
    ;  a casualty came out of the Mothership already attacking, and phase4_fly
    ;  skips an attacking ship on purpose. It never joined the formation and
    ;  ignored every order given to it.
    ;
    ;  It is the same rule ENT_TARGET is written for one line above, and the
    ;  same rule mis_make_enemy has always followed: A SPAWN INITIALISES EVERY
    ;  FIELD IT DEPENDS ON. "Never trust a slot index" is about reading one;
    ;  this is about inheriting one.
    ld hl,(eco_ent)
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_IDLE

    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld (hl),0

    ;  It joins the squadron that ORDERED it, which is not necessarily the one
    ;  selected now -- see eco_build_squad in game/economy.asm.
    ld hl,(eco_ent)
    ld de,ENT_SQUAD
    add hl,de
    ld a,(eco_build_squad)
    ld (hl),a

    jp squad_refresh


; ----------------------------------------------------------------------------
;  eco_queue -- put the currently picked class on the yard's list
;  Out: CF set if it was ordered
;  Uses: everything
;
;  THE RU IS TAKEN HERE, at order time, and that is a decision rather than the
;  easiest thing to write. The player pays for what they queue: the affordable
;  test and the debit are one act at one moment, which is exactly what
;  ctx_build_state re-derives to decide whether to say ENTER BUY. Charging at
;  the head of the queue instead would let ten orders be placed for nothing and
;  then fail one at a time, minutes later, with the player looking somewhere
;  else -- and every one of those failures would need a state the yard does not
;  have ("stalled, waiting for money"), a word on the bar for it, and a rule
;  about whether a stalled order blocks the ones behind it. A queue is a plan
;  that has been paid for.
;
;  The refusals are checked in the order the bar says them: room in the yard,
;  then room in the FLEET, then the cost. Keep the two in step -- see
;  ctx_build_state.
; ----------------------------------------------------------------------------
eco_queue:
    ;  Checked here as well as in eco_pick_step, because the pick is a byte in
    ;  RAM and the panel is not the only thing that can move it -- the orders
    ;  menu injects keys, and a class that is off the list one mission is on
    ;  it the next.
    call eco_pick_allowed
    jr nc,@eco_refused

    ;  Is there room? The slipway counts as one of the ECO_QUEUE_MAX.
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,@eco_have_room                ; the slipway is empty, so there is
    ld a,(eco_queue_len)
    cp ECO_QUEUE_WAIT
    jr nc,@eco_refused                  ; ten outstanding already
@eco_have_room:

    ;  ...and is there room in the FLEET for the ship it would become? The
    ;  entity table is partitioned now (game/entity.asm), so the fleet has a
    ;  ceiling of its own and a player who builds will reach it.
    ;
    ;  The test is against the WHOLE outstanding line and not just this one
    ;  order, and that is the substance of it: the RU is taken here, at order
    ;  time, so ten orders against one free slot would be nine ships bought and
    ;  never built -- which is the same silent failure this partition exists to
    ;  end, moved one step along. Everything on the slipway or in the queue is
    ;  a slot already spoken for.
    call ent_room_ours
    ld c,a                              ; how many the fleet can still hold
    ld a,(eco_build_class)
    cp CLASS_COUNT
    ld a,(eco_queue_len)
    jr nc,@eco_want                     ; the slipway is empty
    inc a                               ; ...the half-built hull wants one too
@eco_want:
    inc a                               ; ...and so would this order
    ld b,a
    ld a,c
    cp b
    jr c,@eco_refused                   ; every free slot is already spoken for

    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld a,(hl)
    ld (eco_pick_class),a
    ld l,a
    ld h,0
    ld de,eco_class_cost
    add hl,de
    ld a,(hl)
    or a
    jr z,@eco_refused                   ; not a buildable class

    ld c,a
    ld b,0
    ld hl,(eco_ru)
    or a
    sbc hl,bc
    jr c,@eco_refused                   ; cannot afford it
    ld (eco_ru),hl

    ;  Paid for. Straight onto the slipway if it is free, otherwise onto the
    ;  end of the line.
    ld a,(squad_sel)
    ld c,a                              ; ...whoever is asking for it, NOW
    ld a,(eco_build_class)
    cp CLASS_COUNT
    ld a,(eco_pick_class)
    jr nc,@eco_to_slipway

    ld hl,eco_queue_len
    ld e,(hl)
    ld d,0
    inc (hl)
    push hl
    ld hl,eco_queue_buf
    add hl,de
    ld (hl),a
    ld hl,eco_queue_squad
    add hl,de
    ld (hl),c
    pop hl
    scf
    ret

@eco_to_slipway:
    call eco_start_build
    scf
    ret

@eco_refused:
    or a
    ret


; ----------------------------------------------------------------------------
;  eco_has_a_harvester -- is one flying, or one on the way?
;  Out: CF set if there is
;  Uses: AF
;
;  Three places a harvester can be, and all three count: on the slipway, in the
;  waiting line behind it, and in the air. Derived rather than kept in a byte,
;  for the reason squad_count is: a running total of harvesters would have to
;  be decremented by whatever kills one, and combat has no business knowing
;  about the build list.
;
;  BC and DE are pushed because this is called from inside eco_pick_allowed,
;  whose own contract is AF/DE/HL, and eco_pick_step loops on that contract.
; ----------------------------------------------------------------------------
eco_has_a_harvester:
    push bc
    push de
    push hl

    ;  On the slipway...
    ld a,(eco_build_class)
    cp CLASS_HARVESTER
    jr z,@eco_harv_yes

    ;  ...or in the waiting line behind it...
    ld a,(eco_queue_len)
    or a
    jr z,@eco_harv_flying
    ld b,a
    ld hl,eco_queue_buf
@eco_harv_queued:
    ld a,(hl)
    cp CLASS_HARVESTER
    jr z,@eco_harv_yes
    inc hl
    djnz @eco_harv_queued

    ;  ...or in the air. The player's region only: a harvester is bought from
    ;  the yard, so ent_find_free_ours is the only thing that ever placed one.
@eco_harv_flying:
    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_PLAYER_MAX
@eco_harv_one:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@eco_harv_next                ; empty, or theirs
    ;  ENT_CLASS is the byte two before ENT_FLAGS -- src/main.asm asserts that
    ;  adjacency for wave_health, and this is the second thing leaning on it.
    dec hl
    dec hl
    ld a,(hl)
    inc hl
    inc hl
    cp CLASS_HARVESTER
    jr z,@eco_harv_yes
@eco_harv_next:
    add hl,de
    djnz @eco_harv_one

    pop hl
    pop de
    pop bc
    or a
    ret

@eco_harv_yes:
    pop hl
    pop de
    pop bc
    scf
    ret


; ----------------------------------------------------------------------------
;  eco_pick_allowed -- may the currently picked class be ordered yet?
;  Out: CF set if it may
;  Uses: AF, C, DE, HL
;
;  IT IS A TABLE NOW, and the comment that used to be here predicted it: section
;  8 gates only the Destroyer, so this was one `cp` "until a second class needs
;  one". The second is the Frigate, and it needs a different KIND of condition
;  -- a flag the player sets by salvaging the derelict, not a mission number --
;  so eco_class_gate in game/classdata.asm holds a rule per class rather than a
;  mission per class. See it for the encoding.
;
;  Both doors are covered by this one routine: eco_pick_step walks past a class
;  it refuses, and eco_queue asks it again at ENTER because the pick is a byte
;  in RAM that the orders menu can move.
; ----------------------------------------------------------------------------
eco_pick_allowed:
    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld a,(hl)                           ; the class

    ;  THE ECONOMY COMES FIRST. With no harvester flying and none on the way,
    ;  the only thing the yard will take is a harvester.
    ;
    ;  It is not a difficulty rule, it is the one place this game can be spent
    ;  into a state it cannot get out of: RU only ever arrives through a
    ;  harvester, so a player with none and forty units left can buy an
    ;  interceptor and then never earn again. The build list is where that gets
    ;  decided, so the build list is where it is stopped -- and eco_pick_step
    ;  walks PAST a class it refuses, so with no harvesters the panel simply
    ;  offers one class. There is nothing to explain and nothing to refuse.
    ;
    ;  ON THE WAY counts, or the first order would lock the list to harvesters
    ;  until that one was delivered and the player would queue three.
    ;  THE CLASS GOES IN C, NOT ON THE STACK. `push af : call : pop af` is the
    ;  obvious way to keep it and it throws away the answer: POP AF restores
    ;  the FLAGS, so the carry eco_has_a_harvester just set is overwritten by
    ;  the carry that was there before the call. The helper preserves BC for
    ;  exactly this, and LD A,C touches no flag.
    ld c,a
    call eco_has_a_harvester
    ld a,c
    jr c,@eco_gates
    cp CLASS_HARVESTER
    jr nz,@eco_deny

@eco_gates:
    ld l,a
    ld h,0
    ld de,eco_class_gate
    add hl,de
    ld a,(hl)
    or a
    jr z,@eco_allow                     ; no condition: always on the list
    bit 7,a
    jr nz,@eco_gate_flag

    ;  From mission N, written 1-based the way the player counts them.
    dec a
    ld e,a
    ld a,(mis_index)                    ; ...but mis_index counts from zero
    cp e
    jr c,@eco_deny
    jr @eco_allow

    ;  Bit n of campaign_unlocks. RRCA n+1 times leaves that bit in the carry,
    ;  and DEC does not touch the carry -- so the loop lands with the answer
    ;  already in the flag the caller is going to read.
@eco_gate_flag:
    and #7F
    inc a
    ld e,a
    ld a,(campaign_unlocks)
@eco_gate_bit:
    rrca
    dec e
    jr nz,@eco_gate_bit
    jr nc,@eco_deny

@eco_allow:
    scf
    ret
@eco_deny:
    or a
    ret


; ----------------------------------------------------------------------------
;  eco_pick_step -- , and . walk the build selection
;  In : A = +1 or -1
;  Uses: everything
;
;  A class that is not available yet is STEPPED OVER rather than shown and
;  refused: the panel has room for one three-letter tag, so an entry the
;  player can see but cannot order looks like a bug in the ENTER key. The loop
;  cannot spin, because the classes with no unlock condition are always there.
; ----------------------------------------------------------------------------
eco_pick_step:
    ld (eco_pick_dir),a
@eco_pick_try:
    ld hl,eco_build_pick
    ld a,(eco_pick_dir)
    add a,(hl)
    cp CLASS_BUILDABLE
    jr c,@eco_pick_ok
    bit 7,a
    ld a,CLASS_BUILDABLE - 1
    jr nz,@eco_pick_ok
    xor a
@eco_pick_ok:
    ld (hl),a
    call eco_pick_allowed
    jr nc,@eco_pick_try
    ret


; ----------------------------------------------------------------------------
;  eco_repair_cost -- what it costs to put one ship back to full
;  In : HL -> the entity record
;  Out: HL = the price in RU, CF set if there is anything to repair
;  Uses: everything
;
;  TWICE THE SHIP'S PRICE, FOR THE FRACTION OF IT THAT IS GONE:
;
;      cost = 2 * eco_class_cost[class] * (full - hull) / full
;
;  So a half-dead interceptor costs 35 RU -- exactly what a new one costs --
;  and a nearly-dead one costs nearly seventy. That is the whole design of it
;  and it is a decision rather than an arbitrary multiplier: at 50% damage
;  repairing and replacing cost the same, so the number tells the player which
;  to do without a word of explanation. Below half, mend it; above half, let it
;  die and build another. A multiplier of one would make repair strictly better
;  than building and nobody would ever build again.
;
;  Hull is NOT recovered by building, so the two are not interchangeable in the
;  other direction: a fresh ship is a fresh SHIP, and the fleet only ever
;  shrinks (section 1). Repair is the only thing in the game that puts hull
;  back, which is why it is allowed to be expensive.
;
;  THE ARITHMETIC AVOIDS A SECOND DIVIDE. wave_frac_of gives the damage in
;  256ths, so
;
;      cost = (price * frac) >> 7
;
;  is 2 * price * frac / 256 with one mul_u8 and a shift. The product is at
;  most 250 * 255 = 63,750, which is why it is >>7 of the product rather than
;  <<1 of it -- doubling first would overflow sixteen bits at the Destroyer.
; ----------------------------------------------------------------------------
eco_repair_cost:
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    inc hl                              ; ENT_HULL is the byte after ENT_CLASS,
    ld c,(hl)                           ; which src/main.asm asserts
    pop hl

    ;  The class's full hull and its price, both bank-4 tables and both read
    ;  with the window at rest -- this runs on a keypress.
    ld e,a
    ld d,0
    ld hl,class_hull
    add hl,de
    ld b,(hl)                           ; B = full
    ld hl,eco_class_cost
    add hl,de
    ld a,(hl)
    ld (eco_rep_price),a

    ld a,b
    sub c                               ; A = full - hull
    jr nz,@eco_rep_damaged
    ld hl,0
    or a                                ; CF clear: nothing to do
    ret

@eco_rep_damaged:
    ld l,a
    ld h,0
    ld e,b
    ld d,0
    call wave_frac_of                   ; A = damage in 256ths

    ld h,a
    ld a,(eco_rep_price)
    ld l,a
    call mul_u8                         ; HL = price * frac

    ;  Rounded rather than truncated, so a ship one hull point short does not
    ;  come back free for every class.
    ld de,64
    add hl,de
    ld b,7
@eco_rep_shift:
    srl h
    rr l
    djnz @eco_rep_shift
    scf
    ret


; ----------------------------------------------------------------------------
;  eco_repair -- the E key: mend the selected squadron, as far as the RU goes
;  Uses: everything
;
;  Walks the squadron in SLOT ORDER and repairs every ship it can afford,
;  SKIPPING the ones it cannot rather than stopping at the first. Stopping
;  would let one Destroyer at 90% damage hold up four interceptors that cost
;  ten RU each, which is a rule the player would have to be told; skipping is
;  the forgiving version and the only thing it costs is that the order the
;  yard mends in is the order the ships happen to sit in.
;
;  ALL OR NOTHING PER SHIP. Buying half a repair is expressible -- the cost is
;  linear in the damage -- and it is not offered, because a partial repair
;  makes the price of the NEXT one depend on how much was bought last time and
;  the player can no longer read the cost off the ship. A ship comes back
;  whole or it does not come back.
;
;  Section 8 makes losing the Mothership the end of the game, and it is a ship
;  like any other here: it is in the squadron walk if the player has selected
;  its squadron, and it is the most expensive thing in the game to mend.
; ----------------------------------------------------------------------------
eco_repair:
    ;  ONCE A MISSION. mis_setup clears the flag, so "once per mission" is
    ;  true by construction rather than by anyone remembering to reset it.
    ld a,(eco_repaired)
    or a
    ret nz

    ;  ...AND NOT UNDER FIRE. The same predicate the jump gate asks: nothing
    ;  hostile still flying, wave ships included and wrecks excluded. The yard
    ;  works in the lulls, so repairing is something the player does after
    ;  winning the ground rather than a way of winning it -- otherwise a
    ;  treasury deep enough turns every fight into an attrition the enemy
    ;  cannot win, which is the opposite of section 1's fleet that only ever
    ;  shrinks.
    call mis_count_hostiles
    or a
    ret nz

    ld hl,entities + ENT_FLAGS
    ld (eco_walk),hl
    ld a,ENT_PLAYER_MAX
    ld (eco_index),a

@eco_rep_one:
    ld hl,(eco_walk)
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@eco_rep_next                 ; empty, or theirs

    ;  ...and in the squadron the player is looking at.
    ld hl,(eco_walk)
    inc hl                              ; ENT_SQUAD follows ENT_FLAGS
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    jr nz,@eco_rep_next

    ld hl,(eco_walk)
    ld de,-ENT_FLAGS
    add hl,de                           ; -> the record
    push hl
    call eco_repair_cost
    pop de                              ; DE -> the record
    jr nc,@eco_rep_next                 ; undamaged

    ;  Affordable? The treasury is a word and so is the price.
    ld (eco_rep_cost),hl
    ld hl,(eco_ru)
    ld bc,(eco_rep_cost)
    or a
    sbc hl,bc
    jr c,@eco_rep_next                  ; not this one; the next may be cheaper
    ld (eco_ru),hl

    ;  Back to full, out of the class table.
    ex de,hl                            ; HL -> the record
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    ld e,a
    ld d,0
    ld hl,class_hull
    add hl,de
    ld a,(hl)
    pop hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),a

    ;  A ship was actually mended, so the one repair is spent. Set here and
    ;  not at the top: a press that found nothing damaged, or nothing it could
    ;  afford, has used nothing up -- spending it on a no-op would be a rule
    ;  the player could trip over without ever seeing why.
    ld a,1
    ld (eco_repaired),a

@eco_rep_next:
    ld hl,(eco_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (eco_walk),hl
    ld hl,eco_index
    dec (hl)
    jr nz,@eco_rep_one
    ret


; ----------------------------------------------------------------------------
;  eco_scrap_value -- what breaking one ship up pays back
;  In : HL -> the entity record
;  Out: A = the refund in RU
;  Uses: everything
;
;  HALF THE PRICE, RISING TO SEVEN TENTHS FOR A SHIP IN GOOD ORDER:
;
;      refund = eco_class_cost[class] * (0.5 + 0.2 * hull / full)
;
;  "50% to 70%" was the ask and the RANGE had to be given a driver. It is the
;  HULL, not a die roll, for the reason game/salvage.asm gives about wrecks: a
;  coin toss is not something a player can act on, and "a ship in good order is
;  worth more broken up than a hulk is" is a rule they can. It is also the only
;  number on the screen that the player is already watching -- the `I` page
;  prints it per class.
;
;  IT COMPOSES WITH THE REPAIR PRICE, AND THE CROSSOVER IS THE INTERESTING
;  PART. Repair costs 2 * P * d for damage d; scrapping and rebuilding costs
;  P - refund = P * (0.3 + 0.2 * d). Repair is the cheaper of the two only
;  while 1.8 * d < 0.3 -- below about ONE SIXTH damage. So the pair of them
;  says: mend a scratch, recycle a hulk. That is a real decision and it is
;  narrower than it looks; if repair is meant to be the usual answer rather
;  than the exceptional one, it is these two constants that have to move, not
;  the code.
;
;  THE ARITHMETIC, in 256ths so that nothing needs a second divide:
;
;      frac    = 256 * hull / full          wave_frac_of
;      share   = 128 + (frac * 51 >> 8)     128..178, i.e. 50%..69.5%
;      refund  = (price * share) >> 8       and 250 * 178 fits sixteen bits
; ----------------------------------------------------------------------------
eco_scrap_value:
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    inc hl                              ; ENT_HULL follows ENT_CLASS
    ld c,(hl)
    pop hl

    ld e,a
    ld d,0
    ld hl,class_hull
    add hl,de
    ld b,(hl)                           ; B = full
    ld hl,eco_class_cost
    add hl,de
    ld a,(hl)
    ld (eco_rep_price),a

    ld l,c
    ld h,0
    ld e,b
    ld d,0
    call wave_frac_of                   ; A = hull in 256ths of full

    ld h,a
    ld l,51                             ; 0.2 of 256, near enough
    call mul_u8
    ld a,h
    add a,128                           ; the half that is unconditional
    ld h,a
    ld a,(eco_rep_price)
    ld l,a
    call mul_u8
    ld a,l
    add a,128                           ; round rather than truncate
    ld a,h
    adc a,0
    ret


; ----------------------------------------------------------------------------
;  eco_decommission -- the Y key: break the selected squadron up for RU
;  Uses: everything
;
;  Squadron-scoped, like H, T, E, A and G -- and the squadron IS the selection
;  mechanism here, which is what makes a destructive command safe enough to sit
;  on one key: `O` splits the fleet by class in one press, so "scrap the
;  scouts" is two keystrokes and never touches anything else.
;
;  THE MOTHERSHIP IS NEVER BROKEN UP. Section 8 makes losing it the end of the
;  campaign, so a key that could scrap it is a key that can end the game by
;  accident -- and moth_slot is not the test, because fleet_restore moves what
;  that points at. The CLASS is.
; ----------------------------------------------------------------------------
eco_decommission:
    ld hl,entities + ENT_FLAGS
    ld (eco_walk),hl
    ld a,ENT_PLAYER_MAX
    ld (eco_index),a

@eco_dec_one:
    ld hl,(eco_walk)
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@eco_dec_next                 ; empty, or theirs

    ld hl,(eco_walk)
    inc hl                              ; ENT_SQUAD follows ENT_FLAGS
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    jr nz,@eco_dec_next

    ld hl,(eco_walk)
    ld de,-ENT_FLAGS
    add hl,de                           ; -> the record
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    cp CLASS_MOTHERSHIP
    pop hl
    jr z,@eco_dec_next                  ; sixty thousand sleepers are not scrap

    call eco_scrap_value
    ld c,a
    call eco_earn                       ; ...which saturates at ECO_RU_MAX

    ld hl,(eco_walk)
    ld (hl),0                           ; the slot is free

@eco_dec_next:
    ld hl,(eco_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (eco_walk),hl
    ld hl,eco_index
    dec (hl)
    jr nz,@eco_dec_one

    ;  Counts are derived, so one recount puts the HUD right -- and the
    ;  selection falls back by itself if the squadron is now empty.
    jp squad_refresh


; ----------------------------------------------------------------------------
;  eco_set_harvest -- the H key: the selected squadron's HARVESTERS go to work
;
;  Section 9 marks this one "(harvesters)". Ordering the whole squadron out
;  would put fifteen interceptors on a resource patch, which mines the map
;  dry in seconds and leaves nothing on the battle line -- the economy is
;  supposed to be a choice, not a free action.
;  Uses: everything
; ----------------------------------------------------------------------------
eco_set_harvest:
    xor a
    ld (eco_index),a
@eco_order:
    ld a,(eco_index)
    call ent_addr
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    pop hl
    cp CLASS_HARVESTER
    jr nz,@eco_order_next

    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    pop hl
    jr nz,@eco_order_next

    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_HARVEST

@eco_order_next:
    ld hl,eco_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@eco_order
    ret


