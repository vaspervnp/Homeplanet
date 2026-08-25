; ============================================================================
;  sys/keyboard.asm -- keyboard matrix scanning
; ============================================================================
;  The firmware is gone, so there is no KM READ KEY. This talks to the PPI and
;  the PSG directly.
;
;  The CPC keyboard is a 10 x 8 matrix. The row is selected by PPI port C bits
;  0-3 (through a 74LS145 BCD decoder) and the eight columns of that row come
;  back on PSG port A, which is only reachable by asking the PSG to read its
;  register 14 -- so a scan is a little dance across two chips. A bit reads 0
;  when the key is DOWN.
;
;  The awkward part is the PPI direction. Port A is the bidirectional data bus
;  between the PPI and the PSG: it has to be an OUTPUT to hand the PSG a
;  register number, and an INPUT to read the columns back. Both directions come
;  from one PPI control word, so key_scan writes #82 (A out) to set the PSG up
;  and #92 (A in) before the row loop. Forget the #92 and every row reads back
;  whatever the PPI last latched on port A -- in practice #FF, a keyboard where
;  nothing is ever pressed and nothing in the source looks wrong.
; ----------------------------------------------------------------------------

KEY_ROWS            equ 10

;  PPI 8255 control words. Bit 7 = 1 marks a mode-set; the rest is
;  mode 0 / port A direction / port B input / port C output.
;  These belong in equ/hardware.asm the day anything else needs them.
KEY_PPI_A_OUT       equ %10000010       ; A output, B input,  C output
KEY_PPI_A_IN        equ %10010010       ; A INPUT,  B input,  C output

;  PSG register 14 is port A of the AY-3-8912, wired to the keyboard columns.
KEY_PSG_REG         equ 14

; ----------------------------------------------------------------------------
;  Logical key ids, encoded as (row << 3) | bit -- one byte that key_down
;  splits back into an index into key_state and a rotate count. The ids are
;  therefore sparse: they are matrix positions, not a dense enumeration.
;
;  The matrix, as the hardware wires it (row = the value in port C bits 0-3):
;
;         bit 0    bit 1    bit 2    bit 3    bit 4    bit 5    bit 6    bit 7
;    0    CUR UP   CUR RT   CUR DN   f9       f6       f3      ENTER     f.
;    1    CUR LT   COPY     f7       f8       f5       f1       f2       f0
;    2    CLR      [        RETURN   ]        f4       SHIFT    \        CTRL
;    3    ^        -        @        P        ;        :        /        .
;    4    0        9        O        I        L        K        M        ,
;    5    8        7        U        Y        H        J        N        SPACE
;    6    6        5        R        T        G        F        B        V
;    7    4        3        E        W        S        D        C        X
;    8    1        2        ESC      Q        TAB      A        CAPSLOCK Z
;    9    joystick 0 / DEL (bit 7)
;
;  Note the digits are not in row order: 1 and 2 sit down in row 8 while 0 and
;  9 are up in row 4. Deriving an id by arithmetic from the digit will pick the
;  wrong key; the table below is the only source of truth.
; ----------------------------------------------------------------------------
KEY_1               equ 8*8 + 0
KEY_2               equ 8*8 + 1
KEY_3               equ 7*8 + 1
KEY_4               equ 7*8 + 0
KEY_5               equ 6*8 + 1
KEY_6               equ 6*8 + 0
KEY_7               equ 5*8 + 1
KEY_8               equ 5*8 + 0
KEY_9               equ 4*8 + 1
KEY_0               equ 4*8 + 0

KEY_A               equ 8*8 + 5
KEY_B               equ 6*8 + 6
KEY_C               equ 7*8 + 6
KEY_D               equ 7*8 + 5
KEY_F               equ 6*8 + 5
KEY_G               equ 6*8 + 4
KEY_H               equ 5*8 + 4
KEY_J               equ 5*8 + 5
KEY_M               equ 4*8 + 6
KEY_N               equ 5*8 + 6
KEY_X               equ 7*8 + 7
KEY_Z               equ 8*8 + 7

;  Cursor keys are KEY_CUR_*, not KEY_UP/KEY_DOWN: RASM is case-insensitive,
;  so a KEY_DOWN equate and the key_down routine below would be the same
;  symbol and the build would fail with a duplicate alias.
KEY_CUR_UP          equ 0*8 + 0
KEY_CUR_RIGHT       equ 0*8 + 1
KEY_CUR_DOWN        equ 0*8 + 2
KEY_CUR_LEFT        equ 1*8 + 0

KEY_SPACE           equ 5*8 + 7
KEY_TAB             equ 8*8 + 4
KEY_ESC             equ 8*8 + 2
KEY_COMMA           equ 4*8 + 7
KEY_PERIOD          equ 3*8 + 7
KEY_R               equ 6*8 + 2
KEY_S               equ 7*8 + 4
KEY_ENTER           equ 2*8 + 2         ; the big RETURN, not the numeric one
KEY_SHIFT           equ 2*8 + 5


; ----------------------------------------------------------------------------
;  key_scan -- read the whole matrix, once per frame
;
;  Out: key_state = what is held now (a 1 bit means DOWN)
;       key_edge  = what went down since the previous scan
;  Uses: everything
;
;  Interrupts are off across the whole routine. Not for timing -- the PSG
;  latches and holds -- but because the handshake is stateful: it leaves the
;  PPI mid-reconfiguration for a few dozen microseconds, and phase 6 puts
;  snd_update in the IRQ, which drives the same PSG through the same port A.
;  An interrupt landing between the #92 and the row loop would come back to a
;  PPI pointing somewhere else entirely. It is one instruction to make that
;  impossible now rather than debug it later.
;
;  key_scan therefore expects to be called from the main loop, with interrupts
;  enabled: it ends with EI unconditionally.
; ----------------------------------------------------------------------------
key_scan:
    di

    ; --- point the PSG at register 14 -------------------------------------
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_OUT
    out (c),c                           ; port A drives the PSG data bus
    ld bc,PPI_PORT_A * 256 + KEY_PSG_REG
    out (c),c                           ; put the register number on it
    ld bc,PPI_PORT_C * 256 + PSG_SELECT
    out (c),c                           ; BDIR+BC1: latch it as the address
    ld c,PSG_INACTIVE
    out (c),c                           ; and release the bus (B is still #F6)

    ; --- walk the ten rows -------------------------------------------------
    ;  The raw scan lands in key_edge, which is scratch space until the loop
    ;  below turns it into edges in place. That saves a third 10-byte array
    ;  and, more usefully, a third pointer register in that loop.
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_IN
    out (c),c                           ; port A now reads back from the PSG
    ld hl,key_edge
    ld bc,PPI_PORT_C * 256 + PSG_READ   ; C = read function | row number
@key_row:
    out (c),c                           ; select the row
    ld b,PPI_PORT_A
    in a,(c)                            ; its eight columns, 0 = down
    ld (hl),a
    inc hl
    ld b,PPI_PORT_C
    inc c                               ; next row; the function bits are
    ld a,c                              ; in the top nibble and untouched
    and #0F
    cp KEY_ROWS
    jr c,@key_row

    ; --- put the PPI back the way the rest of the machine expects it ------
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_OUT
    out (c),c
    ld bc,PPI_PORT_C * 256 + PSG_INACTIVE
    out (c),c

    ; --- held state and press edges ---------------------------------------
    ;  key_state still holds the PREVIOUS frame at this point, which is what
    ;  makes the edge cheap:  pressed = down_now AND was_up = NOT(raw OR held).
    ld hl,key_state
    ld de,key_edge
    ld b,KEY_ROWS
@key_edges:
    ld a,(de)                           ; this frame, raw: a 1 bit is UP
    ld c,a
    or (hl)                             ; OR last frame's held bits (1 = down)
    cpl                                 ; -> 1 = down now and up before
    ld (de),a
    ld a,c
    cpl
    ld (hl),a                           ; held state := this frame, 1 = down
    inc hl
    inc de
    djnz @key_edges

    ei
    ret


; ----------------------------------------------------------------------------
;  key_down -- is this key held?
;  In : A = key id
;  Out: CF set = down
;  Uses: AF, HL
; ----------------------------------------------------------------------------
key_down:
    ld hl,key_state
    jr key_bit

; ----------------------------------------------------------------------------
;  key_hit -- was this key pressed since the last scan?
;
;  Edge-triggered, which is what the squadron commands want: holding `d` must
;  split once, not once per frame. key_scan clears the bit on the next scan,
;  so a hit is readable for exactly one frame and only one caller can act on
;  it -- read it once, act on it there.
;  In : A = key id
;  Out: CF set = newly pressed
;  Uses: AF, HL
; ----------------------------------------------------------------------------
key_hit:
    ld hl,key_edge
    ; fall through -- nothing may be inserted between here and key_bit

; ----------------------------------------------------------------------------
;  key_bit -- CF = bit (A and 7) of the byte at HL + (A >> 3)
;  In : A = key id, HL = base of a 10-byte matrix array
;  Out: CF set = bit is 1
;  Uses: AF, HL   -- nothing else, so the callers stay usable from inside
;                    loops that are already holding BC and DE.
;
;  The id has to be taken apart twice, so it goes on the stack rather than into
;  a register we promised not to touch.
; ----------------------------------------------------------------------------
key_bit:
    push af
    rrca
    rrca
    rrca
    and #1F                             ; row = id >> 3  (ids are all < 128)
    add a,l
    ld l,a
    jr nc,@key_bit_norow
    inc h
@key_bit_norow:
    ld a,(hl)
    ld h,a                              ; park the row byte; HL is done as a
    pop af                              ; pointer now
    and 7
    inc a                               ; n+1 rotates puts bit n in the carry
    ld l,a
    ld a,h
@key_bit_shift:
    rrca                                ; DEC does not touch CF, so the flag
    dec l                               ; survives to the RET
    jr nz,@key_bit_shift
    ret


; ----------------------------------------------------------------------------
;  key_digit -- key id of a digit key
;  In : A = 0..9, the digit
;  Out: A = its key id
;  Uses: AF, HL
;
;  The digits are scattered across four matrix rows in an order that is not the
;  numeric one (see the table above: 1 and 2 are in row 8, 3 and 4 in row 7, 0
;  and 9 up in row 4), so `KEY_1 + n` is NOT the id of digit n+1 -- it walks
;  into ESC, Q, TAB and A. Anything that loops over the squadron number keys
;  has to come through here:
;
;      ld a,c : inc a : call key_digit : call key_hit
; ----------------------------------------------------------------------------
key_digit:
    ld hl,key_digit_ids
    add a,l
    ld l,a
    jr nc,@key_digit_same_page
    inc h
@key_digit_same_page:
    ld a,(hl)
    ret


; ----------------------------------------------------------------------------
;  Data
; ----------------------------------------------------------------------------
;  One byte per matrix row, indexed by id >> 3. Both are stored INVERTED with
;  respect to the hardware -- a 1 bit means down -- so key_bit is a rotate with
;  no CPL in front of it, and so a cleared array is the correct "nothing
;  pressed" starting state.
key_state:          defs KEY_ROWS, 0    ; held now
key_edge:           defs KEY_ROWS, 0    ; went down at the last scan

;  Digit '0' to '9', in numeric order. Indexed by key_digit.
key_digit_ids:
    defb KEY_0, KEY_1, KEY_2, KEY_3, KEY_4
    defb KEY_5, KEY_6, KEY_7, KEY_8, KEY_9
