; ============================================================================
;  title.asm -- the screen the game opens on
; ============================================================================
;  HOMEPLANET across the full width, a starfield, a flight of ships, and the
;  credit line. ENTER goes on to the first briefing.
;
;  Drawn EVERY frame, like the briefing and the help page, because the display
;  page-flips and a screen painted once alternates with whatever the other
;  buffer holds. It is expensive -- a full clear plus 80x32 of title -- but it
;  is drawn while nothing else is running and it is over the moment the player
;  presses a key.
;
;  The title takes the whole width by construction rather than by centring:
;  txt_big is 8 bytes a glyph and the screen is 80, so ten letters is exactly
;  the line. There is an assert below to keep it that way.
; ----------------------------------------------------------------------------

TITLE_Y             equ 20              ; the big letters, 32 scanlines of them
TITLE_STARS         equ 40
TITLE_CREDIT_Y      equ 186
TITLE_PROMPT_Y      equ 160
;  THE BLINK IS COUNTED IN GAME FRAMES AND A GAME FRAME IS NOT A FIXED LENGTH,
;  which is the trap the attack waves fell into three times before their
;  clock was moved onto sys_tick_50hz altogether. This bit
;  was %100 -- four game frames each way -- and the comment said "a little under
;  a second", which it was at the 5 fps the screen ran at when it was written.
;
;  The planet took this screen from 3.45 fps to 2.30 (measured, DEMO_FRAMES over
;  1000 emulator frames), so four frames became 1.7 seconds each way and a blink
;  with a three-and-a-half second period does not read as a blink -- it reads as
;  a prompt that keeps going away. Two frames at 2.30 is 0.87 s, which is what
;  the screen has always meant to do.
TITLE_BLINK_BIT     equ %00000010   ; ~2 game frames on, ~2 off: 0.87 s at 2.3 fps

;  ...and the second way in. `T` ALREADY MEANS TOW once a mission is running --
;  it sends the selected squadron's Salvage Corvettes after wrecks -- and there
;  is no clash, because SPACE and T are the only live keys on this screen and
;  the tow order does not exist until there is a mission. But it is one letter
;  with two meanings, and this project has been here before: `,` and `.` step
;  the target with the build panel shut and the price list with it open, and
;  THE CONTEXT BAR EXISTS BECAUSE THAT WAS INVISIBLE. So whatever this screen
;  says about SPACE it says about T, in the same words, one line below.
;
;  It does NOT blink. The blink belongs to the primary call to action, and a
;  second blinking line reads as two things competing rather than as "and also".
TITLE_TUT_Y         equ 172

;  The ships, as (x, y) in the flight below the title.
TITLE_SHIP_Y        equ 104


; ----------------------------------------------------------------------------
;  title_open -- the game starts here
;  Uses: AF
; ----------------------------------------------------------------------------
title_open:
    ld a,1
    ld (title_shown),a

    ;  ...and the music, which belongs to this screen and to nothing else. It
    ;  plays by DEFAULT rather than waiting for a key: a tune nobody has turned
    ;  on is a tune nobody knows is there, and `M` is here for the player who
    ;  wants the silence back rather than for the one who wants the music.
    jp mus_start


; ----------------------------------------------------------------------------
;  title_key -- SPACE starts the game
;
;  SPACE is the tactical pause once the game is running, and there is no
;  clash: this screen returns out of demo_update before phase4_commands is
;  ever reached, so the keypress that starts the game cannot also pause it.
;  Uses: everything
; ----------------------------------------------------------------------------
title_key:
    ;  `T` first, and it does not come back: tut_enter clears title_shown and
    ;  builds the tutorial's own world. demo_update goes on to call title_draw
    ;  once more in this same frame, exactly as it does after SPACE, and the two
    ;  frames of mis_wipe tut_enter schedules are what pay for that.
    ;  `M` first, and it is the only one of the three that does not leave: it
    ;  toggles and falls through, so a player can silence the tune and then go
    ;  on reading the screen.
    ld a,KEY_M
    call key_hit
    call c,mus_toggle

    ld a,KEY_T
    call key_hit
    jr nc,@title_no_tut
    call mus_start_solo                 ; the game's mode: one voice, channel C
    jp tut_enter
@title_no_tut:

    ld a,KEY_SPACE
    call key_hit
    ret nc
    call mus_start_solo                 ; ...and the campaign gets the same
    xor a
    ld (title_shown),a

    ;  Same debt as the briefing and the help page: the whole screen has been
    ;  painted with no dirty rectangle recorded for any of it. Two frames of
    ;  wipe, one per buffer. The briefing that follows paints over the top
    ;  anyway, but the credit line sits BELOW its wipe, in the HUD strip.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a             ; and the HUD has to come back

    ret


; ----------------------------------------------------------------------------
;  title_draw -- the whole screen
;  Uses: everything
; ----------------------------------------------------------------------------
title_draw:
    ;  All 200 lines, not just the tactical area: the credit line lives in
    ;  the strip the HUD normally owns, and the HUD is not up yet.
    ld bc,#0000
    ld d,SCR_BYTES_PER_LINE
    ld e,SCR_HEIGHT_PX
    xor a
    call scr_fill_rect

    ld hl,title_text
    ld c,TITLE_Y
    call txt_big

    ;  One call a game frame. It writes no PSG register -- it fills the three
    ;  voice blocks and lets snd_update do what it already does -- and it
    ;  advances by the number of 50 Hz TICKS that have gone by, so the tempo is
    ;  right whatever this screen's frame rate happens to be. Which matters
    ;  here more than anywhere: the planet took it from 3.45 fps to 2.30.
    call mus_update

    call title_draw_stars
    ;  Between the two on purpose: the planet blacks its own interior, so it
    ;  has to go down after the stars to take out the ones inside it, and
    ;  before the flight so the ships cross in FRONT of it.
    call title_draw_planet
    call title_draw_ships

    ;  The prompt blinks. The whole screen is repainted every frame anyway, so
    ;  "blink" is just declining to draw it on half the frames -- no erase, no
    ;  dirty rectangle, six instructions. demo_frames counts GAME frames, so
    ;  bit 2 is about four of them either way: a little under a second on and
    ;  a little under a second off.
    ld a,(demo_frames)
    and TITLE_BLINK_BIT
    jr z,@title_no_prompt
    ld hl,title_prompt
    ld b,TITLE_PROMPT_X
    ld c,TITLE_PROMPT_Y
    call txt_draw
@title_no_prompt:

    ;  ...and the tutorial, steady. See TITLE_TUT_Y for why it is here at all
    ;  and why it does not blink.
    ld hl,title_tut
    ld b,TITLE_TUT_X
    ld c,TITLE_TUT_Y
    call txt_draw

    ld hl,title_credit
    ld b,TITLE_CREDIT_X
    ld c,TITLE_CREDIT_Y
IF DIAG_DISC
    call txt_draw
    ;  Last, so it wins over the stars and the flight it sits on. See
    ;  game/libdiag.asm for what the five lines say and how to turn it off.
    ld a,DIAG_TITLE_Y
    jp diag_draw
ELSE
    jp txt_draw
ENDIF


; ----------------------------------------------------------------------------
;  title_draw_stars -- the backdrop
;
;  GENERATED, not stored. Forty stars written out as (x, y, pixel) was 120
;  bytes of bank 4, and the bank has none -- but the objection the table was
;  there to answer was TWINKLING, and twinkling comes from randomness, not
;  from arithmetic. A xorshift reseeded to the same constant at the top of
;  every frame lays the same forty stars down every frame, so the field is as
;  still as the table was.
;
;  Pen 2 is %10, so a star sets its pixel's bit in the LOW nibble and nothing
;  in the high one -- the mask is that bit, ready to be poked straight in.
;  Uses: everything
; ----------------------------------------------------------------------------
TITLE_STAR_SEED     equ #A17C           ; picked by looking at the result
TITLE_STAR_TOP      equ 56              ; clear of the big letters above
TITLE_STAR_BAND     equ 127             ; ...and short of the credit line below

title_draw_stars:
    ld hl,TITLE_STAR_SEED
    ld (title_rng),hl
    ld a,TITLE_STARS
    ld (title_left),a

@title_star:
    ;  x, in bytes: 0..79 out of a byte by subtracting the width off three
    ;  times. The tail above 240 lands in the left fifth twice as often, which
    ;  is a scatter and not a pattern.
    call title_rand
    call title_mod80
    ld c,a

    call title_rand
    push af
    and TITLE_STAR_BAND
    add a,TITLE_STAR_TOP
    ld l,a                              ; hmm: scr_line_addr wants A
    ;  the pixel within the byte, from the two bits x did not use
    pop af
    rlca
    rlca
    and 3
    ld b,1
@title_star_shift:
    or a
    jr z,@title_star_placed
    sla b
    dec a
    jr @title_star_shift
@title_star_placed:
    ld a,l
    push bc

    call scr_line_addr                  ; HL = the line; BC survives
    pop bc
    ld a,l
    add a,c
    ld l,a
    jr nc,@title_star_no_carry
    inc h
@title_star_no_carry:
    ld a,(hl)
    or b
    ld (hl),a

    ld a,(title_left)
    dec a
    ld (title_left),a
    jr nz,@title_star
    ret


;  A = A mod 80, near enough
;  Uses: AF
title_mod80:
    cp SCR_BYTES_PER_LINE
    ret c
    sub SCR_BYTES_PER_LINE
    cp SCR_BYTES_PER_LINE
    ret c
    sub SCR_BYTES_PER_LINE
    cp SCR_BYTES_PER_LINE
    ret c
    sub SCR_BYTES_PER_LINE
    ret


;  A = the next byte of the scatter.
;  Uses: AF, HL
;
;  The STEP is sys_rand_step, in the low 16K, shared with the attack waves. The
;  STATE is this file's own and must stay that way: the loop above reseeds it to
;  a constant at the top of every frame so the starfield does not twinkle, which
;  is the exact opposite of what game/waves.asm needs from the same eight
;  instructions. Sharing the word would make every campaign send the same waves.
title_rand:
    ld hl,(title_rng)
    call sys_rand_step
    ld (title_rng),hl
    ret


; ----------------------------------------------------------------------------
;  title_draw_planet -- the homeplanet, ahead of the flight
;
;  The game is named after it and it was not on the screen. It sits to the
;  right of the title, in the gap between the big letters (which end at line
;  52) and the prompt (which starts at 160), and the two right-hand ships of
;  the flight cross it -- so it is what they are flying towards rather than a
;  decoration in a corner.
;
;  A DARK DISC WITH A LIT LIMB, and both halves of that are decided by what
;  each edge costs to draw.
;
;      the INTERIOR is black, filled by scr_fill_rect at BYTE granularity --
;      four pixels at a time, ~200 T a row. The quantisation is invisible
;      because the fill is rounded INWARD and the rim is drawn over the top of
;      where it stops: nothing the eye can see is on a byte boundary.
;
;      the LIMB is pixel-exact, through gfx_vline one dot at a time. A Mode 1
;      fill can only write four pixels, and a circle quantised to four pixels
;      at this radius is a visible staircase -- which is exactly what a limb
;      must not be, because the limb IS the shape.
;
;  So the expensive primitive is spent only where it shows.
;
;  WHAT IT COSTS, MEASURED RATHER THAN COUNTED: this screen goes from 3.45 fps
;  to 2.30 -- DEMO_FRAMES over 1000 emulator frames, both builds -- so the
;  planet is about a third of a title frame, or 580,000 T-states. That is an
;  order of magnitude more than a hand count of the ~820 gfx_vline calls
;  suggests, which is the usual lesson about hand counts on this machine.
;
;  It is affordable because this screen does nothing else and is not the frame
;  loop; it is not free, and TITLE_BLINK_BIT had to move with it. Anything
;  further would mean giving the limb its own inner loop -- the dots on a row
;  are contiguous, so one byte address and a mask per row would do the work of
;  ten calls -- and that is the first place to look if the title ever needs to
;  be quicker.
;
;  WHY NOT A LIT CRESCENT. A terminator is a second ellipse and the region
;  between the two is a horizontal run per row, which at pixel granularity is
;  ~1,700 dots -- four times the whole rest of this -- and at byte granularity
;  puts a four-pixel staircase down the middle of the disc. A planet in
;  eclipse needs neither, and section 2's palette already means "scenery" by
;  ink 2, which is what a limb is.
;
;  It is an ELLIPSE and not a circle because a Mode 1 pixel is not square: the
;  screen is 320x200 across a 4:3 display, so a pixel is 0.83 of a line, and a
;  disc that reads as round wants its horizontal radius about 1.2x its
;  vertical one. 41 and 34.
;  Uses: everything
; ----------------------------------------------------------------------------
TITLE_PLANET_CX     equ 250             ; pixels, 0..319
TITLE_PLANET_CY     equ 118             ; lines
TITLE_PLANET_RX     equ 41
TITLE_PLANET_RY     equ 34

;  Ink 2. Section 2 gives it to the stars and the reference grid -- it is the
;  ink this game means SCENERY by, and a planet is the scenery. Ink 1 is the
;  fleet and the text, so a white limb would read as something of ours; ink 3
;  is the alarm ink and a world is not an alarm.
TITLE_PLANET_PEN    equ 2

;  Half the disc's width, in PIXELS, one entry per line from the equator to
;  the pole:
;
;      hw[dy] = round(RX * sqrt(1 - (dy / RY)^2))
;
;  Hand-written rather than generated, because it is 35 bytes and adding a
;  third generated file to carry them would cost more than they do -- but the
;  formula above is the specification and tests/test_title.py re-derives every
;  entry from it and compares against the bank, which is how gen/tables.asm is
;  checked as well.
title_planet_hw:
    defb  41,  41,  41,  41,  41,  41,  40,  40,  40
    defb  40,  39,  39,  38,  38,  37,  37,  36,  36
    defb  35,  34,  33,  32,  31,  30,  29,  28,  26
    defb  25,  23,  21,  19,  17,  14,  10,   0
;  ONE ENTRY PAST THE POLE, and it is not padding. game/homeplanet.asm reads
;  this table at four times the size -- one entry every four rows -- and
;  INTERPOLATES between an entry and the one after it, so the last row of the
;  shape asks for the entry after the last. It is zero because the pole is, so
;  the curve closes on it rather than on whatever byte follows the table.
    defb   0

title_draw_planet:
    ld hl,TITLE_PLANET_CX
    ld (planet_cx),hl
    ld a,TITLE_PLANET_CY
    ld (planet_cy),a

;  ...and the same ellipse anywhere: game/gameover.asm draws it at the middle
;  of its own screen with fires on it, which is the same world this one is
;  flying towards and is the point of sharing the routine rather than a saving.
;  The radii and the half-width table are shared too; only the centre moves.
planet_draw:
    ld a,TITLE_PLANET_PEN
    ld (planet_pen),a

    ;  gfx_vline clips against the viewport, and the viewport is the game's
    ;  rather than this screen's. Opened here and PUT BACK before returning,
    ;  for the reason spelled out over title_draw_ships -- which does the same
    ;  thing for the same reason, and doing it in title_key instead does not
    ;  work.
    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    xor a
    ld (spr_clip_top),a

    ;  prev is the previous row's half-width, so that the rim can be drawn as
    ;  the RUN between one row and the next rather than as a dot per row. At
    ;  the poles the curve is shallow and hw falls by ten in a line; a dot per
    ;  row would leave the top and bottom of the planet as a dotted arc with
    ;  nine-pixel gaps in it. At dy = 0 there is no previous row and prev is
    ;  hw, which makes the run one dot -- the equator's own extreme point.
    ld a,TITLE_PLANET_RX
    ld (title_planet_prev),a
    xor a
    ld (title_planet_dy),a

@tp_row:
    ld a,(title_planet_dy)
    ld e,a
    ld d,0
    ld hl,title_planet_hw
    add hl,de
    ld a,(hl)
    ld (title_planet_hw_now),a

    call title_planet_fill
    call title_planet_rim

    ld a,(title_planet_hw_now)
    ld (title_planet_prev),a
    ld hl,title_planet_dy
    inc (hl)
    ld a,(hl)
    cp TITLE_PLANET_RY + 1
    jr c,@tp_row

    ld a,HUD_TOP                        ; the strip belongs to the HUD again
    ld (spr_clip_bottom),a
    ld a,CTX_BAR_H                      ; ...and the top one to the context bar
    ld (spr_clip_top),a
    ret


; ----------------------------------------------------------------------------
;  title_planet_fill -- this row's interior, black, in whole bytes inside the rim
;
;  Rounded INWARD at both ends: the first whole byte at or after the left edge
;  and the last whole byte at or before the right one. So the fill can never
;  eat the limb that is about to be drawn, and where it stops short the rim's
;  own dots cover the gap. scr_fill_rect honours no clip of its own -- it takes
;  an explicit x and width and writes them -- and src/main.asm asserts that
;  this disc's bytes are inside the screen, which is why nothing is cut here.
; ----------------------------------------------------------------------------
title_planet_fill:
    ld a,(title_planet_hw_now)
    ld c,a
    ld b,0

    ;  THE NIGHT SIDE ROUNDS OUTWARD AND THE DAY SIDE ROUNDS INWARD, and the
    ;  asymmetry is the whole of what makes this look right.
    ;
    ;  Black is free to spill: outside the disc is black too, so a fill that
    ;  overshoots the limb by up to three pixels costs nothing and BUYS the one
    ;  thing an inward-rounded fill cannot -- every star inside the planet gone,
    ;  right up to the edge, rather than a three-pixel band against the limb
    ;  where one may or may not happen to be. The rim goes down afterwards, so
    ;  the spill cannot eat it.
    ;
    ;  Be honest about the size of that: the field is forty stars over the
    ;  whole screen and the band is a tenth of one, so this is insurance and
    ;  not a repair -- tests/test_title.py says the same thing and says why it
    ;  cannot demonstrate it. The starlight that WAS visible is on the day
    ;  side, and what fixes it is the run at the end of title_planet_rim.
    ;
    ;  Ink 2 has no such freedom: three pixels of blue outside the limb is three
    ;  pixels of ragged silhouette, and the silhouette is the shape. So the day
    ;  side stops at the last whole byte inside, and the thin dark line left
    ;  between it and the limb reads as the edge of a world.
    ;
    ;  left = (cx - hw) >> 2, the first byte at or before the left edge
    ld hl,(planet_cx)
    or a
    sbc hl,bc
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (title_planet_x0),a

    ;  right = (cx + hw + 4) >> 2, the first byte at or after the right one.
    ;  In HL: cx + hw + 4 is 295 at the equator, which does not fit the byte an
    ;  `add a,c` would use.
    ld hl,(planet_cx)
    inc hl
    inc hl
    inc hl
    inc hl
    add hl,bc
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld hl,title_planet_x0
    sub (hl)
    jr z,@tp_lit
    jr c,@tp_lit
    ld d,a                              ; D = width in bytes
    ld b,(hl)                           ; B = x in bytes
    ld a,SOLID_INK_0
    call title_planet_span

    ;  ...and now the day side, over the top of it. The terminator of a lit
    ;  sphere is an ellipse of the same height and a narrower width, so it comes
    ;  out of the SAME table with one shift -- and the shift is what decides the
    ;  PHASE. At hw >> 1 the terminator is twenty pixels off centre at the
    ;  equator and nothing at the poles, which is twenty pixels of visible
    ;  curve; at hw >> 2 it was ten, and ten pixels of curve over sixty-eight
    ;  lines is a straight line with two steps in it. Past the centre, so the
    ;  planet is gibbous rather than a crescent: a crescent reads as a moon.
    ;
    ;  A four-pixel staircase down the terminator, and this is the one place in
    ;  this drawing where byte granularity is affordable -- a terminator is a
    ;  soft edge and the eye does not measure it. The LIMB is the shape and it
    ;  is drawn a pixel at a time; see the head of title_draw_planet.
@tp_lit:
    ld a,(title_planet_hw_now)
    ld c,a
    ld b,0
    ld hl,(planet_cx)
    inc hl
    inc hl
    inc hl
    or a
    sbc hl,bc
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (title_planet_x0),a              ; the day side's own left, rounded IN

    srl c                               ; the terminator, at hw >> 1
    ld hl,(planet_cx)
    inc hl
    add hl,bc
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (title_planet_x1),a              ; ...where the fill stops, for the rim
    ld hl,title_planet_x0
    sub (hl)
    jr z,@tp_no_day
    jr c,@tp_no_day
    ld d,a
    ld b,(hl)
    ld a,SOLID_INK_2
    jp title_planet_span

;  A row with no day side at all -- the last few before the pole. x1 is zeroed
;  rather than left standing, because the rim reads it to finish the terminator
;  and would otherwise put three pixels of daylight on a row that has none.
;  No real x1 is ever 0: the disc starts at byte 52.
@tp_no_day:
    xor a
    ld (title_planet_x1),a
    ret


; ----------------------------------------------------------------------------
;  title_planet_span -- one run of bytes, on this row and on its mirror
;  In : B = x in bytes, D = width in bytes, A = the fill byte
;  Uses: everything
; ----------------------------------------------------------------------------
title_planet_span:
    ld (title_planet_ink),a
    ld a,(planet_cy)
    ld hl,title_planet_dy
    sub (hl)
    ld c,a                              ; C = the row above the equator
    ld e,1
    push bc
    push de
    ld a,(title_planet_ink)
    call scr_fill_rect
    pop de
    pop bc

    ld a,(planet_cy)
    ld hl,title_planet_dy
    add a,(hl)
    ld c,a                              ; ...and the mirror below it
    ld e,1
    ld a,(title_planet_ink)
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  title_planet_rim -- the limb, from the previous row's half-width to this one
;
;  Four dots a column: left and right of centre, above and below the equator.
;  At dy = 0 the two rows are the same line and the dot is drawn twice, which
;  costs two hundred T-states once and saves a special case.
; ----------------------------------------------------------------------------
title_planet_rim:
    call planet_rim_run
    jr @tp_rim_repairs

;  planet_rim_run -- one row's worth of limb, all four quadrants
;  In : title_planet_prev, title_planet_hw_now, title_planet_dy, planet_cx/cy
;  Uses: everything
planet_rim_run:
    ld a,(title_planet_prev)
    ld hl,title_planet_hw_now
    sub (hl)
    inc a
    ld b,a                              ; B = columns in this run
    ld c,(hl)                           ; C = dx, from this row's half-width out

@tp_col:
    push bc
    ld b,0
    ld hl,(planet_cx)
    add hl,bc
    call title_planet_dot               ; ...the right-hand limb

    pop bc
    push bc
    ld hl,(planet_cx)
    ld a,l
    sub c
    ld l,a
    ld a,h
    sbc a,0
    ld h,a
    call title_planet_dot               ; ...and the left

    pop bc
    inc c
    djnz @tp_col
    ret

;  The repairs below belong to the LIT planet and read title_planet_x0/x1,
;  which only title_planet_fill sets -- so the in-game limb calls
;  planet_rim_run above and never gets here. Splitting them is what stops
;  game/homeplanet.asm being a second copy of that loop.
@tp_rim_repairs:
    ;  ...and then close the gap the day side leaves against the limb. Its fill
    ;  stops at the last WHOLE byte inside the disc, so between that byte and
    ;  the limb there are nought to three pixels of nothing -- which read as a
    ;  ring standing off the planet rather than as its edge. Those three pixels
    ;  are the same ink as the limb and the limb is what they belong to, so the
    ;  rim draws them: this is the run from the limb inward to where the fill
    ;  begins, and it is why the day side may round inward without paying for
    ;  it.
    ;
    ;  n = 4 * x0 - (cx - hw), and it is 0..3 by construction: x0 is
    ;  floor((cx + 3 - hw) / 4), so four times it is at least cx - hw and at
    ;  most three past it.
    ld a,(title_planet_x0)
    add a,a
    add a,a                             ; the first lit pixel
    ld c,a
    ld a,(planet_cx)
    ld hl,title_planet_hw_now
    sub (hl)                            ; the limb, cx - hw
    ld b,a
    ld a,c
    sub b
    ret z
    ret c
    ld c,b                              ; C = x, from the limb inward
    ld b,a                              ; B = how many pixels of gap

@tp_gap:
    push bc
    ld l,c
    ld h,0
    call title_planet_dot
    pop bc
    inc c
    djnz @tp_gap

;  ...and the same repair at the other end of the day side, where the fill
;  stops short of the TERMINATOR. Without it the terminator is a staircase of
;  whole bytes -- four pixels a step, three or four steps down the face -- and
;  it is the second largest thing on this screen, so the eye goes straight to
;  it. These are the nought to three pixels between the last filled byte and
;  where the terminator really falls.
;
;  Both ends are done in HL: 4 * x1 reaches 268 and cx + 1 + (hw >> 1) reaches
;  271, and neither fits the byte an 8-bit subtract would use.
title_planet_term:
    ld a,(title_planet_x1)
    or a
    ret z                               ; this row has no day side
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    push hl                             ; the first pixel past the fill

    ld a,(title_planet_hw_now)
    srl a
    ld c,a
    ld b,0
    ld hl,(planet_cx)
    inc hl
    add hl,bc
    pop de
    or a
    sbc hl,de                           ; ...how far short the fill stopped
    ld a,l
    or a
    ret z
    ld b,a

@tp_term:
    push bc
    push de
    ld h,d
    ld l,e
    call title_planet_dot
    pop de
    inc de
    pop bc
    djnz @tp_term
    ret


;  One column of the rim, both sides of the equator. gfx_vline uses every
;  register, so the x goes through memory rather than being held.
title_planet_dot:
    ;  OFF THE SIDE OF THE SCREEN IS NOT NOTHING. gfx_vline clips in Y only, so
    ;  an x past 319 lands on the next scanline down and an x below zero on the
    ;  previous one -- the limb wraps round and a planet sitting at the right
    ;  edge draws a second arc down the LEFT of the screen, which nothing then
    ;  erases because the erase box is over on the right where the planet is.
    ;  Found by looking; the counts said the right edge was clean.
    ;
    ;  One unsigned compare does both ends: a negative x is a very large one.
    ld de,SCR_WIDTH_PX
    push hl
    or a
    sbc hl,de
    pop hl
    ret nc

    ld (title_planet_x),hl

    ld a,(planet_cy)
    ld hl,title_planet_dy
    sub (hl)
    ld c,a
    ld hl,(title_planet_x)
    ld b,1
    ld a,(planet_pen)
    call gfx_vline

    ld a,(planet_cy)
    ld hl,title_planet_dy
    add a,(hl)
    ld c,a
    ld hl,(title_planet_x)
    ld b,1
    ld a,(planet_pen)
    jp gfx_vline


; ----------------------------------------------------------------------------
;  title_draw_ships -- a flight crossing the middle of the screen
;
;  The real sprites out of the bank, blitted by the real blitter. Nothing is
;  drawn for the title that the game does not already own.
;  Uses: everything
; ----------------------------------------------------------------------------
title_draw_ships:
    ;  Open the clip to the whole screen so the flight can sit anywhere, and
    ;  put it BACK before returning. Restoring it in title_key instead does
    ;  not work: title_key only clears the flag, and the frame loop goes on
    ;  to call title_draw one last time in the same frame -- which re-opened
    ;  it, permanently. The tactical view then drew over the HUD and the
    ;  dirty-rectangle erase rubbed it out again, so the strip came and went
    ;  with whatever happened to be flying low.
    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    xor a
    ld (spr_clip_top),a                 ; ...both ends, and both put back below
    ld (spr_enemy),a

    ld hl,title_ship_table
    ld a,TITLE_SHIPS
    ld (title_left),a

@title_ship:
    ld e,(hl)                           ; x, signed, low byte
    inc hl
    ld d,(hl)
    inc hl
    ld (spr_x),de
    ld e,(hl)                           ; y
    inc hl
    ld d,0
    ld (spr_y),de
    ld e,(hl)                           ; the sprite block
    inc hl
    ld d,(hl)
    inc hl
    ld (spr_src),de
    ld a,(hl)                           ; width in bytes
    inc hl
    ld (spr_w),a
    ld a,(hl)                           ; height
    inc hl
    ld (spr_h),a
    ld a,(hl)                           ; ...and which bank it lives in
    inc hl

    push hl
    ;  NOT spr_blit. This routine runs from bank 4 and the art is in 5 and 6,
    ;  so the paging has to happen on the other side of a CALL -- see
    ;  spr_blit_banked.
    call spr_blit_banked
    pop hl

    ld a,(title_left)
    dec a
    ld (title_left),a
    jr nz,@title_ship

    ld a,HUD_TOP                        ; the strip belongs to the HUD again
    ld (spr_clip_bottom),a
    ld a,CTX_BAR_H                      ; ...and the top one to the context bar
    ld (spr_clip_top),a
    ret


; ============================================================================
;  State
; ============================================================================
title_shown:        defb 0
title_left:         defb 0
title_rng:          defw 0

;  WHERE THE PLANET IS. Two screens draw the same ellipse out of the same
;  table -- the title's and the game-over screen's -- so the centre is a
;  variable. The radii are not: they are the shape of the half-width table.
;
;  A `planet_lit` flag was written first, so the game-over world could be dark
;  with only its fires showing. Looked at, that read as a hollow ring with red
;  specks in it -- the interior is black and the limb is one pixel, so nothing
;  says it is a body at all. Lit, it is unmistakably the same world the title
;  shows, now burning, which is a better picture AND a better story. The flag
;  went with it: nothing used it, and an untested branch is worse than none.
planet_cx:              defw 0
planet_cy:              defb 0

;  One row of the planet. All of it belongs to a single pass of
;  planet_draw and none of it survives the call.
title_planet_dy:        defb 0
;  THE PEN IS A VARIABLE because game/homeplanet.asm draws this same limb in
;  black to rub out where it was last frame. Whoever changes it puts it back,
;  the same contract txt_set_pen has -- and planet_draw is the one that does.
;
;  DOWN HERE WITH THE REST OF THE STATE, and not next to planet_draw where it
;  was written first: title_draw_planet FALLS THROUGH into planet_draw, so a
;  defb between them is not a variable, it is an instruction. #02 is LD (BC),A,
;  and the title screen never came up again.
planet_pen:         defb TITLE_PLANET_PEN

title_planet_hw_now:    defb 0
title_planet_prev:      defb 0
title_planet_x0:        defb 0
title_planet_x1:        defb 0
title_planet_ink:       defb 0
title_planet_x:         defw 0
