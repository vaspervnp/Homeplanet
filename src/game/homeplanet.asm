; ============================================================================
;  game/homeplanet.asm -- the world, under the last mission
; ============================================================================
;  improvements.md section 4: the campaign is a journey to a planet, and the
;  planet was never on the screen except as a word. This puts it under the
;  final mission, which is the only one whose name it shares.
;
;  IN BANK 4, and legal there by the narrow test in game/shipclass.asm: it runs
;  once a game frame, from demo_update, and it cannot run between
;  class_tier_addr and class_blit_done. game/ctxbar.asm and gfx/markproj.asm
;  are the other two here on that reasoning.
;
;  A HORIZON, NOT A DISC, AND NOT A RING EITHER
;  --------------------------------------------
;  It was drawn as a complete ellipse first, at the title screen's own size and
;  then at twice it, and BOTH READ AS AN ARENA: a thin ring with the fleet
;  sitting inside it, which is a boundary and not a body. The title screen's
;  planet works because it is filled, lit and off to one side; none of that is
;  available here -- see below for why it cannot be filled.
;
;  So the centre is BELOW the playfield and the radius is four times the
;  table's. What is on the screen is the top of a very large sphere: one curve
;  across the lower third, with the fleet flying above it. That is what
;  arriving somewhere looks like, and it is the one reading that cannot be
;  mistaken for a circle drawn round the ships.
;
;  It is also much cheaper, which was not the reason but is a real consequence:
;  the rows outside the playfield are rejected before their columns are walked,
;  so a shape with most of itself off the bottom of the screen costs a fraction
;  of what a centred one did.
;
;  WHY IT CANNOT BE FILLED
;  -----------------------
;  phase4_erase clears each buffer's dirty rectangles to BLACK -- which is what
;  makes a 3D game affordable on a 4 MHz Z80 -- so anything painted behind the
;  fleet is punched full of holes by every ship that crosses it. The answer is
;  not to fight that but to be cheap enough to redraw after it: the limb goes
;  down every frame, straight after phase4_erase and before the markers and the
;  ships, so a hole opened this frame is closed in the same frame. There is no
;  dirty rectangle to record either, which matters -- a slot per pixel would
;  swamp a list sized for entities.
;
;  Section 4.1's reference plane is a lattice of DOTS and section 7's resource
;  fields are three pixels each for the same reason. On this machine the
;  background is drawn by not drawing most of it.
;
;  WHAT IT COSTS, AND THE VERSION THAT WAS THROWN AWAY
;  --------------------------------------------------
;  The first version plotted through gfx_vline, one call per pixel, and cost
;  HALF THE FRAME: 6.90 fps in mission 1 against 3.55 in the last one. That is
;  not something gfx_vline is bad at -- it is what calling it six hundred times
;  is. Each call re-clips against both bounds and rebuilds the scanline address
;  from the line table, which is right for the sixteen dots of the reference
;  plane and wrong here.
;
;  planet_run_if_visible computes the scanline address ONCE PER ROW and plots
;  straight into it. The measured figures are in the commit that brought it.
;
;  AT INFINITY, NOT AT A POINT IN THE WORLD
;  ----------------------------------------
;  It cannot be an ordinary world point: proj_deltas clips a camera-space axis
;  at PROJ_V_LIMIT, so anything far enough away to read as a planet is rejected
;  before it is ever projected -- the same wall moth_update climbs over by
;  borrowing the widest zoom step.
;
;  So it is scenery at infinity, exactly as section 5.4 describes the
;  background stars: no translation and no perspective divide, because neither
;  means anything at that distance. Its screen position is a function of where
;  the camera is LOOKING and of nothing else -- turn, and it slides across;
;  pan, and it does not move, because panning does not change a bearing.
;
;  The map from angle to pixels is linear rather than a tangent. PROJ_K gives a
;  45 degree half-field, which is 32 of the 256 units a turn is counted in, so
;  the half-width of the screen is 32 units and a unit is five pixels. Over a
;  range this narrow the difference from a real projection is under two pixels
;  and it costs one add instead of a divide.
; ----------------------------------------------------------------------------

;  Where it hangs, as a bearing in 256ths of a turn.
PLANET_BEARING      equ 32

;  The middle of the screen, written out rather than as SCR_WIDTH_PX / 2.
PLANET_CENTRE_X     equ 160

;  FOUR TIMES the title screen's disc, out of the same 35-byte quadrant: one
;  table entry every four rows, its half-width shifted up twice. 164 by 136 is
;  wider than the screen and taller than the playfield, which is the point --
;  what is visible is an arc, not an outline.
PLANET_RX           equ TITLE_PLANET_RX * 4
PLANET_RY           equ TITLE_PLANET_RY * 4

;  ...and its centre sits below the HUD, so the arc crosses the lower third of
;  the playfield. The apex is at PLANET_HORIZON_Y - PLANET_RY, which is 104 at
;  rest: fifteen lines under the middle of the visible band.
PLANET_HORIZON_Y    equ 240

;  How far off-bearing it can be and still have any of it on the screen. The
;  half-field is 32 units and the disc is another 33 at five pixels each, so
;  past this there is nothing to draw and nothing to erase either, and the
;  whole pass is a compare and a jump.
PLANET_CULL         equ 64

;  The two asserts that measure this against the playfield are at the bottom of
;  src/main.asm and not here: ASSERT is evaluated where it stands, and
;  TITLE_PLANET_RY is defined by an include that has not happened yet.


; ----------------------------------------------------------------------------
;  planet_init -- nothing is on the screen yet
;  Uses: AF
; ----------------------------------------------------------------------------
planet_init:
    xor a
    ld (planet_shown),a
    ld (planet_rec_a),a
    ld (planet_rec_b),a
    ret


; ----------------------------------------------------------------------------
;  planet_scene -- one frame of it
;  Uses: everything
;
;  Called from demo_update's playing path, straight after phase4_erase, so
;  everything else in the frame draws in front of it.
; ----------------------------------------------------------------------------
planet_scene:
    ;  WHICH BUFFER, FIRST. The display page-flips, so a limb drawn on frame N
    ;  is in one buffer and the copy on frame N+1 is in the other -- and an
    ;  erase that only ever cleans the buffer being drawn leaves the other one
    ;  holding a planet nobody will take off it. Turning the camera left a ROW
    ;  of them across the sky, which is what the screenshot showed.
    ;
    ;  So each buffer remembers where its own limb is, exactly as
    ;  phase4_select_list gives each one its own dirty-rectangle list.
    call planet_load

    ;  Only the mission the campaign is travelling to. A compare rather than
    ;  the flag bit in the mission row improvements.md suggests: there is one
    ;  planet and it is the last mission by definition, and a field would have
    ;  cost every row two bytes and mis_descriptor its multiply.
    ld a,(mis_index)
    cp MIS_COUNT - 1
    jp nz,planet_take_it_down

    ;  Where. The bearing the camera would have to be looking on to have it
    ;  dead ahead, less where it IS looking, as a signed byte.
    ld a,PLANET_BEARING
    ld hl,cam_yaw
    sub (hl)
    ld c,a

    bit 7,a
    jr z,@planet_right
    neg
@planet_right:
    cp PLANET_CULL
    jp nc,planet_take_it_down

    ;  x = 160 + 5 * offset, built in HL because the product reaches 320 and is
    ;  signed.
    ld a,c
    call planet_times5
    ld de,PLANET_CENTRE_X
    add hl,de
    ld (planet_next_cx),hl

    ;  y = the horizon, plus the pitch at the same five pixels a unit -- so
    ;  looking down at the fleet lifts the world up the screen, which is what
    ;  the reference plane does and is the only way the two can agree.
    ld a,(cam_pitch)
    call planet_times5
    ld de,PLANET_HORIZON_Y
    add hl,de
    ld (planet_next_cy),hl

    ;  THE NEW POSITION IS HELD ASIDE UNTIL THE OLD ONE HAS BEEN RUBBED OUT.
    ;  planet_erase_last draws through planet_at_x/cy, so those have to be free
    ;  for it to put the old position in: writing the new one there and then
    ;  calling it threw the new one away every frame, and the planet froze at
    ;  wherever the camera happened to be pointing on the first frame.
    ld a,(planet_shown)
    or a
    jr z,@planet_fresh
    ld hl,(planet_next_cx)
    ld de,(planet_last_cx)
    or a
    sbc hl,de
    jr nz,@planet_moved
    ld hl,(planet_next_cy)
    ld de,(planet_last_cy)
    or a
    sbc hl,de
    jr z,@planet_fresh                  ; exactly where it was: leave it alone

@planet_moved:
    call planet_erase_last

@planet_fresh:
    ld hl,(planet_next_cx)
    ld (planet_at_x),hl
    ld (planet_last_cx),hl
    ld hl,(planet_next_cy)
    ld (planet_at_y),hl
    ld (planet_last_cy),hl

    xor a
    ld (planet_erasing),a
    call planet_limb

    ld a,1
    ld (planet_shown),a
    jp planet_store


; ----------------------------------------------------------------------------
;  planet_take_it_down -- it is not on this screen; make sure it is not on it
;  Uses: everything
;
;  Reached when the camera turns past it and when a jump leaves the mission it
;  belongs to. The second case would otherwise leave an arc hanging over the
;  next mission: mis_wipe clears the screen on a jump, but turning away does
;  not, and neither does the tutorial.
; ----------------------------------------------------------------------------
planet_take_it_down:
    ld a,(planet_shown)
    or a
    jp z,planet_store
    call planet_erase_last
    xor a
    ld (planet_shown),a
    jp planet_store


; ----------------------------------------------------------------------------
;  planet_erase_last -- draw the limb again in BLACK, where it last was
;  Uses: everything
;
;  A SECOND PASS OF THE SAME CURVE, not a rectangle over the whole thing. The
;  box was written first and is many times the work: the arc is a few hundred
;  pixels and its bounding rectangle is eighty bytes by sixty-four lines.
;
;  It could not be done with gfx_vline, which is why the box existed at all --
;  gfx_vline ORs its pixel, deliberately, so that the jump wipe's bar does not
;  take the other three pixels of its byte with it, and ORing pen 0 changes
;  nothing whatever. The old limbs simply stayed, and turning the camera left a
;  row of planets across the sky. planet_plot ANDs the complement instead,
;  which is something only a plotter that owns its own masks can do.
; ----------------------------------------------------------------------------
planet_erase_last:
    ld hl,(planet_last_cx)
    ld (planet_at_x),hl
    ld hl,(planet_last_cy)
    ld (planet_at_y),hl
    ld a,1
    ld (planet_erasing),a
    ;  ...and fall into planet_limb


; ----------------------------------------------------------------------------
;  planet_limb -- the arc, row by row
;  In : planet_at_x, planet_at_y (signed words), planet_erasing
;  Uses: everything
;
;  The quadrant table is the title screen's, read one entry every four rows
;  with its half-width shifted up twice. The run for a row is the columns
;  between this row's half-width and the last one's, which is what turns a
;  table of half-widths into a curve one pixel thick.
; ----------------------------------------------------------------------------
planet_limb:
    call planet_set_op

    ;  START AT THE FIRST ROW THAT CAN BE SEEN. A horizon has most of itself
    ;  below the HUD, and walking those rows to reject them cost more than
    ;  drawing the ones that show: the top row of dy is cy - dy, so nothing
    ;  above dy = cy - HUD_TOP + 1 can land on the playfield at all.
    ;
    ;  It is a floor and not a range: the BOTTOM row, cy + dy, is what shows if
    ;  the planet is ever above the playfield -- a full nose-down pitch -- and
    ;  that case still walks the whole shape.
    ld hl,(planet_at_y)
    ld de,HUD_TOP - 1
    or a
    sbc hl,de
    jr c,@planet_from_top
    jr z,@planet_from_top
    ld a,h
    or a
    jr nz,@planet_from_top              ; further below than the shape is tall
    ld a,l
    cp PLANET_RY + 1
    jr nc,@planet_none                  ; the whole arc is under the HUD
    ld (planet_dy),a
    dec a
    call planet_hw_at
    ld (planet_prev),a
    jr @planet_row

@planet_from_top:
    ld a,PLANET_RX
    ld (planet_prev),a
    xor a
    ld (planet_dy),a

@planet_row:
    ld a,(planet_dy)
    call planet_hw_at
    ld (planet_hw),a

    ;  The run: from this row's half-width out to the previous row's.
    ld hl,planet_hw
    ld a,(planet_prev)
    sub (hl)
    inc a
    ld (planet_cols),a
    ld a,(hl)
    ld (planet_from),a

    ;  The two rows this dy names, above and below the centre. Each is walked
    ;  only if it is inside the playfield -- for a horizon that rejects most of
    ;  the shape before a single column is touched, which is where the cost of
    ;  the centred version went.
    ld hl,(planet_at_y)
    ld de,(planet_dy_word)
    or a
    sbc hl,de
    call planet_run_if_visible

    ld hl,(planet_at_y)
    ld de,(planet_dy_word)
    add hl,de
    call planet_run_if_visible

    ld a,(planet_hw)
    ld (planet_prev),a
    ld hl,planet_dy
    inc (hl)
    ld a,(hl)
    cp PLANET_RY + 1
    jr c,@planet_row
@planet_none:
    ret


; ----------------------------------------------------------------------------
;  planet_hw_at -- the half-width of the arc at row dy
;  In : A = dy, 0..PLANET_RY
;  Out: A = half-width in pixels
;  Uses: everything but B
;
;  INTERPOLATED, NOT STEPPED. Reading one entry every four rows and shifting it
;  up twice gives a half-width that is constant for four rows and then jumps by
;  up to twenty-four pixels, and the curve came out as a visible staircase --
;  five or six steps across the screen, which is the one thing that makes a big
;  smooth shape look cheap. It is the same finding as the title planet's
;  terminator, which stopped being drawn in whole bytes for exactly this
;  reason.
;
;  Between two table entries the half-width falls by (t0 - t1) four times over,
;  so one row of the four is worth exactly (t0 - t1) and the drop needs no
;  multiply: it is subtracted f times, and f is 0 to 3.
; ----------------------------------------------------------------------------
planet_hw_at:
    push bc
    ld c,a
    srl a
    srl a                               ; the entry, one every four rows
    ld e,a
    ld d,0
    ld hl,title_planet_hw
    add hl,de
    ld a,(hl)
    inc hl
    ld e,(hl)                           ; the next one -- the table carries a
    sub e                               ; spare zero past the pole for this
    ld e,a                              ; E = the drop for one row

    dec hl
    ld a,(hl)
    add a,a
    add a,a                             ; four times the entry itself

    ld d,a
    ld a,c
    and 3
    ld c,a
    ld a,d
    jr z,@planet_hw_done                ; on an entry: nothing to interpolate
@planet_hw_step:
    sub e
    dec c
    jr nz,@planet_hw_step
@planet_hw_done:
    pop bc
    ret


; ----------------------------------------------------------------------------
;  planet_run_if_visible -- one scanline of the run, if it is on the playfield
;  In : HL = the pixel row, signed
;  Uses: everything
; ----------------------------------------------------------------------------
planet_run_if_visible:
    ;  Inside the playfield? Unsigned compares do both ends, because a negative
    ;  row is a very large one. The strips above and below belong to the
    ;  context bar and the HUD and neither may be drawn into.
    ld de,CTX_BAR_H
    push hl
    or a
    sbc hl,de
    pop hl
    ret c
    ld de,HUD_TOP
    push hl
    or a
    sbc hl,de
    pop hl
    ret nc

    ;  ONE SCANLINE ADDRESS FOR THE WHOLE RUN, and this is the performance
    ;  story of the file: the version that called gfx_vline per pixel rebuilt
    ;  it out of the line table for every one of six hundred dots.
    ld a,l
    call scr_line_addr
    ld (planet_row_ptr),hl

    ld a,(planet_cols)
    or a
    ret z

    ;  Both halves of the run, out from the half-width. Separate passes because
    ;  one walks LEFT and the other RIGHT, and the whole speed of this file is
    ;  in walking rather than in computing where to walk.
    ld hl,(planet_at_x)
    ld a,(planet_from)
    ld e,a
    ld d,0
    push hl
    add hl,de
    call planet_span_right
    pop hl
    ld a,(planet_from)
    ld e,a
    ld d,0
    or a
    sbc hl,de
    jp planet_span_left


; ----------------------------------------------------------------------------
;  planet_span_right / planet_span_left -- one run of pixels along a scanline
;  In : HL = the first pixel's x, signed; (planet_cols) = how many
;  Uses: everything
;
;  THIS IS WHERE THE FRAME WENT. The first version called a general plotter per
;  pixel: an unsigned range check, a shift of x down to a byte, an add to the
;  row base and a table lookup for the mask -- about 250 T-states of which 240
;  were rediscovering what the pixel before it already knew. It cost half the
;  frame: 6.90 fps in mission 1 against 3.55 in the last.
;
;  Along a run the x moves by one, so the mask is the last one rotated and the
;  byte address only changes every fourth pixel. The range check leaves the
;  loop altogether: a run is a straight line, so how much of it is on the
;  screen is an arithmetic answer rather than a per-pixel question.
;
;  In Mode 1 the four pixels of a byte have their plane-0 bits in the high
;  nibble and their plane-1 bits in the low one, so ink 2 -- which is %10 -- is
;  one bit of the low nibble: #08 for the leftmost pixel down to #01 for the
;  rightmost. Rotating it right walks rightwards, and it carries out of the
;  byte exactly when the byte changes.
;
;  ERASING IS THE SAME LOOP WITH THREE BYTES PATCHED. Drawing ORs the bit;
;  erasing ANDs its complement, which rotates the same way -- the carry simply
;  comes out with the opposite polarity, because the bit falling off the end is
;  a one instead of a zero. So the opcode, the branch and the value the mask
;  restarts at are patched by planet_set_op once a pass, and the loop never
;  asks which it is doing. Self-modifying and commented, as scr_fill_rect's
;  @fill_byte is.
; ----------------------------------------------------------------------------
planet_span_right:
    ld a,(planet_cols)
    ld b,a                              ; B = pixels still to draw

    bit 7,h
    jr z,@planet_r_not_left
    ;  Starts off the left-hand edge: drop that many and begin at zero.
    ld a,l
    neg
    cp b
    ret nc                              ; the whole run is off the screen
    ld c,a
    ld a,b
    sub c
    ld b,a
    ld hl,0
@planet_r_not_left:
    ld de,SCR_WIDTH_PX
    push hl
    or a
    sbc hl,de
    pop hl
    ret nc                              ; begins past the right edge

    ;  How many pixels there are between here and the edge. Sixteen-bit,
    ;  because it reaches 320 and because H is the high byte of the START and
    ;  says nothing about the room left -- an x of 300 has H set and three
    ;  pixels to spare.
    push hl
    ex de,hl
    or a
    sbc hl,de                           ; DE was SCR_WIDTH_PX
    ld a,h
    or a
    jr nz,@planet_r_room                ; more than 255 to spare
    ld a,l
    cp b
    jr nc,@planet_r_room
    ld b,a
@planet_r_room:
    pop hl
@planet_r_go:
    ld a,b
    or a
    ret z

    call planet_addr_and_mask
@planet_r_pixel:
    ld a,(hl)
@planet_op_r equ $
    or c                                ; ...or `and c` while erasing
    ld (hl),a
    rrc c
@planet_br_r equ $
    jr nc,@planet_r_next                ; ...or `jr c` while erasing
@planet_wrap_r equ $+1
    ld c,#08                            ; ...or #F7 while erasing
    inc hl
@planet_r_next:
    djnz @planet_r_pixel
    ret


planet_span_left:
    ld a,(planet_cols)
    ld b,a

    bit 7,h
    ret nz                              ; begins off the left edge
    ld de,SCR_WIDTH_PX
    push hl
    or a
    sbc hl,de
    pop hl
    jr c,@planet_l_on
    ;  Starts off the right: skip forward to the last on-screen pixel.
    ld de,SCR_WIDTH_PX - 1
    or a
    sbc hl,de
    ld a,h
    or a
    ret nz                              ; further off than a byte can count
    ld a,l
    cp b
    ret nc                              ; the whole run is off the screen
    ld c,a
    ld a,b
    sub c
    ld b,a
    ld hl,SCR_WIDTH_PX - 1
@planet_l_on:
    ;  ...and it may run off the left, which cuts the count instead. There are
    ;  x + 1 pixels between here and zero.
    ld a,h
    or a
    jr nz,@planet_l_go                  ; x >= 256: more room than B can ask
    ld a,l
    inc a
    jr z,@planet_l_go                   ; x was 255, so room is 256
    cp b
    jr nc,@planet_l_go
    ld b,a
@planet_l_go:
    ld a,b
    or a
    ret z

    call planet_addr_and_mask
@planet_l_pixel:
    ld a,(hl)
@planet_op_l equ $
    or c
    ld (hl),a
    rlc c
@planet_br_l equ $
    jr nc,@planet_l_next
@planet_wrap_l equ $+1
    ld c,#01
    dec hl
@planet_l_next:
    djnz @planet_l_pixel
    ret


; ----------------------------------------------------------------------------
;  planet_addr_and_mask -- HL -> the screen byte, C = the bit inside it
;  In : HL = an on-screen pixel x
;  Out: HL -> the byte, C = the mask, complemented already if erasing
;  Uses: AF, C, DE, HL
; ----------------------------------------------------------------------------
planet_addr_and_mask:
    push bc
    ld a,l
    and 3
    ld c,a
    ld b,0
    srl h
    rr l
    srl h
    rr l
    ld de,(planet_row_ptr)
    add hl,de
    push hl
    ld hl,planet_mask
    add hl,bc
    ld a,(hl)
    pop hl
    pop bc
    ld c,a
    ld a,(planet_erasing)
    or a
    ret z
    ld a,c
    cpl
    ld c,a
    ret


; ----------------------------------------------------------------------------
;  planet_set_op -- point the two loops at OR or AND for this pass
;  In : (planet_erasing)
;  Uses: AF
; ----------------------------------------------------------------------------
planet_set_op:
    ld a,(planet_erasing)
    or a
    jr nz,@planet_op_erase

    ld a,#B1                            ; OR C
    ld (@planet_op_r),a
    ld (@planet_op_l),a
    ld a,#30                            ; JR NC
    ld (@planet_br_r),a
    ld (@planet_br_l),a
    ld a,#08
    ld (@planet_wrap_r),a
    ld a,#01
    ld (@planet_wrap_l),a
    ret

@planet_op_erase:
    ld a,#A1                            ; AND C
    ld (@planet_op_r),a
    ld (@planet_op_l),a
    ld a,#38                            ; JR C -- the complement drops a ONE
    ld (@planet_br_r),a
    ld (@planet_br_l),a
    ld a,#F7
    ld (@planet_wrap_r),a
    ld a,#FE
    ld (@planet_wrap_l),a
    ret


; ----------------------------------------------------------------------------
;  planet_load / planet_store -- this buffer's memory of where the limb is
;  Uses: everything
; ----------------------------------------------------------------------------
planet_load:
    call planet_select
    ld de,planet_shown
    ld bc,PLANET_REC_SIZE
    ldir
    ret

planet_store:
    call planet_select
    ex de,hl
    ld hl,planet_shown
    ld bc,PLANET_REC_SIZE
    ldir
    ret

;  HL -> the record belonging to the buffer being drawn into. The same test
;  phase4_select_list makes, and it has to be: this runs from demo_update
;  between the page flip and the drawing.
planet_select:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    ld hl,planet_rec_b
    ret nz
    ld hl,planet_rec_a
    ret


; ----------------------------------------------------------------------------
;  planet_times5 -- HL = 5 * A, with A signed
;  In : A
;  Out: HL
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
planet_times5:
    ld l,a
    rla                                 ; the sign into carry
    sbc a,a                             ; ...and out again as 0 or #FF
    ld h,a
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl
    add hl,de
    ret


; ============================================================================
;  State
; ============================================================================
;  Ink 2 in Mode 1, one bit a pixel. Section 2 gives ink 2 to the stars and the
;  reference grid: it is the ink this game means SCENERY by, and a world is the
;  scenery. Ink 1 is the fleet and the text, so a white horizon would read as
;  something of ours; ink 3 is the alarm ink and a planet is not an alarm.
planet_mask:        defb #08, #04, #02, #01

planet_at_x:          defw 0
planet_at_y:          defw 0
planet_next_cx:     defw 0
planet_next_cy:     defw 0
planet_row_ptr:     defw 0
planet_erasing:     defb 0
planet_hw:          defb 0
planet_prev:        defb 0
planet_cols:        defb 0
planet_from:        defb 0

;  planet_dy is read as a WORD by planet_limb. The byte after it is the high
;  half and is never written, so it has to stay zero and has to stay adjacent.
planet_dy_word:
planet_dy:          defb 0
                    defb 0

;  The working copy, and the two it is loaded from and stored back to. The
;  bytes below planet_shown are ONE RECORD and their order is its layout:
;  planet_load LDIRs over all five in one go.
planet_shown:       defb 0
planet_last_cx:     defw 0
planet_last_cy:     defw 0
PLANET_REC_SIZE     equ 5

planet_rec_a:       defs PLANET_REC_SIZE, 0
planet_rec_b:       defs PLANET_REC_SIZE, 0

    assert planet_last_cx == planet_shown + 1, "the planet record is not contiguous"
    assert planet_last_cy == planet_shown + 3, "the planet record is not contiguous"
    assert planet_dy_word == planet_dy, "planet_dy is not the low byte of its word"
