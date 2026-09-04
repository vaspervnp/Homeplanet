; ============================================================================
;  game/screentext.asm -- words that are only ever READ, IN BANK 7
; ============================================================================
;  The orders menu's list, the help page's left column, the tutorial's
;  seventeen instruction lines and the words on the two ending pages. They
;  followed the briefings across for the same reason and by the same road; read
;  the top of game/briefings.asm for the arithmetic, because it is the same
;  arithmetic.
;
;  "Stopped-world" was the rule when this file held two tables and it is not
;  the rule any more: the tutorial's row is drawn from tut_draw, at the very
;  end of an ordinary playing frame. What actually decides it is the narrow
;  test in game/shipclass.asm -- can this run between class_tier_addr and
;  class_blit_done? -- and nothing here can. bank7_fetch puts bank 4 back
;  before it returns, so a reader only has to be somewhere the window is at
;  rest, which the whole frame loop is except inside the blit.
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

; ----------------------------------------------------------------------------
;  tut_text -- the tutorial's seventeen instruction lines
;
;  TUT_STEPS strings back to back, in the order the steps run, so the order in
;  this file is the order on the screen. tut_draw fetches step n with a skip
;  count of n -- the seek the briefing does, not the walk the two columns above
;  do, because the tutorial draws ONE line and it is not the one after the last.
;
;  THE GATES AND THE ACTS STAYED IN BANK 4, and that is the menu_keys rule
;  again: tut_table is two addresses a row and it is the whole of the
;  behaviour, so a row fetched out of bank 7 would put the paging between a
;  player's key and the step advancing, to save sixty-eight bytes.
;
;  Every line has to fit TUT_TEXT_CHARS -- txt_draw clips at the SCREEN edge
;  and says nothing, so a long one is silently written over the step counter.
;  src/main.asm has the gross check and tests/test_tutorial.TestTheWords has
;  the exact one, per string, off build/bank7.raw.
; ----------------------------------------------------------------------------
tut_text:
    defb "ARROW KEYS TURN THE VIEW",0
    defb "Z AND X ZOOM IN AND OUT",0
    defb "P PANS  THEN 0 COMES BACK",0
    defb "S SWITCHES TO THE SENSORS",0
    defb "PRESS 1 OR 2 TO PICK A SQUADRON",0
    defb "I SHOWS WHAT IT IS MADE OF",0
    defb "ENTER ARROWS ENTER TO MOVE IT",0
    defb "F CHANGES THE FORMATION",0
    defb "D DIVIDES IT AND C JOINS IT",0
    defb "R SENDS IT HOME TO THE BASE",0
    defb "H SENDS HARVESTERS OUT TO MINE",0
    defb "B OPENS THE YARD  ENTER BUYS",0
    defb "ESC SHUTS IT   , . PICK A TARGET",0
    defb "A ATTACKS WHAT YOU PICKED",0
    defb "SPACE STOPS THE BATTLE",0
    defb "T TOWS THE WRECK HOME FOR RU",0
    defb "J LEAVES WHEN THE JOB IS DONE",0
tut_text_end:

; ----------------------------------------------------------------------------
;  The two endings' words -- see game/overtext.asm, which is what is left of
;  that file: the columns, the fire table and the equates.
;
;  THE ORDER IS LOAD-BEARING TWICE OVER. over_draw fetches a page's title with
;  a skip of 0 and then hands the cursor back for each of its three lines, so
;  the four strings of a page have to be adjacent and in the order they are
;  drawn -- exactly the walk the help page's columns do. And src/main.asm
;  measures each line's LENGTH as the distance to the label after it, so the
;  centring asserts are checking the strings that are really there.
;
;  over_prompt is shared: the victory page erases the save for the same reason
;  the defeat does, so both say BEGIN AGAIN. It sits after the losing page's
;  three lines, which is what makes (over_prompt - over_line_3 - 1) line 3's
;  length.
; ----------------------------------------------------------------------------
over_title:
    defb "GAME OVER",0
over_line_1:
    defb "THE MOTHERSHIP IS GONE.",0
over_line_2:
    defb "SIXTY THOUSAND SLEEPERS WITH IT.",0
over_line_3:
    defb "NINE GENERATIONS END HERE.",0
over_prompt:
    defb "SPACE - BEGIN AGAIN",0
over_prompt_end:

win_title:
    defb "HOMEPLANET",0
win_line_1:
    defb "THE MOTHERSHIP IS HOME.",0
win_line_2:
    defb "SIXTY THOUSAND SLEEPERS WAKE.",0
win_line_3:
    defb "NINE GENERATIONS BEGIN HERE.",0
win_line_3_end:


; ----------------------------------------------------------------------------
;  mini_words -- the four things the vortex chase has to say
;
;  Read by mini_draw, which is bank 4 code and fetches them a line at a time
;  through bank7_fetch, exactly as the briefings and the two ending pages do.
;
;  CENTRED BY HAND, in mini_msg_x: a line of n characters starts at
;  (SCR_BYTES_PER_LINE - n * TXT_CHAR_W_BYTES) / 2, and src/main.asm checks
;  every one of these against its own length so that rewording a line without
;  moving its column stops the build.
;
;  Section 1's voice: quiet, and never explaining more than it has to. The
;  first line is the exception and has to be -- it is the only place the keys
;  are named, because the context bar is suppressed on a screen that owns the
;  whole of the display.
; ----------------------------------------------------------------------------
mini_words:
mini_say_run:
    defb "IT CAME THROUGH.  ARROWS TO CLOSE.",0
mini_say_won:
    defb "THE VEKHAR IS CAPTURED.",0
mini_say_lost:
    defb "IT GOT AWAY.  THEY WERE WAITING.",0
mini_say_toll:
    defb "SHIPS LOST",0
;  Under the ship for the whole of the run -- "γράψε καθαρά από κάτω ότι
;  πρέπει να χρησιμοποιεί τα left και right". The top line names the arrows;
;  this one says which two, in a sentence, where the eye is.
mini_say_steer:
    defb "USE LEFT AND RIGHT TO STEER.",0
mini_words_end:

; ----------------------------------------------------------------------------
;  mini_intro_words -- what the chase is and which keys it wants, ONCE
;
;  Shown before the FIRST chase of a campaign and dismissed with ENTER; see
;  mini_intro in game/minigame.asm. Four lines and a prompt, walked in order on
;  the cursor bank7_fetch hands back. Each line is centred by hand in
;  MG_INTRO_XY and src/main.asm checks every x against its own string.
;
;  Section 1's voice, and the two keys named in the second line are the whole
;  of the controls -- there is nothing else to press until it is over.
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  class_name -- the full name of each class, for the context bar's build
;  panel and the squadron page. Back to back and zero-terminated, in class
;  order; ctx_class_name fetches the Ath. No name may exceed CTX_NAME_CHARS
;  or it runs into the cost figure -- src/main.asm asserts the total.
; ----------------------------------------------------------------------------
class_name:
    defb "INTERCEPTOR",0
    defb "MOTHERSHIP",0
    defb "HARVESTER",0
    defb "SCOUT",0
    defb "BOMBER",0
    defb "FRIGATE",0
    defb "SALVAGE",0
    defb "DESTROYER",0
class_name_end:

; ----------------------------------------------------------------------------
;  over_fire_table -- what is burning on the game-over planet, as
;  (dx, dy, height) from its centre. The design of it is in game/overtext.asm,
;  beside the columns it used to sit with; it is here because it is data the
;  game-over page reads with the world stopped, which is what bank 7 is for.
;  Both offsets are SIGNED. bank7_copy carries it, not bank7_fetch, because
;  it is full of zero bytes.
; ----------------------------------------------------------------------------
over_fire_table:
    defb  -25,   -9, 3
    defb  -24,  -11, 5
    defb  -23,  -10, 4
    defb  -11,  -18, 3
    defb  -10,  -20, 5
    defb   -9,  -19, 4
    defb    3,  -13, 3
    defb    4,  -15, 5
    defb    5,  -14, 4
    defb   19,   -7, 3
    defb   20,   -9, 5
    defb   21,   -8, 4
    defb  -19,    4, 3
    defb  -18,    2, 5
    defb  -17,    3, 4
    defb   -4,    8, 3
    defb   -3,    6, 5
    defb   -2,    7, 4
    defb   13,   10, 3
    defb   14,    8, 5
    defb   15,    9, 4
    defb   -9,   19, 3
    defb   -8,   17, 5
    defb   -7,   18, 4
    defb   24,    7, 3
    defb   25,    5, 5
    defb   26,    6, 4
    defb    7,   21, 3
    defb    8,   19, 5
    defb    9,   20, 4
over_fire_table_end:

; ----------------------------------------------------------------------------
;  ban_words -- the unlock banner, one line a class, in the order of
;  campaign_unlocks' bits. Centred by hand in game/banner.asm and asserted.
; ----------------------------------------------------------------------------
ban_words:
ban_frigate:    defb "THE YARD CAN BUILD THE FRIGATE",0
ban_destroyer:  defb "THE YARD CAN BUILD THE DESTROYER",0
ban_words_end:

; ----------------------------------------------------------------------------
;  title_words -- the title screen's four lines, in the order title_draw
;  fetches them: the name (txt_big, ten glyphs), the prompt, the key line,
;  the credit. src/main.asm asserts the name still spans the screen.
; ----------------------------------------------------------------------------
title_words:
title_text:     defb "HOMEPLANET",0
title_prompt:   defb "PRESS SPACE TO START",0
title_tut:      defb "T TUTORIAL  M MUSIC",0
title_tut_end:
title_credit:   defb "REVIVE8BIT - 2026 - VASPER",0
title_credit_end:

; ----------------------------------------------------------------------------
;  wave_say_text -- the HUD message row's five things, indexed by wave_msg.
; ----------------------------------------------------------------------------
wave_say_text:      defb "INCOMING",0
wave_say_text_1:    defb "YARD: FRIGATE",0
wave_say_text_2:    defb "YARD: DESTROYER",0
wave_say_text_3:    defb "AUTO RESPONSE ON",0
wave_say_text_4:    defb "AUTO RESPONSE USED",0
wave_say_text_end:

; ----------------------------------------------------------------------------
;  page_words -- the small words of the static pages: the help page's title
;  and its shared ESC - BACK prompt, the orders menu's title and prompt, and
;  the four formation names the squadron page prints. Indexed by the PAGE_*
;  equates; the formation names are the last four, in FORM order.
; ----------------------------------------------------------------------------
PAGE_HELP_TITLE     equ 0
PAGE_HELP_PROMPT    equ 1
PAGE_MENU_TITLE     equ 2
PAGE_MENU_PROMPT    equ 3
PAGE_FORM_0         equ 4
page_words:
help_title:         defb "HOMEPLANET - CONTROLS",0
help_prompt:        defb "ESC - BACK",0
menu_title:         defb "ORDERS",0
menu_prompt:        defb "UP/DOWN  ENTER  ESC",0
menu_prompt_end:
info_form_names:    defb "LOOSE",0
                    defb "WEDGE",0
                    defb "SPHERE",0
                    defb "WALL",0
info_form_names_end:
page_words_end:

; ----------------------------------------------------------------------------
;  tut_table -- the tutorial's steps: (gate, entry act) per row, in bank 4
;  code addresses. Data, so it lives here; tut_row copies a row down.
; ----------------------------------------------------------------------------
tut_table:
    ;  --- Act 1: looking. No enemies; nothing can go wrong. -----------------
    defw tut_g_look,    tut_a_none
    defw tut_g_zoom,    tut_a_none
    defw tut_g_pan,     tut_a_none
    defw tut_g_view,    tut_a_none
    ;  --- Act 2: the fleet --------------------------------------------------
    defw tut_g_squad,   tut_a_none
    defw tut_g_info,    tut_a_none
    defw tut_g_move,    tut_a_none
    defw tut_g_form,    tut_a_none
    defw tut_g_split,   tut_a_none
    defw tut_g_dock,    tut_a_none
    ;  --- Act 3: the economy ------------------------------------------------
    defw tut_g_mine,    tut_a_none
    defw tut_g_build,   tut_a_none
    ;  --- Act 4: the fight --------------------------------------------------
    defw tut_g_target,  tut_a_enemy
    defw tut_g_fight,   tut_a_none
    defw tut_g_pause,   tut_a_none
    defw tut_g_salvage, tut_a_none
    ;  --- Act 5: leaving ----------------------------------------------------
    defw tut_g_never,   tut_a_ready
tut_table_end:

mini_intro_words:
mini_intro_1:
    defb "A VEKHAR IS IN THE JUMP WITH US.",0
mini_intro_2:
    defb "LEFT AND RIGHT STEER INTO ITS WAKE.",0
mini_intro_3:
    defb "CLOSE ON IT BEFORE THE TUNNEL ENDS.",0
mini_intro_4: defb "DODGE ITS TORPEDOES. THREE HITS LOSE.",0
mini_intro_5:
    defb "LOSE IT, AND THEY WILL BE WAITING.",0
mini_intro_go:
    defb "ENTER - BEGIN",0
mini_intro_words_end:
