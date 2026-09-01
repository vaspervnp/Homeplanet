; ============================================================================
;  game/jumpfx.asm -- the jump: a bar per ship takes it away, and gives it back
; ============================================================================
;  "Θέλω εφέ για το jump των πλοίων. Θα εμφανίζεται μια γραμμή στην μια πλευρά
;  τους που θα μετακινείται μέχρι την άλλη, σβήνοντάς τα. Στην επόμενη πίστα θα
;  συμβαίνει το ανάποδο για να εμφανιστούν."
;
;  ...and then, once it had been seen: "θέλω η γραμμή του jump να μην είναι μία
;  για όλα. Να είναι μία ανά σκάφος. μικρή και να ξεκινάει πριν το σκάφος και
;  να τελειώνει μετά το σκάφος. Το ίδιο και στην είσοδο από το jump."
;
;  So there is no longer one bar crossing the playfield. Every ship on the
;  screen gets its OWN short bar, which starts a few pixels to its left, walks
;  across it, and stops a few pixels past its right-hand side. All of them move
;  together, so the vanish is as long as one ship is wide rather than as long as
;  the screen. Arriving in the next mission the same bars make the same walk and
;  the ships come out from behind them.
;
;  ...and then, once THAT had been seen: "Θέλω η ταχύτητα του jump in και του
;  jump out να είναι 10 φορές πιο αργή. Και ο ήχος να είναι αντίστοιχα τόσος."
;  So the vanish is 7.2 seconds where it was 0.70 and the reveal 17.1 where it
;  was 1.76, and the two sounds are the same lengths -- which took a prescaler
;  in sys/sound.asm, because a voice's timer is one byte and 300 and 880 do not
;  fit in it. Where the time actually goes is JFX_VANISH_DWELL, and the note
;  there is the one to read before changing any of this.
;
;  WHAT THE TRAVEL IS, WHICH IS THE WHOLE OF THE GEOMETRY
;  -----------------------------------------------------
;  A ship's sprite is class_geom's (width, height) for its size tier, placed by
;  phase4_blit_body at (sx - halfwidth, sy - halfheight). Every one of those
;  numbers is already in phase4_vis, the list phase4_project builds and
;  phase4_draw draws from, so nothing here re-projects anything: it reads the
;  frame that was last drawn.
;
;      x0     = the sprite's left byte column, minus JFX_MARGIN
;      reach  = the sprite's width in bytes, plus JFX_MARGIN at each end
;      band   = the sprite's rows, JFX_VMARGIN proud at top and bottom
;
;  jfx_col is how far along that run every bar is, in BYTE COLUMNS, and it is
;  ONE counter for the whole fleet. It is not one number per ship because it
;  does not have to be: the bar's position is x0 + col and x0 is a property of
;  the ship, so a shared step gives every bar the same speed and every ship its
;  own start and finish. A tier A ship is three bytes wide and a tier C one is
;  seven, so the small ships are done first and the capitals last, for free.
;
;  A BAR IS ONE BYTE WIDE and four pixels, exactly as the full-height line was.
;  It stands JFX_VMARGIN lines proud of the sprite at each end so that it reads
;  as a bar rather than as a fatter pixel: at tier A the sprite is six lines
;  tall and the bar is twelve.
;
;  WHAT EACH HALF BLACKENS
;  -----------------------
;      vanishing -- the whole band from x0 up to the bar, every step, not just
;                   the column just taken. The buffer being painted is the one
;                   that was on show a step ago, so it is still carrying its own
;                   bar and a ship that has only been half rubbed out; repainting
;                   the trail costs one fill either way because scr_fill_rect's
;                   per-row overhead dwarfs the bytes. One fill and a bar.
;      appearing -- everything in the band EXCEPT the part of the sprite the bar
;                   has already passed, which is precisely the part that is
;                   meant to be showing. That is four fills, and it is four
;                   rather than two because of the paragraph below.
;
;  Proportional to the ships on the screen rather than to the screen, which is
;  the point: a full-width fill every frame cost four 50 Hz ticks and took 5.0
;  fps to 3.5 on a sweep that can only step once a frame.
;
;  THE BAND AND THE SPRITE'S OWN ROWS ARE NOT THE SAME THING, AND THE REVEAL
;  HAS TO KNOW THE DIFFERENCE
;  ------------------------------------------------------------------------
;  A bar stands JFX_VMARGIN lines proud of its ship at each end. Nothing in the
;  reveal erases a bar directly -- the masking does it, by painting the band
;  black around wherever the bar has got to -- except in one place: the columns
;  the bar has ALREADY passed, which are the revealed part of the ship and must
;  not be painted at all. There, the eraser is phase4_erase and the ordinary
;  dirty rectangle, and a sprite's rectangle is the SPRITE, not the band.
;
;  So the two or three lines of the bar standing proud of the ship were left on
;  the screen, one little white block above and one below every ship in the
;  fleet, and nothing ever took them off again. It is exactly the trap
;  mark_store was fixed for -- drawing outside the rectangle you recorded --
;  arriving from the other side.
;
;  The reveal therefore blacks the rows ABOVE and BELOW the sprite across the
;  whole run, every step, and only the sprite's own rows are left to the
;  ordinary erase. Those two strips are JFX_VMARGIN lines each, so they cost
;  less than the band did.
;
;  WHAT IS NOT A SHIP
;  ------------------
;  The reference plane, the resource fields and the Mothership indicator have
;  no bar, because the owner asked for one per SHIP and because they are the
;  PLACE rather than the fleet -- section 4.1's grid is where the battle is,
;  and a place does not jump. So the vanish ends with two passes of black over
;  the playfield, one per buffer, which takes the scenery and guarantees that
;  both buffers are empty before the briefing lands on them; and the reveal
;  simply lets the grid arrive with the first drawn frame.
;
;  THE TWO HALVES ARE DRIVEN DIFFERENTLY, AND THAT IS THE FIRST REAL DECISION
;  -------------------------------------------------------------------------
;  The vanish has nothing left to draw: the picture it is erasing is already on
;  the screen and no more of it is coming. So it runs as its own loop with its
;  own VSYNC and its own page flip. That also keeps mis_jump ATOMIC, which is
;  worth more than it looks: a dozen tests and both measuring tools press `J`
;  and read mis_index straight afterwards.
;
;  The reveal cannot. It is uncovering a world that does not exist until the
;  frame loop draws it, so it can step no oftener than a GAME frame -- five a
;  second. There is no arrangement of masks that makes it smoother: a receding
;  mask has to put back what it covered, and the only place that picture exists
;  is the frame loop's own output. That ceiling is why the two halves need
;  different dwells for the same slowdown: the vanish is counting vertical
;  blanks and the reveal is counting frames ten times as long.
;
;  Nobody sees the two together -- the briefing screen sits between them -- so
;  the asymmetry costs nothing on screen.
;
;  NOTHING RECORDS A DIRTY RECTANGLE ANY MORE, and that is a consequence of the
;  bars being small rather than a saving. The full-height line had to record
;  one so the ordinary erase would rub it out when it moved; a bar is rubbed
;  out by the masking, everywhere except the sprite's own rows, and there the
;  sprite's own rectangle does it. One rect per ship would also have been one
;  rect per ship: PHASE4_RECT_SLOTS has five spare, not forty-eight.
;
;  The one place the masking cannot reach on its own is the far end of the run,
;  where the last bar a buffer drew is past everything the next step masks. So
;  the reveal makes two more passes after the last bar has gone by -- one per
;  buffer -- with col past every ship's reach, which mask the whole band and
;  draw nothing.
;
;  WHAT IT DOES NOT TOUCH
;  ----------------------
;  The playfield only, CTX_BAR_H..HUD_TOP. jfx_band clips every band to it, and
;  it has to: scr_fill_rect honours no clip of its own, unlike gfx_vline. The
;  context bar and the HUD are the instruments and not the view; they are also
;  repainted from dirty flags rather than every frame, so a row scrubbed out of
;  either would stay scrubbed out.
;
;  Ink 1, section 2's ink for the fleet itself and for anything the game says
;  in its own voice. Ink 3 is the alarm ink and a jump is not an alarm; ink 2
;  is scenery, and the bars are not part of the world -- they are the fleet's
;  own drive going off.
;
;  LEFT TO RIGHT BOTH TIMES, and the reveal repeats the vanish rather than
;  mirroring it. A mirrored sweep reads as an undo -- the curtain coming back
;  the way it went -- and section 10's campaign only goes one way: what is lost
;  is lost and the fleet never returns to a system it has left.
;
;  BOTH HALVES STOP THE WORLD, and the reveal has to. The vanish gets it for
;  free -- it runs inside mis_jump, and there is nothing left to run. The
;  reveal was an overlay first, with the battle live behind it, and that is a
;  BALANCE change rather than a visual one: seven jumps times two seconds of
;  unattended battle, and tools/balance.py loses two ships in mission 4 where
;  it loses none. demo_update skips its whole simulation while jfx_mode is set,
;  exactly as it does for order_paused.
;
;  Bank 4, by the rule in game/shipclass.asm: the vanish runs from a keypress
;  with the world stopped, and jfx_update runs at the very end of a frame,
;  after ctx_bar, where nothing has paged bank 4 out. Everything it reads --
;  phase4_vis, phase4_gcount, class_geom, scr_fill_rect -- is in the low 16K
;  and is read with the window at rest. jfx_mode, jfx_col and jfx_armed are in
;  the low 16K with the rest of the campaign's state, in game/mission.asm, so
;  tests can read them without waiting for the window to come back.
; ----------------------------------------------------------------------------

;  Which way the bars are going. NOT called JFX_VANISH and JFX_REVEAL: RASM is
;  case-insensitive, so either would be the same symbol as the routine below it
;  and the build stops with "there is already an alias with the same name".
JFX_NONE            equ 0
JFX_OUT             equ 1               ; sweeping the old mission away
JFX_IN              equ 2               ; uncovering the new one

;  The band the effect owns: exactly the playfield.
JFX_TOP             equ CTX_BAR_H
JFX_HEIGHT          equ HUD_TOP - CTX_BAR_H
JFX_WIDTH           equ SCR_BYTES_PER_LINE

;  How far before and after its ship a bar starts and stops. Three bytes is
;  twelve pixels, which is a run-up long enough to be seen as one at tier A --
;  where the ship itself is only two byte columns of drawn sprite -- without
;  making the run so long that the bars of a formation overlap each other.
JFX_MARGIN          equ 3

;  ...and how far proud of the sprite the bar stands, in lines. Three, so a
;  tier A ship's six-line sprite gets a twelve-line bar: a bar shorter than
;  that reads as a brighter pixel rather than as an edge. It also covers the
;  two or three lines a ship moves between frames, which matters because one of
;  the two buffers is always a frame older than the list this works from.
JFX_VMARGIN         equ 3

;  The widest sprite there is, so the longest run any bar has to make. Every
;  class shares class_geom, so tier C's width is the answer for all eight;
;  src/main.asm asserts this against the generated art.
JFX_SPRITE_W_MAX    equ 7
JFX_TRAVEL          equ JFX_SPRITE_W_MAX + 2 * JFX_MARGIN

;  How far the bars move in one step, in byte columns -- ONE, both halves, the
;  finest step the screen has.
;
;  TEN TIMES SLOWER, AND WHERE THAT HAD TO COME FROM. "Θέλω η ταχύτητα του jump
;  in και του jump out να είναι 10 φορές πιο αργή." A bar is a whole BYTE and
;  the run is JFX_TRAVEL of them, so the whole journey has fourteen places a
;  bar can stand and no arrangement of arithmetic gives it more: four pixels is
;  the quantum of a Mode 1 fill. Ten times the duration over a fixed number of
;  places is therefore ten times the DWELL at each of them, and that is what
;  the two constants below are. Dropping the step from 2 and 5 to 1 is what
;  buys back the only resolution there was to buy: fourteen positions rather
;  than seven and three.
;
;  It is worth being plain about what that means on the screen. The vanish is
;  now fourteen positions over about seven seconds, so a bar stands still for
;  half a second and then moves four pixels; the reveal is fifteen over
;  seventeen and a half, so a second and a bit. It reads as a series of steps
;  rather than as a sweep, and the only cure would be a bar that moves at PIXEL
;  resolution -- which needs an OR-masked partial-byte write, because the fill
;  ahead of the bar would otherwise erase the part of the ship inside the
;  bar's own byte, and scr_fill_rect only ever writes whole bytes.
;
;  THE VANISH holds each position for JFX_VANISH_DWELL vertical blanks. It
;  draws on the first of them and waits out the rest, rather than repainting:
;  the picture is identical either way and a repaint is a fill and a bar per
;  ship for nothing.
;
;  THE REVEAL holds each position for JFX_REVEAL_DWELL GAME frames, and it has
;  to redraw on every one of them -- the frame loop repaints the whole mission
;  underneath it every frame, so the mask that hides the part not yet uncovered
;  has to go back down each time. Only the COLUMN is held.
JFX_VANISH_STEP     equ 1
JFX_REVEAL_STEP     equ 1

;  ...and how long a position is held for. BOTH ARE MEASUREMENTS rather than
;  round numbers, and they had to be: the vanish counts vertical blanks and the
;  reveal counts game frames, which are about nine blanks each and not a fixed
;  number of them, and the reveal also spends two frames on mis_wipe that no
;  dwell covers. 23 and 6 measure 359 ticks and 856 against the 35 and 88 they
;  replace -- 10.3 and 9.7 times, on mission 1.
;
;  The vanish's floor is what the disc write depends on and it is arithmetic,
;  not a measurement -- every pass costs JFX_VANISH_DWELL whole vertical
;  blanks whatever is on the screen, so the sweep cannot be shorter than
;  JFX_VANISH_PASSES * JFX_VANISH_DWELL + 2 = 324 ticks. snd_fx_jump_out is
;  300 and silent from 279; see its own note in sys/sound.asm.
JFX_VANISH_DWELL    equ 23
JFX_REVEAL_DWELL    equ 6

;  Passes each half makes, rounded UP so the last one is past the end of the
;  longest run whether or not the step divides it.
;
;  The vanish adds one more, and then two of black over the whole playfield --
;  one per buffer -- to take the scenery the bars do not own. The reveal adds
;  TWO passes with col past every ship, which draw no bar and mask the whole
;  band: each buffer's last bar has to be masked by that buffer's NEXT pass,
;  and the buffers alternate, so one extra pass would clean up only one of
;  them. It is the far end of the run that needs it -- a bar the sprite's own
;  rectangle does not cover.
JFX_VANISH_PASSES   equ (JFX_TRAVEL + JFX_VANISH_STEP - 1) / JFX_VANISH_STEP + 1
JFX_REVEAL_PASSES   equ (JFX_TRAVEL + JFX_REVEAL_STEP - 1) / JFX_REVEAL_STEP + 2

;  The bar is drawn as a PEN through gfx_vline rather than as a solid byte
;  through scr_fill_rect, because it is ONE PIXEL wide and a Mode 1 fill can
;  only ever write four. JFX_INK is what the black behind it is measured
;  against and what src/main.asm still asserts; nothing fills with it.
JFX_INK             equ SOLID_INK_1
JFX_PEN             equ 1


; ----------------------------------------------------------------------------
;  jfx_vanish -- take the fleet away, before anything else happens
;
;  Called from mis_jump once it has decided the jump goes ahead and BEFORE it
;  touches anything, so what the bars erase is the mission the player is
;  leaving rather than a half-built next one.
;
;  IT DOES ITS OWN DOUBLE BUFFERING, and that is not gold plating -- the first
;  version of the full-height line painted straight into the buffer on show and
;  came apart on the screen, because two fills over 158 rows take longer than a
;  50 Hz frame and the display caught it half-erased about as often as whole.
;  The bars are far cheaper than that and might well survive it, but the buffer
;  on show is also the one the frame loop's own flip is about to take away, so
;  painting it would be painting the wrong one.
;
;  Each step therefore paints the BACK buffer, waits for the vertical blank and
;  flips, exactly as the frame loop does -- which means the buffer being
;  painted is the one that was on show a step ago, and is the whole reason
;  jfx_bars repaints a bar's entire trail rather than the column it has just
;  taken.
;  Uses: everything
; ----------------------------------------------------------------------------
jfx_vanish:
    ;  ...and the sound of it, which is 300 ticks against this sweep's floor of
    ;  324. It starts here rather than anywhere else in mis_jump because the
    ;  sound belongs to the BARS: they begin together and it is over before the
    ;  loop below is, which is what keeps it clear of the disc write's DI. See
    ;  the jump descriptors in sys/sound.asm.
    call snd_jump_out

    ld a,JFX_OUT
    ld (jfx_mode),a
    ;  ...and the note for the other half. The briefing this jump is about to
    ;  put up is the one the reveal belongs to; every other briefing in the
    ;  game gets none.
    ld (jfx_armed),a
    xor a
    ld (jfx_col),a
    ld (jfx_bar_off),a
    ld a,JFX_VANISH_PASSES
    ld (jfx_left),a

@jfx_sweep:
    call jfx_ships
    call scr_wait_vsync
    call scr_flip

    ;  ...and then hold this column for the rest of its dwell. The counter is
    ;  in memory rather than in B because scr_wait_vsync uses BC, and a djnz
    ;  round it would have to push and pop it every blank.
    ld a,JFX_VANISH_DWELL - 1
    ld (jfx_dwell),a
@jfx_hold:
    call scr_wait_vsync
    ld hl,jfx_dwell
    dec (hl)
    jr nz,@jfx_hold

    ld hl,jfx_col
    ld a,(hl)
    add a,JFX_VANISH_STEP
    ld (hl),a
    ld hl,jfx_left
    dec (hl)
    jr nz,@jfx_sweep

    ;  The bars only ever owned the ships. The reference plane, the resource
    ;  fields and the Mothership indicator are still standing where the frame
    ;  loop left them, in both buffers -- so the view goes out behind the
    ;  fleet, one pass per buffer, and the screen is black before the briefing
    ;  lands on it. The frame loop's own flip is still to come at the end of
    ;  this frame, which is why it has to be BOTH.
    ld a,2
    ld (jfx_left),a
@jfx_dark:
    xor a
    ld b,a
    ld c,JFX_TOP
    ld d,JFX_WIDTH
    ld e,JFX_HEIGHT
    call scr_fill_rect
    call scr_wait_vsync
    call scr_flip
    ld hl,jfx_left
    dec (hl)
    jr nz,@jfx_dark

    xor a
    ld (jfx_mode),a
    ret


; ----------------------------------------------------------------------------
;  jfx_reveal_open -- start the reveal, if a jump is what put the briefing up
;
;  Called from mis_brief_key, which does not know how its briefing was opened
;  -- so jfx_vanish leaves the note. THE REVEAL IS THE SECOND HALF OF A JUMP
;  and belongs to jumps: mission 1 is reached from the title screen and a
;  restored campaign is reached from the disc, and neither of those has had
;  anything take a fleet away for this one to give back.
;
;  It was armed on every briefing first, on the argument that an arrival is an
;  arrival. That is defensible on screen and it was wrong underneath: every
;  boot_quick in the suite dismisses the opening briefing, so every test in the
;  project started life with two seconds of half-masked playfield, and seven
;  that read pixels failed -- the resource patches, the Mothership indicator,
;  the enemy recolour. None of them was about jumps.
;
;  Uses: AF, BC, DE, HL -- snd_jump_in is an LDIR of a descriptor over a voice
;  block. It was AF alone before that, and the only caller is mis_brief_key,
;  which is "Uses: everything" and reaches here with a JP rather than a CALL.
; ----------------------------------------------------------------------------
jfx_reveal_open:
    ld a,(jfx_armed)
    or a
    ret z

    ;  The other half of the pair, and the SAME note arms both -- so the
    ;  arrival sound belongs to a jump's briefing and to no other one. Nothing
    ;  behind this half touches the disc; it rides demo_update with interrupts
    ;  on for the whole 88 ticks, which is why it is the long one.
    call snd_jump_in

    xor a
    ld (jfx_armed),a
    ld (jfx_col),a
    ld (jfx_bar_off),a
    ld a,JFX_IN
    ld (jfx_mode),a
    ld a,JFX_REVEAL_PASSES
    ld (jfx_left),a
    ld a,JFX_REVEAL_DWELL
    ld (jfx_dwell),a
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
;  screen is always this frame's step.
;
;  About fifty T-states on a frame that is not a transition -- a load, a
;  compare and a RET.
;  Uses: everything
; ----------------------------------------------------------------------------
jfx_update:
    ld a,(jfx_mode)
    cp JFX_IN
    ret nz                               ; idle, or the vanish's own loop

    ;  NOTHING MOVES WHILE THE SCREEN IS STILL BEING CLEARED. mis_wipe is two
    ;  frames of clearing sixteen thousand bytes and they are the two slowest
    ;  the game ever runs -- a fifth of a second each -- and they are the two
    ;  this sweep starts on, because the briefing schedules both on its way
    ;  out. Bars standing still on them for half a second look like the game
    ;  has hung rather than like a pause. The MASK still has to run: each of
    ;  those frames draws the whole mission after its wipe, and letting that
    ;  through shows the player exactly the thing the bars are there to hide.
    ld a,(mis_wipe)
    or a
    jr z,@jfx_step
    ld a,1
    ld (jfx_bar_off),a
    jp jfx_ships

@jfx_step:
    xor a
    ld (jfx_bar_off),a
    call jfx_ships

    ;  The COLUMN moves every JFX_REVEAL_DWELL game frames; the mask above runs
    ;  on every one of them, and has to -- the frame loop has just redrawn the
    ;  whole mission underneath it, which is precisely what the bars are here
    ;  to hide.
    ld hl,jfx_dwell
    dec (hl)
    ret nz
    ld a,JFX_REVEAL_DWELL
    ld (hl),a

    ld hl,jfx_col
    ld a,(hl)
    add a,JFX_REVEAL_STEP
    ld (hl),a
    ld hl,jfx_left
    dec (hl)
    ret nz
    xor a
    ld (jfx_mode),a
    ret


; ----------------------------------------------------------------------------
;  jfx_ships -- one step, for every ship that is actually on the screen
;  Uses: everything
;
;  phase4_vis in order, skipping the entries phase4_group consolidated away:
;  those drew no sprite at all, so a bar over one would be a bar with nothing
;  behind it. That is the same list, in the same order, that phase4_draw walks.
; ----------------------------------------------------------------------------
jfx_ships:
    ld a,(phase4_visible)
    or a
    ret z
    ld (jfx_n),a
    xor a
    ld (jfx_i),a

@jfx_ship:
    ld a,(jfx_i)
    ld l,a
    ld h,0
    ld de,phase4_gcount
    add hl,de
    ld a,(hl)
    or a
    jr z,@jfx_ship_next                  ; consolidated: nothing was drawn

    ld a,(jfx_i)
    call phase4_vis_addr
    call jfx_band
    call c,jfx_bars

@jfx_ship_next:
    ld hl,jfx_i
    inc (hl)
    ld hl,jfx_n
    dec (hl)
    jr nz,@jfx_ship
    ret


; ----------------------------------------------------------------------------
;  jfx_band -- the strip one ship's bar runs along, clipped to the playfield
;  In : HL -> a phase4_vis entry
;  Out: CF set   -> (jfx_bx0) the run-up column, SIGNED; (jfx_reach) how far
;                   the bar has to go; (jfx_by), (jfx_bh) the rows the BAND
;                   covers; (jfx_cy), (jfx_ch) the rows the SPRITE covers
;       CF clear -> none of the band is in the playfield
;  Uses: everything
;
;  This is phase4_blit_body's placement arithmetic and nothing else: the same
;  class_geom row, the same "sx minus half the width", the same arithmetic
;  shift so that a ship hanging off the left-hand edge stays negative. If the
;  two ever disagree the bar walks somewhere the ship is not.
;
;  The sprite's own rows come out of it as well as the band's, because they are
;  the rows the ordinary dirty-rectangle erase covers and the band's are not.
;  See the header of this file. A sprite clipped away entirely still leaves a
;  band -- the bar is taller than it -- and then the core is nothing, pinned to
;  the top of the band so that "the rows below the sprite" is the whole of it.
; ----------------------------------------------------------------------------
jfx_band:
    ld e,(hl)
    inc hl
    ld d,(hl)                            ; DE = sx, 0..319
    inc hl
    ld a,(hl)
    ld (jfx_sy),a
    inc hl
    inc hl
    inc hl
    ld a,(hl)
    and 3                                ; the tier is the low two bits

    ;  class_geom + tier * CLASS_GEOM_SIZE. It is in the low 16K, and has to
    ;  be: it is read from inside the blitter with a foreign bank up.
    ld l,a
    ld h,0
    ld c,l
    ld b,h
    add hl,hl                            ; * 2
    add hl,bc                            ; * 3
    add hl,hl                            ; * 6
    ld bc,class_geom
    add hl,bc                            ; DE, the sx, is untouched

    ld a,(hl)                            ; sprite width, bytes
    add a,JFX_MARGIN * 2
    ld (jfx_reach),a
    inc hl
    ld a,(hl)                            ; sprite height, lines
    ld (jfx_spr_h),a
    inc hl
    ld c,(hl)                            ; half width, PIXELS
    inc hl
    ld a,(hl)                            ; half height, lines
    ld (jfx_half_h),a

    ;  x0 = ((sx - halfwidth) >> 2) - JFX_MARGIN, and the shift is arithmetic
    ;  because the left-hand edge of a ship half off the screen is negative.
    ld a,e
    sub c
    ld l,a
    ld a,d
    sbc a,0
    ld h,a
    sra h
    rr l
    sra h
    rr l
    ld a,l
    sub JFX_MARGIN
    ld (jfx_bx0),a

    ;  The band: the sprite's rows with JFX_VMARGIN proud at each end.
    ld a,(jfx_half_h)
    add a,JFX_VMARGIN
    call jfx_band_top
    ld a,(jfx_spr_h)
    add a,JFX_VMARGIN * 2
    call jfx_clip_rows
    ret nc                               ; none of it is in the playfield
    ld a,d
    ld (jfx_by),a
    ld a,e
    ld (jfx_bh),a

    ;  ...and the sprite's own rows inside it.
    ld a,(jfx_half_h)
    call jfx_band_top
    ld a,(jfx_spr_h)
    call jfx_clip_rows
    jr c,@jfx_band_core
    ld a,(jfx_by)
    ld (jfx_cy),a
    xor a
    ld (jfx_ch),a
    scf
    ret
@jfx_band_core:
    ld a,d
    ld (jfx_cy),a
    ld a,e
    ld (jfx_ch),a
    scf
    ret


;  HL = sy - A, signed, in sixteen bits.
;
;  SIXTEEN, and that is not belt and braces: sy reaches 199, so "sy minus
;  eleven" cannot be tested as a signed byte -- 199 has bit 7 set and so does
;  -11, and a ship at the bottom of the screen would read as one above the top.
jfx_band_top:
    ld b,a
    ld a,(jfx_sy)
    ld l,a
    ld h,0
    sub b
    ld l,a
    ld a,h
    sbc a,0
    ld h,a
    ret


; ----------------------------------------------------------------------------
;  jfx_clip_rows -- cut a range of rows down to the playfield
;  In : HL = the first row, SIGNED; A = how many
;  Out: CF set -> D = the first row, E = how many; CF clear -> none of it
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
jfx_clip_rows:
    ld c,a
    ld de,JFX_TOP
    or a
    sbc hl,de
    jr nc,@jfx_rows_inside

    ;  Above the playfield: lose that many rows off the top. L is the low byte
    ;  of a small negative number, so adding it subtracts, and the carry says
    ;  whether anything is left.
    ld a,c
    add a,l
    jr nc,@jfx_rows_none
    jr z,@jfx_rows_none
    ld e,a
    ld d,JFX_TOP
    jr @jfx_rows_bottom

@jfx_rows_inside:
    ld de,JFX_HEIGHT
    or a
    sbc hl,de
    jr nc,@jfx_rows_none                 ; starts at or below the HUD
    add hl,de
    ld a,l
    add a,JFX_TOP
    ld d,a
    ld e,c

@jfx_rows_bottom:
    ld a,d
    add a,e
    cp JFX_TOP + JFX_HEIGHT + 1
    jr c,@jfx_rows_ok
    ld a,JFX_TOP + JFX_HEIGHT
    sub d
    ld e,a
@jfx_rows_ok:
    scf
    ret

@jfx_rows_none:
    or a
    ret


; ----------------------------------------------------------------------------
;  jfx_bars -- one ship's share of one step
;  In : (jfx_bx0), (jfx_reach), (jfx_by), (jfx_bh) from jfx_band
;  Uses: everything
;
;  The bar goes down LAST in both halves, because both of them black out a run
;  that the bar is standing in the middle of.
; ----------------------------------------------------------------------------
jfx_bars:
    ld a,(jfx_mode)
    cp JFX_IN
    jr z,@jfx_in

    ;  --- the vanish -------------------------------------------------------
    ;  The whole band, as far as the bar has come -- all of it, and not merely
    ;  the column taken since last time: the buffer being painted is the one
    ;  that was on show a step ago, so it is carrying a bar of its own two
    ;  columns back and a ship rubbed out only as far as the step before that.
    call jfx_rows_band
    ld a,(jfx_col)
    ld hl,jfx_reach
    cp (hl)
    jr c,@jfx_out_partway
    ld a,(hl)                            ; past the end: the whole run
@jfx_out_partway:
    ld d,a
    ld a,(jfx_bx0)
    ld e,a
    xor a
    call jfx_fill
    jp jfx_the_bar

    ;  --- the reveal -------------------------------------------------------
@jfx_in:
    ;  The rows the sprite does not occupy, across the whole run. They are
    ;  never anything but black, and they are the one place a bar can be left
    ;  standing that nothing else would take out: what erases a bar in the
    ;  columns the bar has already passed is the SPRITE's dirty rectangle, and
    ;  a bar is taller than its sprite. See the header of this file.
    ld a,(jfx_by)
    ld (jfx_fy),a
    ld a,(jfx_cy)
    ld hl,jfx_by
    sub (hl)
    ld (jfx_fh),a                        ; ...above the sprite
    call jfx_mask_run

    ld a,(jfx_cy)
    ld hl,jfx_ch
    add a,(hl)
    ld (jfx_fy),a
    ld c,a
    ld a,(jfx_by)
    ld hl,jfx_bh
    add a,(hl)
    sub c
    ld (jfx_fh),a                        ; ...and below it
    call jfx_mask_run

    ;  Across the sprite's own rows: the run-up, which never has a ship in it
    ;  and is where a bar in the near margin is taken out...
    call jfx_rows_core
    ld d,JFX_MARGIN
    ld a,(jfx_bx0)
    ld e,a
    xor a
    call jfx_fill

    ;  ...and everything the bar has not reached, which is the rest of the ship
    ;  plus the run-out past it. Clamped at MARGIN + width, so that once the bar
    ;  is out beyond the ship this is the far margin and the ship is whole.
    ld a,(jfx_reach)
    ld c,a
    sub JFX_MARGIN                       ; A = MARGIN + the sprite's width
    ld b,a
    ld a,(jfx_col)
    cp b
    jr c,@jfx_in_ahead
    ld a,b
@jfx_in_ahead:
    ld b,a                               ; B = min(col, MARGIN + width)
    ld a,c
    sub b                                ; ...which is never the whole reach
    ld d,a
    ld a,(jfx_bx0)
    add a,b
    ld e,a
    xor a
    call jfx_fill

    call jfx_rows_band

;  The bar itself, at x0 + col, until it has run off the far end of its own
;  ship. jfx_bar_off is the two mis_wipe frames, where the sweep is held.
;
;  ONE PIXEL, NOT FOUR, and it is drawn through gfx_vline rather than as a
;  byte fill. Mode 1 packs four pixels into a byte and scr_fill_rect writes
;  whole ones, so the bar was as fat as the quantum of the thing that erases
;  it -- which is not a reason for it to be that fat, only the reason nobody
;  had separated the two.
;
;  THE STEP STAYS BYTE-GRANULAR ON PURPOSE. The bar sits at the LEADING EDGE
;  of the black, so its pixel is exactly the boundary the mask ends on, and
;  mask and bar go on agreeing to the pixel. Stepping in pixels instead would
;  need a read-modify-write mask -- the fill ahead of the bar would otherwise
;  erase the part of the ship inside the bar's own byte -- and it is the
;  motion that would get finer, not the line. The line is what was fat.
;
;  What it buys beyond thinness: gfx_vline ORs one pixel, so during the vanish
;  the other three pixels of that byte still show the ship. The bar used to
;  black them out four at a time, which took a column of the ship with it a
;  step before the erasure was meant to reach it.
jfx_the_bar:
    ld a,(jfx_bar_off)
    or a
    ret nz
    ld a,(jfx_col)
    ld hl,jfx_reach
    cp (hl)
    ret nc
    ld hl,jfx_bx0
    add a,(hl)                           ; x0 is signed; the wrap is the answer

    ;  ...so the column can be off either end, and gfx_vline clips only in Y.
    ;  jfx_fill was cutting both ends of every fill and this had been riding on
    ;  it; a byte column of 254 taken as an x would be 1016, which is not on
    ;  this screen at all but IS on some other scanline of it.
    bit 7,a
    ret nz
    cp JFX_WIDTH
    ret nc

    ;  x in PIXELS: the leftmost of that byte, four to a byte.
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld a,(jfx_fy)
    ld c,a
    ld a,(jfx_fh)
    ld b,a
    ld a,JFX_PEN
    jp gfx_vline                         ; ...which clips to the playfield too


;  Black across the whole of this ship's run, in whatever rows are set.
jfx_mask_run:
    ld a,(jfx_reach)
    ld d,a
    ld a,(jfx_bx0)
    ld e,a
    xor a
    jp jfx_fill

;  Which rows the next fills cover: the bar's, or the sprite's.
jfx_rows_band:
    ld a,(jfx_by)
    ld (jfx_fy),a
    ld a,(jfx_bh)
    ld (jfx_fh),a
    ret

jfx_rows_core:
    ld a,(jfx_cy)
    ld (jfx_fy),a
    ld a,(jfx_ch)
    ld (jfx_fh),a
    ret


; ----------------------------------------------------------------------------
;  jfx_fill -- one fill across the rows in (jfx_fy)/(jfx_fh), clipped
;  In : E = x in bytes, SIGNED; D = width in bytes; A = the fill byte
;  Uses: everything
;
;  scr_fill_rect takes an explicit x and width and writes them: it honours no
;  clip of its own, unlike gfx_vline. A negative x would be read as a column in
;  the two hundreds and a width running past byte 79 spills into the scanline
;  eight rows down, because a Mode 1 line is eighty bytes and the rows are
;  interleaved. Both ends have to be cut here.
; ----------------------------------------------------------------------------
jfx_fill:
    ld (jfx_ink_byte),a
    ld a,d
    or a
    ret z
    bit 7,e
    jr z,@jfx_fill_right

    ;  It starts off the left-hand edge: lose that much of the width. The carry
    ;  out of the add is the sign of the true sum.
    ld a,e
    add a,d
    ret nc
    or a
    ret z
    ld d,a
    ld e,0

@jfx_fill_right:
    ld a,e
    cp JFX_WIDTH
    ret nc                               ; off the right-hand edge entirely
    add a,d
    cp JFX_WIDTH + 1
    jr c,@jfx_fill_go
    ld a,JFX_WIDTH
    sub e
    ld d,a

@jfx_fill_go:
    ld b,e
    ld a,(jfx_fy)
    ld c,a
    ld a,(jfx_fh)
    ld e,a
    ld a,(jfx_ink_byte)
    jp scr_fill_rect                     ; ...which returns at once on E = 0


; ============================================================================
;  Scratch. All of it belongs to one step of one ship, except jfx_left and
;  jfx_bar_off which belong to the sweep; jfx_mode, jfx_col and jfx_armed are
;  in game/mission.asm, in the low 16K, so tests can read them with read_ram.
; ============================================================================

;  How many passes of the current half are left.
jfx_left:           defb 0

;  How much longer the bars stand where they are: vertical blanks in the
;  vanish, game frames in the reveal. See JFX_VANISH_DWELL.
jfx_dwell:          defb 0

;  Set on the frames the sweep is held, when the bars must not be drawn.
jfx_bar_off:        defb 0

;  The walk over phase4_vis.
jfx_i:              defb 0
jfx_n:              defb 0

;  This ship's band: where its bar starts (signed) and how far it goes...
jfx_bx0:            defb 0
jfx_reach:          defb 0

;  ...the rows the BAR covers, and the rows the SPRITE covers, both clipped to
;  the playfield. They are not the same and the reveal turns on the difference.
jfx_by:             defb 0
jfx_bh:             defb 0
jfx_cy:             defb 0
jfx_ch:             defb 0

;  ...and which of the two the next fill is using.
jfx_fy:             defb 0
jfx_fh:             defb 0

jfx_sy:             defb 0
jfx_spr_h:          defb 0
jfx_half_h:         defb 0

jfx_ink_byte:       defb 0
