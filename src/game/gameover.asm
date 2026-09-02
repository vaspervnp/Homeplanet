; ============================================================================
;  game/gameover.asm -- the Mothership is gone, and so is the campaign
; ============================================================================
;  Section 8's table says it in four words -- "Αν χαθεί → τέλος παιχνιδιού" --
;  and section 10 says the same in prose: the whole colony is aboard, sixty
;  thousand sleepers, and there is no fleet without it. mis_update has set
;  mis_failed on that condition since the campaign was written.
;
;  NOTHING EVER LOOKED AT IT. The only reader was wave_update, which stopped
;  sending waves; the frame loop went on running, the HUD went on offering
;  JUMP, and the player was left flying a fleet around an empty map with no
;  way to be told the game had ended. A defeat condition that is computed and
;  not shown is not a defeat condition.
;
;  IT HAS NO FLAG OF ITS OWN, and that is the whole design of it. The page is
;  up exactly when mis_failed is set, and mis_failed is already cleared in the
;  three places a campaign can begin -- mis_init, mis_setup, and the
;  tutorial's own setup. So "the screen goes away when a new campaign starts"
;  is true by construction rather than by anyone remembering to clear a second
;  byte, which is the same reasoning that makes squad_count derived and
;  eco_repaired per-mission.
;
;  It is the fifth screen to stop the world, after the briefing, the help
;  page, the squadron breakdown and the orders menu, and it has the same two
;  obligations: repaint every frame, because the display page-flips and a
;  screen painted once alternates with whatever the other buffer holds; and
;  leave the screen clean behind it.
;
;  THE WHOLE SCREEN, NOT static_wipe. The other four pages stop at
;  spr_clip_bottom and leave the HUD strip standing, because the fleet counts
;  are what a player is about to give an order about. There are no more orders.
;  A strip reading RU 1240 and M 5 under GAME OVER is the instruments of a ship
;  that is gone, and clearing all two hundred lines costs one fill on a screen
;  that has nothing else to do.
;
;  SPACE BEGINS AGAIN, AND IT DESTROYS THE SAVE
;  --------------------------------------------
;  This is the part that makes the defeat real, and it is a decision rather
;  than a detail. FLEET.DAT is written at every jump, so it holds the fleet as
;  it stood at the start of the mission that has just been lost -- with the
;  Mothership alive. Leave it there and "τέλος παιχνιδιού" costs nothing at
;  all: the player power-cycles, demo_init reads the save back, and the
;  campaign resumes one mission earlier. Section 1's premise is that what is
;  lost is lost; the Mothership is the one thing whose loss cannot be a
;  setback.
;
;  So the magic is zeroed and the block written back, which is exactly what
;  fleet_disc_load checks first. An erased save reads as no save, and no save
;  is how a new game starts -- sixteen ships on mission 1. The prompt says
;  BEGIN AGAIN rather than CONTINUE for that reason.
;
;  And then demo_reset, which is the tutorial's own way out: it re-reads the
;  disc, spawns a fresh fleet, lays mission 1 out and opens the title. Reading
;  the campaign back IS reading the disc, so there is one path and it cannot
;  disagree with itself.
; ----------------------------------------------------------------------------

;  Nine glyphs at TXT_BIG_W_BYTES is 72 of the 80-byte line. The face is five
;  pixels in an eight-pixel cell, so the last three byte columns of the last
;  glyph are blank by construction -- the drawn width is 69 and the margin
;  that centres it is (80 - 69) / 2, not (80 - 72) / 2. src/main.asm asserts
;  the string is the length this arithmetic assumes.
OVER_TITLE_X        equ 5

;  Sixteen, not thirty-six: the burning world went in below the message and
;  the whole stack moved up to make room for it. The big letters are 32
;  scanlines tall, so this is as high as they go without touching the top edge.
OVER_TITLE_Y        equ 16

;  The body, centred by hand: a character is TXT_CHAR_W_BYTES wide, so a line
;  of n characters starts at (SCR_BYTES_PER_LINE - n * 2) / 2. There is no
;  centring in txt_draw and one caller does not justify one.
OVER_BODY_Y         equ 58
OVER_LINE_STEP      equ 12

;  THE HOMEPLANET, BURNING, BETWEEN THE MESSAGE AND THE WAY OUT.
;
;  The same ellipse the title screen draws, out of the same table and through
;  the same planet_draw, with fires on it. THE SAMENESS IS THE POINT: the title
;  shows the world the fleet is flying towards and this shows the same world
;  burning, which is the only picture in the game that says what was lost
;  rather than counting it. Drawing it dark instead was tried and read as a
;  hollow ring with red specks in it -- see planet_cx in game/title.asm.
;
;  It sits below the three lines and above the prompt rather than behind
;  either. There is no clipping anywhere in this drawing -- scr_fill_rect
;  writes the bytes it is given and gfx_vline clips only in Y -- so overlapping
;  the text would not be a layout choice, it would be a fill walking through
;  the glyphs. src/main.asm asserts the gaps at both ends.
OVER_PLANET_CX      equ 160
OVER_PLANET_CY      equ 132

OVER_PROMPT_Y       equ 180

;  Ink 3 for the fires, which is the same ink GAME OVER is in and is the point
;  rather than a coincidence: section 2 gives ink 3 to the thing that demands
;  attention, and on this screen the word and the fires are the same statement.
;  Against a black night side they are the only colour inside the limb.
OVER_FIRE_PEN       equ 3


; ----------------------------------------------------------------------------
;  over_key -- SPACE begins again
;  Uses: everything
; ----------------------------------------------------------------------------
over_key:
    ld a,KEY_SPACE
    call key_hit
    ret nc

    call over_erase_save
    jp demo_reset                       ; ...which ends by opening the title


; ----------------------------------------------------------------------------
;  over_erase_save -- make the disc read as a disc with no save on it
;  Uses: everything
;
;  Two bytes of the header and the same write fleet_disc_save does. NOT
;  fleet_disc_save itself, which begins by stamping the magic back in.
;
;  The rest of the block is left exactly as it is, deliberately: nothing reads
;  a byte of it once the magic has failed, and writing sixteen hundred bytes of
;  zeroes to say so would be a second thing to keep in step with the record
;  layout every time that layout changes.
; ----------------------------------------------------------------------------
over_erase_save:
    ld hl,fleet_block
    xor a
    ld (hl),a
    inc hl
    ld (hl),a
    jp fdc_fleet_save


; ----------------------------------------------------------------------------
;  over_draw -- the whole page
;  Uses: everything
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
;  THE TWO ENDINGS ARE ONE PAGE, and that is worth stating because they were
;  nearly two files. Everything below is identical for both: the two-hundred
;  line wipe, a ten-or-nine glyph word in txt_big, three centred lines, the
;  homeplanet, and SPACE erasing the save and beginning again. What differs is
;  the words, their columns, the ink of the big one, and whether the world is
;  burning -- so those are a DESCRIPTOR and the drawing is shared.
;
;  A second copy would have cost about two hundred bytes of DISC.BIN, which has
;  four hundred; and it would have been two places to fix the day the layout
;  moved, which is how the orders menu and the help page came to disagree about
;  where their prompts went.
;
;  Nine bytes: three (string, x) pairs, the title and its x, and the big ink.
;  The FIRES are not in it -- they are keyed on mis_failed directly, because
;  "the losing page has fires" is a fact about which page it is rather than a
;  parameter anyone would ever want to set the other way.
; ----------------------------------------------------------------------------
OVER_PAGE_SIZE      equ 9

over_page_lost:
    defw over_title
    defb OVER_TITLE_X, SOLID_INK_3
    defb OVER_LINE_1_X, OVER_LINE_2_X, OVER_LINE_3_X
    defb 0                              ; pad to OVER_PAGE_SIZE
    defb 0

over_page_won:
    defw win_title
    defb WIN_TITLE_X, TXT_BIG_INK
    defb WIN_LINE_1_X, WIN_LINE_2_X, WIN_LINE_3_X
    defb 0
    defb 0


over_draw:
    ;  All two hundred lines: see the head of this file for why this one does
    ;  not use static_wipe.
    ld bc,#0000
    ld d,SCR_BYTES_PER_LINE
    ld e,SCR_HEIGHT_PX
    xor a
    call scr_fill_rect

    ;  Which ending. mis_failed is the flag for one and mis_won for the other,
    ;  and they cannot both be set: mis_jump only lands on a board with nothing
    ;  hostile flying, and mis_update only fails on a Mothership that is gone.
    ld hl,over_page_lost
    ld a,(mis_won)
    or a
    jr z,@over_page
    ld hl,over_page_won
@over_page:
    ld (over_page_ptr),hl

    ;  The big word, in its own ink, and put back to the title screen's on the
    ;  way out -- that screen draws through the same routine and is white.
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld b,(hl)                           ; its x
    inc hl
    ld a,(hl)                           ; ...and its ink
    call txt_big_set_ink
    ex de,hl
    ld c,OVER_TITLE_Y
    call txt_big_at
    ld a,TXT_BIG_INK
    call txt_big_set_ink

    ;  The three lines. Their strings are back to back after the title, so the
    ;  walk is mis_next_line and only the columns come out of the descriptor --
    ;  the same shape as the briefings and the orders menu.
    ld hl,(over_page_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    ex de,hl
    call mis_next_line                  ; past the title, to line 1
    ld (over_line_ptr),hl

    ld a,OVER_BODY_Y
    ld (over_line_y),a
    ld hl,(over_page_ptr)
    ld de,4
    add hl,de
    ld (over_x_ptr),hl
    ld a,3
    ld (over_lines_left),a
@over_line:
    ld hl,(over_x_ptr)
    ld b,(hl)
    inc hl
    ld (over_x_ptr),hl
    ld a,(over_line_y)
    ld c,a
    ld hl,(over_line_ptr)
    push hl
    call txt_draw
    pop hl
    call mis_next_line
    ld (over_line_ptr),hl
    ld a,(over_line_y)
    add a,OVER_LINE_STEP
    ld (over_line_y),a
    ld hl,over_lines_left
    dec (hl)
    jr nz,@over_line

    ;  The world, and then what is burning on it.
    ld hl,OVER_PLANET_CX
    ld (planet_cx),hl
    ld a,OVER_PLANET_CY
    ld (planet_cy),a
    call planet_draw
    ;  ...burning, on the losing page only. The winning one is the same world
    ;  arrived at, and the title screen already draws exactly that.
    ld a,(mis_won)
    or a
    call z,over_fires

    ;  The prompt in ink 2, which is what the context bar means by "a key".
    ;  The bar itself is suppressed on every full-screen page, so this line is
    ;  the only thing on the screen saying how to leave it.
    ld a,2
    call txt_set_pen
    ld hl,over_prompt
    ld b,OVER_PROMPT_X
    ld c,OVER_PROMPT_Y
    call txt_draw
    ld a,1
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  over_fires -- what is burning, in ink 3, inside the dark side
;  Uses: everything
;
;  A table of (dx, dy, height) from the planet's centre, each drawn as a
;  one-pixel column through gfx_vline. Two or three of them side by side and a
;  row apart is what makes a fire rather than a dot: a single pixel reads as
;  noise and a rectangle reads as a window, but a ragged two-wide column two or
;  three tall reads as a flame at this size. They are grouped rather than
;  scattered evenly for the same reason -- an even scatter reads as a texture.
;
;  Every offset is well inside the ellipse by construction, which is what makes
;  this affordable: there is no per-fire test against the limb, because a fire
;  outside it would be a fire in space and the table is the place to get that
;  right. tests/test_gameover.py checks every entry against the ellipse.
;
;  planet_draw puts the viewport back to the game's on its way out, so this has
;  to open it again -- gfx_vline clips against spr_clip_top and _bottom, and
;  the lower half of the planet is inside the strip the HUD normally owns.
; ----------------------------------------------------------------------------
over_fires:
    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    xor a
    ld (spr_clip_top),a

    ld a,OVER_FIRE_COUNT
    ld (over_fires_left),a
    ld hl,over_fire_table
    ld (over_fire_ptr),hl

@of_one:
    ld hl,(over_fire_ptr)
    ld a,(hl)
    ld (over_fire_dx),a
    inc hl
    ld a,(hl)
    ld (over_fire_dy),a
    inc hl
    ld a,(hl)
    ld (over_fire_h),a
    inc hl
    ld (over_fire_ptr),hl

    ;  x = cx + dx, and dx is SIGNED -- half the fires are left of centre, so
    ;  the byte has to be sign-extended into a word before it is added to a
    ;  centre that is 160.
    ld a,(over_fire_dx)
    ld e,a
    add a,a                             ; the sign bit into the carry
    sbc a,a                             ; #FF if it was set, #00 if not
    ld d,a
    ld hl,(planet_cx)
    add hl,de

    push hl
    ld a,(over_fire_dy)
    ld hl,planet_cy
    add a,(hl)
    ld c,a                              ; C = y
    ld a,(over_fire_h)
    ld b,a                              ; B = how many lines
    pop hl
    ld a,OVER_FIRE_PEN
    call gfx_vline

    ld hl,over_fires_left
    dec (hl)
    jr nz,@of_one

    ld a,HUD_TOP                        ; ...and the viewport back again
    ld (spr_clip_bottom),a
    ld a,CTX_BAR_H
    ld (spr_clip_top),a
    ret


; ============================================================================
;  Scratch. One fire's worth, and none of it survives over_fires.
; ============================================================================
over_page_ptr:      defw 0
over_line_ptr:      defw 0
over_x_ptr:         defw 0
over_line_y:        defb 0
over_lines_left:    defb 0
over_fires_left:    defb 0
over_fire_ptr:      defw 0
over_fire_dx:       defb 0
over_fire_dy:       defb 0
over_fire_h:        defb 0
