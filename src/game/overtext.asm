; ============================================================================
;  overtext.asm -- where the two ending pages' words are drawn, in bank 4
; ============================================================================
;  Section 1's voice: lonely, quiet, and never explaining more than it has to.
;  The Mothership is the colony -- sixty thousand sleepers and nine generations
;  of them -- so the loss is stated as what it costs and not as a rule.
;
;  THE WORDS THEMSELVES ARE IN BANK 7, in game/screentext.asm, and what is left
;  here is their COLUMNS and the fire table. They went across when DISC.BIN was
;  down to a hundred and forty bytes: lib_load reads LIB_SECTORS into bank 7
;  every boot whether anything is in them or not, so raw-sector text costs the
;  file nothing while a byte of the bank-4 image costs it one.
;
;  The columns stayed because they are not text: over_draw reads three of them
;  out of a descriptor per page, one per line, and a column fetched out of bank
;  7 would need a bank flip to read a byte -- the menu_keys rule exactly.
;
;  Each x is (SCR_BYTES_PER_LINE - characters * TXT_CHAR_W_BYTES) / 2, worked
;  out here rather than at run time because there is no centring in txt_draw
;  and one screen does not justify inventing it. They are asserted in
;  src/main.asm against the strings themselves -- which is why the strings have
;  to stay ADJACENT AND IN ORDER over there, and why those asserts had to move
;  to the bottom of that file, after the bank-7 include: ASSERT is evaluated
;  where it stands and cannot see an include that has not happened yet.
; ----------------------------------------------------------------------------

;  Nine glyphs, which is what OVER_TITLE_X is centred for.
OVER_LINE_1_X       equ 17
OVER_LINE_2_X       equ 8
OVER_LINE_3_X       equ 14

;  BEGIN AGAIN and not CONTINUE, because over_erase_save has just made that
;  true: the disc no longer carries a campaign to continue. SHARED with the
;  victory page, which erases the save for the same reason -- a finished
;  campaign is not one to be resumed either.
OVER_PROMPT_X       equ 21


; ----------------------------------------------------------------------------
;  ...AND THE OTHER ENDING, which is the same page with different words.
;
;  THE BIG WORD IS THE GAME'S NAME, and that is the whole idea rather than a
;  convenience. HOMEPLANET is exactly ten glyphs, which is what txt_big spans
;  the screen with and what the title screen already says -- so the first
;  screen of the game states it as a promise and the last one states it as an
;  arrival, in the same letters at the same size. It is white where GAME OVER
;  is red: section 2 gives ink 1 to the fleet and ink 3 to alarm.
;
;  THE THREE LINES DELIBERATELY MIRROR THE DEFEAT'S, line for line, because
;  the two endings are the same sentence with the verbs changed:
;
;      THE MOTHERSHIP IS GONE.          THE MOTHERSHIP IS HOME.
;      SIXTY THOUSAND SLEEPERS WITH IT. SIXTY THOUSAND SLEEPERS WAKE.
;      NINE GENERATIONS END HERE.       NINE GENERATIONS BEGIN HERE.
;
;  The first pair is even the same length, so they occupy the same column.
;  Section 1's voice is what decides "WAKE" rather than anything triumphant:
;  the reward for nine generations of flight is that the sleepers get up.
; ----------------------------------------------------------------------------
;  Ten glyphs, one more than GAME OVER, so it is centred differently -- and
;  at ten it is what txt_big spans the whole line with, which is exactly
;  what the title screen asserts about the same word.
WIN_TITLE_X         equ 0
WIN_LINE_1_X        equ 17
WIN_LINE_2_X        equ 11
WIN_LINE_3_X        equ 12


; ----------------------------------------------------------------------------
;  What is burning, as (dx, dy, height) from the planet's centre.
;
;  Both offsets are SIGNED. Ten fires of THREE COLUMNS EACH -- heights 3, 5, 4
;  with the tall one starting a row higher, so the shape is a flame and not a
;  block.
;
;  There were six single columns scattered between them as well, so the field
;  was not ten copies of one silhouette, and they were SPENT: eighteen bytes of
;  the bank-4 window, which was thirteen bytes over when the title screen's
;  music went in. Six pixels of texture against a tune is not a close call.
;
;  IT WAS SIXTEEN ENTRIES OF ONE AND TWO COLUMNS AND THAT WAS NOT ENOUGH. Looked
;  at, the planet read as a hollow blue ring with red specks inside it: the
;  interior is black and the limb is one pixel, so unless the fires give the
;  disc some substance there is nothing to say it is a body at all. Three
;  columns is what turns a mark into a flame at this size, and thirty-six
;  entries is what fills the face.
;
;  Every entry is well inside the ellipse: the worst is at 0.54 of the way out,
;  where 1.0 is the limb. There is no per-fire clip in over_fires and there
;  should not be one -- a fire outside the planet is a fire in space, and the
;  table is where that is got right. tests/test_gameover.py re-derives the
;  ellipse and checks every entry, top and bottom.
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

;  A literal with an assert rather than (end - start) / 3, because RASM cannot
;  resolve an equate derived from two bank-4 labels at symbol-export time --
;  the same reason TUT_STEPS is written out.
OVER_FIRE_COUNT     equ 30
