; ============================================================================
;  helptext.asm -- the words on the help page, in bank 4
; ============================================================================
;  Section 9's control table, as the player sees it. In the bank rather than
;  the low 16K because it is about 400 bytes of pure data and the code area
;  has 512 left in total.
;
;  Two columns of HELP_ROWS lines each, stored back to back and each
;  zero-terminated; help_column walks them in order, so the ORDER here is the
;  layout. Left column is looking and moving, right column is ordering.
;
;  The font has no lower case. Keep every line inside 19 characters or it
;  runs into the other column -- txt_draw clips at the screen edge, not at
;  the column, so there is nothing to catch it but this comment.
; ----------------------------------------------------------------------------

help_title:
    defb "HOMEPLANET - CONTROLS",0
help_prompt:
    defb "ESC - BACK TO THE BATTLE",0

;  --- Left: the camera, the view, the disc --------------------------------
help_col_left:
    defb "1-9 SQUADRON",0
    defb "0   MOTHERSHIP",0
    defb "ARROWS  CAMERA",0
    defb "Z X ZOOM",0
    defb "SPACE   PAUSE",0
    defb "ENTER   MOVE DISC",0
    defb "ESC CANCEL MOVE",0
    defb "SHIFT+UP/DN HEIGHT",0
    defb "TAB SENSORS",0
    defb "F   FORMATION",0

;  --- Right: what the fleet is told to do ---------------------------------
help_col_right:
    defb "A   ATTACK",0
    defb ", . PICK TARGET",0
    defb "G   GUARD",0
    defb "R   STATION",0
    defb "H   HARVEST",0
    defb "B   BUILD",0
    defb "J   JUMP",0
    defb "D   DIVIDE SQUAD",0
    defb "M N MOVE ONE SHIP",0
    defb "C   COMBINE SQUADS",0
