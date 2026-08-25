; ============================================================================
;  game/order.asm -- camera control and the move disc (Homeplanet.md section 9)
; ============================================================================
;  Controlling a 3D fleet from a keyboard is the hardest part of the design.
;  The answer the document settles on is orders PER SQUADRON, never per ship,
;  and a cursor that moves on the Y=0 reference plane with a vertical line
;  showing its height -- Homeworld's move disc, which costs about twenty
;  pixels to draw.
;
;  Key assignment
;  --------------
;  Section 9 puts the move order on `M` and docking on `D`, but those keys now
;  belong to the squadron commands. So:
;
;      ENTER   open the move disc; ENTER again confirms, ESC cancels
;      R       return to the Mothership (was `D`)
;
;  ENTER doing both the opening and the confirming is not a compromise: the
;  document already had it as the confirm key, and a mode you enter and leave
;  with the same key is one less thing to remember.
;
;  While the disc is open the cursor keys drive IT, not the camera. That is
;  the document's intent and it is why the disc is a mode at all.
;
;  Disc movement is camera-relative, so "up" always means away from you. The
;  camera's yaw is rounded to one of eight octants and the step vector comes
;  out of a table -- no multiplies, and at 45 degrees of granularity the
;  difference from a true rotation is not perceptible on a 320-pixel screen.
; ----------------------------------------------------------------------------

CAM_YAW_STEP        equ 8               ; 256/8 = the 32 yaw steps of section 4.3
CAM_PITCH_STEP      equ 4               ; 16 steps
CAM_PITCH_MAX       equ 53              ; +/-75 degrees

DISC_STEP           equ 1600            ; world units per frame held
DISC_STEP_DIAG      equ 1131            ; the same length at 45 degrees
DISC_LIMIT          equ 30000           ; keep well inside the 16-bit world

;  Ink used to draw the disc and its height line.
DISC_INK_TOP        equ 1               ; the disc itself: friendly white
DISC_INK_STEM       equ 2               ; the line down to the plane


; ----------------------------------------------------------------------------
;  order_init -- give every squadron a starting station
;  Uses: everything
; ----------------------------------------------------------------------------
order_init:
    ld hl,order_home
    ld de,squad_dest
    ld bc,SQUAD_MAX * 6
    ldir
    xor a
    ld (disc_active),a
    ld (order_paused),a
    ld a,1
    ld (cam_zoom),a
    jp order_apply_zoom


; ----------------------------------------------------------------------------
;  order_update -- one frame of input
;  Uses: everything
; ----------------------------------------------------------------------------
order_update:
    ;  Cursor keys belong to whichever thing is in charge.
    ld a,(disc_active)
    or a
    jr nz,@ord_disc_has_cursors
    call order_camera
    jr @ord_shared
@ord_disc_has_cursors:
    call order_disc_move

@ord_shared:
    call order_zoom

    ld a,KEY_SPACE
    call key_hit
    jr nc,@ord_no_pause
    ld hl,order_paused
    ld a,(hl)
    xor 1
    ld (hl),a
@ord_no_pause:

    ld a,KEY_ENTER
    call key_hit
    jr nc,@ord_no_enter
    ld a,(disc_active)
    or a
    jr nz,@ord_confirm
    call order_disc_open
    jr @ord_no_enter
@ord_confirm:
    call order_disc_confirm
@ord_no_enter:

    ld a,KEY_ESC
    call key_hit
    ret nc
    xor a
    ld (disc_active),a
    ret


; ----------------------------------------------------------------------------
;  order_camera -- cursor keys orbit, within the pitch limits
;  Uses: everything
; ----------------------------------------------------------------------------
order_camera:
    ld a,KEY_CUR_LEFT
    call key_down
    jr nc,@ord_no_left
    ld hl,cam_yaw
    ld a,(hl)
    sub CAM_YAW_STEP
    ld (hl),a
@ord_no_left:

    ld a,KEY_CUR_RIGHT
    call key_down
    jr nc,@ord_no_right
    ld hl,cam_yaw
    ld a,(hl)
    add a,CAM_YAW_STEP
    ld (hl),a
@ord_no_right:

    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_no_up
    ld a,(cam_pitch)
    add a,CAM_PITCH_STEP
    call order_clamp_pitch
    ld (cam_pitch),a
@ord_no_up:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld a,(cam_pitch)
    sub CAM_PITCH_STEP
    call order_clamp_pitch
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  order_clamp_pitch -- hold a signed pitch inside +/-CAM_PITCH_MAX
;  In/Out: A
;  Uses: AF, B
;
;  Biasing by the limit turns the two-sided signed test into one unsigned
;  range check: anything valid lands in 0..2*MAX once shifted up.
; ----------------------------------------------------------------------------
order_clamp_pitch:
    ld b,a
    add a,CAM_PITCH_MAX
    cp CAM_PITCH_MAX * 2 + 1
    jr c,@ord_pitch_ok
    bit 7,b
    jr nz,@ord_pitch_low
    ld b,CAM_PITCH_MAX
    jr @ord_pitch_ok
@ord_pitch_low:
    ld b,-CAM_PITCH_MAX
@ord_pitch_ok:
    ld a,b
    ret


; ----------------------------------------------------------------------------
;  order_zoom -- Z closer, X further, four steps (section 4.3)
;  Uses: everything
; ----------------------------------------------------------------------------
order_zoom:
    ld a,KEY_Z
    call key_hit
    jr nc,@ord_no_in
    ld hl,cam_zoom
    ld a,(hl)
    or a
    jr z,@ord_no_in
    dec (hl)
    call order_apply_zoom
@ord_no_in:

    ld a,KEY_X
    call key_hit
    ret nc
    ld hl,cam_zoom
    ld a,(hl)
    cp CAM_ZOOM_STEPS - 1
    ret nc
    inc (hl)
    ; fall through

; ----------------------------------------------------------------------------
;  order_apply_zoom -- cam_dist = cam_zoom_dist[cam_zoom]
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
order_apply_zoom:
    ld a,(cam_zoom)
    add a,a                             ; a table of words
    ld l,a
    ld h,0
    ld de,cam_zoom_dist
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (cam_dist),de
    ret


; ----------------------------------------------------------------------------
;  order_disc_open -- start a move order at the squadron's current station
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_open:
    call order_dest_addr                ; HL -> squad_dest[selection]
    ld de,disc_pos
    ld bc,6
    ldir
    ld a,1
    ld (disc_active),a
    ret


; ----------------------------------------------------------------------------
;  order_disc_confirm -- hand the disc position to the selected squadron
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_confirm:
    call order_dest_addr
    ex de,hl                            ; DE -> squad_dest[selection]
    ld hl,disc_pos
    ld bc,6
    ldir
    xor a
    ld (disc_active),a
    ret


; ----------------------------------------------------------------------------
;  order_dest_addr -- HL = &squad_dest[squad_sel]
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
order_dest_addr:
    ld a,(squad_sel)
    dec a                               ; squadrons are 1-based
    call phase4_times6
    ld de,squad_dest
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  order_disc_move -- cursor keys drive the disc across the reference plane
;
;  SHIFT swaps up/down from "away and towards" to "higher and lower", which is
;  the one piece of 3D the player has to steer by hand. The vertical line down
;  to Y=0 is what makes that legible; see order_draw_disc.
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_move:
    ;  Round the camera yaw to one of eight octants: +16 to round rather than
    ;  truncate, then take the top three bits.
    ld a,(cam_yaw)
    add a,16
    rrca
    rrca
    rrca
    rrca
    rrca
    and 7
    ld (disc_octant),a

    ld a,KEY_SHIFT
    call key_down
    jr c,@ord_vertical

    ld a,KEY_CUR_RIGHT
    call key_down
    jr nc,@ord_disc_no_right
    ld a,(disc_octant)
    call order_disc_step_plus
@ord_disc_no_right:

    ld a,KEY_CUR_LEFT
    call key_down
    jr nc,@ord_disc_no_left
    ld a,(disc_octant)
    call order_disc_step_minus
@ord_disc_no_left:

    ;  Forward is right turned a quarter turn, which in octants is +2.
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_disc_no_fwd
    ld a,(disc_octant)
    add a,2
    and 7
    call order_disc_step_plus
@ord_disc_no_fwd:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld a,(disc_octant)
    add a,2
    and 7
    jp order_disc_step_minus

@ord_vertical:
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@ord_disc_no_rise
    ld hl,disc_pos + 2                  ; the Y axis
    ld de,DISC_STEP
    call order_add_clamped
@ord_disc_no_rise:

    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld hl,disc_pos + 2
    ld de,-DISC_STEP
    jp order_add_clamped


; ----------------------------------------------------------------------------
;  order_disc_step_plus / _minus -- move the disc along octant direction A
;  In : A = octant 0..7
;  Uses: everything
; ----------------------------------------------------------------------------
order_disc_step_plus:
    ld (disc_sign),a
    xor a
    ld (disc_negate),a
    jr order_disc_step

order_disc_step_minus:
    ld (disc_sign),a
    ld a,1
    ld (disc_negate),a

order_disc_step:
    ld a,(disc_sign)
    add a,a
    add a,a                             ; four bytes an entry: dx, dz
    ld l,a
    ld h,0
    ld de,order_octant_step
    add hl,de

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    push hl
    call order_maybe_negate
    ld hl,disc_pos + 0                  ; X
    call order_add_clamped
    pop hl

    ld e,(hl)
    inc hl
    ld d,(hl)
    call order_maybe_negate
    ld hl,disc_pos + 4                  ; Z
    jp order_add_clamped


;  DE = -DE if (disc_negate)
;  Uses: AF, DE
order_maybe_negate:
    ld a,(disc_negate)
    or a
    ret z
    ld a,e
    cpl
    ld e,a
    ld a,d
    cpl
    ld d,a
    inc de
    ret


; ----------------------------------------------------------------------------
;  order_add_clamped -- (HL) += DE, held inside +/-DISC_LIMIT
;  In : HL -> a 16-bit signed world coordinate, DE = the delta
;  Uses: AF, BC, DE, HL
;
;  Clamped rather than allowed to wrap: the world is 16-bit signed, and a disc
;  that walks off the positive edge and reappears at the negative one would be
;  a very confusing thing to have happen while you are holding a cursor key.
; ----------------------------------------------------------------------------
order_add_clamped:
    ld c,(hl)
    inc hl
    ld b,(hl)
    dec hl
    push hl
    ld h,b
    ld l,c
    add hl,de

    ;  Past the positive limit?
    ld bc,DISC_LIMIT
    ld a,h
    bit 7,a
    jr nz,@ord_check_low
    or a
    sbc hl,bc
    add hl,bc
    jr c,@ord_store                     ; below the limit
    ld hl,DISC_LIMIT
    jr @ord_store

@ord_check_low:
    ld bc,-DISC_LIMIT
    or a
    sbc hl,bc
    add hl,bc
    jr nc,@ord_store                    ; at or above the negative limit
    ld hl,-DISC_LIMIT

@ord_store:
    ex de,hl
    pop hl
    ld (hl),e
    inc hl
    ld (hl),d
    ret


; ============================================================================
;  State
; ============================================================================

;  Where each squadron is stationed. A move order rewrites the entry for the
;  selected squadron and the formation follows, so this is the ONLY thing an
;  order changes -- no per-ship destinations to keep in step.
squad_dest:         defs SQUAD_MAX * 6, 0

disc_active:        defb 0
disc_pos:           defs 6, 0
disc_octant:        defb 0
disc_sign:          defb 0
disc_negate:        defb 0

order_paused:       defb 0

;  The camera's "right" direction on the Y=0 plane, per octant of yaw, already
;  scaled to one frame's movement. Forward is the entry two octants on.
order_octant_step:
    defw  DISC_STEP,           0
    defw  DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw  0,                   DISC_STEP
    defw -DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw -DISC_STEP,           0
    defw -DISC_STEP_DIAG,     -DISC_STEP_DIAG
    defw  0,                  -DISC_STEP
    defw  DISC_STEP_DIAG,     -DISC_STEP_DIAG

;  Starting stations. Squadron 1 sits in the middle of the battle and the rest
;  fan out around it, spread in Z as well as X so ships sit at genuinely
;  different depths and so at different sprite tiers.
order_home:
    defw      0,  2000,      0           ; 1
    defw -18000, -3000,   8000           ; 2
    defw  18000,  3000,  -8000           ; 3
    defw -12000, -2000,  16000           ; 4
    defw  12000,  2500, -16000           ; 5
    defw  -6000, -3000, -12000           ; 6
    defw   6000,  2000,  12000           ; 7
    defw -24000, -2500,   4000           ; 8
    defw  24000,  3000,  -4000           ; 9
