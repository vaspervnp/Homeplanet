; ============================================================================
;  game/entity.asm -- the entity table (Homeplanet.md section 7)
; ============================================================================
;  48 slots of 20 bytes. Everything in the battle is one of these: ships,
;  wrecks, the Mothership. A slot is free when ENT_F_ACTIVE is clear.
;
;  The fleet is PERMANENT (section 1) -- what survives a mission starts the
;  next one -- so this table is also the save format, give or take the fields
;  that only mean something mid-battle.
; ----------------------------------------------------------------------------

ENT_MAX             equ 48
ENT_SIZE            equ 20

;  THE TABLE IS PARTITIONED BY INDEX, and it is one array still.
;
;      slots 0 .. ENT_PLAYER_MAX-1        the fleet, and the Mothership
;      slots ENT_PLAYER_MAX .. ENT_MAX-1  hostiles, waves, wrecks
;
;  It used to be one pool for everything, allocated from zero, and that is a
;  bug with a very quiet symptom: a player who builds hard fills the low slots,
;  wave_send then cannot find anywhere to put a wave, and THE WAVES SILENTLY
;  STOP. The one mechanism that makes `J` a decision rather than a formality
;  switches itself off for the player who has done best at the game, and
;  nothing reports it.
;
;  The numbers are a decision about who gets the FRAME, not about who gets
;  memory -- 24 entities measure at 5.8-6.5 fps against a 12.5 target, so the
;  table has held more than can be drawn for a long time. Twenty-eight is the
;  starting sixteen plus the ten a full build queue can deliver, plus two; and
;  twenty is mission 7's picket of twelve with one whole WAVE_MAX wave still
;  able to land on top of it. A wreck is NOT a third thing to make room for:
;  slv_make_wreck converts the hostile in place and takes no new slot.
;
;  A picket that did not fit would be silent in exactly the way this change
;  exists to stop, so it is held from the other end: mis_setup runs after
;  mis_clear_enemies, so the whole hostile region is free when a mission is
;  laid out, and tests/test_campaign.TestEveryPicketFits reads the enemy count
;  out of every row of mission_table and checks it against ENT_ENEMY_MAX.
ENT_PLAYER_MAX      equ 28
ENT_ENEMY_MAX       equ ENT_MAX - ENT_PLAYER_MAX

ENT_X               equ 0               ; world position, 16-bit signed
ENT_Y               equ 2
ENT_Z               equ 4
ENT_YAW             equ 6               ; orientation, 256ths of a turn
ENT_PITCH           equ 7
ENT_SPEED           equ 8
ENT_CLASS           equ 9               ; index into the ship class table
ENT_HULL            equ 10              ; 0-255
ENT_FLAGS           equ 11
ENT_SQUAD           equ 12              ; 1-9, or 0 for none
ENT_ORDER           equ 13              ; MOVE / ATTACK / GUARD / ...
ENT_TARGET          equ 14              ; entity index
ENT_DEST            equ 15              ; 4 bytes, reserved for the packed
                                        ; 12-bit order destination

;  A harvester's hold, borrowed from the first of those reserved bytes.
;  Deliberately NOT ENT_TIMER: combat decrements that every frame as a weapon
;  cooldown, and a hold that drains itself would be a puzzling thing to debug.
ENT_LOAD            equ 15

;  ...and a Salvage Corvette's tow, borrowed from the second. A corvette is
;  never a harvester, so the two could have shared a byte; they do not, because
;  "the hold" and "which wreck" are different kinds of thing and a class that
;  ever did both would be a silent bug rather than a build error.
;
;  IT IS A SLOT INDEX, AND A SLOT INDEX NAMES SOMETHING WHATEVER IS IN IT --
;  ent_clear_all leaves this zero, which is slot 0, which is a real ship. So
;  nothing trusts it: slv_towing re-checks that the slot it names is actually
;  an ACTIVE, ENEMY, DISABLED hull before believing a corvette is towing it.
;  That is the "never trust a slot index" rule from CLAUDE.md paid for once,
;  at the point of use, instead of a second initialisation pass here.
ENT_TOW             equ 16

ENT_TIMER           equ 19              ; weapon cooldown / general counter

ENT_F_ACTIVE        equ %00000001
ENT_F_ENEMY         equ %00000010

;  Crippled: a hull that is still in the table but is no longer a ship. It does
;  not fire, is not fired at, does not close on anything and does not count
;  towards a CLEAR objective -- see game/salvage.asm for all four and for why
;  each one is where it is. A Salvage Corvette tows it to the Mothership and
;  the yard pays for the wreck.
ENT_F_DISABLED      equ %00000100

;  Arrived with an attack wave rather than with the mission (game/waves.asm).
;  The ONE thing it changes is that mis_count_enemies looks past it: a CLEAR
;  objective asks for the mission's own picket, and counting the arrivals would
;  make the objective uncompletable the moment the first wave landed -- so `J`
;  would never be offered and the waves would trap the player in the mission
;  they exist to push them out of.
ENT_F_WAVE          equ %00001000

ENT_ORDER_IDLE      equ 0
ENT_ORDER_MOVE      equ 1
ENT_ORDER_ATTACK    equ 2
ENT_ORDER_GUARD     equ 3
ENT_ORDER_HARVEST   equ 4
ENT_ORDER_DOCK      equ 5
;  Section 8's Salvage Corvette, "ρυμουλκεί εχθρικά ναυάγια στο Mothership".
;  Exactly the same shape as HARVEST: the ship leaves its formation, flies out,
;  picks something up, brings it back and is paid for it -- so phase4_fly has to
;  skip it for the same reason, and eco_run_workers walks it in the same loop.
ENT_ORDER_TOW       equ 6

;  ENT_TARGET holds a slot index; this means nobody.
ENT_NO_TARGET       equ #FF


; ----------------------------------------------------------------------------
;  ent_addr -- HL = &entities[A]
;  In : A = slot index 0..47
;  Out: HL = its record
;  Uses: AF, DE, HL
;
;  20 = 16 + 4, so the index shifts up twice, gets kept, then shifts up twice
;  more and adds the copy back. Cheaper than a multiply and it is called for
;  every entity, several times a frame.
; ----------------------------------------------------------------------------
ent_addr:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; index * 4
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl                           ; index * 16
    add hl,de                           ; index * 20
    ld de,entities
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  ent_clear_all -- mark every slot free
;  Uses: everything
; ----------------------------------------------------------------------------
ent_clear_all:
    ld hl,entities
    ld de,entities + 1
    ld (hl),0
    ld bc,ENT_MAX * ENT_SIZE - 1
    ldir

    ;  A zeroed ENT_TARGET names slot 0, not "nobody". Every spawn would
    ;  otherwise come up aimed at whatever is in the first slot.
    xor a
    ld (ent_index),a
@ent_untarget:
    ld a,(ent_index)
    call ent_addr
    ld de,ENT_TARGET
    add hl,de
    ld (hl),ENT_NO_TARGET
    ld hl,ent_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@ent_untarget
    ret


; ----------------------------------------------------------------------------
;  ent_is_active -- CF set if slot A is in use
;  In : A = slot index
;  Out: CF set = active, A preserved is NOT guaranteed
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
ent_is_active:
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    rra                                 ; ENT_F_ACTIVE is bit 0 -> carry
    ret


; ----------------------------------------------------------------------------
;  ent_find_free_ours / ent_find_free_theirs -- the first free slot of a REGION
;  Out: CF set and A = the slot (and (ent_index) = it too), or CF clear if that
;       region is full
;  Uses: everything
;
;  Two entry points over a range rather than two tables: every walking loop in
;  the game already steps the whole array looking at ENT_FLAGS, so phase4_fly,
;  phase4_project, cbt_update, wave_health and squad_refresh need to know
;  nothing about the partition at all.
;
;  There is deliberately no `ent_find_free` left for anybody to call. A spawn
;  has a side, always, and a routine that did not have to say which is a
;  routine that would go back to allocating the fleet's slots to hostiles the
;  first time somebody added a spawner -- the same reasoning that gives
;  game/shipclass.asm no separate spr_select_bank.
; ----------------------------------------------------------------------------
ent_find_free_ours:
    xor a
    ld c,ENT_PLAYER_MAX
    jr ent_find_free_range
ent_find_free_theirs:
    ld a,ENT_PLAYER_MAX
    ld c,ENT_MAX
ent_find_free_range:
    ld (ent_index),a
@ent_free_try:
    ld a,(ent_index)
    call ent_addr                       ; AF, DE, HL -- C survives it
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr nz,@ent_free_next
    ld a,(ent_index)
    scf
    ret
@ent_free_next:
    ld hl,ent_index
    inc (hl)
    ld a,(hl)
    cp c
    jr c,@ent_free_try
    or a
    ret


; ----------------------------------------------------------------------------
;  ent_room_ours -- how many of the fleet's slots are free
;  Out: A = 0..ENT_PLAYER_MAX
;  Uses: everything
;
;  Walks the ENT_FLAGS byte and steps by ENT_SIZE, the way wave_health does,
;  rather than calling ent_addr twenty-eight times -- an empty slot costs a
;  load and a shift.
;
;  Two callers, and they have to agree: eco_queue refuses an order the fleet
;  has no room for, and ctx_build_state re-derives the same answer to put
;  FLEET FULL on the context bar. Counting rather than "is there one free"
;  is the point -- the yard takes the RU when the order is PLACED, so a queue
;  of ten against one free slot would be nine ships paid for and never built,
;  which is the bug being fixed moved one step along.
; ----------------------------------------------------------------------------
ent_room_ours:
    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_PLAYER_MAX
    ld c,0
@ent_room_one:
    ld a,(hl)
    rra                                 ; ENT_F_ACTIVE is bit 0
    jr c,@ent_room_next
    inc c
@ent_room_next:
    add hl,de
    djnz @ent_room_one
    ld a,c
    ret


; ============================================================================
;  Storage
; ============================================================================
ent_index:          defb 0
entities:           defs ENT_MAX * ENT_SIZE, 0
