; ============================================================================
;  game/textpack.asm -- bank7_fetch's BODY, in bank 7, and the 5-bit decoder
; ============================================================================
;  bank7_fetch (sys/libload.asm) used to skip and copy the string itself, in
;  the low 16K, with the paging round it. The paging is the only part that
;  HAS to be down there -- the OUT must happen with the CPU already out of
;  bank 4 -- so it is a six-instruction trampoline now and the walk lives
;  here, in the bank the words are in. Legal for the reason the chase is:
;  this calls nothing in bank 4 and reads nothing there, and bank7_line is
;  in the low 16K.
;
;  WHY: the briefings are PACKED, five bits a character (tools/packtext.py
;  is the format), and the decoder wants to sit beside them. Sixty lines of
;  capitals, spaces and stops were 1862 bytes of a bank that was full to the
;  byte; packed they are about 1220, and the six hundred bytes between are
;  what the cockpit's scanner (game/scanner.asm) runs in. The low 16K got
;  thirty bytes back in the same move.
;
;  A packed table begins with TEXT_PACKED, #FF, which no raw string begins
;  with, so the body tells the two kinds apart by one byte and every caller
;  of bank7_fetch is unchanged: the same HL and A in, the same string in
;  bank7_line and the same cursor out. A packed string is a length byte and
;  then its bits, MSB first, code 0 ending it, the last byte padded with
;  zeros -- so stepping over one is an add, and decoding one consumes
;  exactly its bytes, which is what keeps the cursor honest.
; ============================================================================

TEXT_PACKED         equ #FF

; ----------------------------------------------------------------------------
;  b7_fetch_body -- ONE string out of a table in this bank into bank7_line
;  In : HL = a string table in bank 7, A = how many strings to step over first
;  Out: bank7_line holds the string; HL points JUST PAST it, ready for the next
;  Uses: everything
; ----------------------------------------------------------------------------
b7_fetch_body:
    ld c,a
    ld a,(hl)
    inc a
    ld a,c
    jr z,b7_packed                      ; TEXT_PACKED in front: a packed table

    ;  A raw table: zero-terminated strings back to back.
    or a
    jr z,@b7_at_text
    ld b,a
@b7_skip_string:
    ld a,(hl)
    inc hl
    or a
    jr nz,@b7_skip_string
    djnz @b7_skip_string                ; ...one whole string per pass
@b7_at_text:
    ;  C is the room left in the buffer. A bound rather than a comment: the
    ;  text is authored in another file and a line long enough to run past the
    ;  end would write over whatever follows, on a screen that is drawn before
    ;  anyone could see what went wrong.
    ld de,bank7_line
    ld c,B7_BUF_SIZE
@b7_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    dec c
    jr z,@b7_full
    or a
    jr nz,@b7_copy
    ret

@b7_full:
    ;  Out of room. Terminate what there is, so the drawing walks off the end
    ;  of a string rather than off the end of the buffer -- and then finish
    ;  stepping over the rest of it, or the cursor this hands back would be
    ;  stranded in the middle of a string and every row after it would be
    ;  garbage rather than merely short.
    dec de
    xor a
    ld (de),a
@b7_rest:
    ld a,(hl)
    inc hl
    or a
    jr nz,@b7_rest
    ret

; ----------------------------------------------------------------------------
;  b7_packed -- the same, out of a packed table; HL -> its TEXT_PACKED byte
;
;  The bit buffer is C with a MARKER: the unread bits sit at the top and a
;  single 1 below them, so `sla c` hands over a bit in CF and leaves C zero
;  exactly when the bit was the marker -- the moment to load the next byte,
;  with `scf : rl c` putting the marker back under its seven remaining bits.
;  No counter. Five bits are rotated into A from zero, so A IS the code, and
;  the alphabet is a table because a table is the whole of the format.
;  The packer refuses a line longer than the buffer, so no bound is needed
;  here: the line ends at code 0 and the cursor is then just past its bytes.
; ----------------------------------------------------------------------------
b7_packed:
    inc hl                              ; past the marker
    or a
    jr z,@b7p_at_text
    ld b,a
@b7p_skip:
    ld a,(hl)                           ; the length byte...
    inc hl
    add a,l                             ; ...is how far to the next one
    ld l,a
    jr nc,@b7p_skip_nc
    inc h
@b7p_skip_nc:
    djnz @b7p_skip
@b7p_at_text:
    inc hl                              ; past the length byte
    ld de,bank7_line
    ld c,#80                            ; the buffer: empty, the marker alone
@b7p_char:
    xor a
    ld b,5                              ; five bits a code
@b7p_bit:
    sla c
    jr nz,@b7p_have
    ld c,(hl)
    inc hl
    scf
    rl c
@b7p_have:
    rla
    djnz @b7p_bit
    push hl
    ld hl,b7_alpha
    add a,l
    ld l,a
    jr nc,@b7p_alpha
    inc h
@b7p_alpha:
    ld a,(hl)
    pop hl
    ld (de),a
    inc de
    or a
    jr nz,@b7p_char
    ret

;  The alphabet, by code. tools/packtext.py's ALPHABET is the same string and
;  tests/test_textpack.py holds the two together.
b7_alpha:
    defb 0,"ABCDEFGHIJKLMNOPQRSTUVWXYZ .,-'"
    assert $ - b7_alpha == 32, "the packed alphabet is thirty-two codes"
