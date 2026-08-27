; ============================================================================
;  gfx/line.asm -- the few primitives the move disc needs
; ============================================================================
;  Not a general line drawer. The move disc needs a vertical line and a small
;  cross, both of which are cheap and neither of which needs Bresenham; the
;  design budgets the whole disc at "about twenty pixels of drawing".
;
;  Everything here draws into the back buffer through scr_line_addr, so it
;  respects the CPC's interleave and the current buffer.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  gfx_pixel_setup -- work out where pixel (HL, A) lives
;  In : HL = x 0..319, A = y 0..199
;  Out: DE = the byte address, C = the pixel position 0..3
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
gfx_pixel_setup:
    push hl
    call scr_line_addr                  ; HL = the start of that line
    ex de,hl
    pop hl

    ld a,l
    and 3
    ld c,a                              ; which pixel within the byte

    ld a,h
    srl a
    rr l
    srl a
    rr l                                ; x >> 2, and x < 320 so A is now 0
    ld h,a
    add hl,de
    ex de,hl                            ; DE = the byte holding that pixel
    ret


; ----------------------------------------------------------------------------
;  gfx_vline -- a one-pixel-wide vertical line
;  In : HL = x 0..319, C = y of the top, B = how many lines, A = pen 0..3
;  Out: -
;  Uses: everything
;
;  Clipped against the tactical viewport, not the screen: the HUD strip below
;  spr_clip_bottom and the context bar above spr_clip_top are not ours to draw
;  on.
; ----------------------------------------------------------------------------
gfx_vline:
    ld (gfx_pen),a
    ld a,b
    or a
    ret z
    ld (gfx_rows),a
    ld a,c
    ld (gfx_y),a
    ld (gfx_x),hl

;  Both bounds, per row, and NOT hoisted out of the loop.
;
;  Hoisting was written first and is the obvious optimisation: clip the run
;  once, drop the test from the loop. It is a PESSIMISATION here, and the
;  arithmetic says so -- clipping the run costs about a hundred T-states
;  either way, and almost everything drawn through this is ONE row. The
;  reference plane is sixteen single-pixel dots, a resource patch is three
;  more, and only the move disc's stem is ever long. Break-even is three rows
;  and the frame is full of ones.
;
;  spr_clip_top is deliberately the byte after spr_clip_bottom so the second
;  bound is an INC HL rather than another LD HL,nn; src/main.asm asserts it.
@gfx_line_row:
    ld a,(gfx_y)
    ld hl,spr_clip_bottom
    cp (hl)
    jr nc,@gfx_line_next                ; at or below the HUD strip: not ours
    inc hl                              ; -> spr_clip_top, next door on purpose
    cp (hl)
    jr c,@gfx_line_next                 ; ...and above it is the context bar

    ld hl,(gfx_x)
    ld a,(gfx_y)
    call gfx_pixel_setup                ; DE = byte, C = pixel

    ld b,0
    ld hl,gfx_pen_mask
    ld a,(gfx_pen)
    add a,a
    add a,a                             ; four masks per pen
    add a,c
    ld c,a
    add hl,bc
    ld a,(de)
    or (hl)
    ld (de),a

@gfx_line_next:
    ld hl,gfx_y
    inc (hl)
    ld hl,gfx_rows
    dec (hl)
    jr nz,@gfx_line_row
    ret


; ----------------------------------------------------------------------------
;  gfx_cross -- a three-pixel-wide plus sign, the disc marker itself
;  In : HL = x 0..319, C = y, A = pen
;  Uses: everything
;
;  Deliberately tiny and deliberately not a filled shape: the disc has to be
;  readable on top of a ship without hiding it.
; ----------------------------------------------------------------------------
gfx_cross:
    ld (gfx_pen),a
    ld (gfx_cross_x),hl
    ld a,c
    ld (gfx_cross_y),a

    ;  the vertical stroke, three tall, centred
    dec a
    ld c,a
    ld b,3
    ld a,(gfx_pen)
    push af
    call gfx_vline
    pop af

    ;  the two side pixels
    ld (gfx_pen),a
    ld hl,(gfx_cross_x)
    dec hl
    ld a,(gfx_cross_y)
    ld c,a
    ld b,1
    ld a,(gfx_pen)
    push af
    call gfx_vline
    pop af

    ld (gfx_pen),a
    ld hl,(gfx_cross_x)
    inc hl
    ld a,(gfx_cross_y)
    ld c,a
    ld b,1
    ld a,(gfx_pen)
    jp gfx_vline


; ============================================================================
;  Data
; ============================================================================
gfx_pen:            defb 0
gfx_rows:           defb 0
gfx_y:              defb 0
gfx_x:              defw 0
gfx_cross_x:        defw 0
gfx_cross_y:        defb 0

;  OR-masks that set one pixel to one pen, indexed by pen*4 + position.
;  Mode 1 packs pixels A B C D as A0 B0 C0 D0 A1 B1 C1 D1, so pen bit 0 sits
;  at 7-p and pen bit 1 at 3-p.
gfx_pen_mask:
    defb #00, #00, #00, #00             ; pen 0 -- nothing to set
    defb #80, #40, #20, #10             ; pen 1
    defb #08, #04, #02, #01             ; pen 2
    defb #88, #44, #22, #11             ; pen 3
