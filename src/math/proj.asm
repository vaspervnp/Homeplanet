; ============================================================================
;  math/proj.asm -- world point -> screen (Homeplanet.md section 4.4)
; ============================================================================
;      1.  v = (P - focus) >> 8          three 16-bit subtracts
;      2.  r = M . v                     nine signed 8x8 multiplies
;      3.  x = rx>>8, y = ry>>8, z = rz>>8 + cam_dist
;      4.  clip on z
;      5.  recip = recip[z]
;      6.  sx = 160 + ((x * recip) >> 7)
;          sy = 100 - ((y * recip) >> 7)
;      7.  clip on screen
;
;  Every truncation here is deliberate and is mirrored exactly by project() in
;  tools/gentables.py; tests/test_phase1.py runs both and demands they agree
;  bit for bit. If you change a shift, change it in both places.
;
;  The >>8 steps are free -- they are just "take H" -- which is why the whole
;  world (16 bits per axis) maps onto a +/-128 camera cube rather than being
;  scaled per zoom step. Zoom moves cam_dist instead.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  proj_point
;  In : HL -> six bytes of world position (x, y, z as 16-bit signed)
;  Out: CF set   -> visible; (proj_sx) (proj_sy) (proj_z) are filled in
;       CF clear -> clipped
;  Uses: everything
; ----------------------------------------------------------------------------
proj_point:
    call proj_deltas                    ; -> proj_v16
    call proj_rotate                    ; -> proj_x, proj_y, proj_z_raw

    ; --- z = (rz >> 8) + cam_dist, in 16 bits so "behind us" is visible ----
    ld a,(proj_z_raw)
    ld l,a
    rla                                 ; sign into CF
    sbc a,a                             ; #FF if negative, #00 if not
    ld h,a                              ; HL = sign-extended rz>>8
    ld de,(cam_dist)
    add hl,de

    ld a,h
    or a
    jr nz,proj_clip                     ; negative, or past 255
    ld a,l
    cp Z_NEAR
    jr c,proj_clip
    ld (proj_z),a

    ; --- recip[z] ---------------------------------------------------------
    ld l,a
    ld h,recip / 256
    ld a,(hl)
    ld (proj_r),a

    ; --- sx = 160 + ((x * r) >> 7) ----------------------------------------
    ld a,(proj_x)
    ld b,a
    ld a,(proj_r)
    ld c,a
    call mul_s8u8
    call proj_shr7
    ld de,SCR_CENTRE_X
    add hl,de

    ;  One unsigned compare covers both ends: a negative sx wraps round to a
    ;  huge unsigned value and fails the same test as sx >= 320.
    ld de,SCR_WIDTH_PX
    or a
    sbc hl,de
    jr nc,proj_clip
    add hl,de
    ld (proj_sx),hl

    ; --- sy = 100 - ((y * r) >> 7) ----------------------------------------
    ld a,(proj_y)
    ld b,a
    ld a,(proj_r)
    ld c,a
    call mul_s8u8
    call proj_shr7
    ex de,hl
    ld hl,SCR_CENTRE_Y
    or a
    sbc hl,de

    ld de,SCR_HEIGHT_PX
    or a
    sbc hl,de
    jr nc,proj_clip
    add hl,de
    ld a,l
    ld (proj_sy),a

    scf                                 ; visible
    ret

proj_clip:
    or a                                ; CF clear
    ret


; ----------------------------------------------------------------------------
;  proj_deltas -- v = (P - focus) >> 8, sign-extended to a word per axis
;  In : HL -> six bytes of world position
;  Out: proj_v16 (three signed words)
;  Uses: everything
;
;  Sign-extended here, once per point, because the rotation below reads each
;  component three times and wants it 16-bit.
;
;  Unrolled rather than looped: a loop would need a fourth register pair to
;  hold the point pointer while HL does the 16-bit subtract, and the only one
;  left is IX.
; ----------------------------------------------------------------------------
    macro DELTA focus, slot
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE = the world coordinate
        inc hl
        push hl
        ld hl,({focus})
        ex de,hl                        ; HL = P, DE = focus
        or a
        sbc hl,de
        ld a,h                          ; >>8
        ld l,a
        rla                             ; sign into CF
        sbc a,a
        ld h,a
        ld (proj_v16 + {slot} * 2),hl
        pop hl
    mend

proj_deltas:
    DELTA cam_focus_x, 0
    DELTA cam_focus_y, 1
    DELTA cam_focus_z, 2
    ret


; ----------------------------------------------------------------------------
;  MULACC -- proj_acc += cam_m16[midx] * proj_v16[vidx]
; ----------------------------------------------------------------------------
;  The signed multiply, with no sign handling and no branches:
;
;      m*v = f9[(m+v) & 1FF] - f9[(m-v) & 1FF]
;
;  f9 is indexed by a NINE-BIT TWO'S COMPLEMENT number (see
;  signed_quarter_squares in tools/gentables.py), so the 16-bit sum already
;  sitting in HL is the index. Both m+v and m-v stay inside -256..255, so the
;  high byte is only ever #00 or #FF and bit 8 of the index is `H AND 1`.
;
;  That is the whole trick. The obvious sign-magnitude version costs two
;  conditional NEGs, a sign XOR and a conditional 16-bit negate; this costs an
;  AND and an ADD, and it has no branches to mispredict a flag through.
; ----------------------------------------------------------------------------
    macro MULACC midx, vidx
        ld hl,(cam_m16 + {midx} * 2)
        ld de,(proj_v16 + {vidx} * 2)
        ld b,h
        ld c,l                          ; keep m, we need it twice
        add hl,de                       ; m + v

        ld a,h
        and 1                           ; bit 8 of the index
        add a,f9_lo / 256
        ld h,a
        ld e,(hl)
        inc h
        inc h                           ; +512 -> the high plane
        ld d,(hl)                       ; DE = f(m+v)
        push de

        ld h,b
        ld l,c                          ; m again
        ld de,(proj_v16 + {vidx} * 2)
        or a
        sbc hl,de                       ; m - v

        ld a,h
        and 1
        add a,f9_lo / 256
        ld h,a
        ld e,(hl)
        inc h
        inc h
        ld d,(hl)                       ; DE = f(m-v)

        pop hl
        or a
        sbc hl,de                       ; HL = m * v, signed

        ld de,(proj_acc)
        add hl,de
        ld (proj_acc),hl
    mend


; ----------------------------------------------------------------------------
;  proj_rotate -- r = M . v
;  In : proj_v16, cam_m16
;  Out: proj_x, proj_y, proj_z_raw  (each the high byte of its row's sum)
;  Uses: everything
;
;  Fully unrolled. m01 is skipped because it is structurally zero for an
;  orbit camera -- row 0 of Rx(pitch).Ry(yaw) is (cy, 0, sy). That is worth
;  about 350 T-states an entity. cam_build_matrix still writes the zero, and
;  test_row_zero_has_the_structural_zero guards it; if the camera model ever
;  gains roll, this shortcut has to go with it.
;
;  The accumulator cannot overflow: |M.v| <= 127 * 128*sqrt(3) = 28156.
;  See the note on MAT_ONE in tools/gentables.py.
; ----------------------------------------------------------------------------
proj_rotate:
    ld hl,0
    ld (proj_acc),hl
    MULACC 0, 0
    MULACC 2, 2
    ld a,(proj_acc + 1)                 ; >>8
    ld (proj_x),a

    ld hl,0
    ld (proj_acc),hl
    MULACC 3, 0
    MULACC 4, 1
    MULACC 5, 2
    ld a,(proj_acc + 1)
    ld (proj_y),a

    ld hl,0
    ld (proj_acc),hl
    MULACC 6, 0
    MULACC 7, 1
    MULACC 8, 2
    ld a,(proj_acc + 1)
    ld (proj_z_raw),a
    ret


; ----------------------------------------------------------------------------
;  proj_shr7 -- HL >>= 7, arithmetic
;  Uses: AF, HL
;
;  Seven SRA/RR pairs would cost 112 T-states. This costs 28: the result's low
;  byte is (H<<1) | (L>>7), which one ADD and one ADC produce directly, and
;  the carry left over from the ADC is the sign for SBC A,A to smear into H.
; ----------------------------------------------------------------------------
proj_shr7:
    ld a,l
    add a,a                             ; CF = bit 7 of L
    ld a,h
    adc a,a                             ; A = low byte; CF = sign of HL
    ld l,a
    sbc a,a                             ; #FF if negative, #00 if not
    ld h,a
    ret


; ============================================================================
;  Working storage
; ============================================================================
;  Camera-space input: (P - focus) >> 8, sign-extended to words because the
;  rotation reads each one three times.
proj_v16:           defs 6, 0

proj_x:             defb 0              ; rotated, after >>8
proj_y:             defb 0
proj_z_raw:         defb 0              ; rotated depth, before cam_dist
proj_z:             defb 0              ; final depth, unsigned, Z_NEAR..Z_FAR
proj_r:             defb 0              ; recip[z]

proj_sx:            defw 0              ; 0..319
proj_sy:            defb 0              ; 0..199

proj_acc:           defw 0
