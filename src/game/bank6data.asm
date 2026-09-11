; ============================================================================
;  game/bank6data.asm -- tables read once through bank6_copy, in BANK 6
; ============================================================================
;  The title screen's flight of ships: x (signed word), y, the sprite block,
;  its width in bytes and height, and the bank it lives in -- eight bytes a
;  ship, TITLE_SHIPS of them. title_draw_ships copies the whole table into
;  bank7_line (forty bytes: exactly the table) once a frame, at two frames a
;  second, and walks the copy. It left bank 4 for the squadron alarm's room.
; ----------------------------------------------------------------------------
title_ship_table:
    defw   36
    defb  104
    defw  frigate_c
    defb  FRIGATE_C_W_BYTES, FRIGATE_C_H
    defb  GA_BANK_6
    defw   18
    defb   92
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_7
    defw   55
    defb   94
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_7
    defw    7
    defb  120
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_7
    defw   66
    defb  122
    defw  interceptor_c
    defb  INTERCEPTOR_C_W_BYTES, INTERCEPTOR_C_H
    defb  GA_BANK_7
