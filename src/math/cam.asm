; ============================================================================
;  math/cam.asm -- the orbit camera and its rotation matrix
; ============================================================================
;  The camera orbits a focus point (the Mothership, or the selected squadron)
;  rather than flying free: yaw about Y, then pitch about X, at a distance set
;  by the zoom step. So the world-to-camera rotation is
;
;      M = Rx(pitch) . Ry(yaw)
;
;  which works out as
;
;      [  cy          0    sy      ]
;      [  sp*sy       cp  -sp*cy   ]
;      [ -cp*sy       sp   cp*cy   ]
;
;  Nine signed bytes at MAT_ONE (=127) scale, rebuilt ONCE PER FRAME, never
;  per entity -- that is the whole reason the projection is affordable.
;
;  m01 is structurally zero, and proj_rotate skips that multiply outright. The
;  zero is still written here so the matrix reads correctly and the model can
;  be compared against it entry by entry. If the camera ever gains roll, that
;  shortcut in proj_rotate has to go with it.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  cam_build_matrix
;  In : (cam_yaw), (cam_pitch)
;  Out: cam_m filled in
;  Uses: everything
; ----------------------------------------------------------------------------
cam_build_matrix:
    ld a,(cam_yaw)
    call cam_sin
    ld (cam_sy),a
    ld a,(cam_yaw)
    add a,TRIG_QUARTER                  ; cos(a) == sin(a + quarter turn)
    call cam_sin
    ld (cam_cy),a

    ld a,(cam_pitch)
    call cam_sin
    ld (cam_sp),a
    ld a,(cam_pitch)
    add a,TRIG_QUARTER
    call cam_sin
    ld (cam_cp),a

    ; --- row 0:  cy, 0, sy ------------------------------------------------
    ld a,(cam_cy)
    ld (cam_m + 0),a
    xor a
    ld (cam_m + 1),a
    ld a,(cam_sy)
    ld (cam_m + 2),a

    ; --- row 1:  sp*sy, cp, -sp*cy ----------------------------------------
    ld a,(cam_sp)
    ld b,a
    ld a,(cam_sy)
    ld c,a
    call cam_mul7
    ld (cam_m + 3),a

    ld a,(cam_cp)
    ld (cam_m + 4),a

    ld a,(cam_sp)
    ld b,a
    ld a,(cam_cy)
    ld c,a
    call cam_mul7
    neg
    ld (cam_m + 5),a

    ; --- row 2:  -cp*sy, sp, cp*cy ----------------------------------------
    ld a,(cam_cp)
    ld b,a
    ld a,(cam_sy)
    ld c,a
    call cam_mul7
    neg
    ld (cam_m + 6),a

    ld a,(cam_sp)
    ld (cam_m + 7),a

    ld a,(cam_cp)
    ld b,a
    ld a,(cam_cy)
    ld c,a
    call cam_mul7
    ld (cam_m + 8),a

    ; --- sign-extend the nine entries for the projection ------------------
    ;  proj_rotate wants them 16-bit, and doing it here costs ~250 T-states
    ;  once a frame instead of nine times per entity.
    ld hl,cam_m
    ld de,cam_m16
    ld b,9
@sign_extend:
    ld a,(hl)
    inc hl
    ld (de),a
    inc de
    rla                                 ; sign into CF
    sbc a,a
    ld (de),a
    inc de
    djnz @sign_extend
    ret


; ----------------------------------------------------------------------------
;  cam_sin -- A = sin(angle A) * 127
;  Uses: AF, C, DE, HL
;
;  sin7 is only the FIRST QUADRANT -- 65 bytes, not 256 -- and the other three
;  are folded onto it here. Bit 7 of the angle is the sign, and an angle past
;  the peak reflects back as 128 - a.
;
;  The trade is about 40 T-states against 191 bytes of the low 16K, and it is
;  only worth taking because this is called FOUR TIMES A FRAME by
;  cam_build_matrix and nowhere else. The same trade inside proj_rotate would
;  be a bad one, which is why f9 is still 1 KB of full table.
;
;  It is exact, not approximate: sin(pi - x) == sin(x), sin(-x) == -sin(x),
;  and Python's round() is symmetric about zero, so a folded angle reads the
;  same byte the full table held. tests/test_phase1 compares the whole matrix
;  against the model, which still builds itself from all 256.
; ----------------------------------------------------------------------------
cam_sin:
    ld c,a                              ; kept for its sign bit alone
    and #7F                             ; the angle within the half turn
    cp TRIG_QUARTER + 1
    jr c,@cam_sin_rising
    neg
    add a,TRIG_STEPS / 2                ; past the peak: reflect, 128 - a
@cam_sin_rising:
    ld l,a
    ld h,0
    ld de,sin7
    add hl,de
    ld a,(hl)
    bit 7,c
    ret z
    neg
    ret


; ----------------------------------------------------------------------------
;  cam_mul7 -- A = (B * C) >> 7, both signed
;  Uses: everything
;
;  The product cannot exceed 127*127 = 16129, so doubling it stays inside a
;  signed 16-bit value and the shift is just "take the high byte of HL*2".
; ----------------------------------------------------------------------------
cam_mul7:
    call mul_s8
    add hl,hl
    ld a,h
    ret


; ============================================================================
;  Camera state
; ============================================================================

;  Orientation, in 256ths of a turn. The design gives the player 32 yaw steps
;  and 16 pitch steps, so the UI moves these by 8 and 4 -- the matrix itself
;  is happy at full resolution.
cam_yaw:            defb 0
cam_pitch:          defb 0

;  Distance from the focus, added to the rotated Z. One field of the zoom
;  record; order_apply_zoom writes it. Kept 16-bit so the add can overflow
;  visibly.
cam_dist:           defw 150

;  Where the camera is looking.
cam_focus_x:        defw 0
cam_focus_y:        defw 0
cam_focus_z:        defw 0

;  Which zoom step is in force. Twelve of them now (Homeplanet.md section 4.3
;  asks for four), and the table they index -- cam_zoom_table, with its
;  distance AND the shift ladder proj_scale runs -- is generated, because the
;  Python model of the projection has to agree with it exactly. Five is the
;  neutral step, the one whose scaling is a plain >> WORLD_SHIFT.
cam_zoom:           defb CAM_ZOOM_DEFAULT

; --- scratch for the matrix build -------------------------------------------
cam_sy:             defb 0
cam_cy:             defb 0
cam_sp:             defb 0
cam_cp:             defb 0

;  Row-major: m00 m01 m02 m10 m11 m12 m20 m21 m22
cam_m:              defs 9, 0

;  The same nine, sign-extended to words. proj_rotate reads these.
cam_m16:            defs 18, 0
