; ============================================================================
;  game/briefings.asm -- the mission briefings, IN BANK 7 WITH THE SPRITES
; ============================================================================
;  Not in bank 4 with the rest of the mission data, and that is the whole
;  reason this file exists separately from game/campaign.asm.
;
;  WHY IT MOVED
;  ------------
;  DISC.BIN loads at #4000 and must finish below AMSDOS's workspace at #A700,
;  so it has 26368 bytes and no more. It is at 25985. Twenty missions -- what
;  improvements.md section 4 asks for -- costs about 1590: 240 of mission rows,
;  24 of fares, ~224 of enemy layouts, and ELEVEN HUNDRED of briefing text.
;  There are 383 bytes of headroom. The design entry estimated 900 for the
;  whole job, which was already wrong by half before the text was counted.
;
;  So the text is the two thirds of the problem, and it is also the part that
;  does not have to travel in the file at all.
;
;  WHERE IT WENT, AND WHY IT COST NOTHING
;  --------------------------------------
;  lib_load reads LIB_SECTORS -- twenty-six, 13312 bytes -- into each of banks
;  5, 6 and 7 at boot. Banks 5 and 6 hold three 4320-byte sprite libraries
;  each, 12960; bank 7 holds TWO, 8640. So 4672 bytes of every boot were
;  already being read into bank 7 and thrown away. Text put there is read by
;  code that already exists, off tracks that are already reserved, and it costs
;  DISC.BIN exactly nothing -- raw sectors are not in the file.
;
;  There is no new FDC code, which matters more than the bytes. This project's
;  own rule is that the controller is only to be believed after Retro Virtual
;  Machine has agreed, and lib_load is untouched.
;
;  THE COST IS THAT BANK 4 CANNOT READ ITS OWN BRIEFINGS
;  ----------------------------------------------------
;  mis_brief_draw lives in bank 4, and the instant it paged bank 7 into the
;  window it would vanish from under the program counter -- the same trap
;  gfx/sprite.asm's spr_blit_banked exists for, and the one the title screen
;  walked into the day the libraries repacked. brief_fetch does the paging from
;  the LOW 16K and copies the three lines into brief_buffer; see sys/libload.asm.
;
;  Everything below this line is unchanged from when it lived in campaign.asm.
; ----------------------------------------------------------------------------

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
    defb "SALVAGE THE HULL. WE CAN BUILD IT.",0

    defb "THE NEBULA BLINDS THE SENSORS.",0
    defb "THEY WILL BE INSIDE THE FORMATION",0
    defb "BEFORE ANYONE SEES THEM.",0

    defb "A DEAD FLEET, DRIFTING.",0
    defb "THE HULL MARKINGS ARE KERA.",0
    defb "SOMEONE ELSE TRIED THIS BEFORE US.",0

    defb "A VEKHAR JUMP GATE.",0
    defb "EVERYTHING THEY HAVE LEFT IS HERE.",0
    defb "THERE IS NO WAY ROUND IT.",0

    defb "THERE IS NOTHING IN THIS SYSTEM.",0
    defb "NO STAR WORTH THE NAME, NO ROCK.",0
    defb "THEY WILL COME ANYWAY. THEY ALWAYS D",0
    defb "THREE HULLS OUR GUNS BARELY MARK.",0
    defb "FIGHTERS WILL NOT PAY FOR THIS ONE.",0
    defb "BUILD SOMETHING THAT HURTS THEM.",0
    defb "THEY ARE CALLING AHEAD OF US NOW.",0
    defb "EVERY SYSTEM IS EXPECTING US.",0
    defb "TAKE THE RELAY. BUY US THE QUIET.",0
    defb "THE KERA MARKINGS AGAIN, AND MORE",0
    defb "OF THEM. WHOEVER THEY WERE, THIS",0
    defb "IS AS FAR AS THEY GOT.",0
    defb "A SHOAL OF BROKEN HULLS, DRIFTING.",0
    defb "IT HIDES THEM AS WELL AS US.",0
    defb "NOTHING IS SEEN UNTIL IT IS CLOSE.",0
    defb "THIS IS WHERE THE BOMBERS ARE MADE.",0
    defb "FOUR OF THEM CAME OUT TO MEET US.",0
    defb "THE ESCORT IS NOT WHAT THEY WANT.",0
    defb "EMPTY. NO STATION, NO PICKET.",0
    defb "THE ENGINES NEED THE HOURS.",0
    defb "HOLD HERE, AND LET THEM FIND US.",0
    defb "THE SAME HAMMER AS THE FOUNDRY.",0
    defb "THIS TIME THEY KNEW WE WERE COMING",0
    defb "AND THEY WAITED FOR US.",0
    defb "ONE LANE THROUGH, AND A LINE OF",0
    defb "FRIGATES LAID ACROSS IT.",0
    defb "THERE IS NO GOING ROUND. AGAIN.",0
    defb "A SMALL POST, TWO SHIPS ON WATCH.",0
    defb "EVERY ONE OF THEM IS HEAVY.",0
    defb "THEY ARE NOT GUARDING. THEY WAIT.",0
    defb "THE LAST OF THEIR OUTER LINE.",0
    defb "PAST IT THE MAP IS OURS AGAIN,",0
    defb "AND NINE GENERATIONS OLD.",0
    defb "EVERYTHING THEY HAVE LEFT IS HERE.",0
    defb "THEY HAVE NOWHERE TO FALL BACK TO",0
    defb "EITHER. NEITHER OF US DOES.",0

    defb "THE MAP WAS NOT WRONG.",0
    defb "THE PLANET IS THERE. SO ARE THEY.",0
    defb "HOLD LONG ENOUGH TO SEE IT.",0
mission_text_end:
