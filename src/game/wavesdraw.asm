; ============================================================================
;  game/wavesdraw.asm -- the hull row, in bank 4
; ============================================================================
;  The DRAWING half of game/waves.asm. The equates, every byte of state and the
;  whole of the simulation stay in the low 16K; this is the pen work and the
;  four strings it needs.
;
;  Same split as order.asm/ordercmd.asm and squadinfo.asm/squadinforun.asm, and
;  it went across for the same reason those did: the low 16K ran out. Adding
;  the Mothership's own figure to this row took `free:` from 524 to 268, and
;  the floor is about 450 -- tests/test_sound.py puts 384 bytes of stub above
;  LOW_END and the harness another 0x60, so a dozen test classes that have
;  nothing to do with waves start failing below it. The bill arrives in units
;  of 256, because gen/tables.asm is page-aligned.
;
;  IT IS LEGAL HERE BY THE NARROW TEST AND NOT BY THE LOOSE ONE. "Does it run
;  while the game is stopped" would say no -- this runs once every game frame.
;  The rule is "can it run between class_tier_addr and class_blit_done", and
;  nothing here can: wave_draw is called from the HUD's own point in the frame,
;  after every blit is finished and with bank 4 back at rest. game/ctxbar.asm
;  and gfx/markproj.asm are the other two that live here on that reasoning.
;
;  CODE MOVES FOR FREE AND DATA COSTS A HUNDRED CALL SITES, so wave_pct,
;  wave_moth_pct, wave_dirty and the two shadows all stayed down there: half
;  the suite reads them with read_ram, and a variable in the bank has to be
;  read with read_bank4 instead.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  wave_draw -- one frame of the hull readout
;  Uses: everything
; ----------------------------------------------------------------------------
wave_draw:
    ;  The tutorial owns this row outright while it is running, and wave_dirty
    ;  goes with it -- one dirty flag for row C whoever is drawing there, which
    ;  is what makes the coupling with phase4_hud and mis_wipe free. The row is
    ;  eighty BYTES, which is forty characters, and HULL nnn% and INCOMING
    ;  already take the first twenty of them; there is no sharing it with a line
    ;  of instruction. See game/tutorialrun.asm.
    ld a,(tut_active)
    or a
    jp nz,tut_draw

    call wave_changed
    ld hl,wave_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ;  Blank the row first. This is the only thing that ever writes here -- the
    ;  tactical view is clipped out at spr_clip_bottom and the other two HUD
    ;  rows are below it -- so this is the whole erase, with no dirty rectangle
    ;  to record and nothing to co-ordinate with.
    ld b,0
    ld c,HUD_ROW_C_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,TXT_CHAR_H
    xor a
    call scr_fill_rect

    ld hl,wave_hp_label
    ld b,HUD_HP_X
    ld c,HUD_ROW_C_Y
    call phase4_hud_label               ; chrome is ink 2, and puts the pen back

    ;  The figure, and its ink. Section 2 keeps ink 3 for the thing that wants
    ;  attention, and a fleet down to a third of its hull is the clearest case
    ;  of that in the game: it is the moment the answer to "one more wave or
    ;  jump now" changes.
    ld a,(wave_pct)
    cp HUD_HP_ALARM
    ld a,PEN_WHITE
    jr nc,@wave_hp_pen
    ld a,PEN_RED
@wave_hp_pen:
    call txt_set_pen

    ld a,(wave_pct)
    ld b,HUD_HP_X + 5 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    ld d,3
    call txt_draw_num
    ld hl,wave_hp_sign
    ld b,HUD_HP_X + 8 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE                      ; nothing inherits an ink
    call txt_set_pen

    ;  THE MOTHERSHIP'S OWN HULL, at the other end of the same row. See
    ;  wave_moth_percent for why it cannot be read off the fleet's figure: an
    ;  average of seventeen ships hides the one whose loss ends the campaign.
    ;  BASE rather than MOTH because BASE is the word the game already uses for
    ;  it -- the orders menu says CENTRE ON BASE and the help page repeats it --
    ;  and four letters keeps it the same shape as HULL beside it.
    ld hl,wave_moth_label
    ld b,HUD_MOTH_X
    ld c,HUD_ROW_C_Y
    call phase4_hud_label

    ld a,(wave_moth_pct)
    cp HUD_HP_ALARM
    ld a,PEN_WHITE
    jr nc,@wave_moth_pen
    ld a,PEN_RED
@wave_moth_pen:
    call txt_set_pen

    ld a,(wave_moth_pct)
    ld b,HUD_MOTH_X + 5 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    ld d,3
    call txt_draw_num
    ld hl,wave_hp_sign
    ld b,HUD_MOTH_X + 8 * TXT_CHAR_W_BYTES
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE
    call txt_set_pen

    ;  ...and, for a few seconds after one lands, why the shooting started. A
    ;  wave arrives six thousand units out and the player may be looking the
    ;  other way; without this the first they know of it is a hull figure
    ;  falling for no reason they can see.
    ld a,(wave_say)
    or a
    ret z
    ld a,PEN_RED
    call txt_set_pen
    ld hl,wave_say_text
    ld b,HUD_SAY_X
    ld c,HUD_ROW_C_Y
    call txt_draw
    ld a,PEN_WHITE
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  wave_changed -- has anything in the row moved?
;  Uses: everything
;
;  Two shadows and the same shape as phase4_hud_changed, for the same reason:
;  hull falls with nobody pressing anything. The INCOMING countdown is compared
;  as a yes/no rather than as a number, because it ticks every frame and only
;  its two transitions are worth a repaint.
; ----------------------------------------------------------------------------
wave_changed:
    ld a,(wave_pct)
    ld hl,wave_pct_shadow
    cp (hl)
    jr nz,@wave_hp_diff

    ;  ...and the Mothership's, which moves on its own: a wave that goes
    ;  straight for it can take a fifth of its hull without the fleet's average
    ;  moving a whole point.
    ld a,(wave_moth_pct)
    ld hl,wave_moth_shadow
    cp (hl)
    jr nz,@wave_hp_diff

    ld a,(wave_say)
    or a
    jr z,@wave_hp_quiet
    ld a,1
@wave_hp_quiet:
    ld hl,wave_say_shadow
    cp (hl)
    ret z

@wave_hp_diff:
    ld a,(wave_pct)
    ld (wave_pct_shadow),a
    ld a,(wave_moth_pct)
    ld (wave_moth_shadow),a
    ld a,(wave_say)
    or a
    jr z,@wave_hp_quiet2
    ld a,1
@wave_hp_quiet2:
    ld (wave_say_shadow),a
    ld a,2                              ; once into each screen buffer
    ld (wave_dirty),a
    ret



wave_hp_label:      defb "HULL",0
wave_moth_label:    defb "BASE",0
wave_hp_sign:       defb "%",0
wave_say_text:      defb "INCOMING",0
wave_say_text_end:
