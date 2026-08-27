; ============================================================================
;  helptext.asm -- the words on the help page, in bank 4
; ============================================================================
;  Section 9's control table, as the player sees it. In the bank rather than
;  the low 16K because it is about 400 bytes of pure data and the code area
;  has 512 left in total.
;
;  ONLY THE LEFT COLUMN IS HERE. The right-hand one is menu_entries -- the
;  orders menu's own list, drawn through the same walker with its key ids
;  stepped over. Two lists of the same commands would have drifted the first
;  time one grew a row, and the second copy was a hundred and thirty bytes of
;  a bank with none to spare.
;
;  So what is left here is everything the orders menu does NOT offer: looking,
;  moving, and carving the fleet up. Stored back to back and each
;  zero-terminated; help_column walks them in order, so the ORDER here is the
;  layout.
;
;  The font has no lower case. Keep every line inside 19 characters or it
;  runs into the other column -- txt_draw clips at the screen edge, not at
;  the column, so there is nothing to catch it but this comment.
; ----------------------------------------------------------------------------

help_title:
    defb "HOMEPLANET - CONTROLS",0
help_prompt:
    defb "ESC - BACK",0

;  --- Left: the camera, the view, and reshaping the fleet ------------------
help_col_left:
    defb "1-9 SQUADRON",0
    defb "0   MOTHERSHIP",0
    defb "ARROWS  CAMERA",0
    defb "Z X + - ZOOM",0
    defb "SPACE   PAUSE",0
    defb "ESC CANCEL MOVE",0
    defb "SHIFT+UP/DN HEIGHT",0
    defb ", . PICK TARGET",0
    defb "D C DIVIDE/COMBINE",0
    defb "M N MOVE ONE SHIP",0

;  --- Right: menu_entries, in game/menutext.asm ---------------------------
