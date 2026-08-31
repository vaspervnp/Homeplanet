# improvements.md

Designs that are agreed but not yet built. One heading each. The point of a
file like this is to do the *thinking* while it is cheap — before anyone has
written a line and started defending it.

---

# 1. The Frigate is unlocked by salvaging a derelict

**Asked for:** Frigates are not buildable until mission 4. In mission 4 a
**derelict ship** appears somewhere at the edge of the play area, and salvaging
it is what unlocks them.

## Why this is a good mechanic, and the one idea that makes it cohere

**The derelict should BE a Vekhar frigate.** Then the mechanic is not "fetch
the token to open the door" — it is **reverse-engineering**. You tow an enemy
hull home and your yard learns to build one. That single choice justifies why
it is this class, why salvage specifically, and why it happens once.

It also gives the Salvage Corvette a reason to exist beyond RU. Today it pays
for itself and nothing more; here it is the only way to reach a class.

## What already exists, and is more than half of it

- **`ENT_F_DISABLED`** is the wreck flag, and `mis_count_enemies` already folds
  it into its mask — so a derelict sitting on the map does **not** stop a CLEAR
  mission completing. That trap was closed twice already (`ENT_F_WAVE`, then
  the salvage wrecks) and it is closed for this too, for free.
- **`cbt_target_flying`** means the fleet will not shoot at it and an attack
  order will not hang on it.
- **`T`** already orders the selected squadron's corvettes to fetch wrecks, and
  `slv_*` already handles closing, taking, towing to the Mothership and paying
  on arrival.
- **`eco_pick_allowed`** already gates the Destroyer to mission 5, and the
  build panel already **steps over** a class that cannot be ordered rather than
  showing and refusing it — because the yard readout is one three-letter tag
  wide and an entry you can see but cannot buy looks like a broken ENTER key.

So the work is: place the derelict, make salvaging it set a flag, gate the
Frigate on that flag, and persist it.

## The five decisions

### 1. `eco_pick_allowed` becomes a table, and CLAUDE.md predicted it

Its comment says it is "one test rather than a table of unlock missions — it
becomes a table the second time a class needs one". **This is the second time**,
and the table wants a *rule* per class rather than a mission number, because
the two gates are different in kind:

| class | gate |
|---|---|
| Destroyer | from mission 5 |
| Frigate | a flag, set by salvaging the derelict |

Cheapest shape that covers both: one byte per class, where 0 means always
available, 1..N means "from mission N", and a value above some marker means
"bit n of an unlock byte". Eight bytes of bank 4 and one branch.

### 2. It has to be FINDABLE, and this is the part that will go wrong

"Somewhere at the edges" means it can easily be off screen, and a player who
does not know it is there will never look. Three candidates, and they are not
exclusive:

- **The briefing says so.** §10 gives every mission its own text, it is already
  the place the player is told what to do, and it costs bytes of bank-4 string
  and nothing else. **Do this one regardless of the others.**
- **A marker on the border**, the way `moth_update` already points at an
  off-screen Mothership. That code is written and generalising it is honest
  work rather than new invention — but note it borrows the twelfth zoom step to
  do its projection, and having two things do that per frame wants measuring.
- **The sensor view.** It already draws dots and crosses for entities; a
  derelict is a third shape. Cheapest of the three if the player thinks to
  press `S`.

**Do not rely on the player noticing a red dot at the edge of a 320-pixel
screen.** The recurring lesson in this project is that a feature the player
cannot find does not exist — the build panel needed a whole context bar before
anyone could work out how to choose a ship.

### 3. What happens if they jump without it

Two honest options and they say different things about the game:

- **It is gone.** §1 and §10 are about a fleet that only ever shrinks and what
  is lost is lost. Consistent, harsh, and it permanently removes a class from
  the rest of a campaign — for a player who may simply not have found it.
- **It comes back.** The derelict reappears in mission 5, 6, 7… until salvaged.
  Kinder, keeps the class reachable, and costs one condition in `mis_setup`.

**Recommendation: it comes back.** The campaign is eight missions and losing a
whole class to a missed cue is a punishment for not reading rather than for
playing badly. The harsh reading is already carried by the fleet itself.

### 4. It must survive a power cycle, and the save has no room reserved

`FLEET.DAT` is magic, mission index, ship count, then the fleet, padded to two
sectors. The unlock is one bit and there is padding to put it in — but
`fleet_disc_load` range-checks what it reads because a blank disc, another
game's disc and a half-written save all arrive there. **Adding a field means
deciding what an OLD save does**: the safest answer is that a save without the
field reads as "not unlocked", which is what a zeroed pad gives for free.

Worth noting while here: **RU and the build queue are not in the save at all**
(`demo_init` calls `eco_init`, so a loaded game starts at 120 RU with an empty
yard). That is a pre-existing gap listed in `todo.md`, and if it is ever fixed
the unlock bit should go in the same pass rather than twice.

### 5. Should a derelict look different from a live enemy?

It is drawn in ink 3 today because it is flagged ENEMY, and ink 3 is §2's
attention colour. A hull that cannot shoot is not a threat, and drawing it in
**ink 2** — the scenery ink — would say so without a word of text. That is the
semantic palette doing the job it was designed for, and it is the same
reasoning that put resource patches in ink 2 rather than 3 so a rich field
could not be mistaken for a hostile.

It is not free: it means the blitter's enemy recolour has to be conditional on
DISABLED as well as ENEMY. Measure it — the recolour is on the per-entity path
and CLAUDE.md records an 8,000 T-state mistake made in exactly that kind of
loop.

## Where it goes in memory

Bank 4 for the mission data and the unlock table; the low 16K only for
whatever `mis_setup` and the salvage delivery path need, and both of those are
already there. Current headroom: `DISC.BIN` 3659, bank 4 5587, low 16K 768 —
comfortable for this.

## How it should be tested, given this project's blind spot

**Not by counting.** "The frigate is in the build list" is exactly the
assertion that passes when the wrong thing unlocked it, or when it unlocked at
mission 4 regardless of the derelict, or when any wreck at all sets the flag.

The tests that would actually hold it:

- the Frigate is **stepped over** by `,`/`.` before, and reachable after —
  read off the CONTEXT BAR, which names the class, so it is a statement about
  what the player can see;
- salvaging **an ordinary wreck** does *not* unlock it;
- the derelict followed **by slot**: it exists at setup, a corvette reaches it,
  it moves with the corvette, it arrives at the Mothership, and the flag flips
  **at arrival and not before**;
- jumping and power-cycling keeps it — `boot_disc` with a written save;
- a mission-4 CLEAR objective still completes with the derelict untouched,
  which is the `mis_count_enemies` trap stated as a test rather than trusted.

## What this does to the balance measurements

`tools/balance.py` never spends RU, so it never builds a corvette and never
sees a derelict — the feature is inert in it by construction, the same way the
salvage change was. `tools/waverate.py` inherits that tactic. **So neither tool
measures this**, and a swing in either is a tick boundary until the control
says otherwise.

What is NOT measured by anything today: whether delaying the Frigate to mission
4 makes missions 1-3 harder. Nothing scripted buys one, so only a human can
answer it.

---

# 2. The jump bar should be one pixel wide, always

**Asked for:** the bar that erases and reveals each ship on a jump should be
**1 pixel** wide, in and out, at every zoom.

It is 4 pixels today — `JFX_WIDTH` is a whole byte, because Mode 1 packs four
pixels into one and the bar is drawn with byte fills.

## The primitive already exists and is exactly right

`gfx_vline` in `src/gfx/line.asm` is *"a one-pixel-wide vertical line"*, takes
`HL` = x in 0..319 rather than a byte column, and **clips against the tactical
viewport itself** — so unlike `scr_fill_rect` it cannot spill into the context
bar or the HUD. Every marker, the move disc and the sensor view already draw
through it.

So drawing the bar is a solved problem. The awkward part is the other half.

## The real difficulty: the bar becomes finer than the thing that erases it

The effect is a **moving mask**, and the mask is `scr_fill_rect`, which works
in whole bytes. So today the bar and the black edge behind it move together
because both are byte-granular. Make the bar one pixel and they no longer
agree: the black can only ever end on a 4-pixel boundary, and the bar can sit
anywhere.

Three ways out, in order of preference:

1. **Keep the STEP byte-granular; only the bar gets thinner.** The bar sits at
   the leading edge of the black, `x = col * 4`, and is one pixel instead of
   four. Nothing else changes, the mask and the bar still agree exactly, and
   the motion is the same 8-pixel-a-step it is now. **This is almost certainly
   what was wanted** — the complaint is that the line is fat, not that it moves
   coarsely.
2. **Step in pixels and round the mask down**, so the black always ends at or
   just behind the bar. Smoother motion, at the cost of the mask lagging the
   bar by up to 3 pixels — which shows as a sliver of un-erased ship sitting
   in front of the line. Whether that reads as a flaw or as a leading edge is
   a question for a picture, not for a paragraph.
3. Read-modify-write the mask at pixel granularity. Correct, and far more
   expensive per step than either of the above in a routine that already
   repaints its whole trail every step.

**Take (1) unless a frame of (2) looks better.** It is the smallest change that
answers what was asked.

## What to check when it is done

- **Both buffers.** The vanish paints the buffer that was on show a step ago,
  so a bar drawn into one only is on screen every other frame — a flicker on
  the machine and nothing at all in a front-buffer test.
- **Look at it.** One pixel of ink 1 on black at 320×200 is thin. It may read
  as a scratch rather than as an edge, and it may disappear entirely against
  the blue lattice. That is exactly the kind of thing no test reports.
- The trail bug is still there to fall into: a bar standing proud of its sprite
  is rubbed out by the *sprite's* dirty rectangle, not the band's, so the rows
  above and below still need blacking across the whole run.

---

# 3. `T` on the title screen: a tutorial stage

**Asked for:** a `T` option on the menu that enters a unique stage where the
player learns each command.

## Two things to settle before anything else

**`T` already means TOW.** It orders the selected squadron's Salvage Corvettes
to fetch wrecks. There is no clash — the tutorial's `T` is on the **title
screen**, where the only live keys are `SPACE` and (once the music lands) `M`,
and the tow order only exists once a mission is running. But it is one letter
with two meanings, and this project has been here before: `,` and `.` step the
target with the build panel shut and the price list with it open, and the
**context bar exists because that was invisible**. Whatever the title screen
says about `SPACE` it must now also say about `T`.

**The tutorial must not be a mission.** If it touches `mis_index`, the entity
table's persistence, or `FLEET.DAT`, then playing it destroys a campaign in
progress — and it is reached from the title screen, which is exactly where
somebody with a saved game arrives. It needs its own mode: set up, played,
torn down, and `demo_init`'s restore left alone. **This is the single most
likely way to get it wrong.**

## The mechanic that makes a tutorial teach rather than lecture

**Every step is gated on the player DOING the thing, not on pressing a key to
continue.** One line of instruction, and it does not advance until the game can
see the command was issued. That is the whole design; the rest is content.

It also means each step needs a *condition*, not a keypress — "the yaw has
changed by 32", "`squad_sel` is not what it was", "`eco_ru` went up", "no
hostile is left". A small enumeration checked once a frame, dispatched from a
table, the same shape `menu_entries` and `mission_table` already have: **a step
is a row, and adding one is adding a row.**

## The scenario

Five acts, in dependency order — you cannot command what you cannot see, and
you cannot fight before you can move.

### Act 1 — Looking (no enemies, nothing can go wrong)

| step | teaches | gate |
|---|---|---|
| 1 | cursor keys orbit the camera | yaw moved a quarter turn |
| 2 | `Z`/`X` (or `+`/`-`) zoom, twelve steps | the step changed in both directions |
| 3 | `P` pans, `0` centres on the Mothership | panned away, then `0` |
| 4 | `S` is the sensor view | toggled and back |

### Act 2 — The fleet

Four interceptors and the Mothership. Few enough that a formation reads.

| step | teaches | gate |
|---|---|---|
| 5 | `1`-`9` select a squadron | the selection changed |
| 6 | `I` says what it is made of | opened and closed |
| 7 | `ENTER` opens the move disc, arrows drive it, `ENTER` confirms | an order issued **and the ships arrive** |
| 8 | `F` cycles the formation | cycled once |
| 9 | `d` divides, `c` combines | two squadrons existed, then one |
| 10 | `R` stations on the Mothership | issued |

### Act 3 — The economy

A resource patch appears within reach, and a harvester is in the fleet.

| step | teaches | gate |
|---|---|---|
| 11 | `H` sends harvesters to work | `eco_ru` rose |
| 12 | `B`, then `,`/`.`, then `ENTER` | something is on the slipway |

### Act 4 — The fight

**One** hostile interceptor arrives, alone and no tougher than ours.

| step | teaches | gate |
|---|---|---|
| 13 | `,`/`.` step the target | the target changed |
| 14 | `A` attacks, and spends itself | the hostile is gone |
| 15 | `SPACE` is the tactical pause | toggled |

`SPACE` is taught **here** and not in Act 1 on purpose: a pause means nothing
until there is something to pause.

### Act 5 — Leaving

| step | teaches | gate |
|---|---|---|
| 16 | `J` jumps when the objective is met | pressed |

`J` returns to the **title screen**, not to mission 1 — the tutorial is not the
first rung of the campaign and must not become it.

## Where the text goes, and it is the hard part

Sixteen instructions of about forty characters is ~700 bytes of bank 4 (5170
free — fine). **Where they are drawn is the problem, not what they cost.**

- **The context bar is already saying what the keys do**, on one line, in the
  ink scheme that means "this is something you press". A tutorial line and the
  bar in the same place would fight; a tutorial line *instead of* the bar loses
  the very thing that teaches the keys.
- **The HUD's third row** (`HUD_ROW_C_Y`, the hull percentage and `INCOMING`)
  is a candidate — §5.5 asked for a "γραμμή μηνυμάτων" there and it carries one
  message today. A tutorial is exactly a message line. It is 80 characters
  wide and free while the tutorial is running, since the fleet is at full hull
  and nothing is incoming.
- **Its own line, in the playfield**, under the bar. Costs playfield and needs
  its own dirty handling.

**Recommendation: the HUD's third row.** It exists, it is the message line the
design already asked for, it does not fight the context bar, and the two
together then read as "what you press" above and "what to do" below.

## How to test it, given this project's blind spot

**A test that only checks the tutorial advanced is worthless** — it passes when
the step advanced for the wrong reason, which is the failure mode a gated
tutorial has. Every gate wants two tests:

- do the **wrong** thing and assert it does **not** advance;
- do the right thing and assert it does.

Plus one that matters more than any of them: **start a campaign, save, play the
tutorial, and check the campaign is untouched** — `mis_index`, the fleet and
`FLEET.DAT` all as they were. That is the bug this feature is most likely to
ship with.

## What it does not need

Not a scripted camera, not cutscenes, not text that scrolls. The game already
stops the world for a full-screen page and already has a message row; a
tutorial that is one line and a condition per step needs no new machinery, and
that is what makes it affordable at all.
