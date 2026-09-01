; ============================================================================
;  staticscreens.asm -- code that runs once, or only while the game is stopped
; ============================================================================
;  None of this belongs in the low 16K. phase4_spawn_fleet runs exactly once,
;  from demo_init; mis_brief_draw runs only while a briefing is up, and nothing
;  else is running then; squad_by_class runs on a keypress. The low 16K is for
;  the frame loop and it is down to its last few hundred bytes -- see the note
;  in CLAUDE.md.
;
;  Bank 4 is paged in for the whole run, so this is ordinary executable RAM.
;  The one thing that must not appear here is anything reached from between
;  class_tier_addr and class_blit_done, where bank 4 is out.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  static_wipe -- clear the tactical area for a screen that owns the whole of it
;  Uses: everything
;
;  The briefing, the help page and the orders menu all begin with this, and all
;  three leave the HUD's strip alone: the fleet counts are exactly what a
;  player is about to give an order about. Three copies of six instructions,
;  and one of them would have been the one to forget when spr_clip_bottom moved.
; ----------------------------------------------------------------------------
static_wipe:
    ld bc,#0000
    ld a,(spr_clip_bottom)
    ld e,a
    ld d,SCR_BYTES_PER_LINE
    xor a
    jp scr_fill_rect


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
    ld de,phase4_ship_fields
    call phase4_set_fields
    pop hl

    ld de,ENT_YAW
    add hl,de
    ld a,(phase4_index)
    add a,a
    add a,a
    add a,a
    add a,a                             ; fan the headings out
    ld (hl),a

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
    ld de,phase4_moth_fields
    call phase4_set_fields
    ;  ...at the origin, which is where the fleet forms up around it. Six
    ;  zeroes rather than a table of six zeroes.
    pop hl
    ld b,6
    xor a
@p4_moth_pos:
    ld (hl),a
    inc hl
    djnz @p4_moth_pos

    ret


; ----------------------------------------------------------------------------
;  phase4_set_fields -- write a short list of fields into one entity
;  In : HL -> the entity, DE -> (offset, value) pairs ending in #FF
;  Uses: everything
;
;  Spawning a ship used to be four copies of "pop, push, load the offset, add,
;  store" per class of thing being spawned, and there are three places that
;  spawn something. The offsets and the values are DATA; only the walk is code.
; ----------------------------------------------------------------------------
phase4_set_fields:
@p4_field:
    ld a,(de)
    cp #FF
    ret z
    inc de
    push hl
    ld c,a
    ld b,0
    add hl,bc
    ld a,(de)
    inc de
    ld (hl),a
    pop hl
    jr @p4_field


phase4_ship_fields:
    defb ENT_FLAGS, ENT_F_ACTIVE
    defb ENT_HULL,  255
    defb ENT_SQUAD, 1                   ; the fleet starts as one squadron
    defb ENT_CLASS, CLASS_INTERCEPTOR
    defb #FF

phase4_moth_fields:
    defb ENT_FLAGS, ENT_F_ACTIVE
    defb ENT_CLASS, CLASS_MOTHERSHIP
    defb ENT_SQUAD, SQUAD_NONE
    defb ENT_HULL,  255
    defb #FF


; ----------------------------------------------------------------------------
;  squad_by_class -- the `O` key: one squadron per ship class
;
;  Every order in section 9 is given to a squadron, so what the squadrons ARE
;  decides what the player can say. Carving a fleet up by hand with d, m and n
;  is fine for three ships and hopeless for thirty -- and the division that
;  matters in a fight is by class, because section 8's balance triangle is a
;  statement about classes. "Send the bombers at the frigate" needs the bombers
;  to be a squadron before it can be an order at all.
;
;  THE NUMBER IS THE CLASS INDEX PLUS ONE, and nothing else. That is what makes
;  it worth having: press it again three missions later and the interceptors
;  are squadron 1 again, whatever was lost in between. A class with no ships
;  leaves its number empty rather than everything shuffling up -- numbers that
;  move between missions are worse than numbers with gaps in them, because the
;  player's fingers have already learned them.
;
;  The Mothership is left out: it is not part of the fleet, it is what the
;  fleet is for. `0` selects it, it belongs to no squadron, and its number --
;  2 -- is simply never handed out.
;
;  squad_count is derived, never maintained, so writing ENT_SQUAD, handing the
;  ship to squad_born and calling squad_refresh is the whole of it. Everything
;  else follows: the HUD, the selection falling back if it emptied, and every
;  squadron flying to its own station because phase4_fly derives a ship's slot
;  from its membership.
;  Uses: everything
; ----------------------------------------------------------------------------
squad_by_class:
    xor a
    ld (squad_index),a
@sq_class_one:
    ld a,(squad_index)
    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    pop hl
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    jr nz,@sq_class_next                ; empty, or theirs
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    pop hl
    cp CLASS_MOTHERSHIP
    jr z,@sq_class_next
    inc a
    cp SQUAD_MAX + 1
    jr nc,@sq_class_next                ; more classes than squadrons one day

    ;  Through squad_born like the four reshaping commands, so a class
    ;  squadron that did not exist a moment ago is stationed where its ships
    ;  are rather than at whatever order_home left in the slot. `O` has the
    ;  same defect as `d` -- it is simply invisible on the starting fleet,
    ;  which is all interceptors and therefore all still squadron 1.
    push hl
    ld c,a
    ld de,ENT_SQUAD
    add hl,de
    ld b,(hl)                           ; the squadron it is leaving
    ld (hl),c
    pop hl
    ld a,b
    or a
    call nz,squad_born                  ; nothing to inherit from squadron 0
@sq_class_next:
    ld hl,squad_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@sq_class_one
    jp squad_refresh


; ----------------------------------------------------------------------------
mis_brief_draw:
    ;  ...AND PAY THE DEBT OF WHATEVER PAGE WAS HERE BEFORE, which for the
    ;  first briefing of a game is the TITLE SCREEN. Reported as "στο κείμενο
    ;  της πρώτης πίστας μένει από κάτω μέρος κειμένων του μενού".
    ;
    ;  static_wipe stops at spr_clip_bottom and leaves the strip alone, because
    ;  every other time a briefing is up the fleet counts are down there and
    ;  they are what the player is about to give an order about. The FIRST
    ;  time, what is down there is the title screen's own last two lines -- T
    ;  FOR THE TUTORIAL at 172 and the credit at 186 -- and nothing was ever
    ;  going to take them off: the HUD does not clear its strip, it draws
    ;  labels onto it.
    ;
    ;  title_key already schedules the wipe for exactly this and says so in a
    ;  comment. What was missing is that mis_wipe_screen is called from
    ;  demo_update's PLAYING path only, and the briefing goes up before the
    ;  game ever reaches it -- so the two frames sat unspent behind the
    ;  briefing, and were still unspent when mis_brief_key scheduled two more
    ;  of its own over the top of them.
    ;
    ;  ONLY WHILE THE BRIEFING IS ACTUALLY UP, and that guard is the whole of
    ;  the second bug this caused. A page closes by clearing its own flag
    ;  inside its `_key` routine and demo_update then draws it ONE MORE TIME in
    ;  the same frame -- so without this test, the closing frame spent one of
    ;  the two wipes mis_brief_key had just scheduled for erasing the briefing
    ;  itself. One buffer got cleared and the other did not, and the display
    ;  page-flips: the mission text was on screen every OTHER frame for the
    ;  rest of the mission. Reported as "το κείμενο της πίστας δεν σβήνεται
    ;  όταν μπαίνω στην πίστα, αναβοσβήνει συνέχεια μπροστά".
    ;
    ;  It is the same trap the context bar shipped and @p4_static_done carries
    ;  a paragraph about, arriving from the other side: there the page was
    ;  drawn a frame too late, here its debt was paid a frame too early.
    ;
    ;  On every frame but the first two of a briefing this is a flag test and a
    ;  RET.
    ld a,(mis_briefing)
    or a
    call nz,mis_wipe_screen

    ;  Wipe the whole tactical area; the strip below belongs to the HUD.
    call static_wipe

    call mis_descriptor
    ld b,BRIEF_X
    ld c,BRIEF_TITLE_Y
    call txt_draw                       ; HL is already the name

    ;  The lines are BRIEF_LINES zero-terminated strings a mission, back to
    ;  back in mission_text, walked to rather than pointed at: twenty-four
    ;  pointers was forty-eight bytes of a bank that has none, and the strings
    ;  were already in order.
    call mis_descriptor
    ld de,MIS_TEXT
    add hl,de
    ld a,(hl)
    ld b,a
    add a,a
    add a,b                             ; BRIEF_LINES strings a mission
    ld b,a
    ld hl,mission_text
    or a
    jr z,@mis_brief_at
@mis_brief_seek:
    call mis_next_line
    djnz @mis_brief_seek
@mis_brief_at:
    ld (mis_text_ptr),hl

    ld a,BRIEF_TEXT_Y
    ld (mis_text_y),a
    ld a,BRIEF_LINES
    ld (mis_text_left),a

@mis_brief_line:
    ld hl,(mis_text_ptr)
    push hl
    call mis_next_line
    ld (mis_text_ptr),hl
    pop hl
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
IF DIAG_DISC
    call txt_draw
    ;  One row, and it is here rather than on the title screen because this
    ;  is the screen that comes up AFTER a jump -- so it is the only place
    ;  the fleet SAVE can be reported. See game/libdiag.asm.
    ld a,DIAG_BRIEF_Y
    jp diag_draw_fleet
ELSE
    jp txt_draw
ENDIF


;  HL -> just past the zero terminator of the string at HL
;  Uses: AF, HL
mis_next_line:
    ld a,(hl)
    inc hl
    or a
    jr nz,mis_next_line
    ret


