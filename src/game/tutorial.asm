; ============================================================================
;  game/tutorial.asm -- the tutorial stage: the equates and the state
; ============================================================================
;  THE CODE IS IN game/tutorialrun.asm, WHICH IS IN BANK 4. What is left here
;  is the layout numbers and the handful of bytes the frame loop and the tests
;  read, in the low 16K -- the same split game/order.asm and game/squad.asm
;  make, and for the same reason: code moves for free, data costs a hundred
;  test call sites. tut_active is read by demo_update and by wave_draw, and
;  tut_step is what every test in tests/test_tutorial.py asserts on; a byte in
;  the bank has to be read with read_bank4 and that has caught this project
;  three times.
;
;  WHAT IT IS
;  ----------
;  `T` on the title screen enters a stage that teaches each command in turn.
;  Sixteen steps in five acts, in dependency order -- you cannot command what
;  you cannot see, and you cannot fight before you can move -- and EVERY STEP
;  IS GATED ON THE PLAYER DOING THE THING rather than on pressing a key to
;  continue. That is the whole design; the rest is content.
;
;  WHAT IT IS NOT
;  --------------
;  IT IS NOT A MISSION, and that is the single most important thing about it.
;  It is reached from the title screen, which is exactly where a player with a
;  saved campaign arrives, so anything that touched mis_index, the fleet buffer
;  or FLEET.DAT would destroy a game in progress. Nothing here does:
;
;    * mis_jump is intercepted at its first instruction while tut_active is
;      set, so `J` can never reach fleet_save, fleet_disc_save or mis_setup;
;    * demo_update skips mis_update and wave_update entirely while the
;      tutorial runs, so there is no objective, no clock and no attack wave;
;    * leaving does not restore a snapshot -- it re-runs demo_init's whole
;      campaign setup, which RE-READS FLEET.DAT off the disc. The campaign is
;      derived from the disc rather than remembered, so the only way the
;      tutorial could damage it is by writing the disc, and it never does.
;      That is also what makes the test cheap: read mis_index and the fleet
;      back after leaving and you are reading the disc.
;
;  WHERE THE TEXT GOES
;  -------------------
;  HUD row C, which section 5.5 asked for as a "γραμμή μηνυμάτων" and which
;  carries HULL nnn% and INCOMING in a mission. The tutorial takes the whole
;  row for as long as it runs -- see tut_draw for why sharing it is not
;  possible: the row is 80 BYTES, which is forty characters, and HULL nnn%
;  plus INCOMING already occupy the first twenty of them.
; ----------------------------------------------------------------------------

;  How many steps there are. Asserted in src/main.asm against the size of
;  tut_steps, which is the table that actually decides it -- this is the copy
;  the code indexes with and the copy the "/16" on the screen agrees with.
TUT_STEPS           equ 16
TUT_STEP_SIZE       equ 4               ; a gate and an entry act, both words

;  ...and how many ships the tutorial's own fleet has, the Mothership apart.
;  A literal for the same reason TUT_STEPS is one: an equate derived from two
;  bank-4 labels is not resolvable where the low 16K needs to read it, and
;  src/main.asm checks this one against tut_fleet the way it checks the other
;  against tut_table.
TUT_SHIPS           equ 6

;  Row C, in BYTES across the line. The step counter sits at the right-hand
;  end, in ink 2, because it is chrome in exactly the sense RU and HULL are.
TUT_TEXT_X          equ 2
TUT_TEXT_CHARS      equ 32
TUT_NUM_X           equ 68
TUT_OF_X            equ 72

;  How far the camera has to be turned before step 1 is satisfied: a quarter
;  turn of the 256ths ENT_YAW counts in. order_camera moves CAM_YAW_STEP a
;  frame while the key is held, so that is eight game frames of holding.
TUT_YAW_TURN        equ 64

;  Two general-purpose latches. A gate that has to see something happen and
;  then UN-happen -- the sensor view toggled and toggled back, the disc opened
;  and confirmed, `A` given and the target gone -- keeps its "it happened" in
;  bit 0 here, and the pair of them is what the zoom step needs to see both
;  directions.
TUT_F_A             equ %00000001
TUT_F_B             equ %00000010


; ============================================================================
;  State
; ============================================================================
;  In the low 16K, deliberately -- see the head of this file.
; ----------------------------------------------------------------------------

;  Whether the tutorial owns the game. Read by demo_update (which skips the
;  mission clock and the waves) and by wave_draw (which hands row C over).
tut_active:         defb 0

;  Which step is showing, 0..TUT_STEPS-1. TUT_STEPS itself means "finished",
;  which cannot happen: the last step is terminal and is left by `J`.
tut_step:           defb 0

;  Set for the first frame of a step, so a gate can take its own reference
;  reading and an entry act can run once. tut_update clears it after the gate
;  has been given its chance at it, so a gate never has to remember to.
tut_fresh:          defb 0

;  The latches above, cleared on every step boundary.
tut_flags:          defb 0

;  Whatever the current step's gate is comparing against. A word, because
;  eco_ru is one; the byte gates use the low half.
tut_mark:           defw 0

;  ...and a six-byte one, for the gates that compare a POSITION -- the move
;  disc's station, which is the only thing an order changes.
tut_ref6:           defs 6, 0
