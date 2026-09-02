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
;  THE STRINGS ARE IN BANK 7, with the mission briefings and for the same
;  reason -- see game/screentext.asm. This code is bank 4 and cannot page bank 7
;  in for itself, so help_column fetches each row through bank7_fetch, which
;  does the paging from the low 16K. Both columns are plain lists of strings
;  now: the right-hand one is the orders menu's own words, and the key ids that
;  used to be interleaved with them stayed behind in bank 4.
; ----------------------------------------------------------------------------

;  Both moved up eight lines when the orders menu grew a fifteenth row. The
;  RIGHT column IS menu_words, so this page's height is set by a file it does
;  not mention, and the assert in src/main.asm is the only thing that says so.
HELP_TITLE_Y        equ 4
HELP_BODY_Y         equ 14
;  Nine, and it has come down twice for the same reason: the RIGHT column is
;  menu_words, so it is MENU_COUNT rows long and grows every time an order is
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
;  How wide a left-column line may be before it runs into the right one.
;  txt_draw clips at the screen edge and not at the column, so nothing catches
;  an over-long line but this and the test that measures each one off the disc.
;
;  A LITERAL WITH AN ASSERT, and not the division it obviously wants to be.
;  (HELP_COL2_X - HELP_COL1_X) / TXT_CHAR_W_BYTES is 39/2, and RASM does not
;  floor it -- it came back TWENTY, which is one character past HELP_COL2_X and
;  exactly the overlap this equate exists to prevent. Same reason TUT_STEPS is
;  written out: when the assembler's arithmetic is not the arithmetic you
;  meant, state the answer and check it.
HELP_MAX_CHARS      equ 19
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

    ld a,HELP_ROWS
    ld (help_left),a
    ld hl,help_words
    ld b,HELP_COL1_X
    ld c,HELP_BODY_Y
    call help_column

    ;  The right-hand column IS the orders menu's own list. One copy of the
    ;  words, so an order added to screentext.asm turns up on both screens and
    ;  the two cannot disagree. It used to need a "step over the key id" offset
    ;  to walk that list; the keys are a separate table now, so both columns
    ;  are plain lists of strings and this is the same call twice.
    ld a,MENU_COUNT
    ld (help_left),a
    ld hl,menu_words
    ld b,HELP_COL2_X
    ld c,HELP_BODY_Y
    jp help_column

; ----------------------------------------------------------------------------
;  help_column -- (help_left) strings out of BANK 7, one under the next
;  In : HL = the first string, B = x in bytes, C = y, (help_left) = how many
;  Uses: everything
;
;  The strings are stored back to back, each zero-terminated, so walking to
;  the next one is walking to just past the terminator -- and bank7_fetch hands
;  the cursor back already there, which is what stops seventeen rows from
;  re-counting the rows above them.
;
;  BC IS PUSHED AROUND THE FETCH AS WELL AS AROUND THE DRAW. It carries the x
;  and the y of the row, and the fetch uses BC for the gate array port. That is
;  the whole of what moving the words to bank 7 cost this routine.
; ----------------------------------------------------------------------------
help_column:
@help_row:
    push bc
    xor a
    call bank7_fetch
    pop bc
    push bc
    push hl                             ; the cursor, for the next row

    ld hl,bank7_line
    call txt_draw

    pop hl
    pop bc

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
