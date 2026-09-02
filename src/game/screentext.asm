; ============================================================================
;  game/screentext.asm -- the words the stopped-world screens draw, IN BANK 7
; ============================================================================
;  The orders menu's list and the help page's left column. They followed the
;  briefings across for the same reason and by the same road; read the top of
;  game/briefings.asm for the arithmetic, because it is the same arithmetic.
;
;  The short of it: lib_load reads LIB_SECTORS -- 13312 bytes -- into bank 7
;  every boot, and bank 7 holds two 4320-byte sprite libraries, so thousands of
;  those bytes were already being read off tracks that are already reserved and
;  thrown away. Raw sectors are not in DISC.BIN. Text put here costs the file
;  nothing, and DISC.BIN's ceiling under AMSDOS's #A700 is what binds this
;  project.
;
;  WHAT STAYED BEHIND, AND WHY THE MENU IS NOW TWO TABLES
;  -----------------------------------------------------
;  A menu entry used to be a key id and then its words, back to back, and the
;  key id is the whole of the behaviour -- menu.asm injects it and lets
;  phase4_commands do the work. The words moved and THE KEYS DID NOT, because
;  a key that had to be fetched out of bank 7 would put the paging on the path
;  between pressing ENTER and the order being given, to save seventeen bytes.
;
;  So menu_keys is in bank 4 beside the code that reads it and menu_words is
;  here, and the two are parallel arrays: row n is menu_keys[n] and the nth
;  string. src/main.asm asserts they are the same length, which is the check
;  that used to be free when they were interleaved and is now worth having --
;  a missing line here would silently shift every row's shortcut onto the row
;  above it, and the menu would go on working while giving the wrong orders.
;
;  ...AND IT MADE THE HELP PAGE SIMPLER
;  -----------------------------------
;  The help page's right column IS the orders menu's list, so that it cannot
;  drift from it. It used to walk menu_entries with a "step over one byte in
;  front of each string" offset, which existed only because the key ids were in
;  the way. They are not in the way any more: both columns are now plain lists
;  of strings and help_column has one less thing to know.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  menu_words -- the orders menu's lines, in the order they are shown
;
;  The shortcut is printed at the end of each line, right-aligned into a
;  seventeen-character field, so the menu doubles as the reminder. Keep them
;  seventeen: MENU_TEXT_X is 24 bytes in and the screen is 80, which leaves
;  room for exactly that and no more. tests/test_menu.py measures every one of
;  them off build/bank7.raw -- what the build put on the disc, not the source.
;
;  The ORDER here is the order on the screen and it is the order of menu_keys
;  in game/menutext.asm. Adding a row is adding a line here and a key there.
; ----------------------------------------------------------------------------
menu_words:
    defb "ATTACK          A",0
    defb "GUARD           G",0
    defb "STATION         R",0
    defb "HARVEST         H",0
    ;  Beside HARVEST, because it is the same order for the other work ship and
    ;  a player looking for one will be looking at the other.
    defb "TOW WRECKS      T",0
    defb "BUILD           B",0
    ;  Beside BUILD, because they are the two things RU buys and the choice
    ;  between them is the whole point of what a repair costs.
    defb "REPAIR          E",0
    ;  ...and its opposite, beside it: the other direction RU and hull go in.
    defb "RECYCLE         Y",0
    defb "FORMATION       F",0
    defb "SPLIT BY CLASS  O",0
    ;  S rather than TAB: both are bound to the same thing, and S is the one
    ;  the emulator's keymap can press, so the tests can follow this row all
    ;  the way through to the view changing.
    defb "SENSORS         S",0
    defb "MOVE DISC   ENTER",0
    defb "JUMP            J",0
    defb "PAN VIEW        P",0
    defb "CENTRE ON BASE  0",0
    ;  The two that tell you something rather than order somebody, last and
    ;  together.
    defb "SQUADRON INFO   I",0
    defb "CONTROLS        ?",0
menu_words_end:

; ----------------------------------------------------------------------------
;  help_words -- the help page's LEFT column
;
;  Everything the orders menu does NOT offer: looking, moving, and carving the
;  fleet up. The right-hand column is menu_words above.
;
;  The font has no lower case. Keep every line inside 19 characters or it runs
;  into the other column -- txt_draw clips at the screen edge, not at the
;  column, so there is nothing to catch it but the test that measures these
;  off the disc image.
; ----------------------------------------------------------------------------
help_words:
    defb "1-9 SQUADRON",0
    defb "0   MOTHERSHIP",0
    defb "ARROWS  CAMERA",0
    defb "Z X + - ZOOM",0
    defb "SPACE   PAUSE",0
    defb "ESC CANCEL MOVE",0
    defb "SHIFT+UP/DN HEIGHT",0
    defb ", . PICK TARGET",0
    defb "D C DIVIDE/COMBINE",0
    defb "K L MOVE ONE SHIP",0
    defb "M   MUSIC ON/OFF",0
help_words_end:
