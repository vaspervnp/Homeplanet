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

;  World units a ship closes on its slot each frame. Fast enough that a split
;  resolves in a couple of seconds, slow enough to read as flight.
PHASE4_STEP         equ 600

;  Screen cache per visible ship (Homeplanet.md section 7).
PHASE4_VIS_SIZE     equ 6
PHASE4_V_SX         equ 0               ; 2 bytes
PHASE4_V_SY         equ 2
PHASE4_V_Z          equ 3
PHASE4_V_VIEW       equ 4
PHASE4_V_CLASSTIER  equ 5           ; (class << 2) | tier

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

    xor a
    ld (cam_yaw),a
    ld (cam_pitch),a
    call order_init

    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ld a,2
    ld (phase4_hud_dirty),a

    call form_init
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

    ;  Position: squadron 1's station, so the fleet unpacks from one point.
    ld de,squad_dest
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
    ld de,ENT_SQUAD
    add hl,de
    ld (hl),1                           ; the fleet starts as one squadron
    pop hl
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld (hl),CLASS_INTERCEPTOR
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

    ;  ...and the Mothership, which belongs to no squadron: it is the fleet's
    ;  base, not part of it, and `0` selects it separately.
    ld a,PHASE4_SHIPS
    ld (moth_slot),a
    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE
    pop hl
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld (hl),CLASS_MOTHERSHIP
    pop hl
    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld (hl),SQUAD_NONE
    pop hl
    push hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),255
    pop hl
    ld de,order_mothership_pos
    ld b,6
@p4_moth_pos:
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    djnz @p4_moth_pos
    ret


; ----------------------------------------------------------------------------
;  demo_update -- one frame
; ----------------------------------------------------------------------------
demo_update:
    call key_scan
    call phase4_commands
    call order_update

    ;  SPACE freezes the battle but not the orders (Homeplanet.md section 9):
    ;  the player can still re-plan while everything holds station.
    ld a,(order_paused)
    or a
    jr nz,@p4_frozen
    call phase4_fly
    ;  Sensors run the battle at triple speed (section 9): the view exists for
    ;  the long transits, and there is nothing to look at while they happen.
    ld a,(view_sensors)
    or a
    jr z,@p4_frozen
    call phase4_fly
    call phase4_fly
@p4_frozen:

    call phase4_select_list
    call phase4_erase
    call order_focus
    call cam_build_matrix
    call phase4_project
    call phase4_sort
    ld a,(view_sensors)
    or a
    jr z,@p4_tactical
    call phase4_draw_sensor
    jr @p4_drawn
@p4_tactical:
    call phase4_draw
@p4_drawn:
    call phase4_draw_disc
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
    ;  Number keys. The ids are MATRIX POSITIONS, not a dense enumeration --
    ;  1 and 2 sit in row 8 while 9 and 0 are up in row 4 -- so the id for a
    ;  digit has to come out of key_digit. Walking up from KEY_1 gets you
    ;  ESC, Q, TAB, A and Z, and squadrons 3 to 9 become unreachable.
    ld c,1
@p4_number:
    ld a,c
    call key_digit
    push bc
    call key_hit
    pop bc
    jr nc,@p4_next_number
    ld a,c
    push bc
    call squad_select
    pop bc
@p4_next_number:
    inc c
    ld a,c
    cp SQUAD_MAX + 1
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

    ld a,KEY_F
    call key_hit
    call c,form_cycle
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
    jr z,@p4_next_fly                   ; unassigned: the Mothership holds station
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
    ld de,squad_dest
    add hl,de
    ld (phase4_home_ptr),hl

    ld a,(phase4_squad)
    ld b,a
    ld a,(phase4_slotno)
    ld c,a
    call form_slot_addr                 ; the squadron's own shape
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
phase4_approach:
    ld hl,(phase4_tgt)
    ld de,(phase4_cur)
    or a
    sbc hl,de                           ; how far there is to go
    jp pe,@p4_far                       ; ...if that even fit. Test P/V HERE:
                                        ; the OR below overwrites it.

    ld a,h
    or l
    jr z,@p4_arrive

    bit 7,h
    jr nz,@p4_behind

    ld de,PHASE4_STEP
    or a
    sbc hl,de
    jr c,@p4_arrive                     ; less than a step away: snap
    ld hl,(phase4_cur)
    add hl,de
    ret

@p4_behind:
    ld de,PHASE4_STEP
    add hl,de                           ; distance + step
    bit 7,h
    jr z,@p4_arrive                     ; within a step of the target
    ld hl,(phase4_cur)
    or a
    sbc hl,de
    ret

@p4_arrive:
    ld hl,(phase4_tgt)
    ret

@p4_far:
    ;  Every axis of the world is 16-bit signed, so two points can be 65534
    ;  apart and `target - current` does not fit in the register that is
    ;  holding it. When SBC overflows, the sign bit LIES -- the true sign is
    ;  S XOR P/V -- and a ship at one end of the map reads a target at the
    ;  other end as being behind it and flies away from it, forever.
    ;
    ;  Nothing to check for arrival on this path: overflowing means more than
    ;  32767 away, which is a long way past one step.
    ld de,PHASE4_STEP
    bit 7,h
    jr nz,@p4_far_forward
    ld hl,(phase4_cur)
    or a
    sbc hl,de
    ret
@p4_far_forward:
    ld hl,(phase4_cur)
    add hl,de
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

    ;  Size tier from depth, packed with the class: the blitter needs both to
    ;  name a sprite block, and the design gives this record six bytes.
    push hl
    ld hl,(phase4_ent)
    ld de,ENT_CLASS
    add hl,de
    ld b,(hl)                           ; B = class
    ld a,(proj_z)
    ld l,a
    ld h,tier_lut / 256
    ld a,(hl)
    call class_apply_bias               ; capital ships draw a tier larger
    ld c,a
    ld a,b
    add a,a
    add a,a
    or c
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
;  phase4_draw_sensor -- one dot per entity, and nothing else
;
;  Section 9's stripped-back view. The Mothership gets a cross rather than a
;  dot so the fleet's anchor is still findable among them.
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_draw_sensor:
    xor a
    ld (phase4_rect_count),a
    ld hl,(phase4_rects)
    ld (phase4_rect_ptr),hl

    ld a,(phase4_visible)
    or a
    jp z,@p4_sensor_done
    ld (phase4_remaining),a
    xor a
    ld (phase4_index),a

@p4_sensor_one:
    ld a,(phase4_index)
    call phase4_vis_addr

    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)                           ; screen y
    ld (phase4_sy),a
    inc hl
    inc hl                              ; skip the depth
    inc hl                              ; skip the view
    ld a,(hl)                           ; (class << 2) | tier
    ld (phase4_sx),de
    rrca
    rrca
    and #3F
    ld (phase4_view),a                  ; reuse: the class

    ld hl,(phase4_sx)
    ld a,(phase4_sy)
    ld c,a
    ld a,(phase4_view)
    or a
    jr nz,@p4_sensor_capital

    ;  A fighter: a single pixel.
    ld b,1
    ld a,DISC_INK_TOP
    call gfx_vline
    ld a,1
    ld (phase4_disc_rect + 2),a
    ld a,1
    ld (phase4_disc_rect + 3),a
    ld a,(phase4_sy)
    ld (phase4_disc_rect + 1),a
    jr @p4_sensor_rect_x

@p4_sensor_capital:
    ld a,DISC_INK_STEM
    call gfx_cross
    ld a,3
    ld (phase4_disc_rect + 2),a
    ld a,3
    ld (phase4_disc_rect + 3),a
    ld a,(phase4_sy)
    or a
    jr z,@p4_sensor_y0
    dec a
@p4_sensor_y0:
    ld (phase4_disc_rect + 1),a

@p4_sensor_rect_x:
    ;  x is SIXTEEN bit -- shifting only the low byte is the bug that left a
    ;  comb of stems on screen the first time round.
    ld hl,(phase4_sx)
    srl h
    rr l
    srl h
    rr l                                ; HL = x in bytes
    ld a,l
    ld hl,phase4_disc_rect + 2
    ld b,(hl)
    dec b
    jr z,@p4_sensor_x_store             ; a single-pixel dot needs no margin
    or a
    jr z,@p4_sensor_x_store             ; already hard against the left edge
    dec a                               ; a byte of margin for the cross
@p4_sensor_x_store:
    ld (phase4_disc_rect + 0),a

    ld hl,phase4_disc_rect
    ld de,(phase4_rect_ptr)
    ld b,4
@p4_sensor_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz @p4_sensor_copy
    ld (phase4_rect_ptr),de
    ld hl,phase4_rect_count
    inc (hl)

    ld hl,phase4_index
    inc (hl)
    ld hl,phase4_remaining
    dec (hl)
    jp nz,@p4_sensor_one

@p4_sensor_done:
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
    ld a,(hl)                           ; (class << 2) | tier
    ld (phase4_sx),de

    ld c,a
    and 3
    push af                             ; the tier
    ld a,c
    rrca
    rrca
    and #3F
    ld b,a                              ; B = class
    pop af
    ld c,a                              ; C = tier
    call class_tier_addr

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
;  phase4_draw_disc -- the move cursor and its height line
;
;  Two projections: the disc itself, and the point directly below it on the
;  Y=0 reference plane. The line between them is what tells the player how
;  high the order is -- without it a cursor in a 3D void is unreadable, which
;  is the whole problem section 9 is solving.
;
;  The line is drawn at the disc's screen x rather than tracked properly. The
;  two points differ only in world Y, and row 0 of the camera matrix is
;  (cy, 0, sy) -- structurally independent of Y -- so they differ only through
;  the perspective divide. At these distances that is under a pixel.
;
;  Uses: everything
; ----------------------------------------------------------------------------
phase4_draw_disc:
    ld a,(disc_active)
    or a
    ret z

    ;  Where the order sits, and the point directly below it on the plane.
    ld hl,(disc_pos + 0)
    ld (phase4_disc_flat + 0),hl
    ld hl,0
    ld (phase4_disc_flat + 2),hl
    ld hl,(disc_pos + 4)
    ld (phase4_disc_flat + 4),hl

    ld hl,phase4_disc_flat
    call proj_point
    ld a,0
    jr nc,@p4_disc_no_base
    ld a,(proj_sy)
    ld (phase4_disc_by),a
    ld a,1
@p4_disc_no_base:
    ld (phase4_disc_has_base),a

    ld hl,disc_pos
    call proj_point
    ret nc                              ; the order is off screen entirely

    ld hl,(proj_sx)
    ld (phase4_disc_tx),hl
    ld a,(proj_sy)
    ld (phase4_disc_ty),a

    ;  If the base is off screen there is no stem to draw, only the marker.
    ld a,(phase4_disc_has_base)
    or a
    ld a,(phase4_disc_ty)
    ld b,1                              ; a stem of one line: just the marker row
    ld c,a
    jr z,@p4_disc_have_stem

    ;  Smaller screen y is the top of the stem; the difference is its height.
    ld a,(phase4_disc_ty)
    ld b,a
    ld a,(phase4_disc_by)
    cp b
    jr nc,@p4_disc_top_is_upper
    ld c,a                              ; the base is higher up the screen
    ld a,b
    sub c
    ld b,a
    jr @p4_disc_have_stem
@p4_disc_top_is_upper:
    ld c,b
    sub c
    ld b,a

@p4_disc_have_stem:
    inc b                               ; include the last row
    ld a,c
    ld (phase4_disc_rect + 1),a
    ld a,b
    ld (phase4_disc_rect + 3),a

    ld hl,(phase4_disc_tx)
    ld a,DISC_INK_STEM
    call gfx_vline

    ld hl,(phase4_disc_tx)
    ld a,(phase4_disc_ty)
    ld c,a
    ld a,DISC_INK_TOP
    call gfx_cross

    ;  One rectangle covering stem and marker, so the next pass through this
    ;  buffer erases the lot. The cross reaches one pixel either side of the
    ;  stem and one row above and below it, hence the margins.
    ;
    ;  x is SIXTEEN bit here. Shifting only the low byte was the bug that left
    ;  a comb of stems down the screen: the rectangle was recorded somewhere
    ;  else entirely and erased nothing.
    ld hl,(phase4_disc_tx)
    srl h
    rr l
    srl h
    rr l                                ; x >> 2, in bytes
    ld a,l
    or a
    jr z,@p4_disc_x_at_edge
    dec a                               ; a byte of margin for the cross
@p4_disc_x_at_edge:
    ld (phase4_disc_rect + 0),a
    ld a,3
    ld (phase4_disc_rect + 2),a

    ld hl,phase4_disc_rect + 1
    ld a,(hl)
    or a
    jr z,@p4_disc_y_at_edge
    dec (hl)                            ; a row of margin above
    inc hl
    inc hl
    inc (hl)
@p4_disc_y_at_edge:
    ld hl,phase4_disc_rect + 3
    inc (hl)                            ; ...and below

    ld hl,phase4_disc_rect
    ld de,(phase4_rect_ptr)
    ld b,4
@p4_disc_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz @p4_disc_copy
    ld (phase4_rect_ptr),de
    ld hl,phase4_rect_count
    inc (hl)
    ld hl,(phase4_count)
    ld a,(phase4_rect_count)
    ld (hl),a
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

phase4_disc_flat:   defs 6, 0
phase4_disc_tx:     defw 0
phase4_disc_ty:     defb 0
phase4_disc_bx:     defw 0
phase4_disc_by:     defb 0
phase4_disc_has_base: defb 0
phase4_disc_rect:   defs 4, 0

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

demo_tick0:         defb 0
demo_frames:        defb 0

phase4_slot_next:   defs SQUAD_MAX + 1, 0

phase4_drawn_a:     defb 0
phase4_drawn_b:     defb 0
phase4_rects_a:     defs (ENT_MAX + 1) * 4, 0    ; +1 for the move disc
phase4_rects_b:     defs (ENT_MAX + 1) * 4, 0

phase4_vis:         defs ENT_MAX * PHASE4_VIS_SIZE, 0
phase4_order:       defs ENT_MAX, 0
