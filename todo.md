# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

## 1. Music — the two `musicsamples/*.ogg`, in the game and on the disc

`musicsamples/MorningLight.ogg` (4.3 MB) and `musicsamples/Tranquility.ogg`
(2.7 MB). Wanted: music on the **intro** and **during play**, and two files on
the disc that can be run on their own as `MUSIC1` and `MUSIC2`. In an upper
bank.

**Read these three things before starting, because two of them contradict the
request as stated.**

### There is no ogg converter

`~/repos/GravassistCPC/tools/genmusic.py` is **not** an audio converter. It is
a note-table generator: the melody is written out in Python as `("D2", 100)`
pairs and the tool turns note names into AY periods (`period = 125000 / f`),
which is the one calculation worth not doing by hand. Its own comments say
where the tunes came from — *"Μεταγραμμένα από το
musicsamples/8-bit-marching-drums_160bpm.wav"* — and **μεταγραμμένα means
transcribed, by a person, by ear.** The `musicsamples/` directory in that
project is reference material, not input.

So the job is not "run the ogg through the tool". It is one of:

- **transcribe** the two pieces into `genmusic.py`'s note form — which is the
  path that has actually been walked once, and the only one that gives three
  clean AY voices;
- or find a real chain (ogg → MIDI → AY, or an Arkos Tracker / `.ym` player),
  none of which exists in either repo today;
- or sample-playback, which a 4 MHz Z80 with a 6128's memory will not do for
  anything like the length of these files.

The output format is three bytes a note — index, volume, duration — because
whole firmware sound blocks would cost triple. Homeplanet does **not** use the
firmware sound queue (§ "No firmware calls after boot"), so the player has to
be ours; `src/sys/sound.asm` already owns the AY, drives software envelopes,
and shares port A with `key_scan` under a documented contract. A music player
has to go through it, not around it.

### There is no free bank

`OUT (#7Fxx)` reaches banks 4-7 and **all four are in use** — bank 4 is code
and data with 258 bytes left, banks 5-7 hold two 4320-byte sprite libraries
each. "Put it in an upper bank" has no bank to put it in as things stand.

What is available, and it is real: six yaw views made a library 4320 bytes, so
**three** fit in a 16K window. Repacking eight libraries as 3+3+2 across banks
5, 6 and 7 leaves **7744 bytes free in bank 7** — and takes the two that
currently travel inside `DISC.BIN` (interceptor and frigate) out of it, which
is 900 bytes of headroom under `#A700` back as well. That is the space. It
costs `LIB_SECTORS`, `LIB_TRACKS_PER_BANK`, `class_bank`, `tools/discbanks.py`
and the `BANK` sections in `src/main.asm`, all of which already read their
layout from one place.

### The frame budget, and the interrupt

`snd_update` runs from the 50 Hz IM 1 handler and costs 4,433 T-states with
three voices live, out of the ~6,300 a whole tick currently spends. A music
player that also runs at 50 Hz is competing for the same tick **and the same
three AY channels** as the game's own effects — so "music plus a shot plus a
kill" is a mixing decision (does a sound effect steal a voice, or is music
two voices and effects one?), not just a memory one. That decision should be
made before any of the above is written.

`MUSIC1`/`MUSIC2` as standalone disc files is the easy half and is a good
first step: it is a loader and a player with no game around it, which proves
the player before it has to share anything.

*(The two items that were here — showing that the game is paused, and a
context bar along the top — were one job and are done together. See "The
context bar" in CLAUDE.md for what it shows, how `spr_clip_top` was threaded
through the blitter, `gfx_vline` and `mark_store`, and the page-flip bug it
turned up.)*

*(The third — using the whole screen for the playfield — is done. See "Using
the width of the screen" in CLAUDE.md: `proj_mag`, six patched bytes carried
in the zoom record, and the eleven lines the projection had been low ever
since the context bar arrived. It came out ~100 T-states an entity CHEAPER
than what it replaced, and the note that item carried about mission 8 has its
answer: the frame time came back and the campaign did not change at all.)*

*(The fourth — "selecting squadrons mixes them up" — is fixed. It was not the
selection and it was not the membership: `squad_dest` gave a newly created
squadron a FIXED station out of `order_home`, up to 6000 units from where its
ships actually were, so dividing a formation flung half of it off the screen.
See "A squadron is born where its ships are" in CLAUDE.md for the rule, and
for why every existing squadron test — all of which counted — agreed with the
bug.)*

*(The fifth — attack waves after three minutes, random in number, strength and
spacing, and a fleet-health percentage on screen — is done. See "Attack waves,
and the price of staying" in CLAUDE.md for the scaling rule (hull, not
headcount), the measured win rate, and the three design decisions; and "The
fleet's hull, on the screen" for the third HUD row and the only division in
the game. `tools/waverate.py` is the measuring stick.)*

*(The sixth — "an attacking ship never comes home" — is fixed.
`cbt_fire_if_able` spends the order the moment its re-acquire comes back
`ENT_NO_TARGET`, dropping it to `ENT_ORDER_IDLE` and not to `ENT_ORDER_GUARD`
as this entry proposed: `cbt_retarget_one` returns early for GUARD, so a ship
put there would keep whatever target it picked up next and never be re-pointed
at a nearer one. See "An attack order has to be spent, and for a long time
nothing spent it" in CLAUDE.md for why the clear is guarded on ATTACK — a
harvester reaches the same line — and for the one swing in `tools/balance.py`
that has ever survived its own control.)*

*(Zoom on `+` and `-` is done. `-` is a key of its own; `+` is not a key at
all -- it is SHIFT + `;`, and the matrix reports only the physical key, so
KEY_PLUS is the `;` position. Same trick as KEY_SLASH for `?`.)*
