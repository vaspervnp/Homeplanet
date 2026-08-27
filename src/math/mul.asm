; ============================================================================
;  math/mul.asm -- multiplication, which the Z80 does not have
; ============================================================================
;  Quarter squares (Homeplanet.md section 4.2):
;
;      a * b = f(a + b) - f(a - b),   f(n) = n^2 / 4
;
;  One table serves both terms: a+b reaches 510, and |a-b| never exceeds 255,
;  so the difference indexes the same array. 512 entries, split into a low and
;  a high byte plane on consecutive pages -- see tools/gentables.py.
; ----------------------------------------------------------------------------

;  mul_u8 indexes both planes off one page register, so the high plane must sit
;  exactly 512 bytes above the low one and both must be page-aligned. The
;  generator emits them that way and main.asm asserts it -- the check has to
;  live there because RASM evaluates ASSERT where it stands, and the tables
;  are included after this file.
; ----------------------------------------------------------------------------


; ----------------------------------------------------------------------------
;  mul_u8 -- unsigned 8 x 8 -> 16
;  In : H = a, L = b
;  Out: HL = a * b
;  Uses: AF, BC, DE, HL
;
;  The two table lookups are WRITTEN OUT rather than called. They used to be a
;  routine, qsq_f, and the pair of CALL/RET was 54 T-states of a routine whose
;  whole body is eleven; proj_point runs mul_u8 twice and cam_build_matrix nine
;  times, so it was ~110 T an entity and ~500 T a frame for nothing. Inlining
;  costs one byte, because the second copy also loses the `jr nc` -- the second
;  index is eight bits by construction and can only be on page 0.
;
;  f is indexed by a NINE-bit number: a+b reaches 510, so the carry out of the
;  add is bit 8, and LD does not touch flags, which is why the two `ld` in the
;  middle are safe.
; ----------------------------------------------------------------------------
mul_u8:
    ld a,h
    add a,l                             ; a+b, CF = bit 8
    ld b,h                              ; LD does not touch flags, so CF
    ld c,l                              ; survives to the `jr nc` below

    ld l,a
    ld h,qsq_lo / 256
    jr nc,@qsq_page0
    inc h
@qsq_page0:
    ld e,(hl)
    inc h
    inc h                               ; +512 -> the high plane, same index
    ld d,(hl)
    push de                             ; f(a+b)

    ld a,b
    sub c
    jr nc,@positive
    neg                                 ; |a-b|, which is 8 bits, page 0 only
@positive:
    ld l,a
    ld h,qsq_lo / 256
    ld e,(hl)
    inc h
    inc h
    ld d,(hl)                           ; DE = f(|a-b|)

    pop hl
    or a
    sbc hl,de
    ret


; ----------------------------------------------------------------------------
;  mul_s8 -- signed 8 x 8 -> 16
;  In : B = a, C = b (both signed)
;  Out: HL = a * b (signed)
;  Uses: AF, BC, DE, HL
;
;  Sign-magnitude: the sign of the result is the XOR of the operands' signs,
;  so multiply the magnitudes and negate at the end if needed.
; ----------------------------------------------------------------------------
mul_s8:
    ld a,b
    xor c
    push af                             ; bit 7 = sign of the product

    ld a,b
    or a
    jp p,@a_positive
    neg
@a_positive:
    ld h,a

    ld a,c
    or a
    jp p,@b_positive
    neg
@b_positive:
    ld l,a

    call mul_u8                         ; HL = |a| * |b|

    pop af
    and #80
    ret z
    ; fall through to negate

; ----------------------------------------------------------------------------
;  neg_hl -- HL = -HL
;  Uses: AF, HL
; ----------------------------------------------------------------------------
neg_hl:
    xor a
    sub l
    ld l,a
    sbc a,a                             ; #FF if the low byte borrowed
    sub h
    ld h,a
    ret


; ----------------------------------------------------------------------------
;  mul_s8u8 -- signed x unsigned -> signed 16
;  In : B = a (signed), C = b (unsigned 0..255)
;  Out: HL = a * b (signed)
;  Uses: AF, BC, DE, HL
;
;  The projection needs this: the coordinate is signed but recip[] runs up to
;  255, which would read back as a negative byte in mul_s8.
; ----------------------------------------------------------------------------
mul_s8u8:
    ld a,b
    or a
    jp p,@a_not_negative
    neg
    ld h,a
    ld l,c
    call mul_u8
    jp neg_hl
@a_not_negative:
    ld h,a
    ld l,c
    jp mul_u8
