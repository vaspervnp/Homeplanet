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
;  RASM's BANK directive, and why the build needs it now.
;
;  There are four 16K images in this file and three of them are assembled at
;  #4000: the game's bank 4, and the two-libraries-each banks 5, 6 and 7 that
;  hold the ship classes DISC.BIN has no room for. A plain second `org #4000`
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
;  Table layout invariants.
;
;  The lookup routines index these tables by page register -- qsq_f does
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
;  The low 16K is the whole world below the bank window. If we ever spill past
;  #4000 the next thing we would overwrite is paged sprite data, and the
;  symptom would be baffling. Fail the build instead -- and leave room for the
;  stack, which is growing down from #4000 to meet us.
; ----------------------------------------------------------------------------
;  PRINTED BEFORE THE ASSERT, deliberately: RASM stops at the failing assert,
;  and "code + tables overflow into the stack" without a number is a question
;  rather than an answer. The figure is negative when it fails, which is
;  exactly how much has to come back out.
    print "code+tables:", {hex}CODE_START, "..", {hex}code_end, " free:", CODE_LIMIT - STACK_SIZE - code_end

    assert code_end < CODE_LIMIT - STACK_SIZE, "code + tables overflow into the stack"

; ============================================================================
;  Output
; ============================================================================
;  A headerless blob only. src/disc.asm wraps it in the relocating stub that
;  actually gets it to #0040 -- see the long explanation there.
; ----------------------------------------------------------------------------
    save "build/home.raw", CODE_START, code_end - CODE_START


; ============================================================================
;  Bank 4 -- the sprite library
; ============================================================================
;  Assembled at #4000 but NOT part of the low-memory image: src/disc.asm pages
;  extended bank 4 into the window and copies this there at load time, so the
;  labels below resolve to bank-4 addresses and the low 16K keeps its space.
;
;  Bank 4 is the RESTING state of the window, and it holds two things that
;  could not be more different: the interceptor and frigate sprite libraries,
;  and all the code that only runs while the game is stopped. Six more
;  libraries live in banks 5-7 and are read off the disc by lib_load; the one
;  rule that keeps that safe is in game/shipclass.asm.
; ----------------------------------------------------------------------------
    BANK 1

    org BANK_WINDOW
bank4_start:
    include "gen/spr_interceptor.asm"
    include "gen/spr_frigate.asm"
    include "gen/zoom.asm"
    include "game/classdata.asm"
    include "game/formdata.asm"
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
;  The cached half of the marker pass. It runs only when the camera hash has
;  changed and always with the window at rest, so it is bank-4 code by the
;  same rule as everything above it -- but it is the ONLY thing here that runs
;  from inside the frame loop, so read the note at the top of the file.
    include "gfx/markproj.asm"
bank4_end:

; ----------------------------------------------------------------------------
;  Uninitialised bank storage, deliberately BELOW the save above.
;
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
    defs ENT_MAX * ENT_SIZE, 0
    defs FLEET_BLOCK_SIZE - FLEET_HDR_SIZE - ENT_MAX * ENT_SIZE, 0
bank4_limit:

    assert fleet_buffer == fleet_block + FLEET_HDR_SIZE, "the fleet must follow its header"
    assert bank4_limit - fleet_block == FLEET_BLOCK_SIZE, "the save block is not whole sectors"

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

    save "build/sprites.raw", BANK_WINDOW, bank4_end - BANK_WINDOW


; ============================================================================
;  Banks 5, 6 and 7 -- the six ship classes DISC.BIN cannot carry
; ============================================================================
;  These are NOT in DISC.BIN. They go on the disc as raw sectors and lib_load
;  reads them in at boot -- src/sys/libload.asm has the arithmetic and the
;  reason. Two 5.62 KB libraries a bank, which is what LIB_SECTORS is sized
;  for; the assert below is what stops a third being added by accident.
;
;  Nothing but sprite data may go in here. Bank 4 is paged out while one of
;  these is under the window, so code assembled here could only ever run in a
;  world where the game's own static screens do not exist.
; ----------------------------------------------------------------------------
    BANK 2

    org BANK_WINDOW
bank5_start:
    include "gen/spr_mothership.asm"
    include "gen/spr_harvester.asm"
bank5_end:
    save "build/bank5.raw", BANK_WINDOW, bank5_end - BANK_WINDOW

    BANK 3

    org BANK_WINDOW
bank6_start:
    include "gen/spr_scout.asm"
    include "gen/spr_bomber.asm"
bank6_end:
    save "build/bank6.raw", BANK_WINDOW, bank6_end - BANK_WINDOW

    BANK 4

    org BANK_WINDOW
bank7_start:
    include "gen/spr_salvage.asm"
    include "gen/spr_destroyer.asm"
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
    assert class_fallback - class_hull == CLASS_COUNT,    "class_hull is not CLASS_COUNT entries"
    assert class_tag - class_fallback == CLASS_COUNT,     "class_fallback is not CLASS_COUNT entries"
    assert class_tag_end - class_tag == CLASS_COUNT * 4,  "class_tag is not CLASS_COUNT tags"
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

    assert ctx_text_play_end - ctx_text_play <= CTX_BAR_CHARS + 1, "the playing line is wider than the screen"
    assert ctx_text_disc_end - ctx_text_disc <= CTX_BAR_CHARS + 1, "the move disc line is wider than the screen"
    assert (ctx_text_pause_tail - ctx_text_paused - 1) * TXT_CHAR_W_BYTES <= CTX_PAUSE_TAIL_X, "PAUSED runs into the rest of its line"
    assert CTX_PAUSE_TAIL_X + (ctx_text_pause_end - ctx_text_pause_tail - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "the paused line is wider than the screen"

;  The build panel's four fields, each against the start of the next one.
    assert CTX_NAME_X + CTX_NAME_CHARS * TXT_CHAR_W_BYTES <= CTX_COST_X, "a class name would run into the cost"
    assert CTX_COST_X + 3 * TXT_CHAR_W_BYTES <= CTX_RU_X, "the cost figure would run into the RU label"
    assert CTX_RU_X + (ctx_text_pick - ctx_text_ru - 1) * TXT_CHAR_W_BYTES <= CTX_KEYS_X, "the RU label would run into the keys"
    assert CTX_KEYS_X + (ctx_text_pick_end - ctx_text_pick - 1) * TXT_CHAR_W_BYTES <= CTX_STAT_X, "the key hint would run into the status"
    assert CTX_STAT_X + (ctx_text_poor - ctx_text_buy - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "ENTER BUY runs off the screen"
    assert CTX_STAT_X + (ctx_text_busy - ctx_text_poor - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "NEED MORE RU runs off the screen"
    assert CTX_STAT_X + (ctx_text_end - ctx_text_busy - 1) * TXT_CHAR_W_BYTES <= SCR_BYTES_PER_LINE, "YARD BUSY runs off the screen"

;  A SUM, and it only catches gross overrun -- one name eighteen characters
;  long and three short ones would slip through. There is no way to ask RASM
;  for the longest of eight strings, and the alternative was a fixed stride
;  that costs 25 bytes to buy an exact check on a table that changes once a
;  year. Keep every name inside CTX_NAME_CHARS by hand.
    assert class_name_end - class_name <= CLASS_COUNT * (CTX_NAME_CHARS + 1), "the class names do not fit the context bar's name field"
