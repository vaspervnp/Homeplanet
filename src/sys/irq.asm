; ============================================================================
;  irq.asm -- IM 1 handler
; ============================================================================
;  The gate array raises an interrupt 300 times a second (once every 52
;  scanlines). We count them down 6 at a time to get a 50 Hz tick, which is
;  what the sound player and the game clock run on.
;
;  Contract: this runs behind the main loop's back, so it may only touch
;  AF/AF' and HL', and it must leave the main registers untouched.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  sys_irq -- entered via JP at #0038
; ----------------------------------------------------------------------------
sys_irq:
    push af
    push hl

    ld hl,irq_divider
    dec (hl)
    jr nz,@not_50hz

    ld (hl),6
    ld hl,sys_tick_50hz                 ; free-running 50 Hz counter
    inc (hl)

    ; TODO(phase 6): call snd_update here -- one AY frame per 50 Hz tick.

@not_50hz:
    pop hl
    pop af
    ei
    reti


; ----------------------------------------------------------------------------
;  Data
; ----------------------------------------------------------------------------
irq_divider:
    defb 6

;  Incremented 50 times a second, wraps at 256. Read it, never write it.
sys_tick_50hz:
    defb 0
