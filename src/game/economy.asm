; ============================================================================
;  game/economy.asm -- resources, harvesters and construction (phase 7)
; ============================================================================
;  THE LOW HALF: the equates, and every byte of state. The code is in
;  game/economyrun.asm, in bank 4 -- see the head of that file for why it went
;  and why it is legal there.
;
;  The loop the design calls for: harvesters fly to a resource patch, fill up,
;  fly back to the Mothership, and turn what they carry into RU. RU pays for
;  new ships, which come out of the Mothership one at a time.
;
;      H   put the selected squadron on harvesting duty
;      B   open the build panel; , and . pick a class, ENTER queues it
;
;  A harvester's whole state is its ENT_ORDER plus how much it is carrying, so
;  there is no separate harvester table to keep in step with the entity list --
;  the same reason squad_count is recounted rather than maintained.
;
;  Patches are fixed points with a stock that runs down. When one is empty the
;  harvesters that were using it look for another; when they are all empty the
;  economy stops, which is the pressure the mission design wants.
;
;  THE QUEUE
;  ---------
;  Section 5.5 asks the HUD strip for "Πόροι (RU) και ουρά κατασκευής" -- the
;  resources AND the build queue -- and for a long time there was no queue: the
;  yard took one order and refused every other. So a player who had just mined
;  a field dry had to sit and watch a countdown before they could spend the
;  next 40 RU, which is the opposite of what an economy is for.
;
;  It is a FIFO of ECO_QUEUE_MAX orders, mixed classes, and the head of it IS
;  the slipway: eco_build_class and eco_build_timer keep meaning exactly what
;  they meant, and the array behind them holds the ones still waiting. That is
;  why the array is one short of the maximum -- ten orders outstanding is the
;  slipway plus nine in the line. Keeping the head where it was rather than at
;  index 0 of the array is what stops this being two copies of "what is being
;  built": the HUD, ctx_build_state and half a dozen tests all read
;  eco_build_class and none of them had to learn a new name.
; ----------------------------------------------------------------------------

ECO_PATCH_COUNT         equ 4
ECO_PATCH_SIZE      equ 8               ; x, y, z (6) + stock (2)

ECO_HARVEST_RANGE   equ 24              ; camera-scale, as combat's range is
ECO_LOAD_MAX        equ 60              ; RU a harvester carries
ECO_LOAD_RATE       equ 3               ; RU mined per frame in contact
ECO_START_RU        equ 120

;  Orders the yard will hold at once, the one on the slipway included.
ECO_QUEUE_MAX       equ 10
ECO_QUEUE_WAIT      equ ECO_QUEUE_MAX - 1   ; ...so nine of them are waiting

;  The ceiling on RU, and it is the READOUT's rather than the arithmetic's.
;  eco_ru is a word and always has been, but phase4_hud draws it with
;  txt_draw_num4, which subtracts powers of ten into four digits: hand it
;  16600 and the thousands column comes out as '@'. The patches carry several
;  times what they used to (see game/campaign.asm), so a whole campaign's
;  mining now adds up past 65535 if none of it is ever spent -- which would
;  wrap the word as well as break the field. Saturating at what the strip can
;  say keeps the number on screen equal to the number in memory, which is the
;  only property worth having here.
ECO_RU_MAX          equ 9999

;  eco_build_order, eco_class_cost and eco_class_frames are in
;  game/classdata.asm, in bank 4 with the rest of the per-class tables. They
;  are read when the player presses ENTER, which is never inside the one
;  window where bank 4 is paged out.


; ============================================================================
;  State
; ============================================================================
eco_ru:             defw 0              ; resource units in hand
eco_index:          defb 0
eco_ent:            defw 0
eco_patch_ptr:      defw 0
eco_walk:           defw 0
eco_new_slot:       defb 0
eco_pick_class:     defb 0
eco_pick_dir:       defb 0
eco_amount:         defb 0
eco_rep_price:      defb 0
eco_rep_cost:       defw 0

;  WHETHER THE YARD HAS ALREADY MENDED ANYTHING THIS MISSION.
;
;  Cleared by mis_setup, so "once per mission" is true by construction rather
;  than by anyone remembering to reset it -- the same way mis_timer's two
;  minutes are per mission. In the low 16K with the rest of the economy's
;  state, so a test reads it with read_ram.
;
;  It is set only when a ship was ACTUALLY mended. A press that found nothing
;  damaged, or nothing affordable, has not used the one repair up -- spending
;  it on a no-op would be a rule the player could trip over without ever
;  seeing why.
eco_repaired:       defb 0

eco_build_open:     defb 0              ; the panel is showing
eco_build_pick:     defb 0              ; which class the panel is offering
eco_build_class:    defb #FF            ; what is on the slipway
eco_build_timer:    defb 0

;  The orders WAITING behind the slipway, oldest first. The one being built is
;  eco_build_class and is not in here, so a full yard is eco_build_class set
;  and eco_queue_len == ECO_QUEUE_WAIT.
;
;  None of this is touched by mis_setup, so the queue -- like the half-built
;  hull on the slipway, which has always behaved this way -- SURVIVES A JUMP.
;  It has to: the RU was taken when the order was placed, so throwing the queue
;  away at the jump would silently destroy the player's money, and refunding it
;  is a second rule that would have to be kept in step with the first. Section
;  10's fleet carries between missions with its losses; the yard is part of
;  that fleet.
eco_queue_len:      defb 0
eco_queue_buf:      defs ECO_QUEUE_WAIT, 0

;  ...AND WHICH SQUADRON EACH ORDER WAS PLACED BY, one byte alongside each
;  class. A ship used to join whatever squadron was selected when it FINISHED,
;  which was already odd with a single slipway and is worse with a queue: the
;  window between ordering and delivery is now ten build times, and a player
;  who orders three interceptors for squadron 1 and then presses `3` to look
;  at something gets them all in squadron 3.
;
;  The order is a plan, and a plan says who it is for. Paying for it is the
;  moment the player expressed that -- the same moment eco_queue takes the RU,
;  and for the same reason.
;
;  A PARALLEL ARRAY rather than a wider entry, because eco_queue_buf's shape is
;  read by half a dozen tests and by ctx_build_state, and a stride of two would
;  have to be learned by all of them. Both are `defs ECO_QUEUE_WAIT`, so they
;  are the same length by construction and there is nothing here for an assert
;  to catch -- one was written and taken out again, because an assert that
;  cannot fail is a comment pretending to be a check.
eco_build_squad:    defb 0              ; ...for the one ON the slipway
eco_queue_squad:    defs ECO_QUEUE_WAIT, 0

;  Where the fields are and how much is left in them. Written only by
;  mis_setup, out of the mission descriptor in bank 4.
eco_patches:        defs ECO_PATCH_COUNT * ECO_PATCH_SIZE, 0
