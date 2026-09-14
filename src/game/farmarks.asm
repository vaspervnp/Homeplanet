; ============================================================================
;  farmarks.asm -- a ship that is far away is a MARK, not a sprite
;
;  Bank 4. "Όταν είναι πολλά τα σκάφη γίνεται αργό": a PC-sampled profile at
;  fifty ships (CLAUDE.md, the frame budget) put a third of the frame in the
;  masked blit and its erase and a sixth in projecting -- the frame is the
;  sprites. A tier A ship is an 8x6 blit plus a 3x6 erase, about four thousand
;  T-states with the row overhead; a mark is one pixel wide and two lines
;  tall through gfx_vline, with a one-byte dirty rectangle, about four
;  hundred. So the far band of tier A is drawn as marks -- from MARK_MIN_Z on,
;  in the side's own ink, where the sprite's centre would have been -- and
;  the ship is still THERE, still the right colour, still where it is.
;
;  ...AND WHILE A SHIP IS BEING FLOWN, everything outside the reticle is a
;  mark whatever its depth: "Μόνο οι εχθροί και φίλοι που είναι κοντά στο
;  στόχαστρο μου θα φαίνονται κανονικά με sprite. Οι υπόλοιποι θα είναι marks
;  όπως στο scanner για να επιταχύνεται το παιχνίδι." The cockpit sits one
;  unit inside the near plane, so everything it sees is close and therefore
;  tier C -- the most expensive picture the game can draw -- and this is what
;  makes flying affordable in a fight. PILOT_BOX_HW/HH are the reticle's half
;  sizes in pixels; the reticle itself is pilot_reticle, below.
;
;  THE MARK IS TIER 3. The visible-list entry packs the tier into two bits
;  and only 0..2 were ever used; 3 is free, so nothing about the list's shape
;  changes and phase4_group keys on side and class alone (the tier is not
;  identity), so marks consolidate exactly as sprites do at the wide steps.
;  Two readers had to learn the value: phase4_blit_body, which hands tier 3
;  to mark_draw_one instead of class_tier_addr, and jfx_band in the jump
;  wipe, which indexes class_geom by tier and treats 3 as 0.
;
;  mark_tier_for is called from phase4_cache, in the low 16K, with the window at
;  rest (it already calls shot_cache here); mark_draw_one from
;  phase4_blit_body, whose caller restores bank 4 afterwards anyway. Both are
;  bank-4 code by the narrow rule: neither can run between class_tier_addr
;  and class_blit_done.
; ============================================================================

MARK_TIER           equ 3

;  Camera depth from which a ship is a mark. Z_NEAR is 84, tier B ends at
;  TIER_B_MAX_Z (190) and Z_FAR is 255, so this is the far end of tier A's
;  band. Measured before it was chosen: see CLAUDE.md, "Far ships are marks".
MARK_MIN_Z          equ 224

;  The reticle's half width and half height, pixels, about the middle of the
;  playfield (SCR_CENTRE_X, PROJ_CENTRE_Y). Inside it a ship is drawn at its
;  tier; outside it is a mark.
PILOT_BOX_HW        equ 56
PILOT_BOX_HH        equ 36

;  Rotated depth, camera units past the flown ship, under which a ship is
;  not drawn from the cockpit: behind the nose, or the nose itself, which
;  lags the focus by a frame's flight (200 units, three camera units).
PILOT_NEAR_RAW      equ 8

;  ...and the two bands above it where a ship is drawn LARGER than tier C,
;  by pixel replication in gfx/sprscale.asm: under PILOT_X4_RAW camera units
;  ahead at four times, under PILOT_X2_RAW at twice. Tier C ends at depth
;  TIER_C_MAX_Z, which from the cockpit is raw 47.
PILOT_X4_RAW        equ 16              ; 2048 world units, at 128 a camera unit
PILOT_X3_RAW        equ 24              ; 3072
PILOT_X2_RAW        equ 32              ; 4096

;  How many ships the cockpit draws as SPRITES: the nearest ones, in draw
;  order, which is back to front. Everything further is a mark like the
;  sensor view's -- a dot for a fighter, a cross for anything else. A x4
;  ship is a quarter of a frame, so this is what bounds the cockpit's cost.
PILOT_SPRITES       equ 3

;  The scale bits in a visible-list entry: 01 = x2, 10 = x4, 11 = x3, 00 =
;  as the tier says. Bits 5 and 6, which the class -- eight of them, bits 2..4 --
;  never reaches; phase4_blit_body masks the class to three bits, copies
;  them into spr_enemy beside the side bit for the blitter, and
;  PHASE4_GROUP_MASK leaves them out of a group's key.
SCALE_BITS          equ #60
SCALE_X2            equ #20
SCALE_X4            equ #40
SCALE_X3            equ #60

;  The tactical view's scale by zoom step, for steps 0..ZOOM_X2_STEP: the
;  innermost two at x4, then x3, then x2. Step 4 and out draw tier C.
ZOOM_X2_STEP        equ 3
zoom_scale:         defb SCALE_X4, SCALE_X4, SCALE_X3, SCALE_X2

;  The reticle: four ticks, PILOT_RET_GAP pixels out from the centre and
;  PILOT_RET_LEN long, in the fleet's ink -- or in the alarm ink on a frame a
;  flying hostile projected inside the box (pilot_locked, set by
;  mark_tier_for and spent by pilot_reticle).
PILOT_RET_GAP       equ 6
PILOT_RET_LEN       equ 3


; ----------------------------------------------------------------------------
;  mark_tier_for -- A = the tier to draw this entity at, or MARK_TIER
;  In : A = the tier so far (0..2, after class_apply_bias), B = class
;       proj_z, proj_z_raw, proj_sx, proj_sy = this entity's projection
;  Out: CF clear, A = tier; or CF SET: do not list this entity at all
;  Uses: AF, C, DE, HL -- B is preserved, phase4_cache packs it next
;
;  THE DROP IS THE COCKPIT'S. The eye sits PILOT_CAM_DIST behind the flown
;  ship, one unit inside the near plane, so that everything ahead of the
;  ship is drawn from the largest tier down -- and so, it turned out, is
;  everything BEHIND the ship for eighty-three units, which is the pilot's
;  own squadron drawn in front of the pilot, and the flown ship itself,
;  which the view follows a frame behind and which therefore sits a few
;  units past the focus every frame it moves. Seen in a screenshot: three
;  white interceptors at the top of the view of a ship flying away from
;  them. So while flying, anything whose rotated depth is under
;  PILOT_NEAR_RAW -- behind the nose, or the nose itself -- is not listed.
; ----------------------------------------------------------------------------
mark_tier_for:
    ld c,a
    ld a,(pilot_slot)
    cp ENT_MAX
    jr nc,@mt_depth                     ; nobody flying: depth alone decides
    ld a,(proj_z_raw)
    sub PILOT_NEAR_RAW
    jp m,@mt_drop                       ; behind the nose: not drawn at all
    ;  ONE ENEMY AND NOTHING ELSE. "Θα αγνοεί τα φιλικά σκάφη, δεν θα τα
    ;  εμφανίζει ... θα διαλέγεις μόνο έναν εχθρό να δείξεις": from the
    ;  cockpit the only thing listed is pilot_target -- the ship in the
    ;  reticle, else the nearest flying hostile, chosen by pilot_frame
    ;  before this projection -- and it is always a sprite, scaled by its
    ;  depth; the box below decides the lock, not the picture. The rest of
    ;  the battle goes on unseen, and pilot_shown says the target was
    ;  drawn this frame, so pilot_arrow knows when to point instead.
    ld a,(phase4_index)
    neg
    add a,ENT_MAX                       ; the slot, as shot_cache reckons it
    ld hl,pilot_target
    cp (hl)
    jr nz,@mt_drop
    ld (pilot_shown),a                  ; nonzero: a hostile's slot
    ;  Near enough to be drawn larger than tier C?
    ld a,(proj_z_raw)
    cp PILOT_X4_RAW
    jr nc,@mt_not_x4
    ld a,SCALE_X4
    jr @mt_scaled
@mt_not_x4:
    cp PILOT_X3_RAW
    jr nc,@mt_not_x3
    ld a,SCALE_X3
    jr @mt_scaled
@mt_not_x3:
    cp PILOT_X2_RAW
    jr nc,@mt_depth
    ld a,SCALE_X2
@mt_scaled:
    or 2                                ; tier C, scaled
    ld c,a
    jr @mt_box
@mt_depth:
    ld a,(proj_z)
    cp MARK_MIN_Z
    jr nc,@mt_mark                      ; the far band

    ld a,(pilot_slot)
    cp ENT_MAX
    jr c,@mt_box

    ;  ZOOMED IN, THE SAME THREE SIZES: "στο Zoom in βάλε και τα 3 επίπεδα
    ;  με τα resized sprites." At the innermost steps everything near the
    ;  focus is tier C already -- cam_dist is short and the deltas are
    ;  shifted small -- so the step alone decides: 3 draws x2, 2 x3, and 0
    ;  and 1 x4. A ship further off, at tier B or A on its depth, stays
    ;  the size its depth says. mark_or_blit keeps it to the nearest
    ;  PILOT_SPRITES, as it does in the cockpit; the rest are tier C.
    ld a,c
    cp 2
    jr nz,@mt_keep                      ; tier A or B: too far to grow
    ld a,(cam_zoom)
    cp ZOOM_X2_STEP + 1
    jr nc,@mt_keep                      ; the ordinary steps
    ld hl,zoom_scale
    add a,l
    ld l,a
    jr nc,@mt_zs_ok
    inc h
@mt_zs_ok:
    ld a,(hl)
    or 2
    ld c,a
    jr @mt_keep

@mt_box:
    ;  Outside the reticle's box? sx first, as a word, then sy as a byte.
    ;  Outside it the target is still a sprite -- the box is the LOCK's.
    ld hl,(proj_sx)
    ld de,SCR_CENTRE_X - PILOT_BOX_HW
    or a
    sbc hl,de
    jr c,@mt_keep                       ; left of the box
    ld de,PILOT_BOX_HW * 2 + 1
    sbc hl,de                           ; CF is clear here
    jr nc,@mt_keep                      ; right of it
    ld a,(proj_sy)
    sub PROJ_CENTRE_Y - PILOT_BOX_HH
    jr c,@mt_keep                       ; above
    cp PILOT_BOX_HH * 2 + 1
    jr nc,@mt_keep                      ; below
    ;  INSIDE THE BOX, WHILE FLYING: a hostile here is IN THE RETICLE, and
    ;  pilot_reticle draws the ticks in the alarm ink this frame -- "όταν
    ;  έχω στο στόχαστρο εχθρό να γίνεται κόκκινο το στόχαστρο". A flying
    ;  hostile, not a wreck: a hull adrift is not a thing to shoot at.
    ld hl,(phase4_ent)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY + ENT_F_DISABLED
    cp ENT_F_ENEMY
    jr nz,@mt_keep
    ld (pilot_locked),a                 ; nonzero: ENT_F_ENEMY itself. WHICH
                                        ; needs no saying: only pilot_target
                                        ; reaches this box, so the lock is it
@mt_keep:
    ld a,c
    or a                                ; CF clear: list it
    ret
@mt_mark:
    ld a,MARK_TIER
    or a
    ret
@mt_drop:
    scf
    ret


; ----------------------------------------------------------------------------
;  mark_or_blit -- is this visible-list entry a mark? Draw it if so.
;  In : DE = sx (0..319), C = the packed byte, phase4_sy = sy; called from
;       phase4_blit_body with bank 4 at rest, before any library is paged
;  Out: CF set: a mark was drawn (and its rectangle recorded), nothing more
;       to do. CF clear: blit it, at the scale C's bits 6 and 5 now say --
;       which may be none where the entry said some, past the nearest few.
;  Uses: AF, and everything if it draws; C is the packed byte, possibly
;       with its scale bits cleared, on the blit path
;
;  Three reasons for a mark: the tier is MARK_TIER; or a ship is being
;  flown and this entry is not one of the PILOT_SPRITES nearest -- the
;  draw order is back to front, so the nearest are the LAST, and
;  phase4_remaining counts down to one at the last. The scale bits travel
;  in spr_enemy, which phase4_blit_body fills from the same byte.
; ----------------------------------------------------------------------------
mark_or_blit:
    ld a,c
    and 3
    cp MARK_TIER
    jr z,@mob_mark
    ld a,(phase4_remaining)
    cp PILOT_SPRITES + 1
    jr c,@mob_blit                      ; among the nearest: a sprite, scaled or not
    ld a,(pilot_slot)
    cp ENT_MAX
    jr c,@mob_mark                      ; flying: everything further is a mark
    ;  The tactical view zoomed in: a scaled entry past the nearest few is
    ;  drawn at tier C instead -- C comes back with its scale bits cleared,
    ;  and phase4_blit_body reads the side, class and tier out of it after.
    ld a,c
    and #FF - SCALE_BITS
    ld c,a
@mob_blit:
    or a
    ret
@mob_mark:
    call mark_draw_one
    scf
    ret


; ----------------------------------------------------------------------------
;  mark_draw_one -- draw a visible-list entry as a mark
;  In : DE = sx (0..319), C = the packed byte (bit 7 = enemy, class in
;       bits 2..4), phase4_sy = sy
;  Out: the mark drawn, and its rectangle appended
;  Uses: everything
;
;  The sensor view's vocabulary: a fighter is a dot, one pixel wide and two
;  lines tall -- a Mode 1 pixel is wider than a line, so two lines is about
;  a square dot and one reads as dust -- and anything else is a cross. Pen 1
;  for ours and pen 3 for theirs, which is the recolour the blitter does
;  with spr_enemy, done by hand. On the row the sprite's centre would have
;  been; gfx_vline clips to the playfield.
; ----------------------------------------------------------------------------
mark_draw_one:
    ld a,c
    rlca                                ; bit 7, the side, into CF
    ld a,1
    jr nc,@mdo_pen
    ld a,3
@mdo_pen:
    ex de,hl                            ; HL = sx
    ld b,a                              ; B = pen, for a moment
    ld a,c
    and #1C                             ; the class
    jr z,@mdo_dot
    ld a,(phase4_sy)
    ld c,a
    ld a,b
    jp mark_cross                       ; anything but a fighter
@mdo_dot:
    ;  A fighter: the dot, two rows centred on sy.
    ld a,(phase4_sy)
    or a
    jr z,@mdo_top
    dec a
@mdo_top:
    ld c,a
    ld a,b
    ld b,2
    jp mark_bar


; ----------------------------------------------------------------------------
;  pilot_reticle -- four ticks about the middle of the view, while flying
;  Uses: everything
;
;  Called from wave_draw, after the ships and the tracers, so it is on top;
;  each tick appends its own rectangle and the next pass through the buffer
;  erases it exactly as it erases a ship. Nothing while nobody is flying, and
;  nothing in the sensor view, which has no cockpit.
; ----------------------------------------------------------------------------
pilot_reticle:
    ld a,(pilot_slot)
    cp ENT_MAX
    ret nc
    ;  THE INK IS THE LOCK. mark_tier_for set pilot_locked this frame if a
    ;  flying hostile projected inside the box. pilot_frame is what spends
    ;  it, at the top of the NEXT frame, before that frame's projection --
    ;  it is the same byte that makes the ship match the target's motion.
    ld a,(pilot_locked)
    or a
    ld a,PEN_WHITE
    jr z,@pr_pen
    ld a,PEN_RED
@pr_pen:
    ld (pilot_ret_pen),a
    ld a,(view_sensors)
    or a
    ret nz
    ;  Left and right: a vertical tick either side, centred on the row.
    ld hl,SCR_CENTRE_X - PILOT_RET_GAP - 1
    ld c,PROJ_CENTRE_Y - PILOT_RET_LEN / 2
    ld b,PILOT_RET_LEN
    ld a,(pilot_ret_pen)
    call mark_bar
    ld hl,SCR_CENTRE_X + PILOT_RET_GAP + 1
    ld c,PROJ_CENTRE_Y - PILOT_RET_LEN / 2
    ld b,PILOT_RET_LEN
    ld a,(pilot_ret_pen)
    call mark_bar
    ;  Above and below: a vertical tick each, in the centre column.
    ld hl,SCR_CENTRE_X
    ld c,PROJ_CENTRE_Y - PILOT_RET_GAP - PILOT_RET_LEN
    ld b,PILOT_RET_LEN
    ld a,(pilot_ret_pen)
    call mark_bar
    ld hl,SCR_CENTRE_X
    ld c,PROJ_CENTRE_Y + PILOT_RET_GAP + 1
    ld b,PILOT_RET_LEN
    ld a,(pilot_ret_pen)
    jp mark_bar


; ----------------------------------------------------------------------------
;  pilot_arrow -- where the chosen enemy is: an arrow at the edge of the
;                 view while it is off the screen, its strength over it
;                 while it is on
;  Uses: everything
;  "Θα δείχνει ένα μεγάλο βέλος στις άκρες της οθόνης προς τα που πρέπει να
;  πας για να βρεις εχθρό (δεξιά, αριστερά, πάνω κάτω, διαγώνια προς όλες
;  τις κατευθύνσεις)." From wave_draw after the reticle. Which way is the
;  Mothership indicator's own question, so it is asked the way wave_marker
;  asks it: moth_border on the target's record, the widest zoom borrowed so
;  nothing is out of range. Nothing is saved round the call: the cockpit
;  draws no marker for the base (moth_update, gfx/markproj.asm -- a friend
;  is a friend), and moth_bar is zeroed afterwards so a camera holding
;  still, paused, cannot have moth_draw read this bearing as the base's.
;  moth_place leaves the rotated direction in moth_dx and moth_dy (screen
;  sense: +y is DOWN), and the eight arrows come from their signs with a
;  dead zone -- a component counts when it is more than three eighths of
;  the other, so each diagonal owns about 45 degrees and each cardinal
;  about the same. The apex sits ARROW_IN pixels inside the edge pointed
;  at, in the middle of that edge for a cardinal and in the corner for a
;  diagonal.
;
;  THE HEADS ARE SUMS, NOT PICTURES: a head is columns k = 0.. from the
;  apex away from its edge, column k a run of b0 + db*k rows starting dt*k
;  rows from the apex -- (n, dt, db, b0) a shape, twelve bytes for the
;  three where the pictures were a hundred and seventeen, which is what
;  the window had to have back. Sideways, a run of 2k+1 rows centred on
;  the apex; up, both halves at once, a run from 2k down to the base; the
;  corner, a run from the apex down to the diagonal. Down and left are
;  the same runs mirrored about the apex, so eight arrows are three
;  records and two signs. One rectangle of ARROW_BOX round the apex covers
;  every shape, so the next pass through the buffer erases it. Straight
;  behind has no answer (moth_place's own degenerate case) and draws
;  nothing.
; ----------------------------------------------------------------------------
ARROW_IN            equ 16              ; the apex, in from the playfield's edge
ARROW_BOX           equ 15              ; ...and the rectangle, this far each way
ARROW_RECT_W        equ 8               ; ...eight bytes wide: 32 pixels from a byte at or before apex - ARROW_BOX
ARROW_DX            equ SCR_CENTRE_X - 1 - ARROW_IN         ; 143: centre to a side apex
ARROW_DY            equ PROJ_CENTRE_Y - CTX_BAR_H - ARROW_IN ; 58: centre to the top apex
    assert PROJ_CENTRE_Y + ARROW_DY + ARROW_BOX < HUD_TOP, "the bottom arrow's rectangle reaches the HUD"
    assert ARROW_DX - ARROW_BOX >= 0 && ARROW_DY - ARROW_BOX >= 0, "an arrow's rectangle leaves the playfield"
    assert SCR_CENTRE_X + ARROW_DX + ARROW_BOX + 2 <= SCR_BYTES_PER_LINE * 4, "the right arrow's rectangle runs off the line"
ARROW_SIDE_N        equ 10              ; a sideways head: ten columns, 19 rows at its base
ARROW_UP_N          equ 8               ; an up or down head: eight columns a side...
ARROW_UP_ROWS       equ 16              ; ...and sixteen rows at the apex
ARROW_CORNER_N      equ 12              ; a corner head: twelve columns and twelve rows
    assert ARROW_SIDE_N - 1 <= ARROW_BOX && ARROW_UP_N - 1 <= ARROW_BOX && ARROW_CORNER_N - 1 <= ARROW_BOX, "a head is wider than its rectangle"
    assert ARROW_UP_ROWS - 1 <= ARROW_BOX && ARROW_CORNER_N - 1 <= ARROW_BOX, "a head is taller than its rectangle"

pilot_arrow:
    ld a,(pilot_slot)
    cp ENT_MAX
    ret nc
    ld a,(view_sensors)
    or a
    ret nz
    ld a,(pilot_target)
    cp ENT_MAX
    ret nc                              ; nothing chosen: nothing to point at
    ld a,(pilot_shown)
    or a
    jp nz,pilot_enemy_bar               ; on the screen: its strength instead

    ld a,(pilot_target)
    call ent_addr
    ld (mark_src),hl                    ; ENT_X is offset 0
    call moth_border
    ld hl,moth_bar
    ld a,(hl)
    ld (hl),0                           ; not the base's bearing: see above
    or a
    ret z                               ; straight along the view axis: no answer

    ;  Which of the eight: h and v are -1, 0 or 1.
    ld a,(moth_dx)
    call moth_abs
    ld b,a                              ; B = |dx|
    ld a,(moth_dy)
    call moth_abs
    ld c,a                              ; C = |dy|
    call arw_three_eighths              ; A = 3/8 |dy|
    cp b
    ld a,0                              ; (no flags)
    jr nc,@arw_h_is                     ; |dx| is not more than that: no sideways
    ld a,(moth_dx)
    rla
    sbc a,a
    or 1                                ; its sign: 1 or -1
@arw_h_is:
    ld (arw_h),a
    ;  The apex: the middle of the view, pushed to the edge(s) pointed at.
    ld hl,SCR_CENTRE_X
    or a
    jr z,@arw_x_done
    ld de,ARROW_DX
    jp p,@arw_x_add
    ld de,-ARROW_DX
@arw_x_add:
    add hl,de
@arw_x_done:
    ld (arw_x),hl
    ld a,b
    call arw_three_eighths              ; A = 3/8 |dx|
    cp c
    ld a,0
    jr nc,@arw_v_is                     ; |dy| is not more than that: level
    ld a,(moth_dy)
    rla
    sbc a,a
    or 1
@arw_v_is:
    ld (arw_v),a
    or a
    ld a,PROJ_CENTRE_Y                  ; (no flags)
    jr z,@arw_y_done
    jp m,@arw_y_up
    add a,ARROW_DY
    jr @arw_y_done
@arw_y_up:
    sub ARROW_DY
@arw_y_done:
    ld (arw_y),a

    ;  The shape, and the half or halves of it.
    ld hl,arrow_side
    ld a,(arw_v)
    or a
    jr z,@arw_shape
    ld hl,arrow_up
    ld a,(arw_h)
    or a
    jr z,@arw_shape
    ld hl,arrow_corner
@arw_shape:
    ld de,arw_n
    ld bc,4
    ldir                                ; arw_n, arw_dt, arw_db, arw_b0
    ld a,(arw_h)
    or a
    jr nz,@arw_half
    inc a                               ; straight up or down: both halves, +1 then -1
    ld (arw_hh),a
    call arw_fan
    ld a,-1
@arw_half:
    ld (arw_hh),a
    call arw_fan

    ;  One rectangle round the apex, whichever way it points.
    ld a,(arw_y)
    sub ARROW_BOX
    ld (mark_rect + 1),a
    ld a,ARROW_BOX * 2 + 1
    ld (mark_rect + 3),a
    ld a,ARROW_RECT_W
    ld (mark_rect + 2),a
    ld hl,(arw_x)
    ld de,-ARROW_BOX
    add hl,de
    srl h
    rr l
    srl h
    rr l
    ld a,l
    jp mark_store

;  arw_fan -- one half of a head: column k = 0..arw_n-1 at arw_x - arw_hh*k,
;  a run of arw_b0 + arw_db*k rows from arw_dt*k below the apex, the run
;  mirrored about the apex when the head points down. Sums, not products:
;  the top and the rows step by dt and db a column.
;  Uses: everything
arw_fan:
    ld a,(arw_b0)
    ld b,a                              ; B = this column's rows
    ld c,0                              ; C = its top, from the apex
    ld e,c                              ; E = k
@arw_col:
    push bc
    push de
    ld a,(arw_hh)
    or a
    ld a,e
    jp m,@arw_x_from                    ; pointing left: the body is to the right
    neg                                 ; pointing right: to the left
@arw_x_from:
    ld l,a
    rla
    sbc a,a
    ld h,a                              ; HL = -+k, sign-extended
    ld de,(arw_x)
    add hl,de                           ; HL = x
    ld a,(arw_v)
    or a
    jp m,@arw_as_drawn                  ; pointing up: as drawn
    jr z,@arw_as_drawn                  ; ...or level: as drawn
    ld a,c
    add a,b
    dec a
    neg
    ld c,a                              ; pointing down: the run mirrored about the apex
@arw_as_drawn:
    ld a,(arw_y)
    add a,c
    ld c,a                              ; C = y of the top
    ld a,PEN_RED
    call gfx_vline
    pop de
    pop bc
    ld a,(arw_dt)
    add a,c
    ld c,a
    ld a,(arw_db)
    add a,b
    ld b,a
    inc e
    ld a,(arw_n)
    cp e
    jr nz,@arw_col
    ret

;  A = 3/8 of A, which is (A >> 2) + (A >> 3): no overflow, no multiply.
;  (It was (A >> 1) + (A >> 3) first, which is FIVE eighths, and a hostile
;  twice as far across as up read as beside rather than as the corner.)
;  Uses: AF, E
arw_three_eighths:
    ld e,a
    srl e
    srl e
    srl a
    srl a
    srl a
    add a,e
    ret

;  The three shapes: (n, dt, db, b0) as arw_fan reads them. tests/test_marks
;  reads them back out of the bank and does the same sums.
arrow_side:
    defb ARROW_SIDE_N, -1, 2, 1                 ; column k: rows -k..k
arrow_up:
    defb ARROW_UP_N, 2, -2, ARROW_UP_ROWS       ; column k: rows 2k..15
arrow_corner:
    defb ARROW_CORNER_N, 0, -1, ARROW_CORNER_N  ; column k: rows 0..11-k


; ----------------------------------------------------------------------------
;  pilot_enemy_bar -- the chosen enemy's strength, over its sprite
;  Uses: everything
;  "Το σκάφος που θα αντιμετωπίζεις να έχει πάνω την μπάρα με την ισχύ του."
;  PILOT_BAR_W bytes by PILOT_BAR_H lines, PILOT_BAR_UP lines above where
;  the ship projected this frame -- clear of a x4 sprite's top -- in the
;  HUD's own enemy vocabulary: a red trough, the hull over the class's full
;  in white, in eighths, rounded. Whole bytes through scr_fill_rect, which
;  clips nothing, so the column is held inside the screen and the row
;  inside the playfield; the rectangle is the bar's own, through mark_store.
; ----------------------------------------------------------------------------
PILOT_BAR_W         equ 8
PILOT_BAR_H         equ 3
PILOT_BAR_UP        equ 36
    assert PILOT_BAR_UP > 32, "the bar sits on a x4 sprite"

pilot_enemy_bar:
    ld a,(pilot_target)
    call shot_where                     ; HL = sx, C = sy, CF if projected this frame
    ret nc
    ld a,c
    sub PILOT_BAR_UP
    jr nc,@peb_y_low_ok
    xor a
@peb_y_low_ok:
    cp CTX_BAR_H
    jr nc,@peb_y_ok
    ld a,CTX_BAR_H
@peb_y_ok:
    ld (mark_rect + 1),a
    ld c,a                              ; C = the bar's row
    srl h
    rr l
    srl h
    rr l                                ; HL = sx / 4, the ship's byte
    ld a,l
    sub PILOT_BAR_W / 2
    jr nc,@peb_x_low_ok
    xor a
@peb_x_low_ok:
    cp SCR_BYTES_PER_LINE - PILOT_BAR_W + 1
    jr c,@peb_x_ok
    ld a,SCR_BYTES_PER_LINE - PILOT_BAR_W
@peb_x_ok:
    ld b,a                              ; B = its byte
    push bc
    ;  The trough...
    ld d,PILOT_BAR_W
    ld e,PILOT_BAR_H
    ld a,SOLID_INK_3
    call scr_fill_rect
    ;  ...and the fill: hull over full, 256ths, then eighths rounded.
    ld a,(pilot_target)
    call ent_addr
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld e,(hl)
    ld d,0
    ld hl,class_hull
    add hl,de
    ld e,(hl)                           ; DE = the class's full hull
    pop hl
    ld bc,ENT_HULL
    add hl,bc
    ld l,(hl)
    ld h,0                              ; HL = what is left of it
    call wave_frac_of                   ; A = 256ths
    add a,16
    jr c,@peb_all                       ; past 240: all eight
    rlca
    rlca
    rlca
    and 7                               ; (A + 16) >> 5
    jr @peb_fill
@peb_all:
    ld a,PILOT_BAR_W
@peb_fill:
    pop bc
    push bc
    or a
    jr z,@peb_rect                      ; nothing left: the trough alone
    ld d,a
    ld e,PILOT_BAR_H
    ld a,SOLID_INK_1
    call scr_fill_rect
@peb_rect:
    pop bc
    ld a,PILOT_BAR_W
    ld (mark_rect + 2),a
    ld a,PILOT_BAR_H
    ld (mark_rect + 3),a
    ld a,b
    jp mark_store


; ----------------------------------------------------------------------------
;  phase4_refresh_order -- last frame's draw order with this frame's depths
;  In : A = phase4_visible, which equalled last frame's
;  Out: CF clear: phase4_order holds a permutation of 0..n-1 with every
;       depth refreshed from phase4_vis; CF set: it does not, fill it afresh
;  Uses: everything
;
;  The other half of phase4_sort's coherence (src/demo/phase4.asm): the
;  list is trusted only when every index is below n and NONE REPEATS, which
;  sort_seen -- ENT_MAX bytes of the save block's pad, cleared here and
;  written here -- says exactly. A list that is stale but a permutation is
;  merely a slower sort; a list of power-on rubbish is not a picture.
; ----------------------------------------------------------------------------
phase4_refresh_order:
    ld c,a                              ; C = n
    push bc
    ld hl,sort_seen
    ld de,sort_seen + 1
    ld bc,ENT_MAX - 1
    ld (hl),0
    ldir
    pop bc
    ld b,c
    ld hl,phase4_order
@pr_one:
    ld a,(hl)
    cp c
    jr nc,@pr_bad                       ; not a visible index
    push hl
    push bc
    ld hl,sort_seen
    add a,l
    ld l,a
    jr nc,@pr_seen_ok
    inc h
@pr_seen_ok:
    ld a,(hl)
    or a
    jr nz,@pr_dup                       ; the same index twice: not a permutation
    ld (hl),1
    pop bc
    pop hl
    push hl
    push bc
    ld a,(hl)
    call phase4_vis_addr                ; HL = &phase4_vis[A]; uses DE too
    inc hl
    inc hl
    inc hl                              ; -> its depth
    ld a,(hl)
    pop bc
    pop hl
    inc hl
    ld (hl),a                           ; the depth beside the index, fresh
    inc hl
    djnz @pr_one
    or a                                ; CF clear: trusted
    ret
@pr_dup:
    pop bc
    pop hl
@pr_bad:
    scf
    ret
