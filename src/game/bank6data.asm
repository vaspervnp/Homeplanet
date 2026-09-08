; ============================================================================
;  bank6data.asm -- read-once tables that moved to BANK 6 for the room
;
;  Both are copied down whole through bank6_copy and never fetched a line
;  at a time, so which bank they sit in is one byte in the copy routine's
;  caller. They were in bank 7 with the words until gfx/sprscale.asm's copy
;  of the scaled blitter needed the top of that bank; bank 6 had two
;  kilobytes idle.
; ============================================================================

; ----------------------------------------------------------------------------
;  tut_table -- the tutorial's steps: (gate, entry act) per row, in bank 4
;  code addresses. Data, so it lives in a bank; tut_row copies a row down
;  through bank6_copy.
; ----------------------------------------------------------------------------
tut_table:
    ;  --- Act 1: looking. No enemies; nothing can go wrong. -----------------
    defw tut_g_look,    tut_a_none
    defw tut_g_zoom,    tut_a_none
    defw tut_g_pan,     tut_a_none
    defw tut_g_view,    tut_a_none
    ;  --- Act 2: the fleet --------------------------------------------------
    defw tut_g_squad,   tut_a_none
    defw tut_g_info,    tut_a_none
    defw tut_g_move,    tut_a_none
    defw tut_g_form,    tut_a_none
    defw tut_g_split,   tut_a_none
    defw tut_g_dock,    tut_a_none
    ;  --- Act 3: the economy ------------------------------------------------
    defw tut_g_mine,    tut_a_none
    defw tut_g_build,   tut_a_none
    ;  --- Act 4: the fight --------------------------------------------------
    defw tut_g_target,  tut_a_enemy
    defw tut_g_fight,   tut_a_none
    defw tut_g_pause,   tut_a_none
    defw tut_g_fly,     tut_a_none
    defw tut_g_salvage, tut_a_none
    ;  --- Act 5: leaving ----------------------------------------------------
    defw tut_g_never,   tut_a_ready
tut_table_end:

; ----------------------------------------------------------------------------
;  order_home -- where the nine squadrons are stationed at boot, six bytes a
;  row: only row 1 is ever near the fleet, and the other eight are the layout
;  a RESTORED fleet fans out into. See "A squadron is born where its ships
;  are" in CLAUDE.md. Read once by order_init through bank6_copy.
; ----------------------------------------------------------------------------
order_home:
    defw      0,   500,      0           ; 1
    defw  -4500,  -750,   2000           ; 2
    defw   4500,   750,  -2000           ; 3
    defw  -3000,  -500,   4000           ; 4
    defw   3000,   625,  -4000           ; 5
    defw  -1500,  -750,  -3000           ; 6
    defw   1500,   500,   3000           ; 7
    defw  -6000,  -625,   1000           ; 8
    defw   6000,   750,  -1000           ; 9


; ----------------------------------------------------------------------------
over_fire_table:
    defb  -25,   -9, 3
    defb  -24,  -11, 5
    defb  -23,  -10, 4
    defb  -11,  -18, 3
    defb  -10,  -20, 5
    defb   -9,  -19, 4
    defb    3,  -13, 3
    defb    4,  -15, 5
    defb    5,  -14, 4
    defb   19,   -7, 3
    defb   20,   -9, 5
    defb   21,   -8, 4
    defb  -19,    4, 3
    defb  -18,    2, 5
    defb  -17,    3, 4
    defb   -4,    8, 3
    defb   -3,    6, 5
    defb   -2,    7, 4
    defb   13,   10, 3
    defb   14,    8, 5
    defb   15,    9, 4
    defb   -9,   19, 3
    defb   -8,   17, 5
    defb   -7,   18, 4
    defb   24,    7, 3
    defb   25,    5, 5
    defb   26,    6, 4
    defb    7,   21, 3
    defb    8,   19, 5
    defb    9,   20, 4
over_fire_table_end:
