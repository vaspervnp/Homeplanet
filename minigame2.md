# minigame2.md — THE RUN: an R-Type between the jumps

*"Μπορείς να κάνεις χώρο για άλλο ένα minigame τύπου rtype; Απλά σχεδίασέ το."*

Designed, not built. The vortex chase (`minigame.md`, and `game/minigame.asm`
as it turned out) is the model for everything here that is not new; what IS
new is where the room comes from, and that is section 1, because without it
nothing in sections 2–6 can be built.

---

## 1. Is there room? — not where the chase went, and yes somewhere better

**`DISC.BIN` is 26020 of 26368.** The chase is about 1,300 bytes of bank 4 and
a second minigame of the same size does not fit in 348, and will not fit after
the next two levers either (the context bar's words, ~200; the title's, ~55).
Every lever this project has pulled moves DATA out of the file. A minigame is
CODE, and code has had exactly one place to go: bank 4, which is inside the
file byte for byte.

**It has a second place, and the rule that says otherwise is older than the
reason for it.** CLAUDE.md: *"Banks 5-7 hold sprite data only, and must. Code
assembled there could only run in the one moment bank 4 is out, which is the
one moment nothing else can."* That was written when bank 4 held the game's
static screens and every routine in the window was something the rest of the
game called into. A minigame is the opposite shape — it is the thing that runs
when nothing else does, from a black screen to a black screen, with its own
loop and its own vertical blank, exactly as `mini_run` already does — and it
calls almost nothing:

| it needs | where that is |
|---|---|
| `spr_blit`, `spr_enemy` | low 16K — and it must NOT be `spr_blit_banked` or `class_tier_addr`, both of which page banks |
| `gfx_vline`, `scr_fill_rect`, `scr_wait_vsync`, `scr_flip` | low 16K |
| `txt_draw`, `txt_set_pen` | low 16K |
| `key_down`, `key_hit`, `key_consume` | low 16K |
| `sys_rand_step` | low 16K |
| `snd_fire`, `snd_explosion`, `snd_hit` | low 16K |
| its sprites | **must be in the bank it runs from** — see below |
| its words | in the same bank: a plain `ld hl,words : call txt_draw`, no `bank7_fetch` at all |
| its state | in the same bank — bank 7 is RAM and nothing rewrites it until the next boot — or in the low 16K |

So: **the run lives in bank 7 and executes there.** A low-16K trampoline pages
bank 7 in, calls it, and pages bank 4 back — the same three-instruction shape
as `spr_blit_banked` and `bank7_fetch`, for the same reason those two are in
the low 16K: the OUT has to happen with the CPU already outside the window.
The interrupt is safe: the IM 1 handler is low 16K and calls `snd_update` and
`key_scan`, neither of which reads bank 4 — which is the exact property the
title screen's music already depends on.

**What it costs `DISC.BIN`: about thirty bytes.** The trampoline, a result byte
and the call in `mis_jump_now`. Everything else is raw sectors.

### The sprites have to be in bank 7, and the fix is a swap

Bank 7 holds the salvage corvette and the destroyer. An R-Type wants
interceptors — ours white and theirs red through `spr_enemy` — and a
destroyer for the end. **Swap the interceptor and the salvage libraries**:
bank 5 becomes salvage + mothership + harvester and bank 7 becomes interceptor
+ destroyer + the text. Every library is 4320 bytes since six yaw views, so
nothing else moves: two rows of `class_bank`, two `include` lines in
`src/main.asm`, and `test_shipclass`'s content compare goes on passing because
it compares each bank against what the build wrote.

**And that swap pays twice.** The chase draws interceptors too — it is the one
thing `mini_blit` exists to do — so once they are in bank 7, `game/minigame.asm`
can move there as well, behind the same trampoline, and `DISC.BIN` gets its
1,300 bytes back. Build the run first and move the chase second, so that the
trampoline is proven on new code before it carries old.

### Bank 7 has 464 bytes free, and needs a fourth track

13360 of 13824 when this was written; the run is 1,500–2,000 bytes.
`LIB_TRACKS_PER_BANK` is 4 now and `LIB_SECTORS` 32 — **and 32 is the
ceiling**, because the window is 16 KB: the fourth track is nine sectors on
the disc and five in memory. That is 2560 bytes more in bank 7 (16384 in
all) and the same again unused in 5 and 6. The 4.6 KB an earlier draft of
this section promised was arithmetic that forgot the window.

That is fifteen more sectors at boot, a third of a second on a real 6128,
for two banks that gain nothing — cheap enough that one `LIB_SECTORS` stayed
one loop. **So the run has to fit in about 2.5 KB of bank 7 plus whatever the
chase gives back when it moves there** (~1.4 KB): the smaller version in
section 7 is the one to build first, and the destroyer is what the chase's
bytes pay for.

---

## 2. What it is

**Your interceptor goes ahead of the fleet to clear the lane, left to right,
for thirty seconds.** Vekhar interceptors come in from the right in flights of
three or four on sine paths; you fire; they fire back; three hits and you are
down. At the end a destroyer crosses the screen and takes three hits to kill.

It is R-Type reduced to what four inks and 46 T-states a byte can carry:

- **Your ship is fixed in x** (a third of the way in) and moves in y on the
  cursor keys. That is the chase's "the tunnel moves, not the ship" applied
  sideways: the scroll is the background, and the background is the title
  screen's starfield — the same eight instructions of xorshift, reseeded to
  the same constant every frame, with a **scroll offset subtracted from every
  x**. Forty stars, one byte of scroll, and it reads as motion because
  everything moves the same way at the same speed.
- **Enemies are the interceptor's yaw view 4** (the three-quarter that points
  left — CLAUDE.md's tilt section records which view faces which way) in red,
  at tier B (16×10), on `y = y0 + AMP · sin(θ)` with θ advancing per step and
  x falling by a constant. Yours is view 1, white, tier B. **There is no 90°
  view** — six views, sixty degrees apart — so both ships are three-quarter
  rather than profile. If that reads wrong on the machine, `tools/mkships.py`
  can render a seventh frame at exactly 90° for the interceptor alone: 2
  shifts × 100 bytes at tier B, and the run addresses it directly, so the
  game's own `PHASE4_VIEWS` never learns it exists.
- **Shots are `gfx_vline` in ink 1 (yours) and ink 3 (theirs)**, two pixels
  tall, moving four bytes a step. Three of yours live at once; `SPACE` fires
  on the edge, which is what `key_hit` gives for nothing. Theirs fire on a
  `sys_rand_step` roll when the shooter is on screen.
- **Collision is byte Manhattan**, as the chase's `MG_LOCK` is: a shot within
  the sprite's half-extents of its centre is a hit. No masks are read.
- **Three hits.** Shown as three white marks top left that turn red as they go,
  drawn every step inside the band the step clears, which is what makes them
  free — the same argument the chase's steer line makes about the band UNDER
  the ship.
- **The destroyer is the last thirty per cent.** Tier C, ink 3, crossing
  slowly along a shallow sine, three hits to kill, and it fires twice as
  often. It is the only thing in the run that is a decision rather than a
  reflex: it can be outlasted — the run ends on the clock whether it dies or
  not.

### What it is worth

The same stakes as the chase, with the sign reversed: **lose and it is an
ambush** — `mini_penalty`'s 10% to 50%, driven by how many hits you took
rather than by distance — **win and the kills are salvage**, `eco_class_cost`
per interceptor and per destroyer, exactly what a corvette would have towed
home. Losing is the fleet paying for your not clearing the lane. It ends on
the clock, so it can be *survived* without being *won*: two hits and no kills
is a small ambush; two hits and eleven kills is a profit.

### The loop, per step

Six ticks a step — `MG_STEP_TICKS` is seven for the chase, and this one draws
less per step and wants to feel quicker:

1. scroll: the star seed's offset falls by one;
2. advance: every enemy's x and θ, every shot's x, the destroyer if it is in;
3. spawn: a flight when the last one is past the middle;
4. fire: theirs on a roll, yours on the edge;
5. collide: yours against theirs, theirs and their ships against you;
6. draw: clear the band, stars, ships, shots, the three marks; flip;
7. pace on `sys_tick_50hz`, exactly `mini_wait`.

---

## 3. Where it sits in the campaign

**The jumps the chase does not take.** `MG_EVERY` is 4, so the chase runs on
the jumps into missions 5, 9, 13 and 17. The run takes 3, 7, 11, 15 and 19 —
`(mis_index + 1) mod 4 == 2` — so the two alternate every other jump and no
jump has both. The fiction is one line in the briefing that follows: *"A picket
was waiting at the jump point. One of ours went ahead."*

**It opens on a page the first time**, like the chase, naming `UP`, `DOWN`,
`SPACE` and the three hits, and dismissed with ENTER. `mini_intro` is the
model; the page's words are in bank 7 already by construction.

**And it goes on the disc as `MINI2.BIN`**, the way the chase is `MINI.BIN`:
`MINI_ONLY` grows a second value, or a sibling `RUN_ONLY`, and the boot loop
under it runs the trampoline for ever. That is what makes it playable on the
machine before it is wired into a campaign, which is how the chase was tuned.

---

## 4. What it reuses, and what it must not

Reused as is: the starfield (`title_draw_stars`'s reseeded xorshift, one
subtraction added), `spr_blit` + `spr_enemy`, `gfx_vline`, `scr_fill_rect`,
`txt_draw`, `key_down`/`key_hit`, `mini_wait`'s pacing (copied — it is bank 4
and cannot be called), the three sound effects.

**Must not, and each of these is a crash rather than a bug:**

- **anything in bank 4.** The window IS bank 7 while the run executes. Not
  `mini_penalty`, not `mini_say`, not `cam_sin` if it lives there (it is low
  16K; check), not `class_tier_addr`. The penalty is applied by the CALLER,
  after the trampoline has put bank 4 back, from a result byte the run leaves
  in the low 16K — the same division the chase already makes between
  `mini_run` and `mis_jump_now`.
- **`bank7_fetch` and `bank7_copy`.** Both end by paging bank 4 in and
  returning — into code that is no longer there. The run's words are in its
  own bank; it reads them with `ld hl`.
- **`mus_update`.** It reads bank 4. The run has its own loop and never calls
  it; the tune is held by `mus_battle` for the duration and comes back in time
  with itself, as it does after a fight.
- **the no-disc fallback.** With `LIB_OK` clear there is no bank 7 to run
  from. The trampoline checks it and returns "no run" — the campaign skips
  the jump's minigame exactly as it skips the chase's sprites today.

---

## 5. What it costs, itemised

| | bytes | where |
|---|---|---|
| the loop, spawn, fire, collide | ~500 | bank 7 |
| drawing: stars with scroll, ships, shots, marks | ~400 | bank 7 |
| the destroyer | ~150 | bank 7 |
| the two pages (intro, result) and the toll | ~250 | bank 7 |
| words | ~200 | bank 7 |
| state | ~60 | bank 7, or after `low_end` |
| the trampoline and the call | ~30 | **`DISC.BIN`** |
| **total against `DISC.BIN`** | **~30** | of 348 |
| total against bank 7 | ~1,600 | of 2,600 with the fourth track, ~4,000 once the chase moves there |

The last four features in this project each cost 1.3× to 4.7× their estimate.
At 4.7× the run is 7.5 KB and still fits a bank with four tracks; that is the
whole argument for the fourth track over squeezing into 464.

---

## 6. What will go wrong

- **The trampoline will be written with `call` into bank 7 and `ret` out of
  it, and that is fine — until something inside the run pushes a bank-4
  return address.** Nothing may `call` bank 4. There is no assert that can see
  a call target's bank; the guard is `tests/test_regions`-style: every routine
  the run's source names, resolved against the symbol file, has to be in bank
  7 or below `#4000`. Write that test first.
- **`read_bank4` will lie for the whole run**, exactly as it did for the
  chase's tests — bank 7 is under the window on purpose. The harness needs
  `read_bank7(c, addr)`: page-aware like `read_cpu`, checking a sentinel in
  bank 7 (`class_name`'s first bytes will do) and stepping a frame until it is
  there.
- **The interrupt fires with bank 7 in.** Safe today; the day someone puts a
  bank-4 read into `snd_update` or `key_scan` it is not, and the failure will
  be the run crashing a second in. `src/main.asm` should assert that neither
  routine's address range contains a `#4000`–`#7FFF` reference — which RASM
  cannot do — so the comment on `sys_irq` has to say it, and `test_sound`'s
  "the whole tick fits" test is the place to add "...with bank 7 paged in".
- **Six T-states a scanline of star is nothing; forty stars redrawn every step
  is not** — each is a `gfx_vline` at ~250 T with the range check, 10,000 T a
  step. Affordable at six ticks (240,000 T) and worth knowing where it goes.
- **A constant in steps is a constant in seconds only against `MG_STEP_TICKS`.**
  Thirty seconds is `30 * 50 / 6 = 250` steps. Count ticks.
- **Every test will want to count kills.** The test that means something
  follows one shot by its x from the frame it is fired to the frame the enemy
  it hits goes inactive, and follows one enemy shot to the mark that turns red.
- **`RUN_ONLY` and `MINI_ONLY` will both want the boot loop**, and `IF`/`ELSE`
  nesting in `main.asm` will get a third branch. Fine; the Makefile gets a third
  pair of `save` paths under `build/run/`.

---

## 7. The smaller version, if 1,600 bytes turns out to be 3,000

Cut the destroyer and the enemy fire. Keep **one flight of interceptors at a
time, your shots, the clock and the three hits from collisions**. It is the
same lane and the same reflex; what is lost is the boss and the dodging. The
destroyer is the expensive third and the third that can be added afterwards,
which is the right way round — the same reasoning that kept the chase's tunnel
for last.
