; ============================================================================
;  demo/phase4.asm -- Phase 4: entities, squadrons, formations
; ============================================================================
;  Homeplanet.md section 13, phase 4: "Στόλος 12 σκαφών κινείται σε σχηματισμό"
;
;  A fleet of interceptors flies in formation while the camera orbits. Every
;  ship is a real entity record (section 7) and belongs to a squadron; the
;  player carves the fleet up with the keyboard and the ships fly to their new
;  formation as they are reassigned. That flight is the point: it is what
;  makes a reassignment legible on screen rather than a number changing in the
;  HUD.
;
;  Controls
;      1-9  select a squadron (only ones with ships in them)
;      d    divide the selection in half
;      m    move one ship to the next number
;      n    move one ship to the previous number
;      c    combine the selection with the next active squadron
;
;  Each squadron has a home position, and ships take numbered slots in a
;  lattice around it. A ship's target is therefore entirely derived from
;  (squadron, slot) -- nothing is stored per ship, so reassigning a ship IS
;  giving it a new destination.
; ----------------------------------------------------------------------------

PHASE4_SHIPS        equ 20              ; how many the demo starts with

PHASE4_SLOTS        equ 16              ; formation slots per squadron
PHASE4_SLOT_MASK    equ PHASE4_SLOTS - 1

;  World units a ship closes on its slot each frame. Fast enough that a split
;  resolves in a couple of seconds, slow enough to read as flight.
PHASE4_STEP         equ 600

;  Screen cache per visible ship (Homeplanet.md section 7).
PHASE4_VIS_SIZE     equ 6
PHASE4_V_SX         equ 0               ; 2 bytes
PHASE4_V_SY         equ 2
PHASE4_V_Z          equ 3
PHASE4_V_VIEW       equ 4
PHASE4_V_TIER       equ 5

;  Tier descriptor, 8 bytes, indexed by tier_lut.
PHASE4_T_SIZE       equ 8

DEMO_TICKS_PER_FRAME equ 4              ; 50 Hz / 4 = 12.5 fps

;  The tactical view stops here; the HUD owns everything below (Homeplanet.md
;  section 5.5 puts it in a 32-pixel strip at the bottom). Clipping the ships
;  out of the strip is what lets the HUD be redrawn only when it changes.
HUD_TOP             equ 168

;  HUD: two rows of five slots at the bottom of the screen.
HUD_ROW_A_Y         equ 178
HUD_ROW_B_Y         equ 188
HUD_X               equ 2
HUD_ENTRY_CHARS     equ 5               ; ">n:cc"
HUD_ENTRY_BYTES     equ HUD_ENTRY_CHARS * 2
HUD_PER_ROW         equ 5


; ----------------------------------------------------------------------------
;  demo_init
; ----------------------------------------------------------------------------
demo_init:
    xor a
    ld (phase4_drawn_a),a
    ld (phase4_drawn_b),a
    ld (demo_frames),a
    ld a,(sys_tick_50hz)
    ld (demo_tick0),a

    ld hl,150
    ld (cam_dist),hl
    xor a
    ld (cam_yaw),a
    ld (cam_pitch),a

    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ld a,2
    ld (phase4_hud_dirty),a

    call ent_clear_all
    call phase4_spawn_fleet
    jp squad_init


; ----------------------------------------------------------------------------
;  phase4_spawn_fleet -- fill the first PHASE4_SHIPS slots
;
;  They all start on top of the squadron-1 home and fly apart into formation,
;  which doubles as proof that the approach code works at all.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_spawn_fleet:
    xor a
    ld (phase4_index),a
@p4_ship:
    ld a,(phase4_index)
    call ent_addr
    push hl

    ;  Position: the squadron 1 home, so the fleet unpacks from one point.
    ld de,phase4_home
    ld b,6
@p4_copy_pos:
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    djnz @p4_copy_pos

    pop hl
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE
    pop hl
    push hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),255
    pop hl
    push hl
    ld de,ENT_YAW
    add hl,de
    ld a,(phase4_index)
    add a,a
    add a,a
    add a,a
    add a,a                             ; fan the headings out
    ld (hl),a
    pop hl

    ld hl,phase4_index
    inc (hl)
    ld a,(hl)
    cp PHASE4_SHIPS
    jr c,@p4_ship
    ret


; ----------------------------------------------------------------------------
;  demo_update -- one frame
; ----------------------------------------------------------------------------
demo_update:
    call key_scan
    call phase4_commands
    call phase4_fly

    call phase4_select_list
    call phase4_erase
    call phase4_move_camera
    call cam_build_matrix
    call phase4_project
    call phase4_sort
    call phase4_draw
    call phase4_hud

    ld hl,demo_frames
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  demo_wait_frame -- hold the loop to 12.5 fps
;
;  Returns immediately if the frame already overran, so the rate drops instead
;  of the picture tearing.
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
;  phase4_commands -- read the keyboard and reshape the fleet
;
;  Everything here is EDGE triggered: holding `d` down must divide once, not
;  once every frame until there is nothing left to divide.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_commands:
    ;  Number keys. KEY_1..KEY_9 are consecutive ids, so one loop covers them.
    ld c,0
@p4_number:
    ld a,KEY_1
    add a,c
    push bc
    call key_hit
    pop bc
    jr nc,@p4_next_number
    ld a,c
    inc a                               ; id offset -> squadron number
    push bc
    call squad_select
    pop bc
@p4_next_number:
    inc c
    ld a,c
    cp SQUAD_MAX
    jr c,@p4_number

    ld a,KEY_D
    call key_hit
    call c,squad_split

    ld a,KEY_M
    call key_hit
    call c,squad_move_next

    ld a,KEY_N
    call key_hit
    call c,squad_move_prev

    ld a,KEY_C
    call key_hit
    call c,squad_combine
    ret


; ----------------------------------------------------------------------------
;  phase4_fly -- move every ship towards its formation slot
;
;  Slot numbers are handed out by walking the table in order, so a ship's slot
;  is just its ordinal within its squadron. That means reassigning any ship
;  renumbers the ones after it and the whole formation shuffles up -- which
;  looks right, and costs nothing to maintain.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_fly:
    ld hl,phase4_slot_next
    ld b,SQUAD_MAX + 1
    xor a
@p4_zero_slots:
    ld (hl),a
    inc hl
    djnz @p4_zero_slots

    xor a
    ld (phase4_index),a
@p4_ship_fly:
    ld a,(phase4_index)
    call ent_addr
    ld (phase4_ent),hl

    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@p4_next_fly

    ld hl,(phase4_ent)
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    or a
    jr z,@p4_next_fly
    cp SQUAD_MAX + 1
    jr nc,@p4_next_fly
    ld (phase4_squad),a

    ;  slot = phase4_slot_next[squad]++
    ld l,a
    ld h,0
    ld de,phase4_slot_next
    add hl,de
    ld a,(hl)
    inc (hl)
    ld (phase4_slotno),a

    call phase4_step_to_slot

@p4_next_fly:
    ld hl,phase4_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@p4_ship_fly
    ret


; ----------------------------------------------------------------------------
;  phase4_step_to_slot -- close on (home[squad] + offset[slot]) by one step
;  In : (phase4_ent), (phase4_squad), (phase4_slotno)
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_step_to_slot:
    ld a,(phase4_squad)
    dec a                               ; squadrons are 1-based
    call phase4_times6
    ld de,phase4_home
    add hl,de
    ld (phase4_home_ptr),hl

    ld a,(phase4_slotno)
    and PHASE4_SLOT_MASK                ; more ships than slots: share them
    call phase4_times6
    ld de,phase4_offset
    add hl,de
    ld (phase4_off_ptr),hl

    ld hl,(phase4_ent)                  ; ENT_X is offset 0
    ld (phase4_coord_ptr),hl

    ld a,3
    ld (phase4_axis),a

@p4_axis:
    ld hl,(phase4_home_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (phase4_home_ptr),hl

    ld hl,(phase4_off_ptr)
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld (phase4_off_ptr),hl

    ld h,d
    ld l,e
    add hl,bc
    ld (phase4_tgt),hl

    ld hl,(phase4_coord_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (phase4_cur),de

    call phase4_approach                ; HL = the new coordinate

    ex de,hl
    ld hl,(phase4_coord_ptr)
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ld (phase4_coord_ptr),hl

    ld hl,phase4_axis
    dec (hl)
    jr nz,@p4_axis
    ret


; ----------------------------------------------------------------------------
;  phase4_approach -- one axis, one step
;  In : (phase4_cur), (phase4_tgt)
;  Out: HL = the new value, snapped to the target if within one step
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
phase4_approach:
    ld hl,(phase4_tgt)
    ld de,(phase4_cur)
    or a
    sbc hl,de                           ; HL = how far there is to go
    ld a,h
    or l
    jr z,@p4_arrive

    bit 7,h
    jr nz,@p4_behind

    ld de,PHASE4_STEP
    or a
    sbc hl,de
    jr c,@p4_arrive                        ; less than a step away: snap
    ld hl,(phase4_cur)
    add hl,de
    ret

@p4_behind:
    ld de,PHASE4_STEP
    add hl,de                           ; distance + step
    bit 7,h
    jr z,@p4_arrive                        ; within a step of the target
    ld hl,(phase4_cur)
    or a
    sbc hl,de
    ret

@p4_arrive:
    ld hl,(phase4_tgt)
    ret


;  HL = A * 6
;  Uses: AF, DE, HL
phase4_times6:
    ld l,a
    ld h,0
    add hl,hl                           ; *2
    ld d,h
    ld e,l
    add hl,hl                           ; *4
    add hl,de                           ; *6
    ret


; ----------------------------------------------------------------------------
;  phase4_select_list -- point at the back buffer's rectangle list
; ----------------------------------------------------------------------------
phase4_select_list:
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    jr z,@p4_buffer_a
    ld hl,phase4_rects_b
    ld (phase4_rects),hl
    ld hl,phase4_drawn_b
    ld (phase4_count),hl
    ret
@p4_buffer_a:
    ld hl,phase4_rects_a
    ld (phase4_rects),hl
    ld hl,phase4_drawn_a
    ld (phase4_count),hl
    ret


; ----------------------------------------------------------------------------
;  phase4_erase -- blank every rectangle this buffer is holding
; ----------------------------------------------------------------------------
phase4_erase:
    ld hl,(phase4_count)
    ld a,(hl)
    or a
    ret z
    ld b,a
    ld hl,(phase4_rects)
@p4_rect:
    push bc
    ld a,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld e,(hl)
    inc hl
    push hl
    ld b,a
    xor a
    call scr_fill_rect
    pop hl
    pop bc
    djnz @p4_rect
    ret


; ----------------------------------------------------------------------------
;  phase4_move_camera -- a slow orbit, so every yaw view gets exercised
; ----------------------------------------------------------------------------
phase4_move_camera:
    ld hl,cam_yaw
    inc (hl)

    ld hl,phase4_pitch_phase
    inc (hl)
    ld a,(hl)
    call cam_sin
    sra a
    sra a
    sra a
    ld (cam_pitch),a
    ret


; ----------------------------------------------------------------------------
;  phase4_project -- project every active entity, cache the survivors
; ----------------------------------------------------------------------------
phase4_project:
    xor a
    ld (phase4_visible),a
    ld (phase4_index),a
    ld hl,phase4_vis
    ld (phase4_vis_ptr),hl

@p4_ship_proj:
    ld a,(phase4_index)
    call ent_addr
    ld (phase4_ent),hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    jr z,@p4_next_proj

    ld hl,(phase4_ent)                  ; ENT_X is offset 0
    call proj_point
    call c,phase4_cache                 ; test CF before anything clobbers it

@p4_next_proj:
    ld hl,phase4_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@p4_ship_proj
    ret


; ----------------------------------------------------------------------------
;  phase4_cache -- append the projected ship to the visible list
; ----------------------------------------------------------------------------
phase4_cache:
    ld hl,(phase4_vis_ptr)

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

    ;  View: the ship's heading as seen from the camera, in eighths of a turn.
    push hl
    ld hl,(phase4_ent)
    ld de,ENT_YAW
    add hl,de
    ld a,(hl)
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

    push hl
    ld a,(proj_z)
    ld l,a
    ld h,tier_lut / 256
    ld a,(hl)
    pop hl
    ld (hl),a
    inc hl

    ld (phase4_vis_ptr),hl
    ld hl,phase4_visible
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  phase4_sort -- order the visible list back to front (Homeplanet.md 5.3)
;
;  Insertion sort over an index array, descending by depth, so the nearest
;  ship is drawn last and ends up on top. Nearly-sorted from frame to frame,
;  which is exactly where insertion sort is O(n).
; ----------------------------------------------------------------------------
phase4_sort:
    ld a,(phase4_visible)
    or a
    ret z
    ld b,a
    ld hl,phase4_order
    xor a
@p4_fill:
    ld (hl),a
    inc hl
    inc a
    djnz @p4_fill

    ld a,(phase4_visible)
    cp 2
    ret c
    ld (phase4_sort_n),a

    ld a,1
    ld (phase4_sort_i),a

@p4_outer:
    ld a,(phase4_sort_i)
    ld hl,phase4_sort_n
    cp (hl)
    ret nc

    ld (phase4_sort_j),a
    call phase4_order_at
    ld a,(hl)
    ld (phase4_sort_key),a
    call phase4_z_of
    ld (phase4_sort_key_z),a

@p4_inner:
    ld a,(phase4_sort_j)
    or a
    jr z,@p4_place

    dec a
    call phase4_order_at
    ld a,(hl)
    call phase4_z_of
    ld b,a
    ld a,b
    ld hl,phase4_sort_key_z
    cp (hl)
    jr nc,@p4_place                        ; at least as far away: the key sits here

    ld a,(phase4_sort_j)
    dec a
    call phase4_order_at
    ld a,(hl)
    inc hl
    ld (hl),a
    ld hl,phase4_sort_j
    dec (hl)
    jr @p4_inner

@p4_place:
    ld a,(phase4_sort_j)
    call phase4_order_at
    ld a,(phase4_sort_key)
    ld (hl),a

    ld hl,phase4_sort_i
    inc (hl)
    jr @p4_outer


;  HL = &phase4_order[A]
phase4_order_at:
    ld l,a
    ld h,0
    ld de,phase4_order
    add hl,de
    ret

;  A = the camera depth of visible entry A
phase4_z_of:
    call phase4_vis_addr
    inc hl
    inc hl
    inc hl
    ld a,(hl)
    ret

;  HL = &phase4_vis[A]
phase4_vis_addr:
    ld l,a
    ld h,0
    ld d,h
    ld e,l
    add hl,hl                           ; *2
    add hl,de                           ; *3
    add hl,hl                           ; *6
    ld de,phase4_vis
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  phase4_draw -- blit the visible ships, far to near
; ----------------------------------------------------------------------------
phase4_draw:
    xor a
    ld (phase4_rect_count),a
    ld hl,(phase4_rects)
    ld (phase4_rect_ptr),hl

    ld a,(phase4_visible)
    or a
    jr z,@p4_done
    ld (phase4_remaining),a
    xor a
    ld (phase4_order_idx),a

@p4_one:
    ld a,(phase4_order_idx)
    ld l,a
    ld h,0
    ld de,phase4_order
    add hl,de
    ld a,(hl)
    call phase4_vis_addr
    call phase4_blit_one

    ld hl,phase4_order_idx
    inc (hl)
    ld hl,phase4_remaining
    dec (hl)
    jr nz,@p4_one

@p4_done:
    ld hl,(phase4_count)
    ld a,(phase4_rect_count)
    ld (hl),a
    ret


; ----------------------------------------------------------------------------
;  phase4_blit_one
;  In : HL -> a visible-list entry
; ----------------------------------------------------------------------------
phase4_blit_one:
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    ld (phase4_sy),a
    inc hl
    inc hl                              ; skip depth
    ld a,(hl)
    ld (phase4_view),a
    inc hl
    ld a,(hl)                           ; tier
    ld (phase4_sx),de

    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; * PHASE4_T_SIZE
    ld de,phase4_tiers
    add hl,de

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (phase4_base),de
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
    ld (phase4_blocksz),de

    ld hl,(phase4_sx)
    ld e,c
    ld d,0
    or a
    sbc hl,de
    ld (phase4_left),hl

    ld a,(phase4_sy)
    ld l,a
    ld h,0
    ld e,b
    ld d,0
    or a
    sbc hl,de
    ld (spr_y),hl

    ;  Pre-shift 0 covers sub-byte offsets 0 and 1, pre-shift 1 covers 2 and 3.
    ld hl,(phase4_left)
    ld a,l
    and 3
    rrca
    and 1
    ld (phase4_shift),a

    ld hl,(phase4_left)
    sra h
    rr l
    sra h
    rr l                                ; arithmetic >> 2, keeps negatives sane
    ld (spr_x),hl

    ld a,(phase4_view)
    add a,a
    ld hl,phase4_shift
    add a,(hl)
    or a
    jr z,@p4_no_offset

    ld b,a
    ld hl,0
    ld de,(phase4_blocksz)
@p4_add_block:
    add hl,de
    djnz @p4_add_block
    ld de,(phase4_base)
    add hl,de
    jr @p4_have_block
@p4_no_offset:
    ld hl,(phase4_base)
@p4_have_block:
    ld (spr_src),hl

    call spr_blit
    ret nc

    ld hl,spr_rect
    ld de,(phase4_rect_ptr)
    ld b,4
@p4_copy_rect:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz @p4_copy_rect
    ld (phase4_rect_ptr),de
    ld hl,phase4_rect_count
    inc (hl)
    ret


; ----------------------------------------------------------------------------
;  phase4_hud -- the squadron strip (Homeplanet.md section 5.5)
;
;  Two rows of five: squadrons 1-5 above, 6-9 below. Every slot is drawn every
;  frame whether the squadron exists or not, so the layout never shifts under
;  the player's eye and an emptied squadron blanks itself.
;
;      >3:07     selected, squadron 3, seven ships
;       4:12     not selected
;               (blank -- no such squadron)
;
;  Drawn last, after the ships, so a ship that flies over the strip is
;  overwritten rather than the other way round.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_hud:
    call phase4_hud_changed
    ld hl,phase4_hud_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)                            ; once into each buffer

    ld a,1
    ld (phase4_hud_squad),a

    ld a,HUD_ROW_A_Y
    ld (phase4_hud_y),a
    ld a,HUD_X
    ld (phase4_hud_x),a
    ld a,HUD_PER_ROW
    ld (phase4_hud_left),a
    call phase4_hud_row

    ld a,HUD_ROW_B_Y
    ld (phase4_hud_y),a
    ld a,HUD_X
    ld (phase4_hud_x),a
    ld a,SQUAD_MAX - HUD_PER_ROW
    ld (phase4_hud_left),a
    jp phase4_hud_row


; ----------------------------------------------------------------------------
;  phase4_hud_changed -- has anything the HUD shows moved?
;
;  Compares the counts and the selection against a shadow copy rather than
;  having every command remember to flag itself. Ships will start dying later
;  and that changes the counts with nobody pressing anything.
;
;  Sets the dirty counter to 2, not 1: there are two screen buffers and the
;  strip has to be redrawn into each of them.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_hud_changed:
    ld hl,squad_count
    ld de,phase4_hud_shadow
    ld b,SQUAD_MAX + 1
@p4_hud_cmp:
    ld a,(de)
    cp (hl)
    jr nz,@p4_hud_diff
    inc hl
    inc de
    djnz @p4_hud_cmp

    ld a,(squad_sel)
    ld hl,phase4_hud_shadow_sel
    cp (hl)
    ret z

@p4_hud_diff:
    ld hl,squad_count
    ld de,phase4_hud_shadow
    ld bc,SQUAD_MAX + 1
    ldir
    ld a,(squad_sel)
    ld (phase4_hud_shadow_sel),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


phase4_hud_row:
@p4_entry:
    call phase4_hud_entry

    ld hl,phase4_hud_x
    ld a,(hl)
    add a,HUD_ENTRY_BYTES
    ld (hl),a
    ld hl,phase4_hud_squad
    inc (hl)

    ld hl,phase4_hud_left
    dec (hl)
    jr nz,@p4_entry
    ret


phase4_hud_entry:
    ld a,(phase4_hud_squad)
    call squad_count_of
    ld (phase4_hud_n),a
    or a
    jr nz,@p4_active

    ;  No such squadron: blank the whole slot so nothing stale survives.
    ld hl,phase4_hud_blank
    ld a,(phase4_hud_x)
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    jp txt_draw

@p4_active:
    ;  ">" if this is the selection, otherwise a space.
    ld a,(phase4_hud_squad)
    ld hl,squad_sel
    cp (hl)
    ld a,' '
    jr nz,@p4_not_selected
    ld a,'>'
@p4_not_selected:
    ld (phase4_hud_text + 0),a

    ld a,(phase4_hud_squad)
    add a,'0'
    ld (phase4_hud_text + 1),a

    ld hl,phase4_hud_text
    ld a,(phase4_hud_x)
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    call txt_draw

    ;  The count goes in the last two columns of the slot.
    ld a,(phase4_hud_x)
    add a,3 * TXT_CHAR_W_BYTES
    ld b,a
    ld a,(phase4_hud_y)
    ld c,a
    ld d,2
    ld a,(phase4_hud_n)
    jp txt_draw_num


; ============================================================================
;  Data
; ============================================================================

phase4_rects:       defw 0
phase4_count:       defw 0
phase4_rect_ptr:    defw 0
phase4_rect_count:  defb 0

phase4_ent:         defw 0
phase4_vis_ptr:     defw 0
phase4_index:       defb 0
phase4_remaining:   defb 0
phase4_visible:     defb 0
phase4_order_idx:   defb 0

phase4_squad:       defb 0
phase4_slotno:      defb 0
phase4_axis:        defb 0
phase4_home_ptr:    defw 0
phase4_off_ptr:     defw 0
phase4_coord_ptr:   defw 0
phase4_cur:         defw 0
phase4_tgt:         defw 0

phase4_sx:          defw 0
phase4_sy:          defb 0
phase4_view:        defb 0
phase4_shift:       defb 0
phase4_left:        defw 0
phase4_base:        defw 0
phase4_blocksz:     defw 0

phase4_sort_key:    defb 0
phase4_sort_key_z:  defb 0
phase4_sort_n:      defb 0
phase4_sort_i:      defb 0
phase4_sort_j:      defb 0

phase4_hud_squad:   defb 0
phase4_hud_x:       defb 0
phase4_hud_y:       defb 0
phase4_hud_left:    defb 0
phase4_hud_n:       defb 0
phase4_hud_dirty:   defb 0
phase4_hud_shadow:  defs SQUAD_MAX + 1, #FF
phase4_hud_shadow_sel: defb #FF
phase4_hud_text:    defb " 0:",0        ; the marker and digit are patched in
phase4_hud_blank:   defb "     ",0

phase4_pitch_phase: defb 0
demo_tick0:         defb 0
demo_frames:        defb 0

phase4_slot_next:   defs SQUAD_MAX + 1, 0

phase4_drawn_a:     defb 0
phase4_drawn_b:     defb 0
phase4_rects_a:     defs ENT_MAX * 4, 0
phase4_rects_b:     defs ENT_MAX * 4, 0

phase4_vis:         defs ENT_MAX * PHASE4_VIS_SIZE, 0
phase4_order:       defs ENT_MAX, 0

;  Tier descriptors: far, middle, near -- matching tier_lut's 0/1/2.
phase4_tiers:
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

;  Where each squadron sits. Spread along X so a split is visible as one group
;  peeling away from another, rather than as a number changing.
phase4_home:
    ;  Squadron 1 sits at the middle of the battle and the rest fan out around
    ;  it, so a split reads as a group peeling away from the centre. Spread in
    ;  Z as well as X: that is what puts ships at different depths and so at
    ;  different size tiers.
    defw      0,  2000,      0           ; 1
    defw -18000, -3000,   8000           ; 2
    defw  18000,  3000,  -8000           ; 3
    defw -12000, -2000,  16000           ; 4
    defw  12000,  2500, -16000           ; 5
    defw  -6000, -3000, -12000           ; 6
    defw   6000,  2000,  12000           ; 7
    defw -24000, -2500,   4000           ; 8
    defw  24000,  3000,  -4000           ; 9

phase4_offset:
oz = 0
    repeat 4
ox = 0
        repeat 4
            defw (ox * 2 - 3) * 2200
            defw 0
            defw (oz * 2 - 3) * 2200
ox = ox + 1
        rend
oz = oz + 1
    rend
phase4_offset_end:

    assert (phase4_offset_end - phase4_offset) / 6 == PHASE4_SLOTS, "formation lattice is not 16 slots"
