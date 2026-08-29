; ============================================================================
;  game/ctxbar.asm -- the context bar along the top of the screen
; ============================================================================
;  What keys do something RIGHT NOW, in one line above the tactical view.
;
;  WHY THIS EXISTS
;  ---------------
;  It is not decoration. A player who had been told the build panel is `B`,
;  then `,` and `.`, then ENTER, asked TWICE how to choose what to build. The
;  yard's entire readout was a three-letter tag in the corner of the bottom
;  strip -- no cost, no name of the class, and nothing at all to say that `,`
;  and `.` were live. Worse, those three keys mean one thing with the panel
;  open and another with it shut, and there was no way to see which.
;
;  So the build context is the one that matters and the one the layout is
;  built around: the class by NAME, what it costs, the keys that walk the
;  list, and -- when ENTER will not work -- why not.
;
;  WHY IT IS AFFORDABLE
;  --------------------
;  Two things, and they are the same two that make the HUD affordable.
;
;  Ships are clipped out of the strip: spr_clip_top is the mirror of
;  spr_clip_bottom and every drawing primitive in the game honours both, so
;  nothing can draw over the bar and the dirty-rectangle eraser cannot reach
;  into it. That means the bar only has to be repainted when the WORDS change,
;  which is once every few seconds at worst -- ctx_changed compares against a
;  shadow copy exactly the way phase4_hud_changed does, and sets the counter
;  to 2 because there are two screen buffers.
;
;  And it is bank-4 code. It runs once a frame, but only ever with the window
;  at rest -- never between class_tier_addr and class_blit_done -- so it is
;  bank code by the rule in game/shipclass.asm, and forty characters of text
;  in eight contexts is a few hundred bytes the low 16K does not have to find.
;
;  WHY THE FULL-SCREEN PAGES DO NOT GET ONE
;  ---------------------------------------
;  The title, the briefing, the help page and the orders menu each own the
;  whole screen and each already draws its own prompt, in the place the eye is
;  already looking -- "PRESS SPACE TO START", "ENTER", "ESC - BACK",
;  "UP/DOWN  ENTER  ESC" under the list it belongs to. A second copy at the top
;  would be the same words twice and the two would drift the first time one of
;  them grew a key.
;
;  So the bar is SUPPRESSED under all four, and nothing has to blank it: every
;  one of those pages starts by clearing from line 0, so the act of putting the
;  page up takes the bar down. Coming back is a context change like any other
;  and the shadow catches it.
;
;  THE KEYS ARE BLUE AND WHAT THEY DO IS WHITE
;  -------------------------------------------
;  A bar that is one colour has to be READ. Forty characters of white above a
;  battle is a paragraph, and the player wanted a glance: which keys are live
;  right now. So the key is ink 2 and its action ink 1 -- the same split the
;  HUD already makes between chrome and values, used here to say "this part is
;  something you press".
;
;  Which means a line can no longer be one string drawn by one txt_draw, and
;  the shape it takes instead is a RUN: zero-terminated words back to back,
;  ended by a second zero, drawn in turn with the pen alternating and x
;  advancing by the word just drawn plus one space. See ctx_run.
;
;  The alternative was a sentinel byte inside the string that switched the pen
;  mid-draw. It is a byte cheaper per colour change and it keeps the spacing
;  visible in the source -- and it was rejected for two reasons. It puts a
;  special case in txt_draw, which the briefing, the help page, the orders
;  menu, the title and both HUD strips all go through, to serve one caller.
;  And it breaks the only build-time check there is on this file: main.asm
;  asserts a line fits the screen by measuring the bytes it occupies, which
;  works because a run's terminators are exactly the spaces between its words
;  --  bytes == drawn characters + 2, always. Sentinels are bytes that draw
;  nothing, so the count would have had to be corrected by a hand-maintained
;  number of them, and a hand-maintained number is a comment rather than a
;  test.
; ----------------------------------------------------------------------------

;  Which context is up. Zero is "a full-screen page owns the screen".
CTX_NONE            equ 0
CTX_PLAYING         equ 1
CTX_PAUSED          equ 2
CTX_DISC            equ 3
CTX_BUILD           equ 4

;  How many characters fit on one line, which is the only real constraint on
;  the words below -- txt_draw clips at the screen edge rather than wrapping,
;  so an overrun is a silently truncated label.
CTX_BAR_CHARS       equ SCR_BYTES_PER_LINE / TXT_CHAR_W_BYTES

;  The build panel's fields, in BYTES across the line. The name is the widest
;  thing here and everything after it is placed off the longest one.
CTX_NAME_X          equ 0
CTX_NAME_CHARS      equ 11              ; "INTERCEPTOR"
CTX_COST_X          equ 24              ; three digits, right aligned
CTX_RU_X            equ 32
CTX_KEYS_X          equ 38
CTX_STAT_X          equ 56

;  ...and where the word PAUSED stops and the rest of the line starts.
CTX_PAUSE_TAIL_X    equ 16

;  Why the yard will not take an order. Encoded into ctx_sub beside the pick,
;  so the shadow notices the moment the answer flips -- and NOT the RU figure
;  itself, which moves every time a harvester comes home and would repaint the
;  bar forty times for one change of meaning.
CTX_BUY_OK          equ 0
CTX_BUY_POOR        equ 1
CTX_BUY_FULL        equ 2               ; ECO_QUEUE_MAX orders outstanding


; ----------------------------------------------------------------------------
;  ctx_bar -- one frame of the context bar
;  Uses: everything
;
;  The shape is phase4_hud's, deliberately: work out whether anything changed,
;  and if it did paint the strip into this buffer and the next one.
; ----------------------------------------------------------------------------
ctx_bar:
    call ctx_changed
    ld hl,ctx_dirty
    ld a,(hl)
    or a
    ret z
    ld a,(ctx_key)
    or a
    ret z                               ; a full-screen page owns the strip
    dec (hl)

    ;  Blank it first. The bar is the only thing that ever writes here, so
    ;  this is the whole erase -- there is no dirty rectangle to record and
    ;  nothing else to co-ordinate with.
    ld bc,#0000                         ; B = x, C = y
    ld d,SCR_BYTES_PER_LINE
    ld e,CTX_BAR_H
    xor a
    call scr_fill_rect

    ld a,(ctx_key)
    cp CTX_BUILD
    jp z,ctx_draw_build
    cp CTX_DISC
    ld hl,ctx_text_disc
    jr z,ctx_line
    cp CTX_PAUSED
    jr z,ctx_draw_paused
    ld hl,ctx_text_play
    ;  ...and fall through

;  HL -> a whole line of the bar, from the left-hand edge.
ctx_line:
    ld b,CTX_NAME_X
    ;  ...and fall through


; ----------------------------------------------------------------------------
;  ctx_run -- draw a run of words, keys in ink 2 and what they do in ink 1
;  In : HL -> the run, B = x in bytes
;  Uses: everything
;
;  A run is zero-terminated words back to back, ended by a second zero. Each
;  one is drawn in the pen the last one was not, starting blue, and x steps on
;  by the word plus one space -- so a terminator IS the space that follows the
;  word it ends, which is what makes main.asm's width assert exact.
;
;  A run may end on a blue word: a key with no action beside it is legal and
;  the move disc's trailing ESC is one. What is not expressible is two blue
;  words running, and that is deliberate -- it is the same rule as "every key
;  in this bar says what it does", stated where the build would catch it.
;
;  The pen lives in memory rather than a register because txt_draw uses
;  everything and B and C are already spoken for by x and y. XOR 3 flips 1 and
;  2 into each other, which is the whole of the alternation.
; ----------------------------------------------------------------------------
ctx_run:
    ld a,PEN_BLUE
    ld (ctx_pen),a
    ld c,CTX_Y                          ; survives, in the push bc below

@ctx_word:
    ld a,(hl)
    or a
    jr z,@ctx_run_done                  ; the second zero: the run is over

    push hl
    push bc                             ; txt_set_pen clobbers B
    ld a,(ctx_pen)
    call txt_set_pen
    pop bc
    pop hl

    push hl
    push bc
    call txt_draw
    pop bc
    pop hl

@ctx_advance:
    inc hl
    inc b
    inc b                               ; TXT_CHAR_W_BYTES
    ld a,(hl)
    or a
    jr nz,@ctx_advance
    inc hl                              ; past the terminator...
    inc b
    inc b                               ; ...and over the space it stands for

    ld a,(ctx_pen)
    xor PEN_WHITE ^ PEN_BLUE            ; 1 <-> 2
    ld (ctx_pen),a
    jr @ctx_word

@ctx_run_done:
    ld a,PEN_WHITE                      ; nothing inherits an ink
    jp txt_set_pen


; ----------------------------------------------------------------------------
;  ctx_draw_paused -- item 1 of the todo list, which belongs here
;
;  SPACE freezes the battle and nothing on screen said so, and a paused fleet
;  does not look paused -- it looks broken, because it simply stops obeying.
;  Ink 3: section 2 reserves it for the thing that wants attention, and a
;  state the player chose and then forgot they were in is exactly that.
;
;  PAUSED stays ink 3 now that the rest of the bar has two inks, and it is the
;  one word here that is neither a key nor an action -- it is the STATE, and
;  the ink is what says so. Its tail is an ordinary run.
;  Uses: everything
; ----------------------------------------------------------------------------
ctx_draw_paused:
    ld a,PEN_RED
    call txt_set_pen
    ld hl,ctx_text_paused
    ld b,CTX_NAME_X
    ld c,CTX_Y
    call txt_draw                       ; ctx_run puts the pen back

    ld hl,ctx_text_pause_tail
    ld b,CTX_PAUSE_TAIL_X
    jr ctx_run


; ----------------------------------------------------------------------------
;  ctx_draw_build -- the one this file exists for
;
;      SCOUT                     25 RU   , . PICK      ENTER BUY
;      DESTROYER                250 RU   , . PICK      NEED MORE RU
;
;  The name and the cost are WHITE, and that is a decision rather than the
;  default. They are not keys -- they are what the player is choosing between
;  and the two things that change when `,` or `.` is pressed -- so they are
;  values in the sense the HUD already uses, and blue would have made the name
;  of a ship read as something to press, which is the exact confusion this bar
;  was built to end. RU stays ink 2 because it is a unit caption, which is
;  chrome; and ", ." is a key, so it is blue like every other key on the line.
;  Uses: everything
; ----------------------------------------------------------------------------
ctx_draw_build:
    call ctx_build_state
    ld (ctx_state),a

    ld a,(ctx_class)
    call ctx_class_name
    ld b,CTX_NAME_X
    ld c,CTX_Y
    call txt_draw

    ld a,(ctx_cost)
    ld b,CTX_COST_X
    ld c,CTX_Y
    ld d,3
    call txt_draw_num
    ld hl,ctx_text_ru
    ld b,CTX_RU_X
    ld c,CTX_Y
    call phase4_hud_label               ; chrome is ink 2, and puts it back

    ld hl,ctx_text_pick
    ld b,CTX_KEYS_X
    call ctx_run

    ;  What ENTER will do, or why it will do nothing. "ENTER BUY" is in ink 3
    ;  for the same reason JUMP is in the HUD: it is the one key on the screen
    ;  that is asking to be pressed. It stays ink 3 in BOTH its words rather
    ;  than becoming a blue key and a white action, because the blue/white
    ;  split says "here is a key" and this one is saying something else --
    ;  press THIS one, now. Split it and it would look like the other four.
    ;  The refusals stay white -- they are the answer to a question the player
    ;  asked, not an alarm.
    ld a,(ctx_state)
    or a
    jr nz,@ctx_build_refuse
    ld a,PEN_RED
    call txt_set_pen
    ld hl,ctx_text_buy
    ld b,CTX_STAT_X
    ld c,CTX_Y
    call txt_draw
    ld a,PEN_WHITE
    jp txt_set_pen

@ctx_build_refuse:
    cp CTX_BUY_POOR
    ld hl,ctx_text_poor
    jr z,@ctx_build_say
    ld hl,ctx_text_full
@ctx_build_say:
    ld b,CTX_STAT_X
    ld c,CTX_Y
    jp txt_draw


; ----------------------------------------------------------------------------
;  ctx_class_name -- HL -> the full name of class A
;  Uses: AF, B, HL
;
;  Walked rather than indexed: eight zero-terminated names back to back are
;  71 bytes and the same eight at a fixed stride are 96, and this runs when
;  the panel is opened or stepped, not per entity. mis_next_line is the
;  briefing's walker, doing exactly this job one file over.
; ----------------------------------------------------------------------------
ctx_class_name:
    ld hl,class_name
    ;  ...and fall through.


; ----------------------------------------------------------------------------
;  str_index -- HL -> the Ath of a run of zero-terminated strings
;  In : HL -> the first string, A = which one
;  Out: HL -> that one
;  Uses: AF, B, HL
;
;  Split out of ctx_class_name for game/squadinfo.asm's formation names, and
;  it cost NOTHING: the fall-through means bank 4 holds one copy of the loop
;  and one `ld hl` in front of it, which is what it held before. The third
;  caller is the one that would have paid for it.
; ----------------------------------------------------------------------------
str_index:
    or a
    ret z
    ld b,a
@ctx_name_skip:
    call mis_next_line
    djnz @ctx_name_skip
    ret


; ----------------------------------------------------------------------------
;  ctx_build_state -- what the yard would say to an ENTER right now
;  Out: A = CTX_BUY_OK / CTX_BUY_POOR / CTX_BUY_BUSY
;       (ctx_class) = the class on offer, (ctx_cost) = what it costs
;  Uses: everything
;
;  These are eco_queue's own three refusals, in eco_queue's own order. They
;  are re-derived rather than read out of a flag because eco_queue does not
;  leave one -- and a second copy of the decision that only ran when the
;  player pressed ENTER would be a bar that says BUY to a yard that says no.
;  If eco_queue grows a fourth condition it grows here too.
; ----------------------------------------------------------------------------
ctx_build_state:
    ld a,(eco_build_pick)
    ld l,a
    ld h,0
    ld de,eco_build_order
    add hl,de
    ld a,(hl)
    ld (ctx_class),a
    ld l,a
    ld h,0
    ld de,eco_class_cost
    add hl,de
    ld a,(hl)
    ld (ctx_cost),a
    ld c,a
    ld b,0

    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,@ctx_yard_free                ; slipway empty: there is always room
    ld a,(eco_queue_len)
    cp ECO_QUEUE_WAIT
    jr c,@ctx_yard_free
    ld a,CTX_BUY_FULL                   ; ECO_QUEUE_MAX orders outstanding
    ret
@ctx_yard_free:
    ld hl,(eco_ru)
    or a
    sbc hl,bc
    ld a,CTX_BUY_POOR
    ret c
    xor a                               ; CTX_BUY_OK
    ret


; ----------------------------------------------------------------------------
;  ctx_changed -- has the context, or anything the bar says about it, moved?
;  Uses: everything
;
;  Two bytes of shadow, not one. ctx_key is which context; ctx_sub is what
;  distinguishes two frames of the SAME context that need different words --
;  today that is only the build panel, where it carries the pick and the
;  yard's answer.
;
;  Nothing else has to remember to flag the bar dirty, including everything
;  that schedules a mis_wipe: a full-screen page going up or coming down IS a
;  change of context, so the comparison below has already caught it by the
;  time the wipe runs.
; ----------------------------------------------------------------------------
ctx_changed:
    call ctx_classify
    ld a,(ctx_key)
    ld hl,ctx_key_shadow
    cp (hl)
    jr nz,@ctx_diff
    ld a,(ctx_sub)
    ld hl,ctx_sub_shadow
    cp (hl)
    ret z
@ctx_diff:
    ld a,(ctx_key)
    ld (ctx_key_shadow),a
    ld a,(ctx_sub)
    ld (ctx_sub_shadow),a
    ld a,2                              ; once into each screen buffer
    ld (ctx_dirty),a
    ret


; ----------------------------------------------------------------------------
;  ctx_classify -- fill in (ctx_key) and (ctx_sub) from the game's own flags
;  Uses: everything
;
;  The order is the order demo_update and phase4_commands read them in, and it
;  has to be: ESC means "cancel" while the disc or the panel is open and
;  "orders menu" otherwise, so a bar that named the menu while the disc was up
;  would be lying about the key the player is most likely to press.
; ----------------------------------------------------------------------------
ctx_classify:
    xor a
    ld (ctx_sub),a

    ld a,(title_shown)
    ld hl,mis_briefing
    or (hl)
    ld hl,help_shown
    or (hl)
    ld hl,info_shown
    or (hl)
    ld hl,menu_shown
    or (hl)
    jr z,@ctx_not_static
    xor a                               ; CTX_NONE
    ld (ctx_key),a
    ret

@ctx_not_static:
    ld a,(disc_active)
    or a
    ld a,CTX_DISC
    jr nz,@ctx_set

    ld a,(eco_build_open)
    or a
    jr z,@ctx_no_build
    call ctx_build_state
    ld c,a
    ld a,(eco_build_pick)
    add a,a
    add a,a
    add a,c                             ; (pick << 2) | why-not
    ld (ctx_sub),a
    ld a,CTX_BUILD
    jr @ctx_set

@ctx_no_build:
    ld a,(order_paused)
    or a
    ld a,CTX_PLAYING
    jr z,@ctx_set
    ld a,CTX_PAUSED
@ctx_set:
    ld (ctx_key),a
    ret


; ============================================================================
;  The words
; ============================================================================
;  Every line has to fit CTX_BAR_CHARS, and there are asserts below for it
;  because nothing at run time would catch an overrun -- txt_draw stops at the
;  right-hand edge and says nothing. A run occupies exactly two bytes more
;  than it draws characters, so the asserts measure bytes and mean characters.
; ----------------------------------------------------------------------------
;  The words alternate key, action, key, action, starting with a key. Single
;  spaces throughout: the double spaces that used to group the pairs are what
;  the two inks do now, and paying for the grouping twice costs screen width
;  that the move disc's line does not have.
;
;  ", ." keeps its inner space, and that space is doing work -- the comma and
;  the full stop are one pixel apart in this font, so ",." reads as ".." at
;  8x8, and the pair is the whole reason the bar exists.
ctx_text_play:
    defb "ESC",0,"MENU",0
    defb "ENTER",0,"MOVE",0
    defb "B",0,"BUILD",0
    defb ", .",0,"TARGET",0
    defb 0
ctx_text_play_end:

ctx_text_paused:
    defb "PAUSED",0
ctx_text_pause_tail:
    defb "SPACE",0,"RESUME",0
    defb "ESC",0,"MENU",0
    defb 0
ctx_text_pause_end:

;  SHIFT and the arrows raise and lower the disc rather than sliding it, which
;  the old line said as "SHIFT UP/DN" -- eleven characters naming a key with
;  nothing beside it saying what it was for. HEIGHT is what it is for, and the
;  arrows are already named two words to its left.
;
;  ESC ends the run on a key with no action, which is legal and is the only
;  place in the bar that uses it: "cancel" and "menu" and "back" would all
;  have been the wrong word, because ESC here puts the disc away without
;  moving anything and the player has just been told ENTER is OK.
ctx_text_disc:
    defb "ARROWS",0,"MOVE",0
    defb "SHIFT",0,"HEIGHT",0
    defb "ENTER",0,"OK",0
    defb "ESC",0
    defb 0
ctx_text_disc_end:

ctx_text_ru:
    defb "RU",0
ctx_text_pick:
    defb ", .",0,"PICK",0
    defb 0
ctx_text_pick_end:
ctx_text_buy:
    defb "ENTER BUY",0
ctx_text_poor:
    defb "NEED MORE RU",0
;  It used to say YARD BUSY, which was true of a yard that took one order at a
;  time and is a lie about one that takes ten: BUSY invites the player to wait,
;  and what they should do is press ENTER again. FULL says the one thing that
;  is still refused.
ctx_text_full:
    defb "QUEUE FULL",0
ctx_text_end:


; ============================================================================
;  State
; ============================================================================
;  All of it in bank 4 with the code, because nothing in the low 16K reads it.
;  The one piece that had to stay down there is spr_clip_top, in gfx/sprite.asm
;  where the blitter can reach it without a thought.
;
;  The shadows start at #FF so the first frame is always a change: demo_init
;  has nothing to initialise here.
ctx_key:            defb CTX_NONE
ctx_sub:            defb 0
ctx_key_shadow:     defb #FF
ctx_sub_shadow:     defb #FF
ctx_dirty:          defb 0

ctx_class:          defb 0
ctx_cost:           defb 0
ctx_state:          defb 0
ctx_pen:            defb PEN_BLUE       ; which ink ctx_run's next word gets
