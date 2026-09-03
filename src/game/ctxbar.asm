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
CTX_RECYCLE         equ 5               ; `Y` is armed and asking again
CTX_JUMPING         equ 6               ; the drive is spooling, ESC calls it off
CTX_TUTORIAL        equ 7               ; ...and in the tutorial ESC leaves it

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

;  ...and the same for RECYCLE?, which is two characters longer.
CTX_RECYCLE_TAIL_X  equ 20
;  "JUMPING nn" is ten characters at CTX_NAME_X, so the tail starts one clear
;  cell after it. src/main.asm asserts the whole line against CTX_BAR_CHARS.
CTX_JUMP_NUM_X      equ CTX_NAME_X + 8 * TXT_CHAR_W_BYTES
CTX_JUMP_TAIL_X     equ CTX_NAME_X + 11 * TXT_CHAR_W_BYTES

;  Why the yard will not take an order. Encoded into ctx_sub beside the pick,
;  so the shadow notices the moment the answer flips -- and NOT the RU figure
;  itself, which moves every time a harvester comes home and would repaint the
;  bar forty times for one change of meaning.
;
;  Four values and two bits, which is what ctx_sub has room for beside a pick
;  of 0..CLASS_BUILDABLE-1. A fifth answer needs a third bit and the shift in
;  ctx_classify to match.
CTX_BUY_OK          equ 0
CTX_BUY_POOR        equ 1
CTX_BUY_FULL        equ 2               ; ECO_QUEUE_MAX orders outstanding
CTX_BUY_FLEET       equ 3               ; the fleet's own slots are all spoken for


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
    jp z,ctx_draw_paused
    cp CTX_RECYCLE
    jr z,ctx_draw_recycle
    cp CTX_JUMPING
    jr z,ctx_draw_jumping
    cp CTX_TUTORIAL
    ld hl,ctx_text_tutorial
    jp z,ctx_line
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
;  ----------------------------------------------------------------------------
;  ctx_draw_recycle -- `Y` is armed and wants to be told again
;
;  RECYCLE? in ink 3 for the reason PAUSED has it and ENTER BUY has it: section
;  2 gives ink 3 to the thing that wants attention, and a question that is
;  about to break ships up for scrap is the only thing on the screen. Without
;  this line the first `Y` does nothing a player can see, and a key that does
;  nothing visible is a key that is broken -- which is the exact failure this
;  whole file was built to end.
; ----------------------------------------------------------------------------
ctx_draw_recycle:
    ld a,PEN_RED
    call txt_set_pen
    ld hl,ctx_text_recycle
    ld b,CTX_NAME_X
    ld c,CTX_Y
    call txt_draw                       ; ctx_run puts the pen back

    ld hl,ctx_text_recycle_tail
    ld b,CTX_RECYCLE_TAIL_X
    jr ctx_run


;  The drive spooling. PAUSED's shape exactly, because it is the same kind of
;  thing: a STATE and not a key, in section 2's attention ink -- and this one
;  has a number in it that moves every second, which is why ctx_changed folds
;  jump_secs into its shadow. The HUD's JUMP label says the jump is AVAILABLE;
;  this says it is HAPPENING, and both statements are wanted.
ctx_draw_jumping:
    ld a,PEN_RED
    call txt_set_pen
    ;  JUMPING, or LANDING on the last mission -- the same one-place decision
    ;  mis_leave_word already makes for the HUD's word, asked of the same
    ;  routine, so the two strips cannot come to disagree about what the key is
    ;  about to do. A bar that said JUMPING under a HUD that said LAND would be
    ;  the exact lie this file exists to prevent.
    call mis_is_last
    ld hl,ctx_text_jumping
    jr nc,@ctx_jump_word
    ld hl,ctx_text_landing
@ctx_jump_word:
    ld b,CTX_NAME_X
    ld c,CTX_Y
    call txt_draw

    ld a,(jump_secs)
    ld b,CTX_JUMP_NUM_X
    ld c,CTX_Y
    ld d,2                              ; right-aligned, so ESC does not jitter
    call txt_draw_num
    ld a,PEN_WHITE
    call txt_set_pen

    ld hl,ctx_text_jump_tail
    ld b,CTX_JUMP_TAIL_X
    jr ctx_run


ctx_draw_paused:
    ld a,PEN_RED
    call txt_set_pen
    ld hl,ctx_text_paused
    ld b,CTX_NAME_X
    ld c,CTX_Y
    call txt_draw                       ; ctx_run puts the pen back

    ld hl,ctx_text_pause_tail
    ld b,CTX_PAUSE_TAIL_X
    jp ctx_run


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
    cp CTX_BUY_FULL
    ld hl,ctx_text_full
    jr z,@ctx_build_say
    ld hl,ctx_text_fleet
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
;  Out: A = CTX_BUY_OK / CTX_BUY_POOR / CTX_BUY_FULL / CTX_BUY_FLEET
;       (ctx_class) = the class on offer, (ctx_cost) = what it costs
;  Uses: everything
;
;  These are eco_queue's own refusals, in eco_queue's own order. They are
;  re-derived rather than read out of a flag because eco_queue does not leave
;  one -- and a second copy of the decision that only ran when the player
;  pressed ENTER would be a bar that says BUY to a yard that says no. If
;  eco_queue grows another condition it grows here too.
;
;  It walks the fleet's twenty-eight slots now, which is about 1,500 T-states
;  -- but only on the frames the build panel is OPEN, since ctx_classify does
;  not come this way otherwise. Nothing in the ordinary frame pays for it.
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

    ld a,(eco_build_class)
    cp CLASS_COUNT
    jr nc,@ctx_yard_free                ; slipway empty: there is always room
    ld a,(eco_queue_len)
    cp ECO_QUEUE_WAIT
    jr c,@ctx_yard_free
    ld a,CTX_BUY_FULL                   ; ECO_QUEUE_MAX orders outstanding
    ret

;  Room in the FLEET, which is eco_queue's second refusal and is measured the
;  same way: against everything outstanding, because every one of those is a
;  slot that has been paid for and not yet filled.
@ctx_yard_free:
    call ent_room_ours
    ld c,a
    ld a,(eco_build_class)
    cp CLASS_COUNT
    ld a,(eco_queue_len)
    jr nc,@ctx_want
    inc a
@ctx_want:
    inc a
    ld b,a
    ld a,c
    cp b
    ld a,CTX_BUY_FLEET
    ret c

;  The cost is reloaded rather than carried down here in BC from the top,
;  because ent_room_ours clobbers both halves of it.
    ld a,(ctx_cost)
    ld c,a
    ld b,0
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
    ld hl,mis_failed                    ; ...and the game-over screen, which
    or (hl)                             ; has no flag but this one
    jr z,@ctx_not_static
    xor a                               ; CTX_NONE
    ld (ctx_key),a
    ret

@ctx_not_static:
    ;  THE TUTORIAL FIRST, because the one key it changes is the one every
    ;  other line on this bar names. ESC opens the orders menu everywhere else
    ;  and LEAVES here, and a bar that went on saying MENU would be lying
    ;  about the key the player is most likely to press -- which is the exact
    ;  thing this file was written to stop. Below the disc and the panel, so
    ;  that ESC still reads as "cancel this" while either is open, and the
    ;  tutorial teaches ESC for the yard at step 12.
    ld a,(tut_active)
    or a
    jr z,@ctx_not_tutorial
    ld a,(disc_active)
    ld hl,eco_build_open
    or (hl)
    jr nz,@ctx_not_tutorial
    ld a,CTX_TUTORIAL
    jr @ctx_set
@ctx_not_tutorial:

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
    ;  ...and the armed RECYCLE, which outranks both PLAYING and PAUSED: it is
    ;  a question the player has to answer and the other two are states.
    ld a,(eco_recycle_armed)
    or a
    ld a,CTX_RECYCLE
    jr nz,@ctx_set

    ;  ...and a jump spooling, which outranks PLAYING for the same reason and
    ;  is BELOW the disc, the panel and the armed RECYCLE, because ESC means
    ;  "cancel the innermost thing" and the bar has to name the key the player
    ;  is most likely to press. Same order as the chain in phase4_commands.
    ld a,(jump_secs)
    or a
    jr z,@ctx_no_jump
    ;  THE SECONDS GO IN ctx_sub, which is what makes the number on the bar
    ;  cost nothing: the shadow already compares that byte, so the repaint
    ;  happens on the tick and only on the tick. Without it the bar would draw
    ;  10 and then sit there saying 10 for ten seconds.
    ld (ctx_sub),a
    ld a,CTX_JUMPING
    jr @ctx_set
@ctx_no_jump:

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

;  "JUMPING" and then the seconds, drawn separately because a number cannot be
;  a run. The tail is a run like every other, so ESC is blue and CANCEL white.
;  The tutorial's line. ESC is the only key on it that means something
;  different from everywhere else, and it is first for that reason.
ctx_text_tutorial:
    defb "ESC",0,"LEAVE",0
    defb "SPACE",0,"PAUSE",0
    defb "?",0,"KEYS",0
    defb 0
ctx_text_tutorial_end:

ctx_text_jumping:
    defb "JUMPING",0
ctx_text_jumping_end:
;  The last mission's word for the same spool. Asserted the same length as
;  JUMPING in src/main.asm, because the seconds are drawn at a fixed x after it
;  -- a longer word would have its tail overwritten by the number.
ctx_text_landing:
    defb "LANDING",0
ctx_text_landing_end:
ctx_text_jump_tail:
    defb "ESC",0,"CANCEL",0
    defb 0
ctx_text_jump_tail_end:

ctx_text_paused:
    defb "PAUSED",0
ctx_text_pause_tail:
    defb "SPACE",0,"RESUME",0
    defb "ESC",0,"MENU",0
    defb 0
ctx_text_pause_end:

ctx_text_recycle:
    defb "RECYCLE?",0
ctx_text_recycle_tail:
    defb "Y",0,"CONFIRM",0
    defb "ESC",0,"CANCEL",0
    defb 0
ctx_text_recycle_end:

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
;  The other ceiling, and the reason it needs a word of its own: QUEUE FULL is
;  "wait, then press ENTER again" and this one is "there is nowhere for another
;  ship to be". Saying the first about the second would have the player waiting
;  for a slipway that is already empty. game/entity.asm has the partition.
ctx_text_fleet:
    defb "FLEET FULL",0
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
