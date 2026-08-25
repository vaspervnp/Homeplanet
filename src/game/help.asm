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

HELP_TITLE_Y        equ 8
HELP_BODY_Y         equ 30
HELP_LINE_STEP      equ 12
HELP_ROWS           equ 10              ; per column, two columns
HELP_COL1_X         equ 1               ; x is in BYTES: 4 pixels each
HELP_COL2_X         equ 40


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
    ld bc,#0000
    ld a,(spr_clip_bottom)
    ld e,a
    ld d,SCR_BYTES_PER_LINE
    xor a
    call scr_fill_rect

    ld hl,help_title
    ld b,HELP_COL1_X
    ld c,HELP_TITLE_Y
    call txt_draw

    ld hl,help_col_left
    ld b,HELP_COL1_X
    ld c,HELP_BODY_Y
    call help_column

    ld hl,help_col_right
    ld b,HELP_COL2_X
    ld c,HELP_BODY_Y
    call help_column

    ld hl,help_prompt
    ld b,HELP_COL1_X
    ld c,HELP_BODY_Y + HELP_ROWS * HELP_LINE_STEP + 6
    jp txt_draw


; ----------------------------------------------------------------------------
;  help_column -- HELP_ROWS strings, one under the next
;  In : HL = the first string, B = x in bytes, C = y
;  Uses: everything
;
;  The strings are stored back to back, each zero-terminated, so walking to
;  the next one is walking to just past the terminator. That costs nothing in
;  the table and a handful of bytes here, which is the right way round when
;  the table is in the bank and the code is not.
; ----------------------------------------------------------------------------
help_column:
    ld a,HELP_ROWS
    ld (help_left),a

@help_row:
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
