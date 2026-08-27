; ============================================================================
;  game/classdata.asm -- what a ship class IS, as data. In bank 4.
; ============================================================================
;  Every table here is indexed by ENT_CLASS and is exactly CLASS_COUNT entries
;  long, and src/main.asm asserts that second part. A table one entry short
;  reads the first byte of whatever follows it, and the symptom is a Destroyer
;  that costs whatever the next table happens to begin with -- which is a
;  plausible-looking number, so nothing appears to be wrong.
;
;  WHY IT IS IN BANK 4
;  -------------------
;  It is 200-odd bytes and the low 16K has 512. When section 8's eight classes
;  arrived, the per-class tables plus the disc loader plus a square damage
;  matrix came to 256 bytes more than there was room for -- and none of this
;  is read while bank 4 is paged out. The rule from CLAUDE.md, "anything that
;  only runs while the game is stopped belongs in the bank", generalises: the
;  low 16K is for what the BLITTER needs, because the blitter is the only
;  thing that ever pages bank 4 away. Costs are read when the player presses
;  ENTER, tags when the HUD is redrawn, the damage matrix inside cbt_update --
;  all of them with bank 4 under the window.
;
;  The two tables that are NOT here are class_bank and class_sprite, in
;  game/shipclass.asm, and they cannot be: they are read after the window has
;  been switched to a sprite library.
;
;  class_use_fallback is here too. It is code, but it runs exactly once, at
;  boot, before anything has been drawn.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  How many size tiers to draw a class ABOVE what its distance alone would
;  give. The tiers are a distance ladder, not a size one, so without this a
;  capital ship at 200 units draws exactly as big as a fighter at 200 units
;  and the fleet reads as a swarm of identical specks.
; ----------------------------------------------------------------------------
class_tier_bias:
    defb 0                              ; interceptor
    defb 1                              ; mothership
    defb 0                              ; harvester
    defb 0                              ; scout
    defb 0                              ; bomber
    defb 1                              ; frigate
    defb 0                              ; salvage corvette
    defb 1                              ; destroyer

; ----------------------------------------------------------------------------
;  Hull. NOT the balance triangle -- see cbt_damage_matrix for that. A hull is
;  one byte, so "tougher" tops out at 255 and the interceptor is already
;  there; what makes a capital ship hard to kill is the COLUMN under it in the
;  damage matrix being small. These numbers only say which classes are
;  FLIMSIER than a fighter, and section 8 names two: the Scout ("γρήγορο") and
;  the Harvester ("αργό, άοπλο, χρειάζεται προστασία").
; ----------------------------------------------------------------------------
class_hull:
    defb 255                            ; interceptor
    defb 255                            ; mothership -- losing it ends the game
    defb 200                            ; harvester: unarmed, and needs escort
    defb 160                            ; scout: fast, and made of paper
    defb 255                            ; bomber
    defb 255                            ; frigate
    defb 220                            ; salvage corvette
    defb 255                            ; destroyer

; ----------------------------------------------------------------------------
;  What each class wears if its library never arrived off the disc. Only the
;  two libraries inside DISC.BIN can be a stand-in, because they are the only
;  two guaranteed to be in memory: a fighter borrows the interceptor, anything
;  bigger borrows the frigate. This is exactly the arrangement the game had
;  before the extra libraries existed at all.
;
;  Every entry must name a class that is its OWN stand-in -- class_use_fallback
;  rewrites the tables in place and skips those, which is what makes the order
;  it visits the classes in not matter.
; ----------------------------------------------------------------------------
class_fallback:
    defb CLASS_INTERCEPTOR              ; interceptor -- itself
    defb CLASS_FRIGATE                  ; mothership
    defb CLASS_FRIGATE                  ; harvester
    defb CLASS_INTERCEPTOR              ; scout
    defb CLASS_INTERCEPTOR              ; bomber
    defb CLASS_FRIGATE                  ; frigate -- itself
    defb CLASS_FRIGATE                  ; salvage corvette
    defb CLASS_FRIGATE                  ; destroyer

; ----------------------------------------------------------------------------
;  Three letters a class for the yard readout, four bytes apart so the index
;  is two shifts. The HUD strip has room for exactly this much.
; ----------------------------------------------------------------------------
class_tag:
    defb "INT",0                        ; interceptor
    defb "MTH",0                        ; mothership
    defb "HAR",0                        ; harvester
    defb "SCT",0                        ; scout
    defb "BMB",0                        ; bomber
    defb "FRG",0                        ; frigate
    defb "SLV",0                        ; salvage corvette
    defb "DST",0                        ; destroyer
class_tag_end:

; ----------------------------------------------------------------------------
;  ...and the whole word, for the context bar.
;
;  Three letters in the corner of the HUD is what the player could not read:
;  they were told the build panel was B then , and . then ENTER, and asked
;  twice how to choose what to build, because "SCT" in a five-byte field says
;  nothing about what it is or what it costs. The bar has forty characters and
;  can afford the word.
;
;  Stored back to back and zero-terminated rather than at a fixed stride --
;  eight names is 71 bytes this way and 96 at twelve apiece, and ctx_class_name
;  walks them with the same mis_next_line the briefing uses. No length may
;  exceed CTX_NAME_CHARS or it runs into the cost figure; txt_draw clips at
;  the screen edge, not at a field, so nothing else would catch it.
; ----------------------------------------------------------------------------
class_name:
    defb "INTERCEPTOR",0
    defb "MOTHERSHIP",0
    defb "HARVESTER",0
    defb "SCOUT",0
    defb "BOMBER",0
    defb "FRIGATE",0
    defb "SALVAGE",0
    defb "DESTROYER",0
class_name_end:

; ----------------------------------------------------------------------------
;  What the yard offers, in the order , and . step through -- cheapest first,
;  so the panel reads as a price list.
; ----------------------------------------------------------------------------
eco_build_order:
    defb CLASS_SCOUT                    ;  25
    defb CLASS_INTERCEPTOR              ;  35
    defb CLASS_HARVESTER                ;  40
    defb CLASS_BOMBER                   ;  55
    defb CLASS_SALVAGE                  ;  90
    defb CLASS_FRIGATE                  ; 120
    defb CLASS_DESTROYER                ; 250, and not before mission 5
eco_build_order_end:

;  Ship costs, Homeplanet.md section 8, indexed by class. A cost of zero means
;  "not buildable" and eco_queue refuses it, which is what keeps the Mothership
;  off the slipway even though it is a perfectly good class everywhere else.
eco_class_cost:
    defb  35                            ; interceptor
    defb   0                            ; mothership -- not buildable
    defb  40                            ; harvester
    defb  25                            ; scout
    defb  55                            ; bomber
    defb 120                            ; frigate
    defb  90                            ; salvage corvette
    defb 250                            ; destroyer

;  Frames of construction, indexed by class. Section 8 gives no build times, so
;  they come from the price: a Destroyer at 250 RU that appeared as fast as a
;  25 RU Scout would make the cost the only thing that mattered, and the yard
;  takes one order at a time -- so time on the slipway is the second half of
;  what a ship costs.
eco_class_frames:
    defb  40                            ; interceptor
    defb   0                            ; mothership
    defb  45                            ; harvester
    defb  30                            ; scout
    defb  60                            ; bomber
    defb 120                            ; frigate
    defb  90                            ; salvage corvette
    defb 200                            ; destroyer

; ----------------------------------------------------------------------------
;  The balance triangle, Homeplanet.md section 8:
;      Interceptor -> Bomber -> Frigate -> Interceptor
;
;  A matrix, not a single damage number, because the whole point is that a
;  class is defined by what it is good against. Rows are the shooter, columns
;  the target; the value is hull points a hit takes off. Eight columns a row,
;  so cbt_damage_for indexes it with three shifts instead of a multiply.
;
;  The triangle is the three pairs you can read off the diagonal -- 30/8 for
;  the first leg, 48/20 for the second, 40/10 for the third. In each, the class
;  section 8 says wins does between two and four times the damage of the one it
;  beats. NOTHING ELSE in the game encodes the triangle: movement, range and
;  cooldown are identical for every class, so if these numbers are wrong the
;  triangle does not exist.
;
;  The interceptor-versus-interceptor cell is still 24, which is what it was
;  when there were three classes -- and since the enemy fields nothing else,
;  the campaign's arithmetic is unchanged by this table growing.
;
;                 vs:  INT  MTH  HAR  SCT  BMB  FRG  SLV  DST
cbt_damage_matrix:
    defb             24,  10,  40,  32,  30,  10,  28,   8  ; interceptor
    defb             40,  24,  40,  40,  36,  24,  36,  20  ; mothership
    defb              4,   2,   4,   4,   4,   2,   4,   2  ; harvester
    defb             10,   4,  16,  12,  10,   4,  10,   3  ; scout
    defb              8,  44,  24,   8,  16,  48,  20,  44  ; bomber
    defb             40,  20,  36,  44,  20,  24,  30,  18  ; frigate
    defb              6,   3,   8,   6,   6,   3,   6,   3  ; salvage corvette
    defb             30,  56,  40,  32,  34,  56,  36,  40  ; destroyer
cbt_damage_matrix_end:


; ----------------------------------------------------------------------------
;  class_use_fallback -- there are no disc libraries, so wear stand-ins
;
;  Rewrites class_bank and class_sprite so that every class in banks 5-7 draws
;  the bank-4 library named in class_fallback. Nothing else about the class
;  changes: a Destroyer still costs 250, still has a Destroyer's damage row,
;  and is still gated to mission 5 -- it just looks like a Frigate.
;
;  Called when lib_load fails, which on a real machine means the disc was
;  taken out between RUN" and now. Drawing a stand-in is a cosmetic loss;
;  blitting whatever bank 5 happens to contain is 24 sprites of noise a frame.
;  Uses: everything
; ----------------------------------------------------------------------------
class_use_fallback:
    xor a
    ld (class_index),a
@class_fb_one:
    ld a,(class_index)
    ld l,a
    ld h,0
    ld de,class_fallback
    add hl,de
    ld a,(hl)                           ; A = the stand-in's class
    ld (class_stand_in),a
    ld hl,class_index
    cp (hl)
    jr z,@class_fb_next                 ; its own stand-in: already correct

    ;  It moves into whichever bank the stand-in is in, which is always one of
    ;  the two libraries DISC.BIN carries.
    ld l,a
    ld h,0
    ld de,class_bank
    add hl,de
    ld c,(hl)
    ld a,(class_index)
    ld l,a
    ld h,0
    ld de,class_bank
    add hl,de
    ld (hl),c

    ;  ...and it draws the stand-in's sprites, at all three tiers.
    ld a,(class_index)
    call class_sprite_addr
    push hl
    ld a,(class_stand_in)
    call class_sprite_addr
    pop de
    ld bc,CLASS_SPRITE_STRIDE
    ldir

@class_fb_next:
    ld hl,class_index
    inc (hl)
    ld a,(hl)
    cp CLASS_COUNT
    jr c,@class_fb_one
    ret

class_index:        defb 0
class_stand_in:     defb 0


