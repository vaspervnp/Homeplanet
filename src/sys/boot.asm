; ============================================================================
;  boot.asm -- take the machine away from the firmware
; ============================================================================
;  On entry we are running from #0040 with AMSDOS still alive. By the time
;  sys_boot returns, the firmware is gone for good: both ROMs disabled, our
;  own IM 1 handler installed, Mode 1 up, palette set, both screens black.
;
;  Nothing here may be called again later -- it is one-way.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  sys_boot
;  In : -
;  Out: interrupts enabled, display on SCREEN_A, back buffer = SCREEN_B
;  Uses: everything
; ----------------------------------------------------------------------------
;  NOTE: the stack is set up by game_main BEFORE this is called. Doing it here
;  would drop the return address that CALL just pushed, and sys_boot would RET
;  into whatever happened to be sitting at the top of the new stack.
sys_boot:
    di

    ; --- our IM 1 handler -------------------------------------------------
    ;  Writes always land in RAM on the CPC (ROM is a read-only overlay), so
    ;  this is safe to do while the lower ROM is still switched in.
    ld a,#C3                            ; JP nn
    ld (IRQ_VECTOR),a
    ld hl,sys_irq
    ld (IRQ_VECTOR+1),hl
    im 1

    ; --- firmware off, Mode 1 on ------------------------------------------
    ld bc,GA_PORT * 256 + GA_GAME_ROMMODE
    out (c),c

    ; --- RAM configuration ------------------------------------------------
    ;  Bank 4 stays in the #4000 window for the whole run: it holds the sprite
    ;  library, which src/disc.asm put there at load time. Selecting the
    ;  power-on layout here instead would page it straight back out and every
    ;  sprite would draw from whatever BASIC left in bank 1.
    ld bc,GA_PORT * 256 + GA_BANK_4
    out (c),c

    call scr_set_palette
    call scr_init_crtc

    ; Both buffers start black so the first flip cannot show garbage.
    ld hl,SCREEN_A
    call scr_clear_buffer
    ld hl,SCREEN_B
    call scr_clear_buffer

    ei
    ret
