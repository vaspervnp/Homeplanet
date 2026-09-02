; ============================================================================
;  HOMEPLANET -- Amstrad CPC 6128, Mode 1
; ============================================================================
;  Build with:  make          (see CLAUDE.md)
;
;  Phase 4: entities and squadrons. A fleet flies in formation while the
;  camera orbits; the player carves it into squadrons from the keyboard.
; ----------------------------------------------------------------------------

    include "equ/hardware.asm"
    include "equ/memmap.asm"

; ----------------------------------------------------------------------------
;  DIAG_DISC -- the disc diagnostic. SET THIS TO 0 TO TURN IT OFF.
;
;  One edit, here, and everything below vanishes: the extra status bytes the
;  controller hands back, the seek-timeout counter, the snapshots, the panel
;  on the title screen and the include in bank 4. Nothing else has to change.
;
;  It is here because the ships come up as solid white boxes on Retro Virtual
;  Machine and are correct under cpcemu, which means lib_load fails on real
;  hardware and succeeds on the emulator -- and the emulator cannot be asked
;  why, because it resolves the controller's execution phase synchronously and
;  will therefore agree with any timing assumption this code makes. So the
;  machine has to say it out loud instead. See src/game/libdiag.asm for what
;  the five lines on the title screen mean.
DIAG_DISC           equ 0

; ----------------------------------------------------------------------------
;  RASM's BANK directive, and why the build needs it now.
;
;  There are four 16K images in this file and three of them are assembled at
;  #4000: the game's bank 4, and banks 5, 6 and 7, which hold all eight ship
;  classes between them -- three, three and two. A plain second `org #4000`
;  is an error ("located in a previous ORG section") because RASM has one
;  output image per bank -- so each gets its own workspace.
;
;  Labels are shared across banks, which is the whole point: class_tiers is in
;  bank 0 (the low 16K) and holds the addresses of sprites in banks 2-4, and
;  those resolve to #4000-#7FFF as they should, because that is where the
;  window will be when they are paged in.
; ----------------------------------------------------------------------------
    BANK 0                              ; the low 16K, #0040-#3FFF

    org CODE_START
    run game_main

; ============================================================================
;  Entry point
; ============================================================================
game_main:
    di
    ld sp,STACK_TOP                     ; before any CALL, obviously
    call sys_boot                       ; one-way: firmware is gone after this

    call demo_init

@frame_loop:
    call demo_update                    ; draw into the back buffer
    call demo_wait_frame                ; hold the loop to 4 VSYNCs = 12.5 fps
    call scr_wait_vsync
    call scr_flip                       ; back becomes front
    jr @frame_loop


; ============================================================================
;  Subsystems
; ============================================================================
    include "sys/boot.asm"
    include "sys/irq.asm"
    include "sys/screen.asm"
    include "sys/keyboard.asm"
    include "sys/rand.asm"
    include "sys/sound.asm"
    include "sys/fdc.asm"
    include "sys/libload.asm"
    include "math/mul.asm"
    include "math/cam.asm"
    include "math/proj.asm"
    include "gfx/sprite.asm"
    include "gfx/text.asm"
    include "gfx/line.asm"
    include "gfx/mark.asm"
    include "game/entity.asm"
    include "game/squad.asm"
    include "game/shipclass.asm"
    include "game/formation.asm"
    include "game/order.asm"
    include "game/combat.asm"
    include "game/economy.asm"
    include "game/mission.asm"
    include "demo/phase4.asm"
;  After phase4, because it draws into the HUD's strip and takes its layout
;  equates from there. It is the frame loop's simulation like combat and the
;  economy, so it stays in the low 16K with them rather than going to bank 4.
    include "game/waves.asm"
;  The `I` page's layout and its one flag. Its CODE went to bank 4 the day the
;  fleet's ceiling needed the room -- see game/squadinforun.asm. Still after
;  waves.asm because the equates sit beside wave_pct_of's caller, and after
;  phase4 for HUD_HP_ALARM and the pens.
    include "game/squadinfo.asm"
;  The tutorial's equates and the dozen bytes of it the frame loop and the
;  tests read. Its CODE is in bank 4 -- see game/tutorialrun.asm -- and the
;  split is game/order.asm's: data down here so read_ram works, code up there
;  because it runs on a keypress and at the two ends of a frame.
    include "game/tutorial.asm"

; ----------------------------------------------------------------------------
;  Generated lookup tables. Must come last: they are page-aligned and would
;  otherwise push the hand-written code around on every regeneration.
; ----------------------------------------------------------------------------
;  Where the HAND-WRITTEN code ends, which is the number that matters when the
;  low 16K fills up: gen/tables.asm is page-aligned, so `free:` below only
;  moves in 256-byte steps and says nothing about how close the next byte is to
;  costing a whole page.
    print "hand-written code ends at", {hex}$
    include "gen/tables.asm"

code_end:

; ----------------------------------------------------------------------------
;  The six arrays that are ENT_MAX long, and they are here rather than beside
;  their own code for ONE reason: everything above code_end costs address
;  space and costs DISC.BIN NOTHING.
;
;  They held nothing at boot even when they were in the file. `entities` is
;  wiped by ent_clear_all before demo_reset spawns a fleet into it; the three
;  below it are rebuilt from scratch every frame off phase4_visible, which
;  phase4_project zeroes and counts back up; and the two rectangle lists are
;  read only as far as their own count byte, which does start at zero in the
;  image. So the two thousand bytes of `defs ..., 0` were two thousand bytes of
;  ZEROS carried across a disc into a file that has to finish under #A700, for
;  nothing at all -- and they were the fleet's ceiling, because they are also
;  the biggest thing in the tightest 16K there is. This is what paid for
;  ENT_PLAYER_MAX doubling.
;
;  IT IS THE SAME TRICK AS fleet_block AND class_standin, which sit after
;  bank4_end for exactly this reason. The difference is that the low 16K has
;  no equivalent of `bank4_end`, so the boundary is code_end and the arrays
;  have to be declared HERE, after the include of the tables, rather than in
;  game/entity.asm and demo/phase4.asm where they read better.
;
;  What it costs: the tests' scratch is derived from a symbol, and that symbol
;  is now low_end and not CODE_END. tests/harness.py says so.
; ----------------------------------------------------------------------------
entities:           defs ENT_MAX * ENT_SIZE
phase4_vis:         defs ENT_MAX * PHASE4_VIS_SIZE
phase4_order:       defs ENT_MAX * 2        ; index, and its depth beside it
phase4_gcount:      defs ENT_MAX

;  The one line being drawn, copied out of BANK 7 by bank7_fetch. Three screens
;  share it: the mission briefing, the orders menu and the help page.
;
;  IN THE LOW 16K, AND THAT IS NOT A PREFERENCE. It was written into bank 4
;  first, with fleet_block and class_standin, on the reasoning that space after
;  bank4_end is free -- and bank 4 is THE WINDOW. bank7_fetch does its copying
;  with bank 7 paged in, so every byte went straight back into bank 7 on top of
;  the text being read, and the buffer was still zero when bank 4 came back.
;  The briefing drew its title and three blank lines.
;
;  Up here it costs address space and no file, exactly like the entity arrays
;  above it: everything past code_end is outside the image DISC.BIN carries.
;  ONE LINE, not all three, and that is the low 16K being the tight one again.
;  Three lines is 111 bytes at the longest text the screen can hold, which took
;  `free:` to 396 -- and the floor is about 450, because tests/test_sound.py
;  puts 384 bytes of stub above LOW_END and harness another 0x60. A dozen test
;  classes with nothing to do with briefings fail below it.
;
;  Fetching per line costs a bank flip a row on screens where nothing else is
;  running at all, which is the cheapest 71 bytes ever bought -- and it is what
;  let the menu's and the help page's words follow the briefings across.
B7_BUF_SIZE         equ 40
bank7_line:         defs B7_BUF_SIZE
;  ...and the two dirty-rectangle lists, which are ENT_MAX-shaped as well
;  (PHASE4_RECT_SLOTS), so they grew with the fleet too.
phase4_rects_a:     defs PHASE4_RECT_SLOTS * 4
phase4_rects_b:     defs PHASE4_RECT_SLOTS * 4
low_end:

; ----------------------------------------------------------------------------
;  Table layout invariants.
;
;  The lookup routines index these tables by page register -- mul_u8 does
;  `inc h : inc h` to cross from the low plane to the high one, scr_line_addr
;  does a single `inc h`. That only works if the generator lays them out
;  exactly so. Check it here rather than at the point of use, because RASM
;  evaluates ASSERT where it stands and the tables are included last.
; ----------------------------------------------------------------------------
    assert qsq_hi == qsq_lo + 512,          "quarter-square planes are not 512 bytes apart"
    assert scr_line_hi == scr_line_lo + 256, "screen line planes are not on consecutive pages"
    assert (qsq_lo & 255) == 0,             "qsq_lo is not page aligned"
    assert (scr_line_lo & 255) == 0,        "scr_line_lo is not page aligned"
    assert (recip & 255) == 0,              "recip is not page aligned"

;  sin7 is deliberately NOT in that list any more. It is 65 bytes -- one
;  quadrant -- and cam_sin adds the index rather than paging it, which is what
;  makes the odd size affordable.
    assert SIN7_ENTRIES == TRIG_QUARTER + 1, "sin7 is not one whole quadrant"

;  proj_scale assembles with the NEUTRAL zoom step already in its instruction
;  stream -- two `add hl,hl`, no x3 tail, and PROJ_V_BIAS in its range check --
;  so that anything which pokes cam_dist without going through the zoom (the
;  differential tests, mostly) gets plain >>WORLD_SHIFT behaviour. That only
;  holds while the default step really is the plain one, and the shift itself
;  is the Python model's to decide, so check both here: the model is included
;  further down than the code that depends on it, and ASSERT is evaluated
;  where it stands.
    assert PROJ_V_BIAS == 1 << (WORLD_SHIFT - 1), "proj_scale's range check does not match WORLD_SHIFT"
    assert CAM_ZOOM_DEFAULT_SHIFT == WORLD_SHIFT, "the default zoom step is not the neutral one"
    assert CAM_ZOOM_DEFAULT < CAM_ZOOM_STEPS, "the default zoom step is off the ladder"
    assert CAM_ZOOM_GROUP_FROM <= CAM_ZOOM_STEPS, "grouping starts past the last zoom step"

;  proj_mag is the other half of a zoom record and it lives in a DIFFERENT
;  routine, so three things have to agree about its size: the slot, the record,
;  and the LDIR in order_apply_zoom. Get it wrong and the zoom does not fail
;  visibly -- it patches six bytes of somebody else's code.
    assert proj_mag_end - proj_mag == 6, "proj_mag is not six patchable bytes"
    assert CAM_ZOOM_RECORD == 14 + (proj_mag_end - proj_mag), "a zoom record does not fit proj_scale and proj_mag"

;  ...and the six it assembles WITH have to be the default step's, the way
;  proj_scale's ladder is. That one cannot be asserted here -- RASM will not
;  read back its own output -- so it is a test instead:
;  tests/test_phase1.TestTheAssembledDefault.

;  The projection centres on the middle of the PLAYFIELD, which is not the
;  middle of the screen: the context bar and the HUD each own a strip. Checked
;  against the two equates that actually define those strips, and against the
;  model's own copy -- all three are literals, and nothing else would notice if
;  one of them moved.
    assert PROJ_CENTRE_Y == PROJ_CENTRE_Y_MODEL, "the model and the code disagree about the centre line"
    assert PROJ_CENTRE_Y == (CTX_BAR_H + HUD_TOP) / 2, "the projection is not centred on the playfield"

;  gfx/mark.asm sizes its patch cache before game/economy.asm has been read --
;  RASM evaluates a `defs` where it stands -- so it states the count itself and
;  the two are checked against each other here, once both are in scope.
    assert MARK_PATCHES == ECO_PATCH_COUNT, "the marker cache does not hold every resource patch"

;  moth_update borrows the last zoom step because proj_scale's range check is
;  patched out there -- see the header in gfx/mark.asm. If a wider step is ever
;  added with a check back in it, the Mothership indicator stops working for
;  exactly the distances it exists to cover.
    assert CAM_ZOOM_LAST_RADIUS == 32768, "the widest zoom step no longer covers the whole world"

; ----------------------------------------------------------------------------
;  Attack waves (game/waves.asm) and the hull readout that shares their number.
; ----------------------------------------------------------------------------
;  ENT_F_WAVE has to be its own bit. It is ORed into a flags byte that already
;  carries three, and mis_count_enemies masks all four together -- an overlap
;  would make every wave ship read as active, hostile or crippled depending on
;  which bit it collided with, and two of those are silent.
    assert (ENT_F_WAVE & (ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_DISABLED)) == 0, "ENT_F_WAVE collides with another entity flag"

;  ...and the same argument for ENT_F_DISABLED, which now has a writer. A wreck
;  is ACTIVE and ENEMY and DISABLED all at once, and mis_count_enemies masks all
;  four bits together to decide whether it counts towards a CLEAR objective. An
;  overlap would make a wreck read as an ordinary hostile, and a CLEAR mission
;  would become uncompletable the moment the fleet crippled the last one.
    assert (ENT_F_DISABLED & (ENT_F_ACTIVE + ENT_F_ENEMY + ENT_F_WAVE)) == 0, "ENT_F_DISABLED collides with another entity flag"

;  slv_survey reaches ENT_CLASS from the flags byte with two DECs, exactly as
;  wave_hp_add does -- the assert for that is a dozen lines down and this one
;  names the second reader, so that moving the field fails with both.
    assert ENT_CLASS == ENT_FLAGS - 2, "slv_survey reaches ENT_CLASS with two DECs"

;  slv_make_wreck writes ENT_SQUAD, ENT_ORDER and ENT_TARGET with two INCs
;  between them. They are consecutive in section 7's record; separate them and
;  the wreck comes out in a squadron, under an order, aiming at slot 0.
    assert ENT_ORDER == ENT_SQUAD + 1, "slv_make_wreck walks ENT_SQUAD into ENT_ORDER"
    assert ENT_TARGET == ENT_ORDER + 1, "slv_make_wreck walks ENT_ORDER into ENT_TARGET"

;  ENT_TOW is one of the four bytes section 7 reserved for a packed destination,
;  and ENT_LOAD is another. They must not be the same byte: a harvester's hold
;  and a corvette's tow would then be one field, and the class that is both does
;  not exist today -- which is exactly the kind of thing that stops being true
;  quietly.
    assert ENT_TOW != ENT_LOAD, "the tow and the harvester's hold share a byte"
    assert ENT_TOW < ENT_SIZE, "ENT_TOW is outside the entity record"

;  Mission 8's objective is MIS_OBJ_SURVIVE, which is a countdown on the same
;  mis_timer the waves run off. If the first wave could land before that
;  countdown expired, the last mission of the campaign would be a different
;  game from the one it was authored as -- and nothing at run time would say so.
    assert WAVE_FIRST_TICKS > MIS_SURVIVE_TICKS, "the first wave lands before a SURVIVE objective can be met"

;  The spacing is WAVE_GAP_MIN + 12 * a byte, and BOTH ENDS ARE NOW IN 50 Hz
;  TICKS rather than in game frames -- so they are wall-clock seconds that
;  cannot drift when the frame rate does. It has been set three times; the
;  first two were frames and both went silently wrong. See game/mission.asm.
;
;  The lower bound guards the thing it always guarded: a gap shorter than the
;  time it takes to kill a wave is not "more often", it is a queue that never
;  empties -- the entity table fills and the frame rate collapses, which reads
;  as a fault rather than as a difficulty setting. A wave takes twenty to forty
;  seconds to resolve, so half a minute is the floor and a minute is the ask.
    assert WAVE_GAP_MIN >= 50 * 30, "the shortest gap between waves is under half a minute"
    assert WAVE_GAP_MIN + 255 * 12 <= 50 * 122, "the longest gap between waves is over two minutes"

    assert WAVE_HULL_MIN + WAVE_HULL_SPAN <= 255, "a wave ship's hull does not fit a byte"

;  wave_health walks a pointer along the ENT_FLAGS byte and reaches the other
;  two fields it needs with two DECs, which is what takes it from 174 T-states
;  a slot to 57. That the three are adjacent is section 7's record layout being
;  convenient rather than anything having been designed, so say so here: move
;  ENT_CLASS and the fleet's hull is silently summed out of ENT_SPEED.
    assert ENT_HULL == ENT_FLAGS - 1, "wave_hp_add reaches ENT_HULL with one DEC"
    assert ENT_CLASS == ENT_FLAGS - 2, "wave_hp_add reaches ENT_CLASS with two DECs"

;  The third HUD row. It has to be inside the strip the HUD owns -- otherwise
;  the tactical view draws over it and the dirty-rectangle erase scrubs it --
;  and clear of row A, which nothing at run time would notice.
    assert HUD_ROW_C_Y >= HUD_TOP, "the hull row is outside the strip the HUD owns"
    assert HUD_ROW_C_Y + TXT_CHAR_H <= HUD_ROW_A_Y, "the hull row runs into the squadron list"

;  ...and its two fields against each other and against the screen edge.
;  txt_draw clips at the edge and says nothing, so these are the only guard.
    assert HUD_HP_X + HUD_HP_CHARS * TXT_CHAR_W_BYTES <= HUD_SAY_X, "the hull figure runs into INCOMING"

;  The two that measure a STRING are further down, after the bank-4 includes:
;  the hull row's words went across when the Mothership's own figure pushed the
;  low 16K past its floor, and an ASSERT is evaluated where it stands.
    assert HUD_HP_ALARM < 100, "the hull alarm threshold is not a percentage"

;  Row B, for the same reason. The yard grew a fifth character when the build
;  queue landed -- the marker, the three-letter tag and the depth -- and the
;  only thing between it and "M n JUMP" is this line. phase4_yard_text is
;  measured rather than counted so that widening the field again cannot pass.
    assert HUD_YARD_X + (phase4_hud_text - phase4_yard_text - 1) * TXT_CHAR_W_BYTES <= HUD_MIS_X, "the yard readout runs into the mission number"

;  ...and the queue's depth is drawn as ONE digit, which is only enough while
;  the waiting line cannot reach ten. The slipway holds the tenth order, so it
;  cannot -- but this is the line that says so.
    assert ECO_QUEUE_WAIT < 10, "the queue is too deep to show in one character"
    assert ECO_QUEUE_MAX == ECO_QUEUE_WAIT + 1, "the slipway is not counted as one of the queue's orders"

; ----------------------------------------------------------------------------
;  The entity table's two regions (game/entity.asm).
;
;  Nothing at run time would report either of these going wrong. A player
;  region too small for the fleet it is handed silently drops ships at setup;
;  a hostile region too small for a wave silently stops the waves, which is
;  the very bug the partition exists to end.
; ----------------------------------------------------------------------------
    assert ENT_PLAYER_MAX + ENT_ENEMY_MAX == ENT_MAX, "the two entity regions do not add up to the table"
    assert ENT_PLAYER_MAX > 0, "the fleet has no slots"
    assert ENT_ENEMY_MAX > 0, "the enemy has no slots"

;  The starting fleet and its Mothership are written straight into slots
;  0..PHASE4_SHIPS by phase4_spawn_fleet, without asking for a free one.
    assert PHASE4_SHIPS + 1 <= ENT_PLAYER_MAX, "the starting fleet does not fit the player's region"

;  ...and a player who fills the yard from the first frame of mission 1 must
;  not be refused by a ceiling they cannot see the reason for. This is the
;  number that says twenty-eight rather than "some slots for growth".
    assert PHASE4_SHIPS + 1 + ECO_QUEUE_MAX <= ENT_PLAYER_MAX, "a full build queue on the starting fleet would not fit"

;  ...and the formation has to have somewhere to put them. `O` can leave every
;  ship the player owns in one squadron, so a shape short of slots does not
;  fail -- it flies the overflow to a point another ship is already at, which
;  is invisible from the outside and was the normal case at FORM_SLOTS 16 the
;  moment ENT_PLAYER_MAX doubled. The Mothership is squadron 0, so the largest
;  a real squadron can be is one short of the region.
    assert FORM_CAPACITY >= ENT_PLAYER_MAX - 1, "a squadron can be bigger than its formation has slots for"

;  One whole wave has to be able to land, or the pressure the waves exist to
;  apply is capped by arithmetic rather than by the fight. The picket it lands
;  ON is checked from the mission table itself, in tests/test_campaign.py --
;  RASM cannot take the largest of eight rows of data.
    assert WAVE_MAX <= ENT_ENEMY_MAX, "a full attack wave does not fit the hostile region"

; ----------------------------------------------------------------------------
;  The low 16K is the whole world below the bank window. If we ever spill past
;  #4000 the next thing we would overwrite is paged sprite data, and the
;  symptom would be baffling. Fail the build instead -- and leave room for the
;  stack, which is growing down from #4000 to meet us.
; ----------------------------------------------------------------------------
;  PRINTED BEFORE THE ASSERT, deliberately: RASM stops at the failing assert,
;  and "code + tables overflow into the stack" without a number is a question
;  rather than an answer. The figure is negative when it fails, which is
;  exactly how much has to come back out.
    print "code+tables:", {hex}CODE_START, "..", {hex}code_end, " image:", code_end - CODE_START
    print "  + entity arrays to", {hex}low_end, " free:", CODE_LIMIT - STACK_SIZE - low_end

;  low_end and not code_end: the arrays above the image take address space
;  even though they take no file, and it is the ADDRESS that collides with the
;  stack. tests/harness.py takes its scratch from the same symbol, so this
;  figure has to stay above about 450 or a dozen test classes with nothing to
;  do with the change start failing for want of somewhere to put a stub.
    assert low_end < CODE_LIMIT - STACK_SIZE, "code + tables + entities overflow into the stack"

; ============================================================================
;  Output
; ============================================================================
;  A headerless blob only. src/disc.asm wraps it in the relocating stub that
;  actually gets it to #0040 -- see the long explanation there.
; ----------------------------------------------------------------------------
    save "build/home.raw", CODE_START, code_end - CODE_START


; ============================================================================
;  Bank 4 -- everything that runs while the game is stopped
; ============================================================================
;  Assembled at #4000 but NOT part of the low-memory image: src/disc.asm pages
;  extended bank 4 into the window and copies this there at load time, so the
;  labels below resolve to bank-4 addresses and the low 16K keeps its space.
;
;  Bank 4 is the RESTING state of the window. It used to hold the interceptor
;  and frigate sprite libraries as well; six yaw views made a library 4320
;  bytes, so THREE fit in a 16K window and all eight now live in banks 5-7 and
;  are read off the disc by lib_load. That is 8640 bytes of bank back (5992 of
;  them free after the painted stand-in below takes its 2688) and 4255 of
;  DISC.BIN, which is far more than the 900 that was expected -- the packed
;  size fell from 10905 to 6650, because what is left in here does not compress
;  at all. It leaves nothing here to blit from; the one rule that keeps the
;  paging safe is still in game/shipclass.asm.
; ----------------------------------------------------------------------------
    BANK 1

    org BANK_WINDOW
bank4_start:
    include "gen/zoom.asm"
    include "game/classdata.asm"
    include "game/formdata.asm"
    include "game/homeplanet.asm"
    include "game/campaign.asm"
    include "game/helptext.asm"
;  The title screen RUNS from the bank. Nothing pages bank 4 out, so #4000
;  upwards is ordinary executable RAM -- and this is code that runs once,
;  before the first mission, so it has no business competing for the low 16K
;  that everything in the frame loop has to share.
    include "gfx/bigtext.asm"
    include "game/help.asm"
    include "game/menu.asm"
    include "game/title.asm"
    include "game/titletext.asm"
    include "game/menutext.asm"
    include "game/gameover.asm"
;  The title screen's music. In the bank with the screen it belongs to, and
;  legal here by the narrow test: it runs once a game frame from the title's
;  own branch of demo_update, never from between class_tier_addr and
;  class_blit_done, and it reads its notes out of this bank. It writes no PSG
;  register at all -- see the head of the file -- so nothing about it has to
;  run in the interrupt, which is the other half of why it may live here.
    include "sys/music.asm"
    include "gen/mus_menu.asm"
    include "game/wavesdraw.asm"
    include "game/overtext.asm"
    include "game/staticscreens.asm"
;  The context bar. It runs once a GAME FRAME rather than only while the game
;  is stopped, which makes it the second thing here reached from inside the
;  frame loop -- see the note at the top of the file for why that is still
;  bank code, and gfx/markproj.asm for the other one.
    include "game/ctxbar.asm"
;  Section 14's mitigation -- six yaw views instead of eight -- took the two
;  bank-4 sprite libraries from 11520 bytes to 8640, and these three moved
;  into what it freed. They are the same kind of thing as everything above
;  them: the player's commands, and setting a mission up and taking it down.
;  None of it runs with a foreign bank under the window. Their equates and
;  their variables stayed in the low 16K -- see the head of each file.
    include "game/ordercmd.asm"
    include "game/squadcmd.asm"
    include "game/campaignrun.asm"
;  The jump wipe. Its vanish runs from mis_jump with the world stopped and its
;  reveal from the tail of demo_update, after ctx_bar -- so it is the fourth
;  thing in here reached from inside the frame loop, and legal for the same
;  reason: nothing pages bank 4 out at that point. After campaignrun.asm
;  because that is what calls it.
    include "game/jumpfx.asm"
;  The Salvage Corvette's job. Two of its three routines run from inside the
;  frame loop -- slv_make_wreck out of cbt_update and slv_tow_step out of
;  eco_update -- which makes it the third thing here reached from there, after
;  game/ctxbar.asm and gfx/markproj.asm. It is still bank code by the narrow
;  rule in game/shipclass.asm: nothing pages bank 4 out during the simulation.
    include "game/salvage.asm"
;  The tutorial. Bank code by the narrow rule: tut_enter runs from a keypress
;  on the title screen, tut_update from the very top of demo_update and
;  tut_draw from its very end, and none of the three can be reached from
;  between class_tier_addr and class_blit_done. After campaignrun.asm and
;  ctxbar.asm because it calls mis_make_enemy, mis_count_enemies and
;  str_index, and after ordercmd.asm for order_dest_addr.
    include "game/tutorialrun.asm"
;  Section 7's economy. Bank code by the narrow rule: eco_update runs from
;  inside the frame loop and nothing in it draws, which is the same argument
;  game/salvage.asm is already here on -- and eco_update is what calls it, so
;  this has to come before it... except that RASM resolves forward references,
;  so the order here is only about which comment explains which. After
;  campaignrun.asm for mis_*, and its state stays in the low 16K.
    include "game/economyrun.asm"
;  The `I` page. Bank code by the narrow rule -- it runs on a keypress and
;  then once a frame with the world stopped. After ctxbar.asm because it calls
;  ctx_class_name and str_index, and after staticscreens.asm for static_wipe.
    include "game/squadinforun.asm"
;  The cached half of the marker pass. It runs only when the camera hash has
;  changed and always with the window at rest, so it is bank-4 code by the
;  same rule as everything above it -- but it is the ONLY thing here that runs
;  from inside the frame loop, so read the note at the top of the file.
    include "gfx/markproj.asm"
IF DIAG_DISC
;  The disc diagnostic's panel. Bank code by the rule above -- it runs from
;  the title screen and from the briefing, both of which stop the world.
    include "game/libdiag.asm"
ENDIF
bank4_end:

; ----------------------------------------------------------------------------
;  Uninitialised bank storage, deliberately BELOW the save above.
;
;  The stand-in ships, for a machine that could not read the disc. Every class
;  and every tier points here when lib_load fails, and class_use_fallback
;  paints it -- mask 0, data #F0 -- so a ship draws as a solid block of its
;  tier's size instead of as whatever bank 5 happens to contain. It has no
;  starting contents, so like the fleet buffer below it costs DISC.BIN nothing.
;
;  This is what the interceptor and frigate libraries used to do for free by
;  being in bank 4. They are on the disc now, so there is no real art to fall
;  back to and the fallback has to make its own.
; ----------------------------------------------------------------------------
class_standin:
    defs CLASS_STANDIN_SIZE, 0

; ----------------------------------------------------------------------------
;  The fleet between missions -- section 10 calls it FLEET.DAT. It has no
;  starting contents, so putting it inside the saved image would add its 960
;  bytes to DISC.BIN for nothing, and DISC.BIN has to finish below #A700
;  where AMSDOS keeps its workspace. That ceiling is close now.
; ----------------------------------------------------------------------------
;  The header goes in front of the fleet inside the same block, padded out to
;  a whole number of sectors, so a save is two 512-byte writes from one
;  address rather than a gather -- which is what keeps the FDC code small
;  enough to fit what is left of the low 16K.
fleet_block:
    defs FLEET_HDR_SIZE, 0              ; magic, magic, mission index, count
fleet_buffer:
;  ENT_PLAYER_MAX records of FLEET_REC_SIZE, not ENT_MAX of ENT_SIZE. It was
;  the second of those and both halves of that were wrong by a margin: only
;  the player's region is ever saved, so twenty of the slots could not be
;  filled, and the record carried six bytes a ship that a restored fleet
;  throws away. 960 bytes for 28 ships; 728 for 56.
    defs ENT_PLAYER_MAX * FLEET_REC_SIZE, 0
; ----------------------------------------------------------------------------
;  What the campaign has unlocked, in the block's PAD and not in its header.
;
;  Growing FLEET_HDR_SIZE would move fleet_buffer, and every save on every disc
;  written before today would then be read one byte out -- 48 records of
;  plausible-looking rubbish behind a magic that still matched. The pad is 60
;  bytes that have never held anything, so a field here costs no compatibility
;  at all.
;
;  IT IS TWO BYTES AND THE FIRST IS A TAG. The obvious argument is that an old
;  save reads as zero and zero means "nothing unlocked", which is what
;  improvements.md assumed -- and it is WRONG here, because this block is
;  declared after bank4_end. It is uninitialised bank RAM: the `,0` above is a
;  fill for an image that is never saved, nothing writes the pad, and so what
;  every existing FLEET.DAT has at this offset is whatever the machine powered
;  up with. See fleet_disc_load.
; ----------------------------------------------------------------------------
fleet_unlocks:
    defs 2, 0
    defs FLEET_BLOCK_SIZE - FLEET_HDR_SIZE - ENT_PLAYER_MAX * FLEET_REC_SIZE - 2, 0
bank4_limit:

    assert fleet_buffer == fleet_block + FLEET_HDR_SIZE, "the fleet must follow its header"
    assert fleet_unlocks == fleet_buffer + ENT_PLAYER_MAX * FLEET_REC_SIZE, "the unlocks must follow the fleet"
    assert bank4_limit - fleet_block == FLEET_BLOCK_SIZE, "the save block is not whole sectors"
;  The one that decides how big the fleet may be. FLEET.DAT is two raw sectors
;  and nothing here would report going past them: fdc_fleet_save writes 1024
;  bytes from fleet_block whatever is behind it, so a fleet that did not fit
;  would simply not come back, silently, in whichever slots fell off the end.
    assert FLEET_HDR_SIZE + ENT_PLAYER_MAX * FLEET_REC_SIZE + 2 <= FLEET_BLOCK_SIZE, "the fleet does not fit its two sectors"

;  The three runs game/entity.asm's save record is made of. Nine loads would
;  need no adjacency; two LDIRs and an LDI need all of this, and getting it
;  wrong does not fail -- it brings a fleet back with its orders in its hulls.
    assert ENT_Y == ENT_X + 2 && ENT_Z == ENT_Y + 2 && ENT_YAW == ENT_Z + 2, "the position is not one run"
    assert ENT_CLASS == ENT_X + FLEET_REC_A_LEN + 2, "pitch and speed are not the two bytes skipped after the position"
    assert ENT_ORDER == ENT_CLASS + FLEET_REC_B_LEN - 1, "class..order is not one run of FLEET_REC_B_LEN"
    assert ENT_LOAD == ENT_TARGET + 1, "the hold is not the byte after the target"

;  Printed before the assert for the same reason the low 16K's figure is.
    print "bank 4:", {hex}BANK_WINDOW, "..", {hex}bank4_limit, " image:", bank4_end - BANK_WINDOW, " free:", BANK_WINDOW + BANK_WINDOW_SIZE - bank4_limit

;  Live again. It was commented out while bank 4 had nine bytes left and every
;  build was a coin toss; six yaw views gave it a kilobyte back, so the guard
;  can go back to doing its job. Overflowing the window does not fail loudly on
;  its own -- the fleet buffer would simply wrap onto the sprite libraries.
    assert bank4_limit <= BANK_WINDOW + BANK_WINDOW_SIZE, "bank 4 contents overflow the window"

;  The title is sized to the screen rather than centred on it: ten glyphs at
;  TXT_BIG_W_BYTES is exactly the 80-byte line. Checked here rather than beside
;  txt_big because ASSERT is evaluated where it stands and the strings are in
;  the bank, which is included further down than the code that draws them.
    assert (title_credit - title_text - 1) * TXT_BIG_W_BYTES == SCR_BYTES_PER_LINE, "the title no longer spans the screen"

;  THE PLANET IS THE ONLY THING ON THIS SCREEN THAT IS NOT CLIPPED BY ANYTHING.
;  Its interior goes down through scr_fill_rect, which honours no clip at all
;  and will happily write a byte column past 79 into the scanline eight rows
;  down; its limb goes through gfx_vline, which clips in Y and not in X. So the
;  disc has to be inside the screen by ARITHMETIC, and it has to stay clear of
;  the two things on this screen that own their own lines -- the big title
;  above it and the prompt below.
;  THE HULL ROW's two string measurements. They live down here rather than
;  beside HUD_HP_X because wave_say_text moved into bank 4 with the rest of the
;  row's drawing, and RASM evaluates an ASSERT where it stands -- it cannot see
;  an include that has not happened yet. Same reason the table invariants are
;  at the bottom of this file.
;
;  ONE PER MESSAGE, and a label between the strings to make that possible: RASM
;  cannot count zero bytes in a run, so a single measurement over the whole
;  table would be the SUM of the messages and would fail the moment there were
;  two of them -- which is not the check anyone wants. Each one is drawn at
;  HUD_SAY_X on its own, so each one is measured against HUD_MOTH_X on its own.
    assert HUD_SAY_X + (wave_say_text_1 - wave_say_text - 1) * TXT_CHAR_W_BYTES <= HUD_MOTH_X, "INCOMING runs into the Mothership's hull"
    assert HUD_SAY_X + (wave_say_text_2 - wave_say_text_1 - 1) * TXT_CHAR_W_BYTES <= HUD_MOTH_X, "the Frigate unlock message runs into the Mothership's hull"
    assert HUD_SAY_X + (wave_say_text_end - wave_say_text_2 - 1) * TXT_CHAR_W_BYTES <= HUD_MOTH_X, "the Destroyer unlock message runs into the Mothership's hull"

;  ...and there is one message for INCOMING plus one per unlock bit, in that
;  order, because wave_say_unlock turns a bit number into an index. A class
;  that could be unlocked with no word to go with it would draw whatever
;  follows the table.
    assert WAVE_MSG_DESTROYER == 2, "the message list and campaign_unlocks' bits are out of step"

;  THE TWO DERELICTS MUST NOT BE ADRIFT AT THE SAME TIME. There is one
;  derelict_pos, so overlapping ranges would put two hulls on the same point --
;  and mis_spawn_derelict's loop does not know that, deliberately: it places
;  every row that wants placing, which is the honest thing for it to do and
;  makes this the only place the constraint is stated.
    assert MIS_DEST_WRECK_FROM > MIS_DERELICT_UNTIL, "the two derelicts overlap and would be placed on the same point"
    assert MIS_DERELICT_FROM <= MIS_DERELICT_UNTIL, "the frigate derelict's range is empty"
    assert MIS_DEST_WRECK_FROM <= MIS_DEST_WRECK_UNTIL, "the destroyer derelict's range is empty"
    assert MIS_DEST_WRECK_UNTIL < MIS_COUNT, "the destroyer derelict outlives the campaign"
    assert HUD_MOTH_X + HUD_HP_CHARS * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the Mothership's hull runs off the screen"

;  THE GAME-OVER SCREEN. Its four lines are centred by hand -- there is no
;  centring in txt_draw and one screen does not justify inventing it -- so the
;  arithmetic that centred them is checked here against the strings themselves.
;  Reword a line without moving its x and the build stops instead of the line
;  sitting a character off.
    assert OVER_LINE_1_X * 2 + (over_line_2 - over_line_1 - 1) * TXT_CHAR_W_BYTES == SCR_BYTES_PER_LINE, "the game-over screen's first line is not centred"
    assert OVER_LINE_2_X * 2 + (over_line_3 - over_line_2 - 1) * TXT_CHAR_W_BYTES == SCR_BYTES_PER_LINE, "the game-over screen's second line is not centred"
    assert OVER_LINE_3_X * 2 + (over_prompt - over_line_3 - 1) * TXT_CHAR_W_BYTES == SCR_BYTES_PER_LINE, "the game-over screen's third line is not centred"
    assert OVER_PROMPT_X * 2 + (over_prompt_end - over_prompt - 1) * TXT_CHAR_W_BYTES == SCR_BYTES_PER_LINE, "the game-over screen's prompt is not centred"

;  ...and the big word, whose glyphs are five pixels in an eight-pixel cell --
;  so the drawn width is three bytes short of the cells it occupies, and that
;  is what OVER_TITLE_X halves. It is a different sum from the four above, not
;  the same one with a different font.
;  Two-sided, because this one cannot come out exact: the drawn width is odd
;  (72 cells less 3 blank columns is 69) and the margin either side of it is
;  therefore a half byte. The four lines above ARE exact -- n characters at two
;  bytes each is always even -- so they are asserted as equalities.
    assert OVER_TITLE_X * 2 + (over_line_1 - over_title - 1) * TXT_BIG_W_BYTES - 3 <= SCR_BYTES_PER_LINE, "GAME OVER sits right of centre"
    assert OVER_TITLE_X * 2 + (over_line_1 - over_title - 1) * TXT_BIG_W_BYTES - 3 >= SCR_BYTES_PER_LINE - 1, "GAME OVER sits left of centre"
    assert (over_line_1 - over_title - 1) * TXT_BIG_W_BYTES <= SCR_BYTES_PER_LINE, "GAME OVER is wider than the screen"

;  Nothing on it may reach the strip, which it clears itself and does not
;  redraw -- it is the one full-screen page that takes all 200 lines.
    assert OVER_TITLE_Y + TXT_BIG_H <= OVER_BODY_Y, "GAME OVER runs into the line below it"
    assert OVER_PROMPT_Y + TXT_CHAR_H < SCR_HEIGHT_PX, "the game-over prompt runs off the bottom of the screen"

;  ...and the burning world sits between the body and the prompt. NOTHING in
;  this drawing clips: scr_fill_rect writes the bytes it is handed and
;  gfx_vline clips only in Y, so an overlap here is not a layout choice, it is
;  a fill walking through the glyphs.
    assert OVER_BODY_Y + 2 * OVER_LINE_STEP + TXT_CHAR_H <= OVER_PLANET_CY - TITLE_PLANET_RY, "the game-over screen's body runs into the planet"
    assert OVER_PLANET_CY + TITLE_PLANET_RY < OVER_PROMPT_Y, "the game-over screen's planet runs into its prompt"
    assert OVER_PLANET_CX >= TITLE_PLANET_RX + 4, "the game-over planet's fill runs off the left of the screen"
    assert OVER_PLANET_CX + TITLE_PLANET_RX + 4 < SCR_WIDTH_PX, "the game-over planet's fill runs off the right of the screen"

;  Three bytes a fire, and the count is a literal because RASM cannot resolve
;  an equate derived from two bank-4 labels at symbol-export time.
    assert over_fire_table_end - over_fire_table == OVER_FIRE_COUNT * 3, "the fire table is not OVER_FIRE_COUNT entries long"

;  Four pixels of margin each side, not none: the night side's fill rounds
;  OUTWARD -- see title_planet_fill for why it has to -- so it writes up to a
;  whole byte past the limb.
    assert TITLE_PLANET_CX >= TITLE_PLANET_RX + 4, "the planet's fill runs off the left of the screen"
    assert TITLE_PLANET_CX + TITLE_PLANET_RX + 4 < SCR_WIDTH_PX, "the planet's fill runs off the right of the screen"
    assert TITLE_PLANET_CY - TITLE_PLANET_RY >= TITLE_Y + 32, "the planet runs into the big title"
    assert TITLE_PLANET_CY + TITLE_PLANET_RY < TITLE_PROMPT_Y, "the planet runs into the title prompt"

    save "build/sprites.raw", BANK_WINDOW, bank4_end - BANK_WINDOW


; ============================================================================
;  Banks 5, 6 and 7 -- all eight ship classes, 3 + 3 + 2
; ============================================================================
;  These are NOT in DISC.BIN. They go on the disc as raw sectors and lib_load
;  reads them in at boot -- src/sys/libload.asm has the arithmetic and the
;  reason. THREE 4320-byte libraries a bank is 12960 of the window's 16384 and
;  26 of the 27 sectors LIB_TRACKS_PER_BANK already reserved, which is the
;  whole reason the interceptor and the frigate could stop riding inside
;  DISC.BIN. The asserts below are what stop a FOURTH being added by accident.
;
;  The order is section 8's class order and nothing cleverer: 0-2, 3-5, 6-7.
;  Which bank a class is in makes no difference to anything at run time --
;  class_tier_addr pages whichever one class_bank names -- so the arrangement
;  that is easiest to check against game/shipclass.asm is the right one.
;
;  Nothing but sprite data may go in here. Bank 4 is paged out while one of
;  these is under the window, so code assembled here could only ever run in a
;  world where the game's own static screens do not exist.
; ----------------------------------------------------------------------------
    BANK 2

    org BANK_WINDOW
bank5_start:
    include "gen/spr_interceptor.asm"
    include "gen/spr_mothership.asm"
    include "gen/spr_harvester.asm"
bank5_end:
    save "build/bank5.raw", BANK_WINDOW, bank5_end - BANK_WINDOW

    BANK 3

    org BANK_WINDOW
bank6_start:
    include "gen/spr_scout.asm"
    include "gen/spr_bomber.asm"
    include "gen/spr_frigate.asm"
bank6_end:
    save "build/bank6.raw", BANK_WINDOW, bank6_end - BANK_WINDOW

    BANK 4

    org BANK_WINDOW
bank7_start:
    include "gen/spr_salvage.asm"
    include "gen/spr_destroyer.asm"

;  ...and the briefings, in the 4672 bytes of this bank that lib_load was
;  already reading and throwing away. game/briefings.asm has the arithmetic;
;  the short of it is that raw sectors cost DISC.BIN nothing and DISC.BIN is
;  what twenty missions do not fit inside.
    include "game/briefings.asm"
;  ...and the words the other two stopped-world screens draw, across for the
;  same reason and read by the same routine. See game/screentext.asm.
    include "game/screentext.asm"
bank7_end:
    save "build/bank7.raw", BANK_WINDOW, bank7_end - BANK_WINDOW

    print "bank 5:", bank5_end - BANK_WINDOW, " bank 6:", bank6_end - BANK_WINDOW, " bank 7:", bank7_end - BANK_WINDOW, " of", LIB_SECTORS * FDC_SECTOR_SIZE, "each"

;  lib_load reads a fixed LIB_SECTORS sectors into each bank, because a
;  per-bank length would be a fourth thing to keep in step between the
;  assembler, the disc writer and the loader. So every bank has to fit that,
;  and the images are padded out to it on the disc rather than here.
    assert bank5_end - BANK_WINDOW <= LIB_SECTORS * FDC_SECTOR_SIZE, "bank 5 does not fit LIB_SECTORS sectors"
    assert bank6_end - BANK_WINDOW <= LIB_SECTORS * FDC_SECTOR_SIZE, "bank 6 does not fit LIB_SECTORS sectors"
    assert bank7_end - BANK_WINDOW <= LIB_SECTORS * FDC_SECTOR_SIZE, "bank 7 does not fit LIB_SECTORS sectors"

;  The whole library area has to stay clear of the tracks AMSDOS hands out for
;  DISC.BIN, and of the fleet save at the far end of the disc.
    assert LIB_TRACK + LIB_BANKS * LIB_TRACKS_PER_BANK <= FLEET_TRACK, "the sprite libraries run into the fleet save"

IF DIAG_DISC
;  fdc_drain_result walks ST0, ST1, ST2 and then sticks on the bin, and it does
;  it by INC L and a compare against the low byte of the last one. So the four
;  have to be adjacent, in that order, and inside one page -- get any of that
;  wrong and the drain writes result bytes over whatever happens to be next in
;  the low 16K, which is a corruption with no message attached to it.
    assert fdc_st1 == fdc_st0 + 1, "fdc_st1 is not immediately after fdc_st0"
    assert fdc_st2 == fdc_st0 + 2, "fdc_st2 is not immediately after fdc_st1"
    assert fdc_spill == fdc_st0 + 3, "fdc_spill is not immediately after fdc_st2"
    assert (fdc_st0 & #FF00) == (fdc_spill & #FF00), "the FDC result bytes straddle a page boundary"
;  The three the fleet transfer keeps for itself are copied with one LDIR.
    assert fleet_diag_st1 == fleet_diag_st0 + 1, "the fleet diagnostic status bytes are not adjacent"
    assert fleet_diag_st2 == fleet_diag_st0 + 2, "the fleet diagnostic status bytes are not adjacent"
;  ...and so are the library's.
    assert lib_diag_st1 == lib_diag_st0 + 1, "the library diagnostic status bytes are not adjacent"
    assert lib_diag_st2 == lib_diag_st0 + 2, "the library diagnostic status bytes are not adjacent"
;  The panel must not run into the strips that are drawn on top of it. On the
;  title screen the prompt is at 160; under a briefing the HUD owns 168 up and
;  static_wipe does not clear it.
    assert DIAG_TITLE_Y >= TITLE_Y + 32, "the disc diagnostic runs into the big title"
    assert DIAG_TITLE_Y + (DIAG_ROWS - 1) * DIAG_STEP + TXT_CHAR_H <= TITLE_SHIP_Y, "the disc diagnostic runs into the flight of ships"
    assert DIAG_TITLE_Y - 1 + DIAG_ROWS * DIAG_STEP <= TITLE_PROMPT_Y, "the disc diagnostic runs into the title prompt"
    assert DIAG_BRIEF_Y > BRIEF_TEXT_Y + BRIEF_LINES * BRIEF_LINE_STEP + 12 + TXT_CHAR_H, "the disc diagnostic runs into the briefing prompt"
    assert DIAG_BRIEF_Y + TXT_CHAR_H <= HUD_TOP, "the disc diagnostic runs into the HUD strip"
ENDIF

; ----------------------------------------------------------------------------
;  Per-class table invariants.
;
;  Every per-class table is indexed by ENT_CLASS and has to be exactly
;  CLASS_COUNT entries long. A table one short reads the first byte of
;  whatever follows it, and the symptom is a Destroyer that costs whatever the
;  next table happens to begin with -- which is a plausible number, so nothing
;  looks wrong.
; ----------------------------------------------------------------------------
    assert class_hull - class_tier_bias == CLASS_COUNT,   "class_tier_bias is not CLASS_COUNT entries"
    assert class_tag - class_hull == CLASS_COUNT,         "class_hull is not CLASS_COUNT entries"
    assert class_tag_end - class_tag == CLASS_COUNT * 4,  "class_tag is not CLASS_COUNT tags"
    assert eco_build_order - eco_class_gate == CLASS_COUNT, "eco_class_gate is not CLASS_COUNT entries"
    assert eco_class_cost - eco_build_order == CLASS_BUILDABLE, "eco_build_order does not offer CLASS_BUILDABLE classes"
    assert eco_class_frames - eco_class_cost == CLASS_COUNT, "eco_class_cost is not CLASS_COUNT entries"
    assert cbt_damage_matrix - eco_class_frames == CLASS_COUNT, "eco_class_frames is not CLASS_COUNT entries"
    assert cbt_damage_matrix_end - cbt_damage_matrix == CLASS_COUNT * CLASS_COUNT, "the damage matrix is not CLASS_COUNT square"
    assert class_sprite_end - class_sprite == CLASS_COUNT * CLASS_SPRITE_STRIDE, "class_sprite is not CLASS_COUNT rows"
    assert class_geom_end - class_geom == CLASS_TIERS * CLASS_GEOM_SIZE, "class_geom is not CLASS_TIERS rows"
    assert form_shell_end - form_shell == FORM_SLOTS * 6, "the sphere formation is not FORM_SLOTS slots"
    assert form_shell - form_arrow == FORM_SLOTS * 4, "the wedge formation is not FORM_SLOTS pairs"
    assert form_arrow - form_grid == 8, "the 4x4 lattice is not four numbers"
    assert cam_zoom_table_end - cam_zoom_table == CAM_ZOOM_STEPS * CAM_ZOOM_RECORD, "cam_zoom_table is not CAM_ZOOM_STEPS records"

;  cbt_damage_for indexes the matrix with three `add a,a`, so the row stride is
;  hard-coded at 8. Eight classes fill it exactly; a ninth would silently
;  overlap two rows.
    assert CLASS_COUNT == 8, "cbt_damage_for's row stride is hand-coded as 8"

; ----------------------------------------------------------------------------
;  class_geom is ONE table for all eight classes, because tools/mkships.py
;  renders every class from the same TIERS list. That is true by construction
;  today and would stop being true the moment somebody hand-retouched a sprite
;  to a different size in RetroTools -- at which point the blitter would read
;  it with the interceptor's stride and draw a smear.
;
;  Checked by summing each field across the eight classes against eight times
;  the reference, per tier: it is six lines instead of forty-eight, and for two
;  classes to slip past they would have to be wrong by equal and opposite
;  amounts in both the width and the block size at once.
; ----------------------------------------------------------------------------
    assert interceptor_a_w_bytes * CLASS_COUNT == interceptor_a_w_bytes + mothership_a_w_bytes + harvester_a_w_bytes + scout_a_w_bytes + bomber_a_w_bytes + frigate_a_w_bytes + salvage_a_w_bytes + destroyer_a_w_bytes, "tier A is not the same width in every class"
    assert interceptor_b_w_bytes * CLASS_COUNT == interceptor_b_w_bytes + mothership_b_w_bytes + harvester_b_w_bytes + scout_b_w_bytes + bomber_b_w_bytes + frigate_b_w_bytes + salvage_b_w_bytes + destroyer_b_w_bytes, "tier B is not the same width in every class"
    assert interceptor_c_w_bytes * CLASS_COUNT == interceptor_c_w_bytes + mothership_c_w_bytes + harvester_c_w_bytes + scout_c_w_bytes + bomber_c_w_bytes + frigate_c_w_bytes + salvage_c_w_bytes + destroyer_c_w_bytes, "tier C is not the same width in every class"
    assert interceptor_a_block_sz * CLASS_COUNT == interceptor_a_block_sz + mothership_a_block_sz + harvester_a_block_sz + scout_a_block_sz + bomber_a_block_sz + frigate_a_block_sz + salvage_a_block_sz + destroyer_a_block_sz, "tier A blocks are not the same size in every class"
    assert interceptor_b_block_sz * CLASS_COUNT == interceptor_b_block_sz + mothership_b_block_sz + harvester_b_block_sz + scout_b_block_sz + bomber_b_block_sz + frigate_b_block_sz + salvage_b_block_sz + destroyer_b_block_sz, "tier B blocks are not the same size in every class"
    assert interceptor_c_block_sz * CLASS_COUNT == interceptor_c_block_sz + mothership_c_block_sz + harvester_c_block_sz + scout_c_block_sz + bomber_c_block_sz + frigate_c_block_sz + salvage_c_block_sz + destroyer_c_block_sz, "tier C blocks are not the same size in every class"

;  ...and the same check for the FRAME count, which is the one that matters
;  most now that it is six rather than eight. phase4_cache derives a view with
;  a multiply by PHASE4_VIEWS and phase4_blit_body steps `view * shifts` blocks
;  from the base, so a library rendered with a different number of yaw views
;  does not draw the wrong picture -- it walks off the end of its own tier into
;  the next one, and the ship at the far end of the table draws whatever
;  follows the library.
    assert PHASE4_VIEWS * CLASS_COUNT == interceptor_a_frames + mothership_a_frames + harvester_a_frames + scout_a_frames + bomber_a_frames + frigate_a_frames + salvage_a_frames + destroyer_a_frames, "tier A is not PHASE4_VIEWS yaw views in every class"
    assert PHASE4_VIEWS * CLASS_COUNT == interceptor_b_frames + mothership_b_frames + harvester_b_frames + scout_b_frames + bomber_b_frames + frigate_b_frames + salvage_b_frames + destroyer_b_frames, "tier B is not PHASE4_VIEWS yaw views in every class"
    assert PHASE4_VIEWS * CLASS_COUNT == interceptor_c_frames + mothership_c_frames + harvester_c_frames + scout_c_frames + bomber_c_frames + frigate_c_frames + salvage_c_frames + destroyer_c_frames, "tier C is not PHASE4_VIEWS yaw views in every class"

;  The blitter's unrolled run is entered SPR_UNIT_BYTES back from its end per
;  byte of width, so a sprite wider than the run walks off into whatever
;  follows it.
    assert interceptor_c_w_bytes <= SPR_MAX_W_BYTES, "tier C is wider than the unrolled blit run"

; ----------------------------------------------------------------------------
;  The painted stand-in.
;
;  All three tiers of all eight classes point at ONE address when there is no
;  disc, and each tier steps `view * shifts` blocks of its own size from it. So
;  the block has to be as long as the greediest tier's whole run -- tier C's,
;  today -- and CLASS_STANDIN_SIZE is a literal because `defs` is evaluated
;  where it stands and the libraries are assembled in a later bank. Get it too
;  small and the blitter reads off the end into the fleet buffer, on the one
;  path nobody tests on real hardware.
; ----------------------------------------------------------------------------
    assert CLASS_STANDIN_SIZE >= interceptor_a_frames * interceptor_a_shifts * interceptor_a_block_sz, "the stand-in is shorter than a tier A library"

;  TIER A ONLY, and that is the point rather than a weakening. class_use_fallback
;  flattens class_geom to tier A's row, so on a machine with no disc every tier
;  reads a tier A library out of this block and the largest read is the one
;  above. It used to have to hold a tier C library -- 2688 bytes of the bank
;  window against 432 -- and that window is what the project ran out of.

;  ...and it is a sprite address like any other, so it has to be in the window.
    assert class_standin >= BANK_WINDOW, "the stand-in is below the bank window"
    assert class_standin + CLASS_STANDIN_SIZE <= BANK_WINDOW + BANK_WINDOW_SIZE, "the stand-in runs off the end of bank 4"

;  class_sprite and class_geom are read AFTER class_tier_addr has paged bank 4
;  out, so neither may live in the window.
    assert class_sprite < BANK_WINDOW, "class_sprite is in the bank window and would page itself out"
    assert class_geom < BANK_WINDOW, "class_geom is in the bank window and would page itself out"
    assert class_bank < BANK_WINDOW, "class_bank is in the bank window"

;  ...and so are the two clip bounds. spr_blit is the ONLY thing that ever runs
;  with a foreign bank under the window, and it reads both of them on every
;  sprite. A clip bound in bank 4 would be read out of a sprite library, which
;  is a plausible-looking number and would clip the ships to a random band.
    assert spr_clip_top < BANK_WINDOW, "spr_clip_top is in the bank window"
    assert spr_clip_bottom < BANK_WINDOW, "spr_clip_bottom is in the bank window"

;  mark_store reads the two of them with an INC HL rather than a second
;  LD HL,nn, because it runs about twenty times a frame and this is a marker
;  pass that was measured at 2% of it. Separate them and the fast path tests
;  the top edge against whatever byte lands in between.
    assert spr_clip_top == spr_clip_bottom + 1, "mark_store's fast path needs the two clip bounds adjacent"

; ----------------------------------------------------------------------------
;  The context bar's layout.
;
;  Nothing at run time would catch a line that is too long: txt_draw clips at
;  the SCREEN edge and not at a field, so a string that overruns silently
;  writes over its neighbour and a string that reaches byte 80 is simply
;  truncated. These are the only guard there is, and they are here rather than
;  beside the text because ASSERT is evaluated where it stands and the bank is
;  included further down than the code that draws it.
; ----------------------------------------------------------------------------
    assert CTX_Y + TXT_CHAR_H <= CTX_BAR_H, "the context bar's text does not fit the strip it owns"
    assert CTX_BAR_H < HUD_TOP, "the context bar and the HUD strip overlap"

;  A RUN of words draws exactly two characters fewer than it occupies bytes:
;  every word but the last is followed by a terminator that stands for the
;  space after it, and the run itself ends in a terminator and a second zero
;  that draw nothing. So these still measure bytes and still mean characters,
;  which is the reason ctx_run encodes the spacing rather than a sentinel byte
;  inside the string -- a byte that draws nothing would have to be subtracted
;  here by hand, once per line, for ever.
    assert ctx_text_play_end - ctx_text_play <= CTX_BAR_CHARS + 2, "the playing line is wider than the screen"
    assert ctx_text_disc_end - ctx_text_disc <= CTX_BAR_CHARS + 2, "the move disc line is wider than the screen"
    assert (ctx_text_pause_tail - ctx_text_paused - 1) * TXT_CHAR_W_BYTES <= CTX_PAUSE_TAIL_X, "PAUSED runs into the rest of its line"
    assert CTX_PAUSE_TAIL_X + (ctx_text_pause_end - ctx_text_pause_tail - 2) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the paused line is wider than the screen"
    assert (ctx_text_recycle_tail - ctx_text_recycle - 1) * TXT_CHAR_W_BYTES <= CTX_RECYCLE_TAIL_X, "RECYCLE? runs into the rest of its line"
    assert CTX_RECYCLE_TAIL_X + (ctx_text_recycle_end - ctx_text_recycle_tail - 2) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the recycle line is wider than the screen"

;  The build panel's four fields, each against the start of the next one.
    assert CTX_NAME_X + CTX_NAME_CHARS * TXT_CHAR_W_BYTES <= CTX_COST_X, "a class name would run into the cost"
    assert CTX_COST_X + 3 * TXT_CHAR_W_BYTES <= CTX_RU_X, "the cost figure would run into the RU label"
    assert CTX_RU_X + (ctx_text_pick - ctx_text_ru - 1) * TXT_CHAR_W_BYTES <= CTX_KEYS_X, "the RU label would run into the keys"
    assert CTX_KEYS_X + (ctx_text_pick_end - ctx_text_pick - 2) * TXT_CHAR_W_BYTES <= CTX_STAT_X, "the key hint would run into the status"
    assert CTX_STAT_X + (ctx_text_poor - ctx_text_buy - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "ENTER BUY runs off the screen"
    assert CTX_STAT_X + (ctx_text_full - ctx_text_poor - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "NEED MORE RU runs off the screen"
    assert CTX_STAT_X + (ctx_text_fleet - ctx_text_full - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "QUEUE FULL runs off the screen"
    assert CTX_STAT_X + (ctx_text_end - ctx_text_fleet - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "FLEET FULL runs off the screen"

;  A SUM, and it only catches gross overrun -- one name eighteen characters
;  long and three short ones would slip through. There is no way to ask RASM
;  for the longest of eight strings, and the alternative was a fixed stride
;  that costs 25 bytes to buy an exact check on a table that changes once a
;  year. Keep every name inside CTX_NAME_CHARS by hand.
    assert class_name_end - class_name <= CLASS_COUNT * (CTX_NAME_CHARS + 1), "the class names do not fit the context bar's name field"

; ----------------------------------------------------------------------------
;  The jump wipe.
;
;  It fills a band of the screen by hand, so nothing at run time would notice
;  if that band stopped being the playfield: a sweep one line too high scrubs a
;  row out of the context bar, and the bar is only repainted when its WORDS
;  change, so the damage would stay there for the rest of the mission. The same
;  trap spr_clip_top was threaded through mark_store to close.
; ----------------------------------------------------------------------------
    assert JFX_TOP == CTX_BAR_H, "the jump wipe starts inside the context bar"
    assert JFX_TOP + JFX_HEIGHT == HUD_TOP, "the jump wipe runs into the HUD strip"
    assert JFX_WIDTH == SCR_BYTES_PER_LINE, "the jump wipe is not the width of the screen"

;  A bar's run is its own ship's width plus a margin at each end, so the
;  longest run in the game is the widest sprite there is. Every class shares
;  class_geom, so that is tier C's width -- and if the art ever gets wider than
;  JFX_SPRITE_W_MAX says, the capitals stop being fully swept and a column or
;  two of them survives the bars. (The final black pass hides it during a jump;
;  the REVEAL has no such pass, and would show a stripe of a ship it had not
;  uncovered yet.)
    assert JFX_SPRITE_W_MAX == interceptor_c_w_bytes, "the widest sprite is not the width the jump wipe's bars run across"
    assert interceptor_c_w_bytes >= interceptor_b_w_bytes, "tier C is no longer the widest tier"
    assert interceptor_b_w_bytes >= interceptor_a_w_bytes, "tier B is no longer wider than tier A"

;  ...and both halves have to make enough passes for the last of them to be
;  past the end of the longest run, or the bars stop somewhere over the ships.
    assert (JFX_VANISH_PASSES - 1) * JFX_VANISH_STEP >= JFX_TRAVEL, "the vanish stops before its bars have crossed"
    assert (JFX_REVEAL_PASSES - 2) * JFX_REVEAL_STEP >= JFX_REVEAL_TRAVEL, "the reveal's last two passes are not past the end of the run"
    assert JFX_REVEAL_TRAVEL <= JFX_TRAVEL, "the reveal's run is not inside the vanish's"

;  Both dwells are counted DOWN with `dec (hl)`, and the vanish loads
;  DWELL - 1 before it waits at all -- so a dwell of 1 loads zero, wraps to 255
;  and holds the bars there for five seconds. A reveal dwell of 0 does the same
;  thing one frame later.
    assert JFX_VANISH_DWELL > 1, "a vanish dwell of 1 loads 0 and counts down from 256"
    assert JFX_REVEAL_DWELL > 0, "a reveal dwell of 0 counts down from 256"

;  THE ONE TIMING TRAP IN THIS FEATURE, and it is not on the screen. mis_jump
;  runs jfx_vanish to completion and then fleet_disc_save, which holds DI for
;  the whole transfer -- so a sound still running freezes mid-envelope and
;  resumes half a second later. The vanish's floor is one whole dwell per pass
;  plus the two dark passes, whatever is on the screen; snd_fx_jump_out is 300
;  ticks (100 steps at slow 3). This is the only place the two are compared.
    assert JFX_VANISH_PASSES * JFX_VANISH_DWELL + 2 > 300, "the jump-out sound outlasts the shortest possible vanish and would freeze inside the disc write's DI"

;  A bar is a whole byte of one pen, which is only a bar at all because Mode 1
;  packs four pixels into it. Ink 1 is the fleet's own -- see the header of
;  game/jumpfx.asm for why not 2 or 3.
    assert JFX_INK == SOLID_INK_1, "the jump wipe's bars are no longer drawn in ink 1"

; ----------------------------------------------------------------------------
;  The two full-screen lists, DOWNWARDS
; ----------------------------------------------------------------------------
;  The same trap one axis over, and this one had already happened. The orders
;  menu grew to thirteen rows when SPLIT BY CLASS went in, and thirteen rows at
;  the old MENU_STEP put CONTROLS at y=176 and the prompt at 190 -- both inside
;  the HUD's strip, which does not clear itself but draws labels onto it. So
;  the last two lines of the menu were printed across "RU 0080 ?HELP" and
;  "M 1 JUMP", every time ESC was pressed, and stayed there.
;
;  Nothing caught it. txt_draw clips at the SCREEN edge and not at HUD_TOP;
;  tests/test_menu.py reads menu_pick and follows the injected key through to
;  the command it stands for, which is the right thing for it to test and is
;  blind to where the row was drawn. It was found by watching a recording --
;  the same way the screen-space grid in phase4_group was killed.
    assert MENU_TOP + (MENU_COUNT - 1) * MENU_STEP + TXT_CHAR_H <= HUD_TOP, "the orders menu's last row is drawn inside the HUD strip"
    assert MENU_TITLE_Y + TXT_CHAR_H <= MENU_TOP, "the orders menu's title runs into its first row"
    assert MENU_PROMPT_X + (menu_bar - menu_prompt - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the orders menu's prompt runs off the screen"
    assert MENU_MARK_X + (menu_prompt - menu_title - 1) * TXT_CHAR_W_BYTES <= MENU_PROMPT_X, "the orders menu's title runs into its prompt"

;  THE MENU IS TWO PARALLEL TABLES NOW -- the key ids in bank 4 and the words
;  in bank 7 -- and these two asserts are what stands where "the key id and its
;  words are stored back to back" used to stand for free. A line missing from
;  either table slides every shortcut below it onto the wrong row, and the menu
;  would go on working perfectly while giving the wrong orders.
;
;  The words divide EXACTLY because every row is padded to the same
;  seventeen-character field so the shortcut right-aligns -- so one assert
;  catches a missing row, a short row and a long row alike. That is a stronger
;  check than the interleaved table ever had, and it is free.
    assert menu_keys_end - menu_keys == MENU_COUNT, "menu_keys is not one key per menu row"
    assert menu_words_end - menu_words == MENU_COUNT * (MENU_FIELD + 1), "menu_words is not MENU_COUNT rows of the full field width"

;  Only a bound for the help page's own column, because its lines are ragged by
;  design. What it catches is a row added here without HELP_ROWS moving, and
;  the wide end of a line running into the right-hand column; the per-line
;  width is measured off build/bank7.raw by tests/test_help.py, which is what
;  it takes to check the strings one at a time.
    assert help_words_end - help_words <= HELP_ROWS * (HELP_MAX_CHARS + 1), "the help page's left column is too long for its rows"
    assert help_words_end - help_words > HELP_ROWS, "the help page's left column has fewer rows than HELP_ROWS"
;  ...and the width HELP_MAX_CHARS claims really is the width there is. Written
;  as a multiply because the division that would derive it does not floor: see
;  the note beside the equate in game/help.asm.
    assert HELP_COL1_X + HELP_MAX_CHARS * TXT_CHAR_W_BYTES <= HELP_COL2_X, "a full-width help line would run into the orders column"

;  The shared buffer has to hold the longest thing any of the three screens
;  fetches into it. The briefing's own bound is BRIEF_MAX_CHARS, below.
    assert B7_BUF_SIZE > MENU_FIELD, "the bank 7 buffer cannot hold a menu row"
    assert B7_BUF_SIZE > HELP_MAX_CHARS, "the bank 7 buffer cannot hold a help row"

;  The help page's right column IS menu_words, so it is MENU_COUNT rows long
;  and not HELP_ROWS. It clears today only because help.asm already moved its
;  prompt up beside the title for exactly this reason.
    assert HELP_BODY_Y + (MENU_COUNT - 1) * HELP_LINE_STEP + TXT_CHAR_H <= HUD_TOP, "the help page's right column is drawn inside the HUD strip"
    assert HELP_BODY_Y + (HELP_ROWS - 1) * HELP_LINE_STEP + TXT_CHAR_H <= HUD_TOP, "the help page's left column is drawn inside the HUD strip"

;  The squadron breakdown is CLASS_COUNT rows and a total, so it grows with
;  section 8's class list rather than with the orders.
    assert INFO_BODY_Y + CLASS_COUNT * INFO_STEP + INFO_TOTAL_GAP + TXT_CHAR_H <= HUD_TOP, "the squadron page's total row is drawn inside the HUD strip"
    assert INFO_TITLE_Y + TXT_CHAR_H <= INFO_BODY_Y, "the squadron page's title runs into its first row"
    assert INFO_PCT_X + 4 * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the squadron page's percentage runs off the screen"
    assert INFO_COUNT_X + 2 * TXT_CHAR_W_BYTES <= INFO_PCT_X, "the squadron page's count would run into the percentage"

;  A SUM, the same shape and with the same limitation as the class-name check
;  above: the longest name has to clear the count column, and RASM cannot be
;  asked for the longest of eight strings.
    assert INFO_NAME_X + ((class_name_end - class_name) / CLASS_COUNT) * TXT_CHAR_W_BYTES <= INFO_COUNT_X, "the class names would run into the squadron page's count"

; ----------------------------------------------------------------------------
;  The tutorial (game/tutorial.asm, game/tutorialrun.asm).
;
;  Row C of the HUD strip is forty characters and the tutorial takes all of it.
;  Nothing at run time would catch a line that runs long: txt_draw clips at the
;  SCREEN edge and not at a field, so an over-length instruction is silently
;  written across the step counter beside it.
; ----------------------------------------------------------------------------
    assert (tut_table_end - tut_table) / TUT_STEP_SIZE == TUT_STEPS, "the tutorial's step table is not TUT_STEPS rows"

;  The counter says "/17" in so many bytes, so the number of steps is on the
;  screen as a literal and has to agree with the table. There is no arithmetic
;  that turns TUT_STEPS into two characters at assembly time.
    assert TUT_STEPS == 17, "the tutorial no longer has seventeen steps, and the /17 on the screen says it does"

;  ...and there has to be a line for every one of them. A SUM, with the same
;  limitation as the class-name check above -- one long line and three short
;  ones would slip through -- so the exact per-line check is a test:
;  tests/test_tutorial.TestTheWords.
    assert tut_text_end - tut_text <= TUT_STEPS * (TUT_TEXT_CHARS + 1), "the tutorial's lines do not fit row C"
    assert tut_text_end - tut_text >= TUT_STEPS * 2, "there are fewer tutorial lines than steps"

;  The row's three fields, each against the start of the next one.
    assert TUT_TEXT_X + TUT_TEXT_CHARS * TXT_CHAR_W_BYTES <= TUT_NUM_X, "a tutorial line would run into the step counter"
    assert TUT_NUM_X + 2 * TXT_CHAR_W_BYTES <= TUT_OF_X, "the step number would run into the /17"
    assert TUT_OF_X + (tut_text - tut_of_text - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the tutorial's step counter runs off the screen"

;  tut_fleet_has_order reaches ENT_ORDER from the flags byte with two INCs, because
;  BC is the loop counter and cannot hold an offset. Separate the two fields and
;  it reads ENT_SQUAD instead, which is a plausible number and would make the
;  fight step fire the moment a ship joined squadron 2.
    assert ENT_ORDER == ENT_FLAGS + 2, "tut_fleet_has_order reaches ENT_ORDER with two INCs"

;  The tutorial's own hostile is placed by index into the HOSTILE region, and
;  its slot has to be free for the whole stage: nothing else spawns one, and
;  the tutorial's fleet is TUT_SHIPS ships and a Mothership.
    assert (tut_fleet_end - tut_fleet) / 2 == TUT_SHIPS, "the tutorial's fleet table is not TUT_SHIPS ships"
    assert TUT_SHIPS + 1 <= ENT_PLAYER_MAX, "the tutorial's fleet does not fit the player's region"

;  The second line on the title screen, against the credit line below it and
;  against the blinking prompt above it. Both are drawn by txt_draw, which
;  clips at the screen edge and nowhere else.
    assert TITLE_PROMPT_Y + TXT_CHAR_H <= TITLE_TUT_Y, "the tutorial prompt runs into PRESS SPACE TO START"
    assert TITLE_TUT_Y + TXT_CHAR_H <= TITLE_CREDIT_Y, "the tutorial prompt runs into the credit line"
    assert TITLE_TUT_X + (title_tut_end - title_tut - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the tutorial prompt runs off the screen"

;  The formation names are indexed by WALKING terminators, so a list shorter
;  than FORM_COUNT does not draw the wrong word -- it walks off the end of the
;  table into whatever the assembler put next. RASM cannot be asked how many
;  zero bytes are in a run, and a hand-maintained byte count would be a comment
;  rather than a check, so the guard is a test instead:
;  tests/test_squadinfo.TestTheFormation.test_every_formation_has_its_own_name
;  presses `F` FORM_COUNT times and reads a different real word off the screen
;  each time. This much can be asserted, and it is the floor:
    assert info_form_names_end - info_form_names >= FORM_COUNT * 2, "there are fewer formation names than FORM_COUNT"
    assert INFO_NUM_X + 2 * TXT_CHAR_W_BYTES <= INFO_FORM_X, "the squadron number would run into the formation name"
    assert INFO_FORM_X + 6 * TXT_CHAR_W_BYTES <= INFO_PROMPT_X, "the formation name would run into the ESC prompt"

;  The horizon has to cross the playfield and not sit above or below it. Here
;  rather than in game/homeplanet.asm because ASSERT is evaluated where it
;  stands and TITLE_PLANET_RY comes from an include further down.
    assert PLANET_HORIZON_Y - PLANET_RY > CTX_BAR_H, "the horizon's apex is above the context bar"
    assert PLANET_HORIZON_Y - PLANET_RY < HUD_TOP, "the horizon never reaches the playfield"
