; ============================================================================
;  sprscale.asm -- a tier C sprite drawn at twice or four times its size
;
;  "Γίνεται όταν είμαι σε V, τα κοντινότερα σκάφη να φαίνονται μεγαλύτερα; Με
;  scaling up των sprite;" Yes: a 24x16 block drawn with every pixel doubled
;  or quadrupled, 48x32 and 96x64, out of the same library, at blit time.
;  Another row of tiers would be ten kilobytes a class; this is under four
;  hundred bytes and no art.
;
;  IT LIVES IN THE SPRITE BANKS, THREE TIMES. A blitter runs with a library
;  under the window, so its code has to be in the low 16K or in that bank --
;  and the low 16K is seven bytes from a page boundary while bank 4 has two
;  hundred. So the routine below is a MACRO, expanded once at SPR_SCALE_ORG
;  in each of banks 5, 6 and 7 with {n} keeping the labels apart, and the
;  low 16K calls SPR_BLIT_X, the one address that holds it whichever bank is
;  in. Its working variables are in the bank beside it, for the same reason:
;  each copy has its own and only one copy ever runs.
;
;  THE DISPATCH IS HERE TOO, which is what keeps the low 16K's part of this
;  to six bytes: phase4_blit_body calls spr_blit_via, a vector that points
;  here, and the first thing here is to jump to spr_blit when there is no
;  scale. The scale rides in bits 6 and 5 of spr_enemy -- 01 x2, 10 x4 --
;  which phase4_blit_body fills from the visible-list entry; spr_blit only
;  ever tests bit 7 of that byte, so it never sees them. With no disc the
;  stand-ins are in bank 4, which has no copy of this, and
;  class_use_fallback points the vector at spr_blit instead.
;
;  HOW A MODE 1 BYTE DOUBLES. Four pixels a byte, plane 0 in the high nibble
;  and plane 1 in the low one, so pixel k is bits 7-k and 3-k. Doubling the
;  left pair (p0 p1 -> p0 p0 p1 p1) is keeping bits 7 6 3 2 and smearing
;  each one right by one; the right pair is the same after two rotates
;  bring bits 5 4 1 0 up. Quadrupling is rotating the pixel wanted up to
;  bits 7 and 3 and smearing each right by three. See ss_expand. The same
;  expansion serves the mask, which is a 2bpp pattern like the data.
;
;  A source row is expanded ONCE into a row buffer of (mask, data) pairs and
;  then written into each of the scale's screen rows with the blitter's own
;  seven-instruction unit; expanding per screen row would do the work of the
;  expansion twice or four times over. About 40,000 T-states for a x2 ship
;  and 150,000 for a x4 -- a quarter of a frame -- which is why the cockpit
;  draws at most PILOT_SPRITES ships and marks the rest.
;
;  Clipped to the playfield both ways, like spr_blit, with the same
;  rectangle recorded in spr_rect and CF set when something was drawn. The
;  seventh source byte -- the pre-shift's spill -- is not read: scaled
;  sprites are byte-aligned and use the pre-shift 0 block of their view.
; ============================================================================

SPR_SCALE_ORG       equ #7DC0
SPR_BLIT_X          equ SPR_SCALE_ORG
SPR_SCALE_SRC_W     equ 6               ; tier C is 24 pixels: six source bytes
SPR_SCALE_MAX       equ 4
SPR_XBUF_PAIRS      equ SPR_SCALE_SRC_W * SPR_SCALE_MAX

    macro SPR_SCALE_COPY n
    org SPR_SCALE_ORG
ss_blit{n}:
    ld a,(spr_enemy)
    and #60
    jp z,spr_blit                       ; unscaled: the ordinary blitter
    rlca
    rlca
    rlca                                ; 01 -> 1 (x2), 10 -> 2 (x4): the shift

    ; --- sizes ------------------------------------------------------------
    ld (ss_shift{n}),a
    ld b,a
    ld a,SPR_SCALE_SRC_W
ss_w_shl{n}:
    add a,a
    djnz ss_w_shl{n}
    ld (ss_outw{n}),a                   ; output bytes a row: 12 or 24
    add a,a                             ; ...times 2 pixels: the half width in pixels
    ld e,a
    ld d,0
    ld hl,(phase4_sx)
    or a
    sbc hl,de                           ; the left edge, pixels, signed
    sra h
    rr l
    sra h
    rr l                                ; ...in byte columns
    ld (ss_x0{n}),hl

    ld a,(ss_shift{n})
    ld b,a
    ld a,(spr_h)
ss_h_shl{n}:
    add a,a
    djnz ss_h_shl{n}
    ld (ss_h{n}),a                      ; output rows: 32 or 64
    srl a
    ld e,a
    ld d,0
    ld a,(phase4_sy)
    ld l,a
    ld h,0
    or a
    sbc hl,de
    ld (ss_top{n}),hl                   ; the top row, signed

    ;  The source block: this view at pre-shift 0.
    ld hl,(phase4_base)
    ld a,(phase4_view)
    add a,a
    jr z,ss_src_ok{n}
    ld b,a
    ld de,(phase4_blocksz)
ss_src_step{n}:
    add hl,de
    djnz ss_src_step{n}
ss_src_ok{n}:
    ld (ss_src{n}),hl

    ; --- vertical clip ------------------------------------------------------
    ;  y0 = max(top, clip_top), y1 = min(top + h, clip_bottom); nothing if
    ;  y1 <= y0. Signed 16-bit compares, because top can be negative.
    ld hl,(ss_top{n})
    ld a,(spr_clip_top)
    ld e,a
    ld d,0
    push hl
    or a
    sbc hl,de
    pop hl
    jp p,ss_y0_is_top{n}
    ld a,e                              ; top is above the viewport
    jr ss_y0_done{n}
ss_y0_is_top{n}:
    ld a,l
ss_y0_done{n}:
    ld (ss_y{n}),a                      ; y0
    ld hl,(ss_top{n})
    ld a,(ss_h{n})
    ld e,a
    ld d,0
    add hl,de                           ; the row after the last, signed
    bit 7,h
    jr nz,ss_reject{n}                  ; wholly above the screen
    ld a,(spr_clip_bottom)
    ld e,a
    push hl
    or a
    sbc hl,de
    pop hl
    jp m,ss_y1_is_bottom{n}
    ld a,e                              ; past the viewport: clip_bottom
    jr ss_y1_done{n}
ss_y1_is_bottom{n}:
    ld a,h
    or a
    jr nz,ss_reject{n}                  ; 256 or more: cannot be, but cannot fit a byte
    ld a,l
ss_y1_done{n}:
    ld hl,ss_y{n}
    sub (hl)                            ; rows = y1 - y0
    jr z,ss_reject{n}
    jr c,ss_reject{n}
    ld (ss_rows{n}),a
    ld (spr_rect + 3),a
    ld a,(hl)
    ld (spr_rect + 1),a
    jr ss_clip_h{n}
ss_reject{n}:                           ; here, in reach of the JRs either side
    or a
    ret
ss_clip_h{n}:

    ; --- horizontal clip ----------------------------------------------------
    ;  j0 = columns of the row buffer skipped on the left, xs = the screen
    ;  column the row starts at, n = bytes a row. |x0| is under 256.
    ld hl,(ss_x0{n})
    xor a
    ld (ss_j0{n}),a
    bit 7,h
    jr z,ss_x_inside{n}
    ld a,l
    neg                                 ; columns off the left
    ld c,a
    ld a,(ss_outw{n})
    cp c
    jr z,ss_reject{n}
    jr c,ss_reject{n}                   ; all of it off the left
    ld a,c
    ld (ss_j0{n}),a
    ld l,0                              ; xs = 0
ss_x_inside{n}:
    ld a,l
    cp SCR_BYTES_PER_LINE
    jr nc,ss_reject{n}                  ; off the right
    ld (ss_xs{n}),a
    ld (spr_rect + 0),a
    ld c,a
    ld a,(ss_outw{n})
    ld hl,ss_j0{n}
    sub (hl)                            ; bytes left after the skip
    ld b,a
    ld a,SCR_BYTES_PER_LINE
    sub c                               ; bytes to the right edge
    cp b
    jr c,ss_n_ok{n}
    ld a,b
ss_n_ok{n}:
    ld (ss_n{n}),a
    ld (spr_rect + 2),a

    ; --- the rows -----------------------------------------------------------
    ld a,#FF
    ld (ss_last{n}),a                   ; no source row expanded yet
ss_row{n}:
    ld a,(ss_y{n})
    ld hl,(ss_top{n})
    sub l                               ; y - top, 0..255 -- exact modulo 256
    ld hl,ss_shift{n}
    ld b,(hl)
ss_srcrow_shr{n}:
    srl a
    djnz ss_srcrow_shr{n}               ; the source row this screen row copies
    ld hl,ss_last{n}
    cp (hl)
    jr z,ss_rmw{n}                      ; already in the buffer
    ld (hl),a
    ;  rowptr = src + srcrow * (spr_w * 2): 14 a row, as 16a - 2a.
    ld l,a
    ld h,0
    add hl,hl
    ld e,l
    ld d,h                              ; DE = 2a
    add hl,hl
    add hl,hl
    add hl,hl                           ; HL = 16a
    or a
    sbc hl,de
    ld de,(ss_src{n})
    add hl,de
    ld (ss_rowptr{n}),hl
    call ss_fill{n}
ss_rmw{n}:
    ld a,(ss_y{n})
    call scr_line_addr                  ; HL = the line, back buffer
    ld a,(ss_xs{n})
    add a,l
    ld l,a
    jr nc,ss_no_carry{n}
    inc h
ss_no_carry{n}:
    ex de,hl                            ; DE = screen
    ld a,(ss_j0{n})
    add a,a
    ld hl,ss_buf{n}
    add a,l
    ld l,a
    jr nc,ss_buf_ok{n}
    inc h
ss_buf_ok{n}:
    ld a,(ss_n{n})
    ld b,a
ss_unit{n}:
    ld a,(de)
    and (hl)
    inc hl
    or (hl)
    inc hl
    ld (de),a
    inc de
    djnz ss_unit{n}
    ld hl,ss_y{n}
    inc (hl)
    ld hl,ss_rows{n}
    dec (hl)
    jr nz,ss_row{n}
    scf
    ret

; ----------------------------------------------------------------------------
;  ss_fill -- expand the source row at ss_rowptr into ss_buf
;  Uses: everything
;
;  Per SOURCE byte, not per output byte: the pair is read once and its
;  2 or 4 output pairs written straight through HL, which is the buffer
;  cursor for the whole row. The first version indexed the source afresh
;  for every output byte through memory pointers and cost some 600
;  T-states an output pair -- most of a x4 ship. A wholly transparent
;  source byte (mask #FF, data 0) is the common case in a sprite's box
;  and is written out without expanding anything.
; ----------------------------------------------------------------------------
ss_fill{n}:
    ld hl,ss_buf{n}
    ld a,SPR_SCALE_SRC_W
    ld (ss_j{n}),a                      ; source bytes left in the row
    ld a,(ss_shift{n})
    ld b,a
    ld a,1
ss_scale_shl{n}:
    add a,a
    djnz ss_scale_shl{n}
    ld (ss_scale{n}),a                  ; the factor: output pairs a source byte
ss_fill_src{n}:
    ld de,(ss_rowptr{n})
    ld a,(de)
    ld (ss_mb{n}),a
    inc de
    ld a,(de)
    ld (ss_db{n}),a
    inc de
    ld (ss_rowptr{n}),de
    ld a,(ss_mb{n})
    inc a                               ; #FF: nothing of this byte is drawn
    jr nz,ss_fill_slow{n}
    ld a,(ss_db{n})
    or a
    jr nz,ss_fill_slow{n}
    ld a,(ss_scale{n})
    ld b,a
ss_fill_clear{n}:
    ld (hl),#FF
    inc hl
    ld (hl),0
    inc hl
    djnz ss_fill_clear{n}
    jr ss_fill_next{n}
ss_fill_slow{n}:
    ld c,0                              ; k: which output pair of this byte
ss_fill_k{n}:
    ld a,(ss_mb{n})
    call ss_expand{n}                   ; reads C, keeps C and HL
    ld (hl),a
    inc hl
    ld a,(ss_db{n})
    call ss_expand{n}
    ld e,a
    ld a,(spr_enemy)
    and #80
    ld a,e
    jr z,ss_data_ours{n}
    rrca
    rrca
    rrca
    rrca
    and #0F
    or e                                ; pen 1 becomes pen 3
ss_data_ours{n}:
    ld (hl),a
    inc hl
    inc c
    ld a,(ss_scale{n})
    cp c
    jr nz,ss_fill_k{n}
ss_fill_next{n}:
    ld a,(ss_j{n})
    dec a
    ld (ss_j{n}),a
    jr nz,ss_fill_src{n}
    ret

; ----------------------------------------------------------------------------
;  ss_expand -- A = source byte A expanded for its output byte C
;  In : A = a Mode 1 byte, C = k (which of the source byte's outputs),
;       ss_shift = 1 or 2
;  Out: A = the output byte
;  Uses: AF, DE -- C and HL are preserved
;
;  No table: a Mode 1 pixel is one bit in each nibble, so doubling is
;  "keep bits 7 6 3 2 and smear each one right by one" and quadrupling is
;  "keep bits 7 and 3 of the pixel rotated to the top and smear each right
;  by three". x2 picks the left or right pair by bit 0 of j; x4 picks the
;  pixel by the two low bits of j. About 50 T-states a byte either way,
;  against some 200 for the table lookups this replaced, which were most
;  of a x4 ship's cost.
; ----------------------------------------------------------------------------
ss_expand{n}:
    ld e,a
    ld a,(ss_shift{n})
    cp 2
    jr z,ss_exp4{n}
    ;  x2: p0 p1 -> p0 p0 p1 p1, of the left pair or the right.
    ld a,e
    bit 0,c
    jr z,ss_exp2_pair{n}
    rlca
    rlca                                ; the right pair up to bits 7 6 3 2
ss_exp2_pair{n}:
    and #CC
    ld d,a
    and #88                             ; p0, both planes
    ld e,a
    rrca
    or e                                ; p0 in bits 7 6 and 3 2
    ld e,a
    ld a,d
    and #44                             ; p1, both planes
    rrca
    ld d,a
    rrca
    or d                                ; p1 in bits 5 4 and 1 0
    or e
    ret
ss_exp4{n}:
    ;  x4: pixel j & 3 in all four places.
    ld a,c
    and 3
    ld d,a
    ld a,e
    jr z,ss_exp4_up{n}
ss_exp4_rot{n}:
    rlca                                ; the pixel up to bits 7 and 3
    dec d
    jr nz,ss_exp4_rot{n}
ss_exp4_up{n}:
    and #88
    ld e,a
    rrca
    or e
    ld e,a
    rrca
    rrca
    or e
    ret

ss_shift{n}:        defb 0
ss_outw{n}:         defb 0
ss_h{n}:            defb 0
ss_x0{n}:           defw 0
ss_top{n}:          defw 0
ss_src{n}:          defw 0
ss_rowptr{n}:       defw 0
ss_y{n}:            defb 0
ss_rows{n}:         defb 0
ss_xs{n}:           defb 0
ss_n{n}:            defb 0
ss_j0{n}:           defb 0
ss_j{n}:            defb 0
ss_last{n}:         defb 0
ss_scale{n}:        defb 0
ss_mb{n}:           defb 0
ss_db{n}:           defb 0
ss_buf{n}:          defs SPR_XBUF_PAIRS * 2
ss_end{n}:
    assert ss_end{n} <= BANK_WINDOW + BANK_WINDOW_SIZE, "the scaled blitter runs off the end of the bank"
    mend
