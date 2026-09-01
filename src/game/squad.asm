; ============================================================================
;  game/squad.asm -- squadron membership: the equates and the counts
; ============================================================================
;  THE COMMANDS ARE IN game/squadcmd.asm, WHICH IS IN BANK 4. They run on a
;  keypress; the counts below are read by the HUD and by phase4_fly and stay
;  in the low 16K, for the same reason game/order.asm's variables do.
;
;  Nine squadrons, numbered 1-9, selected with the number keys. The fleet
;  starts as a single squadron and the player carves it up.
;
;  A squadron is ACTIVE if and only if it has ships in it. There is no
;  separate "exists" flag, which is what makes "a squadron left with 0 ships
;  is deactivated" true by construction rather than by remembering to check.
;
;  squad_count is DERIVED, never authoritative: every command edits the
;  ENT_SQUAD field of the entities it moves and then calls squad_refresh,
;  which recounts the whole table from scratch. Keeping running totals in step
;  with the entity list is exactly the sort of bookkeeping that drifts once
;  ships start dying, and a recount of the player's region is a couple of
;  thousand T-states on a keypress.
;
;  Commands (Homeplanet.md section 9 plus the fleet-splitting the player asked
;  for):
;
;      1-9  select that squadron, if it has any ships
;      d    DIVIDE: split the selection in half, the new half taking the next
;           free number after it
;      m    move one ship to the next number, creating it if need be
;      n    move one ship to the previous number; for 1 that is 9
;      c    COMBINE the selection with the next active squadron
; ----------------------------------------------------------------------------

SQUAD_MAX           equ 9
SQUAD_NONE          equ 0

; ============================================================================
;  State
; ============================================================================
squad_sel:          defb 1

;  Ships per squadron. Index 0 is unused so a squadron number indexes directly.
;  Derived by squad_recount; never written anywhere else.
squad_count:        defs SQUAD_MAX + 1, 0

squad_index:        defb 0              ; scratch for the table walks
squad_pending:      defb 0

