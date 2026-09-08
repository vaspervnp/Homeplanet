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

;  The reticle: four ticks, PILOT_RET_GAP pixels out from the centre and
;  PILOT_RET_LEN long, in the fleet's ink.
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
    jr nc,@mt_keep

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
;       to do. CF clear: blit it -- and spr_scale says at what scale.
;  Uses: AF, and everything if it draws; C is preserved on the blit path
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
    ld a,(pilot_slot)
    cp ENT_MAX
    jr nc,@mob_blit
    ld a,(phase4_remaining)
    cp PILOT_SPRITES + 1
    jr c,@mob_blit                      ; among the nearest: a sprite
@mob_mark:
    call mark_draw_one
    scf
    ret
@mob_blit:
    or a
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
    ld a,(view_sensors)
    or a
    ret nz
    ;  Left and right: a vertical tick either side, centred on the row.
    ld hl,SCR_CENTRE_X - PILOT_RET_GAP - 1
    ld c,PROJ_CENTRE_Y - PILOT_RET_LEN / 2
    ld b,PILOT_RET_LEN
    ld a,1
    call mark_bar
    ld hl,SCR_CENTRE_X + PILOT_RET_GAP + 1
    ld c,PROJ_CENTRE_Y - PILOT_RET_LEN / 2
    ld b,PILOT_RET_LEN
    ld a,1
    call mark_bar
    ;  Above and below: a vertical tick each, in the centre column.
    ld hl,SCR_CENTRE_X
    ld c,PROJ_CENTRE_Y - PILOT_RET_GAP - PILOT_RET_LEN
    ld b,PILOT_RET_LEN
    ld a,1
    call mark_bar
    ld hl,SCR_CENTRE_X
    ld c,PROJ_CENTRE_Y + PILOT_RET_GAP + 1
    ld b,PILOT_RET_LEN
    ld a,1
    jp mark_bar


; ============================================================================
;  The scanner: where the enemy is, while a ship is being flown
;
;  "Όταν είμαι σε V να φαίνεται όπως στο elite δεξιά το scanner με τις θέσεις
;  των εχθρών." A box at the bottom right of the playfield, the flown ship a
;  white dot in its middle, every flying hostile a red dot placed by where it
;  is RELATIVE TO THE SHIP AND ITS HEADING: up the box is ahead, right is
;  right, 1024 world units to the pixel (SCAN_SHIFT). The cockpit shows what is in
;  front; this is what the cockpit cannot show, which is everything else.
;
;  ONE dirty rectangle for the whole box, appended once a frame, so the next
;  pass through the buffer clears it and the frame is redrawn from nothing --
;  a rectangle per dot would be twenty slots a frame out of a list sized for
;  the entities. The dots are drawn straight through gfx_vline for the same
;  reason, not through mark_dot.
;
;  The rotation is the pilot's own: a ship with ENT_YAW y flies along world
;  (sin y, -cos y), so for a hostile at (dx, dz) from the ship
;      ahead = dx * sin y - dz * cos y,   right = dz * sin y - dx * cos y
;  with the four products through cam_mul7 on the high bytes of dx and dz,
;  which is 256 world units of resolution, shifted SCAN_SHIFT more so the
;  box's forty pixels cover about twenty thousand units. About a thousand T-states a hostile.
; ============================================================================

SCAN_W_BYTES        equ 10              ; 40 pixels
SCAN_H              equ 30
SCAN_X_BYTES        equ SCR_BYTES_PER_LINE - SCAN_W_BYTES - 1
SCAN_Y              equ HUD_TOP - SCAN_H - 4
SCAN_CX             equ SCAN_X_BYTES * 4 + SCAN_W_BYTES * 2          ; pixels
SCAN_CY             equ SCAN_Y + SCAN_H / 2
SCAN_HALF_W         equ SCAN_W_BYTES * 2 - 2                         ; pixels the dots may reach
SCAN_HALF_H         equ SCAN_H / 2 - 2
;  A world axis's high byte is 256 units; two more shifts make a pixel 1024,
;  so the box's forty pixels are forty thousand units across and a picket
;  ten thousand units ahead sits a third of the way up it. Weapons reach
;  2560 units, two and a half pixels: a dot next to the ship is one in range.
SCAN_SHIFT          equ 2

    assert SCAN_Y + SCAN_H < HUD_TOP, "the scanner reaches into the HUD"
    assert SCAN_Y > CTX_BAR_H
    assert SCAN_SHIFT == 2, "scan_delta shifts twice; change it with this"

scan_rect:          defb SCAN_X_BYTES, SCAN_Y, SCAN_W_BYTES, SCAN_H

; ----------------------------------------------------------------------------
;  pilot_scanner -- the box, the ship and the hostiles, while flying
;  Uses: everything
; ----------------------------------------------------------------------------
pilot_scanner:
    ld a,(pilot_slot)
    cp ENT_MAX
    ret nc
    ld a,(view_sensors)
    or a
    ret nz

    ;  The box: top and bottom edges as one-line fills, the sides as lines,
    ;  all in ink 2 -- chrome, the HUD's own ink for a thing that is not a
    ;  ship. Then its rectangle, once.
    ld b,SCAN_X_BYTES
    ld c,SCAN_Y
    ld d,SCAN_W_BYTES
    ld e,1
    ld a,SOLID_INK_2
    call scr_fill_rect
    ld b,SCAN_X_BYTES
    ld c,SCAN_Y + SCAN_H - 1
    ld d,SCAN_W_BYTES
    ld e,1
    ld a,SOLID_INK_2
    call scr_fill_rect
    ld hl,SCAN_X_BYTES * 4
    ld c,SCAN_Y
    ld b,SCAN_H
    ld a,2
    call gfx_vline
    ld hl,(SCAN_X_BYTES + SCAN_W_BYTES) * 4 - 1
    ld c,SCAN_Y
    ld b,SCAN_H
    ld a,2
    call gfx_vline
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
;  scan_plot -- one hostile's dot; scan_walk -> its record
;  Uses: everything
; ----------------------------------------------------------------------------
scan_plot:
    ;  dx and dz as high bytes, saturated: SBC HL,DE overflows across a
    ;  60000-unit map and the sign bit lies, so P/V is tested at once.
    ld hl,(scan_walk)
    ld de,(scan_me)
    call scan_delta                     ; A = dx >> 8, saturated
    ld (scan_dx),a
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

    ;  ahead = dx*sin - dz*cos
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
    call scan_clamp_h
    ld (scan_ahead),a
    ;  right = dz*sin - dx*cos: the ship's right hand is (-cos y, sin y),
    ;  which is +X for a nose along +Z (yaw 128, cos -1) -- the same side
    ;  the cockpit camera puts +X on.
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
    call scan_clamp_w
    ;  (SCAN_CX + right, SCAN_CY - ahead), in the alarm ink.
    ld l,a
    ld h,0
    bit 7,a
    jr z,@scan_x_pos
    dec h                               ; sign-extend
@scan_x_pos:
    ld de,SCAN_CX
    add hl,de
    ld a,(scan_ahead)
    neg
    add a,SCAN_CY
    ld c,a
    ld b,1
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
    sra a                               ; SCAN_SHIFT, which is 2
    sra a
    ret

;  Clamp A to the box, signed.
scan_clamp_w:
    ld b,SCAN_HALF_W
    jr scan_clamp
scan_clamp_h:
    ld b,SCAN_HALF_H
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
