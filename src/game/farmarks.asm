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
    ;  Near enough to be drawn larger than tier C? The reticle test below
    ;  still applies -- a ship off to the side is a mark however close.
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
    ld hl,(proj_sx)
    ld de,SCR_CENTRE_X - PILOT_BOX_HW
    or a
    sbc hl,de
    jr c,@mt_mark                       ; left of the box
    ld de,PILOT_BOX_HW * 2 + 1
    sbc hl,de                           ; CF is clear here
    jr nc,@mt_mark                      ; right of it
    ld a,(proj_sy)
    sub PROJ_CENTRE_Y - PILOT_BOX_HH
    jr c,@mt_mark                       ; above
    cp PILOT_BOX_HH * 2 + 1
    jr nc,@mt_mark                      ; below
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
    ld (pilot_locked),a                 ; nonzero: ENT_F_ENEMY itself
    ;  ...and WHICH, the nearest of them, for the gun and for pilot_match:
    ;  the slot is ENT_MAX - phase4_index, as shot_cache reckons it, and
    ;  the depth proj_z_raw. pilot_frame resets pilot_lock_z every frame.
    ld a,(proj_z_raw)
    ld hl,pilot_lock_z
    cp (hl)
    jr nc,@mt_keep                      ; no nearer than the one held
    ld (hl),a
    ld a,(phase4_index)
    neg
    add a,ENT_MAX
    ld (pilot_lock_slot),a
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


; ============================================================================
;  The scanner: where the enemy is, while a ship is being flown
;
;  "Όταν είμαι σε V να φαίνεται όπως στο elite δεξιά το scanner με τις θέσεις
;  των εχθρών." -- and then "να είναι μεγαλύτερο (x2), οβάλ όπως στο elite και
;  να βλέπω και την διαφορά ύψους στους εχθρούς." Elite's: an OVAL at the
;  bottom right of the playfield, which is the plane the ship flies in seen
;  flat, the flown ship a white dot in its middle, and every flying hostile a
;  red mark placed by where it is RELATIVE TO THE SHIP AND ITS HEADING: up
;  the oval is ahead, right is right, 512 world units to the pixel across
;  (SCAN_SHIFT) and twice that up the oval, which is half as tall as it is
;  wide. THE HEIGHT IS A STALK: from the hostile's point on the plane a line
;  rises or falls by its height above or below the ship, with a three-pixel
;  bar at the tip -- so a hostile level with you is a dash on the plane and
;  one above you is a dash on a stalk. The cockpit shows what is in front;
;  this is what the cockpit cannot show, which is everything else.
;
;  ONE dirty rectangle for the whole box, appended once a frame, so the next
;  pass through the buffer clears it and the frame is redrawn from nothing --
;  a rectangle per mark would be twenty slots a frame out of a list sized for
;  the entities. The marks are drawn straight through gfx_vline for the same
;  reason, not through mark_dot. The oval is drawn a column at a time out of
;  scan_oval, a table of its half height per pixel of half width, each column
;  as the run of rows between its own height and the last column's so the
;  steep sides have no gaps: 156 gfx_vline calls a frame, about a twentieth
;  of a cockpit frame, and it is the price of the shape.
;
;  The rotation is the pilot's own: a ship with ENT_YAW y flies along world
;  (sin y, -cos y), so for a hostile at (dx, dz) from the ship
;      ahead = dx * sin y - dz * cos y,   right = dz * sin y - dx * cos y
;  with the four products through cam_mul7 on the high bytes of dx and dz,
;  which is 256 world units of resolution, shifted SCAN_SHIFT more so the
;  oval's eighty pixels cover forty thousand units. The height is the
;  Y delta's high byte shifted the same, +Y being up (pilot_frame's UP adds
;  to ENT_Y, and proj_point's sy is PROJ_CENTRE_Y minus it).
; ============================================================================

SCAN_W_BYTES        equ 20              ; 80 pixels
SCAN_H              equ 60
SCAN_X_BYTES        equ SCR_BYTES_PER_LINE - SCAN_W_BYTES - 1
SCAN_Y              equ HUD_TOP - SCAN_H - 2
SCAN_CX             equ SCAN_X_BYTES * 4 + SCAN_W_BYTES * 2          ; pixels
SCAN_CY             equ SCAN_Y + SCAN_H / 2
SCAN_RX             equ 38              ; the oval's half width, pixels
SCAN_RY             equ 19              ; ...and half height: the plane seen flat
SCAN_HALF_W         equ SCAN_RX - 2                                  ; pixels a mark may reach across
SCAN_HALF_V         equ SCAN_H / 2 - SCAN_RY - 1                     ; ...and up or down off the plane
;  A world axis's high byte is 256 units; one more shift makes a pixel 512,
;  so the oval's eighty pixels are forty thousand units across and, at half
;  that up the oval, a picket ten thousand units ahead sits half way up it.
;  Weapons reach 2560 units, five pixels across and two and a half up: a mark
;  touching the ship is one in range. (It was 1024 a pixel on the forty-pixel
;  box; the doubled oval keeps the same spread of the world and shows it twice
;  as fine.)
SCAN_SHIFT          equ 1

    assert SCAN_Y + SCAN_H <= HUD_TOP, "the scanner reaches into the HUD"
    assert SCAN_Y > CTX_BAR_H
    assert SCAN_SHIFT == 1, "scan_delta shifts once; change it with this"
    assert SCAN_RX * 2 + 2 <= SCAN_W_BYTES * 4, "the oval is wider than its rectangle"
    assert SCAN_RY + SCAN_HALF_V + 1 <= SCAN_H / 2, "a stalk's tip leaves the rectangle"

scan_rect:          defb SCAN_X_BYTES, SCAN_Y, SCAN_W_BYTES, SCAN_H

;  The oval's half height at each pixel of half width, 0..SCAN_RX:
;  round(SCAN_RY * sqrt(1 - (i / SCAN_RX)^2)). tests/test_marks re-derives it.
scan_oval:          defb 19, 19, 19, 19, 19, 19, 19, 19, 19, 18, 18, 18, 18, 18, 18, 17, 17, 17, 17, 16, 16, 16, 15, 15, 15, 14, 14, 13, 13, 12, 12, 11, 10, 9, 8, 7, 6, 4, 0
    assert $ - scan_oval == SCAN_RX + 1

; ----------------------------------------------------------------------------
;  pilot_scanner -- the oval, the ship and the hostiles, while flying
;  Uses: everything
; ----------------------------------------------------------------------------
pilot_scanner:
    ld a,(pilot_slot)
    cp ENT_MAX
    ret nc
    ld a,(view_sensors)
    or a
    ret nz

    ;  The oval, in ink 2 -- chrome, the HUD's own ink for a thing that is
    ;  not a ship -- column by column out of scan_oval, then its rectangle,
    ;  once. Column i draws the rows between the last column's height and
    ;  its own, top and bottom, at cx+i and cx-i; column 0 is one pixel each.
    ld a,(scan_oval)
    ld (scan_prev),a
    xor a
    ld (scan_i),a
@scan_col:
    ld hl,scan_oval
    ld a,(scan_i)
    add a,l
    ld l,a
    jr nc,@scan_col_ok
    inc h
@scan_col_ok:
    ld a,(hl)
    ld (scan_hy),a
    ld b,a
    ld a,(scan_prev)
    sub b
    inc a
    ld (scan_len),a                     ; rows from the last height to this one
    ld a,(scan_prev)
    neg
    add a,SCAN_CY
    ld c,a                              ; the top run starts at cy - prev
    call scan_pair
    ld a,(scan_hy)
    add a,SCAN_CY
    ld c,a                              ; ...and the bottom one at cy + hy
    call scan_pair
    ld a,(scan_hy)
    ld (scan_prev),a
    ld hl,scan_i
    inc (hl)
    ld a,(hl)
    cp SCAN_RX + 1
    jr c,@scan_col
    ld hl,scan_rect
    call phase4_add_rect

    ;  The ship, in the middle, in its own ink.
    ld hl,SCAN_CX
    ld c,SCAN_CY
    ld b,1
    ld a,1
    call gfx_vline

    ;  Its heading, as sin and cos, kept for every hostile.
    ld a,(pilot_slot)
    call ent_addr
    ld (scan_me),hl
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
    push af
    call cam_sin
    ld (scan_sin),a
    pop af
    add a,TRIG_QUARTER
    call cam_sin
    ld (scan_cos),a

    ;  Every flying hostile.
    ld hl,entities + ENT_PLAYER_MAX * ENT_SIZE
    ld (scan_walk),hl
    ld a,ENT_ENEMY_MAX
    ld (scan_left),a
@scan_one:
    ld hl,(scan_walk)
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED
    cp ENT_F_ACTIVE + ENT_F_ENEMY
    jr nz,@scan_next
    call scan_plot
@scan_next:
    ld hl,(scan_walk)
    ld de,ENT_SIZE
    add hl,de
    ld (scan_walk),hl
    ld hl,scan_left
    dec (hl)
    jr nz,@scan_one
    ret

; ----------------------------------------------------------------------------
;  scan_pair -- (scan_len) rows of ink 2 from row C at cx + i and cx - i
;  In : C = the top row, (scan_i), (scan_len)
;  Uses: everything
; ----------------------------------------------------------------------------
scan_pair:
    push bc
    ld a,(scan_i)
    ld e,a
    ld d,0
    ld hl,SCAN_CX
    add hl,de
    ld a,(scan_len)
    ld b,a
    ld a,2
    call gfx_vline
    pop bc
    ld a,(scan_i)
    ld e,a
    ld d,0
    ld hl,SCAN_CX
    or a
    sbc hl,de
    ld a,(scan_len)
    ld b,a
    ld a,2
    jp gfx_vline

; ----------------------------------------------------------------------------
;  scan_plot -- one hostile's mark; scan_walk -> its record
;  Uses: everything
; ----------------------------------------------------------------------------
scan_plot:
    ;  dx, dy and dz as high bytes, saturated: SBC HL,DE overflows across a
    ;  60000-unit map and the sign bit lies, so P/V is tested at once.
    ld hl,(scan_walk)
    ld de,(scan_me)
    call scan_delta                     ; A = dx >> 8, saturated
    ld (scan_dx),a
    ld hl,(scan_walk)
    ld de,(scan_me)
    inc hl
    inc hl
    inc de
    inc de
    call scan_delta                     ; A = dy >> 8: the height
    ld b,SCAN_HALF_V
    call scan_clamp
    ld (scan_dy),a
    ld hl,(scan_walk)
    ld de,(scan_me)
    inc hl
    inc hl
    inc hl
    inc hl
    inc de
    inc de
    inc de
    inc de
    call scan_delta                     ; A = dz >> 8
    ld (scan_dz),a

    ;  right = dz*sin - dx*cos: the ship's right hand is (-cos y, sin y),
    ;  which is +X for a nose along +Z (yaw 128, cos -1) -- the same side
    ;  the cockpit camera puts +X on. First, because the oval's height at
    ;  that column is what bounds `ahead`.
    ld a,(scan_dz)
    ld b,a
    ld a,(scan_sin)
    ld c,a
    call cam_mul7
    ld (scan_t),a
    ld a,(scan_dx)
    ld b,a
    ld a,(scan_cos)
    ld c,a
    call cam_mul7
    ld b,a
    ld a,(scan_t)
    sub b
    ld b,SCAN_HALF_W
    call scan_clamp
    ld (scan_right),a
    ;  ahead = dx*sin - dz*cos, halved for the oval's flattening and kept
    ;  inside the oval at this column: a mark is never outside the plane.
    ld a,(scan_dx)
    ld b,a
    ld a,(scan_sin)
    ld c,a
    call cam_mul7
    ld (scan_t),a
    ld a,(scan_dz)
    ld b,a
    ld a,(scan_cos)
    ld c,a
    call cam_mul7
    ld b,a
    ld a,(scan_t)
    sub b
    sra a
    ld c,a
    ld a,(scan_right)
    bit 7,a
    jr z,@scan_abs_ok
    neg
@scan_abs_ok:
    ld hl,scan_oval
    add a,l
    ld l,a
    jr nc,@scan_oval_ok
    inc h
@scan_oval_ok:
    ld a,(hl)
    dec a
    ld b,a                              ; the oval's half height here, less one
    ld a,c
    call scan_clamp
    ld (scan_ahead),a

    ;  The stalk: from the plane point (cx + right, cy - ahead) up or down
    ;  by the height, then the bar across its tip, all in the alarm ink.
    ld a,(scan_right)
    ld l,a
    ld h,0
    bit 7,a
    jr z,@scan_x_pos
    dec h                               ; sign-extend
@scan_x_pos:
    ld de,SCAN_CX
    add hl,de
    ld (scan_x),hl
    ld a,(scan_ahead)
    neg
    add a,SCAN_CY                       ; A = the plane row
    ld c,a
    ld a,(scan_dy)
    or a
    jp m,@scan_below
    ;  Above, or level: the run starts at the tip, cy - ahead - dy.
    ld b,a
    inc b                               ; dy + 1 rows
    ld a,c
    sub b
    inc a
    ld c,a                              ; the tip row
    jr @scan_stalk
@scan_below:
    neg
    ld b,a
    inc b                               ; |dy| + 1 rows, from the plane row down
@scan_stalk:
    ld (scan_tip),bc                    ; C = the run's top row, B = its length
    ld hl,(scan_x)
    ld a,3
    call gfx_vline
    ;  The bar: one pixel either side of the tip.
    ld a,(scan_dy)
    or a
    ld bc,(scan_tip)
    jp m,@scan_bar
    ;  Above: the tip is the top of the run, which C already is.
    jr @scan_bar_at
@scan_bar:
    ld a,c
    add a,b
    dec a
    ld c,a                              ; below: the tip is the run's last row
@scan_bar_at:
    ld b,1
    push bc
    ld hl,(scan_x)
    dec hl
    ld a,3
    call gfx_vline
    pop bc
    ld hl,(scan_x)
    inc hl
    ld a,3
    jp gfx_vline

; ----------------------------------------------------------------------------
;  scan_delta -- A = ((HL) - (DE)) >> 8 as a saturated signed byte, the
;  words being 16-bit world coordinates. Then >> SCAN_SHIFT.
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
scan_delta:
    ld c,(hl)
    inc hl
    ld b,(hl)                           ; BC = theirs
    ld a,(de)
    ld l,a
    inc de
    ld a,(de)
    ld h,a                              ; HL = ours
    ex de,hl                            ; DE = ours
    ld h,b
    ld l,c                              ; HL = theirs
    or a
    sbc hl,de                           ; HL = theirs - ours
    jp pe,@scan_delta_far               ; overflowed: the true sign is S xor P/V
    ld a,h
    jr @scan_delta_shift
@scan_delta_far:
    ld a,h
    rla                                 ; the false sign into CF...
    ld a,#7F
    jr c,@scan_delta_shift              ; ...which was negative, so it is +far
    ld a,#80
@scan_delta_shift:
    sra a                               ; SCAN_SHIFT, which is 1
    ret

;  Clamp A to +/-B, signed.
scan_clamp:
    bit 7,a
    jr nz,@scan_clamp_neg
    cp b
    ret c
    ld a,b
    ret
@scan_clamp_neg:
    neg
    cp b
    jr c,@scan_clamp_back
    ld a,b
@scan_clamp_back:
    neg
    ret


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
