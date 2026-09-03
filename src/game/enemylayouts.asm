; ============================================================================
;  game/enemylayouts.asm -- where the Vekhar are, IN BANK 7
; ============================================================================
;  Four hundred and seventy-six bytes of pure data that is read ONCE PER
;  MISSION, by mis_setup, with the world stopped. That is the exact shape
;  minigame.md's "cheapest lever left" describes: lib_load reads LIB_SECTORS --
;  13312 bytes -- into bank 7 every boot whether anything is in them or not, so
;  a table put here costs DISC.BIN nothing at all, and DISC.BIN's ceiling under
;  AMSDOS's #A700 is what has bound this project four times running.
;
;  It moved because the vortex chase would not fit otherwise. The chase is
;  about nine hundred bytes of bank 4 and there were five hundred and forty
;  three; this is where the rest came from, and it came out of DATA rather than
;  out of code, which is what every one of the previous four times did too.
;
;  HOW IT IS READ. mis_setup cannot simply LDIR out of here -- it is bank 4
;  code and the instant it pages bank 7 in it stops being the RAM it is
;  executing from. bank7_copy in sys/libload.asm does the paging from the low
;  16K, exactly as bank7_fetch does for the words and spr_blit_banked does for
;  the sprites, and mis_setup takes one seven-byte row at a time into mis_row.
;
;  A row at a time and not the whole layout, because the largest is eighty-four
;  bytes and mis_row is in the low 16K, which has about thirty to spare. Twelve
;  bank flips once a mission is not a cost worth naming.
;
;  THE PROSE BELOW CAME WITH THE DATA. The asserts that count the bytes between
;  these labels did not: ASSERT is evaluated where it stands and this file is
;  assembled after the code that would like to check it, so they are at the
;  bottom of src/main.asm with the rest of bank 7's.
; ----------------------------------------------------------------------------

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

;  COLD IRON and THE WATCH: a small picket that is nearly all capital. Six
;  ships, three of them frigates -- an interceptor does TEN to a frigate, so
;  this is the fight that cannot be won by out-trading and is the campaign
;  saying, in the only language it has, buy a bomber.
enemies_core:
    defw  -2000,   500,  4500
    defb  CLASS_FRIGATE
    defw   2000,  -500,  4500
    defb  CLASS_FRIGATE
    defw      0,     0,  5250
    defb  CLASS_FRIGATE
    defw  -3250,     0,  3750
    defb  CLASS_INTERCEPTOR
    defw   3250,     0,  3750
    defb  CLASS_INTERCEPTOR
    defw      0,  1000,  3000
    defb  CLASS_BOMBER
    defw  -1000, -1000,  6000
    defb  CLASS_INTERCEPTOR
    defw   1000,  1000,  6000
    defb  CLASS_INTERCEPTOR

;  THE FOUNDRY and THE ANVIL: four bombers, and they are not here for the
;  fleet. A bomber does 8 to a fighter and 44 to a Mothership, so an escort
;  that stays in formation watches them go past it. The interceptors are the
;  screen the bombers hide behind.
enemies_hammer:
    defw  -1500,   750,  5500
    defb  CLASS_BOMBER
    defw   -500,   750,  5500
    defb  CLASS_BOMBER
    defw    500,   750,  5500
    defb  CLASS_BOMBER
    defw   1500,   750,  5500
    defb  CLASS_BOMBER
    defw  -3000,  -250,  4000
    defb  CLASS_INTERCEPTOR
    defw  -1750,  -250,  4000
    defb  CLASS_INTERCEPTOR
    defw   -500,  -250,  4000
    defb  CLASS_INTERCEPTOR
    defw    750,  -250,  4000
    defb  CLASS_INTERCEPTOR
    defw   2000,  -250,  4000
    defb  CLASS_INTERCEPTOR
    defw   3250,  -250,  4000
    defb  CLASS_FRIGATE

;  THE CROSS, THRESHOLD and HOMEPLANET: the hardest thing the campaign fields,
;  and it is twelve ships because ENT_ENEMY_MAX is the largest picket plus one
;  whole wave and there is no room for a thirteenth. So the late campaign gets
;  harder by COMPOSITION rather than by count -- five frigates and three
;  bombers against the wall's two and two -- which is also the only way it
;  could get harder without the frame rate paying for it.
enemies_lance:
    defw  -2500,   750,  5000
    defb  CLASS_FRIGATE
    defw  -1250,   750,  5000
    defb  CLASS_FRIGATE
    defw      0,   750,  5000
    defb  CLASS_FRIGATE
    defw   1250,   750,  5000
    defb  CLASS_FRIGATE
    defw   2500,   750,  5000
    defb  CLASS_FRIGATE
    defw  -1750,  -750,  4000
    defb  CLASS_BOMBER
    defw      0,  -750,  4000
    defb  CLASS_BOMBER
    defw   1750,  -750,  4000
    defb  CLASS_BOMBER
    defw  -3500,     0,  5750
    defb  CLASS_INTERCEPTOR
    defw   3500,     0,  5750
    defb  CLASS_INTERCEPTOR
    defw  -1000, -1500,  6500
    defb  CLASS_INTERCEPTOR
    defw   1000,  1500,  6500
    defb  CLASS_INTERCEPTOR
enemies_lance_end:

