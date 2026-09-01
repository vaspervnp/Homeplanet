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
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 4                              ; briefing text

    ; 6. ΤΟ ΚΟΙΜΗΤΗΡΙΟ -- a dead fleet, and it is theirs.
    defb "THE GRAVES",0,0
    defb 6
    defw enemies_scatter
    defb 3
    defw patches_thin
    defb MIS_OBJ_CLEAR
    defb 5                              ; briefing text

    ; 7. Η ΠΥΛΗ -- a Vekhar jump point, and the biggest fight so far.
    defb "THE GATE",0,0,0,0
    defb 12
    defw enemies_wall
    defb 3
    defw patches_rich
    defb MIS_OBJ_CLEAR
    defb 6                              ; briefing text

    ; 8. HOMEPLANET -- arrival. Hold long enough to see it.
    defb "HOMEPLANET",0,0
    defb 10
    defw enemies_wall
    defb 2
    defw patches_thin
    defb MIS_OBJ_SURVIVE
    defb 7                              ; briefing text

mission_table_end:

    assert (mission_table_end - mission_table) / MIS_SIZE == MIS_COUNT, "the campaign is not eight missions"


; ----------------------------------------------------------------------------
;  Enemy layouts. Six bytes a ship: x, y, z.
;
;  All of these are a quarter of what they used to be. WORLD_SHIFT went from 8
;  to 6 to make the play area four times bigger, and the authored content had
;  to shrink by the same factor or every mission would have been laid out four
;  times larger on screen -- see src/math/proj.asm.
; ----------------------------------------------------------------------------
mis_none:

enemies_picket:
    defw  -2250, 0, 5000
    defw   -750, 0, 5000
    defw    750, 0, 5000
    defw   2250, 0, 5000

enemies_line:
    defw  -3000,  0, 5500
    defw  -2125,  0, 5500
    defw  -1250,  0, 5500
    defw   -375,  0, 5500
    defw    375,  0, 5500
    defw   1250,  0, 5500
    defw   2125,  0, 5500
    defw   3000,  0, 5500

;  Right on top of the fleet: the nebula hides them until it is too late.
enemies_close:
    defw  -1250,   500,  1750
    defw   1250,  -500,  1750
    defw  -1750,  -500, -1500
    defw   1750,   500, -1500
    defw      0,  1000,  2250
    defw      0, -1000, -2250
    defw  -2500,     0,     0
    defw   2500,     0,     0

enemies_scatter:
    defw  -4000,   750,  3500
    defw   4000,  -750,  3500
    defw  -4000,  -750, -3500
    defw   4000,   750, -3500
    defw      0,  1250,  5000
    defw      0, -1250, -5000

;  A wall across the jump point.
enemies_wall:
    defw  -3500,  750, 5000
    defw  -2250,  750, 5000
    defw  -1000,  750, 5000
    defw    250,  750, 5000
    defw   1500,  750, 5000
    defw   2750,  750, 5000
    defw  -3500, -750, 5000
    defw  -2250, -750, 5000
    defw  -1000, -750, 5000
    defw    250, -750, 5000
    defw   1500, -750, 5000
    defw   2750, -750, 5000


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


; ----------------------------------------------------------------------------
;  Briefing text (Homeplanet.md section 10).
;
;  BRIEF_LINES lines a mission, back to back and each zero-terminated, walked
;  by mis_brief_draw in the order they are written here -- so the ORDER is the
;  layout and there is no table of pointers. Uppercase because that is the
;  whole of the font, and short because the design asks for "λίγο κείμενο,
;  πολλή σιωπή". The tone is section 1's: lonely, quiet, and never explaining
;  more than it has to.
;
;  THE FIRST TWO SAID SOMETHING THE GAME STOPPED DOING, and that is what these
;  three lines of it are about. mis_gate will not let a mission be left before
;  its third wave, whatever the mission's own objective is -- so missions 1 and
;  2, which field no picket at all and complete on their first frame, are three
;  waves of Vekhar each. Mission 2's briefing said "THERE IS NOTHING HERE TO
;  FIGHT", which was true when it was written and is now the opposite of what
;  happens.
;
;  It is fixed in the FICTION rather than in the rule, because the rule is
;  universal and a universal rule wants saying once. What the jump gate
;  actually means is that arriving is heard: the Vekhar come to the noise, and
;  a fleet leaves when they have stopped coming. Mission 1 is where a player
;  meets that for the first time, so mission 1 is where it is said -- and
;  mission 2 then only has to stop denying it.
;
;  BRIEF_X is 8 pixels and TXT_CHAR_W_BYTES is 2, so a line has 39 characters
;  before txt_draw clips it at the edge of the screen. The longest here is 37.
; ----------------------------------------------------------------------------
mission_text:
    defb "FIRST JUMP IN NINE GENERATIONS.",0
    defb "SIXTY THOUSAND SLEEPERS ABOARD.",0
    defb "THEY HEARD IT. HOLD UNTIL THEY STOP.",0

    defb "THE COLONY IS STILL BURNING.",0
    defb "NOTHING OF THEIRS WAS WAITING HERE.",0
    defb "GATHER WHAT IS LEFT. THEY WILL COME.",0

    defb "A DEBRIS FIELD, AND SOMETHING",0
    defb "SITTING IN IT THAT HAS NOT MOVED",0
    defb "SINCE WE ARRIVED.",0

;  THIS ONE CARRIES A MECHANIC AND NOT ONLY A MOOD, and that is deliberate.
;  From here a dead Vekhar frigate is adrift at the edge of the field, and
;  towing it home with a Salvage Corvette is the only way the yard ever learns
;  to build one -- the build panel STEPS OVER a class it cannot offer, so a
;  player who is not told has nothing on the screen to wonder about. The
;  recurring lesson in this project is that a feature the player cannot find
;  does not exist; three lines of a briefing is the cheapest place to fix that.
    defb "A VEKHAR SUPPLY POST. A DEAD FRIGATE",0
    defb "IS ADRIFT AT THE EDGE OF IT.",0
    defb "SALVAGE THE HULL AND WE CAN BUILD IT.",0

    defb "THE NEBULA BLINDS THE SENSORS.",0
    defb "THEY WILL BE INSIDE THE FORMATION",0
    defb "BEFORE ANYONE SEES THEM.",0

    defb "A DEAD FLEET, DRIFTING.",0
    defb "THE HULL MARKINGS ARE KERA.",0
    defb "SOMEONE ELSE TRIED THIS BEFORE US.",0

    defb "A VEKHAR JUMP GATE.",0
    defb "EVERYTHING THEY HAVE LEFT IS HERE.",0
    defb "THERE IS NO WAY ROUND IT.",0

    defb "THE MAP WAS NOT WRONG.",0
    defb "THE PLANET IS THERE, AND SO ARE THEY.",0
    defb "HOLD LONG ENOUGH TO SEE IT.",0
