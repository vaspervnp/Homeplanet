; ============================================================================
;  gfx/mark.asm -- the world points that are not ships
; ============================================================================
;  Three things live here because they are one problem: take a world point
;  that no entity owns, project it, draw a handful of pixels, and record a
;  dirty rectangle so the next pass through this buffer erases them again.
;
;      * the reference plane at Y=0                 (Homeplanet.md 4.1)
;      * the resource patches                       (Homeplanet.md 7)
;      * the Mothership when it is off screen: which way it lies and how far
;        above or below the camera it sits
;
;  Growing two separate ways of doing that is how a low 16K with a few hundred
;  bytes left gets spent, so there is one marker vocabulary -- mark_dot,
;  mark_bar, mark_cross, mark_patch -- and every one of them records its own
;  rectangle through phase4_add_rect. Nothing here may draw without doing that;
;  the briefing and the help page both learned it the hard way.
;
;  WHY IT COSTS ALMOST NOTHING PER FRAME
;  -------------------------------------
;  None of these points move. The lattice is fixed, a patch is a fixed field,
;  and the Mothership holds station -- so the only thing that can change where
;  they land is the camera. The projection therefore runs against a hash of
;  the camera, exactly the way section 5.4 caches the stars: once when the
;  view moves, and never on the frames in between. Twenty-one points through
;  proj_point is ~100,000 T-states, a fifth of a frame, and the player is not
;  turning the camera on most frames.
;
;  The one thing NOT cached is a patch's ink, because that is a function of
;  its stock and the stock runs down while the camera sits still. mark_draw
;  reads it fresh; see the note on the two colours below.
; ----------------------------------------------------------------------------

GRID_POINTS         equ 16              ; a 4 x 4 lattice
GRID_SPACING        equ 2250            ; world units, and they got 4x smaller

;  How many patches the cache has room for. Asserted against ECO_PATCH_COUNT
;  in src/main.asm -- game/economy.asm is included further down than this and
;  RASM evaluates a `defs` where it stands.
MARK_PATCHES        equ 4

;  Which ink says what, and this is a real decision rather than a detail.
;  Section 2 gives us three: 1 is friendly ships and text, 2 is stars and the
;  reference plane, 3 is enemies and alarms. Spending 3 on a resource field
;  would make a rich patch read as a hostile, which is the one mistake this
;  palette cannot afford -- so the two colours are 1 and 2, and the thing they
;  carry is the only thing about a patch the player has to act on:
;
;      ink 2   there is stock in it. Scenery, in the scenery ink; nothing to
;              decide, the harvesters are already handling it.
;      ink 1   nearly mined out. The attention ink, because a field about to
;              run dry is exactly when the player has to send the harvesters
;              somewhere else -- and if they do not notice, the economy stops.
;
;  A patch with NO stock is not drawn at all, which also disposes of the empty
;  slots: mis_setup zeroes the ones the mission does not use.
MARK_PATCH_LOW      equ 100             ; RU left before it turns white

;  The Mothership indicator. Ink 2 by the same reading -- it is a navigation
;  aid, not an alarm.
MOTH_INK            equ INK_NEUTRAL
MOTH_H_MAX          equ 14              ; longest height bar, in pixels
MOTH_H_SHIFT        equ 8               ; world units per pixel of it: 256

;  Where the indicator rides. A box twice as wide as it is tall, centred on
;  the tactical view, and held far enough in from the top and bottom that the
;  height bar always has somewhere to go.
MOTH_CENTRE_Y       equ 84
MOTH_Y_MIN          equ MOTH_H_MAX + 2
MOTH_Y_MAX          equ HUD_TOP - MOTH_H_MAX - 4


; ============================================================================
;  The marker vocabulary
; ============================================================================
;  Everything below draws into the back buffer and appends exactly one
;  rectangle. gfx_vline clips against spr_clip_bottom, so none of them can
;  scribble on the HUD.

; ----------------------------------------------------------------------------
;  mark_bar -- B pixels straight down from (HL, C) in pen A, and its rectangle
;  In : HL = sx 0..319, C = sy of the top, B = rows, A = pen
;  Uses: everything
; ----------------------------------------------------------------------------
mark_bar:
    push hl
    push bc
    call gfx_vline
    pop bc
    pop hl
    ld a,c
    ld (mark_rect + 1),a
    ld a,1
    ld (mark_rect + 2),a
    ld a,b
    ld (mark_rect + 3),a
    call mark_x_bytes
    jr mark_store


; ----------------------------------------------------------------------------
;  mark_dot -- one pixel
;  In : HL = sx, C = sy, A = pen
; ----------------------------------------------------------------------------
mark_dot:
    ld b,1
    jr mark_bar


; ----------------------------------------------------------------------------
;  mark_cross -- the three-by-three plus sign, and its rectangle
;  In : HL = sx, C = sy, A = pen
;  Uses: everything
; ----------------------------------------------------------------------------
mark_cross:
    push hl
    push bc
    call gfx_cross
    pop bc
    pop hl
    ld a,c
    or a
    jr z,@mark_cross_y0
    dec a                               ; the cross reaches a row either side
@mark_cross_y0:
    ld (mark_rect + 1),a
    ld a,3
    ld (mark_rect + 2),a
    ld (mark_rect + 3),a
    call mark_x_bytes
    or a
    jr z,mark_store                     ; already hard against the left edge
    dec a                               ; ...and a byte either side

mark_store:
    ld (mark_rect + 0),a
    ld hl,mark_rect
    jp phase4_add_rect


; ----------------------------------------------------------------------------
;  mark_x_bytes -- A = the byte column holding pixel HL
;  Uses: AF, HL
;
;  x is SIXTEEN bit. Shifting only the low byte is the bug that left a comb of
;  stems down the screen the first time the move disc was drawn: the rectangle
;  went somewhere else entirely and erased nothing.
; ----------------------------------------------------------------------------
mark_x_bytes:
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ret


; ----------------------------------------------------------------------------
;  mark_patch -- a resource field: three pixels in a triangle
;  In : HL = sx, C = sy, A = pen
;  Uses: everything
;
;  Not a dot and not a cross, because both of those already mean something:
;  the sensor view draws fighters as dots and capitals as crosses, and the
;  move disc is a cross too. A little cluster reads as a field of rock, and it
;  is three gfx_vline calls under one rectangle rather than three.
; ----------------------------------------------------------------------------
mark_patch:
    ld (mark_pen),a

    ;  The right-hand pixel is two across, so a patch hard against the right
    ;  edge would write into the first byte of the next line down.
    ld a,h
    or a
    jr z,@mark_patch_x_ok
    ld a,l
    cp 62                               ; 256 + 62 = 318
    jr c,@mark_patch_x_ok
    ld hl,317
@mark_patch_x_ok:
    ld (mark_px),hl
    ld a,c
    ld (mark_py),a

    dec c                               ; the apex; y-1 at the top of the
    ld b,1                              ; screen wraps to 255 and gfx_vline
    call gfx_vline                      ; clips it, which is what we want

    ld hl,(mark_px)
    inc hl
    inc hl
    ld a,(mark_py)
    ld c,a
    ld b,1
    ld a,(mark_pen)
    call gfx_vline

    ld hl,(mark_px)
    ld a,(mark_py)
    inc a
    ld c,a
    ld b,1
    ld a,(mark_pen)
    call gfx_vline

    ld a,(mark_py)
    or a
    jr z,@mark_patch_y0
    dec a
@mark_patch_y0:
    ld (mark_rect + 1),a
    ld a,2
    ld (mark_rect + 2),a
    ld a,3
    ld (mark_rect + 3),a
    ld hl,(mark_px)
    call mark_x_bytes
    jr mark_store




; ============================================================================
;  Drawing
; ============================================================================

; ----------------------------------------------------------------------------
;  mark_draw -- replot the cached markers
;
;  Called before the ships, so a ship over the plane hides the plane rather
;  than the other way round. The reference plane is tactical-only; the patches
;  are drawn in both views, because section 9's sensor view is where the long
;  transits happen and "is there anything out there to mine" is exactly the
;  question it exists to answer.
;  Uses: everything
; ----------------------------------------------------------------------------
mark_draw:
    ld a,(mark_count)
    or a
    ret z
    ld (mark_left),a
    ld hl,mark_cache
    ld (mark_src),hl

@mark_draw_one:
    ld hl,(mark_src)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)                           ; sy
    inc hl
    ld a,(hl)                           ; the tag
    inc hl
    ld (mark_src),hl
    ex de,hl                            ; HL = sx
    or a
    jr nz,@mark_draw_patch

    ;  The reference plane. Sensors already draw a dot per entity and a lattice
    ;  of more dots over the top of them would be unreadable.
    ld a,(view_sensors)
    or a
    jr nz,@mark_draw_next
    ld a,INK_NEUTRAL
    call mark_dot
    jr @mark_draw_next

@mark_draw_patch:
    ;  Tag n is patch n-1, and its ink comes from the stock HERE rather than
    ;  from the cache: the stock runs down while the camera sits still, and a
    ;  colour that only caught up when the player turned the view would be
    ;  telling them yesterday's news about the one thing they have to act on.
    dec a
    push hl
    push bc
    add a,a
    add a,a
    add a,a                             ; * ECO_PATCH_SIZE
    add a,6                             ; -> the stock word
    ld l,a
    ld h,0
    ld de,eco_patches
    add hl,de
    ld a,(hl)
    inc hl
    or (hl)
    jr z,@mark_draw_gone                ; mined out, or a slot with no field in it
    ld a,(hl)
    or a
    ld a,INK_NEUTRAL
    jr nz,@mark_draw_ink                ; over 255 RU: plenty
    dec hl
    ld a,(hl)
    cp MARK_PATCH_LOW
    ld a,INK_NEUTRAL
    jr nc,@mark_draw_ink
    ld a,INK_FRIEND                     ; nearly out: the attention ink
@mark_draw_ink:
    pop bc
    pop hl
    call mark_patch
    jr @mark_draw_next
@mark_draw_gone:
    pop bc
    pop hl

@mark_draw_next:
    ld hl,mark_left
    dec (hl)
    jr nz,@mark_draw_one
    ret


; ----------------------------------------------------------------------------
;  moth_draw -- the off-screen Mothership indicator
;
;  Drawn AFTER the ships rather than with the rest of the markers: it is a
;  navigation overlay, and a ship flying across the edge of the view must not
;  be allowed to sit on top of it. Where it goes and how long the bar is were
;  worked out by moth_place, in bank 4.
;  Uses: everything
; ----------------------------------------------------------------------------
moth_draw:
    ld a,(moth_bar)
    or a
    ret z

    ld b,a
    ld a,(moth_y)
    ld c,a
    bit 7,b
    jr z,@moth_draw_up
    ld a,b
    neg
    ld b,a
    inc c                               ; below: the bar hangs off the marker
    jr @moth_draw_bar
@moth_draw_up:
    ld a,c
    sub b
    ld c,a                              ; above: it rises to meet it

@moth_draw_bar:
    ld hl,(moth_x)
    ld a,MOTH_INK
    call mark_bar

    ld hl,(moth_x)
    ld a,(moth_y)
    ld c,a
    ld a,MOTH_INK
    jp mark_cross


; ============================================================================
;  State
; ============================================================================
;  Shared with gfx/markproj.asm, which is in bank 4 -- the state stays down
;  here in the low 16K where mark_draw can reach it without a thought.
mark_shadow:        defb #FF            ; a hash of the camera: "has it moved"
mark_src:           defw 0
mark_dst:           defw 0
mark_stride:        defw 0
mark_left:          defb 0
mark_tag:           defb 0
mark_col:           defb 0
mark_point:         defs 6, 0           ; the lattice point being projected
mark_pen:           defb 0
mark_px:            defw 0
mark_py:            defb 0
mark_rect:          defs 4, 0

;  Four bytes a marker: sx, sy, and the tag that says what it is -- 0 for the
;  reference plane, n for resource patch n-1. Clipped points are not in it.
mark_cache:         defs (GRID_POINTS + MARK_PATCHES) * 4, 0
mark_count:         defb 0

moth_x:             defw 0
moth_y:             defb 0
moth_bar:           defb 0              ; signed pixels; 0 = no indicator
moth_zoom:          defb 0
moth_dx:            defb 0
moth_dy:            defb 0
moth_m:             defb 0
moth_r:             defb 0
