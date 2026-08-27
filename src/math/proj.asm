; ============================================================================
;  math/proj.asm -- world point -> screen (Homeplanet.md section 4.4)
; ============================================================================
;      1.  v = (P - focus) >> WORLD_SHIFT, clipped to a signed byte
;      2.  r = M . v                     nine signed 8x8 multiplies
;      3.  x = rx>>8, y = ry>>8, z = rz>>8 + cam_dist
;      4.  clip on z
;      5.  recip = recip[z]
;      6.  sx = 160 + mag((x * recip) >> 7)
;          sy =  89 - mag((y * recip) >> 7)
;      7.  clip on screen
;
;  Every truncation here is deliberate and is mirrored exactly by project() in
;  tools/gentables.py; tests/test_phase1.py runs both and demands they agree
;  bit for bit. If you change a shift, change it in both places.
;
;  WORLD_SHIFT is 6, so 16 bits of world span +/-512 camera units. It used to
;  be 8, which was free on a Z80 -- >>8 is just "take H" -- but that folded the
;  whole world into the +/-128 cube the camera can see at once, and at
;  cam_dist 110..250 the widest zoom then showed all of it. Six costs two
;  `add hl,hl` an axis and buys four times the play area; everything authored
;  in world units was divided by four to keep ships the same size on screen.
;
;  What did NOT grow is how much is visible at once: step 1 still has to fit a
;  signed byte, so anything more than PROJ_V_LIMIT world units off the focus
;  on any axis is clipped. See proj_deltas.
;
;  ...and that clip is where the ZOOM lives, which is not where anyone looks
;  for it. Step 1's shift is not fixed at WORLD_SHIFT any more: proj_scale
;  runs a patched ladder, and the zoom step decides how far down a world delta
;  comes on its way into the +/-127 cube. A bigger shift is a bigger radius of
;  visible world at identical screen positions and identical size tiers.
;  cam_dist cannot do that job -- it only decides how much of the SCREEN the
;  cube covers, and it runs out of byte at 255.
;
;  Step 6 has a MAGNIFICATION in it, and that is a different thing again. PROJ_K
;  was chosen so that 45 degrees off axis lands on the screen edge; nothing in
;  this game ever gets near 45 degrees off axis once cam_dist is long, so the
;  outer part of the screen was not merely empty but unreachable. proj_mag
;  multiplies the offset AFTER the divide and before the centre, by 2 to 4
;  depending on cam_dist. It is not zoom: it shows the same world --
;  proj_deltas' clip radius is untouched -- and it does not touch proj_z, so
;  every ship's size tier is exactly what it was.
;
;  MEASURE IT ALONG THE PLAY AREA'S OWN AXES. The first version of this was
;  calibrated against the largest |sx - 160| the +/-127 cube could produce over
;  every yaw and pitch, which is a corner swung round near the near plane where
;  the divide blows up; it reported 98% of the width while a fleet spread across
;  the play area still came out inside the middle third. The number that matters
;  is the edge of the visible radius at the focus' own depth, and at x1 it is
;  91, 67, 50 and 40 pixels of a half-width of 160. See ZOOM_STEPS.
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
    ret nc                              ; too far off the focus to be on screen
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

    ; --- sx = 160 + mag((x * r) >> 7) -------------------------------------
    ld a,(proj_x)
    call proj_offset
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

    ; --- sy = 89 - mag((y * r) >> 7) --------------------------------------
    ;  89, not 100: the playfield is CTX_BAR_H..HUD_TOP and its middle is not
    ;  the screen's. See PROJ_CENTRE_Y.
    ld a,(proj_y)
    call proj_offset
    ex de,hl
    ld hl,PROJ_CENTRE_Y
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
;  proj_offset -- one axis of the perspective divide, magnified
;  In : A = the rotated component (signed), (proj_r) = recip[z]
;  Out: HL = the signed offset from the centre of the screen
;  Uses: everything
;
;  ONE routine for both axes rather than two calls each, which is where the
;  magnification is paid for: proj_point used to `call mul_s8u8` and then
;  `call proj_shr7` per axis, and folding the pair into one call with the shift
;  written out gives back 54 T-states -- rather more than proj_mag costs.
;
;  (x * r) >> 7 always fits -256..255: |x| <= 128 and r <= 244, so the product
;  is at most 32640 and the shift at most 255. That is what lets the >>7 be six
;  instructions instead of seven SRA/RR pairs -- the low byte of the result is
;  (H<<1) | (L>>7), which one ADD and one ADC produce, and the carry left over
;  is the sign for SBC A,A to smear into H. It is proj_shr7 written out; the
;  routine itself stays for gfx/markproj.asm.
;
;  proj_mag is then the same trick as proj_scale: SIX PATCHED BYTES, no branch,
;  LDIR'd in by order_apply_zoom out of cam_zoom_table. It computes
;
;      HL = (t << j) + (t >> k)
;
;  with DE holding t on the way in. The four-byte head is EITHER the halving of
;  DE -- `sra d : rr e`, two CB-prefixed instructions that fill it on their own
;  -- OR further doublings of HL, so the factors it can reach are 1, 1.5, 2,
;  2.5, 3, 4 and 5. See ZOOM_MAG_FORMS in tools/gentables.py.
;
;  The whole slot is 32 T-states an axis at x1 (six NOPs and a dead
;  `ld d,h : ld e,l`) and 46 at the worst of the factors in use. Measured, at
;  4000 iterations so the quantum is 20 T rather than the cost test's 100:
;
;      x1  4,860 T     x2    4,860 T
;      x4  4,880 T     x2.5  4,880 T   <- the default step
;
;  Twenty T-states an entity for the whole magnification, ~480 of a 530,000 T
;  frame. (TestProjectionCost reads 4,960 for the same build: it runs 800
;  iterations, so one PAL frame is 100 T and the reading rounds up a whole
;  quantum. Budget 5,000. Measure at 4000 before believing a regression here.)
;  A patched JR to skip the NOPs would save 24 of the 64 and is exactly the
;  shape that took proj_scale over the budget guard the first time it was
;  written.
;
;  The bytes below are the DEFAULT step's factor (x2.5) assembled in place, so
;  proj_point is correct before anything has pressed a key -- the same
;  arrangement proj_scale's ladder has, and for the same reason.
; ----------------------------------------------------------------------------
proj_offset:
    ld b,a
    ld a,(proj_r)
    ld c,a
    call mul_s8u8                       ; HL = component * recip[z]

    ld a,l
    add a,a                             ; CF = bit 7 of L
    ld a,h
    adc a,a                             ; A = low byte; CF = sign of HL
    ld l,a
    sbc a,a                             ; #FF if negative, #00 if not
    ld h,a                              ; HL = t, in -256..255

    ld d,h
    ld e,l                              ; DE = t
proj_mag:
    sra d                               ; DE = t >> 1, on the steps with a half
    rr e                                ;   in the factor; four bytes that hold
                                        ;   `add hl,hl` or NOPs on the others
    add hl,hl                           ; HL = t << 1, or NOP
    add hl,de                           ; + DE, or NOP
proj_mag_end:
    ret


; ----------------------------------------------------------------------------
;  proj_deltas -- v = (P - focus) >> WORLD_SHIFT, a sign-extended word per axis
;  In : HL -> six bytes of world position
;  Out: CF set   -> proj_v16 holds three signed words in -128..127
;       CF clear -> out of range on some axis; nothing else is valid
;  Uses: everything
;
;  Sign-extended here, once per point, because the rotation below reads each
;  component three times and wants it 16-bit.
;
;  Unrolled rather than looped: a loop would need a fourth register pair to
;  hold the point pointer while HL does the 16-bit subtract, and the only one
;  left is IX.
;
;  THE RANGE CHECK IS NOT OPTIONAL. Each component has to stay inside a signed
;  byte for two separate reasons, both of them about MAT_ONE being 127:
;
;    * MULACC indexes f9 with m+v as a nine-bit two's complement number, so
;      |m| + |v| must stay under 256. Feed it 200 and the index wraps to a
;      quarter-square of something else entirely, and the entity draws itself
;      somewhere it is not.
;    * proj_rotate's accumulator is bounded by 127 * |v|max * sqrt(3). That is
;      28156 at |v| = 128 and 56312 at 256, and only the first fits 16 bits.
;
;  It pays for itself: a rejected entity never reaches proj_rotate, which is
;  ~2,790 T-states, so the clip is cheaper than the work it skips.
; ----------------------------------------------------------------------------
;  The largest world delta that survives, per axis, AT THE NEUTRAL ZOOM STEP:
;  8191 units at WORLD_SHIFT 6 -- and DISC_LIMIT is 30000, so a fleet really
;  can be sent past it. The zoom ladder moves this between 2048 and 32768; see
;  ZOOM_STEPS in tools/gentables.py.
;
;  PROJ_V_BIAS is written as the bias that turns the two-sided signed test on
;  the difference's HIGH byte into one unsigned range check, the way
;  order_clamp_pitch does: h + 32 in 0..63 is exactly HL in -8192..8191. It is
;  1 << (WORLD_SHIFT - 1), which is 128 at the old shift of 8 -- i.e. a test
;  that can never fail, which is why there was no clipping to do before.
;
;  Literals because gen/tables.asm is included after this file and RASM
;  evaluates as it goes. src/main.asm asserts they agree once both are in
;  scope -- change WORLD_SHIFT in tools/gentables.py and the build says so.
PROJ_V_BIAS         equ 32
PROJ_V_LIMIT        equ (PROJ_V_BIAS << 8) - 1      ; = 8191

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

        ;  Two points on one axis can be 65534 apart, which does not fit the
        ;  register holding their difference -- and when SBC overflows the
        ;  sign bit LIES. Test P/V here, before anything else touches the
        ;  flags: overflowing means further than 32767, which is far.
        jp pe,proj_deltas_far
        call proj_scale                 ; A = the camera-space component
        jr nc,proj_deltas_far

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
    scf                                 ; in range
    ret

;  Shared by all three expansions of DELTA, and therefore OUTSIDE the macro:
;  a label written inside one would be defined three times over.
proj_deltas_far:
    pop hl                              ; the point pointer the macro pushed
    or a                                ; CF clear -> clipped
    ret


; ----------------------------------------------------------------------------
;  proj_scale -- one world delta down into the camera cube, at the zoom in force
;  In : HL = a signed 16-bit world delta
;  Out: CF set   -> A = the camera-space component, -128..127
;       CF clear -> out of range at this zoom; A is rubbish
;  Uses: AF, B, HL
;
;  THIS ROUTINE IS THE ZOOM. Everything else about the zoom -- the key handler,
;  the table, cam_dist -- is bookkeeping around these twenty instructions.
;
;  Two forms, chosen by the patch:
;
;      v = HL >> S           the plain step, radius 128 << S
;      v = 3 * (HL >> S)     the half step,  radius  42 << S
;
;  and S runs from 4 to 9 across the twelve steps.
;
;  IT HAS NO BRANCHES, and that is not showing off -- it is the only version
;  that fits. The obvious shape is a JR with a patched displacement jumping
;  into a ladder of shifts, and it was written that way first: three taken JRs
;  an axis, nine an entity, 108 T-states of pure "which rung", and proj_point
;  went from 4,760 T to 5,060 and over the budget guard. Patching the
;  INSTRUCTIONS instead of jumping over them costs nothing at all:
;
;    * the shift ladder is four `add hl,hl` (multiply up, then take H, which
;      is a shift RIGHT by 8 - n), each patched to NOP when not wanted;
;    * the range check's `add a,bias : cp limit` becomes `and 0 : cp 1`, which
;      passes everything, on the three steps that do not need one;
;    * the tail is `scf : ret`, patched to `jr` into the x3 code -- two bytes
;      either way, so the plain steps do not even step over it;
;    * and `>>9`, which the ladder cannot reach, is one `sra a` after H is
;      taken, patched to two NOPs otherwise. (x>>8)>>1 is x>>9 for arithmetic
;      shifts, so it costs no accuracy.
;
;  order_apply_zoom LDIRs those four runs out of cam_zoom_table, which
;  tools/gentables.py derives from the shift alone. The bytes below are the
;  NEUTRAL step assembled in place, so the routine is correct before anything
;  has pressed a key.
;
;  The range check is EXACT rather than conservative, which matters because the
;  Python model has to reject exactly what this does. `h + 2^(S-1) < 2^S` is
;  HL within +/-2^(S+7), and 2^(S+7) is a whole number of 256s, so testing the
;  high byte alone loses nothing. For the plain form that IS "v fits a signed
;  byte". For the x3 form it only says the ladder will not overflow, and the
;  real test is the one on v itself in the tail.
; ----------------------------------------------------------------------------
proj_scale:
    ld a,h
proj_zoom_check:
    add a,PROJ_V_BIAS                   ; patched to `and 0` when unwanted
    cp PROJ_V_BIAS * 2                  ; ...and this immediate to 1
    ret nc                              ; CF clear -> out of range

proj_zoom_shl:
    add hl,hl                           ; the neutral step is >>6, so two of
    add hl,hl                           ; these...
    nop                                 ; ...and two of these
    nop

    ld a,h                              ; A = HL >> S
proj_zoom_shr:
    nop                                 ; `sra a` on the one step that is >>9
    nop

proj_zoom_mul:
    scf                                 ; patched to `jr @proj_sc_x3` for the
    ret                                 ; half steps -- two bytes either way

@proj_sc_x3:
    ld b,a
    add a,42                            ; 3*43 is 129, so 42 is the last one in
    cp 85
    ret nc                              ; CF clear -> out of range
    ld a,b
    add a,a
    add a,b                             ; A = 3v
    scf
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
