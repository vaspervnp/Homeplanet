; ============================================================================
;  overtext.asm -- the words on the game-over screen, in bank 4
; ============================================================================
;  Section 1's voice: lonely, quiet, and never explaining more than it has to.
;  The Mothership is the colony -- sixty thousand sleepers and nine generations
;  of them -- so the loss is stated as what it costs and not as a rule.
;
;  Each x is (SCR_BYTES_PER_LINE - characters * TXT_CHAR_W_BYTES) / 2, worked
;  out here rather than at run time because there is no centring in txt_draw
;  and one screen does not justify inventing it. They are asserted in
;  src/main.asm against the strings themselves, so a reworded line that is no
;  longer centred stops the build instead of sitting a character off.
; ----------------------------------------------------------------------------

;  Nine glyphs, which is what OVER_TITLE_X is centred for.
over_title:
    defb "GAME OVER",0

over_line_1:
    defb "THE MOTHERSHIP IS GONE.",0
OVER_LINE_1_X       equ 17

over_line_2:
    defb "SIXTY THOUSAND SLEEPERS WITH IT.",0
OVER_LINE_2_X       equ 8

over_line_3:
    defb "NINE GENERATIONS END HERE.",0
OVER_LINE_3_X       equ 14

;  BEGIN AGAIN and not CONTINUE, because over_erase_save has just made that
;  true: the disc no longer carries a campaign to continue.
over_prompt:
    defb "SPACE - BEGIN AGAIN",0
over_prompt_end:
OVER_PROMPT_X       equ 21


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
