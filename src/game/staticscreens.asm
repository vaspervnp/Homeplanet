; ============================================================================
;  staticscreens.asm -- code that runs once, or only while the game is stopped
; ============================================================================
;  Neither of these belongs in the low 16K. phase4_spawn_fleet runs exactly
;  once, from demo_init; mis_brief_draw runs only while a briefing is up, and
;  nothing else is running then. The low 16K is for the frame loop and it is
;  down to its last few hundred bytes -- see the note in CLAUDE.md.
;
;  Bank 4 is paged in for the whole run, so this is ordinary executable RAM.
; ----------------------------------------------------------------------------

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
mis_brief_draw:
    ;  Wipe the whole tactical area; the strip below belongs to the HUD.
    ld bc,#0000
    ld a,(spr_clip_bottom)
    ld e,a
    ld d,SCR_BYTES_PER_LINE
    xor a
    call scr_fill_rect

    call mis_descriptor
    ld b,BRIEF_X
    ld c,BRIEF_TITLE_Y
    call txt_draw                       ; HL is already the name

    ;  The three lines live in their own table, indexed by MIS_TEXT.
    call mis_descriptor
    ld de,MIS_TEXT
    add hl,de
    ld a,(hl)
    ld l,a
    ld h,0
    add hl,hl                           ; three pointers a mission
    ld d,h
    ld e,l
    add hl,hl
    add hl,de                           ; * 6
    ld de,mission_text_table
    add hl,de
    ld (mis_text_ptr),hl

    ld a,BRIEF_TEXT_Y
    ld (mis_text_y),a
    ld a,BRIEF_LINES
    ld (mis_text_left),a

@mis_brief_line:
    ld hl,(mis_text_ptr)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (mis_text_ptr),hl
    ex de,hl
    ld b,BRIEF_X
    ld a,(mis_text_y)
    ld c,a
    call txt_draw

    ld hl,mis_text_y
    ld a,(hl)
    add a,BRIEF_LINE_STEP
    ld (hl),a
    ld hl,mis_text_left
    dec (hl)
    jr nz,@mis_brief_line

    ld hl,mis_brief_prompt
    ld b,BRIEF_X
    ld c,BRIEF_TEXT_Y + BRIEF_LINES * BRIEF_LINE_STEP + 12
    jp txt_draw


