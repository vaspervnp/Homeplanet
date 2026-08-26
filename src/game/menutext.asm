; ============================================================================
;  menutext.asm -- what the orders menu offers, in bank 4
; ============================================================================
;  One entry is a key id followed by a zero-terminated line, back to back.
;  The key id is the whole of the behaviour: menu.asm injects it and lets
;  phase4_commands do the work, so adding an order here is adding a row, and
;  an order that grows a precondition grows it in one place.
;
;  The shortcut is printed at the end of each line, right-aligned into a
;  seventeen-character field, so the menu doubles as the reminder. Keep them
;  seventeen: MENU_TEXT_X is 24 bytes in and the screen is 80, which leaves
;  room for exactly that and no more.
; ----------------------------------------------------------------------------

menu_title:
    defb "ORDERS",0
menu_prompt:
    defb "UP/DOWN  ENTER  ESC",0
menu_bar:
    defb ">",0
menu_blank:
    defb " ",0

menu_entries:
    defb KEY_A
    defb "ATTACK          A",0
    defb KEY_G
    defb "GUARD           G",0
    defb KEY_R
    defb "STATION         R",0
    defb KEY_H
    defb "HARVEST         H",0
    defb KEY_B
    defb "BUILD           B",0
    defb KEY_F
    defb "FORMATION       F",0
    ;  S rather than TAB: both are bound to the same thing, and S is the one
    ;  the emulator's keymap can press, so the tests can follow this row all
    ;  the way through to the view changing.
    defb KEY_S
    defb "SENSORS         S",0
    defb KEY_ENTER
    defb "MOVE DISC   ENTER",0
    defb KEY_J
    defb "JUMP            J",0
    defb KEY_P
    defb "PAN VIEW        P",0
    defb KEY_0
    defb "CENTRE ON BASE  0",0
    defb KEY_SLASH
    defb "CONTROLS        ?",0
menu_entries_end:
