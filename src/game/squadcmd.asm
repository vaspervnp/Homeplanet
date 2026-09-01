; ============================================================================
;  game/squadcmd.asm -- the squadron commands, IN BANK 4
; ============================================================================
;  Split out of game/squad.asm, which keeps SQUAD_MAX and the derived counts.
;  Every routine here is reached from phase4_commands on a key edge, or from
;  demo_init -- never with a foreign bank under the window, which is what
;  makes bank 4 a legal place for it. See game/ordercmd.asm for the whole
;  argument and where the room came from.
;
;  squad_refresh and squad_recount are the exceptions worth naming: they are
;  called after every command AND from the HUD, so they run inside the frame
;  loop. That is still with bank 4 at rest -- the only code that leaves it is
;  class_tier_addr -- so they came across with the rest rather than being
;  stranded on their own in the low 16K.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
;  squad_init -- settle the selection once the fleet exists
;  Uses: everything
; ----------------------------------------------------------------------------
squad_init:
    ;  Membership is set when the ships are created -- the Mothership belongs
    ;  to no squadron and a blanket sweep here would drag it into one.
    ld a,1
    ld (squad_sel),a
    jp squad_refresh


; ----------------------------------------------------------------------------
;  squad_refresh -- recount, then make sure the selection still means something
;  Uses: everything
; ----------------------------------------------------------------------------
squad_refresh:
    call squad_recount

    ld a,(squad_sel)
    call squad_count_of
    or a
    ret nz                              ; still has ships, nothing to do

    ;  The selected squadron just emptied. Fall back to the lowest active one
    ;  so the player is never pointing at nothing.
    ld b,SQUAD_MAX
    ld a,1
@sq_look:
    ld c,a
    call squad_count_of
    or a
    jr nz,@sq_take
    ld a,c
    inc a
    djnz @sq_look
    ret                                 ; the whole fleet is gone
@sq_take:
    ld a,c
    ld (squad_sel),a
    ret


; ----------------------------------------------------------------------------
;  squad_recount -- rebuild squad_count from the entity table
;  Uses: everything
; ----------------------------------------------------------------------------
squad_recount:
    ld hl,squad_count
    ld b,SQUAD_MAX + 1
    xor a
@sq_zero:
    ld (hl),a
    inc hl
    djnz @sq_zero

    xor a
    ld (squad_index),a
@sq_tally:
    ld a,(squad_index)
    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    pop hl
    jr z,@sq_skip

    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    or a
    jr z,@sq_skip                          ; unassigned
    cp SQUAD_MAX + 1
    jr nc,@sq_skip                         ; out of range; ignore rather than corrupt
    ld l,a
    ld h,0
    ld de,squad_count
    add hl,de
    inc (hl)

@sq_skip:
    ld hl,squad_index
    inc (hl)
    ld a,(hl)
    ;  The player's region. mis_make_enemy writes SQUAD_NONE and the test
    ;  above rejects it, so this counted the same squadrons either way -- it
    ;  just walked the hostile region to find that out, on every keypress that
    ;  reshapes a squadron and after every ship that dies.
    cp ENT_PLAYER_MAX
    jr c,@sq_tally
    ret


; ----------------------------------------------------------------------------
;  squad_count_of -- A = how many ships squadron A has
;  In : A = 1..9
;  Out: A = count
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
squad_count_of:
    ld l,a
    ld h,0
    ld de,squad_count
    add hl,de
    ld a,(hl)
    ret


; ----------------------------------------------------------------------------
;  squad_inc / squad_dec -- step a squadron number, wrapping within 1..9
;
;  "For squadron 1 the previous one is the last" -- so the wrap is numeric and
;  goes 1 -> 9, not to the last ACTIVE squadron. Predictable beats clever when
;  the player is holding a key.
;  In/Out: A
;  Uses: AF
; ----------------------------------------------------------------------------
squad_inc:
    inc a
    cp SQUAD_MAX + 1
    ret c
    ld a,1
    ret

squad_dec:
    dec a
    ret nz
    ld a,SQUAD_MAX
    ret


; ----------------------------------------------------------------------------
;  squad_select -- the number keys
;  In : A = 1..9
;  Out: the selection changes only if that squadron has ships
;  Uses: everything
; ----------------------------------------------------------------------------
squad_select:
    or a
    ret z
    cp SQUAD_MAX + 1
    ret nc
    ld b,a
    call squad_count_of
    or a
    ret z                               ; empty squadrons cannot be selected
    ld a,b
    ld (squad_sel),a
    xor a
    ld (sel_mothership),a               ; a squadron now has the camera
    ret


; ----------------------------------------------------------------------------
;  squad_move_ship -- reassign one ship
;  In : B = squadron to take from, C = squadron to give to
;  Out: CF set if a ship was moved
;  Uses: AF, DE, HL  (B and C survive)
;
;  The funnel every one of d, m, n and c goes through, which is why squad_born
;  hangs off it rather than off the four commands: a squadron that did not
;  exist a moment ago is stationed here, once, wherever the reassignment came
;  from. squad_by_class is the only other thing that writes ENT_SQUAD and it
;  calls squad_born itself.
; ----------------------------------------------------------------------------
squad_move_ship:
    xor a
    ld (squad_index),a
@sq_scan:
    ld a,(squad_index)
    cp ENT_MAX
    jr nc,@sq_none

    call ent_addr
    push hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    pop hl
    jr z,@sq_scan_next

    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    cp b
    jr nz,@sq_scan_next
    ld (hl),c

    ;  HL is the ship's ENT_SQUAD; back up twelve bytes for its position,
    ;  which is what squadron C's station becomes if C is only now being made.
    ld de,-ENT_SQUAD
    add hl,de
    call squad_born
    scf
    ret

@sq_scan_next:
    ld hl,squad_index
    inc (hl)
    jr @sq_scan

@sq_none:
    or a
    ret


; ----------------------------------------------------------------------------
;  squad_born -- a squadron that had no ships takes a station and a shape
;  In : B = the squadron the ship is leaving, C = the one it is joining,
;       HL -> the ship's record (ENT_X is offset 0)
;  Out: nothing; B and C survive, HL does not
;  Uses: AF, DE, HL
;
;  THE BUG THIS EXISTS TO FIX. squad_dest used to be nine FIXED stations,
;  copied out of order_home at boot and scattered up to 6000 units apart --
;  and only squadron 1's was anywhere near the fleet, because that is where
;  phase4_spawn_fleet puts it. So the instant `d`, `m` or `n` put a ship into
;  any other number, phase4_fly started dragging it towards a point it had
;  never been sent to. Divide a formation and half of it turned and flew off
;  the screen. The player reported it as "selecting squadrons mixes them up",
;  which is exactly what it looks like: press a key, the fleet comes apart.
;
;  The rule now, and it is the same reasoning as squad_count being derived:
;  an EMPTY SQUADRON HAS NO STATION. It acquires one by being made, from the
;  ship that made it, and its formation from the squadron that ship left --
;  which game/formation.asm has claimed in its header comment since the day it
;  was written without anything implementing it.
;
;  The guard is squad_count, and it reads the value from before the command
;  started: nothing calls squad_refresh until the command is finished, so a
;  divide that peels seven ships runs this seven times and the last one wins.
;  All seven were inside the parent's formation, so any of them will do.
;
;  B and C are pushed because squad_split and squad_combine both loop on
;  squad_move_ship and need their two squadron numbers back -- the LDIR below
;  would otherwise quietly end a divide after one ship.
; ----------------------------------------------------------------------------
squad_born:
    push bc
    push hl
    ld a,c
    call squad_count_of
    or a
    pop hl
    jr nz,@sq_born_done                 ; it has ships: it keeps what it has

    ;  The shape it peeled off in. squad_form is indexed by squadron number,
    ;  so B and C go in as they stand.
    push hl
    ld d,0
    ld e,b
    ld hl,squad_form
    add hl,de
    ld a,(hl)
    ld e,c
    ld hl,squad_form
    add hl,de
    ld (hl),a
    pop hl

    ;  ...and the station: where this ship already is.
    ld a,c
    dec a                               ; squad_dest is 0-based
    push hl
    call phase4_times6
    ld de,squad_dest
    add hl,de
    ex de,hl                            ; DE -> squad_dest[C]
    pop hl                              ; HL -> the ship's position
    ld bc,6
    ldir

@sq_born_done:
    pop bc
    ret


; ----------------------------------------------------------------------------
;  squad_find_free -- the next squadron after the selection with no ships
;  Out: A = 1..9, or 0 if all nine are in use
;  Uses: everything
;
;  Searches from the selection upwards rather than from 1, so splitting twice
;  in a row gives you consecutive numbers instead of reusing a gap you just
;  left behind.
; ----------------------------------------------------------------------------
squad_find_free:
    ld a,(squad_sel)
    ld b,SQUAD_MAX - 1                  ; every number except the selection
@sq_try:
    call squad_inc
    ld c,a
    call squad_count_of
    or a
    jr z,@sq_found
    ld a,c
    djnz @sq_try
    xor a
    ret
@sq_found:
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  squad_find_active -- the next squadron after the selection that has ships
;  Out: A = 1..9, or 0 if the selection is the only one
;  Uses: everything
; ----------------------------------------------------------------------------
squad_find_active:
    ld a,(squad_sel)
    ld b,SQUAD_MAX - 1
@sq_try_active:
    call squad_inc
    ld c,a
    call squad_count_of
    or a
    jr nz,@sq_found_active
    ld a,c
    djnz @sq_try_active
    xor a
    ret
@sq_found_active:
    ld a,c
    ret


; ----------------------------------------------------------------------------
;  squad_split -- 'd'
;
;  Half the selection peels off into the next free number. Odd numbers leave
;  the larger half where it was, so splitting 5 gives 3 and 2.
;  Uses: everything
; ----------------------------------------------------------------------------
squad_split:
    ld a,(squad_sel)
    call squad_count_of
    cp 2
    ret c                               ; a single ship cannot be divided

    srl a
    ld (squad_pending),a                ; how many to move

    call squad_find_free
    or a
    ret z                               ; all nine numbers are taken

    ld c,a
    ld a,(squad_sel)
    ld b,a
@sq_peel:
    call squad_move_ship
    ret nc                              ; ran out; refresh below would be a lie
    ld hl,squad_pending
    dec (hl)
    jr nz,@sq_peel

    jp squad_refresh


; ----------------------------------------------------------------------------
;  squad_move_next -- 'm', move one ship to the next number
;
;  The target is created simply by putting a ship in it: a squadron exists
;  when it has ships.
;  Uses: everything
; ----------------------------------------------------------------------------
squad_move_next:
    ld a,(squad_sel)
    call squad_inc
    ld c,a
    ld a,(squad_sel)
    ld b,a
    call squad_move_ship
    ret nc
    jp squad_refresh


; ----------------------------------------------------------------------------
;  squad_move_prev -- 'n', move one ship to the previous number
;  Uses: everything
; ----------------------------------------------------------------------------
squad_move_prev:
    ld a,(squad_sel)
    call squad_dec
    ld c,a
    ld a,(squad_sel)
    ld b,a
    call squad_move_ship
    ret nc
    jp squad_refresh


; ----------------------------------------------------------------------------
;  squad_combine -- 'c'
;
;  Absorbs the next ACTIVE squadron into the selection, rather than the next
;  NUMBER: merging with an empty squadron would be a no-op, and the player is
;  reading a HUD that only lists the active ones.
;
;  The selection survives the merge, so the player keeps pointing at the
;  bigger formation they just made.
;  Uses: everything
; ----------------------------------------------------------------------------
squad_combine:
    call squad_find_active
    or a
    ret z                               ; nothing to merge with

    ld b,a                              ; take from the one we found
    ld a,(squad_sel)
    ld c,a                              ; give to the selection
@sq_absorb:
    call squad_move_ship
    jr c,@sq_absorb

    jp squad_refresh
