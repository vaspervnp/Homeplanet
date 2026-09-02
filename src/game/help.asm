; ============================================================================
;  help.asm -- the key list, on `?`, out with ESC
; ============================================================================
;  Section 9 is a page and a half of keys and the game gives the player no way
;  to look them up. This is that page, on the machine.
;
;  It works exactly like the mission briefing and for the same reason: while
;  it is up nothing else runs, and it is repainted EVERY frame rather than
;  once, because the display page-flips and a screen painted once would
;  alternate with whatever the other buffer still holds.
;
;  The strings live in bank 4 with the mission texts. They are about 400 bytes
;  and the low 16K has 512 left in total; the bank window is paged in for the
;  whole run, so txt_draw reads them where they lie.
; ----------------------------------------------------------------------------

;  Both moved up eight lines when the orders menu grew a fifteenth row. The
;  RIGHT column IS menu_entries, so this page's height is set by a file it does
;  not mention, and the assert in src/main.asm is the only thing that says so.
HELP_TITLE_Y        equ 4
HELP_BODY_Y         equ 14
;  Nine, and it has come down twice for the same reason: the RIGHT column is
;  menu_entries, so it is MENU_COUNT rows long and grows every time an order is
;  added, and this page's height is set by a file it does not mention. At
;  fifteen rows a step of eleven put the last one inside the HUD's strip; at
;  sixteen, ten does. The glyphs are eight tall, so nine is a one-pixel gutter
;  and there is nothing below it -- seventeen orders will need this column
;  split, which is what this page already does with the left one.
HELP_LINE_STEP      equ 9
HELP_ROWS           equ 11              ; the left column; the right one is
                                        ; MENU_COUNT long
HELP_COL1_X         equ 1               ; x is in BYTES: 4 pixels each
HELP_COL2_X         equ 40
HELP_PROMPT_X       equ 58              ; beside the title: the right column is
                                        ; thirteen rows and wants the bottom


; ----------------------------------------------------------------------------
;  help_open -- put the key list up
;  Uses: AF
; ----------------------------------------------------------------------------
help_open:
    ld a,1
    ld (help_shown),a
    ret


; ----------------------------------------------------------------------------
;  help_key -- ESC puts it away again
;  Uses: everything
; ----------------------------------------------------------------------------
help_key:
    ld a,KEY_ESC
    call key_hit
    ret nc
    xor a
    ld (help_shown),a

    ;  Same debt the briefing runs up: the page is painted over the whole
    ;  tactical area and records no dirty rectangle for any of it, so nothing
    ;  would ever erase it. Two frames of wipe, one per screen buffer.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  help_draw -- the whole page
;  Uses: everything
; ----------------------------------------------------------------------------
help_draw:
    ;  The strip below belongs to the HUD, so the player can still read the
    ;  fleet counts while the keys are up.
    call static_wipe

    ld hl,help_title
    ld b,HELP_COL1_X
    ld c,HELP_TITLE_Y
    call txt_draw

    ld hl,help_prompt
    ld b,HELP_PROMPT_X
    ld c,HELP_TITLE_Y
    call txt_draw

    xor a
    ld (help_gap),a
    ld a,HELP_ROWS
    ld (help_left),a
    ld hl,help_col_left
    ld b,HELP_COL1_X
    ld c,HELP_BODY_Y
    call help_column

    ;  The right-hand column IS the orders menu. One list, so an order added to
    ;  menutext.asm turns up on both screens and the two cannot disagree -- and
    ;  the key id in front of each entry is the one byte to step over.
    ld a,1
    ld (help_gap),a
    ld a,MENU_COUNT
    ld (help_left),a
    ld hl,menu_entries
    ld b,HELP_COL2_X
    ld c,HELP_BODY_Y
    jp help_column

; ----------------------------------------------------------------------------
;  help_column -- (help_left) strings, one under the next
;  In : HL = the first string, B = x in bytes, C = y,
;       (help_left) = how many, (help_gap) = bytes in front of each string
;  Uses: everything
;
;  The strings are stored back to back, each zero-terminated, so walking to
;  the next one is walking to just past the terminator. That costs nothing in
;  the table and a handful of bytes here, which is the right way round when
;  the table is in the bank and the code is not.
;
;  help_gap is what lets the orders menu's own list be one of the columns:
;  its entries carry a key id in front of the text, and one ADD is cheaper
;  than a second copy of the words.
; ----------------------------------------------------------------------------
help_column:
@help_row:
    ld a,(help_gap)
    ld e,a
    ld d,0
    add hl,de

    push bc
    push hl
    call txt_draw
    pop hl
    pop bc

@help_skip:
    ld a,(hl)
    inc hl
    or a
    jr nz,@help_skip                    ; step over the string and its zero

    ld a,c
    add a,HELP_LINE_STEP
    ld c,a

    ld a,(help_left)
    dec a
    ld (help_left),a
    jr nz,@help_row
    ret

; ============================================================================
;  State
; ============================================================================
help_shown:         defb 0
help_left:          defb 0
help_gap:           defb 0
