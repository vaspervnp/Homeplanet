# finishup.md — the ending, finished properly

Three things the owner asked for about the last mission. Written down rather
than built, so the thinking is done while it is still cheap.

The ending works today — `LAND` appears on the last mission, `J` takes it, and
the victory page comes up — but it was built as "the jump, with the
twenty-first row missing". These three are what stop it being that.

See "The end of the journey" and "The jump counts down" in
[CLAUDE.md](CLAUDE.md) for what exists now.

---

## 1. The countdown must say LANDING, not JUMPING

**Asked for:** *"When landing the countdown should say Landing (not Jumping)."*

The context bar draws `JUMPING nn  ESC CANCEL` while the drive spools. On the
last mission the key is already `LAND` in the HUD — the bar contradicting it is
exactly the failure `game/ctxbar.asm` exists to prevent: *a bar that names the
wrong thing is worse than no bar, because the player believes it.*

### What it touches

`ctx_draw_jumping` in `src/game/ctxbar.asm` draws `ctx_text_jumping` and then
the seconds. It needs the same choice `mis_leave_word` already makes:

```
    call mis_is_last            ; already exists, already the one place that knows
    ld hl,ctx_text_jumping
    jr nc,@ctx_jump_word
    ld hl,ctx_text_landing
@ctx_jump_word:
```

**The two words are not the same length** — `JUMPING` is 7 and `LANDING` is 7.
They are. That is luck rather than design, and it means `CTX_JUMP_NUM_X` and
`CTX_JUMP_TAIL_X` do not move and the existing asserts still hold. **Add an
assert that the two strings are equal length**, the way `src/main.asm` already
asserts `LAND` and `JUMP` are, or the day one of them is reworded the number
will be drawn over a letter.

`ctx_classify` needs no change: `CTX_JUMPING` is the state either way, and the
seconds are already folded into `ctx_sub` so the repaint happens on the tick.

### The test

`tests/test_ctxbar.py` reads the bar back off the pixels with the ink per cell.
The discriminating pair is **both halves**: mission 1 says `JUMPING` and the
last mission says `LANDING`. A build that said `LANDING` everywhere passes the
second on its own — the same shape as
`test_the_word_is_jump_until_the_last_mission_and_then_land`.

---

## 2. Landing has no wipe

**Asked for:** *"There should be no effect also."*

`mis_jump_now`'s landing path calls `jfx_land`, which is `jfx_vanish` without
arming the reveal. So the fleet is currently swept away by the bars before the
victory page — and that is wrong twice over:

- **The bars mean "the fleet is leaving".** It is not leaving; it has arrived.
  Sweeping it away says the opposite of what the screen is about to say.
- **It is seven seconds of nothing** between the last shot and the ending.

So: the landing path does not call `jfx_land` at all. Delete the call and
`jfx_land` with it if nothing else wants it — check `jfx_no_arrival`, which
exists only to serve it and can go too. That is ~20 bytes of bank 4 back.

**What replaces it is item 3**, and the two should be built together: taking
the wipe out and putting nothing in its place would make the victory page
appear the instant `LAND` is confirmed, which is abrupt in the other direction.

### Watch for

`jfx_armed` must stay clear on this path — that was the whole reason `jfx_land`
existed. If the call goes, so does the risk, but check nothing else sets it:
a seventeen-second reveal firing over the victory page is the failure `jfx_land`
was written to avoid.

---

## 3. `L` as well as `J`

**Asked for:** *"When LAND is available, both L and J will cause the landing."*

The word on the screen is `LAND`; the key that does it is `J`. A player who
reads the HUD and presses `L` gets nothing, and *a key that does nothing
visible is a key that is broken* — this project's own recurring lesson.

`KEY_L` is **already bound**: it is half of the `K`/`L` pair that moves one ship
between squadrons (`K` back, `L` forward). So this is a **modal** binding, and
the game already has the pattern for one — `,` and `.` mean "step the target"
while playing and "step the price list" with the build panel open, decided by
the mode the player can see.

The rule: **while `mis_leave_ok` is set on the last mission, `L` lands.**
Otherwise `L` keeps its squadron meaning. That is `mis_is_last` and one flag,
both of which already exist, in `phase4_commands` beside the existing `KEY_J`.

### The two things that will go wrong

- **Order matters.** `L` must be tested for landing *before* it is passed to
  the squadron command, or it will do both.
- **The bar has to say so**, or the modal binding is invisible. The playing
  line has no room (it is 40 bytes against the assert's 42), so the honest
  place is the **HUD's fourth field**, which already says `LAND` — no change
  needed there, but do not add `L` to the context bar without measuring.

**A guard test that passes on both builds**: `L` still moves a ship between
squadrons in mission 1. Without it, the day someone makes the binding
unconditional nothing will notice.

---

## 4. The Mothership sets down on the planet

**Asked for:** *"There should be a sequence of the mothership landing on the
planet before the end screen."*

This is the largest of the four and the one with a real design in it.

### What exists to build on

- **`planet_draw`** (`src/game/homeplanet.asm`) draws the ellipse at
  `planet_cx`/`planet_cy` with an interpolated half-width table, and the
  game-over screen already calls it at a chosen centre. The victory page draws
  it too, unburning.
- **`spr_blit` through `class_tier_addr`** gives a real Mothership sprite at
  three size tiers.
- **The stopped-world pattern** — `game/gameover.asm` is the model: repaint
  every frame, own all 200 lines, set `mis_wipe` on the way out.

### The shape

**The planet grows and the Mothership shrinks into it.** Two counters and one
loop: the planet's radius scales up from the horizon it has in the tactical
view to the disc the victory page shows, while the Mothership steps down
through its size tiers and towards the limb. It ends on the frame the victory
page begins, so the two are one movement — the same trick the title screen's
planet and the victory page's planet already play by being the same ellipse.

**Do not animate a descent through an atmosphere.** There is no horizon, no
ground, and nothing in the palette to draw air with. What the game can say at
320×200 in four inks is *"the world got closer and the ship got smaller against
it"*, and that is enough — it is the same statement the whole campaign has been
making.

### What will go wrong, from the two planets already built

- **`gfx_vline` ORs and clips only in Y**, and `scr_fill_rect` clips nothing at
  all. The homeplanet section of CLAUDE.md lists four separate bugs from
  exactly this, every one found by screenshot.
- **Each buffer needs its own record of where the planet was**, or one keeps a
  limb nobody will ever erase. `planet_rec_a`/`planet_rec_b` exist for this.
- **It costs half a frame at the horizon's size**, measured, and it will cost
  more as the radius grows. It stops the world, so it can afford to — but
  measure it rather than assuming.
- **Count 50 Hz TICKS, not game frames.** Four separate constants in this
  project have turned out to be constants in seconds only against a frame rate
  somebody once looked at.

### Length

**Three to four seconds**, and no more. The jump wipe is 7.2 s out and 4.6 s
back and CLAUDE.md records that the reveal was *halved* because it dragged.
This plays once per campaign, which argues for generosity, and it is between
the player and the ending they have earned, which argues hard against it.

---

## Space, and the order to build these in

Measured at the time of writing: **`DISC.BIN` 26187 of 26368 — 181 free.** That
is the tightest this project has ever been, and item 4 does not fit in it.

So the order is forced:

1. **Item 1** (LANDING) — one string and a branch, ~20 bytes. Fits.
2. **Item 2** (no wipe) — *gives bytes back*. Do it second and it pays for
   some of item 3.
3. **Item 3** (`L`) — ~15 bytes. Fits.
4. **Item 4** (the descent) — **does not fit; find the room first.** The lever
   is the one that has worked four times running: move data out of the file
   into bank 7, which has **835 bytes free** and costs `DISC.BIN` nothing.
   `class_name`, the context bar's words and `game/overtext.asm` are all still
   in bank 4 and all are read with the window at rest. CLAUDE.md's "There are
   four levers now" section has the order to reach for them in.

**Do not skip to item 4.** Building it against 181 bytes means fighting the
`#A700` assert on every edit, and the page quantum in the low 16K will make
that worse than it sounds.
