; ============================================================================
;  squadinforun.asm -- `I`: the page itself (bank 4)
; ============================================================================
;  Bank code by the narrow rule in game/shipclass.asm: info_key runs on a
;  keypress and info_draw from demo_update while the world is stopped, so
;  neither can be reached from between class_tier_addr and class_blit_done.
;
;  Its layout equates and info_shown are in game/squadinfo.asm, in the low
;  16K. Everything it reads from the bank -- class_hull, ctx_class_name,
;  static_wipe, help_prompt -- it reads with the window at rest, which is the
;  only test that matters.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  info_open -- put the squadron up
;  Uses: AF
; ----------------------------------------------------------------------------
info_open:
    ld a,1
    ld (info_shown),a
    ret


; ----------------------------------------------------------------------------
;  info_key -- ESC puts it away again
;  Uses: everything
; ----------------------------------------------------------------------------
info_key:
    ld a,KEY_ESC
    call key_hit
    ret nc
    xor a
    ld (info_shown),a

    ;  The same screen debt the briefing and the help page run up.
    ld a,2
    ld (mis_wipe),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  info_draw -- the whole page
;  Uses: everything
; ----------------------------------------------------------------------------
info_draw:
    ;  The strip below belongs to the HUD, so the squadron counts and the
    ;  fleet's hull stay readable beside the breakdown of one squadron.
    call static_wipe

    ld hl,info_title
    ld b,INFO_NAME_X
    ld c,INFO_TITLE_Y
    call txt_draw

    ld a,(squad_sel)
    ld b,INFO_NUM_X
    ld c,INFO_TITLE_Y
    ld d,1
    call txt_draw_num

    ;  The shape it is flying in, on the same line as its number, because both
    ;  are properties of the squadron rather than of the ships in it. The name
    ;  alone and no caption: `F` is what changes it and both the help page and
    ;  the orders menu say so, and a forty-byte line with FORMATION on it would
    ;  push the prompt off the screen.
    ld a,(squad_sel)
    ld l,a
    ld h,0
    ld de,squad_form
    add hl,de
    ld a,(hl)
    add a,PAGE_FORM_0                   ; the formation's name, in bank 7
    ld hl,page_words
    call bank7_fetch
    ld hl,bank7_line
    ld b,INFO_FORM_X
    ld c,INFO_TITLE_Y
    call txt_draw

    ;  "ESC - BACK" is the help page's string. One prompt, so the two pages
    ;  cannot come to disagree about how you get out of them.
    ld hl,page_words
    ld a,PAGE_HELP_PROMPT
    call bank7_fetch
    ld hl,bank7_line
    ld b,INFO_PROMPT_X
    ld c,INFO_TITLE_Y
    call txt_draw

    xor a
    ld (info_class),a
    ld (info_total),a
    ld hl,0
    ld (info_thull),hl
    ld (info_tfull),hl
    ld a,INFO_BODY_Y
    ld (info_y),a

@info_class_row:
    call info_tally

    ;  Fold this class into the totals whether or not it gets a row -- a class
    ;  with no ships contributes nothing, so there is no case to make.
    ld a,(info_count)
    ld hl,info_total
    add a,(hl)
    ld (hl),a

    ld hl,(info_thull)
    ld de,(info_hull)
    add hl,de
    ld (info_thull),hl
    ld hl,(info_tfull)
    ld de,(info_full)
    add hl,de
    ld (info_tfull),hl

    ;  A class the squadron does not have gets no row at all. Printing
    ;  "DESTROYER 0 0%" seven times over would bury the two lines that matter.
    ld a,(info_count)
    or a
    jr z,@info_next_class

    call info_row
    ld a,(info_y)
    add a,INFO_STEP
    ld (info_y),a

@info_next_class:
    ld hl,info_class
    inc (hl)
    ld a,(hl)
    cp CLASS_COUNT
    jr c,@info_class_row

    ;  The total. It is the answer to "how many ships has it got", so it is
    ;  drawn even when it is zero -- a page with nothing on it says nothing.
    ld a,(info_y)
    add a,INFO_TOTAL_GAP
    ld (info_y),a

    ld hl,info_text_all
    ld b,INFO_NAME_X
    ld a,(info_y)
    ld c,a
    call txt_draw

    ld a,(info_total)
    ld (info_count),a
    ld hl,(info_thull)
    ld (info_hull),hl
    ld hl,(info_tfull)
    ld (info_full),hl
    jp info_figures


; ----------------------------------------------------------------------------
;  info_row -- one class: its name, its count, its hull
;  In : (info_class), (info_count), (info_hull), (info_full), (info_y)
;  Uses: everything
; ----------------------------------------------------------------------------
info_row:
    ;  The whole word, not the three-letter tag. The tag exists because the
    ;  HUD's yard readout has five bytes; this page has eighty, and "SCT" in a
    ;  corner is exactly what sent a player to ask what he was building.
    ld a,(info_class)
    call ctx_class_name
    ld b,INFO_NAME_X
    ld a,(info_y)
    ld c,a
    call txt_draw
    ;  ...and fall through.


; ----------------------------------------------------------------------------
;  info_figures -- the count and the hull percentage of the current row
;  In : (info_count), (info_hull), (info_full), (info_y)
;  Uses: everything
;
;  Shared by the class rows and by the total, which is why the total loads the
;  three variables rather than carrying its own drawing code.
; ----------------------------------------------------------------------------
info_figures:
    ld a,(info_y)
    ld c,a
    ld b,INFO_COUNT_X
    ld d,2
    ld a,(info_count)
    call txt_draw_num

    ld hl,(info_hull)
    ld de,(info_full)
    call wave_pct_of
    ld (info_pct),a

    ;  Section 2's attention ink, at the same third the HUD's fleet figure
    ;  uses -- so "this squadron is in trouble" reads the same way as "the
    ;  fleet is", and the two cannot drift apart.
    cp HUD_HP_ALARM
    ld a,PEN_WHITE
    jr nc,@info_pen
    ld a,PEN_RED
@info_pen:
    call txt_set_pen

    ld a,(info_y)
    ld c,a
    ld b,INFO_PCT_X
    ld d,3
    ld a,(info_pct)
    call txt_draw_num

    ld hl,info_text_pct
    ld b,INFO_PCT_X + 3 * TXT_CHAR_W_BYTES
    ld a,(info_y)
    ld c,a
    call txt_draw

    ld a,PEN_WHITE                      ; nothing inherits an ink
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  info_tally -- count (info_class) in the selected squadron
;  Out: (info_count) ships, (info_hull) hull between them, (info_full) what
;       that many undamaged ships of the class would have
;  Uses: everything
;
;  The pointer walks the ENT_FLAGS byte and steps by ENT_SIZE, the way
;  wave_health does: the common case is `ld a,(hl)` and a compare, and
;  ENT_CLASS, ENT_HULL and ENT_SQUAD are all within one byte of the flags in
;  section 7's record. src/main.asm asserts that adjacency for wave_health
;  already, and this leans on the same assert.
; ----------------------------------------------------------------------------
info_tally:
    xor a
    ld (info_count),a
    ld hl,0
    ld (info_hull),hl
    ld (info_full),hl

    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_MAX
@info_slot:
    ld a,(hl)
    and ENT_F_ACTIVE + ENT_F_ENEMY
    cp ENT_F_ACTIVE
    call z,info_fold                    ; ours, and flying
    add hl,de
    djnz @info_slot
    ret


; ----------------------------------------------------------------------------
;  info_fold -- one live friendly ship, if it is ours and of this class
;  In : HL -> its ENT_FLAGS byte
;  Out: HL, DE and B all as they were -- the loop above is holding all three
;  Uses: AF, C
; ----------------------------------------------------------------------------
info_fold:
    push de
    push hl

    inc hl
    ld a,(hl)                           ; ENT_SQUAD is the byte after the flags
    ld hl,squad_sel
    cp (hl)
    jr nz,@info_not_ours

    pop hl
    push hl
    dec hl
    ld c,(hl)                           ; ENT_HULL, the byte before the flags
    dec hl
    ld a,(hl)                           ; ...and ENT_CLASS before that
    ld hl,info_class
    cp (hl)
    jr nz,@info_not_ours

    ld hl,info_count
    inc (hl)

    ;  HL += A without a spare register pair, twice: B is the loop counter and
    ;  DE is the stride, so `ld b,0 : add hl,bc` is not available. The same
    ;  add/ld/adc/sub/ld that wave_hp_add uses.
    ld a,c
    ld hl,(info_hull)
    add a,l
    ld l,a
    adc a,h
    sub l
    ld h,a
    ld (info_hull),hl

    ld a,(info_class)
    ld l,a
    ld h,0
    ld de,class_hull                    ; in bank 4, at rest
    add hl,de
    ld a,(hl)
    ld hl,(info_full)
    add a,l
    ld l,a
    adc a,h
    sub l
    ld h,a
    ld (info_full),hl

@info_not_ours:
    pop hl
    pop de
    ret


; ============================================================================
;  Text and state
; ============================================================================
info_title:         defb "SQUADRON",0
info_text_all:      defb "ALL",0
info_text_pct:      defb "%",0

;  In FORM_LOOSE..FORM_WALL order, which is what str_index indexes by. Back to
;  back and zero-terminated rather than at a fixed stride, like class_name.
;
;  Getting this list out of step with game/formation.asm would not draw the
;  wrong word -- it would walk off the end of the table into whatever the
;  assembler put next. Nothing at build time can count terminators, so the
;  guard is TestTheFormation in tests/test_squadinfo.py, which presses `F`
;  round the cycle and reads a different real word off the screen each time.
;  info_form_names is in BANK 7 -- page_words in game/screentext.asm.

