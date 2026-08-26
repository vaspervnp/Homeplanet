# HOMEPLANET — working notes

Amstrad CPC 6128 fleet-strategy game in Z80 assembly. Mode 1, 320×200, 4 inks.
The design document is [Homeplanet.md](Homeplanet.md) — it is the spec; this
file is how to work on it.

Written in English because it is an instruction file for tooling. The design
document stays in Greek.

---

## Commands

```bash
make            # generate tables, assemble, produce build/homeplanet.dsk
make test       # assemble, then run the emulator test suite (~3s)
make run        # assemble and screenshot the running game into build/shots/
make tables     # regenerate the lookup tables only
make dsk-list   # AMSDOS catalogue of the built disc
make clean
```

```bash
python3 tools/run.py --shots 6 --every 5     # a strip of frames, to see motion
python3 tools/run.py --disc                  # boot from the .dsk like a user
python3 -m unittest tests.test_phase0 -v     # one test module
```

**Always `make test` before saying something works.** The emulator gives us
the whole machine state; there is no reason to guess.

**The `.dsk` is minted fresh every build, and that `rm -f` in the Makefile is
load-bearing.** RASM's `-eo` writes DISC.BIN *into* an existing image, and the
file grows with every feature; overwriting in place left the image holding a
mixture of builds. `boot_quick` reads `build/disc.raw` and kept working, while
`boot_disc` -- and anyone running the real disc in an emulator -- got older
code. The symptom is data three bytes out of where the symbol file says it is,
with nothing in the source to explain it. If a `boot_disc` test disagrees with
a `boot_quick` one, suspect the image before the code.

**Never run `rasm` by hand to look at an error.** It rewrites
`build/homeplanet.sym`, and if that assembly fails the symbol file is left
disagreeing with the binary `make` built. Every test then reads the right name
at the wrong address: `MIS_BRIEFING` came back as 78, which is the `E` of the
`"ENTER"` prompt three bytes further on. Use `make` and read its output, or
`make clean` afterwards.

---

## Toolchain

| Tool | Where | What for |
|---|---|---|
| **RASM** 3.2.5 | `rasm` on PATH (source in `~/rasm`) | Z80 assembler, writes EDSK directly |
| **iDSK** 0.20 | `iDSK` on PATH (source in `~/idsk`) | inspect/patch `.dsk` images |
| **cpcemu** | `~/repos/CPCTools/cpcemu` | headless CPC 6128 emulator, Python API |
| **RetroTools** | `~/repos/retrotools` | sprite editor; graphics come from here |

Python 3.14 with PIL. **No numpy, no pytest** — tests use stdlib `unittest`.

### The emulator

`tests/harness.py` wraps it. It is a full 6128: Z80, AM40010 gate array,
MC6845 CRTC, i8255 PPI, µPD765 FDC with real `.dsk` support. The useful part
is that everything is readable — `read_ram`, `peek` (CPU-visible, so ROM
paging shows up), `pc`, `crtc_screen_addr`, `mode`, `decode_screen_ram`,
`screenshot`.

Two entry points:

- `harness.boot_quick()` — boot the firmware, drop `DISC.BIN` at `#4000`, jump.
  Same code path as a real boot minus the FDC. Use this.
- `harness.boot_disc()` — insert the `.dsk` and `RUN"DISC`. Slow; it is the
  only thing that proves the disc image is right.

You can also call any routine directly: poke a stub that sets up registers and
`CALL`s it, `set_pc` there, run a few frames, then read memory. See
`test_fill_rect_honours_width_and_height` — that is the cheapest way to test a
drawing routine, and it is a real unit test of real Z80 code.

Gotchas:
- Two `CPC` instances in one process interfere. One emulator per process.
- It comes up with **cassette** as the default filing system, unlike a real
  6128 with a drive. `boot_disc` sends `|DISC` first.
- `quickload(start=True)` types `CALL &xxxx` into the BASIC line buffer, so it
  only works once BASIC has reached its prompt — and not for us anyway (see
  the boot section below).

---

## How the thing boots

This is the part that will waste your afternoon if you do not know it.

The game runs at **`#0040`**, and that is forced: two 16K screens at `#8000`
and `#C000` plus the 16K bank window at `#4000` leave nothing else.

But `#0000-#3FFF` is shadowed by the lower ROM. **Writes go to RAM, reads come
from ROM.** So AMSDOS will happily LOAD a file to `#0040` and it will land
correctly — and then `JP #0040` fetches firmware bytes and runs off into the
weeds. The symptom is a program that looks like it hangs, with `PC` wandering
around `#0C00-#1F00`, and nothing in the source to explain it.

Calling `CAS IN OPEN` from a stub does not help either: by the time a binary
started with `RUN"` is executing, the CAS jumpblock has been handed back to
the cassette manager, and the stub sits there printing *Press PLAY then any
key* forever.

So [src/disc.asm](src/disc.asm) builds **one** file, `DISC.BIN`, that AMSDOS
loads at `#4000` in the ordinary way. Its first instructions switch both ROMs
out and block-copy the game down to `#0040` itself. No firmware calls at all.

The game inherits the firmware's CRTC setup (40×25, R1/R6/R9 and friends) and
only ever programs R12/R13. That is normal for a CPC game loaded from BASIC —
but it means starting the emulator on a cold machine and jumping straight in
gives you a CRTC that has never been initialised. `harness.boot_quick` runs
150 frames of firmware first for exactly this reason.

---

## Memory map

```
#0000-#003F   RST vectors; our IM 1 handler is JP'd from #0038
#0040-#3FFF   code + lookup tables + entity data        (16 KB)
              ...stack grows DOWN from #4000 into the slack
#4000-#7FFF   BANK WINDOW — extended bank 4, the sprite library
#8000-#BFFF   screen buffer B
#C000-#FFFF   screen buffer A
```

Everything touched per frame must live below `#4000`, because the `#4000`
window is paged underneath it.

`src/main.asm` asserts at build time that code+tables stay clear of the stack
and prints how many bytes are left in both the low 16K and bank 4. Watch both
numbers: the low 16K is down to **512 bytes**, so anything sizeable now has to
go in the bank and be reached through the window (the help text does).

### Banking

`OUT (#7Fxx), #C4..#C7` pages extended bank 4..7 into `#4000`; `#C0` is the
power-on layout. Equates in `src/equ/hardware.asm`.

**Bank 4 is paged in for the whole run** and holds the sprite library, so
`sys_boot` selects it rather than the default layout. Getting the data there
is the awkward part, and `src/disc.asm` explains it at length: the stub cannot
live at `#4000` any more, because the instant it pages bank 4 in, the window
stops being the RAM the stub is executing from. Both the stub and the sprite
image therefore sit above `#8000`, which the paging leaves alone.

In tests, `read_ram()` indexes the base 64K by address and will hand you
bank 1 for `#4000`. Use `harness.read_cpu()` (and `write_cpu()`) for anything
in the window — they go through `peek`/`poke`, which honour the paging. This
catches you the moment a variable moves into the bank: `title_shown` read back
as 14 the first time, because `read_ram` was looking at bank 1.

**The bank is executable RAM, not just data.** Nothing pages bank 4 out, so
`#4000-#7FFF` runs code as happily as it holds sprites — and that is the
escape hatch when the low 16K fills up. The title screen (`gfx/bigtext.asm`,
`game/title.asm`) lives there for exactly that reason: it runs once, before
the first mission, so it has no business competing for space with the frame
loop. It went in the low 16K first and took `CODE_END` to `#3D00`, which left
the *tests* no room for their scratch and broke seven classes that had nothing
to do with it.

The rule that still holds is the original one: anything touched **per frame**
must be below `#4000`, because a future mission that pages in bank 5 would
pull it out from under itself mid-instruction.

---

## Conventions

### Naming

`<subsystem>_<verb>` for routines, `<subsystem>_<noun>` for data:
`scr_fill_rect`, `scr_line_addr`, `sys_boot`, `demo_update`.
Subsystem prefixes: `sys_`, `scr_`, `snd_`, `ent_`, `cam_`, `hud_`, `spr_`,
`fdc_`, `help_`, `title_`.

Local labels start with `@` and are scoped to the enclosing global label.

**RASM is case-insensitive.** `demo_objects` and `DEMO_OBJECTS` are the same
symbol and the build will fail with "there is already an alias with the same
name". Do not distinguish an equate from a label by case alone — a routine
`fdc_motor` beside a port equate `FDC_MOTOR` is the same collision, and so is
a routine `title_stars` beside a count `TITLE_STARS`. It is an easy one to
walk into because the two read as different kinds of thing — both of those
were written, and both failed the build, after this paragraph existed.

**`@` labels are GLOBAL.** Not per-routine, not even per-file — two routines
anywhere in the build cannot both have an `@no_carry`. Prefix them with the
subsystem (`@spr_no_carry`). Check with:

```bash
grep -hoE '^@[a-z_0-9]+' $(find src -name '*.asm') | sort | uniq -d
```

**`JR` reaches ±127 bytes.** A shared error exit at the end of a long routine
will be out of range; use `JP`. RASM reports it as "relative offset N too far".

**Test scratch memory comes from the build, not from a magic address.** The
tests poke stubs at `harness.STUB` and read results at `harness.RESULT`, both
derived from `CODE_END`. They used to be hard-coded `#3000` and `#2F00`, which
were free space right up until the code grew and `sin7` landed exactly on
`#3000` — after which every test that called a routine silently overwrote the
sine table first, and the failure surfaced in whichever *other* test built a
camera matrix next.

**`SBC HL,DE` overflows, and the sign bit lies when it does.** Two points on
one world axis can be 65534 apart, which does not fit in the register holding
their difference. The true sign is `S XOR P/V`, so test `P/V` *immediately* —
an `OR` or `LD A,H : OR L` in between destroys it. A ship at one end of the
map read a target at the other end as being behind it and flew away from it
forever. See `phase4_approach`.

**Key ids are MATRIX POSITIONS, not a dense enumeration.** `KEY_1` and
`KEY_2` are in row 8, `KEY_3` and `KEY_4` in row 7, `KEY_9` and `KEY_0` up in
row 4. Deriving a digit's id with `KEY_1 + n` gets you `ESC`, `Q`, `TAB`, `A`
and `Z` — use `key_digit`. This shipped once, and made squadrons 3-9
unreachable while a test that pressed `5` and asserted nothing happened passed
anyway.

**`ASSERT` is evaluated where it stands**, so it cannot see anything included
later. The table-layout invariants therefore live at the bottom of
`src/main.asm`, after `gen/tables.asm`, not next to the code that relies on
them.

### Register contracts

Every routine's header comment states `In:`, `Out:` and `Uses:`. Keep them
accurate — this is not documentation for humans, it is the only thing standing
between you and a bug like this one:

> `scr_line_addr` used to clobber `DE`. `scr_fill_rect` called it and then read
> its width out of `D`. Every rectangle came out two bytes wide, because `D`
> happened to hold the high byte of the line table. Nothing in the source
> looked wrong.

`scr_line_addr` is now deliberately `AF`/`HL` only, because it is called once
per scanline from loops whose parameters live in `BC`/`DE`.

### Hard rules

- **Never `IX`/`IY` in a per-pixel or per-scanline loop.** They cost 4 extra
  T-states per access and the frame budget does not have room.
- **No firmware calls after boot.** The ROMs are switched out; there is no
  firmware to call.
- The interrupt handler may only touch `AF` and `HL`, and it must save them.
- Self-modifying code is fine and often the right answer — see the
  `@fill_byte equ $+1` patch in `scr_fill_rect`. Comment it every time.
- **A routine that returns a flag must have that flag tested immediately.**
  `ADD HL,DE` writes the carry. `proj_point` returns visibility in CF, and
  advancing a pointer before checking it silently clipped every entity.

### Frame budget — measured, not estimated

12.5 fps, one frame per 4 VSyncs, ~265,000 T-states. Section 6 of the design
document has the allocation, but **its per-entity figure is optimistic** — see
the measurements below. When adding to the frame loop, measure what it costs;
`tests/test_phase1.py` shows the technique (loop the routine N times, count PAL
frames). Note the gate array steals cycles, so real timings run ~25-30% above
a hand count of the instruction table.

| Routine | Measured | Design §6 |
|---|---|---|
| `proj_point` (one entity, full pipeline) | ~4,560 T | 1,200 T |
| `proj_rotate` (9 multiplies, m01 skipped) | ~2,790 T | — |
| `cam_build_matrix` (once per frame) | ~3,360 T | — |

A general 3×3 rotation will not fit 1,200 T on a 4 MHz Z80: nine table-driven
multiplies alone are more than that. The 100 background stars must therefore
use the cheap path in §5.4 (no translation, no perspective divide, cached
unless the camera moves) — they cannot go through `proj_point`.

A whole frame, 24 entities — the number §6 budgets for — measured at
**5.8–6.5 fps against the 12.5 target**:

| Stage | T-states |
|---|---|
| `phase4_draw` (masked blits) | 182,000 |
| `phase4_project` | 118,000 |
| `phase4_erase` (dirty rectangles) | 75,000 |
| `phase4_sort` (z order) | 73,000 |
| `phase4_fly` (formation movement) | 52,000 |
| `cbt_update` (targeting, firing, damage) | 28,000 |
| `phase4_hud`, explosions | 2,000 |
| `snd_update` (in the interrupt, 3 voices live) | 4,400 |
| **total** | **~530,000** |

Combat is cheap; the cost is the entity count. Going from 21 entities to 31
cost about a third of the frame, which is why the demo now runs the 24 §6
asks for rather than as many as would fit on screen.

Where the remaining headroom is, in the order worth taking it:

- **Blitting.** 46 T a byte is close to the floor for a masked blit, but the
  per-row overhead is ~185 T of `scr_line_addr` and address arithmetic, about
  a third of a tier-C sprite. Stepping the screen address incrementally
  between scanlines would take most of that back.
- **The z-sort at 54,000 T** is O(n²) because the list is rebuilt in entity
  order every frame, so it is never nearly sorted. Caching each entry's depth
  beside its index would cut the comparison from ~140 T to ~40 T.
- **`phase4_fly` and `phase4_project` both walk all 48 slots** to find 20 live
  ones. A high-water mark would nearly halve that.
- Fewer ships at tier C: the thresholds in `tools/gentables.py` decide how
  many 24×16 sprites are on screen, and tier C is four times the pixels of
  tier B.

Enemies blit through a second unrolled run that recolours as it goes, at 17
bytes a unit against 7 — about 1.75× a friendly sprite. It is still far
cheaper than a second copy of every sprite library.

---

## Graphics pipeline

Ship sprites are generated from 3D models by `tools/mkships.py` (`make ships`),
which renders 8 yaw views per size tier, dithers them, and writes a
`.retrotools.json` project into `art/`. Those files are **source art** — open
them in RetroTools to retouch by hand, and the retouched version is what
ships. Anything drawn from scratch in RetroTools goes through the same path.

```bash
make ships                                   # models -> art/*.json -> src/gen/*.asm
python3 tools/mkships.py --contact-sheet     # PNG previews in build/ships/
python3 tools/rt2sprite.py art/frigate.retrotools.json --out src/gen/spr_frigate.asm
```

The converter reads the project JSON, **not** RetroTools' own `.asm` export.
The reason is masks: RetroTools packs its mask at 1 bit per pixel MSB-first
regardless of mode, while Mode 1 data is 2 bits per pixel in the interleaved
`A0 B0 C0 D0 A1 B1 C1 D1` layout. The two do not line up, so the tool's mask
cannot be ANDed against its own data on a CPC. We generate our own mask in
Mode 1 bit order instead.

Output is mask/data pairs, row-major, one block per (frame, pre-shift), which
the blitter consumes without rearranging:

```
ld a,(de) : and (hl) : inc hl : or (hl) : inc hl : ld (de),a : inc de
```

Pre-shifts of 0 and 2 pixels are stored and X is restricted to even positions
(design section 5.1). If a frame has no mask, **pen 0 is treated as
transparent** — pen 0 is empty space in this game's palette.

The converter warns if the project's inks are not the game's four.

### The palette is semantic

| Pen | Colour | Hardware | Meaning |
|---|---|---|---|
| 0 | Black | `#54` | empty space |
| 1 | Bright White | `#4B` | friendly ships, HUD, text |
| 2 | Sky Blue | `#57` | stars, reference grid, shading |
| 3 | Bright Red | `#4C` | enemies, explosions, alarms |

The `HW_*` equates in `src/equ/hardware.asm` are the **`#40`-`#5F` values you
send to the gate array**, with the colour-select bits already folded in — the
same notation RetroTools prints in its export headers, so a palette copied out
of the editor drops straight in.

> Sending the bare 0-31 colour index instead reads back as `%00xxxxxx`, which
> the gate array takes as a **pen select**. The colour silently never changes
> and you sit there staring at the firmware palette. This already happened
> once.

---

## Generated files

`src/gen/` is generated and git-ignored. `tools/gentables.py` is the readable
specification for every lookup table; the tests re-derive the numbers from it
and compare against what is actually in the emulator's RAM, so a table that
changes shape fails the tests instead of quietly corrupting the projection.

Tables: `scr_line_lo`/`scr_line_hi` (screen line offsets, two byte planes on
consecutive pages), `qsq_lo`/`qsq_hi` (quarter squares for multiplication),
`sin_lo`/`sin_hi` (8.8 sine, 256 angles; cosine is the same table at
`(a+64)&255`).

---

## Where the project is

Design document section 13 lists ten phases.

- **Phase 0 — done.** Boot, Mode 1, double buffering, page flip on the VSYNC
  edge, per-buffer dirty rectangles, disc image that boots.
- **Phase 1 — done.** Signed multiply, orbit camera matrix, per-entity
  projection with clipping. The Z80 is verified **bit-exact** against the
  Python model in `tools/gentables.py` over thousands of random inputs —
  that model is the specification, and if you change a shift you change it in
  both places. 100 points run at ~7 fps (see the budget table above for why
  that is expected, and fine).
- **Phases 2 and 3 — done.** Masked sprite blitter with full clipping,
  per-buffer dirty rectangles, z-sorted draw order, yaw view and size tier
  chosen per entity. The blitter is verified pixel-exact against a Python
  model of `(screen AND mask) OR data`, including that a clipped sprite writes
  nothing outside its clipped rectangle.
- **Phase 4 — done.** The 20-byte entity record from section 7, keyboard
  matrix scanning, an 8×8 font and the HUD strip, squadrons, and formation
  flight. 20 ships at ~8 fps.
- **Phases 8 and 9 — done.** Eight missions as data in bank 4, objectives
  (clear / survive / arrive), `J` to jump when the objective is met, briefing
  screens, and the fleet carrying between them with losses permanent — now
  through `FLEET.DAT` on the disc, so it survives the power going off too.
  Played as the design intends, missions 1-5 cost one ship. What is left is
  authoring and taste, not engineering.
- **Phase 7 — done.** Resource patches, harvesters, RU, and a build panel;
  `H` and `B` are live. The loop closes: build a harvester, send it out, and
  what it mines pays for the next ship. What is NOT in: build costs for the
  classes that have no art yet (Scout, Bomber, Frigate, Salvage Corvette,
  Destroyer), and a build *queue* — the yard takes one order at a time.
- **Phase 6 — done.** Both fleets fire, hulls take damage, ships die and leave
  explosions, and the AY plays a tone for a shot and noise for a kill.
  Targeting is round-robin — one entity re-targets per frame — so no frame
  pays for a full search.

  Two things §6 asks for that are **not** in: the §8 balance triangle (every
  class does the same damage) and enemy movement (the picket holds station, so
  the player brings the fight to it).
- **Phase 5 — done, and §9 is closed** except for the three commands that
  need content from later phases (see the control table above). Camera, zoom,
  pause, move disc, formations, sensor view, Mothership, docking and target
  selection all work.
- **Two ship classes now link in**, which is what proved the bank window
  works. The Mothership wears the Frigate's sprites until it has its own; see
  `src/game/shipclass.asm`. Capital ships get a **tier bias** so they draw a
  size larger than their distance alone would give — without it a Mothership
  at 200 units is exactly as big as a fighter at 200 units and the fleet reads
  as a swarm of identical specks.
- **Not drawn yet: the reference grid at Y=0** (section 4.1). It wants a
  cheaper projection than `proj_point` — a 5×5 lattice through the full
  pipeline is 114,000 T-states, which is a quarter of the frame for a
  backdrop. The grid is regular, so its projected points are related and can
  be stepped rather than each one transformed; that is the job.

`src/demo/phase4.asm` is the acceptance test running on the CPC itself.

**Only one ship class is linked in**, but that is now a choice rather than a
limit: bank 4 has ~10 KB spare, enough for a second class. Add it to
`SHIP_CLASSES` in the Makefile and to the include list in `src/main.asm`.

### Controls

| Key | Effect |
|---|---|
| `1`-`9` | select a squadron (see below) |
| `0` | centre on the Mothership, clearing any pan |
| cursor keys | orbit the camera; drive the move disc while it is open |
| `Z` / `X` | zoom in / out, four steps |
| `P` | pan: the cursor keys drag the view instead of orbiting |
| `SPACE` | tactical pause — the battle freezes, orders do not |
| `ENTER` | open the move disc; again to confirm |
| `ESC` | cancel the disc |
| SHIFT + up/down | raise and lower the disc instead of moving it across |
| `F` | cycle the formation: Loose → Wedge → Sphere → Wall |
| `TAB` (or `S`) | tactical view ↔ sensors |
| `R` | station the squadron on the Mothership |
| `,` / `.` | step the target through live entities |
| `A` / `G` | attack / guard — writes the order, nothing acts on it yet |
| `H` | send the selected squadron's **harvesters** to work |
| `B` | open the build panel; `,`/`.` pick a class, ENTER orders it |
| `ESC` | the orders menu — cursor keys pick, `ENTER` runs it |
| `?` | the key list; `ESC` goes back |
| `SPACE` | on the title screen, start the game |

`J` jumps when the objective is met, and writes the save on its way out.

While the build panel is open it takes over `,`, `.` and `ENTER` — one pair of
keys, two meanings, decided by the mode the player can see on screen.

`TAB` is bound and correct per the hardware matrix but **unverified** — the
emulator's keymap has no TAB entry, so no test can press it. `S` does the same
thing and is tested.

The camera orbits whatever is selected (§4.3) — the squadron's *station*
rather than its centre of mass, so the view settles the moment an order is
given instead of drifting along behind the formation.

`A` and `G` write `ENT_ORDER` and `ENT_TARGET` into the selected squadron's
records and stop there. The control surface of §9 is complete; the behaviour
behind it is Phase 6.

**The design's §9 puts the move order on `M` and docking on `D`, and those
keys now belong to the squadron commands.** So the move disc opens and
confirms with `ENTER` — which §9 already had as the confirm key — and cancels
with `ESC`. Docking will be `R`. One equate each if that turns out wrong.

Disc movement is camera-relative so "right" means right on screen. The yaw is
rounded to one of eight octants and the step vector comes from a table, so it
costs no multiplies; at 45° granularity the difference from a true rotation is
not visible on a 320-pixel screen.

### Squadrons

Nine of them, numbered 1-9. A squadron is ACTIVE if and only if it has ships
in it — there is no separate flag, which makes "a squadron left with no ships
is deactivated" true by construction. `squad_count` is derived by recounting
the entity table, never maintained incrementally: running totals drift once
ships start dying, and a 48-slot recount is only ~2,000 T.

| Key | Effect |
|---|---|
| `1`-`9` | select that squadron, if it has ships |
| `d` | divide the selection in half; the new half takes the next free number |
| `m` | move one ship to the next number, creating it if need be |
| `n` | move one ship to the previous number; for 1 that is 9 |
| `c` | combine the selection with the next ACTIVE squadron |

Two judgement calls worth knowing about. `m`/`n` step numerically and wrap
(1 → 9 going back), because they explicitly create the target; `c` takes the
next *active* squadron instead, because merging with an empty one would be a
no-op and the HUD only lists the active ones. All the commands are
edge-triggered — holding `d` divides once, not once a frame — and
`tests/test_squad.py` presses real keys in the emulator to prove it.

### The campaign, and where the fleet lives

A mission is a row in `mission_table` (bank 4): a name, where the enemy is,
where the resources are, and what winning looks like. Adding a mission is
adding a row. The player's ships are never rebuilt by `mis_setup` — they are
already in the entity table, either freshly spawned or restored from the bank.

**The fleet is on the disc, written by our own FDC code** — `src/sys/fdc.asm`.
§11 suggests bringing the firmware back "on the screens between missions" to
reach the drive, and that route is closed for good: screen B sits at
`#8000-#BFFF`, right on top of AMSDOS's workspace at `#A700`, so the first
time the game clears its second screen the firmware is gone. So the µPD765 is
driven directly. `J` writes the save; `demo_init` looks for one at boot.

It goes to **two raw sectors, track 39 `#C1` and `#C2`, and is not an AMSDOS
file.** A real file needs directory allocation, which is several hundred bytes
more than the low 16K has (512 left). AMSDOS hands out blocks from track 2
upward and `DISC.BIN` takes about five tracks, so the last one is a long way
from anything it would use — but copy another file onto this disc with CP/M
and it may land on the save.

Three things to know before touching it:

**Every hang this code has had was the same mistake**: assuming the controller
is where you left it. It is a separate chip running on its own time, and the
emulator here hides that — `chips/upd765.h` resolves the phase *synchronously*,
the instant the last command byte is written, and never runs out of patience.
A real controller does neither, which is why the first version of this worked
perfectly under test and **hung on every jump in Retro Virtual Machine**.

The transfer loop therefore watches `RQM`, `DIO` and `EXM` together, and the
three cases it has to survive are:

- **The command is refused** — no disc, no such sector, write protected. The
  controller never enters the execution phase; it goes straight to the result
  bytes. (No disc is the *common* case here: `boot_quick` never inserts one.)
- **The transfer ends early** — we were too slow feeding it, so it gives up and
  leaves the execution phase part way through. A loop that only ever waits for
  "ready, wants a byte" then waits forever.
- **It has not decided yet.** Testing `EXM` immediately after the last command
  byte is a race: the chip has not entered execution, `EXM` reads 0, and code
  that takes that for a refusal settles down to wait for result bytes it is not
  sending — while it waits for data we are not sending. That was the RVM hang.

Testing `EXM` alongside `RQM`/`DIO` is **free** — one more bit in a mask that
was already being compared — so the fast path stays inside the controller's
32-microsecond-a-byte budget. Do not be tempted to "optimise" it back out.

- **Drain the result by status, not by count.** `fdc_drain_result` reads until
  `CB` clears. READ and WRITE return seven bytes, SENSE INTERRUPT STATUS
  returns two, and a SENSE with no interrupt pending returns *one* — counting
  means the count has to be right everywhere, and being one too high is a wait
  for a byte that is never coming. It also runs before the first command, since
  AMSDOS ran before us and the chip keeps its state across the ROMs going out.
- **EOT must equal R.** It is the last sector of the transfer, so for a single
  sector it is the sector itself. The emulator asserts on this rather than
  returning an error.

The header (magic, mission index, ship count) sits *in front of* the fleet in
the same bank-4 block, padded to two whole sectors, so a save is two writes
from one address instead of a gather. `fleet_disc_load` checks the magic and
range-checks the mission index: a blank disc, another game's disc and a
half-written save all arrive there, and two of them would index off the
mission table.

**`DISC.BIN` used to be close to its ceiling**: it loads at `#4000` and must
finish below `#A700`, and it once ended around `#A66C` — 148 bytes of
headroom, with a second ship class already impossible. The sprite library is
now RLE-compressed (`tools/packsprites.py`, 12767 → 6818 bytes), which brought
the file to 21938 bytes ending near `#9592` and left roughly **4.4 KB**.
Uninitialised bank data (the fleet buffer) is deliberately declared *after*
`bank4_end` so it costs nothing in the file. Per-mission loading, which §10
wants anyway, still needs the same FDC work.

### The economy

Four resource patches with a stock that runs down; harvesters fly out, fill a
hold, fly back to the Mothership and turn it into RU. A harvester's whole
state is its `ENT_ORDER` plus its hold, so there is no harvester table to keep
in step with the entity list — the same reasoning as `squad_count`.

Three things that bit, all of them the same shape — two systems writing the
same thing:

- **The hold lives in `ENT_LOAD`, not `ENT_TIMER`.** Combat decrements
  `ENT_TIMER` every frame as a weapon cooldown, and a hold that drains itself
  is a puzzling thing to debug.
- **`phase4_fly` skips ships that are harvesting.** Both it and `eco_update`
  step by `PHASE4_STEP`, so they cancelled exactly: the harvester sat
  vibrating in place while the RU never moved.
- **Mining clamps at zero.** The last scoop took a patch below zero and a
  16-bit stock wrapped to 65534, turning an exhausted field into an
  inexhaustible one.

`H` only orders **harvesters**, which §9 marks explicitly. Ordering the whole
squadron out put fifteen interceptors on a patch and mined the map dry in
seconds — the economy is meant to be a choice, not a free action.

### Sound and the keyboard share port A

The PSG is reached through PPI port A, and so is `key_scan`. Port A is a
bidirectional bus whose direction lives in the PPI control word, so the two
have a contract: **port A output, port C `PSG_INACTIVE` is the resting state.**
`key_scan` runs `DI`…`EI` from the main loop and restores it; `snd_update`
runs from the interrupt, re-asserts the direction rather than trusting it, and
drops port C back on every write. Break either half and the keyboard goes deaf
or the sound freezes mid-envelope — and the symptom lands in whichever test
runs next.

Envelopes are in **software**. The AY has one shared envelope generator, so
two overlapping effects would retrigger each other; amplitude bit 4 is never
set and R11-R13 are never written. Mixer bit 6 must stay 0 or the PSG's port A
becomes an output and the keyboard stops working — there is a build-time
assert for it.

### Enemies cost no sprite data

Pen 3 is both bit planes set and pen 1 is only the high one, so
`data OR ((data >> 4) AND #0F)` turns every pen-1 pixel into pen 3 and leaves
pens 0 and 2 alone. `spr_erow_start` is the same unrolled blit with those four
instructions folded in. A second copy of every sprite library would be 5.6 KB
a class.

Only the DATA is recoloured, never the background showing through the mask —
a friendly ship behind an enemy stays white.

Do not test this by counting pen-3 pixels on a live screen and nothing else.
Once the enemy closes on its target it parks *behind* the fleet, where the
painter's algorithm correctly hides every last enemy pixel — and a blank count
then looks exactly like a broken recolour. `TestEnemyRecolour` in
`test_phase3.py` drives `spr_blit` directly and compares the pen histogram
with and without `spr_enemy`, which separates "not drawn" from "not coloured".

### Never trust a slot index

`ENT_TARGET` holds an entity index, and a zeroed field names **slot 0, not
"nobody"** — so every freshly spawned ship came up aimed at whatever was in
the first slot, and the fleet shot one of its own before it ever met an enemy.
`ent_clear_all` now writes `ENT_NO_TARGET`, and more importantly
`cbt_fire_if_able` checks the sides at the moment of firing rather than only
when a target is chosen. Stale indices, recycled slots and zeroed fields all
name *something*.

### A fleet has to be able to concentrate

Three separate things conspired to make the player's fleet lose fights it
should win. Eight friendly interceptors against eight enemy ones, identical
hulls and identical guns, ended **8-0 to the enemy** every time — and the
mechanics are symmetric, so the cause was never the damage numbers.

1. **`A` set a target and nothing else.** `ENT_ORDER_ATTACK` was written by
   `order.asm` and read only by `cbt_retarget_one`, to stop the AI overwriting
   it. Nothing ever *moved* the ship. So an attacking squadron aimed from
   wherever its formation slot happened to be, while the Vekhar — who always
   close — massed on it. `cbt_move_enemies` now closes anything hostile *or*
   under an attack order, and `phase4_fly` skips attackers for the same reason
   it skips harvesters: two systems stepping one ship by `PHASE4_STEP` in
   different directions cancel exactly.
2. **Retargeting was round-robin at one ship a frame.** Ships close together
   all pick the same nearest enemy, so a single kill left the *whole* squadron
   holding a dead target and idle for up to `ENT_MAX` frames, while a strung-out
   enemy — each ship aiming at a different target — lost only the few that had
   been aiming at the casualty. **Concentrating fire was punished.**
   `cbt_fire_if_able` now re-acquires the moment it finds its target is
   wreckage; the round-robin stays as the slow path for drift.
3. The default formation is wider than the gun. `FORM_SPACING` 2200 spreads a
   16-ship squadron 13200 units corner to corner — a Manhattan diameter of
   ~103 range-units against `CBT_RANGE` 40. This one is *not* fixed: it is what
   makes "hold formation" a genuinely worse tactic than "attack", and pressing
   `A` is the answer. Raising `CBT_RANGE` to 56 was tried and made missions 3
   and 4 worse, because it lets the enemy's ball reach more of the spread.

Measured campaign cost with the fleet holding station over the Mothership and
attacking: missions 1-5 cost **one ship**. Mission 6 (`enemies_scatter`) must
be fought by *holding*, not chasing — 9 of 14 survive that way and the
Mothership dies if the fleet leaves it. That asymmetry is the design's, not a
bug: §8 makes losing the Mothership the end of the game.

### Never trust a slot index, part two: `moth_slot`

`fleet_restore` packs survivors down into slots `0..n-1`, so after two losses
the Mothership comes home to slot 13, not 15. `moth_slot` was not updated —
and `mis_setup` had just spawned an **enemy interceptor** into slot 15. The
defeat check then watched that enemy, and the moment the fleet shot it down
the campaign ended with "the Mothership was lost", at mission 5, every run.

Anything that caches an entity index across `fleet_save`/`fleet_restore` has
this bug waiting for it. `fleet_restore` now re-finds the Mothership by class
as it loads.

### The harness counts 50 Hz frames, the game runs at 12.5 fps

`run_frames(n)` advances *emulator* frames. `DEMO_TICKS_PER_FRAME` is 4, so
**one game frame is four of them** — and the game does not hit 12.5 fps, so in
practice it is nearer **ten**. A test that waits `CBT_COOLDOWN` frames for a
weapon to come round waits a fraction of the time it thinks it does. Multiply
by `TICKS_PER_GAME_FRAME` when a test is timing game logic.

The nastier version of this: **every command is edge-triggered, so a test that
presses the same key twice must leave it up long enough for `key_scan` to
observe the release.** `test_phase5` released for 15 emulator frames, which at
the real frame rate is one scan if the phase happened to suit and none if it
did not — so the second press was not a press at all. It passed for a long
time on that coin landing right, and what finally tipped it over was adding
the FDC probe to `demo_init`, which shifted the boot by a fifth of a second
and changed nothing else. If a keyboard test starts failing after an unrelated
change, suspect the release window before you suspect the change.

### Loading, and AMSDOS's workspace

`DISC.BIN` is one file loaded at `#4000`, and **AMSDOS keeps its workspace from
`#A700` up** — load past that and the transfer corrupts the very code doing
it. The failure is nasty because `harness.boot_quick()` pokes the image
straight into RAM and keeps working perfectly; only `boot_disc()` catches it.
`src/disc.asm` asserts the file ends below `#A700`.

The sprite library is staged through **screen A** (`#C000`) on the way into
bank 4: it cannot simply sit above `#8000` any more, because a second ship
class pushed the file past AMSDOS. Screen A is 16K of RAM nothing needs until
`sys_boot` clears it, it is untouched by the `#4000` paging, and it is exactly
one bank big.

### The title screen

`HOMEPLANET` across the full width, a starfield, a flight of ships, the credit
line, a blinking `PRESS SPACE TO START`, and `SPACE` to go on to the first
briefing. Third screen to work this
way after the briefing and the help page, with the same two obligations:
repaint every frame, and set `mis_wipe` on the way out.

**The title is sized to the screen rather than centred on it.** `txt_big`
blows the ordinary 8×8 font up 4× — in Mode 1 one source pixel is exactly one
screen byte, so a glyph is 8 bytes and ten glyphs is the whole 80-byte line.
That is why the game is called a ten-letter word on this screen, and
`src/main.asm` asserts it. Rename it and the build says so.

The face is 5 pixels in an 8-pixel cell, so **the last three byte columns are
blank by construction** — the title is flush left and stops one tracking-width
short of the right edge. That is what "spans the screen" means for this font;
a test asserting ink in column 79 is asserting the wrong thing.

`spr_x` is a **byte column, not a pixel** — the first flight had three of its
five ships off the right-hand side because the table was written in pixels.

Two things this screen broke by touching state it did not own, both of which
showed up as "the HUD comes and goes":

- `title_draw_ships` opens `spr_clip_bottom` to all 200 lines so the flight can
  sit anywhere, and it has to **close it again itself**. Restoring it in
  `title_key` does not work: `title_key` only clears the flag, and the frame
  loop goes on to call `title_draw` one last time in the same frame, which
  reopened it permanently. The tactical view then drew over the HUD and the
  dirty-rectangle erase rubbed it out again.
- `mis_wipe_screen` now clears **all 200 lines**, and everything that schedules
  a wipe marks the HUD dirty. It used to stop at `spr_clip_bottom`, which left
  the title's credit line — at y=186, inside the HUD's strip — on screen for
  the rest of the game, because the HUD does not clear its strip, it draws
  labels onto it.

### Panning, and how big the world actually is

`P` hands the cursor keys to the camera; `0` (and the menu's CENTRE ON BASE)
clears the pan and goes back to the Mothership. **Clearing the pan is the
point** — without it "centre" leaves the camera as far off the Mothership as
the player had wandered, which is the state they pressed it to get out of.

Panning reuses `order_disc_move` rather than copying it: the mover writes
through `disc_target`, which points at `disc_pos` while the move disc is open
and at `cam_pan` while panning. Same octant rounding, so "right" is right on
screen for both. The pan is an *offset* applied in `order_focus` after the
selection is copied, so the camera still follows the squadron — it just does
it from off to one side.

**The play area cannot be made bigger without rescaling the world.** World
coordinates are 16-bit and the content already reaches ±26000 of ±32767;
`WORLD_SHIFT` is 8, so the whole world is ±128 camera units while `cam_dist`
is 110-250. That is why it feels small: at the widest zoom you are looking at
essentially all of it.

Four times the extent means `WORLD_SHIFT` 6 (±512 camera units) *and*
dividing every authored position by four, so ships stay the same size on
screen. That is a wide change with three sharp edges:

- `proj_v16` must stay in -256..255 for the `f9` signed-multiply trick, and at
  `WORLD_SHIFT` 6 a delta past ±16320 world units overflows it and the entity
  reappears somewhere it is not. `proj_deltas` needs a range check — which is
  also a *win*, since it would reject distant entities before the 2790-T
  rotate rather than after.
- `cbt_distance` shifts by 8 to compare with `CBT_RANGE`; with positions four
  times smaller it has to shift by 6 to mean the same thing.
- `tools/gentables.py` is the bit-exact reference model for the projection and
  has `WORLD_SHIFT` in it. Change one and not the other and the differential
  tests are comparing against the wrong answer.

### The orders menu

`ESC` puts §9's commands on the screen with their shortcuts beside them,
cursor keys walk the list, `ENTER` runs one. It stops the world like the
briefing and the help page.

**It does not know what any command means.** Each entry in
`src/game/menutext.asm` carries a *key id*, and choosing one **injects that
key** — `key_inject` writes its bit into `key_edge` and `demo_update` falls
through into the playing path so `phase4_commands` acts on it in the same
frame. A menu that called `order_issue` and `eco_build_open` itself would be a
second copy of that dispatch, and the two would drift the first time a command
grew a precondition. Adding an order to the menu is adding a row.

Two things this depends on:

- **`key_scan` rebuilds `key_edge` from the hardware every frame**, so an
  injected edge left for the *next* frame is wiped before anything reads it.
  That is why the menu falls through rather than returning.
- **`key_edge` is cleared before the injected bit goes in.** The `ESC` that
  opened the menu is still in there, and `order_update` reads `ESC` as
  "cancel" — so choosing MOVE DISC would have opened the disc and cancelled it
  on the same frame. `ESC` only opens the menu when `disc_active` and
  `eco_build_open` are both clear; while either is up it still means cancel.

`key_inject` is the mirror of `key_bit` and has to agree with it: `key_bit`
reads the flag out with `RRCA`, so bit n of the row byte **is** key n of that
row — no reversal.

### The help page

`?` (which is SHIFT + `/`; the matrix only ever reports the physical key, so
`KEY_SLASH` catches it either way) puts §9's control table on the screen, and
`ESC` puts it away. It works exactly like the mission briefing and shares its
two obligations: **repaint every frame**, because the display page-flips and a
screen painted once alternates with whatever the other buffer holds; and set
`mis_wipe` on the way out, because it covers the tactical area without
recording a dirty rectangle for any of it, so nothing else will ever erase it.

The page's CODE is in bank 4 too, along with the menu and the title. The rule
that emerged: **anything that only runs while the game is stopped belongs in
the bank.** The low 16K is for the frame loop. Moving the help page and the
menu's two keyboard helpers out is what bought back the 512 bytes the orders
menu spent — and the tests notice immediately, because `HELP_SHOWN` then has
to be read with `read_cpu`. `src/game/helptext.asm` is the layout: two
columns of `HELP_ROWS` zero-terminated strings, walked in order, so the order
in the file is the order on screen. Keep every line inside 19 characters;
`txt_draw` clips at the screen edge, not at the column.

### The HUD

Owns the strip below `HUD_TOP` (line 168). `spr_clip_bottom` keeps the
tactical view out of it, which is what lets the HUD be redrawn only when it
changes rather than every frame — worth ~90,000 T. `phase4_hud_changed`
compares the counts against a shadow copy rather than having each command
remember to flag itself, because ships dying will change the counts with
nobody pressing anything.

### Known open questions

- **Enemy sprites need no separate storage.** In Mode 1 the pen bit-0 plane is
  the high nibble and bit-1 the low, so `data OR ((data >> 4) AND #0F)` turns
  every pen 1 into pen 3 and leaves pens 0 and 2 alone — three instructions in
  the blitter instead of a second 5.6 KB copy per class. `--faction enemy`
  exists for hand-retouched variants; do not ship both sets by default.
- **Sprite memory is 17% over §5.1** (5.62 KB per class, not 4.8 KB) because
  every sprite is stored one byte wider than it is, to give the 2-pixel
  pre-shift somewhere to land. Three classes = 16.9 KB, which does not fit one
  16 KB bank. Adding the second pitch level doubles it. §14 already lists the
  mitigation: 6 yaw views instead of 8.
- **Tier A (8×6) barely distinguishes the classes.** Bow-on, a frigate is 6×2
  and an interceptor 4×2. Class identity at that size is carried by bulk, not
  shape, with a 2-pixel margin.
