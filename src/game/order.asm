; ============================================================================
;  game/order.asm -- camera control and the move disc (Homeplanet.md section 9)
; ============================================================================
;  THE CODE FOR ALL OF THIS IS IN game/ordercmd.asm, WHICH IS IN BANK 4. What
;  is left here is the equates and the variables, in the low 16K where the
;  frame loop can read them. The note above the State section says why they
;  did not move with the routines.
;
;  Controlling a 3D fleet from a keyboard is the hardest part of the design.
;  The answer the document settles on is orders PER SQUADRON, never per ship,
;  and a cursor that moves on the Y=0 reference plane with a vertical line
;  showing its height -- Homeworld's move disc, which costs about twenty
;  pixels to draw.
;
;  Key assignment
;  --------------
;  Section 9 puts the move order on `M` and docking on `D`, but those keys now
;  belong to the squadron commands. So:
;
;      ENTER   open the move disc; ENTER again confirms, ESC cancels
;      R       return to the Mothership (was `D`)
;
;  ENTER doing both the opening and the confirming is not a compromise: the
;  document already had it as the confirm key, and a mode you enter and leave
;  with the same key is one less thing to remember.
;
;  While the disc is open the cursor keys drive IT, not the camera. That is
;  the document's intent and it is why the disc is a mode at all.
;
;  Disc movement is camera-relative, so "up" always means away from you. The
;  camera's yaw is rounded to one of eight octants and the step vector comes
;  out of a table -- no multiplies, and at 45 degrees of granularity the
;  difference from a true rotation is not perceptible on a 320-pixel screen.
; ----------------------------------------------------------------------------

CAM_YAW_STEP        equ 8               ; 256/8 = the 32 yaw steps of section 4.3
CAM_PITCH_STEP      equ 4               ; 16 steps
CAM_PITCH_MAX       equ 53              ; +/-75 degrees

DISC_STEP           equ 400             ; world units per frame held
DISC_STEP_DIAG      equ 283             ; the same length at 45 degrees

;  NOT divided by four with everything else, and that is the whole point. The
;  play area is however far the player may go, and leaving this hard against
;  the 16-bit edge while the content shrank into a quarter of the space is
;  where the extra room came from.
DISC_LIMIT          equ 30000           ; keep well inside the 16-bit world

;  Ink used to draw the disc and its height line.
DISC_INK_TOP        equ 1               ; the disc itself: friendly white
DISC_INK_STEM       equ 2               ; the line down to the plane

;  Which entity `,` and `.` have walked to. #FF is "nobody" -- a zeroed field
;  would name slot 0, which is a real ship. Up here with the other equates
;  rather than beside order_target_step, because that routine is in the bank
;  now and this has to be defined before it is read.
ORDER_NO_TARGET     equ #FF


; ============================================================================
;  State
; ============================================================================
;  THE CODE IS IN game/ordercmd.asm, AND IN BANK 4. This file is the equates
;  above and the variables below, and they stay in the low 16K because the
;  frame loop reads them -- phase4_draw_disc wants disc_pos, phase4_fly wants
;  squad_dest, moth_update wants cam_pan and moth_slot. None of those run with
;  a foreign bank under the window, so the split is not forced; what forces it
;  is that a variable in bank 4 has to be read with read_cpu rather than
;  read_ram, and every test that watches the player's controls watches these.
;  Code moves for free. Data costs a hundred test call sites.

;  Where each squadron is stationed. A move order rewrites the entry for the
;  selected squadron and the formation follows, so this is the ONLY thing an
;  order changes -- no per-ship destinations to keep in step.
;
;  AN ENTRY ONLY MEANS ANYTHING WHILE ITS SQUADRON HAS SHIPS. order_home seeds
;  all nine once at boot, but a squadron created by d, m, n, c or O takes its
;  station from the ship that created it -- see squad_born in game/squadcmd.asm
;  for the bug that came of reading a fixed table instead.
squad_dest:         defs SQUAD_MAX * 6, 0

disc_active:        defb 0
disc_pos:           defs 6, 0

;  Where the cursor keys are pointed: disc_pos while the move disc is open,
;  cam_pan while panning. One mover, two things to move.
disc_target:        defw disc_pos

;  How far the view has been dragged off whatever it is following.
cam_pan:            defs 6, 0
pan_active:         defb 0
disc_octant:        defb 0
disc_sign:          defb 0
disc_negate:        defb 0

order_paused:       defb 0

;  Set when the player has selected the Mothership with `0` rather than a
;  squadron. Kept separate from squad_sel: the Mothership is not squadron
;  zero, it is not in a squadron at all.
sel_mothership:     defb 0

;  0 = the tactical view, 1 = sensors.
view_sensors:       defb 0
VIEW_FAST_FORWARD   equ 3               ; simulation steps per frame in sensors

;  Which entity `,` and `.` have walked to, and the order waiting to be
;  written into the squadron's records.
order_target:       defb ORDER_NO_TARGET
order_step:         defb 0
order_pending:      defb 0
order_index:        defb 0
moth_slot:          defb 0

;  The camera's "right" direction on the Y=0 plane, per octant of yaw, already
;  scaled to one frame's movement. Forward is the entry two octants on.
order_octant_step:
    defw  DISC_STEP,           0
    defw  DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw  0,                   DISC_STEP
    defw -DISC_STEP_DIAG,      DISC_STEP_DIAG
    defw -DISC_STEP,           0
    defw -DISC_STEP_DIAG,     -DISC_STEP_DIAG
    defw  0,                  -DISC_STEP
    defw  DISC_STEP_DIAG,     -DISC_STEP_DIAG

;  Starting stations, copied into squad_dest once by order_init. Squadron 1
;  sits in the middle of the battle and the rest fan out around it, spread in
;  Z as well as X so ships sit at genuinely different depths and so at
;  different sprite tiers.
;
;  ONLY ROW 1 EVER APPLIES TO A NEW GAME: phase4_spawn_fleet puts the whole
;  fleet on squadron 1's station and nothing else has ships. The other eight
;  are the layout a RESTORED fleet fans out into, and they are no longer what
;  a squadron created mid-mission is given -- squad_born stations it on its own
;  ships instead. Reading these on creation is what made dividing a squadron
;  fling half of it 4500 to 11400 units across the map.
;  order_home -- the nine starting stations -- IS IN BANK 7 (game/screentext.asm),
;  copied into squad_dest by order_init through bank7_copy: 54 bytes of the low
;  16K read once, at boot, and the low 16K had none to spare the day the chase's
;  trampoline needed thirteen.

