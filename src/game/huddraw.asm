; ============================================================================
;  game/huddraw.asm -- the top strip: the fleet at a glance, in bank 4
; ============================================================================
;  hud2.md. The strip above the playfield is CTX_BAR_H = 20 lines, two text
;  rows, and both are the FLEET'S -- nothing on it is a key:
;
;      HULL [==========    ]  BASE [======        ]  RU 1050  M  3
;      SQUADRONS |||||||||  2 15      >SCT 4                   JUMP
;
;  Line 1: the fleet's hull and the Mothership's as BARS (the owner's ask --
;  "γραφικά (progress bars)"), the treasury and the mission number. Line 2:
;  the nine squadrons as MARKS -- blue for one with ships in it, white for an
;  empty one, red for the selected one, the owner's assignment and the
;  reverse of the palette's usual "white is the thing", so do not "correct"
;  it -- then only the selected squadron's number and its ship count, the
;  yard's readout, and JUMP or LAND when the way out is open.
;
;  It used to be the bottom strip's three rows of text: nine `>n:cc` slots,
;  RU, ?HELP, M n JUMP, the yard, HULL nnn%, INCOMING, BASE nnn%. The bottom
;  strip is the BUTTONS' now (game/ctxbar.asm has its one text line), and
;  what moved up was reshaped to be read at a glance rather than read.
;
;  WHO PAINTS WHAT. hud_draw owns the strip: it blanks all twenty lines and
;  draws everything but the two bars, on the same shadow discipline
;  phase4_hud always had -- the counts, the selection, RU, the yard and the
;  mission, compared against a copy, once into each buffer. The BARS are
;  wave_draw's (game/wavesdraw.asm), on wave_dirty, because the hull moves
;  every time a shot lands and a repaint of the whole strip for each one
;  would undo the bargain; hud_draw sets wave_dirty when it has blanked, so
;  the bars come back over the black. The tutorial owns line 2 while it runs
;  (tut_draw, from wave_draw), and hud_draw leaves it alone.
;
;  LEGAL IN BANK 4 by the narrow rule -- it runs once a frame at the HUD's own
;  point, after every blit and with the window at rest, exactly as ctx_bar
;  and wave_draw do -- and IN THE LOW 16K by arithmetic: bank 4 was 24 bytes
;  from its window and this is about four hundred, while the old phase4_hud
;  it replaces had just given the low 16K two pages back. Move it across the
;  day the bank has the room. The state -- phase4_hud_dirty and the shadows
;  -- is in demo/phase4.asm, where the suite reads it with read_ram.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  hud_draw -- one frame of the top strip
;  Uses: everything
; ----------------------------------------------------------------------------
hud_draw:
    call phase4_hud_changed
    ld hl,phase4_hud_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)                            ; once into each buffer

    ;  The bars are repainted with us, and this is the only coupling between
    ;  the two: the blank below takes them off, and nothing else would put
    ;  them back. Setting the flag rather than calling keeps the "once into
    ;  each buffer" bookkeeping in one place.
    ld a,2
    ld (wave_dirty),a

    ;  Blank the whole strip. Ships are clipped out of it at spr_clip_top and
    ;  nothing else draws here, so this is the whole erase.
    ld bc,#0000                         ; B = x, C = y
    ld d,SCR_BYTES_PER_LINE
    ld e,CTX_BAR_H
    xor a
    call scr_fill_rect

    ; --- line 1: the two captions, the treasury, the mission ---------------
    ld hl,hud_hp_label
    ld b,HUD_HP_X
    ld c,CTX_Y
    call phase4_hud_label
    ld hl,hud_moth_label
    ld b,HUD_MOTH_X
    ld c,CTX_Y
    call phase4_hud_label

    ld hl,hud_ru_label
    ld b,HUD_RU_X
    ld c,CTX_Y
    call phase4_hud_label
    ;  All sixteen bits, in four digits: the Destroyer costs 250 and a player
    ;  has to save past 255 to afford one.
    ld hl,(eco_ru)
    ld b,HUD_RU_NUM_X
    ld c,CTX_Y
    call txt_draw_num4

    ld hl,hud_mis_label
    ld b,HUD_MIS_X
    ld c,CTX_Y
    call phase4_hud_label
    ld a,(mis_index)
    inc a
    ld b,HUD_MIS_NUM_X
    ld c,CTX_Y
    ld d,HUD_MIS_DIGITS                 ; two, right-aligned: the campaign is twenty
    call txt_draw_num

    ; --- line 2 -------------------------------------------------------------
    ;  The tutorial's instruction lives here while it runs; tut_draw paints
    ;  it from wave_draw, on the flag set above.
    ld a,(tut_active)
    or a
    ret nz

    ld hl,hud_sq_label
    ld b,HUD_SQ_X
    ld c,CTX_Y2
    call phase4_hud_label

    ;  The nine marks, with their digits: hud_marks, in BANK 5
    ;  (game/hudmarks.asm), because it is also the squadron alarm's blink and
    ;  this page of the low 16K is full. E = the phase: on.
    ld e,1
    ld ix,hud_marks
    ld a,GA_BANK_5
    call bankn_call

    ;  The selected squadron's number and its count -- and nothing for the
    ;  others, which is the point: which squadrons exist is the marks, and the
    ;  one figure the player is about to give an order about is here. With
    ;  the base selected it is 0 and the WHOLE fleet's count: "When selected
    ;  squadron = 0 show the entire fleet vessel number" (hud_sel_count).
    ld a,(squad_sel)
    add a,'0'
    ld (hud_sel_text),a
    ld hl,hud_sel_text
    ld b,HUD_SEL_X
    ld c,CTX_Y2
    call txt_draw
    ld a,(squad_sel)
    call hud_sel_count
    ld b,HUD_SEL_N_X
    ld c,CTX_Y2
    ld d,2
    call txt_draw_num

    ; --- the way out ---------------------------------------------------------
    ;  mis_leave_ok and not mis_complete: the label is a promise that the key
    ;  works, so it tracks the byte mis_jump reads. Blank, JUMP, or LAND on
    ;  the last mission -- mis_leave_word is the one place that decides.
    call mis_leave_word
    jr nc,@hud_mis_show
    ld a,PEN_RED                        ; section 2's ink for "press this"
    call txt_set_pen
@hud_mis_show:
    ld b,HUD_MIS_JUMP_X
    ld c,CTX_Y2
    call txt_draw
    ld a,PEN_WHITE
    call txt_set_pen

    ; --- the yard -------------------------------------------------------------
    ;  '*' while a ship is on the slipway, '>' while the panel is open and
    ;  offering one, blank otherwise; then how many orders wait behind it.
    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,@hud_yard_idle
    ld c,a
    ld a,'*'
    jr @hud_yard_show
@hud_yard_idle:
    ld a,(eco_build_open)
    or a
    ret z                               ; nothing: the strip was blanked
    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld c,(hl)
    ld a,'>'

@hud_yard_show:
    ld (phase4_yard_text),a
    ld a,c
    add a,a
    add a,a                             ; four bytes a tag: marker + 3 letters
    ld l,a
    ld h,0
    ld de,class_tag
    add hl,de
    ld de,phase4_yard_text + 1
    ld bc,3
    ldir

    ;  One character of depth is enough BY CONSTRUCTION: the count is of
    ;  orders WAITING, the slipway holds the tenth, so it never exceeds
    ;  ECO_QUEUE_WAIT = 9. A blank rather than a '0' when the line is empty.
    ld a,(eco_queue_len)
    or a
    ld a,' '
    jr z,@hud_yard_depth
    ld a,(eco_queue_len)
    add a,'0'
@hud_yard_depth:
    ld (phase4_yard_text + 4),a

    ld hl,phase4_yard_text
    ld b,HUD_YARD_X
    ld c,CTX_Y2
    jp txt_draw


; ----------------------------------------------------------------------------
;  hud_bar -- one hull bar: a blue trough with a white (or red) fill
;  In : A = the percentage 0..100, B = x in bytes
;  Uses: everything
;
;  HUD_BAR_W bytes by HUD_BAR_H lines of the chrome ink, then the inner four
;  lines overwritten from the left for (pct * 46 + 128) >> 8 bytes -- which
;  is pct * 18 / 100 rounded, 0 at 0 and 18 at 100, in one mul_u8 and no
;  divide. Byte-granular, eighteen steps, which is what a glance reads.
;  Below HUD_HP_ALARM the fill is section 2's attention ink, the same third
;  at which the old figure turned red: the moment "one more wave or jump now"
;  changes its answer.
; ----------------------------------------------------------------------------
hud_bar:
    ld (hud_bar_pct),a
    ld a,b
    ld (hud_bar_col),a
    ld c,HUD_BAR_Y
    ld d,HUD_BAR_W
    ld e,HUD_BAR_H
    ld a,SOLID_INK_2
    call scr_fill_rect

    ld a,(hud_bar_pct)
    ld h,a
    ld l,46
    call mul_u8
    ld de,128
    add hl,de
    ld a,h                              ; the fill, in bytes
    or a
    ret z                               ; nothing to fill: a zero width would loop 256
    ld d,a
    ld a,(hud_bar_pct)
    cp HUD_HP_ALARM
    ld a,SOLID_INK_1
    jr nc,@hud_bar_ink
    ld a,SOLID_INK_3
@hud_bar_ink:
    ld hl,hud_bar_col
    ld b,(hl)
    ld c,HUD_BAR_Y + 1
    ld e,HUD_BAR_H - 2
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  phase4_hud_changed -- has anything the strip shows moved?
;
;  Compares the counts and the selection against a shadow copy rather than
;  having every command remember to flag itself: ships die and that changes
;  the counts with nobody pressing anything. Sets the dirty counter to 2, not
;  1: there are two screen buffers and the strip has to be redrawn into each.
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
    jr nz,@p4_hud_diff

    ;  Resources and the yard live in the same strip. The build TIMER is
    ;  deliberately not compared: it changes every frame while a ship is on
    ;  the slipway, and redrawing the strip for a countdown nobody is reading
    ;  would undo the whole point of the dirty flag.
    ld hl,(eco_ru)
    ld de,(phase4_hud_shadow_ru)
    or a
    sbc hl,de
    jr nz,@p4_hud_diff
    ld a,(eco_build_class)
    ld hl,phase4_hud_shadow_yard
    cp (hl)
    jr nz,@p4_hud_diff
    call phase4_yard_key
    ld hl,phase4_hud_shadow_pick
    cp (hl)
    jr nz,@p4_hud_diff
    ld a,(mis_index)
    add a,a
    ld hl,mis_leave_ok
    add a,(hl)
    ld hl,phase4_hud_shadow_mis
    cp (hl)
    ret z

@p4_hud_diff:
    ld hl,squad_count
    ld de,phase4_hud_shadow
    ld bc,SQUAD_MAX + 1
    ldir
    ld a,(squad_sel)
    ld (phase4_hud_shadow_sel),a
    ld hl,(eco_ru)
    ld (phase4_hud_shadow_ru),hl
    ld a,(eco_build_class)
    ld (phase4_hud_shadow_yard),a
    call phase4_yard_key
    ld (phase4_hud_shadow_pick),a
    ld a,(mis_index)
    add a,a
    ld hl,mis_leave_ok
    add a,(hl)
    ld (phase4_hud_shadow_mis),a
    ld a,2
    ld (phase4_hud_dirty),a
    ret


; ----------------------------------------------------------------------------
;  phase4_yard_key -- everything about the yard that the strip DRAWS, in a byte
;  Out: A
;  Uses: AF, HL
;
;  The panel's marker, the class it is offering and how many orders are
;  waiting all land in one field, so one shadow byte can watch all three. The
;  depth goes in the high nibble because it can reach nine and the other two
;  together cannot reach sixteen.
; ----------------------------------------------------------------------------
phase4_yard_key:
    ld a,(eco_queue_len)
    rrca
    rrca
    rrca
    rrca                                ; << 4
    ld hl,eco_build_open
    add a,(hl)
    add a,(hl)                          ; the panel's marker: '>' or nothing
    ld hl,eco_build_pick
    add a,(hl)
    ret


;  A caption in ink 2 and the pen put back to 1 afterwards: chrome is blue and
;  values are white, and nothing may inherit an ink.
;  In : HL -> the text, B = x in bytes, C = y
phase4_hud_label:
    push hl
    push bc
    ld a,PEN_BLUE
    call txt_set_pen
    pop bc
    pop hl
    call txt_draw
    ld a,PEN_WHITE
    jp txt_set_pen


hud_hp_label:       defb "HULL",0
hud_moth_label:     defb "BASE",0
hud_ru_label:       defb "RU",0
hud_mis_label:      defb "M",0
hud_sq_label:       defb "SQUADRONS",0
hud_sel_text:       defb "0",0          ; the digit is patched in
hud_bar_pct:        defb 0
hud_bar_col:          defb 0

;  THE SQUADRON ALARM -- "να αναβοσβήνει η γραμμή του squadron που δέχεται
;  επίθεση". A byte a squadron, set by cbt_retaliate the frame one of its
;  ships is hit, and a countdown of game frames after the last hit anywhere;
;  while it runs hud_marks draws the flagged marks on alternate phases of the
;  50 Hz tick (game/wavesdraw.asm). In the low 16K so the tests read it with
;  read_ram, in the page the marks' loop just left.
hud_alarm:          defs SQUAD_MAX + 1, 0
hud_alarm_left:     defb 0
hud_alarm_phase:    defb 0
