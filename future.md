# future.md — cheap things that make the game more of an action game

*"Σκέψου τι άλλο θα μπορούσα να κάνω στο παιχνίδι εκτός από τα δύο minigames
που θα είναι σχετικά φτηνό και θα βελτιώσει το gameplay. Θα το κάνει πιο
action oriented."*

Written against what the engine can already do, because that is what makes
something cheap here: a feature that reuses a routine costs a few dozen bytes
of bank 4 and one test; a feature that needs a new routine costs a page of the
low 16K and an afternoon. Ordered by how much action each buys for what it
costs. Numbers are estimates of the kind this project has learned to
multiply by two.

The room: `DISC.BIN` has about 1,200 bytes since the chase moved to bank 7,
bank 4 about 2,300, bank 7 about 1,100, and the low 16K is at its floor.
Everything below is bank 4 code with its words in bank 7.

---

## 1. Direct control of one ship — `V`, and you are the interceptor

**What.** Press `V` on a selected squadron and the camera drops onto its lead
ship, the cursor keys steer THAT ship, and `SPACE` (or `A`) fires its gun on
the edge. `V` again — or its death — hands the squadron back to the AI. The
rest of the fleet goes on doing what it was ordered to.

**Why it is the one to build first.** It is the thing a strategy game on a
CPC does not have and an action game is made of: a moment when the player's
hands decide a fight. Every other item on this list is a knob; this is a
verb. It also turns the balance triangle into something you feel — flying a
bomber at a frigate is a different thing from ordering it.

**What it reuses.** All of it. The ship is an entity like any other:
`phase4_fly` already skips ships under an order it does not own (ATTACK), so a
`ENT_ORDER_PILOT` is one more `cp` in the same place; `order_disc_move`'s
octant table turns "left" into a camera-relative step, which is exactly what
steering wants; `cbt_fire_if_able` fires when `ENT_TIMER` is zero and the
target is in range, so "SPACE fires" is `ENT_TIMER = 0` and
`cbt_find_enemy`; `order_focus` already follows a station, so following a
ship is a pointer.

**Cost.** ~180 bytes of bank 4, one context-bar line (`ARROWS FLY  SPACE
FIRE  V BACK`), one `ENT_ORDER_*`, a HUD word. Frame cost nothing: the ship
was being flown by `phase4_fly` anyway.

**What will go wrong.** The camera. `order_focus` centres on a station and a
piloted ship moves every frame, so the view will follow with a one-frame lag
and the ship will sit a little off-centre in the direction of travel — that is
fine, it is what every chase camera does, and it must not be "fixed" by
projecting first. And the yaw: a piloted ship's `ENT_YAW` is what the sprite
is drawn from, so steering has to turn the yaw and step along it, not step
along the camera axes — or the ship crabs.

## 2. Waves that come from the direction they announce

**What.** `INCOMING` already says a wave is coming and the wave arrives from
one bearing on a shell around the Mothership. Put the bearing on the screen:
the off-screen Mothership marker's own arithmetic (`moth_update`) can draw a
red mark on the border where the wave will appear, for the seconds between
`INCOMING` and arrival. Then the player turns to face it, which is the whole
of what "a direction" is for.

**Cost.** ~60 bytes: `wave_send` already knows the bearing; `moth_update`
already turns a world point into a border position. A second call with the
wave's spawn point and ink 3.

**Why.** It gives the player something to DO during the countdown — pick the
squadron, point it — instead of waiting to be told where the fight is.

## 3. A strafe: the squadron makes one pass and comes back

**What.** `A` closes on the target and stays there until the target dies —
that is the attack order spending itself. Add `S`... no, `S` is sensors. Add
**`W`**: a strafing run. The squadron closes, fires for `CBT_STRAFE_TICKS`,
then flies through and back to station whatever is left, and the order
spends itself on the return. Fast, cheap, and it produces the picture an
action game is made of — ships crossing each other.

**Cost.** ~90 bytes: it is `ENT_ORDER_ATTACK` with a tick budget in
`ENT_TIMER`'s neighbour (`ENT_LOAD` is free on a fighter), and
`order_release_attack`'s path home.

**Why.** Attack is all-or-nothing today; a strafe lets a player hit and
withdraw, which is a tactic rather than a commitment, and it makes the
balance triangle's "hit the frigate with bombers and get out" a thing the
game can express.

## 4. Shots you can see

**What.** A shot today is a sound and a hull byte. Draw it: one `mark_dot` in
ink 1 (ours) or 3 (theirs) at the shooter's projected position for one frame,
and one at the target's. The dirty list erases it. Two dots a shot, no
trajectory, no timing — it reads as fire because it flashes where the ships
are.

**Cost.** ~40 bytes in `cbt_fire_if_able`'s hit path, calling `mark_dot`
with `phase4_vis`'s projected x/y (the projection is already done for every
visible ship this frame). ~300 T a shot.

**Why.** It is the cheapest change on this list and the one a first-time
player would notice first: the fight becomes visible.

## 5. The Mothership's own gun

**What.** §8 says the Mothership is "αργό, θωρακισμένο" and it has a damage
row, but the player never sees it fire because it never moves. Give it a
turret with double range (`CBT_RANGE * 2` for `CLASS_MOTHERSHIP` only) and
the `cbt_fire_if_able` path it already has. Under attack, the base fights
back — visibly, with item 4.

**Cost.** ~15 bytes: a class compare in `cbt_in_range`.

**Why.** It turns "defend the Mothership" from a chore into a position: the
fleet stationed on it is inside its cover.

## 6. A boarding action on a wreck — the corvette's fight

**What.** A tow takes a corvette out to a hull and back and nothing happens
in between. Make the hull fight: a towed wreck has a chance, once, of
`INCOMING`-style resistance — one wave ship spawns at the wreck when the tow
line goes on. The corvette needs cover, which is what §8 says it needs.

**Cost.** ~40 bytes: `wave_send` with a position argument, from `slv_tow_step`'s
"close enough to get a line on it".

**Why.** Salvage is the game's economy of the late campaign and it is a
lorry run. One ship at the wreck makes it a raid.

## 7. Ramming

**What.** A ship under a PILOT order (item 1) that flies into an enemy does its
own hull as damage to both. It is how a fighter kills a frigate it cannot
outgun, and how the player loses a ship on purpose.

**Cost.** ~50 bytes, only meaningful with item 1: `dist_manhattan` under a
threshold on the piloted ship's frame, then two hull subtractions.

---

## The order to build in

1, then 4 — the verb, then the picture of it. Two and five are afternoons.
Three needs one; six and seven are for when the first four have been played.

The test for each of them is the one this project keeps writing down: follow
a ship by slot and read where it is and what it is aiming at. A count of
shots or kills is what every one of these preserves.
