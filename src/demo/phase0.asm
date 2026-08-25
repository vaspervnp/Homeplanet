; ============================================================================
;  demo/phase0.asm -- the Phase 0 acceptance test, running on the CPC itself
; ============================================================================
;  Success criterion from Homeplanet.md section 13:
;      "Σταθερή εναλλαγή οθονών στο VSync"
;
;  Two blocks bounce around a static frame at 50 Hz. They move a whole byte
;  per frame, so any flip that lands mid-frame shows up immediately as a torn
;  or half-erased block.
;
;  This is also the first real exercise of the per-buffer dirty-rectangle
;  scheme the engine will use for good (section 5.3): each buffer remembers
;  what IT is holding, because with double buffering the back buffer contains
;  the frame from two ticks ago, not one.
; ----------------------------------------------------------------------------

DEMO_OBJ_COUNT      equ 2
DEMO_OBJ_SIZE       equ 11

; Record layout, twice over (X then Y) plus the drawing parameters:
DEMO_O_X            equ 0               ; position, byte column / pixel line
DEMO_O_DX           equ 1               ; signed step
DEMO_O_XMIN         equ 2
DEMO_O_XMAX         equ 3
DEMO_O_Y            equ 4
DEMO_O_DY           equ 5
DEMO_O_YMIN         equ 6
DEMO_O_YMAX         equ 7
DEMO_O_W            equ 8               ; width in bytes
DEMO_O_H            equ 9               ; height in lines
DEMO_O_FILL         equ 10              ; Mode 1 solid-pen byte


; ----------------------------------------------------------------------------
;  demo_init -- put the static frame into BOTH buffers
;
;  It has to go into both, because nothing ever redraws it: the dirty
;  rectangles only ever touch the moving blocks.
;  Uses: everything
; ----------------------------------------------------------------------------
demo_init:
    call demo_draw_frame
    call demo_swap_back
    call demo_draw_frame
    jp demo_swap_back

demo_swap_back:
    ld hl,scr_back_page
    ld a,(hl)
    xor SCREEN_XOR / 256
    ld (hl),a
    ret

demo_draw_frame:
    ld bc,#0000                         ; x=0, y=0
    ld de,#5002                         ; w=80 bytes, h=2 lines
    ld a,SOLID_INK_2
    call scr_fill_rect

    ld bc,#00C6                         ; x=0, y=198
    ld de,#5002
    ld a,SOLID_INK_2
    call scr_fill_rect

    ld bc,#0000                         ; x=0, y=0
    ld de,#01C8                         ; w=1 byte, h=200 lines
    ld a,SOLID_INK_2
    call scr_fill_rect

    ld bc,#4F00                         ; x=79, y=0
    ld de,#01C8
    ld a,SOLID_INK_2
    jp scr_fill_rect


; ----------------------------------------------------------------------------
;  demo_update -- one frame into the back buffer
;
;  Erase-everything-then-draw-everything, in two passes. Doing it per object
;  would let object 1's erase punch a hole in object 0 wherever they overlap.
;  Uses: everything
; ----------------------------------------------------------------------------
demo_update:
    ; Which dirty list belongs to the buffer we are about to draw into?
    ld hl,demo_dirty_a
    ld a,(scr_back_page)
    cp SCREEN_A / 256
    jr z,@list_ok
    ld hl,demo_dirty_b
@list_ok:
    ld (demo_dirty_ptr),hl

    ; ---- pass 1: erase ---------------------------------------------------
    ld a,DEMO_OBJ_COUNT
@erase_loop:
    push af
    ld hl,(demo_dirty_ptr)
    ld b,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld (demo_dirty_ptr),hl
    xor a                               ; fill with empty space
    call scr_fill_rect                  ; returns immediately if w or h is 0
    pop af
    dec a
    jr nz,@erase_loop

    ; ---- pass 2: move, draw, remember ------------------------------------
    ld hl,(demo_dirty_ptr)
    ld de,-(DEMO_OBJ_COUNT * 4)
    add hl,de
    ld (demo_dirty_ptr),hl

    ld hl,demo_objects
    ld (demo_obj_ptr),hl

    ld a,DEMO_OBJ_COUNT
@draw_loop:
    push af

    call demo_move_object               ; -> B=x C=y D=w E=h A=fill
    push bc
    push de
    call scr_fill_rect
    pop de
    pop bc

    ld hl,(demo_dirty_ptr)
    ld (hl),b
    inc hl
    ld (hl),c
    inc hl
    ld (hl),d
    inc hl
    ld (hl),e
    inc hl
    ld (demo_dirty_ptr),hl

    ld hl,(demo_obj_ptr)
    ld de,DEMO_OBJ_SIZE
    add hl,de
    ld (demo_obj_ptr),hl

    pop af
    dec a
    jr nz,@draw_loop
    ret


; ----------------------------------------------------------------------------
;  demo_move_object -- advance the object at (demo_obj_ptr) and describe it
;  Out: B = x byte, C = y line, D = width bytes, E = height lines, A = fill
;  Uses: AF, BC, DE, HL
; ----------------------------------------------------------------------------
demo_move_object:
    ld hl,(demo_obj_ptr)
    call demo_step_field                ; X; HL ends up at DEMO_O_Y
    ld (demo_tmp_x),a
    call demo_step_field                ; Y; HL ends up at DEMO_O_W
    ld c,a

    ld d,(hl)                           ; w
    inc hl
    ld e,(hl)                           ; h
    inc hl
    ld a,(demo_tmp_x)
    ld b,a
    ld a,(hl)                           ; fill
    ret

; ----------------------------------------------------------------------------
;  demo_step_field -- step one axis and bounce it off its limits
;  In : HL -> [pos, delta, min, max]
;  Out: A = new pos, the record is updated, HL advanced past the four bytes
;  Uses: AF, C, DE, HL
; ----------------------------------------------------------------------------
demo_step_field:
    ld a,(hl)                           ; pos
    inc hl
    ld c,(hl)                           ; delta
    inc hl
    ld d,(hl)                           ; min
    inc hl
    ld e,(hl)                           ; max
    inc hl                              ; -> next field

    add a,c
    cp d
    jr c,@bounce                        ; below min (also catches the 0->255 wrap)
    inc e
    cp e
    jr c,@store                         ; at or below max
@bounce:
    sub c                               ; undo the step
    push af
    xor a
    sub c
    ld c,a                              ; delta = -delta
    pop af
    add a,c                             ; and step the other way
@store:
    push hl
    dec hl
    dec hl
    dec hl
    dec hl                              ; -> pos
    ld (hl),a
    inc hl
    ld (hl),c
    pop hl
    ret


; ============================================================================
;  Data
; ============================================================================

demo_dirty_ptr:     defw 0
demo_obj_ptr:       defw 0
demo_tmp_x:         defb 0

;  Per-buffer record of what was drawn there, so it can be erased when that
;  buffer comes round again. Starts zeroed: width 0 means "nothing yet".
demo_dirty_a:       defs DEMO_OBJ_COUNT * 4, 0
demo_dirty_b:       defs DEMO_OBJ_COUNT * 4, 0

demo_objects:
    ;    x  dx xmin xmax    y  dy ymin ymax    w   h  fill
    defb 10,  1,   1,  72,  40,  1,   2, 180,  5, 14, SOLID_INK_1
    defb 60, -1,   1,  72, 120, -1,   2, 180,  4, 12, SOLID_INK_3
