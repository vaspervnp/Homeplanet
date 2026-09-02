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
    defb 3
    defw patches_rich
    defb MIS_OBJ_ARRIVE
    defb 0                              ; briefing text

    ; 2. ΤΕΦΡΑ -- back to the burned colony. No battle; only silence.
    defb "ASH",0,0,0,0,0,0,0,0,0
    defb 0
    defw mis_none
    defb 3
    defw patches_thin
    defb MIS_OBJ_ARRIVE
    defb 1                              ; briefing text

    ; 3. ΤΟ ΝΑΥΑΓΙΟ -- a debris field with a picket sitting in it.
    defb "THE WRECK",0,0,0
    defb 4
    defw enemies_picket
    defb 4
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 2                              ; briefing text

    ; 4. Ο ΣΤΑΘΜΟΣ -- the first attack on a static defence.
    defb "THE DEPOT",0,0,0
    defb 8
    defw enemies_line
    defb 3
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 3                              ; briefing text

    ; 5. ΤΟ ΝΕΦΕΛΩΜΑ -- sensors are down; they are already close.
    defb "THE NEBULA",0,0
    defb 8
    defw enemies_close
    defb 2
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 4                              ; briefing text

    ; 6. ΤΟ ΚΟΙΜΗΤΗΡΙΟ -- a dead fleet, and it is theirs.
    defb "THE GRAVES",0,0
    defb 6
    defw enemies_scatter
    defb 3
    defw patches_deep
    defb MIS_OBJ_CLEAR
    defb 5                              ; briefing text

    ; 7. Η ΠΥΛΗ -- a Vekhar jump point, and the biggest fight so far.
    defb "THE GATE",0,0,0,0
    defb 12
    defw enemies_wall
    defb 3
    defw patches_deep
    defb MIS_OBJ_CLEAR
    defb 6                              ; briefing text

    ; 8. HOMEPLANET -- arrival. Hold long enough to see it.
    defb "HOMEPLANET",0,0
    defb 10
    defw enemies_wall
    defb 2
    defw patches_deep
    defb MIS_OBJ_SURVIVE
    defb 7                              ; briefing text

mission_table_end:

    assert (mission_table_end - mission_table) / MIS_SIZE == MIS_COUNT, "the campaign is not eight missions"


; ----------------------------------------------------------------------------
;  Enemy layouts. MIS_ENEMY_SIZE bytes a ship: x, y, z, and the class.
;
;  The class column is read beside cbt_damage_matrix or it says nothing. What
;  the player owns is nearly all interceptors, and an interceptor does 24 to
;  another interceptor, 30 to a bomber and TEN to a frigate; a bomber does 8
;  back to a fighter and 44 to a Mothership. So:
;
;    interceptor  the fight the player already knows
;    bomber       ignores the escort and goes for the one ship that cannot be
;                 lost -- the answer is to intercept it, not to out-trade it
;    frigate      cannot economically be killed with fighters at all; it is
;                 what makes buying a bomber of one's own worth 60 RU
;
;  Kept SPARSE on purpose. Two frigates in a wall of twelve is a fight with a
;  problem in it; six is a wall a fighter fleet simply cannot get through, and
;  the campaign is measured, not argued -- tools/balance.py is what says which.
;
;  All of these are a quarter of what they used to be. WORLD_SHIFT went from 8
;  to 6 to make the play area four times bigger, and the authored content had
;  to shrink by the same factor or every mission would have been laid out four
;  times larger on screen -- see src/math/proj.asm.
; ----------------------------------------------------------------------------
mis_none:

;  The first fight of the campaign, and all four are interceptors on purpose:
;  the player meets the class column later, once the plain fight is understood.
enemies_picket:
    defw  -2250, 0, 5000
    defb  CLASS_INTERCEPTOR
    defw   -750, 0, 5000
    defb  CLASS_INTERCEPTOR
    defw    750, 0, 5000
    defb  CLASS_INTERCEPTOR
    defw   2250, 0, 5000
    defb  CLASS_INTERCEPTOR

;  A static defence, so the two frigates are the middle of it -- the thing the
;  line is built around, and the first time fighters meet a hull they cannot
;  chew through.
enemies_line:
    defw  -3000,  0, 5500
    defb  CLASS_INTERCEPTOR
    defw  -2125,  0, 5500
    defb  CLASS_INTERCEPTOR
    defw  -1250,  0, 5500
    defb  CLASS_INTERCEPTOR
    defw   -375,  0, 5500
    defb  CLASS_FRIGATE
    defw    375,  0, 5500
    defb  CLASS_FRIGATE
    defw   1250,  0, 5500
    defb  CLASS_INTERCEPTOR
    defw   2125,  0, 5500
    defb  CLASS_INTERCEPTOR
    defw   3000,  0, 5500
    defb  CLASS_INTERCEPTOR

;  Right on top of the fleet: the nebula hides them until it is too late.
;  Two bombers, and being already inside the screen is exactly what a bomber
;  wants -- they are here for the Mothership and the escort is behind them.
enemies_close:
    defw  -1250,   500,  1750
    defb  CLASS_INTERCEPTOR
    defw   1250,  -500,  1750
    defb  CLASS_INTERCEPTOR
    defw  -1750,  -500, -1500
    defb  CLASS_BOMBER
    defw   1750,   500, -1500
    defb  CLASS_BOMBER
    defw      0,  1000,  2250
    defb  CLASS_INTERCEPTOR
    defw      0, -1000, -2250
    defb  CLASS_INTERCEPTOR
    defw  -2500,     0,     0
    defb  CLASS_INTERCEPTOR
    defw   2500,     0,     0
    defb  CLASS_INTERCEPTOR

enemies_scatter:
    defw  -4000,   750,  3500
    defb  CLASS_INTERCEPTOR
    defw   4000,  -750,  3500
    defb  CLASS_INTERCEPTOR
    defw  -4000,  -750, -3500
    defb  CLASS_FRIGATE
    defw   4000,   750, -3500
    defb  CLASS_INTERCEPTOR
    defw      0,  1250,  5000
    defb  CLASS_BOMBER
    defw      0, -1250, -5000
    defb  CLASS_INTERCEPTOR

;  A wall across the jump point. The frigates ARE the wall, so they are in the
;  front rank; the bombers sit behind it and come through the hole.
;
;  Mission 8 fields the first TEN of these rather than all twelve, so the order
;  is what decides what it gets: both frigates and one bomber.
enemies_wall:
    defw  -3500,  750, 5000
    defb  CLASS_INTERCEPTOR
    defw  -2250,  750, 5000
    defb  CLASS_FRIGATE
    defw  -1000,  750, 5000
    defb  CLASS_INTERCEPTOR
    defw    250,  750, 5000
    defb  CLASS_INTERCEPTOR
    defw   1500,  750, 5000
    defb  CLASS_FRIGATE
    defw   2750,  750, 5000
    defb  CLASS_INTERCEPTOR
    defw  -3500, -750, 5000
    defb  CLASS_INTERCEPTOR
    defw  -2250, -750, 5000
    defb  CLASS_INTERCEPTOR
    defw  -1000, -750, 5000
    defb  CLASS_BOMBER
    defw    250, -750, 5000
    defb  CLASS_INTERCEPTOR
    defw   1500, -750, 5000
    defb  CLASS_INTERCEPTOR
    defw   2750, -750, 5000
    defb  CLASS_BOMBER
enemies_wall_end:

;  A FORGOTTEN CLASS BYTE IS THE FAILURE THIS FILE IS SHAPED TO HAVE, and it
;  would not look like one: the stride is seven, so one missing defb slides
;  every ship after it half a row along and the picket comes out at coordinates
;  nobody wrote, with classes read out of somebody else's Z. Counting the bytes
;  between the labels is the one check that catches it, and RASM can do it at
;  build time for nothing.
    assert enemies_line    - enemies_picket  ==  4 * MIS_ENEMY_SIZE, "enemies_picket is not four ships"
    assert enemies_close   - enemies_line    ==  8 * MIS_ENEMY_SIZE, "enemies_line is not eight ships"
    assert enemies_scatter - enemies_close   ==  8 * MIS_ENEMY_SIZE, "enemies_close is not eight ships"
    assert enemies_wall    - enemies_scatter ==  6 * MIS_ENEMY_SIZE, "enemies_scatter is not six ships"
    assert enemies_wall_end - enemies_wall   == 12 * MIS_ENEMY_SIZE, "enemies_wall is not twelve ships"


; ----------------------------------------------------------------------------
;  What it costs to LEAVE each mission. One word a mission, read by
;  mis_jump_fare, and deliberately a column rather than a field in the row
;  above: the fare is a curve, and a curve is something you want to be able to
;  see the shape of at a glance while you tune it.
;
;  Row N is the price of leaving mission N, so the last one is never charged --
;  there is nowhere to go from HOMEPLANET. It carries the dearest figure anyway
;  so that the shape reads honestly and so that MIS_JUMP_COST stays true.
;
;  Rising, because the treasury does. The first fare is above ECO_START_RU's
;  120 on purpose -- that is the whole of what the old flat thousand was FOR,
;  and it survives here: mission 1 cannot be left without buying a harvester
;  and mining with it. See the long note in game/mission.asm for the
;  measurement that killed the flat number.
; ----------------------------------------------------------------------------
mission_fare:
    defw 200                            ; 1. THE TEST
    defw 300                            ; 2. ASH
    defw 400                            ; 3. THE WRECK
    defw 500                            ; 4. THE DEPOT
    defw 600                            ; 5. THE NEBULA
    defw 700                            ; 6. THE GRAVES
    defw MIS_JUMP_COST                  ; 7. THE GATE -- the dearest
    defw MIS_JUMP_COST                  ; 8. HOMEPLANET -- never charged
mission_fare_end:

    assert (mission_fare_end - mission_fare) / 2 == MIS_COUNT, "the fare curve is not one word a mission"


; ----------------------------------------------------------------------------
;  THE DERELICT -- one position, shared by every mission that fields it,
;  because it is the same hull still adrift rather than a new one each time.
;  game/mission.asm has the rules and mis_spawn_derelict places it.
;
;  Two things decided where it is, and the first was got WRONG first and is
;  the lesson CLAUDE.md's "measure what is on the screen, not what the geometry
;  could reach" already states.
;
;  It has to be ON SCREEN at the zoom every mission opens on. The obvious test
;  is the clip -- proj_deltas rejects a world delta past PROJ_V_LIMIT per axis,
;  so -7000 and -6500 both pass it with room to spare. They were the first
;  position and the ship was NOT DRAWN: inside the visible cube is not the same
;  as inside the frustum, because proj_mag deliberately magnifies by a little
;  more than fills the width, so the outer RIM of the radius clips off the
;  sides. Two axes near the rim at once is the corner that goes. Measured, with
;  the derelict alone on the board and phase4_visible read at each zoom step,
;  (-7000, 250, -6500) first appeared at step 8 -- three presses of `X` past
;  where the player starts. A derelict the briefing points at and the screen
;  does not show is worse than none.
;
;  And it has to be on the OPPOSITE side from the picket: every enemy layout
;  above is at +z, so this sits at -z and fetching it is a decision to send a
;  corvette AWAY from the battle rather than something that happens on the way
;  in. It is still a real journey -- about 9,000 units of Manhattan distance
;  from the Mothership, there and back.
; ----------------------------------------------------------------------------
derelict_pos:
    defw  -5500,   250, -3500


; ----------------------------------------------------------------------------
;  Resource layouts. Eight bytes a patch: x, y, z, stock.
;  The positions are world units and are quartered with everything else; the
;  STOCK is RU and is not a coordinate, so it is untouched.
;
;  EVERY MISSION FIELDS SOME. Section 7 makes the economy a running choice --
;  build a harvester or build a fighter, mine this field or hold the line --
;  and a choice that only exists in five missions out of eight is not one.
;  Three missions used to field one patch or none at all, which meant the
;  harvesters were baggage for a third of the campaign.
;
;  The two layouts are the only difference that matters: a rich mission can
;  pay for a capital ship out of what is on the map, a thin one cannot.
;
;  EVERY STOCK IS SIX TIMES WHAT IT WAS, and that is the yard's arithmetic
;  rather than the map's. A rich mission used to carry 3200 RU in the ground,
;  which is twelve Interceptors or thirteen Harvesters -- so the build panel
;  offered seven classes and the map could only ever pay for the bottom of the
;  list. Six times is inside the five-to-ten the design owner asked for and it
;  is what makes a ten-deep queue of mixed classes a thing a player can
;  actually fill: 19200 RU on a rich map is seventy-six Destroyers' worth, so
;  what to build stops being decided by what is affordable.
;
;  The stock is a WORD and every figure here is far inside one; the mining
;  clamp in eco_harvester_step is what keeps it from going below zero and
;  wrapping to 65534, and it is unchanged. What six times DOES reach is the
;  other end -- see ECO_RU_MAX in game/economy.asm, which is the four-digit
;  readout's ceiling and not the word's.
; ----------------------------------------------------------------------------
patches_rich:
    defw  -6500,   250, -1500
    defw 5400
    defw   6500,  -250,  1500
    defw 5400
    defw  -1500,   500,  6500
    defw 4200
    defw   2500,  -500, -6000
    defw 4200

patches_thin:
    defw   5000,  -500, -4500
    defw 2400
    defw  -5000,   500,  4500
    defw 1800
    defw    750,   250, -5500
    defw 1500

;  THE LATE CAMPAIGN: FEWER PATCHES, MUCH DEEPER ONES.
;
;  A mission is three to five minutes now, because mis_gate will not let one be
;  left before its third wave -- and three harvesters working that long mine
;  more than a thin field holds. Measured with tools/balance.py at its old
;  hundred-second linger the stock never ran out and this set would have been
;  pointless; measured over a real mission it is the binding constraint.
;
;  Deeper rather than MORE, and that is the whole shape of it. Section 1's
;  campaign is a fleet that only ever shrinks, and a late mission scattered
;  with plentiful little fields would read as the war getting easier. Two or
;  three large finds reads as scraping: there is more in each one, and there is
;  nowhere else to go.
patches_deep:
    defw  -6000,   500, -2500
    defw 9000
    defw   6000,  -500,  2500
    defw 9000
    defw   -750,   250,  6000
    defw 7500
    defw   2500,  -250, -6000
    defw 7500
