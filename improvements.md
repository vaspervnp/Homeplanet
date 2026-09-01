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

---

# 4. Twenty missions, and a planet behind the last one

**Asked for:** the campaign goes to twenty missions, and the last one has a
planet in the background.

## Twenty missions is a BALANCE change wearing a data change's clothes

Adding a mission is adding a row — `mission_table` is a name, where the enemy
is, where the resources are, and what winning looks like, and `mis_setup` never
rebuilds the player's ships. Twelve more rows is perhaps 900 bytes of bank 4
against 5170 free. `mis_index` is a byte. `fleet_disc_load` range-checks it and
would need the new bound. **All of that is the easy part and none of it is the
problem.**

The problem is that **the campaign cannot sustain eight today.**
`tools/balance.py` — hold station, press `A` — loses the Mothership at mission
7. §1 and §10 are about a fleet that only ever shrinks, and eight missions is
tuned so that it *nearly* lasts. Twenty of the same is not a longer campaign,
it is the same campaign with twelve rows nobody reaches.

So the real work is one of:

- **A gentler curve.** Missions 9-20 cannot keep escalating the picket at the
  rate 1-8 do; the enemy counts in `campaign.asm` would have to flatten or
  cycle.
- **More income, and a reason to spend it.** The economy already closes the
  loop — patches, harvesters, RU, a queue of ten — and the resources were just
  multiplied by six. A twenty-mission campaign is one where you are expected to
  *rebuild*, not merely survive, which makes the yard the spine of the second
  half rather than a luxury.
- **Both**, which is likely, and which is a tuning job measured with
  `tools/balance.py` and `tools/waverate.py` rather than argued.

**Do not add twelve rows and call it done.** Measure first: run `balance.py` and
find out what actually kills the run at 7, because that number decides whether
missions 9-20 are content or arithmetic.

Worth noting too: the **Vekhar field only interceptors**. §8's balance triangle
is something the player's fleet has and the enemy does not use. A twenty-mission
campaign that never varies its opposition will feel like one mission twenty
times — a class byte per enemy row in `campaign.asm` is data, not engineering,
and it matters more at twenty than at eight.

## The planet is a rendering problem, not an art problem

It is also the right ending: §1 is about a fleet carrying sixty thousand
sleepers away from a lost world, so **arriving somewhere is the story**, and a
planet appearing behind the last mission is the payoff for the whole campaign.

### The obstacle: this renderer assumes the background is BLACK

`phase4_erase` clears each dirty rectangle to **0**. Every moving thing in the
game — ships, markers, the move disc, the labels — is erased by filling its
rectangle with black, and that is what makes a 5 fps 3D game affordable on a
4 MHz Z80. Put a filled disc behind the fleet and every ship punches a black
hole in it on the frame it moves.

The three ways out, in order of what they cost:

1. **Draw the planet as a LIMB, not a disc** — an arc, a crescent, a ring of
   the terminator. Most of it is black, so a dirty rectangle mostly erases
   nothing; where it does cross the arc, the repair is a handful of pixels.
   This is the same reasoning that makes §4.1's reference plane a lattice of
   dots rather than a grid of lines, and the same reason resource patches are
   three pixels rather than a blob. **Cheapest, most in keeping, and it still
   reads as a planet.**
2. **Redraw the intersection after the erase.** Correct for a filled disc, and
   it puts a per-rectangle test-and-repair into the hot path — the erase is
   75,000 T-states of a 530,000 T frame already.
3. **Erase to the background instead of to black**, which means the background
   has to be readable per byte — a second buffer, or a generator. Neither the
   memory nor the frame has room.

**Recommendation: (1).** A crescent limb across the lower part of the playfield,
in ink 2 — the scenery ink, which is what the stars and the reference grid
already use, and which cannot be confused with a hostile.

### The rest of it

- **It is static**, so it belongs with the markers: projected against a hash of
  yaw, pitch, zoom and focus, and redrawn only on the frames the camera moves.
  `gfx/markproj.asm` already does exactly this for twenty-one fixed points.
- **It must respect `spr_clip_top`/`spr_clip_bottom`.** `gfx_vline` does;
  `scr_fill_rect` does not, and that has already caught this project twice.
- **Where does the arc come from?** A quarter of a circle in a table, mirrored
  four ways, the way `sin7` is one quadrant folded by `cam_sin`. A radius of
  ~48 pixels is 48 bytes.
- **Only mission 20 draws it**, so it is a flag in the mission row — one bit
  beside the objective, not a new table.

---

# 5. Split the entity table: the fleet and the enemy get their own ceilings

**Asked for:** a separate limit for enemies, not counted against the fleet's, so
waves keep arriving when the player's fleet is at its own limit.

## Why it matters more than it looks

`ENT_MAX` is 48 and it is **one pool for everything** — the fleet, the
Mothership, the mission's picket, every wave ship, every wreck, every
explosion. `ent_find_free` returns "the first slot not in use", from zero.

So a player who builds hard eventually fills the low slots, and then
`wave_send` cannot find anywhere to put a wave. **The waves silently stop**,
and the entire mechanism that makes `J` a decision rather than a formality
quietly switches itself off for the player who has done best. Nothing reports
it. That is the same shape as every other bug in this project's history: not a
crash, just a thing that stops happening.

The same starvation hits `mis_spawn_enemy` at mission setup, and the derelict
in §1 of this file, which is an enemy-region entity too.

## The shape: partition by index, do not build a second table

Keep the one array and split it in two by slot number:

```
slots 0 .. ENT_PLAYER_MAX-1     the fleet, and the Mothership
slots ENT_PLAYER_MAX .. ENT_MAX-1   hostiles, waves, wrecks, derelicts
```

`ent_find_free` becomes two entry points over a range — `ent_find_free_ours`
and `ent_find_free_theirs` — and **that is nearly the whole change**. Every
walking loop in the game already steps the whole table looking at
`ENT_FLAGS`, so `phase4_fly`, `phase4_project`, `cbt_update`, `wave_health`,
`squad_refresh` and the rest need no change at all.

Two things that already depend on slot order and must be checked rather than
assumed:

- **`fleet_restore` packs survivors down into slots `0..n-1`** and re-finds the
  Mothership by class as it loads — that stays inside the player region and is
  fine, but it is the routine that has already caused one "the Mothership was
  lost" bug and deserves a test rather than a glance.
- **`ENT_NO_TARGET` and every cached slot index.** A zeroed `ENT_TARGET` names
  slot 0, which is now definitely a friendly. That was already true and already
  guarded by `cbt_fire_if_able` checking sides at the moment of firing; the
  partition does not break it, but it makes slot 0 permanently the player's,
  which is worth knowing.

## The number, and it is a design decision not an arithmetic one

The frame rate binds long before the table does: **24 entities measured at
5.8-6.5 fps against a 12.5 target**, and going from 21 to 31 costs a third of a
frame. So the split is not about finding room, it is about **deciding who gets
the frame time**.

A reasonable first cut of the existing 48:

| region | slots | why |
|---|---|---|
| fleet | 28 | 16 formation slots plus growth, and the Mothership |
| hostile | 20 | `WAVE_MAX` 8, `SLV_WRECK_MAX` 4, and mission 8's picket of 12 does not fit alongside a full wave — which is itself worth knowing |

**Raising `ENT_MAX` past 48 is raising the wrong ceiling.** The table already
holds more than the frame can draw; see the note under §4.

## It makes the fleet's cap REAL, so the game has to say so

Today running out of slots is invisible because it barely happens. Give the
fleet its own ceiling and a player will hit it — and `eco_queue` currently just
fails to find a slot with nothing said.

The context bar already has the vocabulary: it says `QUEUE FULL` when ten
orders are outstanding, re-derived from `eco_queue`'s own refusals in
`eco_queue`'s own order. **A `FLEET FULL` beside it is the same mechanism and
the same three lines**, and without it the yard takes RU for a ship that will
never appear.

## How to test it

- **A wave arrives with the fleet at its ceiling.** That is the whole point of
  the change and it is one test: fill the player region, run the clock past
  `WAVE_FIRST_FRAMES`, assert a hostile appeared.
- A fleet at its ceiling **cannot** build another ship, and the bar says so.
- `mis_setup` on the mission with the largest picket, with a full fleet, still
  spawns every hostile the row asks for — or, if it cannot, fails visibly
  rather than quietly fielding fewer enemies than the mission was designed
  around.
- The Mothership is still found after `fleet_restore` with the fleet at its
  ceiling.

---

# 6. A scoring system

**Asked for:** a score.

## The one decision that decides all the others

**Score what SURVIVES, not what you destroyed.**

§1 of the design document is a convoy carrying sixty thousand sleepers away from
a lost world; §10 is a fleet that only ever shrinks. A game whose whole
identity is that loss is permanent should not hand out points for kills — it
should count what you managed to bring through.

That is not a stylistic preference, it is the only version that does not fight
the rest of the game:

- **A kill score rewards loitering**, and the attack waves exist specifically to
  make loitering cost something. `tools/waverate.py` exists to prove the loiter
  is survivable but expensive. Points for kills tells the player to stay and
  farm the very waves that were built to move them on.
- **Salvage already pays for kills**, in RU, at the hull's own class cost. A
  kill score would be a second reward for the same act, compounding a loop that
  is already the most profitable thing in the game.

So: the score goes **up** for arriving with a fleet, and there is no way to
grind it.

## What it is made of, and all of it already exists

| component | where it already is |
|---|---|
| missions reached | `mis_index` |
| fleet hull remaining | `wave_hull` — summed `ENT_HULL`, computed every fourth frame |
| what that hull is worth | `eco_class_cost`, the yard's own prices, so a Destroyer counts for what it cost |
| RU banked | `eco_ru` — unspent resources are husbanded ones |
| the Mothership | **not a component.** Losing it ends the campaign, so it is a gate, not a term |

Nothing here needs a new tally walked per frame. `wave_health` already walks
the entity table once every fourth frame and has both hull and class in hand.

## The constraint that will decide the shape: four digits

`txt_draw_num4` draws HL in four digits by subtracting powers of ten. There is
no five-digit printer, and `ECO_RU_MAX` is 9999 for exactly this reason — six
times the resources made a campaign's mining sum past what the readout could
draw, and 16600 came out with `@` in the thousands column.

So either **the score fits 9999**, or somebody writes a wider printer. A score
that fits four digits is also a score a player can hold in their head, which is
an argument for it rather than against.

**And there is no general divide in this game.** `wave_pct_of` is the only one —
eight steps of a restoring divide and a multiply — and it exists because the
denominator is whatever fleet the player has. A scoring formula built out of
multiplications and shifts costs nothing; one with a division per class costs a
real slice of a frame. Design it as adds and shifts.

## Where it goes

- **Per mission, on the briefing.** That screen already appears between
  missions, already stops the world, and already has room. "What this one cost
  you" is exactly the reading a player wants at that moment.
- **At the end of the campaign**, which today does not exist as a screen —
  `mis_failed` is the Mothership being lost and there is no arrival screen for
  the other outcome. §4 of this file proposes a planet behind the last mission;
  a final score belongs on the same screen.

## Persistence, and the thing to decide first

A high score has to survive the power going off, which means the disc, which
means `FLEET.DAT` — two raw sectors on track 39, written by our own FDC code,
with padding to spare and a magic and a range check on the way in.

**But a high score is not campaign state**, and putting it in the save means it
dies with a save that is overwritten by a new game. Decide before writing which
of these is wanted:

- **The score of the run in progress**, which belongs in the save beside the
  fleet;
- **a best-ever score**, which has to outlive any single campaign and therefore
  wants its own field that a new game does not clear.

They are different features and the second is the one people mean by
"high score".

## What no test can tell you

Whether the number is *satisfying*. A score that only moves at the end of a
mission gives a player nothing to play against moment to moment; one that
ticks constantly becomes wallpaper. That is a judgement to make by watching
somebody play, and this project has a recorder — `tools/record.py` — for
exactly that kind of question.

---

# 7. Double the fleet's capacity — BUILT

**Asked for:** twice the fleet capacity — `ENT_PLAYER_MAX` from 28 to 56, and
`ENT_MAX` from 48 to 76. **That is what shipped**, and CLAUDE.md's "Doubling
the fleet, and the four things that had to happen first" is what it took.

> **Read the rest of this section as a record of being wrong, because it was,
> four times, and the shape of each is worth more than the design was.**
>
> - **"The entity table has to leave the low 16K", at a cost of ~70 test call
>   sites.** It did not have to. It and the four other `ENT_MAX` arrays are
>   declared **above `code_end`** — they are uninitialised, so they cost
>   address space and not the file — and `DISC.BIN` gained 2 KB while they grew
>   by half again. Not one test call site moved. The mistake was assuming the
>   only two places a byte can live are "in the low 16K" and "in a bank"; the
>   third is "in the low 16K but not in the file".
> - **"The frame rate is the ceiling, and it does not move."** It moved a
>   long way. `cbt_find_enemy` swept the whole table through `ent_addr`, per
>   ship, every frame once the shooting stopped — O(fleet × table), so it grew
>   with the *square* of the ceiling. Searching one region with a stepped
>   pointer took the ordinary sixteen-ship game from 5.0 fps to **6.9**, and a
>   fleet of 40 now runs better than 27 used to. This section reasoned from
>   CLAUDE.md's budget table, and every line of that table is per-entity;
>   the routine that actually bound it is per-entity *per entity* and is not
>   in it.
> - **"The honest number is somewhere in the thirties."** It is 56, because of
>   the above. What survives is the *reason* the number had to be measured.
> - **The FLEET.DAT arithmetic and `FORM_SLOTS` were both right**, and they are
>   the two that were checked against the source rather than reasoned about.

**This one fights three measured limits, and one of them is a hard break rather
than a cost.** None of that means don't; it means know the bill before signing.

## It breaks the save, and that is arithmetic not opinion

`FLEET.DAT` is **two raw sectors, `FLEET_BLOCK_SIZE` 1024 bytes**, with a
four-byte header in front of the fleet in the same block so a save is two
writes from one address rather than a gather.

```
28 ships x ENT_SIZE 20 + 4  =   564   fits 1024
56 ships x 20         + 4  =  1124   DOES NOT
```

So doubling the fleet **needs a third sector**, or a narrower per-ship record
in the save than the 20 bytes it holds in RAM. Both are real work and the
second is the better one — most of `ENT_SIZE` is per-frame state (target,
timer, order, dest) that a restored fleet does not need and `mis_setup` would
overwrite anyway. A save record of position, yaw, class, hull, squad and load
is nine or ten bytes, which fits 56 ships in one sector with room to spare and
would be worth doing even at 28.

## The memory: the entity table has to leave the low 16K

`entities` is `ENT_MAX * 20` — 960 bytes today, **1520 at 76**. The low 16K has
about 512 free and must keep ~450 for the test scratch, so the extra 560 bytes
are not there.

They do not have to be: **the blitter never reads the entity table.** It reads
`phase4_vis`, so `entities` is not touched between `class_tier_addr` and
`class_blit_done` and could sit in bank 4, which has ~5100 free.

**The cost is not bytes, it is test call sites.** CLAUDE.md's own rule —
*"Code moves for free; data costs a hundred test call sites"* — and this is
precisely that: dozens of tests read `ENTITIES` with `read_ram` and would all
need `read_bank4`. It is mechanical and it is a day.

`phase4_vis` is 6 bytes an entity and **must stay in the low 16K** — the
blitter does read that one. 76 entities is 456 bytes against 288, so +168 in
the tightest 16K there is.

## The frame rate is the ceiling, and it does not move

Measured, from CLAUDE.md's own budget table: **24 entities cost ~530,000
T-states and run at 5.8-6.5 fps against a 12.5 target.** Going from 21 to 31
costs a third of a frame. Most of the cost is linear in the entity count and
the z-sort is O(n²).

So a *fleet* of 56 in the air at once is not a slower game, it is a different
one — somewhere near 2 fps. **The table already holds more than the frame can
draw**, which is why raising `ENT_MAX` was called raising the wrong ceiling.

Two things make it less bleak than that, and both are real:

- **`phase4_group` consolidates at wide zoom.** Sixteen entities become two
  blits at the widest steps and the frame rate goes *up*, from 4.75 to 6.25.
  A large fleet is affordable **while the player is zoomed out**, which is how
  a large battle is actually watched.
- **The optimisations CLAUDE.md names are unspent**: caching each entry's depth
  beside its index cuts the sort comparison from ~140 T to ~40, and a
  high-water mark stops `phase4_fly` and `phase4_project` walking empty slots.
  Neither has been done.

## `FORM_SLOTS` is 16 and nothing says so

A squadron with more than sixteen ships **shares formation slots** — two ships
at the same point. It works, it is invisible, and it becomes the normal case
the moment a fleet can be 56. Doubling the fleet without touching this means
doubling the number of ships flying inside each other.

## What I would do instead, and why it is not evasion

**Narrow the save record first.** It is the one piece of this that is pure gain:
it is needed for any increase at all, it halves the save's size at the current
28, and it removes a limit nobody has hit yet rather than one everybody will.

Then raise `ENT_PLAYER_MAX` **as far as the frame rate allows and no further**,
measured with `tools/balance.py` and by watching the frame counter — not to 56
because 56 is twice 28. The honest number is somewhere in the thirties, and it
is a measurement rather than a design decision.

---

# 8. `J` starts a countdown from ten, and `ESC` cancels it

**Asked for:** pressing `J` begins a countdown from 10. `ESC` cancels it. If it
reaches 0, the jump happens.

## The decision the whole feature turns on: does the world keep running?

**It must.** If the countdown freezes the battle the way the briefing and the
jump wipe do, then **nothing can happen during it that would make anyone press
ESC** — and a cancel nobody would ever use is decoration. The ten seconds only
mean something if they are ten seconds of live battle.

That makes this a real mechanic rather than a delay: pressing `J` is
**announcing that you are leaving**, and then surviving the announcement. It
fits §1's fiction exactly — a jump drive spools, and a fleet spooling one is a
fleet not manoeuvring.

And it is why `ESC` is the right key rather than `J` again: you cancel because
something arrived, and `ESC` already means "get me out of this mode" for the
move disc and the build panel.

## It costs game time, and that is measurable

Ten seconds of unattended battle per jump, seven jumps in the campaign as it
stands. CLAUDE.md records the precedent precisely: a **non-freezing jump reveal
of two seconds cost `tools/balance.py` two ships in mission 4 where it loses
none**. Ten seconds, eight times, is a bigger change than that.

So this is a **balance change wearing a UI change's clothes** and must be
measured, not reasoned about:

- `tools/balance.py` before and after, with the control (520 T of `djnz` in
  `demo_update`, changing nothing else) — CLAUDE.md's figure is stale, so
  measure HEAD yourself;
- `tools/waverate.py`, because `mis_timer` keeps advancing and the countdown is
  ten more seconds in which a wave can arrive. The floor is 70%.

Whether that cost is *wanted* is the owner's call, not a defect. Announcing
your departure and paying for it is a fair mechanic. But nobody should discover
the price by accident.

## Where `ESC` sits, and it is not free

`ESC` is already overloaded and the order is deliberate. `phase4_commands`
opens the orders menu on `ESC` **only when `disc_active` and `eco_build_open`
are both clear**, because while either is up `order_update` reads it as
"cancel". `ctx_classify` re-derives the same order so the bar names the key the
player is most likely to press.

A countdown is a **fourth** mode in that chain and has to be inserted in the
right place — above the menu, beside the disc and the panel. Get the order
wrong and pressing `ESC` to abort a jump opens the orders menu instead, which
is the exact class of bug the context bar was built to make visible.

## The player has to SEE it, and the bar is where

A countdown the player cannot read is a ten-second pause followed by a
surprise. The context bar is the right place and already has the vocabulary:

- **`PAUSED` is the precedent** — a state, not a key, drawn in ink 3, §2's
  attention colour. `JUMPING 7  ESC CANCEL` is the same shape.
- It repaints only when the words change, and **the number changes every
  second**, so this is the first thing on the bar that repaints on a timer.
  Nine repaints over the countdown is nothing, but `ctx_changed` compares
  against a shadow and the seconds counter has to be part of what it compares
  or the bar will show `10` for ten seconds.

The HUD's `JUMP` label in ink 3 says the jump is *available*; the bar would say
it is *happening*. Those are different statements and both are wanted.

## The counter itself

Ten seconds at the measured 5 fps is **50 game frames**, which is one byte, and
`mis_timer` already proves the pattern — a counter stepped once per
`mis_update` and reset in exactly one place. Count game frames and divide by
five for the display, or hold a seconds byte and a frames-within-the-second
byte; the second is cheaper than a divide and this game has only one divide for
a reason.

**`order_paused` must stop it**, the way it already stops `mis_timer`. A
tactical pause that let the countdown run would be a pause that jumps you out
of the mission.

## What it does not need

No new screen, no new sound necessarily — though `snd_fx_jump_out` currently
fires when the wipe starts, and a countdown gives it somewhere better to begin.
A tick per second would be the obvious addition and is a separate decision.
