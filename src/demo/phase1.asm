; ============================================================================
;  demo/phase1.asm -- the Phase 1 acceptance test
; ============================================================================
;  Success criterion from Homeplanet.md section 13:
;      "100 σημεία περιστρέφονται στα 12,5 fps"
;
;  A 5 x 5 x 4 lattice of 100 world points, orbited by the camera and plotted
;  one pixel each. A lattice rather than a random cloud on purpose: rotation
;  errors show up immediately as a grid that shears or breathes, where a cloud
;  of dots would hide them.
;
;  The frame is paced to 4 VSYNCs. If the work overruns, the frame simply
;  takes longer and the rate drops -- which is exactly what the performance
;  test measures, by counting phase1_frames over a known wall-clock window.
; ----------------------------------------------------------------------------

PHASE1_POINTS           equ 100
PHASE1_TICKS_PER_FRAME  equ 4           ; 50 Hz / 4 = 12.5 fps

;  Per plotted pixel we remember where it went and how to undo it:
;      +0 address (2 bytes), +2 AND-mask that clears just that pixel
PHASE1_SLOT_SIZE        equ 3


; ----------------------------------------------------------------------------
;  phase1_init
;  Uses: everything
; ----------------------------------------------------------------------------
phase1_init:
    xor a
    ld (phase1_drawn_a),a
    ld (phase1_drawn_b),a
    ld (phase1_frames),a
    ld a,(sys_tick_50hz)
    ld (phase1_tick0),a

    ld hl,150
    ld (cam_dist),hl
    xor a
    ld (cam_yaw),a
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  phase1_update -- one frame into the back buffer
;  Uses: everything
; ----------------------------------------------------------------------------
phase1_update:
    call phase1_select_list
    call phase1_erase
    call phase1_move_camera
    call cam_build_matrix
    call phase1_draw

    ld hl,phase1_frames
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  phase1_select_list -- point phase1_slots / phase1_count at the back buffer's
;
;  Each buffer needs its own record of what is in it: with double buffering
;  the back buffer holds the frame from two ticks ago, not one.
;  Uses: AF, HL
; ----------------------------------------------------------------------------
phase1_select_list:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    jr z,@buffer_a
    ld hl,phase1_slots_b
    ld (phase1_slots),hl
    ld hl,phase1_drawn_b
    ld (phase1_count),hl
    ret
@buffer_a:
    ld hl,phase1_slots_a
    ld (phase1_slots),hl
    ld hl,phase1_drawn_a
    ld (phase1_count),hl
    ret


; ----------------------------------------------------------------------------
;  phase1_erase -- undo every pixel this buffer is holding
;  Uses: everything
; ----------------------------------------------------------------------------
phase1_erase:
    ld hl,(phase1_count)
    ld a,(hl)
    or a
    ret z
    ld b,a
    ld hl,(phase1_slots)
@slot:
    push bc
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)                           ; the AND-mask
    inc hl
    push hl
    ex de,hl
    ld a,(hl)
    and c
    ld (hl),a
    pop hl
    pop bc
    djnz @slot
    ret


; ----------------------------------------------------------------------------
;  phase1_move_camera -- yaw round steadily, pitch breathing slowly
;  Uses: AF, HL
; ----------------------------------------------------------------------------
phase1_move_camera:
    ld hl,cam_yaw
    inc (hl)
    inc (hl)

    ;  pitch = sin7[slow] >> 2, so +/-31 of 256 -- about +/-44 degrees, inside
    ;  the +/-75 the design allows.
    ld hl,phase1_pitch_phase
    inc (hl)
    ld a,(hl)
    call cam_sin
    sra a
    sra a
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  phase1_draw -- project all 100 points and plot the survivors
;  Uses: everything
; ----------------------------------------------------------------------------
phase1_draw:
    xor a
    ld (phase1_drawn),a
    ld hl,(phase1_slots)
    ld (phase1_slot_ptr),hl

    ld hl,phase1_point_table
    ld (phase1_point_ptr),hl

    ld a,PHASE1_POINTS
    ld (phase1_remaining),a

@point:
    ld hl,(phase1_point_ptr)
    call proj_point
    ;  Test the carry IMMEDIATELY. Advancing the pointer first would work on
    ;  paper and fail here, because ADD HL,DE writes the carry flag.
    call c,phase1_plot

    ld hl,(phase1_point_ptr)
    ld de,6
    add hl,de
    ld (phase1_point_ptr),hl
    ld hl,phase1_remaining
    dec (hl)
    jr nz,@point

    ld hl,(phase1_count)
    ld a,(phase1_drawn)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase1_plot -- set one ink-1 pixel at (proj_sx, proj_sy) and record it
;  Uses: everything
; ----------------------------------------------------------------------------
phase1_plot:
    ld a,(proj_sy)
    call scr_line_addr                  ; HL = start of that line, back buffer

    ld de,(proj_sx)
    ld a,e
    and 3
    ld c,a                              ; pixel position within the byte
    ld a,d
    srl a
    rr e
    srl a
    rr e                                ; E = sx >> 2; sx < 320 so A is now 0
    ld d,a
    add hl,de                           ; HL = the byte holding this pixel

    ;  The two mask tables are adjacent, so one index reaches both: the
    ;  clearing mask for pixel p is four bytes past the setting mask.
    ld b,0
    push hl
    ld hl,phase1_set_mask
    add hl,bc
    ld e,(hl)                           ; OR-mask, sets the pixel to ink 1
    ld bc,phase1_clr_mask - phase1_set_mask
    add hl,bc
    ld d,(hl)                           ; AND-mask, clears it again
    pop hl                              ; HL = the byte address

    ld a,(hl)
    or e
    ld (hl),a

    ; --- remember it so this buffer's next pass can undo it ---------------
    ld a,d                              ; keep the AND-mask across the EX
    ex de,hl                            ; DE = the byte address
    ld hl,(phase1_slot_ptr)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (hl),a
    inc hl
    ld (phase1_slot_ptr),hl

    ld hl,phase1_drawn
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  Data
; ----------------------------------------------------------------------------

;  Mode 1 pixel masks. A byte is four pixels, bit-planes interleaved as
;  A0 B0 C0 D0 A1 B1 C1 D1, so pen 1 (bit-plane 0 only) is bit 7-p, and the
;  two bits a pixel occupies at all are #88 >> p.
phase1_set_mask:    defb #80, #40, #20, #10
phase1_clr_mask:    defb #77, #BB, #DD, #EE

phase1_slots:       defw 0              ; -> the back buffer's slot array
phase1_count:       defw 0              ; -> the back buffer's count byte
phase1_slot_ptr:    defw 0
phase1_point_ptr:   defw 0
phase1_remaining:   defb 0
phase1_drawn:       defb 0

phase1_pitch_phase: defb 0
phase1_tick0:       defb 0
phase1_frames:      defb 0

phase1_drawn_a:     defb 0
phase1_drawn_b:     defb 0
phase1_slots_a:     defs PHASE1_POINTS * PHASE1_SLOT_SIZE, 0
phase1_slots_b:     defs PHASE1_POINTS * PHASE1_SLOT_SIZE, 0

;  A 5 x 5 x 4 lattice, 8192 world units apart. The whole 16-bit world maps
;  onto a +/-128 camera cube, so 8192 units is 32 camera units -- the lattice
;  spans most of the view at cam_dist 150.
phase1_point_table:
pz = 0
    repeat 4
px = 0
        repeat 5
py = 0
            repeat 5
                defw (px - 2) * 8192
                defw (py - 2) * 8192
                defw (pz * 2 - 3) * 4096
py = py + 1
            rend
px = px + 1
        rend
pz = pz + 1
    rend
phase1_point_table_end:

    assert (phase1_point_table_end - phase1_point_table) / 6 == PHASE1_POINTS, "lattice is not 100 points"


; ----------------------------------------------------------------------------
;  phase1_wait_frame -- hold the loop to 12.5 fps
;
;  If drawing already overran the budget this returns immediately and the
;  frame rate drops, which is the honest behaviour and what the test measures.
;  Uses: AF, HL
; ----------------------------------------------------------------------------
phase1_wait_frame:
    ld a,(sys_tick_50hz)
    ld hl,phase1_tick0
    sub (hl)
    cp PHASE1_TICKS_PER_FRAME
    jr c,phase1_wait_frame
    ld a,(sys_tick_50hz)
    ld (phase1_tick0),a
    ret
