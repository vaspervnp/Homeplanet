; ============================================================================
;  menutext.asm -- the orders menu's keys and chrome, in bank 4
; ============================================================================
;  THE WORDS ARE NOT HERE. They are menu_words in game/screentext.asm, in bank
;  7, because DISC.BIN's ceiling under AMSDOS is what binds this project and
;  bank 7 is read off the disc into space that was already being read and
;  thrown away. What is left here is the four short strings that are cheaper
;  to keep than to fetch, and the key ids -- which stay for a reason rather
;  than for want of moving them.
;
;  THE KEY ID IS THE WHOLE OF THE BEHAVIOUR. menu.asm injects it and lets
;  phase4_commands do the work, so adding an order is adding a row and an order
;  that grows a precondition grows it in one place. Fetching it out of bank 7
;  would put a bank flip on the path between pressing ENTER and the order being
;  given, to save seventeen bytes; and menu_entry_key is now an index into this
;  table rather than a walk through seventeen strings, so it is smaller AND it
;  is the one that does not page.
;
;  Row n of the menu is menu_keys[n] and the nth string of menu_words. The two
;  files must stay the same length and src/main.asm asserts it: a line missing
;  from one of them would slide every shortcut onto the row above, and the menu
;  would go on working while giving the wrong orders.
; ----------------------------------------------------------------------------

;  menu_title and menu_prompt are in BANK 7 with the rest of the page words --
;  page_words in game/screentext.asm. The bar and the blank stay: they are
;  drawn seventeen times a frame.
menu_bar:
    defb ">",0
menu_blank:
    defb " ",0

;  In the same order as menu_words. The comments saying WHY each row sits where
;  it does are beside the words, because that is where the reader is looking.
menu_keys:
    defb KEY_A                          ; ATTACK
    defb KEY_G                          ; GUARD
    defb KEY_R                          ; STATION
    defb KEY_H                          ; HARVEST
    defb KEY_T                          ; TOW WRECKS
    defb KEY_B                          ; BUILD
    defb KEY_E                          ; REPAIR
    defb KEY_Y                          ; RECYCLE
    defb KEY_F                          ; FORMATION
    defb KEY_O                          ; SPLIT BY CLASS
    defb KEY_S                          ; SENSORS
    defb KEY_ENTER                      ; MOVE DISC
    defb KEY_J                          ; JUMP
    defb KEY_P                          ; PAN VIEW
    defb KEY_0                          ; CENTRE ON BASE
    defb KEY_I                          ; SQUADRON INFO
    defb KEY_SLASH                      ; CONTROLS
menu_keys_end:
