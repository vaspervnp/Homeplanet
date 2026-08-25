; ============================================================================
;  screen.asm -- Mode 1 display, double buffering, rectangle fills
; ============================================================================
;  Two 16K buffers, A at #C000 and B at #8000. One is on screen, the other is
;  being drawn into; scr_flip swaps them by reprogramming CRTC R12.
;
;  The two bases differ in exactly one bit (#4000), which is why the line
;  table below stores plain OFFSETS and the base is merged in with OR rather
;  than ADD -- 4 T-states cheaper, 200 times a frame.
; ----------------------------------------------------------------------------

; ============================================================================
;  Initialisation
; ============================================================================

; ----------------------------------------------------------------------------
;  scr_set_palette -- load the four semantic inks plus the border
;  Uses: AF, BC, HL, DE
; ----------------------------------------------------------------------------
scr_set_palette:
    ld bc,GA_PORT * 256
    ld hl,scr_palette
    ld e,GA_PEN                         ; pen index, counts up 0..3
    ld d,4
@pen_loop:
    out (c),e                           ; select pen
    ld a,(hl)
    inc hl
    out (c),a                           ; set its hardware colour
    inc e
    dec d
    jr nz,@pen_loop

    ld a,GA_PEN_BORDER
    out (c),a
    ld a,(hl)
    out (c),a
    ret

; ----------------------------------------------------------------------------
;  scr_init_crtc -- park the display on buffer A with zero offset
;  Uses: AF, BC
; ----------------------------------------------------------------------------
scr_init_crtc:
    ld bc,CRTC_INDEX * 256 + CRTC_R13_START_LO
    out (c),c
    ld b,CRTC_DATA
    xor a
    out (c),a                           ; R13 = 0, always

    ld a,CRTC_PAGE_C000
    jp scr_set_page


; ============================================================================
;  Frame flow
; ============================================================================

; ----------------------------------------------------------------------------
;  scr_wait_vsync -- block until the START of the next vertical blank
;
;  Two phases on purpose: if we are already inside VSYNC when called, waiting
;  only for "vsync high" would return instantly and the flip would land mid
;  frame. So we wait it out first, then catch the rising edge.
;  Uses: AF, BC
; ----------------------------------------------------------------------------
scr_wait_vsync:
    ld b,PPI_PORT_B
@wait_low:
    in a,(c)
    rra                                 ; bit 0 -> carry
    jr c,@wait_low
@wait_high:
    in a,(c)
    rra
    jr nc,@wait_high
    ret

; ----------------------------------------------------------------------------
;  scr_flip -- swap front and back buffers and show the new front
;
;  Call this immediately after scr_wait_vsync. The CRTC latches R12 at the
;  start of the next frame, so the swap is never visible.
;  Uses: AF, BC, HL
; ----------------------------------------------------------------------------
scr_flip:
    ld hl,scr_front_page
    ld a,(hl)
    xor SCREEN_XOR / 256                ; #C0 <-> #80
    ld (hl),a
    inc hl                              ; -> scr_back_page
    ld b,a
    xor SCREEN_XOR / 256
    ld (hl),a

    ld a,b
    ; page #C0 -> R12 #30, page #80 -> R12 #20
    rrca
    rrca
    and #30
    ; fall through

; ----------------------------------------------------------------------------
;  scr_set_page -- A = CRTC R12 value
;  Uses: AF, BC
; ----------------------------------------------------------------------------
scr_set_page:
    ld bc,CRTC_INDEX * 256 + CRTC_R12_START_HI
    out (c),c
    ld b,CRTC_DATA
    out (c),a
    ret


; ============================================================================
;  Addressing
; ============================================================================

; ----------------------------------------------------------------------------
;  scr_line_addr -- address of column 0 of line A, in the BACK buffer
;  In : A = pixel line 0..199
;  Out: HL = address
;  Uses: AF, HL   -- and NOTHING else. Callers rely on that.
;
;  The two offset planes sit on consecutive pages, so the whole lookup is an
;  index into H:L and an `inc h` to cross to the other plane. Nothing here
;  needs a spare register pair, which is the point: this is called once per
;  scanline from the fill and blit loops, whose parameters live in BC/DE.
; ----------------------------------------------------------------------------
scr_line_addr:
    ld l,a
    ld h,scr_line_lo / 256
    ld a,(hl)                           ; offset low byte
    inc h                               ; -> scr_line_hi, same index
    ld h,(hl)                           ; offset high byte
    ld l,a
    ld a,(scr_back_page)
    or h                                ; base is #C0/#80, offset < #40: no carry
    ld h,a
    ret


; ============================================================================
;  Drawing
; ============================================================================

; ----------------------------------------------------------------------------
;  scr_clear_buffer -- blank a whole 16K buffer (boot only; ~344,000 T)
;  In : HL = buffer base
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
scr_clear_buffer:
    ld (hl),0
    ld d,h
    ld e,l
    inc de
    ld bc,SCREEN_SIZE - 1
    ldir
    ret

; ----------------------------------------------------------------------------
;  scr_fill_rect -- fill a byte-aligned rectangle in the back buffer
;  In : B  = x in BYTES (0..79)      -- 4 pixels each
;       C  = y in pixel lines (0..199)
;       D  = width in bytes
;       E  = height in lines
;       A  = fill byte (see SOLID_INK_* below)
;
;  Crosses the 8-line character-row boundary correctly by re-reading the line
;  table for every row -- 40 T per line, which is cheaper than tracking the
;  #800 wrap by hand and far harder to get wrong.
;  Uses: everything except IX/IY
; ----------------------------------------------------------------------------
scr_fill_rect:
    ld (@fill_byte),a
    ld a,e
    or a
    ret z
    ld a,d
    or a
    ret z

@row_loop:
    push bc                             ; B is the x column; djnz below eats it

    ld a,c
    call scr_line_addr                  ; HL = start of line C; DE survives
    ld a,b
    add a,l
    ld l,a
    jr nc,@no_carry
    inc h
@no_carry:

    ld b,d                              ; width in bytes
@fill_byte equ $+1
    ld a,#00                            ; patched above
@byte_loop:
    ld (hl),a
    inc hl
    djnz @byte_loop

    pop bc
    inc c                               ; next line
    dec e
    jr nz,@row_loop
    ret


; ============================================================================
;  Data
; ============================================================================

;  A whole byte of one pen, Mode 1. Bit layout for pixels A B C D is
;  A0 B0 C0 D0 A1 B1 C1 D1, so a solid pen n is just its two bit-planes
;  smeared across the nibbles.
SOLID_INK_0         equ #00
SOLID_INK_1         equ #F0
SOLID_INK_2         equ #0F
SOLID_INK_3         equ #FF

;  Hardware colours for the four semantic inks, then the border.
scr_palette:
    defb HW_BLACK                       ; ink 0 -- empty space
    defb HW_BRIGHT_WHITE                ; ink 1 -- friendly, HUD, text
    defb HW_SKY_BLUE                    ; ink 2 -- stars, grid, shading
    defb HW_BRIGHT_RED                  ; ink 3 -- enemies, explosions
    defb HW_BLACK                       ; border

;  High byte of each buffer's base address.
scr_front_page:
    defb SCREEN_A / 256
scr_back_page:
    defb SCREEN_B / 256
