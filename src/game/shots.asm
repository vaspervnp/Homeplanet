; ============================================================================
;  game/shots.asm -- shots you can see (future.md item 4), in bank 4
; ============================================================================
;  A shot used to be a sound and a hull byte. Now it is three dots on the line
;  between the shooter and its target -- a quarter, a half and three quarters
;  of the way along -- in the SHOOTER's ink, for one frame. It reads as fire
;  because it flashes between the two ships that are fighting, and it costs
;  nothing to time: a shot lands the frame it is fired.
;
;  THE DOTS ERASE THEMSELVES, and that is the whole shape of the file. Every
;  other marker appends a dirty rectangle and lets phase4_erase clean up, and
;  that is the right thing for a marker -- but a tracer's three dots are up to
;  a hundred pixels apart, so one rectangle round them is thousands of bytes
;  to clear a frame, and three rectangles a shot is a hundred bytes of the
;  low 16K's address space, which is at its floor. So each buffer keeps its
;  own list of the (address, mask) pairs it was given, and shot_erase ANDs
;  them back out before that buffer's ships are drawn again. No rectangle,
;  no low-16K state, and the erase is one AND a dot.
;
;  WHERE A SHIP IS ON THE SCREEN is not in phase4_vis by slot -- the visible
;  list is in draw order and carries no index -- so shot_cache, called from
;  phase4_cache, keeps a per-slot copy of the projection with the frame it
;  was made in stamped beside it. A shot whose shooter or target was not
;  projected THIS frame draws nothing: one of them is off the screen, and a
;  tracer to a point off the edge is a tracer to nowhere.
;
;  Two call sites in the low 16K, three bytes each: phase4_cache and the fire
;  path of cbt_fire_if_able. Both run with the window at rest.
; ----------------------------------------------------------------------------

;  THE FLOWN SHIP'S OWN SHOT IS A BOLT, AND IT FLIES -- "να φαίνεται η βολή
;  μου που πηγαίνει προς τον εχθρό". Every other tracer lands the frame it
;  is fired; the pilot's leaves the bottom of the view (the ship itself is
;  never drawn; its gun is under the nose) and crosses to its target over SHOT_BOLT_STEPS frames, a
;  quarter of the way a frame, two pixels long so it reads as a streak,
;  aimed afresh each frame at where the target IS. One in flight at a time;
;  the damage still lands when the gun fires, the picture follows.
;  shot_note arms it instead of listing the shot, shot_bolt draws it from
;  the top of shot_draw, and it goes through the same dot lists so the same
;  erase takes it off.

;  Tracers a frame. Four is a busy frame; the fleet fires once in
;  CBT_COOLDOWN frames a ship, and what is dropped past four is dropped.
SHOT_MAX            equ 4
;  ...and their dots, plus the bolt's two.
SHOT_DOTS           equ SHOT_MAX * 3 + 2
;  The bolt is drawn on steps 1..SHOT_BOLT_STEPS-1, at step/SHOT_BOLT_STEPS
;  of the way; on the last it is gone.
SHOT_BOLT_STEPS     equ 4
;  ...FROM THE GUN UNDER THE NOSE, at the bottom of the view, not from the
;  reticle. "Δεν βλέπω στο V να βαράω με το space": with a target locked and
;  held in the reticle, a bolt from the middle of the view to the target is a
;  bolt of no length, two white pixels on top of a red sprite. From the
;  bottom centre it crosses seventy lines to a centred target -- Elite's gun.
SHOT_MUZZLE_Y       equ HUD_TOP - 6
;  A dot in a buffer's list: the byte's address and the mask that was ORed in.
SHOT_DOT_SIZE       equ 3
SHOT_LIST_SIZE      equ 1 + SHOT_DOTS * SHOT_DOT_SIZE
;  A slot's cached projection: sx, sy, and the frame it belongs to.
SHOT_POS_SIZE       equ 4


; ----------------------------------------------------------------------------
;  shot_cache -- remember where this frame put the ship being projected
;  In : (proj_sx), (proj_sy) as phase4_cache is about to read them;
;       (phase4_index) counting DOWN, so the slot is ENT_MAX - it
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
shot_cache:
    ld a,(phase4_index)
    neg
    add a,ENT_MAX                       ; the slot
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; * SHOT_POS_SIZE, past 255 for the top slots
    ld de,shot_pos
    add hl,de
    ld de,(proj_sx)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(proj_sy)
    ld (hl),a
    inc hl
    ld a,(demo_frames)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  shot_note -- a shot was just fired: remember who at whom
;  In : (cbt_index) counting DOWN, so the shooter is ENT_MAX - it (the same
;       arithmetic cbt_retaliate uses); (cbt_target) = the victim
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
shot_note:
    ld a,(cbt_index)
    neg
    add a,ENT_MAX
    ld hl,pilot_slot
    cp (hl)
    jr z,@shot_note_bolt                ; the flown ship: a bolt, not a tracer
    ld a,(shot_count)
    cp SHOT_MAX
    ret nc                              ; a busy frame: the rest are not drawn
    inc a
    ld (shot_count),a
    dec a
    add a,a
    ld e,a
    ld d,0
    ld hl,shot_list
    add hl,de
    ld a,(cbt_index)
    neg
    add a,ENT_MAX
    ld (hl),a
    inc hl
    ld a,(cbt_target)
    ld (hl),a
    ret
@shot_note_bolt:
    ld a,1
    ld (shot_bolt_step),a
    ld a,(cbt_target)
    ld (shot_bolt_victim),a
    ret


; ----------------------------------------------------------------------------
;  shot_lists -- HL -> the dot list of the buffer about to be drawn
;  Uses: AF, HL
; ----------------------------------------------------------------------------
shot_lists:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    ld hl,shot_dots_a
    ret z
    ld hl,shot_dots_b
    ret


; ----------------------------------------------------------------------------
;  shot_erase -- take last time's dots off this buffer, before its ships
;
;  From the top of mark_update: after phase4_erase, before anything this frame
;  draws, so a dot that sat on a ship is gone before the ship is drawn again
;  and a dot that sat on black goes back to black. Cleared with the mask that
;  was set, so a pen-3 pixel under a pen-1 dot keeps its other plane.
;  Uses: everything
; ----------------------------------------------------------------------------
shot_erase:
    call shot_lists
    ld a,(hl)
    or a
    ret z
    ld b,a
    ld (hl),0
    inc hl
@shot_erase_one:
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    inc hl
    cpl
    ld c,a
    ld a,(de)
    and c
    ld (de),a
    djnz @shot_erase_one
    ret


; ----------------------------------------------------------------------------
;  shot_where -- where slot A was put on the screen THIS frame
;  In : A = slot
;  Out: HL = sx, C = sy, CF set if it was projected this frame
;  Uses: AF, DE, HL, C
;
;  The stamp is demo_frames, one byte, so a slot last seen exactly 256 frames
;  ago and not since reads as current for one frame: a tracer to where a ship
;  used to be, once every fifty seconds at most, for a ship that has been off
;  the screen the whole time. Not worth a second byte.
; ----------------------------------------------------------------------------
shot_where:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld de,shot_pos
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld a,(demo_frames)
    cp (hl)
    ex de,hl
    jr nz,@shot_stale
    scf
    ret
@shot_stale:
    or a
    ret


; ----------------------------------------------------------------------------
;  shot_draw -- this frame's tracers, after the ships
;
;  From wave_draw, which runs once a playing frame after phase4_draw and is
;  bank 4 already, so the low 16K pays nothing for the call. The list is
;  emptied on the way out whether or not anything was drawable.
;  Uses: everything
; ----------------------------------------------------------------------------
shot_draw:
    call shot_bolt                      ; the flown ship's own shot, in flight
    ld a,(shot_count)
    or a
    ret z
    ld (shot_left),a
    ld hl,shot_list
    ld (shot_ptr),hl
@shot_next:
    ld hl,(shot_ptr)
    ld a,(hl)
    ld (shot_shooter),a
    inc hl
    ld a,(hl)
    ld (shot_victim),a
    inc hl
    ld (shot_ptr),hl

    ld a,(shot_shooter)
    call shot_where
    jp nc,@shot_done_one                ; one of them is off the screen: no tracer
    ld (shot_ax),hl
    ld l,c
    ld h,0
    ld (shot_ay),hl
    ld a,(shot_victim)
    call shot_where
    jp nc,@shot_done_one
    call shot_quarter

    ;  The shooter's ink: ENT_F_ENEMY is bit 1, so `and 2 : or 1` is 3 for
    ;  theirs and 1 for ours -- section 2's inks, read straight off the flag.
    ld a,(shot_shooter)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    or PEN_WHITE
    add a,a
    add a,a                             ; four masks a pen in gfx_pen_mask
    ld (shot_pen4),a

    ld b,3
@shot_dot:
    push bc
    call shot_advance
    call shot_plot
    pop bc
    djnz @shot_dot

@shot_done_one:
    ld hl,shot_left
    dec (hl)
    jp nz,@shot_next
    xor a
    ld (shot_count),a
    ret


; ----------------------------------------------------------------------------
;  shot_bolt -- the flown ship's shot, one step further along its flight
;  Uses: everything
;
;  Drawn from the muzzle at the bottom of the view (SHOT_MUZZLE_Y, under the
;  reticle) to where its target was projected THIS frame -- so a target that
;  moves is still hit, on the screen as in the hull. Two dots, the second
;  half a step on. Dropped the frame nobody is flying or the target is off
;  the screen; spent by itself on the last step.
; ----------------------------------------------------------------------------
shot_bolt:
    ld a,(shot_bolt_step)
    or a
    ret z
    ld b,a                              ; B = this frame's step, 1..
    inc a
    cp SHOT_BOLT_STEPS
    jr c,@sb_more
    xor a                               ; the last: gone after this one
@sb_more:
    ld (shot_bolt_step),a
    ld a,(pilot_slot)
    cp ENT_MAX
    jr nc,@sb_off
    ld a,(shot_bolt_victim)
    call shot_where
    jr nc,@sb_off                       ; HL = sx, C = sy
    ld de,SCR_CENTRE_X
    ld (shot_ax),de
    ld de,SHOT_MUZZLE_Y
    ld (shot_ay),de
    call shot_quarter
    ld a,PEN_WHITE * 4
    ld (shot_pen4),a
@sb_step:
    push bc
    call shot_advance
    pop bc
    djnz @sb_step
    call shot_plot
    ;  ...and the second pixel, half a step on.
    ld hl,(shot_dx)
    sra h
    rr l
    ld (shot_dx),hl
    ld hl,(shot_dy)
    sra h
    rr l
    ld (shot_dy),hl
    call shot_advance
    jp shot_plot
@sb_off:
    xor a
    ld (shot_bolt_step),a
    ret


; ----------------------------------------------------------------------------
;  shot_quarter -- a quarter of the way from (shot_ax, shot_ay) to HL, C
;  In : HL = the target's sx, C = its sy; (shot_ax), (shot_ay) = from
;  Out: (shot_dx), (shot_dy) = the step, signed
;  Uses: AF, DE, HL
;
;  sy is 0..199 either end, so the difference wants nine bits.
; ----------------------------------------------------------------------------
shot_quarter:
    ld de,(shot_ax)
    or a
    sbc hl,de
    sra h
    rr l
    sra h
    rr l
    ld (shot_dx),hl
    ld a,(shot_ay)
    ld l,a
    ld a,c
    sub l
    ld e,a
    sbc a,a                             ; the borrow, spread: #FF below zero
    ld d,a
    sra d
    rr e
    sra d
    rr e
    ld (shot_dy),de
    ret


; ----------------------------------------------------------------------------
;  shot_advance -- (shot_ax, shot_ay) += (shot_dx, shot_dy)
;  Uses: DE, HL
; ----------------------------------------------------------------------------
shot_advance:
    ld hl,(shot_ax)
    ld de,(shot_dx)
    add hl,de
    ld (shot_ax),hl
    ld hl,(shot_ay)
    ld de,(shot_dy)
    add hl,de
    ld (shot_ay),hl
    ret


; ----------------------------------------------------------------------------
;  shot_plot -- one dot at (shot_ax, shot_ay) in (shot_pen4), remembered
;  Uses: everything
;
;  Inside the playfield, or not at all: a ship's centre may sit in the HUD's
;  strip -- the sprite is clipped there, this has to clip itself. If the
;  buffer's list is full the dot stays on the screen until something else
;  passes over it.
; ----------------------------------------------------------------------------
shot_plot:
    ld hl,(shot_ay)
    ld a,h
    or a
    ret nz
    ld a,l
    cp HUD_TOP
    ret nc
    cp CTX_BAR_H
    ret c
    ld hl,(shot_ax)
    call gfx_pixel_setup                ; DE = the byte, C = the pixel
    ld a,(shot_pen4)
    add a,c
    ld c,a
    ld b,0
    ld hl,gfx_pen_mask
    add hl,bc
    ld c,(hl)                           ; the mask
    ld a,(de)
    or c
    ld (de),a
    ;  ...and remembered, so shot_erase can take it off again.
    call shot_lists
    ld a,(hl)
    cp SHOT_DOTS
    ret nc                              ; the list is full: it stays on screen
    ld b,a
    inc (hl)
    inc hl
    add a,a
    add a,b                             ; * SHOT_DOT_SIZE
    add a,l
    ld l,a
    jr nc,@shot_entry
    inc h
@shot_entry:
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),c
    ret
