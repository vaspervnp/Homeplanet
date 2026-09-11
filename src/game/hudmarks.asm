; ============================================================================
;  game/hudmarks.asm -- the nine squadron marks, and their alarm, in BANK 5
; ============================================================================
;  The top strip's second line: a little line a squadron, HUD_SQ_MARK_STEP
;  bytes apart, HUD_SQ_MARK_W pixels wide -- a byte and half the next -- and
;  HUD_SQ_MARK_H lines tall -- blue for a
;  squadron with ships in it, white for an empty one, red for the selected
;  one (the owner's assignment) -- WITH ITS NUMBER IN BLACK inside it, in a
;  four-pixel-wide font: "οι γραμμές των squadron να έχουν μέσα τον αριθμό
;  με μαύρο από 1 ως 9, με μισού πλάτους γράμματα". A digit row is four bits;
;  both planes of the mark's byte are cleared where they are set, which is
;  the whole of the font engine.
;
;  AND THE ALARM: "να αναβοσβήνει η γραμμή του squadron που δέχεται επίθεση".
;  cbt_retaliate flags a squadron's byte in hud_alarm the frame one of its
;  ships is hit and restarts hud_alarm_left; while that runs hud_alarm_frame
;  redraws the marks into the back buffer every frame with the tick's phase
;  -- bit 4 of sys_tick_50hz, sixteen ticks on, sixteen off -- blanking the
;  flagged ones on the off phase. When it runs out the flags are cleared and
;  the strip marked dirty, so both buffers settle. The buffer on show is
;  always the one drawn last, so the blink needs no shadow.
;
;  IN BANK 5, like txt_big and through the same trampoline (bankn_call, A =
;  GA_BANK_5, IX = the routine), because bank 4 had eighteen bytes and the
;  low 16K's page was full; it calls scr_line_addr and scr_fill_rect and
;  reads and writes low-16K state, nothing more. The phase comes in E, since
;  the trampoline needs A. The room is the icons': the sheet's cells have a
;  blank top and bottom row by rule, so they are stored as fourteen rows.
; ----------------------------------------------------------------------------

HUD_ALARM_FRAMES    equ 24              ; ~3 s of blinking after the last hit

; ----------------------------------------------------------------------------
;  hud_marks -- draw the nine marks
;  In : E = the blink phase: nonzero draws every mark, zero blanks the ones
;       whose squadron is under attack
;  Uses: everything
; ----------------------------------------------------------------------------
hud_marks:
    ld a,e
    ld (hud_alarm_phase),a
    ld b,1                              ; the squadron
    ld c,HUD_SQ_MARK_X                  ; ...and its byte column
@hud_mark:
    push bc
    ld a,(hud_alarm_phase)
    or a
    jr nz,@hud_mark_lit
    ld hl,hud_alarm
    ld a,b
    add a,l
    ld l,a
    jr nc,@hud_mark_flag
    inc h
@hud_mark_flag:
    ld a,(hl)
    or a
    jr z,@hud_mark_lit
    xor a                               ; under attack, phase off: blank
    jr @hud_mark_pen
@hud_mark_lit:
    ld a,b
    ld hl,squad_sel
    cp (hl)
    ld a,SOLID_INK_3                    ; the selected one: red
    jr z,@hud_mark_pen
    ld hl,squad_count
    ld a,b
    add a,l
    ld l,a
    jr nc,@hud_mark_count
    inc h
@hud_mark_count:
    ld a,(hl)
    or a
    ld a,SOLID_INK_2                    ; ships in it: blue
    jr nz,@hud_mark_pen
    ld a,SOLID_INK_1                    ; empty: white
@hud_mark_pen:
    ld (hud_mark_pen),a
    ld a,c
    ld (hud_mark_x),a
    ;  The digit's rows: hud_digits + (b - 1) * HUD_SQ_MARK_H -- nine, the
    ;  first and last blank, so the mark is solid above and below the digit.
    ld a,b
    dec a
    ld l,a
    add a,a
    add a,a
    add a,a
    add a,l                             ; * 9
    ld e,a
    ld d,0
    ld hl,hud_digits
    add hl,de
    ex de,hl                            ; DE -> the digit's rows
    ld a,CTX_Y2
    ld (hud_mark_y),a
    ld b,HUD_SQ_MARK_H
@hud_mark_row:
    push bc
    ld a,(hud_mark_y)
    call scr_line_addr                  ; HL = the row's start; AF, HL only
    ld a,(hud_mark_x)
    ld c,a
    ld b,0
    add hl,bc                           ; + x
    ;  The mark is six pixels: a whole byte and the left half of the next.
    ;  The digit's four columns sit at pixels 1..4 -- three in the first
    ;  byte, one in the second -- so the row's nibble m is split m >> 1 and
    ;  m & 1, each cut out of both planes of the ink.
    ld a,(de)                           ; the digit's row, four bits
    inc de
    ld c,a
    srl a                               ; pixels 1..3 of the first byte
    ld b,a
    rrca
    rrca
    rrca
    rrca                                ; ...in the high nibble too
    or b                                ; both planes
    cpl                                 ; the digit is the black
    ld b,a
    ld a,(hud_mark_pen)
    and b
    ld (hl),a
    inc hl
    ld a,c
    and 1                               ; the digit's last column: pixel 4, the next byte's first
    jr z,@hud_mark_byte2
    ld a,#88
@hud_mark_byte2:
    cpl
    ld b,a
    ld a,(hud_mark_pen)
    and b
    and #CC                             ; ...and only the left two pixels of that byte
    ld (hl),a
    ld hl,hud_mark_y
    inc (hl)
    pop bc
    djnz @hud_mark_row
    pop bc
    inc c
    inc c                               ; HUD_SQ_MARK_STEP
    inc b
    ld a,b
    cp SQUAD_MAX + 1
    jp c,@hud_mark
    ret


; ----------------------------------------------------------------------------
;  hud_alarm_frame -- one frame of the squadron alarm
;  Uses: everything
; ----------------------------------------------------------------------------
hud_alarm_frame:
    ld a,(tut_active)
    or a
    ret nz                              ; the tutorial owns the line
    ld hl,hud_alarm_left
    ld a,(hl)
    or a
    ret z
    dec (hl)
    jr nz,@hud_alarm_on
    ld hl,hud_alarm
    ld b,SQUAD_MAX + 1
@hud_alarm_clear:
    ld (hl),0
    inc hl
    djnz @hud_alarm_clear
    ld a,2
    ld (phase4_hud_dirty),a             ; both buffers back to steady marks
    ret
@hud_alarm_on:
    ld a,(sys_tick_50hz)
    and #10
    ld e,a
    jp hud_marks


;  The digits 1..9, four pixels wide, HUD_SQ_MARK_H rows a digit: seven of
;  glyph with a blank row above and below, one nibble a row.
hud_digits:
    defb 0, %0010, %0110, %0010, %0010, %0010, %0010, %0111, 0    ; 1
    defb 0, %0110, %1001, %0001, %0010, %0100, %1000, %1111, 0    ; 2
    defb 0, %1110, %0001, %0110, %0001, %0001, %1001, %0110, 0    ; 3
    defb 0, %0010, %0110, %1010, %1111, %0010, %0010, %0010, 0    ; 4
    defb 0, %1111, %1000, %1110, %0001, %0001, %1001, %0110, 0    ; 5
    defb 0, %0110, %1000, %1110, %1001, %1001, %1001, %0110, 0    ; 6
    defb 0, %1111, %0001, %0010, %0010, %0100, %0100, %0100, 0    ; 7
    defb 0, %0110, %1001, %0110, %1001, %1001, %1001, %0110, 0    ; 8
    defb 0, %0110, %1001, %1001, %0111, %0001, %0001, %0110, 0    ; 9
hud_digits_end:
    assert hud_digits_end - hud_digits == SQUAD_MAX * HUD_SQ_MARK_H, "the digit font is not HUD_SQ_MARK_H rows a digit"

hud_mark_pen:       defb 0              ; the mark being drawn: its ink byte
hud_mark_x:         defb 0              ; ...its byte column
hud_mark_y:         defb 0              ; ...and the row
