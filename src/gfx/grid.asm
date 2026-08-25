; ============================================================================
;  gfx/grid.asm -- the reference plane at Y=0 (Homeplanet.md section 4.1)
; ============================================================================
;  "Ο χώρος έχει «επίπεδο αναφοράς» Y=0 με σχεδιασμένο πλέγμα, όπως στο
;  Homeworld — δίνει την αίσθηση βάθους χωρίς κόστος."
;
;  Without depth is exactly the difficulty. Sixteen lattice points through
;  proj_point is about 73,000 T-states, a seventh of the frame, for a
;  backdrop -- so it is cached, the way section 5.4 caches the stars: the
;  projection runs only when the camera has actually moved, and every other
;  frame just replots the sixteen dots it worked out last time.
;
;  The camera is the player's now, so "has it moved" is usually no.
; ----------------------------------------------------------------------------

GRID_POINTS         equ 16              ; a 4 x 4 lattice
GRID_SPACING        equ 9000
GRID_INK            equ INK_NEUTRAL     ; sky blue: environment, not a ship


; ----------------------------------------------------------------------------
;  grid_init
;  Uses: AF, HL
; ----------------------------------------------------------------------------
grid_init:
    ld a,#FF
    ld (grid_shadow),a                  ; force the first projection
    xor a
    ld (grid_visible),a
    ret


; ----------------------------------------------------------------------------
;  grid_update -- reproject the lattice, but only if the camera has moved
;
;  The comparison is over yaw, pitch, zoom and the focus point, which between
;  them are the whole of what the projection depends on.
;  Uses: everything
; ----------------------------------------------------------------------------
grid_update:
    ld a,(cam_yaw)
    ld c,a
    ld a,(cam_pitch)
    xor c
    ld c,a
    ld a,(cam_zoom)
    xor c
    ld c,a
    ld a,(cam_focus_x)
    xor c
    ld c,a
    ld a,(cam_focus_z)
    xor c
    ld hl,grid_shadow
    cp (hl)
    ret z                               ; nothing the grid cares about moved
    ld (hl),a

    ld hl,grid_lattice
    ld (grid_src),hl
    ld hl,grid_cache
    ld (grid_dst),hl
    xor a
    ld (grid_visible),a
    ld a,GRID_POINTS
    ld (grid_left),a

@grid_one:
    ld hl,(grid_src)
    call proj_point
    jr nc,@grid_next                    ; clipped; leave it out of the cache

    ld hl,(grid_dst)
    ld de,(proj_sx)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(proj_sy)
    ld (hl),a
    inc hl
    ld (grid_dst),hl
    ld hl,grid_visible
    inc (hl)

@grid_next:
    ld hl,(grid_src)
    ld de,6
    add hl,de
    ld (grid_src),hl
    ld hl,grid_left
    dec (hl)
    jr nz,@grid_one
    ret


; ----------------------------------------------------------------------------
;  grid_draw -- replot the cached dots
;
;  Drawn FIRST, before the ships, so a ship over the plane hides the plane
;  rather than the other way round.
;  Uses: everything
; ----------------------------------------------------------------------------
grid_draw:
    ld a,(grid_visible)
    or a
    ret z
    ld (grid_left),a
    ld hl,grid_cache
    ld (grid_src),hl

@grid_dot:
    ld hl,(grid_src)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    inc hl
    ld (grid_src),hl

    ld c,a
    ld (grid_dot_y),a
    ex de,hl                            ; HL = screen x
    ld (grid_dot_x),hl
    ld b,1
    ld a,GRID_INK
    call gfx_vline

    ;  Record it, or a camera move leaves the old plane behind as a smear.
    ld hl,(grid_dot_x)
    srl h
    rr l
    srl h
    rr l
    ld a,l
    ld (phase4_disc_rect + 0),a
    ld a,(grid_dot_y)
    ld (phase4_disc_rect + 1),a
    ld a,1
    ld (phase4_disc_rect + 2),a
    ld (phase4_disc_rect + 3),a

    ld hl,phase4_disc_rect
    ld de,(phase4_rect_ptr)
    ld b,4
@grid_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz @grid_copy
    ld (phase4_rect_ptr),de
    ld hl,phase4_rect_count
    inc (hl)
    ld hl,(phase4_count)
    ld a,(phase4_rect_count)
    ld (hl),a

    ld hl,grid_left
    dec (hl)
    jr nz,@grid_dot
    ret


; ============================================================================
;  State
; ============================================================================
grid_shadow:        defb #FF            ; a hash of the camera, for "has it moved"
grid_src:           defw 0
grid_dst:           defw 0
grid_left:          defb 0
grid_visible:       defb 0
grid_dot_x:         defw 0
grid_dot_y:         defb 0

;  sx (2 bytes) and sy, per point that survived clipping.
grid_cache:         defs GRID_POINTS * 3, 0
