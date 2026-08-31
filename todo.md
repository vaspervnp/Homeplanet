# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

## 0. THE ORDER, agreed: clean the tests → repack the libraries → title
## music → the PNG tool

Step 0 is done (MUSIC1 and MUSIC2 are off the disc, 462 tests). **Step 1 is
the repack, and it is what unblocks step 2** — the title music is written and
does not fit. Do them in that order or the third one wastes a session.

---

## 1. Repack the sprite libraries as 3+3+2 — DONE

*(4598 bytes of `DISC.BIN` headroom and 6227 of bank 4. Two of the three
things this entry predicted were wrong; see "The repack, and the three things
it was expected to buy" in CLAUDE.md, and note that a NINTH class no longer
fits the reserved disc tracks. The entry below is kept for the reasoning.)*

## 1a. The original entry

Six yaw views made a library 4320 bytes, so THREE fit in a 16K window. Eight
classes are 3+3+2 across banks 5-7 instead of 2+2+2 plus two riding inside
`DISC.BIN`. It buys, in one change:

- **about 900 bytes of `DISC.BIN`**, which has 343 and is the binding
  constraint on the whole project;
- **four tracks of the disc**, which ran out once already and put a music
  binary on top of bank 5;
- **the two bank-4 libraries' worth of bank 4**, which has 235.

It touches `LIB_SECTORS`, `LIB_TRACKS_PER_BANK`, `class_bank`,
`tools/discbanks.py` and the `BANK` sections of `src/main.asm` — all of which
already read their layout from one place, which is the whole reason this is a
day's work and not a week's.

**The test that matters is `test_shipclass`'s
`test_each_bank_holds_exactly_what_the_build_put_on_the_disc`.** It compares
each bank against `build/bank*.raw`. A repack that gets an offset wrong does
not crash — it gives a bank full of the wrong ship — and that test is the only
thing that says so.

---

## 0. Harvesting does not stop when RU hits the ceiling

`eco_earn` saturates at `ECO_RU_MAX` 9999, so the RU stops rising — but the
harvesters keep mining, draining a **finite** patch for income that is thrown
away.

**It is the same bug as the twin below, from the other side.** With no patch
left, `eco_harvester_step` does `ret nc` and `phase4_fly` skips
`ENT_ORDER_HARVEST`, so nobody steers the ship: it stops dead and `fleet_save`
carries the coordinates into the next mission. A full treasury creates the
identical state.

One fix for both: when there is nothing useful to do — no patch with stock, or
RU at the ceiling — **spend the order** to `ENT_ORDER_IDLE` and let
`phase4_fly` bring it home. Exactly the attack order's precedent. Guard it on
HARVEST: clearing unconditionally takes `ENT_ORDER_TOW` with it and stops the
salvage.

## 0. `dismiss_briefing` can return before the reveal starts

`mis_brief_key` clears the briefing a frame before the jump's reveal begins, so
`wait_for_jump_wipe`'s first poll sees `jfx_mode == 0` and returns. The reveal
then stops the world for ~857 emulator frames and **any command sent into it is
lost** — a scripted walk through the campaign advances on alternate missions
only, which looks exactly like a jump being refused.

Left alone deliberately: `wait_for_jump_wipe`'s own docstring records that
`tools/balance.py` comes out with a different campaign when that poll interval
changes, so fixing it invalidates every measurement taken around it. Do it on
its own, with the control run.

## 0aa. The jump reveal is not the same SPEED as the vanish

Asked for and attempted and reverted. The vanish holds each column for
`JFX_VANISH_DWELL` **vertical blanks** (23); the reveal holds it for
`JFX_REVEAL_DWELL` **game frames**. Setting the reveal to 2 overshot — it
finished before its own sound, and two tests caught it.

**The mistake was assuming a game frame is ten vertical blanks** because the
game measures 5 fps. It is not constant: the frame rate falls with the entity
count, and the start of a reveal is a nearly empty screen, so its frames are
much faster than 5 fps. The reveal's pace IS the frame rate's; the vanish's is
not.

So the value has to be **measured, not calculated** — and it drags the arrival
sound with it, because `snd_fx_jump_in` has to be the same length as the
picture. Note the assert in `src/main.asm` that stops the vanish being
shortened below its own sound; the same care is owed the other half.

## 0b. The AY frequency constant is an octave out

`tools/genmusic.py` has `AY_CLOCK = 125000` and computes `period = 125000 / f`.
The CPC clocks the AY at 1 MHz and a full tone cycle is 16 × period, so the
relation is **`f = 62500 / p`** — confirmed against the emulator's own
implementation and standard for the machine. The generator therefore asks for
**twice** the period it needs, and **MUSIC1, MUSIC2 and MUSIC3 all sound an
octave below what was composed.**

Nobody has noticed, which is itself informative: the two transcriptions are
ambient and the composed one has no reference to be flat against.

**It is one constant, and it moves every note in all three tunes at once.**
That is why it has not been changed: whether they are better an octave up is a
decision for an ear. Note the bass would move from A1 (55 Hz) to A2 — the
current A1 is close to the bottom of what the AY's 12-bit period can express
and near the bottom of what the CPC's speaker reproduces at all, so up is
probably right.

`src/sys/sound.asm` carries the correct figure in the comment beside
`snd_fx_jump_out` and the wrong one beside `snd_fx_fire`; the effects were
tuned by ear against the wrong number, so they are right as they sound and
their comments are what is misleading.

## 0a. The harvester has the salvage bug's twin, and it is two lines

`eco_harvester_step` does `call eco_nearest_patch : ret nc` when every patch is
mined out, and `phase4_fly` skips `ENT_ORDER_HARVEST` — so a harvester on an
exhausted map is steered by NOBODY, stops dead, and `fleet_save` carries those
coordinates into the next mission. Exactly the shape of the attack order that
never spent itself, and exactly the shape the tow order was written to avoid.
The fix is the same: spend the order. It was left out of the salvage change on
purpose, so it would not be inside those measurements.

## 1a. A jump EFFECT — DONE

*(See "The jump wipe" in CLAUDE.md. The entry below is kept for the
reasoning, and note it was wrong about scr_fill_rect honouring the clips.)*

## 1a-orig. A jump EFFECT: a line that wipes the ships away and back

Asked for after the Salvage Corvette and to be done after it. A vertical line
appears at one side of the ships and travels to the other, **erasing them as it
passes**. On arriving in the next mission the reverse happens and the line
**reveals** them.

### Do it as a moving MASK, not as a copy

The obvious implementation of the reveal is to draw the new scene into the back
buffer and copy it column by column from behind the line. Do not: the CPC's
screen rows are not contiguous, so a column is 158 separate addresses through
`scr_line_addr`, and that is about 29,000 T-states a column before anything is
drawn.

The cheap version looks identical and is three calls a frame. The scene is
already being drawn every frame by the normal loop, so:

- **vanishing** — draw the frame as usual, then `scr_fill_rect` black over
  everything BEHIND the line, then draw the line. As it advances, more of the
  screen is black.
- **appearing** — the same, with the fill AHEAD of it instead. `mis_wipe`
  already leaves the screen black, so the first frames are black anyway.

`scr_fill_rect` and `gfx_vline` both exist and both already honour
`spr_clip_top`/`spr_clip_bottom`, so the effect cannot spill into the context
bar or the HUD without asking.

### Where it hooks

`mis_jump` is what the player presses `J` for; it increments `mis_index`,
writes the fleet to the DISC (about a third of a second with the drive spinning
up) and then opens the briefing. The vanish belongs BEFORE the briefing and the
reveal AFTER it is dismissed. Note `harness.wait_for_briefing` exists because a
jump is not instant and a test that looked immediately concluded there was no
briefing to dismiss.

### Decisions nobody has made

- **How long.** The game runs at ~5 fps, so a sweep of 80 byte-columns at one
  column a game frame is sixteen seconds and far too slow. It wants either
  several columns a frame or its own tight loop that does not wait on
  `demo_wait_frame`.
- **What ink the line is.** §2's palette is semantic and all three inks already
  mean something: 1 friendly/text, 2 scenery/chrome, 3 attention. A jump is not
  an alarm.
- **Which way it travels**, and whether the reveal mirrors it or repeats it.
- **Whether the HUD and the context bar are wiped too**, or the effect stays
  inside the playfield. They are redrawn from dirty flags, so wiping them means
  setting those flags.

## 1b. A queued ship joins the squadron selected when it FINISHES

Not when it was ordered. That was already true of the single slipway; the
queue widens the window from one build time to ten, so it is worth fixing now.
It costs a second byte per queue entry.

Also worth knowing: **neither RU nor the yard is in the disc save.**
`demo_init` calls `eco_init`, so a loaded game starts at 120 RU with an empty
queue. Pre-existing and unchanged, and more visible now a queue can be ten
deep.

## 2. Music on the TITLE SCREEN, on `M`

**It is written and it does not fit.** `src/sys/music.asm` is complete and is
deliberately NOT included in the build; putting it in took bank 4 from 235
bytes to 20, the low 16K from 1024 to 512, and `DISC.BIN` over `#A700`, where
`src/disc.asm`'s own assert stopped the build. Do step 1 first and this becomes
four lines of wiring.

What it needs when the room exists:

- `include "sys/music.asm"` after `sys/sound.asm`, and
  `include "gen/mus_menu.asm"` in the bank-4 section (199 bytes);
- `title_open` calls `mus_start`, `title_key` checks `KEY_M` before `KEY_SPACE`
  and calls `mus_toggle`, and calls `mus_stop` on the way out;
- `mus_update` from the title's frame loop;
- ONE change in `sound.asm`: channel B takes a TONE mixer mask rather than a
  noise one while `snd_music_on` is set. The diff is in this session's history.

**Why it writes no PSG registers at all** is the part worth not re-deriving:
`snd_update` owns the AY, runs from the 50 Hz interrupt, rebuilds the mixer
every tick and MUTES every idle channel — a second writer is silenced within a
tick whatever it writes. So the music fills in the three VOICE BLOCKS instead,
which turn out to be a held note already (`timer=200, pri=0, vol=v<<4, dvol=0,
period=p, dstep=0`, refreshed every frame). And it advances by the difference
in `sys_tick_50hz` rather than by frames, so the tempo is right whatever the
frame rate does AND none of it has to run in the interrupt — which matters,
because the interrupt can fire with a sprite bank paged into the window.

---

## 3. A sprite PNG export/import tool

Asked for and not started. `tools/rt2sprite.py` already reads the RetroTools
project JSON and `tools/mkships.py` already writes PNG contact sheets, so both
halves of the pixel handling exist; what is missing is a round trip that a
person can edit in an ordinary paint program and put back. Note that the mask
is the hard part -- see the graphics-pipeline section of CLAUDE.md for why
RetroTools' own mask cannot be used, and that pen 0 is transparent when a
frame has none.

---

## 4. Music IN THE GAME — the battle

**Half of this is done.** `MUSIC1` and `MUSIC2` are on the disc and play, the
converter works, and the note streams for the two in-game loops are generated
and waiting in `src/gen/mus_loop_*.asm`. What is left is putting them behind
the game, and it has one hard problem and one taste problem.

### The hard problem: the interrupt and the bank window

The player has to tick at 50 Hz, which means the interrupt. But the interrupt
can fire **while `phase4_blit_one` has bank 5, 6 or 7 paged into `#4000`** —
that is the one rule in `game/shipclass.asm` — so a player that reads its note
stream out of a bank would read whichever sprite library happened to be under
the window, and a player that paged its own bank in would corrupt the blit it
interrupted. Neither is survivable.

There is no fourth option that is free. The three that exist:

- **A shadow byte of "which bank is paged in".** The gate array is write-only,
  so the interrupt cannot ask. Every `OUT` in `class_tier_addr` would have to
  update it and the interrupt would restore it. Touches the hottest code in
  the game to serve the coldest.
- **A prefetch ring in the low 16K.** The main loop refills a few events per
  voice from the bank; the interrupt only counts down and writes the AY, and
  never touches the window at all. This is the shape the rest of the project
  already has — the interrupt does the minimum — and it is the recommended one.
  A ring of eight events a voice is 24 bytes each and covers well over a second
  at 5 fps.
- **Put the loops in the low 16K.** 723 + 624 bytes against 1024 free. One of
  them fits and both do not, and it spends the reserve the tests need.

### The taste problem: three channels, and the game already uses them

`snd_update` owns all three voices for the effects and costs 4,433 T-states of
the ~6,300 a 50 Hz tick spends. Music plus a shot plus a kill does not fit in
three channels, so something has to give: music on two voices and effects on
the third, or effects stealing a voice for as long as they last. **This is a
decision about how the game should sound and it has not been made** — it wants
an ear, not an argument.

The intro is easier than the battle and should come first: the title screen
has no effects competing with it and no blitting, so `title_draw` could drive
the player straight from the frame loop.

---

## 2. What is already built, and where it is

`tools/genmusic.py` decodes with ffmpeg and finds pitches by FFT in three
bands, one per AY voice. **Its header is careful about what is measured and
what is chosen**: the pitches are measurement and can be re-run; the three
bands and where they are cut are an arrangement, and are the first thing to
change if a tune sounds wrong.

`src/musicplay.asm` is the player and `src/music1.asm` / `src/music2.asm` are
the two standalone programs. They poll VSYNC rather than using interrupts,
which is exactly the freedom the in-game version does not have.

**`make music` re-analyses; it is a dependency on the ogg files rather than
something every build pays for** (about half a minute for four and a half
minutes of audio).

`tests/test_music.py` reads the AY's registers back out of the chip while the
player runs and checks the periods against the generated table — that is the
only test of the whole chain, and it is why the periods are known to be right
rather than merely plausible.

### The disc filled up, and the music landed on a sprite bank

`LIB_TRACK` is **20** now and was 12. `DISC.BIN` + the 16 KB splash + the two
music binaries come to about twelve tracks, and AMSDOS wrote `MUSIC2.BIN`
straight over bank 5 — the library tracks are raw sectors, not files, so they
are not in its allocation map and it hands the same blocks out again.

**It did not fail.** `lib_load` read its sectors, set `LIB_OK`, and the game
came up with a bank full of music player. The guard written alongside the music
asked whether the load had SUCCEEDED and passed throughout; what caught it was
`test_shipclass`'s comparison of each bank against `build/bank*.raw`. Both
tests compare CONTENT now.

Twenty leaves eight tracks of headroom. Repacking the libraries as 3+3+2 across
banks 5-7 is still the move that buys real room, and it now buys it in two
places: about 900 bytes of `DISC.BIN` (which has 343) and four tracks.

---

## 3. The original entry, kept for the parts still true

`musicsamples/MorningLight.ogg` (4.3 MB) and `musicsamples/Tranquility.ogg`
(2.7 MB). Wanted: music on the **intro** and **during play**, and two files on
the disc that can be run on their own as `MUSIC1` and `MUSIC2`. In an upper
bank.

### There was no ogg converter, and now there is one

**This entry said the only paths were hand transcription or nothing. That was
wrong, and the reason it was wrong is worth keeping:** it assumed the tool had
to recognise music the way a person does. It does not. Both pieces turned out
to have a strong, stable fundamental in each of three registers -- MorningLight
holds a bass note for seven seconds at a time at 50-70% of its band's energy --
so an FFT and a peak per band gets the notes out, and the result can be checked
against the chip afterwards. Measure the input before concluding it cannot be
done.

The paragraph below is still exactly right about `genmusic.py` in
GravassistCPC, which is a different tool with a different job.

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
