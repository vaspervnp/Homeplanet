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
