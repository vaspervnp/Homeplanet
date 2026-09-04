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
;  The class NAMES are in BANK 7 now -- class_name in game/screentext.asm,
;  read through bank7_fetch by ctx_class_name. They used to be here, 71 bytes
;  of bank 4 that cost DISC.BIN byte for byte; the retaliation routine needed
;  the room and the words are only ever read with the world at rest or from
;  the context bar, both of which may page bank 7 by the narrow rule.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  What has to be true before the yard will take an order for a class.
;
;  eco_pick_allowed WAS one `cp CLASS_DESTROYER` and a mission number, with a
;  comment saying it "becomes a table the moment a second class needs one".
;  This is that moment -- and the table has to hold a RULE per class rather
;  than a mission number, because the two gates are different in kind:
;
;      0          always available
;      1..127     from mission N, as the player counts them (1-based)
;      #80 + n    when bit n of campaign_unlocks is set
;
;  One byte a class and one branch. The alternative -- a second table of
;  "unlock bits" beside a table of "unlock missions" -- is two tables to keep
;  CLASS_COUNT long and two places to look when a class is unexpectedly
;  missing from the panel.
;
;  BOTH CAPITAL SHIPS ARE UNLOCK BITS NOW and no row uses the mission form. The
;  Destroyer's was CLASS_DESTROYER_MIS + 1 -- section 8's "διαθέσιμο από την 5η
;  αποστολή" -- until the design owner moved it to mission 9 and asked for a
;  derelict to go with it. A date and a job would have been two rules saying
;  one thing, and the hull cannot be towed home before mission 9 anyway, so the
;  job is the whole of it. See game/mission.asm.
;
;  THE 1..127 FORM STAYS, and it is not dead weight: it is the cheap gate, and
;  the day a class wants "from mission N" it is a byte rather than a mechanic.
;  tests/test_shipclass.py drives it directly so that it cannot rot unused.
; ----------------------------------------------------------------------------
ECO_GATE_FLAG       equ #80

eco_class_gate:
    defb 0                              ; interceptor
    defb 0                              ; mothership -- not buildable anyway
    defb 0                              ; harvester
    defb 0                              ; scout
    defb 0                              ; bomber
    defb ECO_GATE_FLAG + CAMP_UNLOCK_FRIG_BIT   ; frigate: salvage the derelict
    defb 0                              ; salvage corvette
    defb ECO_GATE_FLAG + CAMP_UNLOCK_DEST_BIT   ; destroyer: salvage its own

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
    defb CLASS_DESTROYER                ; 250, and not before its hull is towed home
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
;  builds one at a time -- so time on the slipway is the second half of what a
;  ship costs. That is still true now that ten orders can be WAITING: the queue
;  is a line, not a second slipway, so a Destroyer at the head of it holds up
;  everything behind it for 200 game frames.
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
;  class_use_fallback -- there are no disc libraries, so paint a stand-in
;
;  Every class, every tier, points at class_standin in bank 4, and the block is
;  filled with mask 0 / data #F0 -- opaque, four pen-1 pixels a byte. A ship
;  then draws as a solid rectangle of its own tier's width and height, which is
;  the right size, in the right place, moving the right way, and unmistakably
;  not a ship. Nothing else about the class changes: a Destroyer still costs
;  250 and still has a Destroyer's damage row.
;
;  IT USED TO NAME A CLASS RATHER THAN PAINT ONE. That worked because the
;  interceptor and the frigate lived in bank 4, inside DISC.BIN, and were
;  therefore the two libraries guaranteed to be in memory whatever the drive
;  did. All eight are on the disc now -- see src/sys/libload.asm -- so there is
;  no real art to borrow and the fallback has to make its own.
;
;  Called when lib_load fails, which on a real machine means the disc was taken
;  out between RUN" and now. Drawing a block is a cosmetic loss; blitting
;  whatever bank 5 happens to contain is 24 sprites of noise a frame.
;
;  One mask/data pattern for the whole block, and not a shape, because a shape
;  would need the tier's width to know where a row ends -- three tiers, three
;  strides, and code in bank 4 to do it. A rectangle needs none of that: every
;  byte of every block is the same two bytes, whichever tier reads it.
;  Uses: everything
; ----------------------------------------------------------------------------
class_use_fallback:
    ld hl,class_standin
    ld de,CLASS_STANDIN_SIZE / 2        ; mask/data pairs
@class_fb_paint:
    ld (hl),0                           ; mask: keep nothing of the background
    inc hl
    ld (hl),#F0                         ; data: four pen-1 pixels
    inc hl
    dec de
    ld a,d
    or e
    jr nz,@class_fb_paint

    ;  Bank 4 for every class, because that is where the block is...
    ld hl,class_bank
    ld b,CLASS_COUNT
@class_fb_bank:
    ld (hl),GA_BANK_4
    inc hl
    djnz @class_fb_bank

    ;  ...and the same address for every tier of every class. They step by
    ;  different block sizes and all three stay inside it -- src/main.asm
    ;  asserts that against the largest tier there is.
    ld hl,class_sprite
    ld de,class_standin
    ld b,CLASS_COUNT * CLASS_TIERS
@class_fb_addr:
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    djnz @class_fb_addr

    ;  ...and every tier draws at TIER A's size, which is what lets the block
    ;  be a tier A library rather than a tier C one -- 432 bytes of the bank
    ;  window instead of 2688. The largest read is view * shifts * block_sz and
    ;  it is bounded by the geometry, so shrinking the geometry shrinks it.
    ;
    ;  A forward LDIR over itself is the whole of it: six bytes of tier A land
    ;  on tier B, and tier B -- now A -- lands on tier C. class_geom is RAM in
    ;  the low 16K and says so at its head, for exactly this.
    ;
    ;  What it costs on screen is that a stand-in no longer grows with range.
    ;  On a machine that is drawing solid rectangles because it has no art at
    ;  all, that is not the thing anyone will notice.
    ld hl,class_geom
    ld de,class_geom + CLASS_GEOM_SIZE
    ld bc,CLASS_GEOM_SIZE * 2
    ldir
    ret


