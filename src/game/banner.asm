; ============================================================================
;  banner.asm -- a line across the middle of the view when the yard learns
; ============================================================================
;  "όταν πιάνεις την φρεγάτα στην πίστα 4, βγάλε ένα σχετικό μήνυμα στο κέντρο
;  της οθόνης για την νέα δυνατότητα. Αντίστοιχα με το destroyer."
;
;  The HUD's message row says YARD: FRIGATE, and the owner wanted it where the
;  eye is. So: one centred line in the playfield for BAN_TICKS, in the fleet's
;  ink, drawn every frame into the buffer being drawn and given to
;  phase4_add_rect -- so the next pass through that buffer erases it exactly as
;  it erases a ship, and when the ticks run out it is simply not drawn again.
;  Nothing here knows about buffers; the dirty list does.
;
;  The words are in bank 7 (ban_words in game/screentext.asm) and fetched a
;  frame at a time through bank7_fetch, which is legal from here by the
;  narrow rule: wave_draw runs with the window at rest. Called from the top of
;  wave_draw rather than from demo_update, because the low 16K had no room for
;  a call and wave_draw is bank 4 and already runs once a frame.
; ----------------------------------------------------------------------------

BAN_TICKS           equ 200             ; four seconds
BAN_Y               equ PROJ_CENTRE_Y - 4
BAN_H               equ TXT_CHAR_H
BAN_FRIGATE_X       equ 10              ; 30 characters, centred
BAN_DESTROYER_X     equ 8               ; 32

; ----------------------------------------------------------------------------
;  ban_say -- put message A (1 = frigate, 2 = destroyer) up for BAN_TICKS
;  Uses: AF
; ----------------------------------------------------------------------------
ban_say:
    ld (ban_msg),a
    ld a,(sys_tick_50hz)
    ld (ban_tick0),a
    ret


; ----------------------------------------------------------------------------
;  unlock_banner -- draw it if it is up, and take it down when its time is
;  Uses: everything
; ----------------------------------------------------------------------------
unlock_banner:
    ld a,(ban_msg)
    or a
    ret z
    ld a,(sys_tick_50hz)
    ld hl,ban_tick0
    sub (hl)                            ; the byte wrap is the right answer
    cp BAN_TICKS
    jr c,@ban_draw
    xor a
    ld (ban_msg),a                      ; ...and the dirty list erases the last one
    ret

@ban_draw:
    ld a,(ban_msg)
    dec a
    ld hl,ban_words
    call bank7_fetch
    ld a,(ban_msg)
    ld b,BAN_FRIGATE_X
    dec a
    jr z,@ban_x
    ld b,BAN_DESTROYER_X
@ban_x:
    ld hl,ban_rect
    ld (hl),b                           ; x in bytes
    inc hl
    ld (hl),BAN_Y
    inc hl
    ld a,SCR_BYTES_PER_LINE
    sub b
    sub b                               ; width: the line is centred, so 80 - 2x
    ld (hl),a
    inc hl
    ld (hl),BAN_H
    ld c,BAN_Y
    push bc
    ld hl,bank7_line
    call txt_draw
    pop bc
    ld hl,ban_rect
    jp phase4_add_rect
