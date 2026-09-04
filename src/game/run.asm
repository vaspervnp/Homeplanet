; ============================================================================
;  run.asm -- THE RUN: one interceptor clears the lane, left to right
; ============================================================================
;  minigame2.md, built small (its section 7): flights of three Vekhar
;  interceptors come in from the right on sine paths and fire back; you fly up
;  and down and fire; three hits and you are down. It ends on the clock. Win
;  and the kills are salvage; lose and it is the ambush, softened by what you
;  killed first. No destroyer yet -- that is what the next room in this bank
;  is for.
;
;  IN BANK 7 AND RUNNING FROM IT, on the jumps the chase does not take, and
;  it is mostly the chase: mini_blit draws both ships (the interceptor is in
;  this bank), mini_clear/mini_blank/mini_wait/mini_show/mini_hold pace and
;  page it, mini_page_at and mini_intro_wait put its page up, mini_hit_marks
;  draws the hits out of mini_hits, mini_penalty takes the toll, mini_nth
;  finds its words. Everything it calls is in this bank or the low 16K, and
;  nothing here pages: the rule game/minigame.asm's head states.
;
;  GEOMETRY IN UNITS OF TWO PIXELS across, so an x is a byte: 0..159 covers
;  the 320. The lane is the chase's body band, MG_BODY_Y..+MG_BODY_H, and
;  everything drawn is clipped to it by spr_blit and gfx_vline.
; ----------------------------------------------------------------------------

RUN_STEPS           equ 150             ; * MG_STEP_TICKS (7) = 21 s
RUN_UX              equ 24              ; our x, in units: 48 px in
RUN_Y0              equ MG_CY           ; where we start, in lines
RUN_YMIN            equ MG_BODY_Y + 10
RUN_YMAX            equ MG_BODY_Y + MG_BODY_H - 14
RUN_DY              equ 4               ; lines a step, up or down
RUN_VIEW            equ 1               ; the three-quarter that points right
RUN_TIER            equ 2               ; tier C, 24x16: B read as specks
RUN_ENEMY_VIEW      equ 4               ; ...and the one that points left
RUN_ENEMY_MAX       equ 4
RUN_FLIGHT          equ 3               ; how many arrive together
RUN_ENEMY_DX        equ 3               ; units a step: six pixels
RUN_ENEMY_AMP       equ 20              ; lines, either side of its y0
RUN_ENEMY_SPIN      equ 6               ; angle a step, in 256ths of a turn
RUN_ENEMY_X0        equ 158             ; units: just off the right edge
RUN_ENEMY_GAP       equ 14              ; units between ships of a flight
RUN_FIRE_P          equ 12              ; of 256, a step, per enemy on screen
RUN_SHOT_MAX        equ 3
RUN_SHOT_DX         equ 8               ; units a step: sixteen pixels
RUN_ESHOT_DX        equ 6
RUN_HIT_UX          equ 7               ; a shot inside this many units...
RUN_HIT_Y           equ 9               ; ...and lines of a centre is a hit
RUN_HITS_MAX        equ MG_HITS_MAX     ; three, like the chase
RUN_STARS           equ 24
RUN_STAR_SEED       equ #4D2B
RUN_STAR_X0         equ 32
RUN_SALVAGE         equ 35              ; RU a kill: eco_class_cost's interceptor
RUN_TOLL_PER_KILL   equ 8               ; ...and how much each softens a loss

;  The words, and their columns. Centred by hand: (80 - n * 2) / 2.
RUN_MSG_RUN         equ 0
RUN_MSG_WON         equ 1
RUN_MSG_LOST        equ 2
RUN_MSG_SALVAGE     equ 3
RUN_MSG_TOLL        equ 4
RUN_RUN_X           equ 11
RUN_WON_X           equ 22
RUN_LOST_X          equ 2
RUN_SALVAGE_X       equ 22
RUN_SALVAGE_NUM_X   equ RUN_SALVAGE_X + 22
RUN_INTRO_1_X       equ 7
RUN_INTRO_2_X       equ 5
RUN_INTRO_3_X       equ 11
RUN_INTRO_4_X       equ 13
RUN_INTRO_LINES     equ 4

    assert RUN_YMIN < RUN_Y0 && RUN_Y0 < RUN_YMAX, "the run's ship does not start inside its lane"
    assert RUN_ENEMY_X0 + (RUN_FLIGHT - 1) * RUN_ENEMY_GAP <= 255, "a flight's last ship is past a byte"

; ----------------------------------------------------------------------------
;  run_main -- the run, from a black screen to a black screen
;  Uses: everything
; ----------------------------------------------------------------------------
run_main:
    ld a,1
    ld (run_active),a
    ld a,RUN_STEPS
    ld (run_left),a
    ld a,RUN_Y0
    ld (run_y),a
    xor a
    ld (run_scroll),a
    ld (run_kills),a
    ld (mini_hits),a
    ld (mini_lost),a
    ld (run_msg),a
    ld hl,run_enemies
    ld b,RUN_ENEMY_MAX * 4 + RUN_SHOT_MAX * 2 + RUN_ENEMY_MAX * 2
@run_wipe:
    ld (hl),a                           ; every enemy dead, every shot free
    inc hl
    djnz @run_wipe
    ld a,MG_BODY_Y
    ld (spr_clip_top),a
    ld a,MG_BODY_Y + MG_BODY_H
    ld (spr_clip_bottom),a
    ld a,RUN_TIER
    ld (mini_cls),a                     ; CLASS_INTERCEPTOR is 0: set below per blit
    xor a
    ld (mini_cls),a
    ld a,(sys_tick_50hz)
    ld (mini_t0),a

    call run_intro
    call mini_blank
    call run_say
    call mini_show
    call mini_blank
    call run_say
    call mini_show

@run_step:
    call key_consume                    ; SPACE is an edge; see mini_intro
    ld hl,run_scroll
    inc (hl)
    call run_steer
    call run_fire
    call run_shots_step
    call run_enemies_step
    call run_eshots_step
    call run_spawn
    call run_draw
    call mini_wait
    ld a,(mini_hits)
    cp RUN_HITS_MAX
    jr nc,@run_down
    ld hl,run_left
    dec (hl)
    jr nz,@run_step

    ;  The clock: the lane is clear, and the kills are salvage.
    ld a,(run_kills)
    ld h,a
    ld l,RUN_SALVAGE
    call mul_u8                         ; HL = kills * 35
    ld de,(eco_ru)
    add hl,de
    ld de,ECO_RU_MAX
    or a
    sbc hl,de
    add hl,de
    jr c,@run_paid
    ld hl,ECO_RU_MAX
@run_paid:
    ld (eco_ru),hl
    call snd_explosion
    ld a,RUN_MSG_WON
    jr @run_over

@run_down:
    ;  Shot down: the ambush, sized on what got past you -- MG_DIST0 is the
    ;  whole toll and every kill takes RUN_TOLL_PER_KILL off it.
    ld a,(run_kills)
    ld b,a
    ld a,MG_DIST0
    inc b
@run_soften:
    dec b
    jr z,@run_tolled
    sub RUN_TOLL_PER_KILL
    jr nc,@run_soften
    xor a
@run_tolled:
    ld (mini_dist),a
    call mini_penalty
    call snd_hit
    ld a,RUN_MSG_LOST

@run_over:
    ld (run_msg),a
    call run_draw
    call run_say
    call mini_show
    call run_draw
    call run_say
    call mini_show
    ld a,MG_HOLD
    call mini_hold
    ld a,2
    ld (run_left),a
@run_dark:
    call mini_blank
    call mini_show
    ld hl,run_left
    dec (hl)
    jr nz,@run_dark

    ld a,CTX_BAR_H
    ld (spr_clip_top),a
    ld a,HUD_TOP
    ld (spr_clip_bottom),a
    xor a
    ld (run_active),a
    ret


; ----------------------------------------------------------------------------
;  run_intro -- the page, the first time in a campaign
; ----------------------------------------------------------------------------
run_intro:
    ld hl,run_shown
    ld a,(hl)
    or a
    ret nz
    ld (hl),1
    call key_consume
    call mini_blank
    call run_intro_page
    call mini_show
    call mini_blank
    call run_intro_page
    call mini_show
    jp mini_intro_wait

run_intro_page:
    ld hl,run_intro_words
    ld de,run_intro_xy
    ld a,RUN_INTRO_LINES
    jp mini_page_at

run_intro_xy:
    defb RUN_INTRO_1_X, MG_INTRO_Y
    defb RUN_INTRO_2_X, MG_INTRO_Y + MG_INTRO_STEP
    defb RUN_INTRO_3_X, MG_INTRO_Y + 2 * MG_INTRO_STEP
    defb RUN_INTRO_4_X, MG_INTRO_Y + 3 * MG_INTRO_STEP


; ----------------------------------------------------------------------------
;  run_steer -- UP and DOWN move us; key_down, because steering is not an edge
; ----------------------------------------------------------------------------
run_steer:
    ld a,KEY_CUR_UP
    call key_down
    jr nc,@run_not_up
    ld a,(run_y)
    sub RUN_DY
    cp RUN_YMIN
    jr nc,@run_steered
    ld a,RUN_YMIN
    jr @run_steered
@run_not_up:
    ld a,KEY_CUR_DOWN
    call key_down
    ret nc
    ld a,(run_y)
    add a,RUN_DY
    cp RUN_YMAX + 1
    jr c,@run_steered
    ld a,RUN_YMAX
@run_steered:
    ld (run_y),a
    ret


; ----------------------------------------------------------------------------
;  run_fire -- SPACE, on the edge: one shot from the nose, if a slot is free
; ----------------------------------------------------------------------------
run_fire:
    ld a,KEY_SPACE
    call key_hit
    ret nc
    ld hl,run_shots
    ld b,RUN_SHOT_MAX
@run_slot:
    ld a,(hl)
    or a
    jr z,@run_slot_free
    inc hl
    inc hl
    djnz @run_slot
    ret                                 ; three in the air already
@run_slot_free:
    ld (hl),RUN_UX + 5
    inc hl
    ld a,(run_y)
    ld (hl),a
    jp snd_fire


; ----------------------------------------------------------------------------
;  run_shots_step -- ours fly right; off the edge they are free; on an enemy, a kill
; ----------------------------------------------------------------------------
run_shots_step:
    ld hl,run_shots
    ld b,RUN_SHOT_MAX
@run_shot:
    ld a,(hl)
    or a
    jr z,@run_shot_next
    add a,RUN_SHOT_DX
    cp 160
    jr c,@run_shot_flies
    xor a                               ; gone off the right
@run_shot_flies:
    ld (hl),a
    or a
    jr z,@run_shot_next
    push bc
    push hl
    call run_shot_hits                  ; ...and did it land on anyone?
    pop hl
    pop bc
    jr nc,@run_shot_next
    ld (hl),0                           ; it did: the shot is spent
@run_shot_next:
    inc hl
    inc hl
    djnz @run_shot
    ret

;  HL -> a shot (x, y). CF set if it hit an enemy, which is then dead.
run_shot_hits:
    ld a,(hl)
    ld (run_tx),a
    inc hl
    ld a,(hl)
    ld (run_ty),a
    ld hl,run_enemies
    ld b,RUN_ENEMY_MAX
@run_hit_one:
    ld a,(hl)
    or a
    jr z,@run_hit_next
    push hl
    inc hl
    call run_near                       ; HL -> the enemy's x, y
    pop hl
    jr nc,@run_hit_next
    ld (hl),0                           ; dead
    ld hl,run_kills
    inc (hl)
    call snd_explosion
    scf
    ret
@run_hit_next:
    ld de,4
    add hl,de
    djnz @run_hit_one
    or a
    ret

;  HL -> an (x, y) pair. CF set if (run_tx, run_ty) is within the hit box.
run_near:
    ld a,(hl)
    ld c,a
    ld a,(run_tx)
    sub c
    jr nc,@run_near_dx
    neg
@run_near_dx:
    cp RUN_HIT_UX
    ret nc
    inc hl
    ld a,(hl)
    ld c,a
    ld a,(run_ty)
    sub c
    jr nc,@run_near_dy
    neg
@run_near_dy:
    cp RUN_HIT_Y
    ret                                 ; CF set: inside


; ----------------------------------------------------------------------------
;  run_enemies_step -- each one flies left on its sine, and may fire
;  An enemy is (alive, x, y, theta), with y0 kept in theta's neighbour: the
;  record is alive, x, y0, theta and y is derived each step.
; ----------------------------------------------------------------------------
run_enemies_step:
    ld ix,run_enemies                   ; not a per-scanline loop: four records a step
    ld hl,run_eshots
    ld b,RUN_ENEMY_MAX
@run_enemy:
    push bc
    push hl
    ld a,(ix+0)
    or a
    jr z,@run_enemy_next
    ld a,(ix+1)
    sub RUN_ENEMY_DX
    jr c,@run_enemy_gone
    cp 4
    jr c,@run_enemy_gone
    ld (ix+1),a
    ld a,(ix+3)
    add a,RUN_ENEMY_SPIN
    ld (ix+3),a
    ;  ...fire? Its own shot slot is beside it: one in the air per enemy.
    pop hl
    push hl
    ld a,(hl)
    or a
    jr nz,@run_enemy_next
    call sys_rand
    cp RUN_FIRE_P
    jr nc,@run_enemy_next
    ld a,(ix+1)
    ld (hl),a                           ; the shot starts where it is...
    inc hl
    push hl
    push ix
    pop hl
    call run_enemy_y                    ; ...at the height it is at
    pop hl
    ld (hl),a
    jr @run_enemy_next
@run_enemy_gone:
    ld (ix+0),0                         ; got past us: no kill, no shot
@run_enemy_next:
    pop hl
    inc hl
    inc hl
    ld de,4
    add ix,de
    pop bc
    djnz @run_enemy
    ret

;  HL -> an enemy record. A = its y this step: y0 + AMP * sin(theta) >> 7.
run_enemy_y:
    push hl
    inc hl
    inc hl
    inc hl
    ld a,(hl)                           ; theta
    call cam_sin
    ld b,a
    ld c,RUN_ENEMY_AMP
    call cam_mul7
    pop hl
    inc hl
    inc hl
    add a,(hl)                          ; + y0
    ret


; ----------------------------------------------------------------------------
;  run_eshots_step -- theirs fly left; off the edge they are free; on us, a hit
; ----------------------------------------------------------------------------
run_eshots_step:
    ld hl,run_eshots
    ld b,RUN_ENEMY_MAX
@run_eshot:
    ld a,(hl)
    or a
    jr z,@run_eshot_next
    sub RUN_ESHOT_DX
    jr c,@run_eshot_gone
    cp 2
    jr c,@run_eshot_gone
    ld (hl),a
    ;  on us?
    ld (run_tx),a
    inc hl
    ld a,(hl)
    ld (run_ty),a
    dec hl
    push hl
    push bc
    ld hl,run_me
    call run_near
    pop bc
    pop hl
    jr nc,@run_eshot_next
    ld (hl),0                           ; landed
    push hl
    push bc
    ld hl,mini_hits
    inc (hl)
    call snd_hit
    pop bc
    pop hl
    jr @run_eshot_next
@run_eshot_gone:
    ld (hl),0
@run_eshot_next:
    inc hl
    inc hl
    djnz @run_eshot
    ret


; ----------------------------------------------------------------------------
;  run_spawn -- a new flight when the last is gone
; ----------------------------------------------------------------------------
run_spawn:
    ld hl,run_enemies
    ld b,RUN_ENEMY_MAX
    ld de,4
@run_any:
    ld a,(hl)
    or a
    ret nz                              ; one is still flying
    add hl,de
    djnz @run_any

    call sys_rand
    and #3F
    add a,RUN_YMIN + 8                  ; the flight's line: 46..109
    ld c,a
    ld hl,run_enemies
    ld b,RUN_FLIGHT
    ld a,RUN_ENEMY_X0
@run_flight:
    ld (hl),1                           ; alive
    inc hl
    ld (hl),a                           ; x
    add a,RUN_ENEMY_GAP
    inc hl
    ld (hl),c                           ; y0
    inc hl
    push af
    ld a,b
    rlca
    rlca
    rlca
    rlca                                ; * 16: out of step with each other
    ld (hl),a
    pop af
    inc hl
    djnz @run_flight
    ret


; ----------------------------------------------------------------------------
;  run_draw -- the lane: stars, theirs, ours, the shots, the hits
; ----------------------------------------------------------------------------
run_draw:
    call mini_clear

    ;  Stars: the same field every frame from a fixed seed, every x less the
    ;  scroll -- the title's trick, with one subtraction, and it reads as
    ;  motion because everything moves the same way at the same speed.
    ld hl,RUN_STAR_SEED
    ld b,RUN_STARS
@run_star:
    push bc
    call sys_rand_step
    push hl
    ld a,(run_scroll)
    ld c,a
    ld a,h
    sub c                               ; x, wrapping in 256
    add a,RUN_STAR_X0
    ld e,a
    ld d,0
    jr nc,@run_star_x
    inc d
@run_star_x:
    ld a,l
    and #7F
    add a,MG_BODY_Y
    ld c,a                              ; y; gfx_vline clips the band
    ex de,hl
    ld b,1
    ld a,MG_PEN
    call gfx_vline
    pop hl
    pop bc
    djnz @run_star

    ;  Theirs, red, facing left.
    ld a,1
    ld (spr_enemy),a
    ld a,RUN_ENEMY_VIEW
    ld (mini_view),a
    ld ix,run_enemies
    ld b,RUN_ENEMY_MAX
@run_draw_enemy:
    push bc
    ld a,(ix+0)
    or a
    jr z,@run_draw_enemy_next
    push ix
    push ix
    pop hl
    call run_enemy_y
    ld c,a
    pop ix
    ld a,(ix+1)
    add a,a                             ; units -> pixels
    ld e,a
    ld d,0
    jr nc,@run_draw_enemy_x
    inc d
@run_draw_enemy_x:
    push ix
    ld b,RUN_TIER
    call mini_blit
    pop ix
@run_draw_enemy_next:
    ld de,4
    add ix,de
    pop bc
    djnz @run_draw_enemy

    ;  Ours, white, facing right.
    xor a
    ld (spr_enemy),a
    ld a,RUN_VIEW
    ld (mini_view),a
    ld a,(run_y)
    ld c,a
    ld e,RUN_UX * 2
    ld d,0
    ld b,RUN_TIER
    call mini_blit

    ;  The shots: ours in the fleet's ink, theirs in the alarm's.
    ld hl,run_shots
    ld b,RUN_SHOT_MAX
    ld a,1
    call run_draw_shots
    ld hl,run_eshots
    ld b,RUN_ENEMY_MAX
    ld a,3
    call run_draw_shots

    jp mini_hit_marks

;  HL -> B shots of (x, y); A = the pen. Three lines tall, four pixels wide.
run_draw_shots:
    ld (run_pen),a
@run_draw_shot:
    ld a,(hl)
    or a
    jr z,@run_draw_shot_next
    push bc
    push hl
    add a,a                             ; units -> pixels
    ld e,a
    ld d,0
    jr nc,@run_draw_shot_x
    inc d
@run_draw_shot_x:
    inc hl
    ld c,(hl)
    ex de,hl
    ld b,3
    ld a,(run_pen)
    push hl
    push bc
    call gfx_vline
    pop bc
    pop hl
    inc hl
    ld a,(run_pen)
    push hl
    push bc
    call gfx_vline
    pop bc
    pop hl
    inc hl
    ld a,(run_pen)
    push hl
    push bc
    call gfx_vline
    pop bc
    pop hl
    inc hl
    ld a,(run_pen)
    call gfx_vline
    pop hl
    pop bc
@run_draw_shot_next:
    inc hl
    inc hl
    djnz @run_draw_shot
    ret


; ----------------------------------------------------------------------------
;  run_say -- the line at the top, and the result's second line at the bottom
; ----------------------------------------------------------------------------
run_say:
    ld b,0
    ld c,CTX_BAR_H
    ld d,SCR_BYTES_PER_LINE
    ld e,MG_BODY_Y - CTX_BAR_H
    xor a
    call scr_fill_rect
    ld b,0
    ld c,MG_LOST_Y
    ld d,SCR_BYTES_PER_LINE
    ld e,8
    xor a
    call scr_fill_rect

    ld a,(run_msg)
    cp RUN_MSG_LOST
    ld a,1
    jr nz,@run_pen_set
    ld a,3
@run_pen_set:
    call txt_set_pen
    ld hl,run_words
    ld a,(run_msg)
    call mini_nth
    push hl
    ld a,(run_msg)
    ld e,a
    ld d,0
    ld hl,run_msg_x
    add hl,de
    ld b,(hl)
    ld c,MG_TEXT_Y
    pop hl
    call txt_draw

    ld a,(run_msg)
    cp RUN_MSG_WON
    jr z,@run_say_salvage
    cp RUN_MSG_LOST
    jr nz,@run_said
    ld hl,run_words
    ld a,RUN_MSG_TOLL
    call mini_nth
    ld b,MG_TOLL_X
    ld c,MG_LOST_Y
    call txt_draw
    ld a,(mini_lost)
    ld b,MG_TOLL_NUM_X
    ld c,MG_LOST_Y
    ld d,2
    call txt_draw_num
    jr @run_said
@run_say_salvage:
    ld hl,run_words
    ld a,RUN_MSG_SALVAGE
    call mini_nth
    ld b,RUN_SALVAGE_X
    ld c,MG_LOST_Y
    call txt_draw
    ld a,(run_kills)
    ld h,a
    ld l,RUN_SALVAGE
    call mul_u8
    ld b,RUN_SALVAGE_NUM_X
    ld c,MG_LOST_Y
    call txt_draw_num4
@run_said:
    ld a,1
    jp txt_set_pen


; ============================================================================
;  Words, columns, state -- all in this bank
; ============================================================================
run_words:
run_say_run:      defb "CLEAR THE LANE.  SPACE FIRES.",0
run_say_won:      defb "THE LANE IS CLEAR.",0
run_say_lost:     defb "WE WERE SHOT DOWN.  THEY WERE WAITING.",0
run_say_salvage:  defb "SALVAGE RU",0
run_say_toll:     defb "SHIPS LOST",0
run_words_end:

run_intro_words:
run_intro_1:      defb "A PICKET WAITS AT THE JUMP POINT.",0
run_intro_2:      defb "ONE OF OURS GOES AHEAD TO CLEAR IT.",0
run_intro_3:      defb "UP AND DOWN FLY. SPACE FIRES.",0
run_intro_4:      defb "THREE HITS AND WE ARE DOWN.",0
run_intro_go:     defb "ENTER - BEGIN",0
run_intro_words_end:

run_msg_x:
    defb RUN_RUN_X, RUN_WON_X, RUN_LOST_X

;  Our own (x, y), for run_near.
run_me:
    defb RUN_UX
run_y:              defb 0
run_left:           defb 0
run_scroll:         defb 0
run_kills:          defb 0
run_msg:            defb 0
run_tx:             defb 0
run_ty:             defb 0
run_pen:            defb 0
run_enemies:        defs RUN_ENEMY_MAX * 4      ; alive, x, y0, theta
run_shots:          defs RUN_SHOT_MAX * 2       ; x (0 = free), y
run_eshots:         defs RUN_ENEMY_MAX * 2      ; x (0 = free), y
