; ============================================================================
;  menu.asm -- ESC brings up the orders, cursor keys pick one
; ============================================================================
;  Section 9 is a lot of keys to remember, and the help page only tells you
;  what they are. This one does them: ESC, up and down, ENTER.
;
;  THE MENU DOES NOT KNOW WHAT ANY COMMAND MEANS.
;  ---------------------------------------------
;  Each entry carries the key id it stands for, and choosing one INJECTS that
;  key -- writes its bit into key_edge and lets the frame carry on into
;  phase4_commands, which acts on it exactly as if the player had pressed it.
;
;  That is the whole design. A menu that called order_issue and eco_build_open
;  itself would be a second copy of the dispatch in phase4_commands, and the
;  two would drift the first time a command grew a precondition -- the build
;  panel already has three. This way there is one dispatch, and the menu is a
;  keyboard with bigger buttons.
;
;  It also means key_edge has to be CLEARED before the injected bit goes in.
;  The ESC that opened the menu is still sitting in there, and ESC also cancels
;  the move disc; leaving it would cancel the very order just given.
;
;  Runs from bank 4 like the title screen -- it is up only while the game is
;  stopped, so it has no business in the low 16K.
; ----------------------------------------------------------------------------

MENU_COUNT          equ 13
MENU_TITLE_Y        equ 20
MENU_TOP            equ 32
MENU_STEP           equ 12
MENU_MARK_X         equ 22              ; x is in BYTES
MENU_TEXT_X         equ 24


; ----------------------------------------------------------------------------
;  menu_open -- put the orders up, selection back at the top
;  Uses: AF
; ----------------------------------------------------------------------------
menu_open:
    ld a,1
    ld (menu_shown),a
    xor a
    ld (menu_pick),a
    ret


; ----------------------------------------------------------------------------
;  menu_close -- take it down and pay the screen debt
;  Uses: AF
; ----------------------------------------------------------------------------
menu_close:
    xor a
    ld (menu_shown),a
    ;  It painted the tactical area without recording a dirty rectangle for
    ;  any of it, same as the briefing and the help page.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  menu_key -- one frame of menu input
;  Out: (menu_shown) cleared if it is finished with
;  Uses: everything
; ----------------------------------------------------------------------------
menu_key:
    ld a,KEY_CUR_UP
    call key_hit
    jr nc,@menu_no_up
    ld a,(menu_pick)
    or a
    jr nz,@menu_up_ok
    ld a,MENU_COUNT                     ; wrap round the top
@menu_up_ok:
    dec a
    ld (menu_pick),a
    ret

@menu_no_up:
    ld a,KEY_CUR_DOWN
    call key_hit
    jr nc,@menu_no_down
    ld a,(menu_pick)
    inc a
    cp MENU_COUNT
    jr c,@menu_down_ok
    xor a
@menu_down_ok:
    ld (menu_pick),a
    ret

@menu_no_down:
    ld a,KEY_ESC
    call key_hit
    jr nc,@menu_no_esc
    call key_clear                      ; or this ESC cancels something next
    jp menu_close

@menu_no_esc:
    ld a,KEY_ENTER
    call key_hit
    ret nc

    ;  Take the entry's key, wipe the board, and put that one key back.
    call menu_entry_addr
    ld a,(hl)
    push af
    call key_clear
    pop af
    call key_inject
    jp menu_close


; ----------------------------------------------------------------------------
;  menu_entry_addr -- HL -> the selected entry (its key id byte)
;  Uses: AF, BC, DE, HL
;
;  The entries are variable length -- a key id and then a string -- so getting
;  to one is walking past the ones before it. Ten of them once a frame is
;  nothing, and it keeps the table a table rather than a table of pointers.
; ----------------------------------------------------------------------------
menu_entry_addr:
    ld hl,menu_entries
    ld a,(menu_pick)
    or a
    ret z
    ld b,a
@menu_skip_entry:
    inc hl                              ; past the key id
@menu_skip_text:
    ld a,(hl)
    inc hl
    or a
    jr nz,@menu_skip_text
    djnz @menu_skip_entry
    ret


; ----------------------------------------------------------------------------
;  menu_draw -- the panel
;  Uses: everything
; ----------------------------------------------------------------------------
menu_draw:
    ;  The HUD keeps its strip: the counts are exactly what a player is about
    ;  to give an order about.
    call static_wipe

    ld hl,menu_title
    ld b,MENU_MARK_X
    ld c,MENU_TITLE_Y
    call txt_draw

    ld hl,menu_entries
    ld (menu_ptr),hl
    ld a,MENU_TOP
    ld (menu_y),a
    xor a
    ld (menu_row),a

@menu_row_draw:
    ;  The marker, so the selection is visible without colour.
    ld hl,menu_bar
    ld a,(menu_row)
    ld c,a
    ld a,(menu_pick)
    cp c
    jr z,@menu_row_marked
    ld hl,menu_blank
@menu_row_marked:
    ld b,MENU_MARK_X
    ld a,(menu_y)
    ld c,a
    call txt_draw

    ld hl,(menu_ptr)
    inc hl                              ; step over the key id to the words
    push hl
    ld b,MENU_TEXT_X
    ld a,(menu_y)
    ld c,a
    call txt_draw
    pop hl

@menu_next_text:
    ld a,(hl)
    inc hl
    or a
    jr nz,@menu_next_text
    ld (menu_ptr),hl

    ld a,(menu_y)
    add a,MENU_STEP
    ld (menu_y),a

    ld hl,menu_row
    inc (hl)
    ld a,(hl)
    cp MENU_COUNT
    jr c,@menu_row_draw

    ld hl,menu_prompt
    ld b,MENU_MARK_X
    ld c,MENU_TOP + MENU_COUNT * MENU_STEP + 2
    jp txt_draw


; ============================================================================
;  State
; ============================================================================
menu_shown:         defb 0
menu_pick:          defb 0
menu_row:           defb 0
menu_y:             defb 0
menu_ptr:           defw 0

; ----------------------------------------------------------------------------
;  key_clear -- forget every edge recorded by the last scan
;  Uses: AF, B, HL
;
;  For the orders menu. The key that opened it is still in the array, and ESC
;  means "cancel the move disc" to order_update -- so choosing an order would
;  have cancelled it on the way out.
; ----------------------------------------------------------------------------
key_clear:
    ld hl,key_edge
    ld b,KEY_ROWS
    xor a
@key_clear_row:
    ld (hl),a
    inc hl
    djnz @key_clear_row
    ret


; ----------------------------------------------------------------------------
;  key_inject -- pretend a key was just pressed
;  In : A = key id
;  Uses: AF, BC, DE, HL
;
;  The mirror of key_bit, and it has to agree with it: that reads the flag out
;  with RRCA, so bit n of the row byte IS key n of that row -- no reversal.
;  Whatever sets this must run AFTER key_scan, which rebuilds the array from
;  the hardware every frame and would wipe an edge planted before it.
; ----------------------------------------------------------------------------
key_inject:
    push af
    rrca
    rrca
    rrca
    and #1F                             ; row = id >> 3
    ld l,a
    ld h,0
    ld de,key_edge
    add hl,de
    pop af

    and 7
    inc a                               ; rotate n times, entered mid-loop
    ld b,a
    ld a,1
    jr @key_inject_count
@key_inject_bit:
    rlca
@key_inject_count:
    djnz @key_inject_bit

    or (hl)
    ld (hl),a
    ret
