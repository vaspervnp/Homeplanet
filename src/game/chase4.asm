; ============================================================================
;  chase4.asm -- the bank-4 half of the vortex chase: when, and the way in
; ============================================================================
;  game/minigame.asm RUNS FROM BANK 7 now, with the interceptor library it
;  draws and the words it says. It gave DISC.BIN fourteen hundred bytes back
;  and left two things behind that have to be bank 4 code: this decision,
;  which reads mis_index with the window at rest, and the squad_refresh the
;  ambush needs afterwards -- squad_refresh is bank 4, and bank-7 code cannot
;  call bank 4. chase_run, in the low 16K, is the page in and out.
; ----------------------------------------------------------------------------

mini_maybe:
    ld a,(mis_index)
    inc a
@mg_every:
    sub MG_EVERY
    jr z,@mg_chase
    jr nc,@mg_every
    ret


; ----------------------------------------------------------------------------
;  mini_run -- the chase, from a black screen to a black screen
;  Uses: everything
;
;  IT RUNS ITS OWN LOOP, with its own vertical blank and its own page flip,
;  exactly as jfx_vanish does and for the same two reasons: there is nothing
;  else left to run, and mis_jump_now has to stay atomic. It also means this
;  costs the frame loop NOTHING -- there is no branch in demo_update to reach
;  it, which matters because demo_update is in the low 16K and the low 16K has
;  thirty spare bytes.
; ----------------------------------------------------------------------------
@mg_chase:
    call chase_run                      ; low 16K: bank 7 in, mini_run, bank 4 back
    jp squad_refresh                    ; ...the ambush may have taken ships
