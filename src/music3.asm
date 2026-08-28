; ============================================================================
;  music3.asm -- MUSIC3.BIN: "Deep Space", composed rather than transcribed
; ============================================================================
;  The other two are somebody's recording, measured. This one was written in
;  tools/genmusic.py, and its COMPOSE section states the three decisions that
;  make it sound like space instead of like a tune -- no thirds in the
;  harmony, the bass moving under a held melody note, and the lead dropping
;  out for a third of the cycle.
;
;  64 seconds exactly, on all three voices, so it comes round cleanly.
; ----------------------------------------------------------------------------
    include "musicplay.asm"
    include "gen/mus_full_deepspace.asm"
