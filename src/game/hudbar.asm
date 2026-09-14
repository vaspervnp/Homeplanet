; ============================================================================
;  game/hudbar.asm -- the button bar along the bottom, running FROM BANK 6
; ============================================================================
;  hud2.md sections 2, 3 and 5. Sixteen buttons in the strip under the
;  playfield (HUD_BTN_Y, sixteen lines), a blue frame on the selected one,
;  and the cursor keys walking it whenever nothing else owns them:
;
;      MOVE DOCK FORM ATTACK GUARD MINE BUILD JUMP INFO PAUSE MENU | COMBAT+ ECON+ SQUAD+ CAMERA+ SYSTEM+
;
;  MOVE IS FIRST, and that is the one layout decision with a reason: the
;  frame starts on it, so ENTER with nothing selected opens the move disc
;  exactly as ENTER always did -- the key every player has learned keeps
;  working, and the bar is discovered from it rather than in its way.
;
;  LEFT and RIGHT move the frame (and wrap); ENTER presses the button under
;  it; a group opens as a SUB-BAR -- BACK first, then its members -- in the
;  same row, and BACK or ESC closes it. A button presses its KEY: the bar
;  plants the key's edge into key_hits exactly as the orders menu does, and
;  phase4_commands, which runs straight after, acts on it -- so the bar is a
;  second front end onto the commands and not a second copy of any of them.
;  Pressing `A` and pressing ATTACK are the same event by construction. The
;  ENTER that pressed the button is TAKEN OUT of the frame's snapshot first,
;  or order_update would open the move disc on top of every press.
;
;  THE ARROWS RULE (the owner's): "όταν τα βελάκια δεν χρησιμοποιούνται για
;  να μετακινήσουν squadron θα επιλέγουν buttons στο hud με απόλυτη
;  προτεραιότητα" -- and then "με shift και βελάκια να ελέγχω το 3d space
;  όπως πριν με τα βελάκια". So the bar is the arrows' DEFAULT owner, and
;  SHIFT + the arrows orbit the camera exactly as the bare arrows used to:
;  game/ordercmd.asm asks key_down of SHIFT before it calls order_camera,
;  and the bar stands aside while SHIFT is down. The disc, the pan, the
;  cockpit and the build panel still take the keys while they are open, and
;  the tutorial keeps the bare arrows outright: its first lesson is that
;  they turn the view.
;
;  THE DESCRIPTION IS THE STRIP'S THIRD LINE (HUD_DESC_Y), under the context
;  line -- "το ποιο button είναι επιλεγμένο να μπει σε τρίτη γραμμή στο κάτω
;  hud. Η δεύτερη να είναι για τα άλλα κείμενα, όπως το paused ή την επιλογή
;  build" -- so PAUSED and a caption can both be up. bar_frame draws it on
;  its own shadow: the icon plus one while the four seconds run, else 0.
;
;  WHY BANK 6. The bar needs ~300 bytes of code and ~600 of words, bank 4 had
;  111 bytes to its window, the low 16K 31 to its page, and bank 7 four. Bank
;  6 had a thousand, and the chase set the precedent for CODE in a sprite
;  bank: this runs with the window at rest, from two bank-4 call sites through
;  bankn_call (sys/libload.asm), and calls nothing but the low 16K -- key_hit,
;  scr_fill_rect, gfx_vline, scr_line_addr -- and bankn_copy, which pages the
;  icons in from bank 5 and pages BANK 6 back, because bankn_call told it
;  where home is. Its state is here too, in the image, like the chase's. What
;  it cannot do is call key_inject or key_clear, which are bank 4, so it
;  carries its own two-instruction copies of their bit arithmetic.
;
;  DRAWING. An icon is fifty-six bytes in bank 5 -- fourteen rows, the cell's
;  top and bottom rows being the frame's blank margin -- and the only RAM
;  outside the window is the low 16K, so it comes down in two halves of
;  twenty-eight through bank7_line and goes onto the screen a row at a time. The bar is
;  repainted only when the selection or the group changes -- and whenever
;  hud_draw is repainting the strips (phase4_hud_dirty), because that is when
;  a page wipe has taken the row away. Twice, once into each buffer.
; ----------------------------------------------------------------------------

BAR_SLOTS           equ 16              ; buttons across the strip
BAR_PITCH           equ 5               ; bytes between them: 4 of icon, 1 of air
BAR_X0              equ 1               ; the first one's byte column
BAR_GROUPS          equ 5
BAR_GROUP_SLOT0     equ BAR_SLOTS - BAR_GROUPS   ; the groups are the last five slots
BAR_DESC_TICKS      equ 200             ; the description stays four seconds
BAR_NONE            equ #FF             ; no group open
BAR_HALF            equ HUD_ICON_BYTES / 2       ; an icon comes down in two of these
BAR_NAME_MAX        equ 4               ; name codes 1..4 are the words below

;  Joystick 1 is row 9 of the matrix, which key_scan reads with the rest, so
;  the stick is four more key ids and its fire button one more: "τα κουμπιά να
;  επιλέγονται και με joystick". Left and right walk, fire presses.
KEY_JOY_UP          equ 9*8 + 0
KEY_JOY_DOWN        equ 9*8 + 1
KEY_JOY_LEFT        equ 9*8 + 2
KEY_JOY_RIGHT       equ 9*8 + 3
KEY_JOY_FIRE2       equ 9*8 + 4
KEY_JOY_FIRE1       equ 9*8 + 5


; ----------------------------------------------------------------------------
;  bar_update -- the keys, once a frame BEFORE phase4_commands reads them
;  Uses: everything
; ----------------------------------------------------------------------------
bar_update:
    ;  An edge the orders menu planted this frame is a command already chosen,
    ;  not a press of ours: the ENTER that picked MOVE DISC must open the disc
    ;  and not press whatever the frame is on.
    ld a,(key_injected)
    ld hl,disc_active
    or (hl)
    ld hl,pan_active
    or (hl)
    ret nz
    ld a,(pilot_slot)
    cp ENT_MAX
    ret c                               ; the cockpit has the arrows and SPACE
    ld a,KEY_SHIFT
    call key_down
    ret c                               ; SHIFT + arrows: the camera's, not ours

    ld a,KEY_CUR_LEFT
    ld c,KEY_JOY_LEFT
    call bar_hit2
    jr nc,@bar_no_left
    call bar_list                       ; B = how many buttons are showing
    ld a,(bar_sel)
    or a
    jr nz,@bar_left_ok
    ld a,b
@bar_left_ok:
    dec a
    ld (bar_sel),a
    call bar_show
@bar_no_left:

    ld a,KEY_CUR_RIGHT
    ld c,KEY_JOY_RIGHT
    call bar_hit2
    jr nc,@bar_no_right
    call bar_list
    ld a,(bar_sel)
    inc a
    cp b
    jr c,@bar_right_ok
    xor a
@bar_right_ok:
    ld (bar_sel),a
    call bar_show
@bar_no_right:

    ;  With the build panel up the arrows still walk the bar -- "τα βελάκια
    ;  δεξιά αριστερά και η επιλογή κουμπιών να έχουν απόλυτη προτεραιότητα"
    ;  -- but ENTER is the panel's (it buys) and so is ESC (it shuts it).
    ld a,(eco_build_open)
    or a
    ret nz

    ;  ESC closes an open group -- and is taken out of the frame, or the
    ;  orders menu would open on top of it. With no group open it is the
    ;  menu's, as everywhere else.
    ld a,KEY_ESC
    call key_hit
    jr nc,@bar_no_esc
    ld a,(bar_group)
    cp BAR_NONE
    jr z,@bar_no_esc
    call bar_close
    ld a,KEY_ESC
    call bar_key_clear
@bar_no_esc:

    ;  A KEY THAT IS A VISIBLE BUTTON SELECTS IT -- "όταν πατάω ένα πλήκτρο
    ;  που αντιστοιχεί σε ορατό κουμπί, να επιλέγεται το κουμπι και να
    ;  εκτελείται η εντολή". The command runs as it always did, because the
    ;  key is left in the snapshot for phase4_commands; this only moves the
    ;  frame onto the button, which puts its caption up. ENTER is skipped:
    ;  it is the bar's own press and MOVE's key both, and a bare ENTER means
    ;  "press what the frame is on". A key whose button is in a closed group
    ;  moves nothing.
    call bar_list
    ld c,0
@bar_scan:
    push bc
    push hl
    ld a,(hl)
    ld l,a
    ld h,0
    ld de,hud_icon_key
    add hl,de
    ld a,(hl)
    or a
    jr z,@bar_scan_next
    cp KEY_ENTER
    jr z,@bar_scan_next
    call key_hit
    jr c,@bar_scan_hit
@bar_scan_next:
    pop hl
    pop bc
    inc hl
    inc c
    djnz @bar_scan
    jr @bar_enter
@bar_scan_hit:
    pop hl
    pop bc
    ld a,c
    ld (bar_sel),a
    call bar_show

@bar_enter:
    ld a,KEY_ENTER
    ld c,KEY_JOY_FIRE1
    call bar_hit2
    jr c,@bar_pressed
    ld a,KEY_JOY_FIRE2                  ; either fire button
    call key_hit
    ret nc
@bar_pressed:
    ld a,KEY_ENTER
    call bar_key_clear                  ; the press is ours, not the disc's
                                        ; (the fire buttons are read by nobody else: left as they are)
    call bar_current_icon
    ;  ...and fall into the dispatch

; ----------------------------------------------------------------------------
;  bar_press -- what the button under the frame does
;  In : A = its icon
; ----------------------------------------------------------------------------
bar_press:
    cp ICON_BACK
    jr z,bar_close
    cp ICON_GRP_COMBAT
    jr c,@bar_key
    cp ICON_BACK
    jr nc,@bar_key
    sub ICON_GRP_COMBAT                 ; the five groups are consecutive icons
    jr bar_open
@bar_key:
    ld l,a
    ld h,0
    ld de,hud_icon_key                  ; gen/hudcaptions.asm: the key an icon presses
    add hl,de
    ld a,(hl)
    or a
    ret z                               ; a chrome cell: nothing to press
    jr bar_key_set


;  Out: CF set if either key A or key C was pressed this frame
bar_hit2:
    call key_hit
    ret c
    ld a,c
    jp key_hit


; ----------------------------------------------------------------------------
;  bar_reset -- the frame back on MOVE, no group open: the tutorial's start
;  Uses: AF
;
;  Its step 7 says "ENTER ARROWS ENTER TO MOVE IT", which is true of ENTER
;  at rest and of nothing else, so the stage begins at rest.
; ----------------------------------------------------------------------------
bar_reset:
    xor a
    ld (bar_sel),a
    ld (bar_desc),a
    ld a,BAR_NONE
    ld (bar_group),a
    ret


; ----------------------------------------------------------------------------
;  bar_open / bar_close -- a group as a sub-bar, and back to the top row
;  In : A = the group (bar_open)
;
;  Opening lands the frame on the first MEMBER, past BACK; closing puts it
;  back on the group's own button, which is slot BAR_GROUP_SLOT0 + group.
; ----------------------------------------------------------------------------
bar_open:
    ld (bar_group),a
    ld a,1
    ld (bar_sel),a
    jr bar_show

bar_close:
    ld a,(bar_group)
    add a,BAR_GROUP_SLOT0
    ld (bar_sel),a
    ld a,BAR_NONE
    ld (bar_group),a
    ;  ...and fall into bar_show

;  The moment the frame moved: the description line counts from here.
bar_show:
    xor a
    ld (bar_hint),a                     ; the player has found the bar: the hint is over
bar_show_keep:
    ld a,(sys_tick_50hz)
    ld (bar_tick),a
    ld a,1
    ld (bar_desc),a
    ret


; ----------------------------------------------------------------------------
;  bar_list -- what the row is showing
;  Out: HL -> the icons, B = how many
;  Uses: AF, B, DE, HL
; ----------------------------------------------------------------------------
bar_list:
    ld a,(bar_group)
    cp BAR_NONE
    jr z,@bl_top
    add a,a
    ld l,a
    ld h,0
    ld de,bar_group_ptrs
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a                              ; HL -> count, then the icons
    ld b,(hl)
    inc hl
    ret
@bl_top:
    ld hl,bar_top_icons
    ld b,BAR_SLOTS
    ret

;  Out: A = the icon under the frame
bar_current_icon:
    call bar_list
    ld a,(bar_sel)
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    ret


; ----------------------------------------------------------------------------
;  bar_key_set / bar_key_clear -- one edge into, or out of, the frame's snapshot
;  In : A = key id
;  Uses: AF, B, DE, HL
;
;  key_inject and key_clear are bank 4 and this is bank 6, so this is their
;  arithmetic and has to agree with key_bit's: row = id >> 3, and bit n of the
;  row byte IS key n, no reversal. key_hits and not key_edge, for the reason
;  key_inject gives: the edge accumulator belongs to the interrupt.
; ----------------------------------------------------------------------------
bar_key_set:
    call bar_key_bit
    or (hl)
    ld (hl),a
    ret

bar_key_clear:
    call bar_key_bit
    cpl
    and (hl)
    ld (hl),a
    ret

;  Out: HL -> the row byte, A = the key's bit
bar_key_bit:
    push af
    rrca
    rrca
    rrca
    and #1F
    ld l,a
    ld h,0
    ld de,key_hits
    add hl,de
    pop af
    and 7
    inc a
    ld b,a
    ld a,1
    jr @bkb_count
@bkb_bit:
    rlca
@bkb_count:
    djnz @bkb_bit
    ret


; ----------------------------------------------------------------------------
;  bar_desc_state -- is a description up, and whose?
;  Out: L = the icon + 1, or 0 for none
;  Uses: AF, HL
;
;  Asked by ctx_classify every frame through bankn_call, which is why the
;  answer is in L and not A -- bankn_call needs A for the bank on the way
;  out. The four seconds are counted on sys_tick_50hz, so they are seconds
;  whatever the frame rate is doing; the tick is a byte and wraps at 256,
;  which 200 sits safely inside.
; ----------------------------------------------------------------------------
;  Out: L = bar_tick, the tick the frame last moved at. The tutorial's gate
;  compares it against the value it saw on its arming frame -- "the frame
;  moved" without a description's four-second window in the way.
bar_tick_get:
    ld a,(bar_tick)
    ld l,a
    ret

bar_desc_state:
    ld a,(bar_desc)
    or a
    jr z,@bds_none
    ld a,(sys_tick_50hz)
    ld hl,bar_tick
    sub (hl)
    cp BAR_DESC_TICKS
    jr c,@bds_live
    xor a
    ld (bar_desc),a                     ; spent
    ld (bar_hint),a                     ; ...and so is the hint, if it was that
@bds_none:
    ld l,0
    ret
@bds_live:
    ld a,(bar_hint)                     ; HUD_ICON_COUNT while the boot's hint is up...
    or a
    call z,bar_current_icon             ; ...else the button under the frame
    inc a
    ld l,a
    ret


; ----------------------------------------------------------------------------
;  bar_caption -- an icon's description, with its key in parentheses
;  In : E = the icon
;  Out: bank7_line holds the line, zero-terminated
;  Uses: everything
;
;  "Να φαίνεται η περιγραφή της λειτουργίας του επιλεγμένου button μαζί με
;  το πλήκτρο του σε παρένθεση." The description is the icon's entry in
;  hud_desc_text (gen/hudcaptions.asm, from tools/hudicons.py); the key's
;  name is a byte beside it -- a letter, or a code for ESC, SPACE, ENTER and
;  ARROWS, or nothing for a group. tools/hudicons.py holds every caption
;  inside the forty characters the line has, terminator included.
; ----------------------------------------------------------------------------
bar_caption:
    ld a,e
    cp HUD_ICON_COUNT
    jr nz,@bc_icon
    ;  THE HINT: "SHIFT+ARROWS TURN THE VIEW", which is the tutorial's first
    ;  line (game/screentext.asm, bank 7) and need not be written twice.
    ;  bankn_copy pages back to bank_home, which is this bank while the bar
    ;  runs, so the copy comes home. No key in parentheses: the line IS the key.
    ld hl,tut_text
    ld de,bank7_line
    ld bc,tut_text_1 - tut_text
    ld a,GA_BANK_7
    jp bankn_copy
@bc_icon:
    push de
    ld hl,hud_desc_text
    or a
    jr z,@bc_at
    ld b,a
@bc_skip:
    ld a,(hl)
    inc hl
    or a
    jr nz,@bc_skip
    djnz @bc_skip
@bc_at:
    ld de,bank7_line
@bc_copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    or a
    jr nz,@bc_copy
    dec de                              ; DE -> the terminator, to build on
    pop hl                              ; L = the icon
    ld h,0
    ld bc,hud_icon_name
    add hl,bc
    ld a,(hl)
    or a
    ret z                               ; no key: the description stands alone
    ld c,a
    ld a,' '
    ld (de),a
    inc de
    ld a,'('
    ld (de),a
    inc de
    ld a,c
    cp BAR_NAME_MAX + 1
    jr nc,@bc_char
    ;  A word: ESC, SPACE, ENTER or ARROWS, the (code - 1)th of bar_names
    dec a
    ld hl,bar_names
    or a
    jr z,@bc_word
    ld b,a
@bc_word_skip:
    ld a,(hl)
    inc hl
    or a
    jr nz,@bc_word_skip
    djnz @bc_word_skip
@bc_word:
    ld a,(hl)
    or a
    jr z,@bc_close
    ld (de),a
    inc hl
    inc de
    jr @bc_word
@bc_char:
    ld (de),a
    inc de
@bc_close:
    ld a,')'
    ld (de),a
    inc de
    xor a
    ld (de),a
    ret


; ----------------------------------------------------------------------------
;  bar_frame -- one frame of the row: repaint it if it has changed
;  Uses: everything
;
;  Called from ctx_bar at the end of every playing frame, after mis_wipe has
;  had its turn, which is why phase4_hud_dirty at ONE means "hud_draw has
;  just repainted this buffer over a wipe": the row was wiped with the rest
;  of the screen and comes back with the strips.
; ----------------------------------------------------------------------------
bar_frame:
    call bar_desc_line
    ;  The HUD is repainting: so is the row, and the first time -- the game's
    ;  first playing frame -- the boot's hint goes up on the description line:
    ;  "Οn start of the game there should be a hint: Use SHIFT+Arrows to
    ;  rotate view". bar_hint is HUD_ICON_COUNT out of the image and stays so
    ;  until the four seconds run out or the player touches the bar, so a help
    ;  page or a menu inside those seconds only restarts the clock. Asked
    ;  BEFORE the shadows: on that first frame they are the image's #FF/#FE
    ;  and the row is repainting for that reason too, and a check after them
    ;  was skipped on the one frame it existed for.
    ld a,(phase4_hud_dirty)
    dec a                               ; Z: it is 1
    jr nz,@bf_shadows
    ld a,(bar_hint)
    or a
    call nz,bar_show_keep
    jr @bf_changed
@bf_shadows:
    ld a,(bar_sel)
    ld hl,bar_sel_shadow
    cp (hl)
    jr nz,@bf_changed
    ld a,(bar_group)
    ld hl,bar_group_shadow
    cp (hl)
    jr z,@bf_paint
@bf_changed:
    ld a,(bar_sel)
    ld (bar_sel_shadow),a
    ld a,(bar_group)
    ld (bar_group_shadow),a
    ld a,2                              ; once into each buffer
    ld (bar_dirty),a
@bf_paint:
    ld hl,bar_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)

    ;  Blank the row: the icons do not overlap and the frame is drawn last,
    ;  so this is the whole erase.
    ld b,0
    ld c,HUD_BTN_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,HUD_BTN_H
    xor a
    call scr_fill_rect

    call bar_list
    ld c,BAR_X0
@bf_slot:
    push bc
    push hl
    ld a,(hl)
    ;  JUMP wears LAND on the last mission, where the key lands: the same
    ;  one-place decision mis_is_last makes, asked of mis_index here because
    ;  mis_is_last is bank 4 and this is not.
    cp ICON_JUMP
    jr nz,@bf_icon
    ld a,(mis_index)
    cp MIS_COUNT - 1
    ld a,ICON_JUMP
    jr nz,@bf_icon
    ld a,ICON_LAND
@bf_icon:
    ld b,c
    call bar_draw_icon
    pop hl
    pop bc
    inc hl
    ld a,c
    add a,BAR_PITCH
    ld c,a
    djnz @bf_slot
    jp bar_draw_frame                   ; (bar_desc_line sits between: no falling into it)

; ----------------------------------------------------------------------------
;  bar_desc_line -- the strip's third line: the selected button's caption
;  Uses: everything
;
;  Its own shadow: the icon plus one while a description is up, else 0. It
;  repaints on the two transitions and when hud_draw is repainting the
;  strips over a wipe, once into each buffer, like the row above it.
; ----------------------------------------------------------------------------
bar_desc_line:
    call bar_desc_state                 ; L = icon + 1, or 0
    ld a,l
    ld hl,bar_dline_shadow
    cp (hl)
    jr nz,@bdl_changed
    ld a,(phase4_hud_dirty)
    dec a                               ; Z: it is 1 -- the strips are repainting
    jr nz,@bdl_paint
    ld a,(hl)
@bdl_changed:
    ld (hl),a
    ld a,2
    ld (bar_dline_dirty),a
@bdl_paint:
    ld hl,bar_dline_dirty
    ld a,(hl)
    or a
    ret z
    dec (hl)
    ld b,0
    ld c,HUD_DESC_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,TXT_CHAR_H
    xor a
    call scr_fill_rect
    ld a,(bar_dline_shadow)
    or a
    ret z                               ; nothing up: the blank is the line
    dec a
    ld e,a
    call bar_caption
    ld hl,bank7_line
    ld b,0
    ld c,HUD_DESC_Y
    jp txt_draw


; ----------------------------------------------------------------------------
;  bar_draw_frame -- the blue frame round the selected button
;
;  The top and bottom lines are one-line fills; the sides are gfx_vline, one
;  pixel each, which clips at spr_clip_bottom -- and the row is BELOW it, so
;  the clip is opened for the two lines and put back.
; ----------------------------------------------------------------------------
bar_draw_frame:
    ld a,(bar_sel)
    ld b,a
    add a,a
    add a,a
    add a,b                             ; * BAR_PITCH
    add a,BAR_X0
    ld (bar_x),a
    ld c,HUD_BTN_Y
    call @bdf_hline
    ld c,HUD_BTN_Y + HUD_BTN_H - 1
    call @bdf_hline

    ld a,SCR_HEIGHT_PX
    ld (spr_clip_bottom),a
    ld a,(bar_x)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl                           ; the pixel column
    push hl
    call @bdf_vline
    pop hl
    ld de,HUD_ICON_W_BYTES * 4 - 1
    add hl,de
    call @bdf_vline
    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    ret
@bdf_hline:                             ; the frame's top or bottom, at row C
    ld a,(bar_x)
    ld b,a
    ld d,HUD_ICON_W_BYTES
    ld e,1
    ld a,SOLID_INK_2
    jp scr_fill_rect
@bdf_vline:                             ; ...and a side, at pixel column HL
    ld c,HUD_BTN_Y
    ld b,HUD_BTN_H
    ld a,PEN_BLUE
    jp gfx_vline


; ----------------------------------------------------------------------------
;  bar_draw_icon -- one icon out of bank 5 onto the row
;  In : A = the icon, B = its byte column
;  Uses: everything
;
;  Two halves of BAR_HALF bytes through bank7_line -- the one buffer outside
;  the window -- each half eight rows of HUD_ICON_W_BYTES. bankn_copy pages
;  bank 5 in and, with bank_home saying 6, this bank back; LDIR leaves HL
;  just past the half it copied, which is where the next one starts.
; ----------------------------------------------------------------------------
bar_draw_icon:
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                           ; * 8
    ld e,l
    ld d,h
    add hl,hl
    add hl,hl
    add hl,hl                           ; * 64...
    or a
    sbc hl,de                           ; ...- 8 = * HUD_ICON_BYTES (56: fourteen rows)
    ld de,hud_icons
    add hl,de                           ; the source, in bank 5
    ld a,b
    ld (bar_x),a
    ld c,HUD_BTN_Y + 1                  ; the cell's first row is the frame's margin
    call @bdi_half
    ;  ...and the second half: HL and C have moved on
@bdi_half:
    push bc
    ld de,bank7_line
    ld bc,BAR_HALF
    ld a,GA_BANK_5
    call bankn_copy
    pop bc
    push hl                             ; the source, for the second half
    ld hl,bank7_line
    ld b,BAR_HALF / HUD_ICON_W_BYTES    ; seven rows
@bdi_row:
    push bc
    push hl
    ld a,c
    call scr_line_addr                  ; HL = the row's start, AF/HL only
    ld a,(bar_x)
    ld c,a
    ld b,0
    add hl,bc
    ex de,hl                            ; DE = where on the screen
    pop hl                              ; HL = the row in bank7_line
    ld bc,HUD_ICON_W_BYTES
    ldir
    pop bc
    inc c
    djnz @bdi_row
    pop hl
    ret


; ============================================================================
;  The layout: sixteen slots, five groups
; ============================================================================
;  hud2.md section 3, as built. The groups are the LAST five slots, in the
;  order of their icons (ICON_GRP_COMBAT..ICON_GRP_SYSTEM), so a group's slot
;  is BAR_GROUP_SLOT0 + (icon - ICON_GRP_COMBAT) and bar_close can find its
;  way back without a table. Each group is a count and then its icons, BACK
;  first.
bar_top_icons:
    defb ICON_MOVE, ICON_BUILD, ICON_ATTACK, ICON_HARVEST, ICON_INFO
    defb ICON_FORMATION, ICON_STATION, ICON_GUARD, ICON_JUMP, ICON_PAUSE, ICON_MENU
    defb ICON_GRP_COMBAT, ICON_GRP_ECONOMY, ICON_GRP_SQUADRON, ICON_GRP_CAMERA, ICON_GRP_SYSTEM
bar_top_icons_end:

bar_group_ptrs:
    defw bar_grp_combat, bar_grp_economy, bar_grp_squadron, bar_grp_camera, bar_grp_system

bar_grp_combat:
    defb 5, ICON_BACK, ICON_STRAFE, ICON_FLY, ICON_TARGET_PREV, ICON_TARGET_NEXT
bar_grp_economy:
    defb 4, ICON_BACK, ICON_TOW, ICON_REPAIR, ICON_RECYCLE
bar_grp_squadron:
    defb 6, ICON_BACK, ICON_DIVIDE, ICON_COMBINE, ICON_SPLIT, ICON_SHIP_PREV, ICON_SHIP_NEXT
bar_grp_camera:
    defb 6, ICON_BACK, ICON_ZOOM_IN, ICON_ZOOM_OUT, ICON_PAN, ICON_CENTRE, ICON_SENSORS
bar_grp_system:
    defb 3, ICON_BACK, ICON_HELP, ICON_MUSIC

;  The key names that are not one letter, by hud_icon_name code 1..4.
bar_names:
    defb "ESC",0,"SPACE",0,"ENTER",0    ; (ARROWS, code 4, is the ORBIT icon's, which the bar does not offer)

;  The descriptions, the keys and the key names: generated from the sheet.
    include "gen/hudcaptions.asm"


; ============================================================================
;  State -- in bank 6 with the code, in the image, like the chase's
; ============================================================================
bar_sel:            defb 0              ; the frame's slot in the row showing
bar_group:          defb BAR_NONE       ; which group the row is, or none
bar_dirty:          defb 0
bar_sel_shadow:     defb #FF
bar_group_shadow:   defb #FE
bar_tick:           defb 0              ; sys_tick_50hz when the frame last moved
bar_desc:           defb 0              ; ...and whether a description is up
bar_dline_shadow:   defb #FF            ; what the third line says: icon + 1, or 0
bar_dline_dirty:    defb 0
bar_x:              defb 0              ; the byte column being drawn
bar_hint:           defb HUD_ICON_COUNT ; the boot's hint: armed by the image, spent once
