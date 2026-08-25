; ============================================================================
;  game/mission.asm -- the campaign (Homeplanet.md section 10)
; ============================================================================
;  Eight missions, and the fleet carries between them. That carrying IS the
;  game: "ό,τι επιβιώνει σε μια αποστολή ξεκινά την επόμενη. Ό,τι χάνεται,
;  χάνεται οριστικά."
;
;      J   jump to the next mission -- only once the objective is met, which
;          is what section 9's "όταν επιτρέπεται" means
;
;  A mission is a descriptor in bank 4: a name, where the enemy is, where the
;  resources are, and what winning looks like. Adding a mission is data.
;
;  WHERE THE FLEET IS KEPT
;  -----------------------
;  In bank 4, not on disc, and that is a real limitation rather than a
;  shortcut. Section 11 wants the firmware brought back "on the screens
;  between missions" to reach the disc -- but the memory map puts screen B at
;  #8000-#BFFF, right on top of AMSDOS's workspace at #A700. The moment the
;  game clears its second screen the firmware is gone for good, and there is
;  no bringing it back.
;
;  So a saved fleet survives a mission but not a power cycle. Making FLEET.DAT
;  real needs the uPD765 driven directly -- see the note in CLAUDE.md.
; ----------------------------------------------------------------------------

MIS_COUNT           equ 8

;  Descriptor layout, all of it in bank 4.
MIS_NAME            equ 0               ; 12 bytes, zero-terminated
MIS_ENEMY_COUNT     equ 12
MIS_ENEMY_PTR       equ 13              ; -> 6-byte positions
MIS_PATCH_COUNT     equ 15
MIS_PATCH_PTR       equ 16              ; -> 8-byte patches
MIS_OBJECTIVE       equ 18
MIS_SIZE            equ 20

;  What winning looks like.
MIS_OBJ_CLEAR       equ 0               ; destroy every enemy
MIS_OBJ_SURVIVE     equ 1               ; still have a Mothership after a while
MIS_OBJ_ARRIVE      equ 2               ; nothing to fight; just be there

MIS_SURVIVE_TICKS   equ 200             ; game frames for MIS_OBJ_SURVIVE


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
    ret


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
    call fleet_restore
    call mis_setup
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

    ld hl,mis_scan
    inc (hl)
    ld hl,mis_left
    dec (hl)
    jr nz,@fleet_load

    ;  Squadron counts are derived, so one recount and the HUD is right.
    jp squad_refresh


; ============================================================================
;  State
; ============================================================================
mis_index:          defb 0              ; 0-based; the HUD shows it plus one
mis_complete:       defb 0
mis_failed:         defb 0
mis_saved:          defb 0
mis_timer:          defw 0
mis_desc:           defw 0
mis_src:            defw 0
mis_scan:           defb 0
mis_left:           defb 0

fleet_ptr:          defw 0
fleet_src:          defw 0
fleet_count:        defb 0
