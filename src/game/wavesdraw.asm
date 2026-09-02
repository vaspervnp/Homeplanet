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

    ;  ...AND THE MESSAGE LINE. Section 5.5 asks for one and this is it: for a
    ;  few seconds, the thing that has just happened that the player would
    ;  otherwise have to infer. A wave arrives six thousand units out and they
    ;  may be looking the other way, so without INCOMING the first they know of
    ;  it is a hull figure falling for no reason they can see; and the Frigate
    ;  unlock is a build panel that silently grows a row three missions after
    ;  the thing that earned it.
    ld a,(wave_say)
    or a
    ret z

    ;  THE INK SEPARATES THEM, because they share the same eighteen characters
    ;  and must never be mistaken for each other. INCOMING is section 2's
    ;  attention ink, like the HULL figure below a third and like JUMP. The
    ;  unlock is ink 1 -- news about the player's own fleet, in the fleet's own
    ;  ink -- and a red word in this slot means a threat and nothing else.
    ld a,(wave_msg)
    or a
    ld a,PEN_RED
    jr z,@wave_say_pen
    ld a,PEN_WHITE
@wave_say_pen:
    call txt_set_pen

    ld a,(wave_msg)
    ld hl,wave_say_text
    call str_index                      ; the walker ctx_class_name uses
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

    call wave_saying
    ld hl,wave_say_shadow
    cp (hl)
    ret z

@wave_hp_diff:
    ld a,(wave_pct)
    ld (wave_pct_shadow),a
    ld a,(wave_moth_pct)
    ld (wave_moth_shadow),a
    call wave_saying
    ld (wave_say_shadow),a
    ld a,2                              ; once into each screen buffer
    ld (wave_dirty),a
    ret



; ----------------------------------------------------------------------------
;  wave_say_frigate -- put the unlock on the message row
;  Uses: AF
;
;  PRESERVES HL, and that is not politeness: its one caller is inside
;  slv_deliver, between the entity pointer being taken and ENT_FLAGS being
;  cleared through it. Two bytes of state, so there is nothing else to save.
;
;  IN BANK 4 with the rest of this row's drawing, and it had to be. Written in
;  waves.asm first, beside the state it writes -- twelve bytes, which took the
;  low 16K over a page boundary and `free:` from 484 to 228, well under the
;  ~450 the tests need for their scratch. The bill comes in units of 256 and
;  the split is the standing answer: state in the low 16K where read_ram can
;  see it, code in the bank. slv_deliver is bank 4 code already, so this is a
;  call between two routines that are both here.
;
;  IT OVERWRITES AN INCOMING THAT IS STILL UP, which is the one judgement in
;  here. A threat outranks good news -- but this fires ONCE IN A CAMPAIGN and
;  INCOMING fires every wave, so the player loses at worst a few seconds of a
;  warning that will be repeated inside a minute, against never being told at
;  all that the thing they have spent three missions towing has worked. The
;  hull was also delivered by a corvette they sent, so they are looking at the
;  fleet rather than at the horizon.
; ----------------------------------------------------------------------------
wave_say_frigate:
    ld a,WAVE_SAY_FRAMES
    ld (wave_say),a
    ld a,WAVE_MSG_FRIGATE
    ld (wave_msg),a
    ret


; ----------------------------------------------------------------------------
;  wave_saying -- what the message row is saying, as ONE byte
;  Out: A = 0 when quiet, else the message number plus one
;  Uses: AF
;
;  ONE shadow byte for both halves of the state, and that is what it is for.
;  The countdown ticks every frame, so comparing it as a number would repaint
;  the row forty times a message; comparing it as a yes/no was right while
;  there was one message and became a hole the moment there were two -- an
;  unlock landing while INCOMING is still up does not change the yes/no, so the
;  row would go on saying INCOMING until the countdown ran out. Plus one is
;  what keeps message 0 distinct from silence.
; ----------------------------------------------------------------------------
wave_saying:
    ld a,(wave_say)
    or a
    ret z
    ld a,(wave_msg)
    inc a
    ret


wave_hp_label:      defb "HULL",0
wave_moth_label:    defb "BASE",0
wave_hp_sign:       defb "%",0
;  Indexed by wave_msg, so the ORDER here is WAVE_MSG_*. Both must fit between
;  HUD_SAY_X and HUD_MOTH_X -- eighteen characters -- and src/main.asm asserts
;  it, because txt_draw clips at the screen edge and would happily write
;  INCOMING over the top of the Mothership's hull figure.
wave_say_text:      defb "INCOMING",0
wave_say_text_1:    defb "FRIGATE UNLOCKED",0
wave_say_text_end:
