; ============================================================================
;  game/scanner.asm -- the cockpit's scanner, IN BANK 7, run through bankn_call
; ============================================================================
;  "Όταν είμαι σε V να φαίνεται όπως στο elite δεξιά το scanner με τις θέσεις
;  των εχθρών." -- then "να είναι μεγαλύτερο (x2), οβάλ όπως στο elite και
;  να βλέπω και την διαφορά ύψους στους εχθρούς" -- and, after the V
;  redesign had put it out to make room, "στο V αφαίρεσες το radar. μπορείς
;  να το ξαναβάλεις;". Elite's: an OVAL at the bottom right of the
;  playfield, which is the plane the ship flies in seen flat, the flown ship
;  a white dot in its middle, and every flying hostile a red mark placed by
;  where it is RELATIVE TO THE SHIP AND ITS HEADING: up the oval is ahead,
;  right is right, 512 world units to the pixel across (SCAN_SHIFT) and
;  twice that up the oval, which is half as tall as it is wide. THE HEIGHT
;  IS A STALK: from the hostile's point on the plane a line rises or falls
;  by its height above or below the ship, with a three-pixel bar at the tip
;  -- so a hostile level with you is a dash on the plane and one above you
;  is a dash on a stalk. The cockpit shows ONE enemy and an arrow towards
;  it; this is where all of them are.
;
;  IN BANK 7, AND THAT IS WHY IT IS BACK. It went out at 527 bytes of bank
;  4 when the window was at zero, and bank 4 has sixteen. It runs from this
;  bank through bankn_call (sys/libload.asm) -- nine bytes of bank 4 at the
;  call site -- on the chase's reasoning: it calls the LOW 16K only
;  (gfx_vline, phase4_add_rect, ent_addr, cam_sin, cam_mul7), reads the low
;  16K only (pilot_slot, view_sensors, the entity table), its oval's table
;  is beside it and its scratch is this bank's RAM. The room in the bank is
;  the briefings' packing: see game/textpack.asm. Nothing here may call
;  bank 4 or bank7_fetch.
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
;
;  The bottom-right corner arrow (pilot_arrow, game/farmarks.asm) lands
;  inside the oval when the enemy is off the screen that way. Both are
;  ORed in, red over blue, and the arrow is on top; neither erases the
;  other, since each has its own rectangle. Accepted rather than moved: the
;  eight arrows cover every edge and a box this size has nowhere else to be.
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
;  touching the ship is one in range.
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
;  In : (through bankn_call, A = GA_BANK_7, IX = pilot_scanner)
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
    ;  HL walks the table, D is the last column's height and E the column,
    ;  pushed round the two calls: registers where the first version kept
    ;  four bytes of scratch, and forty bytes shorter for it.
    ld hl,scan_oval
    ld d,(hl)
    ld e,0
@scan_col:
    ld a,(hl)
    ld c,a                              ; C = this column's height
    ld a,d
    sub c
    inc a
    ld b,a                              ; B = rows from the last height to this one
    push hl
    push de
    push bc
    ld a,d
    neg
    add a,SCAN_CY
    ld c,a                              ; the top run starts at cy - prev
    call scan_pair
    pop bc
    pop de
    push de
    push bc
    ld a,c
    add a,SCAN_CY
    ld c,a                              ; ...and the bottom one at cy + hy
    call scan_pair
    pop bc
    pop de
    pop hl
    ld d,c                              ; the last height is this one now
    inc hl
    inc e
    ld a,e
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
;  scan_pair -- B rows of ink 2 from row C, at cx + E and at cx - E
;  In : C = the top row, B = how many rows, E = the column
;  Uses: everything
; ----------------------------------------------------------------------------
scan_pair:
    ld d,0
    ld hl,SCAN_CX
    add hl,de
    push de
    push hl
    push bc
    call @scan_pair_run
    pop bc
    pop hl
    pop de
    or a
    sbc hl,de
    sbc hl,de                           ; cx + E, less 2E
@scan_pair_run:
    ld a,2
    jp gfx_vline

; ----------------------------------------------------------------------------
;  scan_plot -- one hostile's mark; scan_walk -> its record
;  Uses: everything
; ----------------------------------------------------------------------------
scan_plot:
    ;  dx, dy and dz as high bytes, saturated -- scan_delta walks both
    ;  records an axis at a time. SBC HL,DE overflows across a 60000-unit
    ;  map and the sign bit lies, so P/V is tested at once in there.
    ld hl,(scan_walk)
    ld de,(scan_me)
    call scan_delta                     ; A = dx >> 8, saturated
    ld (scan_dx),a
    call scan_delta                     ; A = dy >> 8: the height
    ld b,SCAN_HALF_V
    call scan_clamp
    ld (scan_dy),a
    call scan_delta                     ; A = dz >> 8
    ld (scan_dz),a

    ;  right = dz*sin - dx*cos: the ship's right hand is (-cos y, sin y),
    ;  which is +X for a nose along +Z (yaw 128, cos -1) -- the same side
    ;  the cockpit camera puts +X on. First, because the oval's height at
    ;  that column is what bounds `ahead`.
    ld a,(scan_dz)
    ld b,a
    ld a,(scan_dx)
    ld d,a
    call scan_cross
    ld b,SCAN_HALF_W
    call scan_clamp
    ld (scan_right),a
    ;  ahead = dx*sin - dz*cos, halved for the oval's flattening and kept
    ;  inside the oval at this column: a mark is never outside the plane.
    ld a,(scan_dx)
    ld b,a
    ld a,(scan_dz)
    ld d,a
    call scan_cross
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
    rla
    sbc a,a
    ld h,a                              ; sign-extended
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
    jp p,@scan_bar_at                   ; above: the tip is the top of the run, which C is
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
;  scan_cross -- A = B * sin - D * cos, the ship's heading being the angle
;  In : B, D = the two signed deltas
;  Uses: everything
; ----------------------------------------------------------------------------
scan_cross:
    push de
    ld a,(scan_sin)
    ld c,a
    call cam_mul7
    pop de
    push af                             ; B * sin
    ld b,d
    ld a,(scan_cos)
    ld c,a
    call cam_mul7                       ; D * cos
    ld b,a
    pop af
    sub b
    ret

; ----------------------------------------------------------------------------
;  scan_delta -- A = ((HL) - (DE)) >> 8 as a saturated signed byte, then
;  >> SCAN_SHIFT; the words being 16-bit world coordinates. HL and DE are
;  left PAST the two words, so three calls walk the three axes.
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
scan_delta:
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl                              ; BC = theirs, HL past it
    ex de,hl                            ; HL -> ours, DE = past theirs
    push de
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl                              ; DE = ours, HL past it
    push hl
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
    pop de                              ; DE = past ours
    pop hl                              ; HL = past theirs
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

;  Scratch: this bank's RAM, all written before it is read inside one call.
;  In the image, as the chase's state is; tests/test_shipclass masks it out
;  of the bank's comparison with the disc.
scan_me:            defw 0              ; the flown ship's record
scan_walk:          defw 0              ; the hostile being plotted
scan_left:          defb 0
scan_sin:           defb 0
scan_cos:           defb 0
scan_dx:            defb 0
scan_dy:            defb 0
scan_dz:            defb 0
scan_right:         defb 0              ; a hostile's mark: across, and
scan_x:             defw 0              ; ...its column on the screen
scan_tip:           defw 0              ; ...and its stalk: top row, rows
scan_ahead:         defb 0              ; ...and up the oval. LAST, and a byte: the mask above is scan_me..here
