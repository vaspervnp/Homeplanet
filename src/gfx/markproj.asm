; ============================================================================
;  gfx/markproj.asm -- the cached half of the marker pass. IN BANK 4.
; ============================================================================
;  gfx/mark.asm draws; this projects. The split is not tidiness, it is the
;  memory map: everything here runs ONLY on the frames where the camera hash
;  has changed, and always with the window at its resting state, so it is bank
;  code by the same rule that put the title screen and the orders menu there.
;
;  It is the only thing in the bank that is reached from inside the frame loop
;  at all, so the rule it must not break is the one in game/shipclass.asm:
;  nothing here may be called from between class_tier_addr and class_blit_done,
;  where bank 4 is paged out. demo_update calls mark_update long before
;  phase4_draw, which is the only place that ever happens.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  mark_init
;  Uses: AF, HL
; ----------------------------------------------------------------------------
mark_init:
    ld a,#FF
    ld (mark_shadow),a                  ; force the first projection
    xor a
    ld (mark_count),a
    ld (moth_bar),a
    ret


; ----------------------------------------------------------------------------
;  mark_update -- reproject everything static, but only if the camera moved
;
;  The hash is over yaw, pitch, zoom and the focus point, which between them
;  are the whole of what the projection depends on: nothing else here moves.
;  Uses: everything
; ----------------------------------------------------------------------------
mark_update:
    ld a,(cam_yaw)
    ld c,a
    ld a,(cam_pitch)
    xor c
    ld c,a
    ld a,(cam_zoom)
    xor c
    ld c,a
    ld a,(cam_focus_x)
    xor c
    ld c,a
    ld a,(cam_focus_y)
    xor c
    ld c,a
    ld a,(cam_focus_z)
    xor c
    ld hl,mark_shadow
    cp (hl)
    ret z                               ; nothing the markers care about moved
    ld (hl),a

    ld hl,mark_cache
    ld (mark_dst),hl
    xor a
    ld (mark_count),a

    ;  The resource patches, tagged 1..MARK_PATCHES so that mark_draw can find
    ;  a patch's stock again -- its ink is the one thing here that must not be
    ;  cached, because the stock runs down while the camera sits still.
    ld hl,eco_patches
    ld (mark_src),hl
    ld hl,ECO_PATCH_SIZE
    ld (mark_stride),hl
    ld a,1
    ld (mark_tag),a
    ld a,MARK_PATCHES
    ld (mark_left),a
    call mark_project_run

    ;  ...and the reference plane, tagged 0. Its points are STEPPED rather
    ;  than stored, so the source pointer does not move and the stride is zero,
    ;  which is what mark_project_run reads as "ask the lattice for the next
    ;  one".
    call mark_lattice_reset
    ld hl,mark_point
    ld (mark_src),hl
    ld hl,0
    ld (mark_stride),hl
    xor a
    ld (mark_tag),a
    ld a,GRID_POINTS
    ld (mark_left),a
    call mark_project_run

    jp moth_update


; ----------------------------------------------------------------------------
;  mark_project_run -- project (mark_left) points into the cache
;  In : (mark_src), (mark_stride) -- zero means "step the lattice instead",
;       (mark_tag) -- 0 for the plane, 1.. for a patch, incremented as it goes
;  Uses: everything
;
;  A clipped point is simply not in the list; nothing needs to find one again,
;  because a patch carries its own tag.
; ----------------------------------------------------------------------------
mark_project_run:
@mark_run_one:
    ld hl,(mark_src)
    call proj_point
    jr nc,@mark_run_next                ; clipped: leave it out

    ld hl,(mark_dst)
    ld de,(proj_sx)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(proj_sy)
    ld (hl),a
    inc hl
    ld a,(mark_tag)
    ld (hl),a
    inc hl
    ld (mark_dst),hl
    ld hl,mark_count
    inc (hl)

@mark_run_next:
    ld hl,mark_tag
    ld a,(hl)
    or a
    jr z,@mark_run_step                 ; the whole plane is one tag
    inc (hl)

@mark_run_step:
    ld hl,(mark_stride)
    ld a,h
    or l
    jr nz,@mark_run_advance
    call mark_lattice_step
    jr @mark_run_dec
@mark_run_advance:
    ld de,(mark_src)
    add hl,de
    ld (mark_src),hl
@mark_run_dec:
    ld hl,mark_left
    dec (hl)
    jr nz,@mark_run_one
    ret


; ----------------------------------------------------------------------------
;  mark_lattice_reset / mark_lattice_step -- walk the 4 x 4 plane at Y=0
;  Uses: AF, BC, DE, HL
;
;  Stepped rather than stored. The lattice used to be ninety-six bytes of
;  `defw` in bank 4 and every one of them was one of four numbers -- it is a
;  square grid, so a corner and a stride say the same thing in eight. That is
;  a good part of what the Mothership indicator is built out of.
; ----------------------------------------------------------------------------
GRID_HALF           equ GRID_SPACING / 2
GRID_FIRST          equ -3 * GRID_HALF
GRID_STEP           equ 2 * GRID_HALF

mark_lattice_reset:
    ld hl,GRID_FIRST
    ld (mark_point + 0),hl              ; x
    ld (mark_point + 4),hl              ; z
    ld hl,0
    ld (mark_point + 2),hl              ; the plane IS Y=0
    ld a,4
    ld (mark_col),a
    ret

mark_lattice_step:
    ld hl,(mark_point + 0)
    ld de,GRID_STEP
    add hl,de
    ld (mark_point + 0),hl
    ld hl,mark_col
    dec (hl)
    ret nz
    ld (hl),4                           ; end of a row: back to the left...
    ld hl,GRID_FIRST
    ld (mark_point + 0),hl
    ld hl,(mark_point + 4)              ; ...and one step further out
    ld de,GRID_STEP
    add hl,de
    ld (mark_point + 4),hl
    ret


; ============================================================================
;  The off-screen Mothership indicator
; ============================================================================
;  A blue marker on the border of the view, in the direction the Mothership
;  lies, with a bar showing how far above or below the camera it sits -- the
;  move disc's height idiom, so the two read as the same language.
;
;  "Which way" is the awkward half. proj_point tells you for free that a point
;  is off screen, but its clip path throws the rotated camera-space vector
;  away, and past PROJ_V_LIMIT it never computes one at all. Rather than grow
;  a second projection pipeline, this borrows the TWELFTH ZOOM STEP: at >>8
;  the visible radius is the whole 16-bit world and proj_scale's range check
;  is patched out altogether, so proj_deltas cannot reject anything. Two LDIRs
;  out and two back, on the frames the camera moves. src/main.asm asserts that
;  the last step really is that wide.
;
;  The one case it does not cover is two points more than 32767 apart on one
;  axis, where the subtract inside proj_deltas overflows and the sign bit lies.
;  DISC_LIMIT is 30000, so a squadron sent to one end of the map with the
;  Mothership past the middle can just about do it. There is no marker then,
;  which is what the player had before this existed.
; ----------------------------------------------------------------------------
moth_update:
    xor a
    ld (moth_bar),a                     ; no indicator unless we reach the end
    ld a,(moth_slot)
    call ent_is_active
    ret nc
    ld a,(moth_slot)
    call ent_addr
    ld (mark_src),hl
    call proj_point
    ret c                               ; on screen: nothing to point at

    ld a,(cam_zoom)
    ld (moth_zoom),a
    ld a,CAM_ZOOM_STEPS - 1
    ld (cam_zoom),a
    call order_apply_zoom

    ld hl,(mark_src)
    call proj_deltas
    push af                             ; the zoom goes back before anything
    call c,proj_rotate                  ; else can project through it
    ld a,(moth_zoom)
    ld (cam_zoom),a
    call order_apply_zoom
    pop af
    ret nc

    call moth_place
    ret nc

    ;  How high it is: world Y against the camera's focus, which is what
    ;  "relative to the camera" means to someone looking at an orbit camera.
    ld hl,(mark_src)
    inc hl
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = the Mothership's Y
    ld hl,(cam_focus_y)
    ex de,hl
    or a
    sbc hl,de
    jp pe,@moth_h_far                   ; P/V first: the sign bit lies when the
                                        ; subtract overflowed, and two points
                                        ; can be 60000 apart
    bit 7,h
    jr z,@moth_h_up
    xor a                               ; below: negate, and hang the bar down
    sub l
    ld l,a
    sbc a,a
    sub h
    ld h,a
    call moth_h_scale
    neg
    ld (moth_bar),a
    ret

@moth_h_up:
    call moth_h_scale
    ld (moth_bar),a
    ret

@moth_h_far:
    ;  Further apart than sixteen bits can say, so it is off the end of the
    ;  bar whichever way it went; H still carries the sign of the difference.
    ld a,MOTH_H_MAX
    bit 7,h
    jr z,@moth_h_far_up
    neg
@moth_h_far_up:
    ld (moth_bar),a
    ret


; ----------------------------------------------------------------------------
;  moth_h_scale -- A = HL >> MOTH_H_SHIFT, held inside 1..MOTH_H_MAX
;  In : HL = a positive world distance
;  Uses: AF
;
;  Never zero: zero is what moth_bar uses for "there is no indicator", and a
;  Mothership exactly level with the camera is not that.
; ----------------------------------------------------------------------------
moth_h_scale:
    ld a,h
    cp MOTH_H_MAX
    jr c,@moth_h_ok
    ld a,MOTH_H_MAX
@moth_h_ok:
    or a
    ret nz
    inc a
    ret


; ----------------------------------------------------------------------------
;  moth_place -- put the marker on the border of the view
;  In : proj_x, proj_y = the rotated direction to the Mothership
;  Out: CF set and (moth_x), (moth_y) filled in; CF clear if there is no
;       bearing to show at all
;  Uses: everything
;
;  The border is a box twice as wide as it is tall, and the marker lands ON it
;  by construction: scale (dx, dy) until max(|dx|, 2|dy|) is exactly the
;  half-width, and whichever of those two was the larger names the edge it
;  touches. No dominance test and no case analysis.
;
;  The scaling is the perspective divide's own table. recip[n] is PROJ_K/n, so
;  (v * recip[2m]) >> 7 is v * 80 / m; the power-of-two normalisation that puts
;  m in 64..127 first is what keeps both the table index and the signed
;  multiply inside a byte, and doubling the result afterwards is free.
;
;  A fixed set of eight or sixteen compass points was the cheaper option and
;  was rejected: the marker would jump between them, and a bearing that jumps
;  is one the eye stops believing.
;
;  NO FRONT/BEHIND TEST, and none is needed. (rx, -ry) is the direction to turn
;  the camera whether the Mothership is in front or behind: a thing behind you
;  and to the right is still found by turning right. Only the degenerate case
;  -- straight along the view axis, where rx and ry are both zero -- has no
;  answer, and that returns CF clear.
; ----------------------------------------------------------------------------
moth_place:
    ld a,(proj_x)
    ld (moth_dx),a
    ld a,(proj_y)
    neg                                 ; screen y grows downward
    ld (moth_dy),a

    ld a,(moth_dx)
    call moth_abs
    ld b,a
    ld a,(moth_dy)
    call moth_abs
    cp 128
    jr c,@moth_dy_fits
    ld a,127                            ; -128 has no positive; near enough
@moth_dy_fits:
    add a,a                             ; 2|dy|, the box being 2:1
    cp b
    jr nc,@moth_have_m
    ld a,b
@moth_have_m:
    or a
    ret z                               ; straight along the view axis
    ld (moth_m),a

@moth_norm:
    ld a,(moth_m)
    cp 64
    jr nc,@moth_norm_big
    add a,a
    ld (moth_m),a
    ld a,(moth_dx)
    add a,a
    ld (moth_dx),a
    ld a,(moth_dy)
    add a,a
    ld (moth_dy),a
    jr @moth_norm
@moth_norm_big:
    cp 128
    jr c,@moth_norm_done
    srl a
    ld (moth_m),a
    ld a,(moth_dx)
    sra a
    ld (moth_dx),a
    ld a,(moth_dy)
    sra a
    ld (moth_dy),a
    jr @moth_norm_big
@moth_norm_done:

    add a,a                             ; recip wants 84..255, and 2m is 128..254
    ld l,a
    ld h,recip / 256
    ld a,(hl)
    ld (moth_r),a

    ld a,(moth_dx)
    call moth_scale                     ; HL = dx * 160 / m, -160..160
    ld de,SCR_CENTRE_X
    add hl,de

    ;  Keep the cross's side pixels on the line they belong to -- and note
    ;  that this is SIGNED. dx' reaches -160, so 160 + dx' can be -2, whose
    ;  high byte is #FF; testing "is the high byte zero" and then treating
    ;  everything else as 256.. put a marker meant for the left edge on the
    ;  right one, and the two pans that should have been mirror images of each
    ;  other came out identical.
    bit 7,h
    jr nz,@moth_x_min
    ld a,h
    or a
    jr z,@moth_x_low
    ld a,l
    cp 62                               ; 256 + 62 = 318
    jr c,@moth_x_done
    ld hl,317
    jr @moth_x_done
@moth_x_low:
    ld a,l
    cp 2
    jr nc,@moth_x_done
@moth_x_min:
    ld hl,2
@moth_x_done:
    ld (moth_x),hl

    ld a,(moth_dy)
    call moth_scale                     ; -80..80
    ld a,l
    add a,MOTH_CENTRE_Y
    cp MOTH_Y_MIN
    jr nc,@moth_y_low_ok
    ld a,MOTH_Y_MIN                     ; leave the height bar somewhere to go
@moth_y_low_ok:
    cp MOTH_Y_MAX + 1
    jr c,@moth_y_done
    ld a,MOTH_Y_MAX
@moth_y_done:
    ld (moth_y),a
    scf
    ret


;  A = |A|, signed
;  Uses: AF
moth_abs:
    or a
    ret p
    neg
    ret


;  HL = (A * moth_r) >> 6, which is A * 160 / m
;  Uses: everything
moth_scale:
    ld b,a
    ld a,(moth_r)
    ld c,a
    call mul_s8u8
    call proj_shr7
    add hl,hl
    ret

