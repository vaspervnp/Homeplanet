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
;  ent_find_free -- the first slot not in use
;  Out: CF set and A = the slot, or CF clear if the table is full
;  Uses: everything
; ----------------------------------------------------------------------------
ent_find_free:
    xor a
    ld (ent_index),a
@ent_free_try:
    ld a,(ent_index)
    call ent_addr
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
    cp ENT_MAX
    jr c,@ent_free_try
    or a
    ret


; ============================================================================
;  Storage
; ============================================================================
ent_index:          defb 0
entities:           defs ENT_MAX * ENT_SIZE, 0
