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
;
;  ---------------------------------------------------------------------------
;  THE SCAN RUNS AT 50 Hz, FROM THE INTERRUPT. THE FRAME LOOP ONLY CONSUMES.
;
;  It used to be called once from demo_update, i.e. once per GAME frame -- and
;  the game does not reach 12.5 fps, it reaches about five. So the keyboard was
;  sampled every 200 ms, and a key that went down AND came back up between two
;  samples was never seen at all. Measured on the shipped build: a 40 ms press
;  registered twice in six tries, an 80 ms press four times in six. Half of
;  every ordinary keypress was thrown away, and the player's report was that
;  they had to hit a key several times before anything happened.
;
;  So sys_irq calls key_scan on its 50 Hz tick and nothing shorter than 20 ms
;  can fall between two samples. That splits the press edges in two:
;
;      key_edge   the ACCUMULATOR. The scan ORs new press edges into it and
;                 never clears it. Fifty writes a second, from the interrupt.
;      key_hits   the frame's SNAPSHOT, and the only thing key_hit reads.
;
;  key_consume moves the one into the other and zeroes the accumulator, once at
;  the top of a game frame, inside DI. Taking a copy rather than reading the
;  accumulator directly is the whole point: an edge that arrives in the middle
;  of a frame -- after the command that would have acted on it has already run
;  -- stays in key_edge and is picked up by the NEXT frame, instead of being
;  cleared unseen. Clearing at either end of the frame reintroduces exactly the
;  bug this is fixing, on a 200 ms window instead of a 20 ms one.
;
;  A key HELD across several frames still hits once and only once, because the
;  edge is computed against key_state, which the scan updates every tick: the
;  second tick of a held key sees it was already down and contributes nothing.
;  That property is what every command in the game depends on -- holding `d`
;  divides the squadron once, not once a frame.
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
KEY_I               equ 4*8 + 3         ; squadron info; same line 4 as O below
KEY_J               equ 5*8 + 5
KEY_M               equ 4*8 + 6
KEY_N               equ 5*8 + 6
KEY_O               equ 4*8 + 2         ; split by class; line 4 is 0 9 O I L K M ,
;  Tow: the Salvage Corvettes go and fetch the wrecks. Row 6 is 6 5 R T G F B V,
;  and T was the only unclaimed letter in the game with the right initial --
;  H already means "the harvesters go to work" and this is its sibling.
KEY_T               equ 6*8 + 3
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
;  The help key. `?` is SHIFT + `/`, and the matrix only ever reports the
;  physical key, so reading `/` catches it whether or not SHIFT is down --
;  and nothing else is bound to `/` for an unshifted press to collide with.
KEY_SLASH           equ 3*8 + 6
KEY_P               equ 3*8 + 3         ; pan; line 3 is  ^ - @ P ; : / .
;  Zoom, as a second pair beside Z and X. `-` is a key of its own; `+` is NOT
;  -- it is SHIFT + `;`, and since the matrix only ever reports the physical
;  key, reading `;` catches it whether or not SHIFT is down. Same trick as
;  KEY_SLASH above, and nothing else is bound to either for an unshifted press
;  to collide with.
KEY_MINUS           equ 3*8 + 1
KEY_PLUS            equ 3*8 + 4         ; the `;` key, which is what `+` is
KEY_R               equ 6*8 + 2
KEY_S               equ 7*8 + 4
KEY_ENTER           equ 2*8 + 2         ; the big RETURN, not the numeric one
KEY_SHIFT           equ 2*8 + 5


; ----------------------------------------------------------------------------
;  key_scan -- read the whole matrix. CALLED FROM THE INTERRUPT, at 50 Hz.
;
;  Out: key_state = what is held now (a 1 bit means DOWN)
;       key_edge |= what went down since the previous scan
;  Uses: AF and HL freely -- sys_irq has already saved those -- plus BC and DE,
;        which it saves and restores itself, exactly as snd_update does.
;
;  NO DI AND NO EI. It used to run from the main loop and bracket itself in
;  DI...EI, because the handshake is stateful -- it leaves the PPI
;  mid-reconfiguration for a few dozen microseconds, and snd_update drives the
;  same PSG through the same port A from the interrupt. Now that both of them
;  ARE the interrupt that problem is gone by construction: they run one after
;  the other, on the same tick, and nothing else in the game touches the PPI.
;  An EI here would hand the machine back mid-handshake and reintroduce it.
;
;  The resting state the two of them share is unchanged and still asserted at
;  both ends: port A OUTPUT, port C PSG_INACTIVE. sys_irq calls this one FIRST,
;  so snd_update's defensive control-word write is on the live path rather than
;  being insurance nobody exercises.
; ----------------------------------------------------------------------------
key_scan:
    push bc
    push de

    ; --- point the PSG at register 14 -------------------------------------
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_OUT
    out (c),c                           ; port A drives the PSG data bus
    ld bc,PPI_PORT_A * 256 + KEY_PSG_REG
    out (c),c                           ; put the register number on it
    ld bc,PPI_PORT_C * 256 + PSG_SELECT
    out (c),c                           ; BDIR+BC1: latch it as the address
    ld c,PSG_INACTIVE
    out (c),c                           ; and release the bus (B is still #F6)

    ; --- walk the ten rows, folding the edge in as we go ------------------
    ;  The raw byte used to be parked in key_edge and turned into edges by a
    ;  second ten-iteration loop. It cannot be any more -- key_edge is an
    ;  accumulator now and must not be scribbled on -- and doing it here is
    ;  both smaller and about 200 T-states cheaper, which matters when it is
    ;  fifty times a second instead of five.
    ld bc,PPI_CONTROL * 256 + KEY_PPI_A_IN
    out (c),c                           ; port A now reads back from the PSG
    ld hl,key_state
    ld de,key_edge
    ld bc,PPI_PORT_C * 256 + PSG_READ   ; C = read function | row number
@key_row:
    out (c),c                           ; select the row
    ld b,PPI_PORT_A
    in a,(c)                            ; its eight columns, 0 = down
    cpl                                 ; -> 1 = down NOW
    ld b,a                              ; B is free until the next port write
    xor (hl)                            ; bits that changed since the last scan
    and b                               ; ...and are down now: the press edges
    ld (hl),b                           ; held state := down now
    ex de,hl
    or (hl)                             ; ACCUMULATE. The frame loop clears it,
    ld (hl),a                           ; not us -- see key_consume.
    inc hl
    ex de,hl
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

    pop de
    pop bc
    ret


; ----------------------------------------------------------------------------
;  key_consume -- take this frame's press edges off the interrupt
;
;  In : -
;  Out: key_hits = every edge accumulated since the last call; key_edge zeroed
;  Uses: AF, BC, DE, HL
;
;  It also SEEDS THE GAME'S RANDOM GENERATOR, once, on the first key of the
;  run. This is the one place that already knows a key went down, and
;  sys_tick_50hz at the moment a human presses one is worth most of eight bits
;  for the cost of a load -- see sys/rand.asm for why that has to happen
;  exactly once and how the tests pin the result.
;
;  Called ONCE, at the top of demo_update, before anything reads key_hit. Runs
;  from the main loop with interrupts on and ends with EI unconditionally --
;  the same shape key_scan itself used to have, and for the same reason: the
;  read and the clear of each row have to be one operation, or a scan landing
;  between them loses the edge it just recorded.
;
;  Snapshot rather than "read key_edge and clear it afterwards": an edge that
;  arrives half way through a frame belongs to the NEXT frame, and clearing at
;  the end of this one would throw it away unseen.
; ----------------------------------------------------------------------------
key_consume:
    di
    ld hl,key_edge
    ld de,key_hits
    ld b,KEY_ROWS
    ld c,0                              ; every edge byte, ORed together
@key_take:
    ld a,(hl)
    ld (hl),0
    ld (de),a
    or c
    ld c,a
    inc hl
    inc de
    djnz @key_take
    ei
    ld a,c
    or a
    ret z
    jp sys_rand_stir                    ; does nothing after the first press


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
;  key_hit -- was this key pressed since the last key_consume?
;
;  Edge-triggered, which is what the squadron commands want: holding `d` must
;  split once, not once per frame. key_consume replaces the whole array at the
;  top of the next frame, so a hit is readable for exactly one frame -- and
;  only one caller should act on it. Read it once, act on it there.
;
;  It reads key_hits, NOT key_edge: key_edge is the interrupt's accumulator and
;  is being written fifty times a second behind this routine's back.
;  In : A = key id
;  Out: CF set = newly pressed
;  Uses: AF, HL
; ----------------------------------------------------------------------------
key_hit:
    ld hl,key_hits
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
;  One byte per matrix row, indexed by id >> 3. All three are stored INVERTED
;  with respect to the hardware -- a 1 bit means down -- so key_bit is a rotate
;  with no CPL in front of it, and so a cleared array is the correct "nothing
;  pressed" starting state.
;
;  Which of the two edge arrays to touch is decided by which side of the
;  interrupt you are on. key_scan owns key_edge; everything else -- key_hit,
;  key_clear, key_inject -- works on key_hits.
key_state:          defs KEY_ROWS, 0    ; held now, as of the last 50 Hz scan
key_edge:           defs KEY_ROWS, 0    ; edges accumulated since key_consume
key_hits:           defs KEY_ROWS, 0    ; this frame's snapshot of key_edge

;  Digit '0' to '9', in numeric order. Indexed by key_digit.
key_digit_ids:
    defb KEY_0, KEY_1, KEY_2, KEY_3, KEY_4
    defb KEY_5, KEY_6, KEY_7, KEY_8, KEY_9

