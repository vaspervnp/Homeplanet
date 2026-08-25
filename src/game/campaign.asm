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
    defb 0                              ; briefing text

    ; 2. ΤΕΦΡΑ -- back to the burned colony. No battle; only silence.
    defb "ASH",0,0,0,0,0,0,0,0,0
    defb 0
    defw mis_none
    defb 1
    defw patches_thin
    defb MIS_OBJ_ARRIVE
    defb 1                              ; briefing text

    ; 3. ΤΟ ΝΑΥΑΓΙΟ -- a debris field with a picket sitting in it.
    defb "THE WRECK",0,0,0
    defb 4
    defw enemies_picket
    defb 3
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 2                              ; briefing text

    ; 4. Ο ΣΤΑΘΜΟΣ -- the first attack on a static defence.
    defb "THE DEPOT",0,0,0
    defb 8
    defw enemies_line
    defb 2
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 3                              ; briefing text

    ; 5. ΤΟ ΝΕΦΕΛΩΜΑ -- sensors are down; they are already close.
    defb "THE NEBULA",0,0
    defb 8
    defw enemies_close
    defb 1
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 4                              ; briefing text

    ; 6. ΤΟ ΚΟΙΜΗΤΗΡΙΟ -- a dead fleet, and it is theirs.
    defb "THE GRAVES",0,0
    defb 6
    defw enemies_scatter
    defb 2
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 5                              ; briefing text

    ; 7. Η ΠΥΛΗ -- a Vekhar jump point, and the biggest fight so far.
    defb "THE GATE",0,0,0,0
    defb 12
    defw enemies_wall
    defb 2
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 6                              ; briefing text

    ; 8. HOMEPLANET -- arrival. Hold long enough to see it.
    defb "HOMEPLANET",0,0
    defb 10
    defw enemies_wall
    defb 0
    defw mis_none
    defb MIS_OBJ_SURVIVE
    defb 7                              ; briefing text

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


; ----------------------------------------------------------------------------
;  The reference plane's lattice: 4 x 4 points at Y=0, in bank 4 with the rest
;  of the static data.
; ----------------------------------------------------------------------------
grid_lattice:
gz = 0
    repeat 4
gx = 0
        repeat 4
            defw (gx * 2 - 3) * (GRID_SPACING / 2)
            defw 0
            defw (gz * 2 - 3) * (GRID_SPACING / 2)
gx = gx + 1
        rend
gz = gz + 1
    rend
grid_lattice_end:

    assert (grid_lattice_end - grid_lattice) / 6 == GRID_POINTS, "the lattice is not 16 points"


; ----------------------------------------------------------------------------
;  Briefing text (Homeplanet.md section 10).
;
;  Three lines a mission, uppercase because that is the whole of the font, and
;  short because the design asks for "λίγο κείμενο, πολλή σιωπή". The tone is
;  section 1's: lonely, quiet, and never explaining more than it has to.
; ----------------------------------------------------------------------------
mission_text_table:
    defw t1a, t1b, t1c
    defw t2a, t2b, t2c
    defw t3a, t3b, t3c
    defw t4a, t4b, t4c
    defw t5a, t5b, t5c
    defw t6a, t6b, t6c
    defw t7a, t7b, t7c
    defw t8a, t8b, t8c

t1a: defb "FIRST JUMP IN NINE GENERATIONS.",0
t1b: defb "THE MOTHERSHIP HOLDS SIXTY THOUSAND",0
t1c: defb "SLEEPERS. TAKE IT OUT AND BACK.",0

t2a: defb "THE COLONY IS STILL BURNING.",0
t2b: defb "THERE IS NOTHING HERE TO FIGHT.",0
t2c: defb "GATHER WHAT IS LEFT.",0

t3a: defb "A DEBRIS FIELD, AND SOMETHING",0
t3b: defb "SITTING IN IT THAT HAS NOT MOVED",0
t3c: defb "SINCE WE ARRIVED.",0

t4a: defb "A VEKHAR SUPPLY POST.",0
t4b: defb "IT WILL NOT COME TO US.",0
t4c: defb "TAKE THE FLEET IN.",0

t5a: defb "THE NEBULA BLINDS THE SENSORS.",0
t5b: defb "THEY WILL BE INSIDE THE FORMATION",0
t5c: defb "BEFORE ANYONE SEES THEM.",0

t6a: defb "A DEAD FLEET, DRIFTING.",0
t6b: defb "THE HULL MARKINGS ARE KERA.",0
t6c: defb "SOMEONE ELSE TRIED THIS BEFORE US.",0

t7a: defb "A VEKHAR JUMP GATE.",0
t7b: defb "EVERYTHING THEY HAVE LEFT IS HERE.",0
t7c: defb "THERE IS NO WAY ROUND IT.",0

t8a: defb "THE MAP WAS NOT WRONG.",0
t8b: defb "THE PLANET IS THERE, AND SO ARE THEY.",0
t8c: defb "HOLD LONG ENOUGH TO SEE IT.",0
