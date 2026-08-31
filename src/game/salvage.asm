; ============================================================================
;  game/salvage.asm -- the Salvage Corvette's job, IN BANK 4
; ============================================================================
;  Homeplanet.md section 8 gives the class one line -- "ρυμουλκεί εχθρικά
;  ναυάγια στο Mothership" -- and for a long time it was the only line in
;  section 8 that nothing implemented. The corvette cost 90 RU, had the second
;  weakest row in the damage matrix, and did nothing an interceptor at 35 does
;  not do better. There was no reason to build one.
;
;  So: an enemy that would have been destroyed is CRIPPLED instead, a corvette
;  is sent out with `T` to fetch the hull, and the yard pays for what it did
;  not have to build.
;
;      T   the selected squadron's SALVAGE CORVETTES go and fetch the wrecks
;
;  It is deliberately the same machine as the harvester. A corvette's whole
;  state is its ENT_ORDER plus which wreck it has hold of, so there is no
;  salvage table to keep in step with the entity list -- the same reasoning
;  that makes squad_count derived and that gives the harvester no table either.
;  eco_run_workers walks both out of one loop; eco_at_target flies both;
;  eco_earn pays both.
;
;  ----------------------------------------------------------------------------
;  WHEN AN ENEMY BECOMES A WRECK, AND THE ONE THING THAT DECIDES IT
;  ----------------------------------------------------------------------------
;  A hostile that is destroyed leaves a wreck if, and only if, the player has a
;  Salvage Corvette flying and there are fewer than SLV_WRECK_MAX hulls already
;  adrift. There is no random roll.
;
;  The corvette test is not flavour, it is the whole safety argument. A wreck is
;  an ACTIVE entity: it holds a slot, it is projected, sorted and drawn, and the
;  frame budget in CLAUDE.md says plainly what ten more entities cost. A player
;  who has never built a corvette must be exactly as well off as before this
;  file existed -- and they are, byte for byte, because slv_survey comes back
;  with no corvette and the flag is never written.
;
;  And it makes the mechanic legible. A coin toss is not something a player can
;  act on; "I built the salvage ship, so kills leave hulls" is. The randomness
;  in this game is in the WAVES, where it is measured (tools/waverate.py); there
;  is nothing here for a random number to buy.
;
;  Wave ships leave wrecks too, and that is a decision rather than an omission.
;  It makes loitering a TRADE -- more waves is more RU and less hull, and hull
;  never comes back -- which is a better version of the choice the waves already
;  ask. What bounds it is SLV_WRECK_MAX and the fact that a wave is sized
;  against the hull the trade is spending.
;
;  ----------------------------------------------------------------------------
;  WHAT A WRECK IS NOT, AND WHERE EACH OF THOSE LIVES
;  ----------------------------------------------------------------------------
;  ENT_F_DISABLED is set and ENT_F_ENEMY stays. Four things follow, and NONE of
;  them is in this file -- each is one test in the routine that would otherwise
;  get it wrong:
;
;      it does not count towards a CLEAR objective   mis_count_enemies' mask
;      it is not fired at, and does not strand an
;        attack order over its own corpse            cbt_target_flying
;      it is not chosen as a target                  cbt_find_enemy
;      it does not fire, and does not close          cbt_update, cbt_move_enemies
;
;  THE FIRST OF THOSE IS THE ONE THAT WOULD HAVE RUINED THIS. mis_count_enemies
;  counts entities whose flags equal ACTIVE+ENEMY; a wreck that stayed in that
;  set makes a CLEAR mission uncompletable the moment the fleet cripples the
;  last hostile, so `J` is never offered and building a corvette silently traps
;  the player in the mission. It is exactly the trap ENT_F_WAVE was given a bit
;  to avoid, and it is avoided the same way: one more bit in a mask that was
;  already being compared, for nothing.
;
;  Keeping ENT_F_ENEMY rather than clearing it is what makes the other side of
;  that free. wave_health sums the hull of everything ACTIVE and not ENEMY, so a
;  wreck is out of the fleet's health -- and therefore out of the wave scaling
;  -- without a line of code. Clear the flag instead and a captured hull would
;  make the next wave bigger, which is the opposite of a reward. mis_clear_enemies
;  and fleet_save fall out the same way: wrecks are cleared at mission setup and
;  are never carried between missions.
;
;  ----------------------------------------------------------------------------
;  WHY IT IS IN BANK 4
;  ----------------------------------------------------------------------------
;  By the narrow test in game/shipclass.asm: can any of it run between
;  class_tier_addr and class_blit_done? slv_set_tow runs on a keypress,
;  slv_make_wreck from inside cbt_update and slv_tow_step from inside
;  eco_update, and the window is at its resting state for the whole of
;  demo_update's simulation. So all of it is legal here, and the low 16K -- 768
;  bytes, quantised in pages of 256, with the test scratch sitting on top of
;  CODE_END -- is where it would have hurt. It is the third thing in the bank
;  reached from inside the frame loop, after game/ctxbar.asm and
;  gfx/markproj.asm.
;
;  There is no state in the low 16K to go with it, and that is the point: the
;  corvette's state IS the entity record. Everything below is scratch.
; ----------------------------------------------------------------------------

;  How many crippled hulls may be adrift at once. Not a difficulty knob: it is
;  the frame budget. A wreck is a whole entity through phase4_project,
;  phase4_sort and phase4_draw, and the measurements in CLAUDE.md put ten more
;  entities at about a third of a frame. The eleventh enemy of a twelve-ship
;  picket therefore dies the way it always did.
;
;  Four is one corvette's work queue, measured rather than guessed: in mission
;  3 -- THE PICKET, four hostiles -- one corvette bought at 90 RU crippled all
;  four, fetched all four, and had them home 780 emulator frames after `T` was
;  pressed, which is about sixteen seconds of game time.
SLV_WRECK_MAX       equ 4


; ----------------------------------------------------------------------------
;  slv_make_wreck -- the ship at (cbt_target) has just been destroyed
;  In : (cbt_target) = its slot
;  Out: CF set if it is now a wreck and its flags have been written;
;       CF clear if the caller should free the slot as it always did
;  Uses: everything except (cbt_target), which the caller still needs
;
;  Called from cbt_kill, which is a handful of times a mission, so the walk of
;  the table below is free -- and it answers both halves of the question at
;  once, which is why there is one walk and not two.
; ----------------------------------------------------------------------------
slv_make_wreck:
    ;  Only the enemy leaves wrecks. Section 8 says "εχθρικά ναυάγια", and a
    ;  fleet that could salvage its own losses would undo section 1's whole
    ;  claim that what is lost is lost.
    ld a,(cbt_target)
    call ent_addr
    ld (slv_ent),hl
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and ENT_F_ENEMY
    jr z,@slv_no_wreck

    call slv_survey                     ; CF: a corvette is flying
    jr nc,@slv_no_wreck
    ld a,(slv_wrecks)
    cp SLV_WRECK_MAX
    jr nc,@slv_no_wreck

    ;  ENT_SQUAD, ENT_ORDER and ENT_TARGET are consecutive, so three writes and
    ;  two INCs put the hull into a state nothing will act on: in no squadron,
    ;  under no order, aiming at nobody. ENT_HULL is already zero -- that is
    ;  what brought it here.
    ld hl,(slv_ent)
    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld (hl),SQUAD_NONE
    inc hl
    ld (hl),ENT_ORDER_IDLE
    inc hl
    ld (hl),ENT_NO_TARGET
    pop hl
    ld de,ENT_FLAGS
    add hl,de
    ld (hl),ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED
    scf
    ret

@slv_no_wreck:
    or a
    ret


; ----------------------------------------------------------------------------
;  slv_survey -- one walk that answers both halves of "may this be a wreck?"
;  Out: (slv_wrecks) = crippled hulls already adrift
;       CF set if the player has a live Salvage Corvette
;  Uses: everything
;
;  The pointer walks the ENT_FLAGS byte and reaches ENT_CLASS with two DECs,
;  which is wave_health's trick and rests on the same adjacency src/main.asm
;  already asserts for it.
; ----------------------------------------------------------------------------
slv_survey:
    xor a
    ld (slv_wrecks),a
    ld (slv_corvette),a

    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_MAX
@slv_survey_one:
    ld a,(hl)
    bit 0,a
    jr z,@slv_survey_next               ; empty slot
    bit 2,a                             ; ENT_F_DISABLED
    jr z,@slv_survey_flying

    ld a,(slv_wrecks)
    inc a
    ld (slv_wrecks),a
    jr @slv_survey_next

@slv_survey_flying:
    and ENT_F_ENEMY
    jr nz,@slv_survey_next              ; theirs, and still a ship
    dec hl
    dec hl                              ; ENT_CLASS, two before the flags
    ld a,(hl)
    inc hl
    inc hl
    cp CLASS_SALVAGE
    jr nz,@slv_survey_next
    ld a,1
    ld (slv_corvette),a

@slv_survey_next:
    add hl,de
    djnz @slv_survey_one

    ld a,(slv_corvette)
    rra                                 ; bit 0 -> carry
    ret


; ----------------------------------------------------------------------------
;  slv_set_tow -- the `T` key: the squadron's corvettes go and fetch
;  Uses: everything
;
;  The mirror of eco_set_harvest, including the part section 9 is explicit
;  about for the harvester: it orders the CORVETTES and not the squadron.
;  Sending fifteen interceptors to stand over a wreck none of them can tow is
;  the same mistake as sending them to a resource patch.
;
;  It clears ENT_TOW, and that is the one line that is not symmetry. ENT_TOW is
;  a slot index; a stale one names a real entity, and if that entity happened to
;  be a wreck the corvette would believe it already had hold of something on the
;  far side of the map -- and slv_drag would teleport the wreck onto the tug.
;  One write on the one path that starts a tow, rather than a rule about who
;  clears it.
; ----------------------------------------------------------------------------
slv_set_tow:
    xor a
    ld (slv_index),a
@slv_order:
    ld a,(slv_index)
    call ent_addr

    push hl
    ld de,ENT_FLAGS
    add hl,de
    bit 0,(hl)
    pop hl
    jr z,@slv_order_next                ; a free slot keeps its old class

    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    pop hl
    cp CLASS_SALVAGE
    jr nz,@slv_order_next

    push hl
    ld de,ENT_SQUAD
    add hl,de
    ld a,(hl)
    ld hl,squad_sel
    cp (hl)
    pop hl
    jr nz,@slv_order_next

    push hl
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_TOW
    pop hl
    ld de,ENT_TOW
    add hl,de
    ld (hl),ENT_NO_TARGET               ; nothing in hand yet

@slv_order_next:
    ld hl,slv_index
    inc (hl)
    ld a,(hl)
    cp ENT_MAX
    jr c,@slv_order
    ret


; ----------------------------------------------------------------------------
;  slv_tow_step -- one corvette's turn, out of eco_run_workers
;  In : (eco_ent) -> the corvette
;  Uses: everything
;
;  Outbound with nothing in hand, homebound dragging a hull, paid out at the
;  Mothership -- eco_harvester_step's three states, and it borrows that
;  routine's machinery outright: eco_at_target does the step and the arrival
;  test, eco_earn takes the money in at the ceiling.
; ----------------------------------------------------------------------------
slv_tow_step:
    ld hl,(eco_ent)
    ld de,ENT_TOW
    add hl,de
    ld a,(hl)
    cp ENT_MAX
    jr nc,@slv_outbound
    ld (slv_wreck),a

    ;  ...and CHECK it, every frame, rather than trusting the index. A slot
    ;  index names something whatever is in it: the wreck may have been
    ;  delivered by another corvette, or cleared by mis_setup, or the slot
    ;  recycled into a fresh hostile. If it is no longer a crippled hull then
    ;  we are not towing anything, whatever the byte says.
    call slv_is_wreck
    jr nc,@slv_outbound

    ld a,(moth_slot)
    call ent_addr                       ; ENT_X is offset 0
    ld (eco_patch_ptr),hl
    call eco_at_target
    push af                             ; the arrival, before slv_drag lands on it
    call slv_drag
    pop af
    ret nc
    jp slv_deliver

@slv_outbound:
    call slv_find_wreck
    jr nc,@slv_nothing_to_tow
    ld (slv_wreck),a
    call ent_addr
    ld (eco_patch_ptr),hl
    call eco_at_target
    ret nc                              ; still on the way

    ;  Close enough to get a line on it.
    ld hl,(eco_ent)
    ld de,ENT_TOW
    add hl,de
    ld a,(slv_wreck)
    ld (hl),a
    ret

;  Nothing adrift anywhere, so the order is SPENT -- and that is not tidiness,
;  it is the bug CLAUDE.md documents at length under "An attack order has to be
;  spent". phase4_fly skips a towing ship on purpose, so a corvette left under
;  a TOW order it can never satisfy is steered by nobody: it stops dead where
;  it stands, for the rest of the mission, and fleet_save carries those
;  coordinates into the next one. IDLE puts it back in its formation, which is
;  where a ship with no work belongs.
@slv_nothing_to_tow:
    ld hl,(eco_ent)
    ld de,ENT_ORDER
    add hl,de
    ld (hl),ENT_ORDER_IDLE
    ret


; ----------------------------------------------------------------------------
;  slv_drag -- the wreck goes wherever the tug goes
;  In : (eco_ent) -> the tug, (slv_wreck) = the hull it has hold of
;  Uses: everything, the flags included -- which is why slv_tow_step pushes AF
;        around the call rather than testing eco_at_target's carry afterwards.
;
;  Six bytes rather than a tow line with a length: at 320 pixels and the sizes
;  these sprites draw at, a hull held one ship's length behind and one held on
;  top are the same picture, and the second one needs no offset, no direction
;  and no case for the tug turning round.
; ----------------------------------------------------------------------------
slv_drag:
    ld a,(slv_wreck)
    call ent_addr
    ex de,hl
    ld hl,(eco_ent)
    ld bc,6
    ldir
    ret


; ----------------------------------------------------------------------------
;  slv_deliver -- the hull reaches the Mothership and the yard pays for it
;  In : (slv_wreck) = its slot, (eco_ent) -> the corvette
;  Uses: everything
;
;  WHAT IT IS WORTH is eco_class_cost for the class of the hull -- what the
;  yard would have charged to build one. A Vekhar interceptor is 35 RU, which
;  is the only figure that matters today because the Vekhar field nothing else.
;
;  Set against the 90 RU the corvette costs: three tows pay for it, and a
;  mission fields four to twelve hostiles. MEASURED, in mission 3 with the
;  four-ship picket that mission carries: 90 RU spent, 140 RU back, one
;  mission. Set against the alternative use of 90 RU -- two and a half
;  interceptors, which fight -- it is a real choice rather than a free one,
;  because the tow is a round trip the corvette spends outside the battle line
;  and because the fleet has to still be in the mission to make it, which is
;  what the attack waves charge for. And it is bounded at both ends:
;  SLV_WRECK_MAX hulls at a time, and eco_earn's ceiling.
;
;  The full price and not half of it, deliberately. Half an interceptor is 17
;  RU and five tows to break even, which is more flying than any player will do
;  for a ship that is not fighting -- at which point the corvette is a 90 RU
;  ornament again, which is the thing this file exists to fix.
; ----------------------------------------------------------------------------
slv_deliver:
    ld a,(slv_wreck)
    call ent_addr
    push hl
    ld de,ENT_CLASS
    add hl,de
    ld a,(hl)
    pop hl
    cp CLASS_COUNT
    jr c,@slv_class_ok
    xor a                               ; the same guard cbt_damage_for keeps
@slv_class_ok:
    push af

    ;  ...AND WHAT THE YARD LEARNED FROM IT. A Vekhar frigate hull towed to the
    ;  Mothership is what unlocks the class in the build panel -- the mechanic
    ;  is reverse-engineering rather than fetching a token, which is the whole
    ;  reason the derelict in game/campaignrun.asm is a frigate and not a crate.
    ;
    ;  It is keyed on the CLASS of the hull and not on "was that the derelict",
    ;  and that is a decision. A remembered slot index is exactly the thing
    ;  CLAUDE.md says never to trust -- the derelict's slot is recycled the
    ;  moment it is delivered -- and the class is the honest statement of the
    ;  rule anyway: tow a frigate home and you can build frigates. The Vekhar
    ;  field only interceptors today, so the derelict is the only hull in the
    ;  game this can be true of; the day campaign.asm grows a class column it
    ;  will be true of a frigate shot down in a fight too, which is right.
    ;
    ;  HERE and not at slv_find_wreck or the moment the tow line goes on: the
    ;  yard has to actually receive the hull.
    cp CLASS_FRIGATE
    jr nz,@slv_nothing_learned
    ld a,(campaign_unlocks)
    or CAMP_UNLOCK_FRIGATE
    ld (campaign_unlocks),a
@slv_nothing_learned:

    ld de,ENT_FLAGS
    add hl,de
    ld (hl),0                           ; the hull is off the table
    pop af

    ld l,a
    ld h,0
    ld de,eco_class_cost
    add hl,de
    ld c,(hl)
    call eco_earn

    ;  Hands free. The next frame goes looking for another one, and spends the
    ;  order if there is none.
    ld hl,(eco_ent)
    ld de,ENT_TOW
    add hl,de
    ld (hl),ENT_NO_TARGET
    ret


; ----------------------------------------------------------------------------
;  slv_is_wreck -- is slot A a crippled enemy hull?
;  In : A = slot index
;  Out: CF set if it is ACTIVE and ENEMY and DISABLED
;  Uses: AF, DE, HL
; ----------------------------------------------------------------------------
SLV_WRECK_FLAGS     equ ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED

slv_is_wreck:
    call ent_addr
    ld de,ENT_FLAGS
    add hl,de
    ld a,(hl)
    and SLV_WRECK_FLAGS
    cp SLV_WRECK_FLAGS
    jr nz,@slv_not_a_wreck
    scf
    ret
@slv_not_a_wreck:
    or a
    ret


; ----------------------------------------------------------------------------
;  slv_find_wreck -- a hull to go and fetch
;  Out: CF set and A = its slot, or CF clear if there is nothing adrift
;  Uses: everything
;
;  The FIRST one, not the nearest, and that is eco_nearest_patch's bargain word
;  for word: a real search is a dist_manhattan per candidate per corvette per
;  frame, and there are at most SLV_WRECK_MAX candidates.
;
;  Two corvettes can therefore pick the same hull, and nothing stops them. It
;  is an inefficiency rather than a fault and it heals itself: the first to
;  arrive frees the slot, at which point the second one's slv_is_wreck comes
;  back false and it goes looking again. The alternative is a claim, and a
;  claim is state -- a mark on the wreck that goes stale the moment the corvette
;  that made it is shot down, leaving a hull nothing will ever tow.
; ----------------------------------------------------------------------------
slv_find_wreck:
    ld hl,entities + ENT_FLAGS
    ld de,ENT_SIZE
    ld b,ENT_MAX
    ld c,0
@slv_find_one:
    ld a,(hl)
    and SLV_WRECK_FLAGS
    cp SLV_WRECK_FLAGS
    jr z,@slv_found
    add hl,de
    inc c
    djnz @slv_find_one
    or a
    ret
@slv_found:
    ld a,c
    scf
    ret


; ============================================================================
;  Scratch
; ============================================================================
;  All of it in bank 4 with the code. None of it is state: the corvette's state
;  is ENT_ORDER and ENT_TOW, in the entity table, where the tests can follow it
;  by slot.
slv_ent:            defw 0
slv_index:          defb 0
slv_wreck:          defb 0
slv_wrecks:         defb 0
slv_corvette:       defb 0
