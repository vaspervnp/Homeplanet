; ============================================================================
;  music2.asm -- MUSIC2.BIN: MorningLight, whole, on its own
; ============================================================================
;  Two lines, because the player and the tune are separate things: the stream
;  is generated into src/gen and the player never learns which one it got.
;  See src/musicplay.asm for why this is a program rather than part of the
;  game, and tools/genmusic.py for where the notes came from.
; ----------------------------------------------------------------------------
    include "musicplay.asm"
    include "gen/mus_full_morninglight.asm"
