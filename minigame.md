# minigame.md — the vortex chase

A design, not a plan to build. The question asked was *"is there room for a
minigame like chasing a single enemy interceptor with a vessel of mine through
a vortex?"*, and the honest answer is in two halves: **yes for the idea, and
almost not for the bytes.** The second half is most of this document, because
on this machine it is the part that decides what the first half is allowed to
be.

Figures are from the build at the time of writing. Check them again before
believing any of the arithmetic below — every one of them has moved this week.

---

## 1. Is there room?

| | free | what it costs `DISC.BIN` |
|---|---|---|
| low 16K | **34** usable (484 less the ~450 test floor) | byte for byte |
| bank 4 | **1542** | byte for byte — the image is STORED, not packed |
| bank 7 | **2315** | **nothing**; raw sectors already read at boot |
| `DISC.BIN` | **409** of 26368 | — |

**`DISC.BIN` is the constraint and nothing else is close.** Bank 4 shows 1542
bytes free, and spending more than 409 of them fails the `#A700` assert — the
bank-4 image travels inside the file and the packer has been a net loss on code
since the sprite libraries left. So the budget for a minigame is:

> **~400 bytes of CODE, plus as much DATA as you like in bank 7.**

Four hundred bytes is not nothing — `game/jumpfx.asm` and `game/homeplanet.asm`
are each about that — but it is not a second game either. Any design that does
not fit inside it has to pay for itself first, and there are two ways to do
that:

- **Move more text to bank 7.** The class names, the tutorial's seventeen
  lines and the context bar's words are all still in bank 4 and all are read
  with the window at rest. `bank7_fetch` already exists and is general; this is
  the cheapest lever left and it is worth roughly a kilobyte.
- **`class_standin` is 2688 bytes of the WINDOW** (not of the file) for a
  no-disc fallback. It does not help `DISC.BIN`, so it is not the answer here.

**Frame budget is a non-issue.** The minigame stops the world, exactly as the
title screen, the briefing, the help page, the orders menu, the squadron page
and the game-over screen do. It gets the whole 265,000 T-states of a frame and
competes with nothing. That is also the rule that puts every byte of it in
bank 4 rather than the low 16K — which is what makes the 400-byte budget the
right one to design against, rather than the 34.

---

## 2. What it is

**One of your ships, one Vekhar interceptor, a tunnel, and a timer.** The enemy
runs; you close. It ends when you are inside weapons range long enough to fire,
or when the tunnel does.

It is a **chase down a receding tube**, not a dogfight. That is a deliberate
narrowing and it is what makes it affordable: a tube is a stack of concentric
ellipses and there is already a routine in this codebase that walks an ellipse
one pixel at a time with the mask rotated incrementally
(`planet_span_right`/`planet_span_left` in `game/homeplanet.asm`). The vortex is
that routine called five or six times at different radii, and nothing else.

### The loop

- The two ships are drawn at fixed screen positions — yours low and centre,
  the enemy somewhere ahead — and **the tunnel moves, not the ships.** This is
  the oldest trick in the genre and it is the one that costs nothing: there is
  no 3D here at all, no `proj_point`, no camera matrix.
- **Left and right steer.** The enemy's lateral position drifts on a fixed
  pattern; yours follows the keys. The gap between the two is what closes or
  opens.
- **The tunnel rings scroll towards the viewer** by cycling which radius each
  ring is drawn at. Six rings and a phase counter.
- **Distance** is one byte. It falls while your lateral offset is close to the
  enemy's and rises while it is not. Reaching zero is the win.
- **The tunnel is finite.** A second byte counts down; reaching zero is the
  loss. That is what makes steering a decision rather than a formality.

### Why a tunnel and not open space

Open space needs a camera, and a camera needs `proj_point` — 4,880 T-states an
entity and, far worse, a whole coordinate system to keep the two ships inside.
A tube is a **one-dimensional** game wearing a 3D coat: the only state that
matters is the difference between two lateral offsets. That fits in about a
dozen bytes and reads on screen as a chase.

---

## 3. What it reuses, and what it must not

Everything in the left column already exists and is tested. That is the whole
reason this is affordable.

| Wanted | Use | Note |
|---|---|---|
| the rings | `planet_span_*`, `planet_hw_at` | the ellipse walker and its half-width table, already interpolated |
| the two ships | `spr_blit` via `class_tier_addr` | real art, all six yaw views, for nothing |
| the enemy's colour | `spr_enemy` | pen 1 → pen 3 in the blitter, no second library |
| clearing the screen | `static_wipe` | the same six instructions the four other stopped-world screens begin with |
| the prompt and the result text | `txt_draw`, and the words in **bank 7** | free file-wise |
| a chase and a hit | `snd_fx_*` on **channel C** | the only voice nothing else in the game uses |

**It must not use `phase4_*` anything.** The entity table, the visible list, the
draw order and the dirty-rectangle lists all belong to the mission that is
paused underneath. Two ships at fixed screen positions need no dirty rectangles
at all — the whole playfield is redrawn every frame, which at 158 lines is
affordable precisely because nothing else is running.

**It must not touch `mis_*` or `wave_*` state.** The tutorial is the model here:
`tut_exit` restores nothing because it never wrote anything, and that is what
makes "it cannot damage a campaign" a cheap claim rather than a careful one.

---

## 4. Where it sits in the campaign

Three candidates, and the third is the one worth building.

- **On the jump.** A vortex is what a jump looks like from inside, and
  `game/jumpfx.asm` already stops the world at exactly that moment. Rejected:
  the jump happens twenty times and a minigame that must be played twenty times
  stops being a minigame by the third. It also lengthens the one transition the
  design already spent effort making short.
- **As a random event.** Rejected on this project's own rule about coin
  tosses: *"a coin toss is not something a player can act on"*. The same
  argument that made wrecks deterministic applies here.
- **As what a fleeing enemy costs you.** ✅ When the last hostile of a mission
  would otherwise die, it **runs** instead — once per campaign, at a mission
  the table names — and catching it is the minigame. Win and you get the kill
  and its salvage; lose and the mission still completes, but that ship is
  gone with whatever it was carrying.

The third one earns its place because **it can be lost without the campaign
being lost**, which is the only safe shape for a mechanic that has one keypress
of skill in it. It also gives the Scout a reason to exist — see below.

### ...and it is the Scout's role, finally

§8 gives the Scout *"μεγάλη εμβέλεια αισθητήρων"* and CLAUDE.md records that the
class has its number and not its role, because the sensor view is not
range-limited and there is nothing for a longer range to extend. **The chase is
something a longer range can extend.** If the ship the player sends is a Scout,
the tunnel is longer — more time to close the gap — and the class has a job no
other class does. That is one byte of `class_*` table and it retires an open
question that has been sitting in this file's "Known open questions" for a long
time.

---

## 5. What it costs, itemised

Guesses, and they are the numbers to check first if this is ever built.

| | bytes | where |
|---|---|---|
| the ring walker | ~40 | bank 4 — mostly a loop around `planet_span_*` |
| the chase state and its update | ~90 | bank 4 |
| drawing the two ships | ~60 | bank 4 |
| keys, entry and exit | ~80 | bank 4 |
| the result screens | ~60 | bank 4 |
| the words | ~120 | **bank 7**, free |
| state | ~12 | after `bank4_end`, free |
| **total against `DISC.BIN`** | **~330** | of 409 |

That fits, with about eighty bytes of margin — which is not enough margin to
start with, given that the last four features in this project each cost between
1.3× and 4.7× their estimate. **Move a kilobyte of text to bank 7 first**, and
then build it against real headroom.

---

## 6. What will go wrong

Written now, while it is cheap, and every one of these is a shape this project
has already met:

- **The rings will read as noise rather than as motion.** The jump wipe's bars
  had exactly this risk and survived it because everything moved the same way
  at the same speed at the same moment. Concentric ellipses cycling through
  radii may instead read as a flicker. **There is no test for this.** Look at
  it early, on the machine, the way the screen-space grid in `phase4_group` was
  killed and the way the one-pixel bar was cleared.
- **A constant in game frames is a constant in seconds only against a frame
  rate somebody looked at.** The tunnel's length and the closing rate are both
  clocks. Count 50 Hz ticks, the way `mis_timer` and `eco_moth_fix` do, not
  frames.
- **Every test will want to count.** "Did the chase end", "was the enemy
  caught", "how many frames did it take" are all preserved by a build where
  the steering does nothing. The test that means something reads the **lateral
  offsets** frame by frame and asserts the gap responds to the key — the same
  lesson as following squadrons by slot.
- **`gfx_vline` ORs and clips only in Y**, and `scr_fill_rect` clips nothing at
  all. The homeplanet section lists four separate bugs that came from exactly
  this and every one of them was found by screenshot.
- **The keyboard is edge-triggered and steering is not.** Every command in this
  game is a `key_hit`; steering wants `key_down`. Check which one `key_scan`
  leaves available before designing the controls around it.

---

## 7. The smaller version, if 400 bytes turns out to be 200

Cut the tunnel. Keep **two ships, one lateral axis, a closing distance and a
clock**, drawn against the starfield the title screen already generates from
eight instructions of xorshift. It is the same game and the same decision; what
is lost is the picture. The tunnel is the expensive half and it is the half
that can be added afterwards, which is the right way round.
