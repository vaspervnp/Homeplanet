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
; ----------------------------------------------------------------------------

ECO_PATCH_COUNT         equ 4
ECO_PATCH_SIZE      equ 8               ; x, y, z (6) + stock (2)

ECO_HARVEST_RANGE   equ 24              ; camera-scale, as combat's range is
ECO_LOAD_MAX        equ 60              ; RU a harvester carries
ECO_LOAD_RATE       equ 3               ; RU mined per frame in contact
ECO_START_RU        equ 120

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

    ld hl,eco_patch_seed
    ld de,eco_patches
    ld bc,ECO_PATCH_COUNT * ECO_PATCH_SIZE
    ldir

    xor a
    ld (eco_build_open),a
    ld (eco_build_timer),a
    ld (eco_build_pick),a
    ld a,#FF
    ld (eco_build_class),a              ; nothing under construction
    ret


; ----------------------------------------------------------------------------
;  eco_update -- one frame of the economy
;  Uses: everything
; ----------------------------------------------------------------------------
eco_update:
    call eco_run_harvesters
    jp eco_run_yard


; ----------------------------------------------------------------------------
;  eco_run_harvesters -- move every harvesting ship one step through its cycle
;
;  Outbound with an empty hold, mining while it sits on a patch, homebound
;  when full, and paid out when it reaches the Mothership. The ship's
;  destination is written straight into its squadron's station... no: into the
;  ship's own ENT_DEST, because a harvester leaves its formation to work.
;  Uses: everything
; ----------------------------------------------------------------------------
eco_run_harvesters:
    xor a
    ld (eco_index),a
@eco_ship:
    ld a,(eco_index)
    call ent_addr
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
    jr nz,@eco_next

    call eco_harvester_step

@eco_next:
    ld hl,eco_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@eco_ship
    ret


; ----------------------------------------------------------------------------
;  eco_harvester_step -- one harvester's turn
;  In : (eco_ent)
;  Uses: everything
; ----------------------------------------------------------------------------
eco_harvester_step:
    ld hl,(eco_ent)
    ld de,ENT_LOAD
    add hl,de
    ld a,(hl)                           ; the hold
    cp ECO_LOAD_MAX
    jr nc,@eco_homebound

    ;  Outbound: find a patch with something left in it and close on it.
    call eco_nearest_patch
    ret nc                              ; everything is mined out
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

    ld b,0
    ld hl,(eco_ru)
    add hl,bc
    ld (eco_ru),hl
    ret


; ----------------------------------------------------------------------------
;  eco_at_target -- close on (eco_patch_ptr) and say whether we have arrived
;  In : (eco_ent), (eco_patch_ptr) -> six bytes of position
;  Out: CF set if within ECO_HARVEST_RANGE
;  Uses: everything
; ----------------------------------------------------------------------------
eco_at_target:
    ;  Steer: one step per axis, the same approach the formations use.
    ld hl,(eco_ent)
    ld (phase4_coord_ptr),hl
    ld hl,(eco_patch_ptr)
    ld (eco_axis_ptr),hl
    ld a,3
    ld (eco_axis),a
@eco_axis:
    ld hl,(eco_axis_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (eco_axis_ptr),hl
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

    ld hl,eco_axis
    dec (hl)
    jr nz,@eco_axis

    jp eco_range_check


; ----------------------------------------------------------------------------
;  eco_range_check -- Manhattan distance between (cbt_ent) and (cbt_other_pos)
;  In : (eco_ent) and (eco_patch_ptr)
;  Out: CF set if within ECO_HARVEST_RANGE
;  Uses: everything
; ----------------------------------------------------------------------------
eco_range_check:
    ld hl,(eco_ent)
    ld (eco_a_ptr),hl
    ld hl,(eco_patch_ptr)
    ld (eco_b_ptr),hl
    xor a
    ld (eco_dist),a
    ld a,3
    ld (eco_axis),a

@eco_dist_axis:
    ld hl,(eco_a_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (eco_a_ptr),hl

    ld hl,(eco_b_ptr)
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld (eco_b_ptr),hl

    ld h,d
    ld l,e
    or a
    sbc hl,bc

    ;  The same |HL| >> WORLD_SHIFT that cbt_distance does, and for the same
    ;  reason: ECO_HARVEST_RANGE is in camera units, so the shift has to match
    ;  the projection's or a harvester docks from four times too far away.
    ;  P/V first -- a difference that did not fit sixteen bits is far, and the
    ;  sign bit lies about which way.
    jp pe,@eco_far
    bit 7,h
    jr z,@eco_pos
    xor a
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
@eco_pos:
    ld a,h
    cp PROJ_V_BIAS * 2
    jr nc,@eco_far
    add hl,hl
    add hl,hl
    ld a,h

    ld hl,eco_dist
    add a,(hl)
    jr c,@eco_far
    ld (hl),a
    cp ECO_HARVEST_RANGE
    jr nc,@eco_far

    ld hl,eco_axis
    dec (hl)
    jr nz,@eco_dist_axis
    scf
    ret
@eco_far:
    or a
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
; ----------------------------------------------------------------------------
eco_run_yard:
    ld a,(eco_build_class)
    cp CLASS_COUNT
    ret nc                              ; nothing on the slipway

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
;  eco_spawn_built -- a finished ship appears at the Mothership
;  Uses: everything
; ----------------------------------------------------------------------------
eco_spawn_built:
    call ent_find_free
    ret nc                              ; the table is full; the RU is spent

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
;  eco_queue -- try to start building the currently picked class
;  Out: CF set if it was ordered
;  Uses: everything
; ----------------------------------------------------------------------------
eco_queue:
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr c,@eco_busy                      ; one at a time

    ;  Checked here as well as in eco_pick_step, because the pick is a byte in
    ;  RAM and the panel is not the only thing that can move it -- the orders
    ;  menu injects keys, and a class that is off the list one mission is on
    ;  it the next.
    call eco_pick_allowed
    jr nc,@eco_busy

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
    jr z,@eco_busy                      ; not a buildable class

    ld c,a
    ld b,0
    ld hl,(eco_ru)
    or a
    sbc hl,bc
    jr c,@eco_busy                      ; cannot afford it
    ld (eco_ru),hl

    ld a,(eco_pick_class)
    ld (eco_build_class),a
    ld l,a
    ld h,0
    ld de,eco_class_frames
    add hl,de
    ld a,(hl)
    ld (eco_build_timer),a
    scf
    ret
@eco_busy:
    or a
    ret


; ----------------------------------------------------------------------------
;  eco_pick_allowed -- may the currently picked class be ordered yet?
;  Out: CF set if it may
;  Uses: AF, DE, HL
;
;  Section 8 gives the Destroyer as "διαθέσιμο από την 5η αποστολή" and gives
;  no such condition to anything else, so this is one test rather than a table
;  of unlock missions. It becomes a table the moment a second class needs one.
; ----------------------------------------------------------------------------
eco_pick_allowed:
    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld a,(hl)
    cp CLASS_DESTROYER
    jr nz,@eco_allow
    ld a,(mis_index)                    ; missions count from zero
    cp CLASS_DESTROYER_MIS
    jr c,@eco_deny
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
eco_axis_ptr:       defw 0
eco_a_ptr:          defw 0
eco_b_ptr:          defw 0
eco_axis:           defb 0
eco_dist:           defb 0
eco_new_slot:       defb 0
eco_pick_class:     defb 0
eco_pick_dir:       defb 0
eco_amount:         defb 0

eco_build_open:     defb 0              ; the panel is showing
eco_build_pick:     defb 0              ; which class the panel is offering
eco_build_class:    defb #FF            ; what is on the slipway
eco_build_timer:    defb 0

eco_patches:        defs ECO_PATCH_COUNT * ECO_PATCH_SIZE, 0

;  eco_patch_seed -- where the fields are and how much is in them -- is in
;  game/classdata.asm, in bank 4. It is copied once, by eco_init.
