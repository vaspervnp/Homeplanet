; ============================================================================
;  menu.asm -- ESC brings up the orders, cursor keys pick one
; ============================================================================
;  Section 9 is a lot of keys to remember, and the help page only tells you
;  what they are. This one does them: ESC, up and down, ENTER.
;
;  THE MENU DOES NOT KNOW WHAT ANY COMMAND MEANS.
;  ---------------------------------------------
;  Each row has a key id it stands for, and choosing one INJECTS that key --
;  writes its bit into key_hits and lets the frame carry on into
;  phase4_commands, which acts on it exactly as if the player had pressed it.
;
;  A row is two tables deep now rather than one: menu_keys in bank 4 beside
;  this code, and menu_words in BANK 7 with the briefings, because DISC.BIN's
;  ceiling is what binds this project and bank 7 costs it nothing. The keys did
;  not go with the words -- see game/menutext.asm -- so nothing pages a bank
;  between pressing ENTER and the order being given, and menu_entry_key is an
;  index rather than the walk it used to be. menu_draw fetches a row at a time
;  through bank7_fetch, which does the paging from the low 16K.
;
;  That is the whole design. A menu that called order_issue and eco_build_open
;  itself would be a second copy of the dispatch in phase4_commands, and the
;  two would drift the first time a command grew a precondition -- the build
;  panel already has three. This way there is one dispatch, and the menu is a
;  keyboard with bigger buttons.
;
;  It also means key_hits has to be CLEARED before the injected bit goes in.
;  The ESC that opened the menu is still sitting in there, and ESC also cancels
;  the move disc; leaving it would cancel the very order just given.
;
;  Runs from bank 4 like the title screen -- it is up only while the game is
;  stopped, so it has no business in the low 16K.
; ----------------------------------------------------------------------------

;  Sixteen rows, and the last three of those were paid for out of the layout
;  rather than out of nothing. "Adding an order to the menu is adding a row" is
;  true about the DISPATCH and was never true about the layout: at fourteen
;  rows the list already ended eight scanlines short of HUD_TOP, and the
;  fifteenth would have been drawn across "RU 0080 ?HELP" and stayed there,
;  because the HUD does not clear its strip -- it draws labels onto it. The
;  asserts in src/main.asm are what stop that shipping, and they have now done
;  it twice: TOW WRECKS failed the build until the title and the list moved six
;  lines up, and REPAIR failed it again with nothing left above the title to
;  move.
;
;  SO THE STEP IS NINE, which the note here previously declined to do. The
;  glyphs are eight tall, so nine is a one-pixel gutter and the list is visibly
;  tighter than it was; ten with sixteen rows is 176 and the HUD starts at 168.
;  The choice was a cramped list or a command the player cannot find -- the
;  help page's right column IS this table, so a row that is not here is not
;  anywhere. Seventeen rows will need a second column, which is what
;  help.asm already does.
MENU_COUNT          equ 17
MENU_TITLE_Y        equ 4
MENU_TOP            equ 14
MENU_STEP           equ 9
MENU_MARK_X         equ 22              ; x is in BYTES
MENU_TEXT_X         equ 24
;  Every row of menu_words is padded to exactly this so the shortcut at the end
;  right-aligns, which is what lets src/main.asm check the whole table with one
;  division. It fits because MENU_TEXT_X is 24 bytes in and the screen is 80,
;  so there is room for twenty-eight characters and no more.
MENU_FIELD          equ 17
;  Beside the title, not under the list. Thirteen rows do not leave room for a
;  line of their own above HUD_TOP -- help.asm reached the same arrangement for
;  the same reason, and its right column is this same table.
MENU_PROMPT_X       equ 40


; ----------------------------------------------------------------------------
;  menu_open -- put the orders up, selection back at the top
;  Uses: AF
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  menu_open_or_leave -- what ESC does when there is nothing left to cancel
;  Uses: everything
;
;  Everything above this in phase4_commands' ESC chain is "cancel the innermost
;  thing" -- the move disc, the build panel, an armed RECYCLE, a jump spooling.
;  Once there is nothing left to cancel, the innermost thing IS the tutorial,
;  and leaving it is what ESC should mean there.
;
;  The menu is no loss on that stage: it teaches the keys themselves, one at a
;  time, and until now the tutorial was the only screen in the game a player
;  could not get out of without finishing all seventeen steps.
; ----------------------------------------------------------------------------
menu_open_or_leave:
    ld a,(tut_active)
    or a
    jp nz,tut_exit
    ;  ...and fall through

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
    call menu_entry_key
    push af
    call key_clear
    pop af
    call key_inject
    jp menu_close


; ----------------------------------------------------------------------------
;  menu_entry_key -- A = the key id the selected row stands for
;  Uses: AF, DE, HL
;
;  One index into a flat table. It used to be a walk past every entry above
;  this one, because a key id and its words were stored back to back and the
;  entries were therefore variable length. The words are in bank 7 now and the
;  keys are a parallel array in bank 4 -- see game/menutext.asm for why the
;  keys did not go with them -- so the walk is gone and, more to the point, so
;  is any question of paging a bank on the path between ENTER and the order.
; ----------------------------------------------------------------------------
menu_entry_key:
    ld a,(menu_pick)
    ld e,a
    ld d,0
    ld hl,menu_keys
    add hl,de
    ld a,(hl)
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

    ld hl,menu_prompt
    ld b,MENU_PROMPT_X
    ld c,MENU_TITLE_Y
    call txt_draw

    ;  The cursor into bank 7's word list. bank7_fetch hands it back one string
    ;  further on each time, so seventeen rows count seventeen strings between
    ;  them rather than a hundred and fifty.
    ld hl,menu_words
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

    ;  Out of bank 7 and into the low 16K, then drawn from there. The fetch
    ;  steps the cursor over the string for us, so there is nothing to walk.
    ld hl,(menu_ptr)
    xor a
    call bank7_fetch
    ld (menu_ptr),hl

    ld hl,bank7_line
    ld b,MENU_TEXT_X
    ld a,(menu_y)
    ld c,a
    call txt_draw

    ld a,(menu_y)
    add a,MENU_STEP
    ld (menu_y),a

    ld hl,menu_row
    inc (hl)
    ld a,(hl)
    cp MENU_COUNT
    jr c,@menu_row_draw
    ret


; ============================================================================
;  State
; ============================================================================
menu_shown:         defb 0
menu_pick:          defb 0
menu_row:           defb 0
menu_y:             defb 0
menu_ptr:           defw 0

; ----------------------------------------------------------------------------
;  key_clear -- forget every edge this frame was given
;  Uses: AF, B, HL
;
;  For the orders menu. The key that opened it is still in the array, and ESC
;  means "cancel the move disc" to order_update -- so choosing an order would
;  have cancelled it on the way out.
;
;  It clears key_hits, the frame's snapshot, and deliberately NOT key_edge --
;  that is the interrupt's accumulator, and anything in it arrived after this
;  frame began, which makes it a keypress the player made and is entitled to.
; ----------------------------------------------------------------------------
key_clear:
    ld hl,key_hits
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
;  Whatever sets this must run AFTER key_consume, which replaces key_hits
;  wholesale at the top of every frame and would wipe an edge planted before
;  it. It plants into key_hits and not key_edge for the same reason key_clear
;  does -- key_edge belongs to the interrupt.
; ----------------------------------------------------------------------------
key_inject:
    push af
    rrca
    rrca
    rrca
    and #1F                             ; row = id >> 3
    ld l,a
    ld h,0
    ld de,key_hits
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
