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
numbers.

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
bank 1 for `#4000`. Use `harness.read_cpu()` for anything in the window — it
goes through `peek`, which honours the paging.

---

## Conventions

### Naming

`<subsystem>_<verb>` for routines, `<subsystem>_<noun>` for data:
`scr_fill_rect`, `scr_line_addr`, `sys_boot`, `demo_update`.
Subsystem prefixes: `sys_`, `scr_`, `snd_`, `ent_`, `cam_`, `hud_`, `spr_`.

Local labels start with `@` and are scoped to the enclosing global label.

**RASM is case-insensitive.** `demo_objects` and `DEMO_OBJECTS` are the same
symbol and the build will fail with "there is already an alias with the same
name". Do not distinguish an equate from a label by case alone.

**`@` labels are GLOBAL.** Not per-routine, not even per-file — two routines
anywhere in the build cannot both have an `@no_carry`. Prefix them with the
subsystem (`@spr_no_carry`). Check with:

```bash
grep -hoE '^@[a-z_0-9]+' $(find src -name '*.asm') | sort | uniq -d
```

**`JR` reaches ±127 bytes.** A shared error exit at the end of a long routine
will be out of range; use `JP`. RASM reports it as "relative offset N too far".

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

A whole frame, 20 ships, measured (~7.3–8.3 fps against the 12.5 target):

| Stage | T-states |
|---|---|
| `phase4_draw` (20 masked blits) | 168,000 |
| `phase4_project` | 113,000 |
| `phase4_erase` (dirty rectangles) | 72,000 |
| `phase4_sort` (z order) | 54,000 |
| `phase4_fly` (formation movement) | 55,000 |
| `phase4_hud` | 800 |
| **total** | **~460,000** |

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
| `0` | select the Mothership |
| cursor keys | orbit the camera; drive the move disc while it is open |
| `Z` / `X` | zoom in / out, four steps |
| `SPACE` | tactical pause — the battle freezes, orders do not |
| `ENTER` | open the move disc; again to confirm |
| `ESC` | cancel the disc |
| SHIFT + up/down | raise and lower the disc instead of moving it across |
| `F` | cycle the formation: Loose → Wedge → Sphere → Wall |
| `TAB` (or `S`) | tactical view ↔ sensors |
| `R` | station the squadron on the Mothership |
| `,` / `.` | step the target through live entities |
| `A` / `G` | attack / guard — writes the order, nothing acts on it yet |

**Not implemented, and deliberately:** `H` (harvest) needs harvesters and
resources, which is Phase 7; `B` (build) is the same; `J` (jump) is Phase 8.

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
