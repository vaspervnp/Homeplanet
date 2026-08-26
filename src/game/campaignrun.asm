; ============================================================================
;  game/campaignrun.asm -- running the campaign, IN BANK 4
; ============================================================================
;  Split out of game/mission.asm, which keeps the descriptor layout and the
;  state. Setting a mission up, checking whether it has been won or lost,
;  jumping, and packing the survivors into the bank between missions.
;
;  Legal here because none of it runs while another bank is paged in:
;  mis_setup and mis_jump are reached from demo_init and from a keypress,
;  mis_update from demo_update's playing path, and mis_wipe_screen from the
;  same frame before anything is blitted. game/ordercmd.asm has the argument
;  and where the space came from.
;
;  fleet_save and fleet_restore are the two that would be a bug anywhere else:
;  the block they copy IS in bank 4, so this is the only bank the window can
;  be holding while they run. They then hand it to src/sys/fdc.asm, which
;  stays in the low 16K -- lib_load reads sectors INTO the window and the
;  controller code cannot be the thing being paged out.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  mis_init -- start the campaign at mission 1
;  Uses: everything
; ----------------------------------------------------------------------------
mis_init:
    xor a
    ld (mis_index),a
    ld (mis_complete),a
    ld (mis_failed),a
    ld (mis_saved),a                    ; nothing banked yet
    ld hl,0
    ld (mis_timer),hl
    jp mis_brief_open


; ----------------------------------------------------------------------------
;  mis_brief_open -- hold the mission on its briefing screen
;  Uses: AF, HL
; ----------------------------------------------------------------------------
mis_brief_open:
    ld a,1
    ld (mis_briefing),a
    ret


; ----------------------------------------------------------------------------
;  mis_brief_draw -- the static screen: name, three lines, and a prompt
;
;  Drawn into the back buffer like everything else, and drawn EVERY frame
;  rather than once -- it is a page-flipping display, so a screen painted once
;  would flicker between the briefing and whatever the other buffer holds.
;  Uses: everything
; ----------------------------------------------------------------------------
;  mis_brief_key -- ENTER dismisses the briefing
;  Uses: everything
; ----------------------------------------------------------------------------
mis_brief_key:
    ld a,KEY_ENTER
    call key_hit
    ret nc
    xor a
    ld (mis_briefing),a

    ;  The briefing paints the whole tactical area and records no dirty
    ;  rectangle for any of it, so nothing would ever erase the text -- it sat
    ;  under the battle for the rest of the mission. Wipe it explicitly, once
    ;  into each of the two buffers.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  mis_wipe_screen -- clear the back buffer after a full-screen page closes
;
;  Called for two frames, which is one per screen buffer. Cheaper and clearer
;  than making the briefing record eighty rectangles it will never look at
;  again.
;
;  ALL 200 lines, including the strip the HUD owns, and whoever schedules the
;  wipe marks the HUD dirty so it comes straight back. Wiping only as far as
;  spr_clip_bottom left the title screen's credit line -- which sits at y=186,
;  inside that strip -- on the screen for the rest of the game: the HUD does
;  not clear its strip, it draws labels onto it, so anywhere it happened not
;  to put a glyph the old pixels stayed. Two HUD redraws per screen change is
;  nothing; a permanent smear across the bottom of the game is not.
;  Uses: everything
; ----------------------------------------------------------------------------
mis_wipe_screen:
    ld hl,mis_wipe
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ld bc,#0000
    ld a,SCR_HEIGHT_PX
    ld e,a
    ld d,SCR_BYTES_PER_LINE
    xor a
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  mis_descriptor -- HL -> the current mission's descriptor
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
mis_descriptor:
    ld a,(mis_index)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; * 4
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl                           ; * 16
    add hl,de                           ; * 20 = MIS_SIZE
    ld de,mission_table
    add hl,de
    ret


; ----------------------------------------------------------------------------
;  mis_setup -- lay out the current mission around whatever fleet survives
;
;  The player's ships are NOT rebuilt here: they are already in the entity
;  table, either freshly spawned for mission 1 or restored from the bank. Only
;  the enemy and the resources are the mission's to place.
;  Uses: everything
; ----------------------------------------------------------------------------
mis_setup:
    xor a
    ld (mis_complete),a
    ld (mis_failed),a
    ld hl,0
    ld (mis_timer),hl

    ;  Clear out whatever the last mission left behind.
    call mis_clear_enemies

    call mis_descriptor
    ld (mis_desc),hl

    ; --- the enemy ---------------------------------------------------------
    ld de,MIS_ENEMY_COUNT
    add hl,de
    ld a,(hl)
    ld (mis_left),a
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (mis_src),de

    ld a,(mis_left)
    or a
    jr z,@mis_no_enemies
@mis_enemy:
    call ent_find_free
    jr nc,@mis_no_enemies               ; table full: place what fits

    call ent_addr
    push hl
    ld hl,(mis_src)
    pop de
    ld bc,6
    ldir
    ld (mis_src),hl

    ld a,(ent_index)
    call ent_addr
    call mis_make_enemy

    ld hl,mis_left
    dec (hl)
    jr nz,@mis_enemy
@mis_no_enemies:

    ; --- the resources -----------------------------------------------------
    ld hl,(mis_desc)
    ld de,MIS_PATCH_COUNT
    add hl,de
    ld a,(hl)
    ld (mis_left),a
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)

    ld hl,eco_patches
    ld b,ECO_PATCH_COUNT * ECO_PATCH_SIZE
    xor a
@mis_wipe_patch:
    ld (hl),a
    inc hl
    djnz @mis_wipe_patch

    ld a,(mis_left)
    or a
    ret z
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; count * ECO_PATCH_SIZE
    ld c,l
    ld b,h
    ld hl,eco_patches
    ex de,hl
    ldir                                ; from the descriptor into the patches
    ret


; ----------------------------------------------------------------------------
;  mis_make_enemy -- turn the entity at HL into a Vekhar interceptor
;  In : HL -> the entity
;  Uses: everything
; ----------------------------------------------------------------------------
mis_make_enemy:
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE + ENT_F_ENEMY
    pop hl
    push hl
    ld de,ENT_HULL
    add hl,de
    ld (hl),200
    pop hl
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld (hl),CLASS_INTERCEPTOR
    pop hl
    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld (hl),SQUAD_NONE
    pop hl
    push hl
    ld de,ENT_TARGET
    add hl,de
    ld (hl),ENT_NO_TARGET
    pop hl
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_IDLE
    ret


; ----------------------------------------------------------------------------
;  mis_clear_enemies -- free every hostile slot
;  Uses: everything
; ----------------------------------------------------------------------------
mis_clear_enemies:
    xor a
    ld (mis_scan),a
@mis_clear:
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    jr z,@mis_clear_next
    ld (hl),0
@mis_clear_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@mis_clear
    ret


; ----------------------------------------------------------------------------
;  mis_update -- has the mission been won or lost?
;
;  Called once per game frame. Losing takes precedence: if the Mothership is
;  gone the campaign is over whatever else happened, because the whole colony
;  is aboard it (section 8).
;  Uses: everything
; ----------------------------------------------------------------------------
mis_update:
    ld hl,(mis_timer)
    inc hl
    ld (mis_timer),hl

    ;  Lost?
    ld a,(moth_slot)
    call ent_is_active
    jr c,@mis_alive
    ld a,1
    ld (mis_failed),a
    ret
@mis_alive:

    ld a,(mis_complete)
    or a
    ret nz                              ; already won; waiting for the jump

    call mis_descriptor
    ld de,MIS_OBJECTIVE
    add hl,de
    ld a,(hl)

    cp MIS_OBJ_CLEAR
    jr z,@mis_check_clear
    cp MIS_OBJ_SURVIVE
    jr z,@mis_check_survive

    ;  MIS_OBJ_ARRIVE: getting here IS the objective. Explicitly, because
    ;  falling through into the survive check instead made "nothing to do"
    ;  quietly mean "wait two hundred ticks doing nothing".
    jr @mis_won

@mis_check_survive:
    ld hl,(mis_timer)
    ld de,MIS_SURVIVE_TICKS
    or a
    sbc hl,de
    ret c
    jr @mis_won

@mis_check_clear:
    call mis_count_enemies
    or a
    ret nz

@mis_won:
    ld a,1
    ld (mis_complete),a
    ret


; ----------------------------------------------------------------------------
;  mis_count_enemies -- A = how many hostiles are left alive
;  Uses: everything
; ----------------------------------------------------------------------------
mis_count_enemies:
    xor a
    ld (mis_scan),a
    ld (mis_left),a
@mis_count:
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE + ENT_F_ENEMY
    jr nz,@mis_count_next
    ld hl,mis_left
    inc (hl)
@mis_count_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@mis_count
    ld a,(mis_left)
    ret


; ----------------------------------------------------------------------------
;  mis_jump -- the J key: leave for the next mission
;
;  Refused unless the objective is met. Section 9 says the jump is available
;  "όταν επιτρέπεται", and this is what decides that.
;  Out: CF set if the jump happened
;  Uses: everything
; ----------------------------------------------------------------------------
mis_jump:
    ld a,(mis_complete)
    or a
    jr z,@mis_no_jump

    ld a,(mis_index)
    inc a
    cp MIS_COUNT
    jr nc,@mis_no_jump                  ; the campaign is over

    call fleet_save                     ; what survives starts the next one
    ld a,(mis_index)
    inc a
    ld (mis_index),a
    ;  And out to the disc, so it survives the power going off too. The
    ;  mission index is stamped in by fleet_disc_save, so it has to happen
    ;  after the increment: what is saved is where the player is going, not
    ;  the mission they have just finished.
    call fleet_disc_save
    call fleet_restore
    call mis_setup
    call mis_brief_open                 ; every mission opens on its briefing
    scf
    ret

@mis_no_jump:
    or a
    ret


; ============================================================================
;  Fleet persistence (Homeplanet.md section 10: FLEET.DAT, about 1 KB)
; ============================================================================
;  The whole entity table, hostiles excluded, packed into bank 4. The record
;  is already the save format -- that is what section 7's twenty bytes are for
;  -- so this is a copy with a filter rather than a serialiser.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  fleet_save -- bank whatever is still flying
;  Uses: everything
; ----------------------------------------------------------------------------
fleet_save:
    ld hl,fleet_buffer
    ld (fleet_ptr),hl
    xor a
    ld (fleet_count),a
    ld (mis_scan),a

@fleet_store:
    ld a,(mis_scan)
    call ent_addr
    ld (fleet_src),hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@fleet_store_next             ; empty, or theirs

    ld hl,(fleet_src)
    ld de,(fleet_ptr)
    ld bc,ENT_SIZE
    ldir
    ld (fleet_ptr),de
    ld hl,fleet_count
    inc (hl)

@fleet_store_next:
    ld hl,mis_scan
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@fleet_store

    ld a,1
    ld (mis_saved),a
    ret


; ----------------------------------------------------------------------------
;  fleet_restore -- put the banked fleet back into the entity table
;
;  Does nothing if nothing was ever saved, so mission 1 keeps the fleet it was
;  given rather than being emptied by a restore of nothing.
;  Uses: everything
; ----------------------------------------------------------------------------
fleet_restore:
    ld a,(mis_saved)
    or a
    ret z

    call ent_clear_all

    ld hl,fleet_buffer
    ld (fleet_ptr),hl
    ld a,(fleet_count)
    or a
    ret z
    ld (mis_left),a

    xor a
    ld (mis_scan),a
@fleet_load:
    ld a,(mis_scan)
    call ent_addr
    ex de,hl
    ld hl,(fleet_ptr)
    ld bc,ENT_SIZE
    ldir
    ld (fleet_ptr),hl

    ;  The fleet packs down as ships are lost, so the Mothership almost never
    ;  lands back in the slot it left -- after two losses it comes home to 13,
    ;  not 15. Follow it. moth_slot is what the defeat check reads, and a
    ;  stale one points at whatever the NEXT mission spawns into that slot:
    ;  an enemy interceptor, whose death then reads as losing the colony.
    ld a,(mis_scan)
    call ent_addr
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    cp CLASS_MOTHERSHIP
    jr nz,@fleet_load_next
    ld a,(mis_scan)
    ld (moth_slot),a

@fleet_load_next:
    ld hl,mis_scan
    inc (hl)
    ld hl,mis_left
    dec (hl)
    jr nz,@fleet_load

    ;  Squadron counts are derived, so one recount and the HUD is right.
    jp squad_refresh
