; ============================================================================
;  demo/phase3.asm -- Phase 2 and 3 acceptance test
; ============================================================================
;  Homeplanet.md section 13:
;    Phase 2: "24 sprites κινούνται χωρίς σκιές/υπολείμματα"
;    Phase 3: "Ένα σκάφος, 8 όψεις, 3 βαθμίδες, στην οθόνη"
;
;  A squadron of interceptors sits in a lattice while the camera orbits them.
;  Each ship picks its yaw view from its heading relative to the camera and
;  its size tier from its depth, so orbiting once exercises all 8 views, and
;  the near/far spread exercises all 3 tiers at the same time.
;
;  Only ONE class is linked in. Three would be 16.9 KB of sprite data and the
;  low 16K does not have it -- multi-class needs the bank window at #4000,
;  which is Phase 8 work.
; ----------------------------------------------------------------------------

PHASE3_SHIP_COUNT        equ 16
PHASE3_ENT_SIZE     equ 8               ; x,y,z (6), heading, spare

;  Screen cache per visible ship (Homeplanet.md section 7).
PHASE3_VIS_SIZE     equ 6
PHASE3_V_SX         equ 0               ; 2 bytes
PHASE3_V_SY         equ 2
PHASE3_V_Z          equ 3
PHASE3_V_VIEW       equ 4
PHASE3_V_TIER       equ 5

;  Tier descriptor, 8 bytes each, indexed by tier_lut.
PHASE3_T_BASE       equ 0               ; 2 bytes
PHASE3_T_WBYTES     equ 2
PHASE3_T_H          equ 3
PHASE3_T_HALFW      equ 4               ; half the width, in PIXELS
PHASE3_T_HALFH      equ 5
PHASE3_T_BLOCKSZ    equ 6               ; 2 bytes
PHASE3_T_SIZE       equ 8

DEMO_TICKS_PER_FRAME equ 4              ; 50 Hz / 4 = 12.5 fps


; ----------------------------------------------------------------------------
;  demo_init
; ----------------------------------------------------------------------------
demo_init:
    xor a
    ld (phase3_drawn_a),a
    ld (phase3_drawn_b),a
    ld (demo_frames),a
    ld a,(sys_tick_50hz)
    ld (demo_tick0),a

    ld hl,150
    ld (cam_dist),hl
    xor a
    ld (cam_yaw),a
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  demo_update -- one frame into the back buffer
; ----------------------------------------------------------------------------
demo_update:
    call phase3_select_list
    call phase3_erase
    call phase3_move_camera
    call cam_build_matrix
    call phase3_project
    call phase3_sort
    call phase3_draw

    ld hl,demo_frames
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  demo_wait_frame -- hold the loop to 12.5 fps
;
;  Returns immediately if the frame already overran, so the rate drops rather
;  than the picture tearing. That is what the performance test measures.
; ----------------------------------------------------------------------------
demo_wait_frame:
    ld a,(sys_tick_50hz)
    ld hl,demo_tick0
    sub (hl)
    cp DEMO_TICKS_PER_FRAME
    jr c,demo_wait_frame
    ld a,(sys_tick_50hz)
    ld (demo_tick0),a
    ret


; ----------------------------------------------------------------------------
;  phase3_select_list -- point at the back buffer's rectangle list
;
;  Per buffer, because with double buffering the back buffer holds the frame
;  from two ticks ago.
; ----------------------------------------------------------------------------
phase3_select_list:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    jr z,@buffer_a
    ld hl,phase3_rects_b
    ld (phase3_rects),hl
    ld hl,phase3_drawn_b
    ld (phase3_count),hl
    ret
@buffer_a:
    ld hl,phase3_rects_a
    ld (phase3_rects),hl
    ld hl,phase3_drawn_a
    ld (phase3_count),hl
    ret


; ----------------------------------------------------------------------------
;  phase3_erase -- blank every rectangle this buffer is holding
; ----------------------------------------------------------------------------
phase3_erase:
    ld hl,(phase3_count)
    ld a,(hl)
    or a
    ret z
    ld b,a
    ld hl,(phase3_rects)
@rect:
    push bc
    ld a,(hl)                           ; x byte
    inc hl
    ld c,(hl)                           ; y
    inc hl
    ld d,(hl)                           ; width in bytes
    inc hl
    ld e,(hl)                           ; height in lines
    inc hl
    push hl
    ld b,a                              ; scr_fill_rect wants B = x, C = y
    xor a                               ; fill with empty space
    call scr_fill_rect
    pop hl
    pop bc
    djnz @rect
    ret


; ----------------------------------------------------------------------------
;  phase3_move_camera -- a slow orbit, so every yaw view gets exercised
; ----------------------------------------------------------------------------
phase3_move_camera:
    ld hl,cam_yaw
    inc (hl)

    ld hl,phase3_pitch_phase
    inc (hl)
    ld a,(hl)
    call cam_sin
    sra a
    sra a
    sra a                               ; +/-15, a gentle rise and fall
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  phase3_project -- project every ship, cache the ones that survive
; ----------------------------------------------------------------------------
phase3_project:
    xor a
    ld (phase3_visible),a
    ld hl,phase3_ships
    ld (phase3_ent_ptr),hl
    ld hl,phase3_vis
    ld (phase3_vis_ptr),hl

    ld a,PHASE3_SHIP_COUNT
    ld (phase3_remaining),a

@ship:
    ld hl,(phase3_ent_ptr)
    call proj_point
    call c,phase3_cache                 ; test CF before anything clobbers it

    ld hl,(phase3_ent_ptr)
    ld de,PHASE3_ENT_SIZE
    add hl,de
    ld (phase3_ent_ptr),hl

    ld hl,phase3_remaining
    dec (hl)
    jr nz,@ship
    ret


; ----------------------------------------------------------------------------
;  phase3_cache -- append the projected ship to the visible list
; ----------------------------------------------------------------------------
phase3_cache:
    ld hl,(phase3_vis_ptr)

    ld de,(proj_sx)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld a,(proj_sy)
    ld (hl),a
    inc hl
    ld a,(proj_z)
    ld (hl),a
    inc hl

    ;  View index: the ship's heading as seen from the camera, in eighths of
    ;  a turn. 256 steps / 8 views = 32, so >> 5.
    push hl
    ld hl,(phase3_ent_ptr)
    ld de,6
    add hl,de
    ld a,(hl)                           ; heading
    pop hl
    ld d,a
    ld a,(cam_yaw)
    ld e,a
    ld a,d
    sub e
    rrca
    rrca
    rrca
    rrca
    rrca
    and 7
    ld (hl),a
    inc hl

    ;  Size tier from depth.
    push hl
    ld a,(proj_z)
    ld l,a
    ld h,tier_lut / 256
    ld a,(hl)
    pop hl
    ld (hl),a
    inc hl

    ld (phase3_vis_ptr),hl
    ld hl,phase3_visible
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  phase3_sort -- order the visible list back to front (Homeplanet.md 5.3)
;
;  Insertion sort over an index array, descending by z, so the nearest ship is
;  drawn last and ends up on top. At 16 to 48 entries and nearly-sorted input
;  from frame to frame, insertion sort is the right choice -- it is O(n) when
;  little has moved.
; ----------------------------------------------------------------------------
phase3_sort:
    ld a,(phase3_visible)
    or a
    ret z
    ld b,a
    ld hl,phase3_order
    xor a
@fill:
    ld (hl),a
    inc hl
    inc a
    djnz @fill

    ld a,(phase3_visible)
    cp 2
    ret c
    ld (phase3_sort_n),a

    ld a,1
    ld (phase3_sort_i),a

@outer:
    ld a,(phase3_sort_i)
    ld hl,phase3_sort_n
    cp (hl)
    ret nc

    ld (phase3_sort_j),a
    call phase3_order_at                ; HL -> order[i]
    ld a,(hl)
    ld (phase3_sort_key),a
    call phase3_z_of
    ld (phase3_sort_key_z),a

@inner:
    ld a,(phase3_sort_j)
    or a
    jr z,@place

    dec a
    call phase3_order_at                ; HL -> order[j-1]
    ld a,(hl)
    call phase3_z_of                    ; A = its depth
    ld b,a
    ld a,b
    ld hl,phase3_sort_key_z
    cp (hl)
    jr nc,@place                        ; it is at least as far away: key sits here

    ;  order[j] = order[j-1], then walk left
    ld a,(phase3_sort_j)
    dec a
    call phase3_order_at
    ld a,(hl)
    inc hl
    ld (hl),a
    ld hl,phase3_sort_j
    dec (hl)
    jr @inner

@place:
    ld a,(phase3_sort_j)
    call phase3_order_at
    ld a,(phase3_sort_key)
    ld (hl),a

    ld hl,phase3_sort_i
    inc (hl)
    jr @outer


;  HL = &phase3_order[A]
;  Uses: AF, DE, HL
phase3_order_at:
    ld l,a
    ld h,0
    ld de,phase3_order
    add hl,de
    ret

;  A = the camera depth of visible entry A
;  Uses: AF, DE, HL
phase3_z_of:
    call phase3_vis_addr
    inc hl
    inc hl
    inc hl                              ; -> PHASE3_V_Z
    ld a,(hl)
    ret


; ----------------------------------------------------------------------------
;  phase3_draw -- blit the visible ships, far to near
; ----------------------------------------------------------------------------
phase3_draw:
    xor a
    ld (phase3_rect_count),a
    ld hl,(phase3_rects)
    ld (phase3_rect_ptr),hl

    ld a,(phase3_visible)
    or a
    jr z,@done
    ld (phase3_remaining),a
    xor a
    ld (phase3_order_idx),a

@one:
    ld a,(phase3_order_idx)
    ld l,a
    ld h,0
    ld de,phase3_order
    add hl,de
    ld a,(hl)
    call phase3_vis_addr                ; HL -> that visible entry
    call phase3_blit_one

    ld hl,phase3_order_idx
    inc (hl)
    ld hl,phase3_remaining
    dec (hl)
    jr nz,@one

@done:
    ld hl,(phase3_count)
    ld a,(phase3_rect_count)
    ld (hl),a
    ret


;  HL = phase3_vis + A * PHASE3_VIS_SIZE
phase3_vis_addr:
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; *2
    add hl,de                           ; *3
    add hl,hl                           ; *6
    ld de,phase3_vis
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  phase3_blit_one
;  In : HL -> a visible-list entry
; ----------------------------------------------------------------------------
phase3_blit_one:
    ld e,(hl)
    inc hl
    ld d,(hl)                           ; DE = sx
    inc hl
    ld a,(hl)
    ld (phase3_sy),a                    ; sy
    inc hl
    inc hl                              ; skip z
    ld a,(hl)
    ld (phase3_view),a
    inc hl
    ld a,(hl)                           ; tier
    ld (phase3_sx),de

    ;  Tier descriptor
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; * 8
    ld de,phase3_tiers
    add hl,de
    ld (phase3_tier_ptr),hl

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (phase3_base),de
    ld a,(hl)
    ld (spr_w),a
    inc hl
    ld a,(hl)
    ld (spr_h),a
    inc hl
    ld c,(hl)                           ; half width, pixels
    inc hl
    ld b,(hl)                           ; half height, lines
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase3_blocksz),de

    ;  left = sx - halfw   (16-bit signed; sx is 0..319)
    ld hl,(phase3_sx)
    ld e,c
    ld d,0
    or a
    sbc hl,de
    ld (phase3_left),hl

    ;  top = sy - halfh
    ld a,(phase3_sy)
    ld l,a
    ld h,0
    ld e,b
    ld d,0
    or a
    sbc hl,de
    ld (spr_y),hl

    ;  x in bytes, and which pre-shift covers the leftover pixels.
    ;  Pre-shift 0 covers sub-byte offsets 0 and 1, pre-shift 1 covers 2 and 3.
    ld hl,(phase3_left)
    ld a,l
    and 3
    rrca                                ; (offset & 3) >> 1  -- CF is discarded
    and 1
    ld (phase3_shift),a

    ld hl,(phase3_left)
    sra h
    rr l
    sra h
    rr l                                ; arithmetic >> 2, keeps negatives sane
    ld (spr_x),hl

    ;  block = base + (view * shifts + shift) * block_sz
    ld a,(phase3_view)
    add a,a
    ld hl,phase3_shift
    add a,(hl)
    or a
    jr z,@no_offset

    ld b,a
    ld hl,0
    ld de,(phase3_blocksz)
@add_block:
    add hl,de
    djnz @add_block
    ld de,(phase3_base)
    add hl,de
    jr @have_block
@no_offset:
    ld hl,(phase3_base)
@have_block:
    ld (spr_src),hl

    call spr_blit
    ret nc                              ; clipped away entirely

    ;  Remember what was drawn so this buffer can erase it next time round.
    ld hl,spr_rect
    ld de,(phase3_rect_ptr)
    ld b,4
@copy_rect:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz @copy_rect
    ld (phase3_rect_ptr),de
    ld hl,phase3_rect_count
    inc (hl)
    ret


; ============================================================================
;  Data
; ============================================================================

phase3_rects:       defw 0
phase3_count:       defw 0
phase3_rect_ptr:    defw 0
phase3_rect_count:  defb 0

phase3_ent_ptr:     defw 0
phase3_vis_ptr:     defw 0
phase3_tier_ptr:    defw 0
phase3_remaining:   defb 0
phase3_visible:     defb 0
phase3_order_idx:   defb 0

phase3_sx:          defw 0
phase3_sy:          defb 0
phase3_view:        defb 0
phase3_shift:       defb 0
phase3_left:        defw 0
phase3_base:        defw 0
phase3_blocksz:     defw 0

phase3_sort_key:    defb 0
phase3_sort_key_z:  defb 0
phase3_sort_n:      defb 0
phase3_sort_i:      defb 0
phase3_sort_j:      defb 0

phase3_pitch_phase: defb 0
demo_tick0:         defb 0
demo_frames:        defb 0

phase3_drawn_a:     defb 0
phase3_drawn_b:     defb 0
phase3_rects_a:     defs PHASE3_SHIP_COUNT * 4, 0
phase3_rects_b:     defs PHASE3_SHIP_COUNT * 4, 0

phase3_vis:         defs PHASE3_SHIP_COUNT * PHASE3_VIS_SIZE, 0
phase3_order:       defs PHASE3_SHIP_COUNT, 0

;  Tier descriptors: far, middle, near -- matching tier_lut's 0/1/2.
phase3_tiers:
    defw interceptor_a
    defb interceptor_a_w_bytes, interceptor_a_h
    defb interceptor_a_w_px / 2, interceptor_a_h / 2
    defw interceptor_a_block_sz

    defw interceptor_b
    defb interceptor_b_w_bytes, interceptor_b_h
    defb interceptor_b_w_px / 2, interceptor_b_h / 2
    defw interceptor_b_block_sz

    defw interceptor_c
    defb interceptor_c_w_bytes, interceptor_c_h
    defb interceptor_c_w_px / 2, interceptor_c_h / 2
    defw interceptor_c_block_sz

;  A 4 x 4 squadron in the XZ plane, spread in depth so all three size tiers
;  are on screen at once, with headings fanned out so the yaw views differ.
phase3_ships:
gz = 0
    repeat 4
gx = 0
        repeat 4
            defw (gx - 2) * 12000
            defw ((gx + gz) & 1) * 6000 - 3000
            defw (gz - 2) * 12000
            defb (gx * 4 + gz) * 16
            defb 0
gx = gx + 1
        rend
gz = gz + 1
    rend
phase3_ships_end:

    assert (phase3_ships_end - phase3_ships) / PHASE3_ENT_SIZE == PHASE3_SHIP_COUNT, "squadron is not 16 ships"
