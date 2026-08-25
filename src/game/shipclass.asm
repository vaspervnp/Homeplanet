; ============================================================================
;  game/shipclass.asm -- what each ship class looks like
; ============================================================================
;  One table, indexed by class and then by size tier, giving the blitter
;  everything it needs. Entities carry a class in ENT_CLASS; the projection
;  picks the tier from depth; between them they name a sprite block.
;
;  The Mothership has no art yet, so it borrows the Frigate's -- the biggest
;  capital silhouette drawn so far. It reads as a capital ship at tier C,
;  which is the point, and swapping it for its own sprites later is a change
;  to this table and nothing else.
; ----------------------------------------------------------------------------

CLASS_INTERCEPTOR   equ 0
CLASS_MOTHERSHIP    equ 1
CLASS_HARVESTER     equ 2
CLASS_COUNT         equ 3

;  Classes the yard will build, which is every class up to but not including
;  the Mothership... except the Mothership is class 1, so the buildable ones
;  are named explicitly by eco_build_order instead.
CLASS_BUILDABLE     equ 2

;  How many size tiers to draw a class ABOVE what its distance alone would
;  give. The tiers are a distance ladder, not a size one, so without this a
;  capital ship at 200 units draws exactly as big as a fighter at 200 units
;  and the fleet reads as a swarm of identical specks. A bias of one is the
;  cheap stand-in for the larger sprite sheets capital ships will eventually
;  have of their own.
class_tier_bias:
    defb 0                              ; interceptor
    defb 1                              ; mothership
    defb 0                              ; harvester

;  Per tier: base address, width in bytes, height, half width and half height
;  in pixels (for centring), and the size of one (frame, pre-shift) block.
CLASS_TIER_SIZE     equ 8
CLASS_STRIDE        equ CLASS_TIER_SIZE * 3


; ----------------------------------------------------------------------------
;  class_apply_bias -- A = the tier class B should actually draw at
;  In : A = tier from the distance table, B = class
;  Out: A = tier, clamped to the largest that exists
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
class_apply_bias:
    ld l,a
    ld a,b
    ld h,0
    push hl
    ld l,a
    ld de,class_tier_bias
    add hl,de
    ld a,(hl)
    pop hl
    add a,l
    cp 3
    ret c
    ld a,2                              ; tier C is as large as it gets
    ret


; ----------------------------------------------------------------------------
;  class_tier_addr -- HL = the descriptor for class B, tier C
;  In : B = class, C = tier 0..2
;  Out: HL -> eight bytes of descriptor
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
class_tier_addr:
    ;  CLASS_STRIDE is 24, which is 16 + 8, so two shifts and an add.
    ld a,b
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; class * 8
    ld d,h
    ld e,l
    add hl,hl                           ; class * 16
    add hl,de                           ; class * 24

    ld a,c
    add a,a
    add a,a
    add a,a                             ; tier * 8
    ld e,a
    ld d,0
    add hl,de

    ld de,class_tiers
    add hl,de
    ret


; ============================================================================
;  The table
; ============================================================================
class_tiers:
    ; --- interceptor: far, middle, near --------------------------------
    defw interceptor_a
    defb interceptor_a_w_bytes, interceptor_a_h
    defb interceptor_a_w_px / 2, interceptor_a_h / 2
    defw interceptor_a_block_sz

    defw interceptor_b
    defb interceptor_b_w_bytes, interceptor_b_h
    defb interceptor_b_w_px / 2, interceptor_b_h / 2
    defw interceptor_b_block_sz

    defw interceptor_c
    defb interceptor_c_w_bytes, interceptor_c_h
    defb interceptor_c_w_px / 2, interceptor_c_h / 2
    defw interceptor_c_block_sz

    ; --- mothership, wearing the frigate's sprites ----------------------
    defw frigate_a
    defb frigate_a_w_bytes, frigate_a_h
    defb frigate_a_w_px / 2, frigate_a_h / 2
    defw frigate_a_block_sz

    defw frigate_b
    defb frigate_b_w_bytes, frigate_b_h
    defb frigate_b_w_px / 2, frigate_b_h / 2
    defw frigate_b_block_sz

    defw frigate_c
    defb frigate_c_w_bytes, frigate_c_h
    defb frigate_c_w_px / 2, frigate_c_h / 2
    defw frigate_c_block_sz

    ; --- harvester: the frigate's hull again, at fighter scale -----------
    ;  A working ship, blunter than an interceptor. It has no art of its own
    ;  yet; when it gets some, this table is the only thing that changes.
    defw frigate_a
    defb frigate_a_w_bytes, frigate_a_h
    defb frigate_a_w_px / 2, frigate_a_h / 2
    defw frigate_a_block_sz

    defw frigate_b
    defb frigate_b_w_bytes, frigate_b_h
    defb frigate_b_w_px / 2, frigate_b_h / 2
    defw frigate_b_block_sz

    defw frigate_c
    defb frigate_c_w_bytes, frigate_c_h
    defb frigate_c_w_px / 2, frigate_c_h / 2
    defw frigate_c_block_sz
