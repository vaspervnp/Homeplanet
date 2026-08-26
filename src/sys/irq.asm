; ============================================================================
;  irq.asm -- IM 1 handler
; ============================================================================
;  The gate array raises an interrupt 300 times a second (once every 52
;  scanlines). We count them down 6 at a time to get a 50 Hz tick, which is
;  what the sound player, the keyboard and the game clock run on.
;
;  Contract: this runs behind the main loop's back, so it saves AF and HL and
;  may touch nothing else. Anything it CALLS that wants more registers saves
;  them itself -- snd_update and key_scan both push BC and DE. That costs 42
;  T-states of the ~6,000 the 50 Hz tick spends, and it keeps the contract in
;  one place instead of making the handler guess what its callees want.
;
;  The 50 Hz tick is ~6,000 T of the 13,333 between two interrupts, so it
;  cannot run into the next one.
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

    ;  The keyboard, at 50 Hz. This is the ONLY place it is scanned: called
    ;  once a game frame from the main loop, as it used to be, the game samples
    ;  the matrix every 200 ms and drops about half of all ordinary keypresses
    ;  on the floor. See the header of sys/keyboard.asm.
    ;
    ;  It goes BEFORE snd_update deliberately. Both drive the PSG through PPI
    ;  port A and both leave it in the resting state; putting the scan first
    ;  means snd_update's "assert the direction rather than trust it" write is
    ;  doing real work on the shipped path, not sitting there as insurance no
    ;  test can provoke.
    call key_scan

    ;  One AY frame per 50 Hz tick. snd_update saves everything beyond AF and
    ;  HL itself -- see its header, and the PPI contract it shares with
    ;  key_scan.
    call snd_update

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
