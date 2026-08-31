; ============================================================================
;  game/economy.asm -- resources, harvesters and construction (phase 7)
; ============================================================================
;  The loop the design calls for: harvesters fly to a resource patch, fill up,
;  fly back to the Mothership, and turn what they carry into RU. RU pays for
;  new ships, which come out of the Mothership one at a time.
;
;      H   put the selected squadron on harvesting duty
;      B   open the build panel; , and . pick a class, ENTER queues it
;
;  A harvester's whole state is its ENT_ORDER plus how much it is carrying, so
;  there is no separate harvester table to keep in step with the entity list --
;  the same reason squad_count is recounted rather than maintained.
;
;  Patches are fixed points with a stock that runs down. When one is empty the
;  harvesters that were using it look for another; when they are all empty the
;  economy stops, which is the pressure the mission design wants.
;
;  THE QUEUE
;  ---------
;  Section 5.5 asks the HUD strip for "Πόροι (RU) και ουρά κατασκευής" -- the
;  resources AND the build queue -- and for a long time there was no queue: the
;  yard took one order and refused every other. So a player who had just mined
;  a field dry had to sit and watch a countdown before they could spend the
;  next 40 RU, which is the opposite of what an economy is for.
;
;  It is a FIFO of ECO_QUEUE_MAX orders, mixed classes, and the head of it IS
;  the slipway: eco_build_class and eco_build_timer keep meaning exactly what
;  they meant, and the array behind them holds the ones still waiting. That is
;  why the array is one short of the maximum -- ten orders outstanding is the
;  slipway plus nine in the line. Keeping the head where it was rather than at
;  index 0 of the array is what stops this being two copies of "what is being
;  built": the HUD, ctx_build_state and half a dozen tests all read
;  eco_build_class and none of them had to learn a new name.
; ----------------------------------------------------------------------------

ECO_PATCH_COUNT         equ 4
ECO_PATCH_SIZE      equ 8               ; x, y, z (6) + stock (2)

ECO_HARVEST_RANGE   equ 24              ; camera-scale, as combat's range is
ECO_LOAD_MAX        equ 60              ; RU a harvester carries
ECO_LOAD_RATE       equ 3               ; RU mined per frame in contact
ECO_START_RU        equ 120

;  Orders the yard will hold at once, the one on the slipway included.
ECO_QUEUE_MAX       equ 10
ECO_QUEUE_WAIT      equ ECO_QUEUE_MAX - 1   ; ...so nine of them are waiting

;  The ceiling on RU, and it is the READOUT's rather than the arithmetic's.
;  eco_ru is a word and always has been, but phase4_hud draws it with
;  txt_draw_num4, which subtracts powers of ten into four digits: hand it
;  16600 and the thousands column comes out as '@'. The patches carry several
;  times what they used to (see game/campaign.asm), so a whole campaign's
;  mining now adds up past 65535 if none of it is ever spent -- which would
;  wrap the word as well as break the field. Saturating at what the strip can
;  say keeps the number on screen equal to the number in memory, which is the
;  only property worth having here.
ECO_RU_MAX          equ 9999

;  eco_build_order, eco_class_cost and eco_class_frames are in
;  game/classdata.asm, in bank 4 with the rest of the per-class tables. They
;  are read when the player presses ENTER, which is never inside the one
;  window where bank 4 is paged out.


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
    ld hl,entities
    ld (eco_walk),hl
    ld a,ENT_MAX
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
    ld a,(eco_queue_buf)                ; the oldest order, and it goes first
    call eco_start_build

    ;  Shuffle the rest down. Nine bytes at worst, once a ship, against a head
    ;  index that every reader of the queue would then have to know about.
    ld a,(eco_queue_len)
    or a
    ret z
    ld c,a
    ld b,0
    ld hl,eco_queue_buf + 1
    ld de,eco_queue_buf
    ldir
    ret


; ----------------------------------------------------------------------------
;  eco_start_build -- class A goes on the slipway, with its own build time
;  In : A = the class
;  Uses: everything
;
;  eco_class_frames is in bank 4, which is legal here for the reason
;  game/shipclass.asm gives: both callers run with the window at rest.
; ----------------------------------------------------------------------------
eco_start_build:
    ld (eco_build_class),a
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
    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld (hl),0

    ;  It joins the squadron that ordered it.
    ld hl,(eco_ent)
    ld de,ENT_SQUAD
    add hl,de
    ld a,(squad_sel)
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
    ld a,(eco_build_class)
    cp CLASS_COUNT
    ld a,(eco_pick_class)
    jr nc,@eco_to_slipway

    ld hl,eco_queue_len
    ld e,(hl)
    ld d,0
    inc (hl)
    ld hl,eco_queue_buf
    add hl,de
    ld (hl),a
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
;  eco_pick_allowed -- may the currently picked class be ordered yet?
;  Out: CF set if it may
;  Uses: AF, DE, HL
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


; ============================================================================
;  State
; ============================================================================
eco_ru:             defw 0              ; resource units in hand
eco_index:          defb 0
eco_ent:            defw 0
eco_patch_ptr:      defw 0
eco_walk:           defw 0
eco_new_slot:       defb 0
eco_pick_class:     defb 0
eco_pick_dir:       defb 0
eco_amount:         defb 0

eco_build_open:     defb 0              ; the panel is showing
eco_build_pick:     defb 0              ; which class the panel is offering
eco_build_class:    defb #FF            ; what is on the slipway
eco_build_timer:    defb 0

;  The orders WAITING behind the slipway, oldest first. The one being built is
;  eco_build_class and is not in here, so a full yard is eco_build_class set
;  and eco_queue_len == ECO_QUEUE_WAIT.
;
;  None of this is touched by mis_setup, so the queue -- like the half-built
;  hull on the slipway, which has always behaved this way -- SURVIVES A JUMP.
;  It has to: the RU was taken when the order was placed, so throwing the queue
;  away at the jump would silently destroy the player's money, and refunding it
;  is a second rule that would have to be kept in step with the first. Section
;  10's fleet carries between missions with its losses; the yard is part of
;  that fleet.
eco_queue_len:      defb 0
eco_queue_buf:      defs ECO_QUEUE_WAIT, 0

;  Where the fields are and how much is left in them. Written only by
;  mis_setup, out of the mission descriptor in bank 4.
eco_patches:        defs ECO_PATCH_COUNT * ECO_PATCH_SIZE, 0
