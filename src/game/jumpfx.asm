; ============================================================================
;  game/jumpfx.asm -- the jump: a line sweeps the ships away, and back
; ============================================================================
;  "Θέλω εφέ για το jump των πλοίων. Θα εμφανίζεται μια γραμμή στην μια πλευρά
;  τους που θα μετακινείται μέχρι την άλλη, σβήνοντάς τα. Στην επόμενη πίστα θα
;  συμβαίνει το ανάποδο για να εμφανιστούν."
;
;  A vertical line appears at the left of the playfield and travels to the
;  right, erasing everything as it passes. Arriving in the next mission, the
;  same line travels the same way and the mission appears behind it.
;
;  A MOVING MASK, NOT A COPY
;  -------------------------
;  The obvious reveal is to draw the new mission into the back buffer and copy
;  it across column by column from behind the line. This does not do that. A
;  column of a CPC screen is 158 unrelated addresses -- the rows are
;  interleaved eight ways -- so a copy goes through scr_line_addr per row
;  whatever it is copying, and it buys nothing here: the frame loop is ALREADY
;  drawing the whole mission every frame. What is wanted is not a picture, it
;  is a way of hiding part of one.
;
;  THE TWO HALVES ARE DRIVEN DIFFERENTLY, AND THAT IS THE FIRST REAL DECISION
;  -------------------------------------------------------------------------
;  The vanish has nothing left to draw: the picture it is erasing is already on
;  the screen and no more of it is coming. So it runs as its own loop with its
;  own VSYNC and its own page flip, at 25 steps a second, and crosses in about
;  four fifths of a second. That also keeps mis_jump ATOMIC, which is worth
;  more than it looks: a dozen tests and both measuring tools press `J` and
;  read mis_index straight afterwards.
;
;  The reveal cannot. It is uncovering a world that does not exist until the
;  frame loop draws it, so it steps once a GAME frame -- five a second -- and
;  its step is correspondingly coarser. There is no arrangement of masks that
;  makes it smoother: a receding mask has to put back what it covered, and the
;  only place that picture exists is the frame loop's own output.
;
;  Nobody sees the two together -- the briefing screen sits between them -- so
;  the asymmetry costs nothing on screen and it saves the campaign from having
;  to carry a half-finished jump across frames.
;
;  WHAT EACH HALF ACTUALLY BLACKENS, WHICH IS THE SECOND DECISION
;  -------------------------------------------------------------
;      vanishing -- the strip the line has just crossed, and nothing else.
;                   Nothing is redrawing behind it, so black stays black and
;                   each step pays only for the columns it has just taken.
;      appearing -- the DIRTY RECTANGLES this frame drew ahead of the line.
;                   The screen out there is already black; the only thing on it
;                   is what the frame loop has just put there, and the list of
;                   where it put it is the one phase4_erase uses. Blacking the
;                   whole area instead is the obvious version and it cost four
;                   50 Hz ticks a frame -- 5.0 fps down to 3.5 -- on a sweep
;                   that can only step once a frame. See jfx_update.
;
;  WHAT IT DOES NOT TOUCH
;  ----------------------
;  The playfield only, CTX_BAR_H..HUD_TOP. The context bar and the HUD are the
;  instruments and not the view; they are also repainted from dirty flags
;  rather than every frame, so including them would mean setting those flags
;  and paying for two full strip repaints in the middle of a transition. The
;  band is exactly the one a ship may be drawn in, which is what makes "erasing
;  them as it passes" true rather than approximately true.
;
;  Ink 1, section 2's ink for the fleet itself and for anything the game says
;  in its own voice. Ink 3 is the alarm ink and a jump is not an alarm; ink 2
;  is scenery, and the line is not part of the world -- it is the fleet's own
;  drive going off. White on black is also the strongest edge there is, which
;  is what makes a wipe read as a wipe.
;
;  LEFT TO RIGHT BOTH TIMES, and the reveal repeats the vanish rather than
;  mirroring it. A mirrored sweep reads as an undo -- the curtain coming back
;  the way it went -- and section 10's campaign only goes one way: what is lost
;  is lost and the fleet never returns to a system it has left. The same line
;  passing the same way says the fleet went through rather than back.
;
;  BOTH HALVES STOP THE WORLD, and the reveal has to. The vanish gets it for
;  free -- it runs inside mis_jump, and there is nothing left to run. The
;  reveal was an overlay first, with the battle live behind it, and that is a
;  BALANCE change rather than a visual one: it is about two seconds long and
;  the campaign has seven jumps in it, so a fleet would fight fourteen seconds
;  the player never saw. tools/balance.py would have printed a different
;  campaign for a change that draws rectangles, and two combat tests that
;  assert "nobody has fired yet" opened their mission with six shots gone.
;  demo_update skips its whole simulation while jfx_mode is set, exactly as it
;  does for order_paused.
;
;  Bank 4, by the rule in game/shipclass.asm: the vanish runs from a keypress
;  with the world stopped, and jfx_update runs at the very end of a frame,
;  after ctx_bar, where nothing has paged bank 4 out. jfx_mode, jfx_col and
;  jfx_armed are in the low 16K with the rest of the campaign's state, in
;  game/mission.asm, so tests can read them without waiting for the window to
;  come back to rest.
; ----------------------------------------------------------------------------

;  Which way the line is going. NOT called JFX_VANISH and JFX_REVEAL: RASM is
;  case-insensitive, so either would be the same symbol as the routine below it
;  and the build stops with "there is already an alias with the same name".
JFX_NONE            equ 0
JFX_OUT             equ 1               ; sweeping the old mission away
JFX_IN              equ 2               ; uncovering the new one

;  The band the sweep owns: exactly the playfield.
JFX_TOP             equ CTX_BAR_H
JFX_HEIGHT          equ HUD_TOP - CTX_BAR_H
JFX_WIDTH           equ SCR_BYTES_PER_LINE

;  How far the line moves in one step, in BYTES of the 80 across the screen.
;  Both have to divide 80 or the last step runs off the end of the line, and
;  src/main.asm asserts it.
;
;  THE VANISH steps once per VSYNC it can catch, and it catches every second
;  one: a step is two fills over 158 rows, and the per-row half of that -- a
;  scr_line_addr and the address arithmetic, ~130 T-states a row -- is most of
;  the ~22 milliseconds it takes, which is just over a 50 Hz tick. So it runs
;  at 25 steps a second whatever the step is, and four bytes is what makes
;  twenty of them cross the screen in four fifths of a second. Two bytes is
;  visibly smoother and takes twice as long; sixteen pixels at 25 Hz already
;  reads as one moving edge rather than as a row of lines.
;
;  THE REVEAL steps once a GAME frame, and the game runs at about five of
;  those a second. There is no cheaper coin to pay in -- it is uncovering what
;  the frame loop draws, so it cannot go faster than the frame loop -- and ten
;  bytes is eight steps and about a second and three quarters.
JFX_VANISH_STEP     equ 4
JFX_REVEAL_STEP     equ 10

JFX_INK             equ SOLID_INK_1


; ----------------------------------------------------------------------------
;  jfx_vanish -- sweep the mission away, before anything else happens
;
;  Called from mis_jump once it has decided the jump goes ahead and BEFORE it
;  touches anything, so what the line erases is the mission the player is
;  leaving rather than a half-built next one.
;
;  IT DOES ITS OWN DOUBLE BUFFERING, and that is not gold plating -- the first
;  version painted straight into the buffer on show and the line came apart on
;  the screen. It has to be rubbed out and put down again four bytes over, and
;  the two fills take longer than a 50 Hz frame, so the display caught the line
;  half-erased about as often as it caught it whole: a shimmering broken bar
;  rather than a moving one. Screenshots of the sweep are what showed it, and
;  no test would have.
;
;  So each step paints the BACK buffer, waits for the vertical blank and flips,
;  exactly as the frame loop does. Which means the back buffer is two steps
;  behind rather than one -- it is the one that was on screen a step ago -- so
;  the black has to cover TWO steps' worth of columns, including the line that
;  buffer is still holding. That is the only difference between this and the
;  obvious version, and it is cheaper: 2*STEP + 1 columns a step against the
;  4 * (STEP + 1) that painting both buffers by hand cost.
;
;  The two extra passes at the end are the price of being two behind: when the
;  line has run off the right-hand edge, one buffer is still holding the last
;  two steps' worth of the mission, and the screen has to be black in BOTH
;  before the briefing lands on it -- the frame loop's own flip is still to
;  come at the end of this frame.
;  Uses: everything
; ----------------------------------------------------------------------------
jfx_vanish:
    ld a,JFX_OUT
    ld (jfx_mode),a
    ;  ...and the note for the other half. The briefing this jump is about to
    ;  put up is the one the reveal belongs to; every other briefing in the
    ;  game gets none.
    ld (jfx_armed),a
    xor a
    ld (jfx_col),a
    ld a,JFX_WIDTH / JFX_VANISH_STEP + 2
    ld (jfx_left),a

@jfx_sweep:
    ;  Black over the two steps' worth of columns behind the line -- which is
    ;  everything this buffer has not caught up on, and includes the line it
    ;  put down two steps ago. Clamped at the left-hand edge, where the sweep
    ;  has not yet come far enough to have two steps behind it.
    ld a,(jfx_col)
    ld d,a                               ; ...so all of it, from column 0
    sub JFX_VANISH_STEP * 2
    jr c,@jfx_from_edge
    ld b,a
    ld d,JFX_VANISH_STEP * 2
    jr @jfx_black
@jfx_from_edge:
    ld b,0
@jfx_black:
    xor a
    call jfx_bar_one

    ;  ...and the line at the leading edge, until it has left the screen.
    ld a,(jfx_col)
    cp JFX_WIDTH
    jr nc,@jfx_no_line
    call jfx_line_args
    call jfx_bar_one
@jfx_no_line:

    call scr_wait_vsync
    call scr_flip

    ld hl,jfx_col
    ld a,(hl)
    cp JFX_WIDTH
    jr nc,@jfx_at_edge                   ; parked, for the two catch-up passes
    add a,JFX_VANISH_STEP
    ld (hl),a
@jfx_at_edge:
    ld hl,jfx_left
    dec (hl)
    jr nz,@jfx_sweep

    xor a
    ld (jfx_mode),a
    ret


; ----------------------------------------------------------------------------
;  jfx_reveal_open -- start the reveal, if a jump is what put the briefing up
;
;  Called from mis_brief_key, which does not know how its briefing was opened
;  -- so jfx_vanish leaves the note. THE REVEAL IS THE SECOND HALF OF A JUMP
;  and belongs to jumps: mission 1 is reached from the title screen and a
;  restored campaign is reached from the disc, and neither of those has had a
;  line sweep anything away for this one to give back.
;
;  It was armed on every briefing first, on the argument that an arrival is an
;  arrival. That is defensible on screen and it was wrong underneath: every
;  boot_quick in the suite dismisses the opening briefing, so every test in the
;  project started life with two seconds of half-masked playfield, and seven
;  that read pixels failed -- the resource patches, the Mothership indicator,
;  the enemy recolour. None of them was about jumps. An effect that only the
;  jump can trigger is also an effect only the jump's own tests have to know
;  about.
;  Uses: AF
; ----------------------------------------------------------------------------
jfx_reveal_open:
    ld a,(jfx_armed)
    or a
    ret z
    xor a
    ld (jfx_armed),a
    ld a,JFX_IN
    ld (jfx_mode),a
    xor a
    ld (jfx_col),a
    ret


; ----------------------------------------------------------------------------
;  jfx_update -- one step of the reveal, at the very end of a drawn frame
;
;  Called from demo_update after ctx_bar, on the playing path only: a
;  full-screen page owns the whole screen and suspends the sweep, which resumes
;  where it left off when the page closes.
;
;  ONE BUFFER, not both, and that is right rather than lazy here: the frame
;  loop redraws the whole playfield of whichever buffer it is holding, every
;  frame, so the mask has to go down after every draw and never has to survive
;  one. The flip then shows whichever buffer was drawn last, so what is on
;  screen is always this frame's step, and the other buffer sits one step
;  behind waiting to be redrawn from scratch.
;
;  AND IT MASKS THE DIRTY RECTANGLES, NOT THE SCREEN. The obvious mask is one
;  black fill from the line to the right-hand edge, which is what this did
;  first and what it cost: at the opening step that is all 12,640 bytes of the
;  playfield, scr_fill_rect runs at about 35 T-states a byte with the gate
;  array taking its share, and the game frame went from 10 ticks to 14 --
;  measured, 5.0 fps to 3.5, on a sweep that can only step once a frame. The
;  whole sweep took 3.1 seconds.
;
;  But the screen ahead of the line is ALREADY black, every frame, except
;  exactly where this frame drew something -- and the list of places this frame
;  drew something is the one phase4_erase uses to clean the screen up. So the
;  mask is a second erase pass over that list, clipped to the far side of the
;  line: proportional to the ships on the screen instead of to the screen, and
;  it cuts a ship in half at the line for free, which a rectangle list gets
;  right and a "skip the whole sprite" test would not.
;  Uses: everything
; ----------------------------------------------------------------------------
jfx_update:
    ld a,(jfx_mode)
    cp JFX_IN
    ret nz                               ; idle, or the vanish's own loop

    ld a,(jfx_col)
    cp JFX_WIDTH
    jr nc,@jfx_revealed

    ;  Take back everything this frame drew ahead of the line.
    call jfx_mask_rects

    ;  NOTHING ELSE WHILE THE SCREEN IS STILL BEING CLEARED. mis_wipe is two
    ;  frames of clearing sixteen thousand bytes and they are the two slowest
    ;  the game ever runs -- a fifth of a second each -- and they are the two
    ;  this sweep starts on, because the briefing schedules both on its way
    ;  out. Stepping through them spent a quarter of the sweep on them; drawing
    ;  the line on them left it standing still on screen for a second, which
    ;  looks like the game has hung rather than like a pause.
    ;
    ;  So those two frames are the black gap they always were, and the line
    ;  arrives on the first frame that has something to uncover. The MASK still
    ;  has to run on them -- each of them draws the whole mission after its
    ;  wipe, and letting that through shows the player exactly the thing the
    ;  line is supposed to be uncovering.
    ld a,(mis_wipe)
    or a
    ret nz

    ;  The line goes down AFTER the masking, or the mask would erase it: it
    ;  stands exactly on the boundary. It gets a dirty rectangle of its own,
    ;  which is the whole of how it is rubbed out when it moves -- the next
    ;  pass through this buffer erases it along with everything else.
    call jfx_line_args
    call jfx_bar_one
    ld a,(jfx_col)
    ld (jfx_line_rect),a
    ld hl,jfx_line_rect
    call phase4_add_rect

    ld hl,jfx_col
    ld a,(hl)
    add a,JFX_REVEAL_STEP
    ld (hl),a
    ret

;  One more frame with nothing masked at all, so the last step is a step and
;  not a jump: the frame before this one still had JFX_REVEAL_STEP columns
;  under black, and this is the one that lets them through.
@jfx_revealed:
    xor a
    ld (jfx_mode),a
    ret


; ----------------------------------------------------------------------------
;  jfx_mask_rects -- black out this frame's drawing, from the line rightwards
;  Uses: everything
;
;  phase4_erase's loop with a horizontal clip in it. Reading the list rather
;  than the screen is what makes the reveal cost about what an ordinary frame
;  costs; see the header of jfx_update. It only ever READS the list -- the
;  count and the append pointer belong to the frame -- so the rectangles it
;  blacks out are erased again in the ordinary way next time this buffer comes
;  round, and nothing has to be un-recorded.
;
;  Every rectangle here is inside the playfield already: spr_blit clips to
;  spr_clip_top/bottom and mark_store clamps, so there is no vertical case to
;  handle and the two strips cannot be reached from in here.
; ----------------------------------------------------------------------------
jfx_mask_rects:
    ld a,(phase4_rect_count)
    or a
    ret z
    ld b,a
    ld hl,(phase4_rects)

@jfx_rect:
    push bc
    ld a,(hl)                            ; x, in bytes
    inc hl
    ld c,(hl)                            ; y
    inc hl
    ld d,(hl)                            ; width, in bytes
    inc hl
    ld e,(hl)                            ; height, in lines
    inc hl
    push hl

    ld b,a
    ld a,(jfx_col)
    sub b
    jr c,@jfx_rect_fill                  ; starts past the line: all of it goes

    ;  A = how many byte columns of it are BEHIND the line and stay on screen.
    cp d
    jr nc,@jfx_rect_next                 ; all of it: the line has gone by
    neg
    add a,d                              ; ...so this much is still ahead
    ld d,a
    ld a,(jfx_col)
    ld b,a

@jfx_rect_fill:
    xor a
    call scr_fill_rect

@jfx_rect_next:
    pop hl
    pop bc
    djnz @jfx_rect
    ret


; ----------------------------------------------------------------------------
;  jfx_line_args -- where the line goes, for whichever fill is about to run
;  Out: B = jfx_col, D = 1, A = the ink
;  Uses: AF, B, D
; ----------------------------------------------------------------------------
jfx_line_args:
    ld a,(jfx_col)
    ld b,a
    ld d,1
    ld a,JFX_INK
    ret


;  In : B = x, D = width, A = fill.  scr_fill_rect returns at once if D is 0,
;  which is what makes "black behind a line standing at column 0" free.
;
;  C and E are not parameters: this effect owns the playfield and nothing else,
;  and the whole point of it is that it cannot reach the two strips.
jfx_bar_one:
    ld c,JFX_TOP
    ld e,JFX_HEIGHT
    jp scr_fill_rect


;  How many passes of the vanish are left, including the two catch-up ones.
jfx_left:
    defb 0

;  The line's own dirty rectangle -- x, y, width, height, in phase4_add_rect's
;  order. Only the x moves, so it is a patched byte rather than four stores.
jfx_line_rect:
    defb 0, JFX_TOP, 1, JFX_HEIGHT
