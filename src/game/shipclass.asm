; ============================================================================
;  game/shipclass.asm -- the eight classes of Homeplanet.md section 8
; ============================================================================
;  Entities carry a class in ENT_CLASS; the projection picks a size tier from
;  depth; between them they name a sprite block. This file turns (class, tier)
;  into an address. Everything else that differs between classes -- cost,
;  hull, damage row, tier bias, the three-letter tag -- is DATA and lives in
;  game/classdata.asm, in bank 4.
;
;  WHICH BANK A CLASS LIVES IN, AND WHO IS ALLOWED TO PAGE
;  ------------------------------------------------------
;  A sprite library is 4320 bytes and there are eight of them -- 33.75 KB,
;  which is nowhere near bank 4. Three fit in a 16K window, so:
;
;      bank 5   interceptor, mothership, harvester   \
;      bank 6   scout, bomber, frigate                > raw sectors on the
;      bank 7   salvage, destroyer                   /  disc, read in by
;                                                       lib_load at boot
;
;  Bank 4 holds NO sprite library at all now. It used to carry the interceptor
;  and the frigate, which made them the two classes guaranteed to be in memory
;  and therefore the stand-ins for everything else; with all eight on the disc
;  there is nothing to stand in, so class_use_fallback paints one instead --
;  see game/classdata.asm.
;
;  Bank 4 is not just sprites any more: the title screen, the help page, the
;  orders menu, the mission table and the fleet buffer all live there, and the
;  first three of those are CODE that runs from #4000. Page another bank in
;  while any of that is executing and it vanishes underneath the program
;  counter.
;
;  So there is exactly one rule, and one routine that can break it:
;
;      BANK 4 IS THE RESTING STATE. The only code that leaves it is
;      class_tier_addr, and the only code that runs before bank 4 comes back
;      is phase4_blit_one -- which restores it on every exit path, because
;      class_blit_done is the routine it returns through.
;
;  Making the paging part of class_tier_addr rather than a step beside it is
;  deliberate: you cannot get a sprite's address without its library being
;  under the window, because the same three instructions do both. A comment
;  saying "remember to select the bank first" would have been forgotten once.
;
;  Everything touched between those two points is in the low 16K: the two
;  tables below, the blitter in gfx/sprite.asm, and the screen at #8000 and
;  #C000. src/main.asm asserts the first of those.
; ----------------------------------------------------------------------------

CLASS_INTERCEPTOR   equ 0
CLASS_MOTHERSHIP    equ 1
CLASS_HARVESTER     equ 2
CLASS_SCOUT         equ 3
CLASS_BOMBER        equ 4
CLASS_FRIGATE       equ 5
CLASS_SALVAGE       equ 6
CLASS_DESTROYER     equ 7
CLASS_COUNT         equ 8

;  What the yard offers. The Mothership is not on the list -- section 8 gives
;  it no cost, and there is only ever one.
CLASS_BUILDABLE     equ 7

;  Section 8 makes the Destroyer "διαθέσιμο από την 5η αποστολή". Missions are
;  counted from zero internally, so mission 5 is index 4.
CLASS_DESTROYER_MIS equ 4

CLASS_TIERS         equ 3               ; far, middle, near

;  How big the painted stand-in is, in bytes. Every class and every tier points
;  at the SAME block of bank 4 when there is no disc, so it has to be as long
;  as the greediest of them: tier C is six yaw views by two pre-shifts by
;  interceptor_c_block_sz, and the two smaller tiers step by less and stay
;  inside it. The block itself is declared after bank4_end in src/main.asm, so
;  it has no starting contents and costs DISC.BIN nothing.
;
;  Written out as a number rather than as the expression, because RASM
;  evaluates a `defs` where it stands and the sprite libraries are assembled in
;  a LATER bank than the block. src/main.asm asserts it once everything is in
;  scope -- the same arrangement gfx/mark.asm's patch cache uses.
;
;  IT WAS 2688 AND IT IS 432, which is 2256 bytes of the bank WINDOW back --
;  and that window, not the image and not DISC.BIN, is what the project ran out
;  of when the title screen got music. The old figure was six views by two
;  shifts by a TIER C block, because every tier pointed into one buffer and the
;  largest read had to stay inside it.
;
;  class_use_fallback now flattens class_geom to tier A's row as well, so on a
;  machine with no disc every ship draws a 3x6 rectangle instead of one that is
;  3x6, 5x10 or 7x16 by distance. The largest read is a tier A library and the
;  buffer is one. Eleven bytes of LDIR buys two kilobytes, and what it costs is
;  that the stand-ins no longer change size with range -- on a screen that is
;  already drawing solid blocks because there is no art at all.
CLASS_STANDIN_SIZE  equ 432


; ----------------------------------------------------------------------------
;  class_bank -- which extended bank holds each class's sprite library
;
;  RAM, not constants: class_use_fallback rewrites it when there is no disc to
;  read the disc-resident libraries from, so a machine with no drive draws
;  stand-ins instead of noise.
; ----------------------------------------------------------------------------
class_bank:
    defb GA_BANK_5                      ; interceptor
    defb GA_BANK_5                      ; mothership
    defb GA_BANK_5                      ; harvester
    defb GA_BANK_6                      ; scout
    defb GA_BANK_6                      ; bomber
    defb GA_BANK_6                      ; frigate
    defb GA_BANK_7                      ; salvage corvette
    defb GA_BANK_7                      ; destroyer


; ----------------------------------------------------------------------------
;  class_sprite -- where each (class, tier) starts. Three words a class.
;
;  This used to be an eight-byte descriptor per (class, tier) carrying the
;  width, height and block size beside the address -- 192 bytes, and 126 of
;  them were the same numbers written out twenty-four times. Every class uses
;  the SAME three tiers, because tools/mkships.py renders all eight from one
;  TIERS list, so the geometry belongs in one table and only the address is
;  per class. The low 16K did not have the 126 bytes to spare.
;
;  Also RAM: class_use_fallback rewrites it. It has to stay in the low 16K,
;  because it is read after class_tier_addr has paged bank 4 out.
; ----------------------------------------------------------------------------
CLASS_SPRITE_STRIDE equ CLASS_TIERS * 2

class_sprite:
    defw interceptor_a, interceptor_b, interceptor_c     ; bank 5
    defw mothership_a,  mothership_b,  mothership_c      ; bank 5
    defw harvester_a,   harvester_b,   harvester_c       ; bank 5
    defw scout_a,       scout_b,       scout_c           ; bank 6
    defw bomber_a,      bomber_b,      bomber_c          ; bank 6
    defw frigate_a,     frigate_b,     frigate_c         ; bank 6
    defw salvage_a,     salvage_b,     salvage_c         ; bank 7
    defw destroyer_a,   destroyer_b,   destroyer_c       ; bank 7
class_sprite_end:


; ----------------------------------------------------------------------------
;  class_geom -- the three tiers, shared by every class
;
;  Width in bytes, height in lines, half width and half height in pixels (for
;  centring), and the size of one (frame, pre-shift) block. Written in terms
;  of the interceptor's equates because one class has to be the reference;
;  src/main.asm asserts that the other seven agree.
; ----------------------------------------------------------------------------
CLASS_GEOM_SIZE     equ 6

class_geom:
    defb interceptor_a_w_bytes, interceptor_a_h
    defb interceptor_a_w_px / 2, interceptor_a_h / 2
    defw interceptor_a_block_sz

    defb interceptor_b_w_bytes, interceptor_b_h
    defb interceptor_b_w_px / 2, interceptor_b_h / 2
    defw interceptor_b_block_sz

    defb interceptor_c_w_bytes, interceptor_c_h
    defb interceptor_c_w_px / 2, interceptor_c_h / 2
    defw interceptor_c_block_sz
class_geom_end:


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
    cp CLASS_TIERS
    ret c
    ld a,CLASS_TIERS - 1                ; tier C is as large as it gets
    ret


; ----------------------------------------------------------------------------
;  class_tier_addr -- page in class B's library and find its sprite
;  In : B = class, C = tier 0..2
;  Out: DE = the sprite block base, HL -> CLASS_GEOM_SIZE bytes of geometry
;       ...and #4000-#7FFF is now class B's sprite library
;  Uses: AF, BC, DE, HL
;
;  THIS LEAVES BANK 4 PAGED OUT. Everything from here until class_blit_done
;  runs on the low 16K only -- see the header of this file.
; ----------------------------------------------------------------------------
class_tier_addr:
    ld a,b
    push af                             ; the class, for the address maths
    push bc                             ; ...and the tier

    ld l,a
    ld h,0
    ld de,class_bank
    add hl,de
    ld c,(hl)
    ld b,GA_PORT
    out (c),c                           ; the window is now this class's library

    pop bc
    pop af

    ;  class * 6 + tier * 2
    call class_sprite_addr
    ld a,c
    add a,a
    ld e,a
    ld d,0
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = the sprite base
    push de

    ;  tier * 6, which is the same shape again
    ld a,c
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; * 2
    add hl,de                           ; * 3
    add hl,hl                           ; * 6 = CLASS_GEOM_SIZE
    ld de,class_geom
    add hl,de
    pop de
    ret


; ----------------------------------------------------------------------------
;  class_sprite_addr -- HL = &class_sprite[A], all three tiers of one class
;  In : A = class
;  Out: HL
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
class_sprite_addr:
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; * 2
    add hl,de                           ; * 3
    add hl,hl                           ; * 6 = CLASS_SPRITE_STRIDE
    ld de,class_sprite
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  class_blit_done -- put bank 4 back under the window
;  Uses: AF, BC
;
;  The other half of class_tier_addr, and the reason phase4_blit_one is a
;  wrapper rather than one routine: it has two exit paths -- the sprite was
;  clipped away, or it was drawn -- and both have to come through here.
; ----------------------------------------------------------------------------
class_blit_done:
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c
    ret
