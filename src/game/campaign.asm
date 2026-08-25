; ============================================================================
;  game/campaign.asm -- the eight missions, as data (Homeplanet.md section 10)
; ============================================================================
;  IN BANK 4, with the sprites, which is where section 11 says mission data
;  and text belong. Nothing here is code; adding a mission is adding a row.
;
;  The premises are the design's. What is NOT here is the writing and the
;  balance: the briefing screens section 10 asks for ("σύντομο κείμενο
;  εισαγωγής σε στατική οθόνη Mode 1"), and enemy counts tuned by playing.
;  Those are authoring, not engineering, and inventing them alone would be
;  guessing at someone else's game.
; ----------------------------------------------------------------------------

mission_table:

    ; 1. Ο ΕΛΕΓΧΟΣ -- the test jump. Training: nothing to fight.
    defb "THE TEST",0,0,0,0
    defb 0
    defw mis_none
    defb 2
    defw patches_rich
    defb MIS_OBJ_ARRIVE
    defb 0

    ; 2. ΤΕΦΡΑ -- back to the burned colony. No battle; only silence.
    defb "ASH",0,0,0,0,0,0,0,0,0
    defb 0
    defw mis_none
    defb 1
    defw patches_thin
    defb MIS_OBJ_ARRIVE
    defb 0

    ; 3. ΤΟ ΝΑΥΑΓΙΟ -- a debris field with a picket sitting in it.
    defb "THE WRECK",0,0,0
    defb 4
    defw enemies_picket
    defb 3
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 0

    ; 4. Ο ΣΤΑΘΜΟΣ -- the first attack on a static defence.
    defb "THE DEPOT",0,0,0
    defb 8
    defw enemies_line
    defb 2
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 0

    ; 5. ΤΟ ΝΕΦΕΛΩΜΑ -- sensors are down; they are already close.
    defb "THE NEBULA",0,0
    defb 8
    defw enemies_close
    defb 1
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 0

    ; 6. ΤΟ ΚΟΙΜΗΤΗΡΙΟ -- a dead fleet, and it is theirs.
    defb "THE GRAVES",0,0
    defb 6
    defw enemies_scatter
    defb 2
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 0

    ; 7. Η ΠΥΛΗ -- a Vekhar jump point, and the biggest fight so far.
    defb "THE GATE",0,0,0,0
    defb 12
    defw enemies_wall
    defb 2
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 0

    ; 8. HOMEPLANET -- arrival. Hold long enough to see it.
    defb "HOMEPLANET",0,0
    defb 10
    defw enemies_wall
    defb 0
    defw mis_none
    defb MIS_OBJ_SURVIVE
    defb 0

mission_table_end:

    assert (mission_table_end - mission_table) / MIS_SIZE == MIS_COUNT, "the campaign is not eight missions"


; ----------------------------------------------------------------------------
;  Enemy layouts. Six bytes a ship: x, y, z.
; ----------------------------------------------------------------------------
mis_none:

enemies_picket:
    defw  -9000, 0, 20000
    defw  -3000, 0, 20000
    defw   3000, 0, 20000
    defw   9000, 0, 20000

enemies_line:
    defw -12000,  0, 22000
    defw  -8500,  0, 22000
    defw  -5000,  0, 22000
    defw  -1500,  0, 22000
    defw   1500,  0, 22000
    defw   5000,  0, 22000
    defw   8500,  0, 22000
    defw  12000,  0, 22000

;  Right on top of the fleet: the nebula hides them until it is too late.
enemies_close:
    defw  -5000,  2000,  7000
    defw   5000, -2000,  7000
    defw  -7000, -2000, -6000
    defw   7000,  2000, -6000
    defw       0,  4000,  9000
    defw       0, -4000, -9000
    defw -10000,      0,     0
    defw  10000,      0,     0

enemies_scatter:
    defw -16000,  3000,  14000
    defw  16000, -3000,  14000
    defw -16000, -3000, -14000
    defw  16000,  3000, -14000
    defw       0,  5000,  20000
    defw       0, -5000, -20000

;  A wall across the jump point.
enemies_wall:
    defw -14000,  3000, 20000
    defw  -9000,  3000, 20000
    defw  -4000,  3000, 20000
    defw   1000,  3000, 20000
    defw   6000,  3000, 20000
    defw  11000,  3000, 20000
    defw -14000, -3000, 20000
    defw  -9000, -3000, 20000
    defw  -4000, -3000, 20000
    defw   1000, -3000, 20000
    defw   6000, -3000, 20000
    defw  11000, -3000, 20000


; ----------------------------------------------------------------------------
;  Resource layouts. Eight bytes a patch: x, y, z, stock.
; ----------------------------------------------------------------------------
patches_rich:
    defw -26000,  1000, -6000
    defw 900
    defw  26000, -1000,  6000
    defw 900
    defw  -6000,  2000, 26000
    defw 700

patches_thin:
    defw  20000, -2000, -18000
    defw 400
    defw -20000,  2000,  18000
    defw 300
