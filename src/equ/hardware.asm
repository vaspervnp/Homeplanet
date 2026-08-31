; ============================================================================
;  hardware.asm -- Amstrad CPC 6128 hardware constants
; ============================================================================
;  Nothing here emits bytes. Equates only.
; ----------------------------------------------------------------------------

    ifndef HW_INCLUDED
HW_INCLUDED equ 1

; --- Gate Array (port #7Fxx) ------------------------------------------------
;  The GA latches the DATA byte, not the port address, so the classic idiom is
;  OUT (C),r with B=#7F and the payload in r.
GA_PORT             equ #7F

;  Function is selected by the top two bits of the payload:
;    %00xxxxxx  pen select      (0-15 = ink, 16 = border)
;    %01xxxxxx  colour select   (hardware colour 0-31)
;    %10xxxxxx  ROM/mode select
;    %11xxxxxx  RAM bank config (6128 only)
GA_PEN              equ %00000000
GA_COLOUR           equ %01000000
GA_ROMMODE          equ %10000000
GA_RAMCFG           equ %11000000

GA_PEN_BORDER       equ GA_PEN + 16

; ROM/mode payload bits
GA_MODE0            equ 0
GA_MODE1            equ 1
GA_MODE2            equ 2
GA_LOWER_ROM_OFF    equ %00000100       ; 1 = disable lower ROM (OS)  -> RAM at #0000
GA_UPPER_ROM_OFF    equ %00001000       ; 1 = disable upper ROM       -> RAM at #C000
GA_IRQ_RESET        equ %00010000       ; 1 = reset the 6-line IRQ counter

;  What we run the game with: Mode 1, both ROMs off, all 64K of base RAM ours.
GA_GAME_ROMMODE     equ GA_ROMMODE + GA_MODE1 + GA_LOWER_ROM_OFF + GA_UPPER_ROM_OFF

; --- RAM banking (6128 PAL, payload %11000nnn) ------------------------------
;  Slots are  #0000 / #4000 / #8000 / #C000.  Configs 4-7 drop extended bank
;  n into the #4000 window and leave the rest alone -- that is our sprite /
;  mission-data window.
;
;    #C0 -> 0 1 2 3   (power-on default)
;    #C4 -> 0 4 2 3
;    #C5 -> 0 5 2 3
;    #C6 -> 0 6 2 3
;    #C7 -> 0 7 2 3
GA_BANK_DEFAULT     equ GA_RAMCFG + 0
GA_BANK_4           equ GA_RAMCFG + 4
GA_BANK_5           equ GA_RAMCFG + 5
GA_BANK_6           equ GA_RAMCFG + 6
GA_BANK_7           equ GA_RAMCFG + 7

; --- CRTC 6845 (index #BCxx, data #BDxx) ------------------------------------
CRTC_INDEX          equ #BC
CRTC_DATA           equ #BD

CRTC_R12_START_HI   equ 12              ; bits 4-5 = 16K page, bits 0-1 = offset hi
CRTC_R13_START_LO   equ 13              ; offset low byte

;  R12 values that park the display on each of our two screen buffers.
;  bits 5-4:  00 -> #0000, 01 -> #4000, 10 -> #8000, 11 -> #C000
CRTC_PAGE_C000      equ #30
CRTC_PAGE_8000      equ #20

; --- PPI 8255 ---------------------------------------------------------------
PPI_PORT_A          equ #F4             ; PSG data
PPI_PORT_B          equ #F5             ; bit 0 = VSYNC, bit 4 = 50/60Hz, ...
PPI_PORT_C          equ #F6             ; PSG control + keyboard row select
PPI_CONTROL         equ #F7

PPI_B_VSYNC         equ %00000001

; --- uPD765 floppy controller -----------------------------------------------
;  Full 16-bit port addresses: these go in BC, so the high byte selects the
;  device and the low byte the register.
FDC_MOTOR           equ #FA7E           ; bit 0 = motor on
FDC_STATUS          equ #FB7E           ; main status register, read only
FDC_DATA            equ #FB7F           ; data register

;  Main status register bits worth naming.
FDC_ST_RQM          equ %10000000       ; the controller wants a byte moved
FDC_ST_DIO          equ %01000000       ; 1 = it has one FOR us, 0 = it wants one
FDC_ST_EXM          equ %00100000       ; an execution phase is under way
FDC_ST_CB           equ %00010000       ; a command is still in progress

;  DO NOT WAIT ON THIS ONE. Bit 0 is "FDD 0 is in the seek mode", and when it
;  is set and when it clears is the least portable thing the controller does:
;  the datasheet has it raised some microseconds AFTER the last command byte
;  lands -- so a poll on the instruction that follows reads zero and falls
;  through a seek that has not started -- and cleared by SENSE INTERRUPT
;  STATUS rather than by the head arriving, so a loop waiting for it to go out
;  waits for something only the code AFTER the loop can do. cpcemu has never
;  set it at all (there is a FIXME saying so in chips/upd765.h), which is why
;  a wait on it looked fine here for months. fdc_seek asks SENSE INTERRUPT
;  STATUS instead; see the comment there.
FDC_ST_BUSY0        equ %00000001       ; drive 0 is in the seek mode -- unused

;  Status register 0, as handed back by SENSE INTERRUPT STATUS.
FDC_ST0_SE          equ %00100000       ; seek end: the head is where we asked
FDC_ST0_NR          equ %00001000       ; not ready: no disc, or no drive

;  ST1's REAL faults. Bit 7 is EN, "end of cylinder", and it is NOT one of
;  them -- see fdc_transfer_ok. Bit 6 and bit 3 are unused.
FDC_ST1_MA          equ %00000001       ; missing address mark
FDC_ST1_ND          equ %00000100       ; no data: sector not found
FDC_ST1_OR          equ %00010000       ; overrun: we were too slow
FDC_ST1_DE          equ %00100000       ; data error: a CRC failed
FDC_ST1_REAL        equ FDC_ST1_MA + FDC_ST1_ND + FDC_ST1_OR + FDC_ST1_DE

FDC_CMD_READ        equ #46             ; READ DATA, MFM
FDC_CMD_WRITE       equ #45             ; WRITE DATA, MFM
FDC_CMD_SEEK        equ #0F
FDC_CMD_SENSE_INT   equ #08

; --- AY-3-8912 (driven through the PPI) -------------------------------------
PSG_INACTIVE        equ %00000000
PSG_READ            equ %01000000
PSG_WRITE           equ %10000000
PSG_SELECT          equ %11000000

; ============================================================================
;  Colours, as the byte you send to the gate array.
;
;  These are the #40-#5F "hardware ink" values -- GA_COLOUR is ALREADY folded
;  in, which is the same notation RetroTools prints in its export headers
;  ("hardware &4B"), so a palette copied out of the sprite editor drops
;  straight in here.
;
;  Sending the bare 0-31 index instead reads back as %00xxxxxx, which the gate
;  array interprets as a PEN SELECT -- the colour never changes and you are
;  left staring at the firmware palette wondering why.
;
;  The comment on each line is the firmware INK number you would use in BASIC.
; ============================================================================
HW_BLACK            equ #54             ; ink 0
HW_BLUE             equ #44             ; ink 1
HW_BRIGHT_BLUE      equ #55             ; ink 2
HW_RED              equ #5C             ; ink 3
HW_MAGENTA          equ #58             ; ink 4
HW_MAUVE            equ #5D             ; ink 5
HW_BRIGHT_RED       equ #4C             ; ink 6
HW_PURPLE           equ #45             ; ink 7
HW_BRIGHT_MAGENTA   equ #4D             ; ink 8
HW_GREEN            equ #56             ; ink 9
HW_CYAN             equ #46             ; ink 10
HW_SKY_BLUE         equ #57             ; ink 11
HW_YELLOW           equ #5E             ; ink 12
HW_WHITE            equ #40             ; ink 13
HW_PASTEL_BLUE      equ #5F             ; ink 14
HW_ORANGE           equ #4E             ; ink 15
HW_PINK             equ #47             ; ink 16
HW_PASTEL_MAGENTA   equ #4F             ; ink 17
HW_BRIGHT_GREEN     equ #52             ; ink 18
HW_SEA_GREEN        equ #42             ; ink 19
HW_BRIGHT_CYAN      equ #53             ; ink 20
HW_LIME             equ #5A             ; ink 21
HW_PASTEL_GREEN     equ #59             ; ink 22
HW_PASTEL_CYAN      equ #5B             ; ink 23
HW_BRIGHT_YELLOW    equ #4A             ; ink 24
HW_PASTEL_YELLOW    equ #43             ; ink 25
HW_BRIGHT_WHITE     equ #4B             ; ink 26

    endif
