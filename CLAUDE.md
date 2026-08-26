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
make test       # assemble, then run the emulator test suite (~7 min)
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

343 tests, about **five minutes**. It doubled when the sprite libraries moved
onto the disc: every `boot_quick` now spins the drive up and reads 69 sectors,
which is a second and a half of emulated time per machine and there are about
a hundred machines. That is the price of testing the real loader instead of a
poke, and it is worth it -- but do not add a fixture that boots per test
method when a `setUpClass` would do.

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

- `harness.boot_quick()` — insert the `.dsk`, boot the firmware, drop
  `DISC.BIN` at `#4000`, jump. Same code path as a real boot minus AMSDOS
  loading the file. Use this. The disc IS needed: six of the eight sprite
  libraries live on it as raw sectors and `lib_load` reads them at boot.
  `boot_quick(disc=False)` skips it, and is how the stand-in fallback is
  tested.
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
#4000-#7FFF   BANK WINDOW — bank 4 at rest; 5, 6 and 7 while blitting
#8000-#BFFF   screen buffer B
#C000-#FFFF   screen buffer A
```

`src/main.asm` asserts at build time that code+tables stay clear of the stack
and prints how many bytes are left in the low 16K and in every bank. Watch all
of them, and watch the "hand-written code ends at" figure rather than `free:` —
see "Where 700 bytes came from" for why the second one lies. The low 16K has
**512 bytes of which about 130 are reachable**, and bank 4 has **9**, so
anything sizeable goes in a bank and is reached through the window — the help
text, the mission table, the formation shapes, all the per-class data and the
cached half of the marker pass do.

**The low 16K's real floor is not `#4000`.** `tests/test_sound.py` puts 384
bytes of stub above `CODE_END` and `harness` puts another 0x60 there, so the
`free:` figure has to stay above about 450 — or a dozen test classes that have
nothing to do with your change start failing with "no room for the test
scratch".

### Banking

`OUT (#7Fxx), #C4..#C7` pages extended bank 4..7 into `#4000`; `#C0` is the
power-on layout. Equates in `src/equ/hardware.asm`.

**All four banks are in use now**, and they are not the same kind of thing:

| Bank | Holds | How it gets there |
|---|---|---|
| 4 | interceptor + frigate sprites; mission table; help, menu and title CODE; the cached marker projection; per-class data; formation shapes; the zoom table; the fleet buffer | inside `DISC.BIN` |
| 5 | mothership + harvester sprites | raw sectors, read by `lib_load` |
| 6 | scout + bomber sprites | " |
| 7 | salvage + destroyer sprites | " |

Getting bank 4 there is the awkward part, and `src/disc.asm` explains it at
length: the loader stub cannot live at `#4000`, because the instant it pages
bank 4 in, the window stops being the RAM the stub is executing from. The stub
sits above `#8000` and the sprite image is staged through screen A.

#### The one rule

> **Bank 4 is the RESTING STATE of the window. The only code that leaves it is
> `class_tier_addr`, and the only code that runs before it comes back is
> `phase4_blit_one`.**

`class_tier_addr` (`src/game/shipclass.asm`) selects a class's bank *and*
returns its sprite address, in the same three instructions — so you cannot get
an address without the library being under the window. That is deliberate, and
it is why there is no separate `spr_select_bank` for somebody to forget.
`phase4_blit_one` is a wrapper around `phase4_blit_body` for the matching
reason: the body has two exits, the sprite was clipped away or it was drawn,
and both have to return through `class_blit_done`.

Everything read between those two points must be in the **low 16K**:
`class_bank`, `class_sprite` and `class_geom` are there for that reason and
`src/main.asm` asserts it. Everything else per-class — costs, hulls, the damage
matrix, the tier bias, the three-letter tags — is in `game/classdata.asm`, in
bank 4, because it is only ever read with the window at rest.

`lib_load` breaks the rule on purpose, once, at boot: it has to, because the
destination of the sector read IS the window. It is in the low 16K, it calls
nothing in bank 4, and every exit path goes through one routine that puts bank
4 back and re-enables interrupts.

In tests, `read_ram()` indexes the base 64K by address and will hand you
bank 1 for `#4000`. Use `harness.read_cpu()` (and `write_cpu()`) for anything
in the window — they go through `peek`/`poke`, which honour the paging. This
catches you the moment a variable moves into the bank: `title_shown` read back
as 14 the first time, because `read_ram` was looking at bank 1, and
`eco_build_order` did the same thing when the class tables moved.

**The bank is executable RAM, not just data.** `#4000-#7FFF` runs code as
happily as it holds sprites — and that is the escape hatch when the low 16K
fills up. The title screen (`gfx/bigtext.asm`, `game/title.asm`) lives there
for exactly that reason: it runs once, before the first mission, so it has no
business competing for space with the frame loop. It went in the low 16K first
and took `CODE_END` to `#3D00`, which left the *tests* no room for their
scratch and broke seven classes that had nothing to do with it.

Banks 5-7 hold **sprite data only**, and must. Code assembled there could only
run in the one moment bank 4 is out, which is the one moment nothing else can.

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
a routine `title_stars` beside a count `TITLE_STARS`, and so is a variable
`lib_track` beside a layout constant `LIB_TRACK`. It is an easy one to walk
into because the two read as different kinds of thing — all three of those
were written, and all three failed the build, after this paragraph existed.

**`BANK n` gives each 16K image its own workspace, and labels are shared
across them.** A second `org #4000` in one bank is an error ("located in a
previous ORG section"); `src/main.asm` has four images, three of them at
`#4000`, so it declares `BANK 0` through `BANK 4`. `save` resolves in
whichever bank is current when the directive is read, so a `save` has to sit
inside its own bank's section. Using `BANK` at all makes RASM write a
`rasmoutput.cpr` cartridge into the working directory with no flag to stop it;
the Makefile deletes it.

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
| `proj_point` (one entity, full pipeline) | ~4,960 T | 1,200 T |
| `proj_point` (rejected by the distance clip) | ~260 T | — |
| `proj_rotate` (9 multiplies, m01 skipped) | ~2,790 T | — |
| `cam_build_matrix` (once per frame) | ~3,360 T | — |
| `phase4_group` (consolidation off) | ~800 T | — |
| `phase4_group` (16 entities, widest zoom) | ~15,200 T | — |
| paging a class's bank in and bank 4 back | ~30 T per entity | — |

**The zoom ladder costs 200 T an entity**, all of it in `proj_scale`: three
calls, one per axis, against the two `add hl,hl` that used to be inline. It is
4% of `proj_point` and about 1% of a frame, and it is what buys eight more
zoom steps. See the zoom section for the version that cost 300 and why it was
thrown away.

**Banking the sprite libraries costs about 1% of the frame.** Measured on
mission 1 with 16 entities: 5.00 fps before, 4.95 fps after. Two `OUT`s an
entity is nothing; the cost is the extra indirection in `class_tier_addr`,
which now reads a bank and a sprite address from two tables instead of walking
one. Worth knowing, and not worth optimising.

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
python3 tools/mkships.py --ship scout --contact-sheet   # just the one you changed
python3 tools/rt2sprite.py art/frigate.retrotools.json --out src/gen/spr_frigate.asm
```

**All eight classes are modelled**, and the models are twenty lines of
`prism()` each. Three rules decide every shape, and they are in the comment
above `_interceptor()`: vertical structure is what a ship is made of at 8×6,
wings must be CANTED or they are seen edge-on from all eight views, and beam
matters as much as length or the head-on view collapses to a dot. A fourth,
learned from the Salvage Corvette: a feature that distinguishes a class must
be **sideways**, not vertical, or it survives broadside and vanishes head-on.

The renderer normalises every class into the same sprite box, so "bigger" is
not available — `span` and the shape carry it, and `class_tier_bias` gives the
three capitals one more size step at the same distance.

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

### The palette is semantic, and the HUD uses it

`txt_draw` produces **pen 1 only** by construction: ink 1 is `%01`, so four
1bpp pixels are their own Mode 1 byte. The other two inks fall out of that for
almost nothing -- ink 2 is `%10`, the same pixels four bits down, and ink 3 is
both. `txt_set_pen` patches one mask per plane into the `AND` immediates in
`txt_pen_map`; there is no branch and no load per byte.

**It is not sticky by convention**: whoever changes the ink puts it back to 1,
so a routine drawing in white never has to ask what the last one left.

In the strip: labels and chrome (`RU`, `M`, `?HELP`) and the squadrons that are
*not* selected are ink 2, so the selection is the only white entry and the eye
finds it without reading a digit. `JUMP` is ink 3 -- the one thing in the HUD
that demands an action, in the ink §2 reserves for attention.

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

`src/gen/` is generated and git-ignored, and so is `build/bank5.raw` and its
two siblings — the extended-bank images `tools/discbanks.py` writes onto the
`.dsk`. `make` produces them in the same pass as `build/home.raw`, and the
`build/.banks-written` stamp is what makes "put them on the disc" a make
dependency rather than a thing to remember: `rm -f $(DSK)` mints a fresh image
every build and throws the previous copy of them away with everything else.

`tools/gentables.py` is the readable
specification for every lookup table; the tests re-derive the numbers from it
and compare against what is actually in the emulator's RAM, so a table that
changes shape fails the tests instead of quietly corrupting the projection.

Tables: `scr_line_lo`/`scr_line_hi` (screen line offsets, two byte planes on
consecutive pages), `qsq_lo`/`qsq_hi` and `f9_lo`/`f9_hi` (quarter squares for
multiplication, unsigned and nine-bit signed), `recip` (the perspective
divide), and `sin7` -- which is **one quadrant, 65 bytes**, folded by
`cam_sin`.

There is a second generated file, `gen/zoom.asm`, and it is the odd one out:
it holds `cam_zoom_table` and is assembled into **bank 4**, because
`order_apply_zoom` reads it on a keypress with the window at rest and the low
16K has nothing to spare.

**Two tables that used to be here are gone, and must not come back.** `sin7`
was 256 entries and `tier_lut` was 256 bytes of three distinct values;
`cam_sin` folds the one and `phase4_tier_for` does two compares for the other,
each for about the same T-states it cost to read a byte. That is 447 bytes of
the low 16K, and it is what the zoom ladder and the grouping pass are built
out of -- neither of them would fit otherwise. The rule that decides it: a
table earns its page when it is read in a per-entity or per-scanline loop
(`f9` is read eight times an entity and stays 1 KB), and not otherwise.
`cam_sin` runs four times a **frame**.

Four more have gone the same way since, out of bank 4 this time, and they paid
for the marker pass: the Y=0 lattice, half of `form_offsets`, the title
starfield and the briefing text's pointer table. See "Where 700 bytes came
from".

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
  what it mines pays for the next ship. **All seven of §8's buildable classes
  are on the list**, at §8's prices, with the Destroyer gated to mission 5.
  Every mission fields two to four patches and they are DRAWN, in the tactical
  view and in the sensor view, in the two inks described under "Markers".
  What is NOT in: a build *queue* — the yard takes one order at a time.
- **Phase 6 — done.** Both fleets fire, hulls take damage, ships die and leave
  explosions, and the AY plays a tone for a shot and noise for a kill.
  Targeting is round-robin — one entity re-targets per frame — so no frame
  pays for a full search.

  **The §8 balance triangle is in**: `cbt_damage_matrix` in
  `game/classdata.asm` is eight classes square, and the three legs —
  Interceptor → Bomber → Frigate → Interceptor — are the only place the
  triangle exists, because movement, range and cooldown are identical for
  every class. Hull is *not* the other half of it: a hull is one byte, so
  "tougher" tops out at 255 and the interceptor is already there. What makes a
  capital ship hard to kill is the column under it being small.

  Still **not** in: enemy composition. The Vekhar field interceptors and
  nothing else, so the triangle is a thing the player's fleet has and the
  enemy does not use. Giving `campaign.asm` a class per enemy row is the job,
  and it is data, not engineering.
- **Phase 5 — done, and §9 is closed** except for the three commands that
  need content from later phases (see the control table above). Camera, zoom,
  pause, move disc, formations, sensor view, Mothership, docking and target
  selection all work. The zoom is **twelve steps rather than §4.3's four** —
  see the zoom ladder below — and distant stacks consolidate at the wide end.
- **All eight classes of §8 exist, with their own art.** Interceptor,
  Mothership, Harvester, Scout, Bomber, Frigate, Salvage Corvette, Destroyer —
  each a model in `tools/mkships.py` and a 5.62 KB sprite library. Nothing
  wears a stand-in any more except when the disc cannot be read; see the
  banking section for where they live. Capital ships (Mothership, Frigate,
  Destroyer) get a **tier bias** so they draw a size larger than their distance
  alone would give — without it a Mothership at 200 units is exactly as big as
  a fighter at 200 units and the fleet reads as a swarm of identical specks.
- **The reference plane at Y=0, the resource fields and the off-screen
  Mothership indicator all draw through one pass** — see "Markers" below. All
  three are fixed world points, so all three are cached against a hash of the
  camera and cost nothing on the frames it has not moved.

`src/demo/phase4.asm` is the acceptance test running on the CPC itself.

**A ninth class does not fit.** Bank 4 has ~9 bytes left and banks 5-7 hold
two libraries each with 4.6 KB spare — enough for the data, but `LIB_SECTORS`
sizes a bank's disc image at exactly two libraries, and a third would need a
fourth bank the 6128 does not have in the `#7Fxx` window. The mitigations §14
lists are the way out: 6 yaw views instead of 8 (−25%), or tiers shared between
classes. Adding a class today means the Makefile's `SHIP_CLASSES`, a `BANK`
section in `src/main.asm`, a row in `class_sprite`/`class_bank`, an entry in
every table in `game/classdata.asm`, and a wider `LIB_BANKS`.

### Controls

| Key | Effect |
|---|---|
| `1`-`9` | select a squadron (see below) |
| `0` | centre on the Mothership, clearing any pan |
| cursor keys | orbit the camera; drive the move disc while it is open |
| `Z` / `X` | zoom in / out, **twelve** steps |
| `P` | pan: the cursor keys drag the view instead of orbiting |
| `SPACE` | tactical pause — the battle freezes, orders do not |
| `ENTER` | open the move disc; again to confirm |
| `ESC` | cancel the disc |
| SHIFT + up/down | raise and lower the disc instead of moving it across |
| `F` | cycle the formation: Loose → Wedge → Sphere → Wall |
| `O` | split the whole fleet into one squadron per class |
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

The panel offers all seven of §8's buildable classes, **cheapest first**, so
walking the list with `.` is walking up a price ladder rather than guessing.
A class that is not available yet is STEPPED OVER, not shown and refused: the
readout is one three-letter tag wide, so an entry the player can see but
cannot order looks like a broken ENTER key. Today the Destroyer is the only
one with a condition (§8: from mission 5), and `eco_pick_allowed` is one test
rather than a table of unlock missions — it becomes a table the second time a
class needs one. `eco_queue` checks as well as the stepper, because the pick
is a byte in RAM and the orders menu injects keys.

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
| `o` | one squadron per CLASS, across the whole fleet |

`o` is the one that scales. Carving a fleet up by hand is fine for three ships
and hopeless for thirty, and the division that matters in a fight is by class,
because §8's balance triangle is a statement about classes -- "send the bombers
at the frigate" needs the bombers to be a squadron before it can be an order.

**The number it hands out is the class index plus one, and nothing else.** That
is what makes it worth having: press it again three missions later and the
interceptors are squadron 1 again whatever was lost in between. A class with no
ships leaves its number EMPTY rather than everything shuffling up -- numbers
that move between missions are worse than numbers with gaps in them, because
the player's fingers have already learned them. The Mothership is left out and
so is its number, 2, which is therefore never handed out by this command.

It is thirty instructions and lives in `game/staticscreens.asm`, in bank 4,
because it runs on a keypress: writing `ENT_SQUAD` and calling `squad_refresh`
is the whole of it, and everything else -- the HUD, the selection falling back
if it emptied, each new squadron flying to its own station -- follows from
`squad_count` being derived.

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
more than the low 16K has (512 left). AMSDOS hands out blocks from track 0
upward and `DISC.BIN` takes about six tracks, so the last one is a long way
from anything it would use — but copy another file onto this disc with CP/M
and it may land on the save.

**The sprite libraries are on the disc the same way**, tracks 12-20, read by
`lib_load` at boot and written by `tools/discbanks.py` at build time. Same
trade, same caveat, and the layout lives in exactly one place: the `LIB_*`
equates in `src/sys/libload.asm`, which the Python tool reads back out of
`build/homeplanet.sym` rather than keeping its own copy. A loader and a writer
that disagree about where a sector is do not crash — they give you a bank full
of the wrong ship, which reads as a rendering bug.

They are stored **uncompressed**, unlike the bank-4 library. Bank 4 is packed
because `DISC.BIN` has a hard ceiling under AMSDOS; the disc does not, so
storing them raw means the sector read *is* the load — no decoder in a low 16K
that has 512 bytes, and no staging buffer, because the controller writes
straight into the window.

**`boot_quick` now inserts the disc**, and has to: without one the game runs
but six of the eight classes wear stand-ins. `boot_quick(disc=False)` is how
the fallback is tested. `insert_disc` takes bytes and cpcemu keeps its own
copy, so a test that jumps a mission writes into that copy and never into
`build/homeplanet.dsk`.

Three things to know before touching it:

**Every hang this code has had was the same mistake**: assuming the controller
is where you left it. It is a separate chip running on its own time, and the
emulator here hides that — `chips/upd765.h` resolves the phase *synchronously*,
the instant the last command byte is written, and never runs out of patience.
A real controller does neither, which is why the first version of this worked
perfectly under test and **hung on every jump in Retro Virtual Machine**. The
fix below was reasoned out rather than reproduced -- cpcemu cannot show the
bug -- and then **confirmed on RVM**: the jump no longer hangs.

That is worth remembering as a method, not just a fact. **Test on RVM before
believing the FDC works.** cpcemu is right about memory, the gate array and
the CRTC, and it is what the suite runs on; but it models the controller as a
state machine that resolves instantly, so every timing assumption this code
makes is one cpcemu will agree with whether or not the hardware would.

The transfer loop therefore watches `RQM`, `DIO` and `EXM` together, and the
three cases it has to survive are:

- **The command is refused** — no disc, no such sector, write protected. The
  controller never enters the execution phase; it goes straight to the result
  bytes. (No disc used to be the *common* case here, because `boot_quick`
  never inserted one. It does now, so this path is exercised by
  `boot_quick(disc=False)` instead — keep something using it.)
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

**`DISC.BIN`'s ceiling is what decides where a sprite library can live.** It
loads at `#4000` and must finish below `#A700`, so it has 26368 bytes to play
with; it is currently 25175, ending just under `#A207`, and that is **about 1.2 KB
of headroom**. One RLE-packed library is 3-4 KB. That arithmetic is the whole
reason six of the eight classes are read off the disc into banks 5-7 instead
of travelling in the file — it is not a stylistic choice, and no amount of
better packing gets 45 KB of sprites under a 1.5 KB gap.

The bank-4 library stays RLE-compressed (`tools/packsprites.py`, 15118 → 9217
bytes); without it the file would not fit at all. Uninitialised bank data (the
fleet buffer) is deliberately declared *after* `bank4_end` so it costs nothing
in the file.

### The economy

Four resource patches with a stock that runs down; harvesters fly out, fill a
hold, fly back to the Mothership and turn it into RU. A harvester's whole
state is its `ENT_ORDER` plus its hold, so there is no harvester table to keep
in step with the entity list — the same reasoning as `squad_count`.

**Every mission fields patches now**, two to four of them, and they are drawn
(see "Markers"). Three missions used to field one or none, which meant the
harvesters were baggage for a third of the campaign — and §7's economy is
supposed to be a running choice, not something that turns up in a few missions.
That was a data change in `game/campaign.asm` and nothing else.

`eco_patch_seed` is gone. `eco_init` used to copy a starting set of patches out
of bank 4 and `mis_setup` then wiped all four and copied the mission's own over
the top, every mission including the first — thirty-two bytes and an LDIR that
nothing ever read.

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
3. The default formation is wider than the gun. `FORM_SPACING` 550 spreads a
   16-ship squadron 3300 units corner to corner — a Manhattan diameter of
   ~103 range-units against `CBT_RANGE` 40. This one is *not* fixed: it is what
   makes "hold formation" a genuinely worse tactic than "attack", and pressing
   `A` is the answer. Raising `CBT_RANGE` to 56 was tried and made missions 3
   and 4 worse, because it lets the enemy's ball reach more of the spread.

**Balance numbers come from `tools/balance.py`, and the tactic is part of the
number.** How expensive the campaign is depends entirely on how it is played:
that script (hold station over the Mothership, press `A`) reaches mission 8,
while a second measurement that also stationed and attacked lost the
Mothership at mission 5. Neither was wrong -- they were different scripts. So
run the tool rather than quoting prose, and treat any figure here as "that
script, that build".

Latest run, with all eight classes in: missions 1-6 cost **two ships** between
them, mission 7 costs nine, and mission 8 takes the fleet. Mission 8 is where
the campaign ends.

```
mis enemy  in out lost   hull  fleet
  4     8  16  14    2   3330  int=13 moth=1
  6     6  14  14    0   2658  int=13 moth=1
  7    12  14   5    9    723  int=4 moth=1
  8    10   5   0    5      0  FAILED -- the Mothership was lost
```

**Mission 7's cost is not a number, it is a coin toss, and this is worth
knowing before anyone "fixes" a regression that is not one.** The zoom work
made `proj_point` 200 T-states slower and mission 7 went from losing four
ships to losing nine, which looks alarming and is not: adding **520 T-states
of `djnz` to `demo_update` and changing nothing else** takes the same
mission from four to seven. The fight is decided by which ship re-targets on
which game frame, `demo_wait_frame` drops the rate rather than the picture,
and a few hundred T-states move a frame boundary. Missions 1-6 and 8 did not
move at all. Run the control before believing a swing here.

That is the same shape as before the classes arrived, and it has to be: the
script never spends its RU, so every ship in it is an interceptor, and the
interceptor-versus-interceptor cell of the damage matrix is still 24. **The
balance triangle changes nothing about the campaign as authored**, because the
Vekhar field interceptors and nothing else. It will start to matter the moment
`campaign.asm` gets a class column.

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

**And a jump is not instant.** `mis_jump` increments `mis_index`, writes a
kilobyte of fleet to the DISC — with the drive spinning up, about a third of a
second — and only then opens the briefing. For that whole stretch `mis_index`
already says the new mission and `mis_briefing` still says zero.
`dismiss_briefing` used to read the flag once and return when it was clear, so
a test that pressed `J` and looked immediately concluded there was nothing to
dismiss and sent its next command into a briefing screen that appeared a
moment later, where nothing runs. Two campaign tests failed with `1 != 2` and
neither of them was about discs. `harness.wait_for_briefing` is the fix, and it
is bounded, because a refused jump legitimately never puts one up.

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

### Panning

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

### How big the world actually is

**`WORLD_SHIFT` is 6, and the play area is ±32767 world units on each axis =
±512 camera units.** It used to be 8, which mapped the whole 16-bit world into
the ±128 cube the camera can see at once — and with `cam_dist` at 110-250, the
widest zoom then showed essentially all of it. That was the smallness.

The shift alone would only have made everything four times bigger on screen.
So **every authored position and speed in `src/game/` was divided by four** at
the same time: `FORM_SPACING`, the wedge/sphere/wall tables, `DISC_STEP`,
`PHASE4_STEP`, `GRID_SPACING`, `order_home`, and every enemy and resource
layout in `campaign.asm`. The two changes cancel exactly — the screenshots
before and after are byte-identical — and the extra room is the coordinate
space the content vacated.

**`DISC_LIMIT` was deliberately NOT divided.** It is 30000, the clamp on how
far the player may send anything, and leaving it hard against the 16-bit edge
while the content shrank into a quarter of the space is the whole point.

Three things this touched, and they are the ones to be careful with:

- **`proj_deltas` now clips, and the limit is ±8191 world units, not
  ±16320.** A camera-space component has to fit a SIGNED BYTE — not
  -256..255 — for two independent reasons, both about `MAT_ONE` being 127:
  `MULACC` indexes `f9` with `m+v` as a nine-bit two's complement number, so
  `|m| + |v|` must stay under 256; and `proj_rotate`'s accumulator is bounded
  by `127 * |v|max * sqrt(3)`, which is 28156 at 128 and 56312 at 256. Only
  the first fits 16 bits. So **what you can see at once did not grow** — it is
  still a ±128 camera cube around the focus. The world got bigger; the window
  onto it did not.

  This is a performance *win*, and a large one: a rejected entity never
  reaches the 2,790 T-state rotate. Measured, `proj_point` went from 4,560 T
  to **4,760 T** for an entity in range and to **260 T** for one out of it.
- **`proj_deltas` also tests P/V on the subtract.** Two coordinates can be
  60000 apart now that `DISC_LIMIT` outruns the content by 4×, `SBC HL,DE`
  wraps, and the sign bit lies — the same trap `phase4_approach` documents. A
  ship 60000 away read as 87 units away without this.
- **`cbt_distance` and `eco_range_check` shift by 6.** `CBT_RANGE` (40) and
  `ECO_HARVEST_RANGE` (24) are tuned, documented and unchanged; with positions
  four times smaller, the old `>>8` would have made every weapon and every
  harvester reach four times as far.

`tools/gentables.py` holds `WORLD_SHIFT` and is the bit-exact reference model,
so `project()` clips exactly where the Z80 does, both ways. The shift is
hand-coded in the Z80 (`proj_scale`'s ladder, and `PROJ_V_BIAS` for the range
test), so **`src/main.asm` asserts `PROJ_V_BIAS == 1 << (WORLD_SHIFT - 1)`**
and that the default zoom step is the one whose scaling is plain
`>>WORLD_SHIFT` — change the model without the assembly and the build stops.
At the old shift of 8 that
expression is 128, i.e. a range test that can never fail, which is why there
was nothing to clip before.

### The zoom ladder, and why `cam_dist` cannot zoom out

`Z` and `X` walk **twelve** steps now, not §4.3's four: four more in and four
more out, at roughly 1.4× a notch and 36× end to end. The four that were
always there are steps 4 to 7 and are unchanged, and step 5 is where the game
starts.

**Widening `cam_zoom_dist` does not zoom out, and finding that out is the whole
job.** `proj_deltas` has to fit one axis of `(P - focus)` into a signed byte,
so the camera can only ever see a **±127 camera-unit cube** around its focus.
`cam_dist` decides how much of the *screen* that cube covers and nothing else.
Measure it — the model will tell you in three lines — and at `cam_dist` 250 the
entire cube lands between sx 120 and sx 200: the **middle quarter** of a
320-pixel screen. So steps 5, 6 and 7 are not three amounts of world, they are
one amount of world drawn at three sizes, all with the same 8191-unit radius.
That is the "everything is small and far away" complaint, and pushing
`cam_dist` past 255 does not fix it — the perspective divide runs out of byte
and the far half of the fleet vanishes.

It also disposes of the obvious alternative, **scaling the projected sx/sy**.
There is nothing out there to reveal: the content is already crammed into the
middle quarter, and shrinking it further just makes the same ships smaller.

What actually changes how much world is visible is **how far a world delta is
shifted down on its way into the cube**. One more bit of shift is one more
doubling of the radius at *identical* screen positions and *identical* size
tiers — which is exactly what was asked for: the same small or large ships,
more world between them. Verified: across steps 8 to 11 the tier histogram is
byte for byte step 7's.

Powers of two alone would be a coarse ladder (four steps out would be 16×), so
there is a second form for the half-steps:

```
v = delta >> S           radius 128 << S
v = 3 * (delta >> S)     radius  42 << S      -- 3*43 is 129, so 42 is the cap
```

Alternating them gives steps of 4/3 and 3/2. `ZOOM_STEPS` in
`tools/gentables.py` is the table; it states only `(dist, shift, mul3)` and
derives everything else.

**`proj_scale` is the zoom.** Everything else — the key handler, the table,
`cam_dist` — is bookkeeping around twenty instructions. It has **no branches**,
and that is not showing off: the first version jumped into a shift ladder with
a patched JR displacement, which is three taken JRs an axis, nine an entity,
108 T-states of "which rung", and it took `proj_point` from 4,760 T to 5,060
and over the budget guard. Patching the *instructions* instead costs nothing:
`add hl,hl` becomes `NOP`, the range check's `add a,bias : cp limit` becomes
`and 0 : cp 1` where no check is wanted, the tail's `scf : ret` becomes a `jr`
into the ×3 code, and `>>9` — which the ladder cannot reach — is one `sra a`
after `H` is taken. `order_apply_zoom` LDIRs four runs of it out of
`cam_zoom_table`. Measured: **4,960 T**, up 200 from 4,760.

Two things that bound the ends of the ladder:

- **The innermost step is `>>4`, a radius of 2048 world units.** `FORM_SPACING`
  is 550, so a squadron fills the screen. Going further in is possible and is
  not useful.
- **The widest step is `>>8`, a radius of 32768 — the whole 16-bit world.**
  There is deliberately no step past it: `DISC_LIMIT` is 30000 and the
  subtract overflows past 32767 anyway, so a thirteenth step would show more
  empty space and nothing else.

**What this does NOT fix is the wasted screen.** The wide steps sit at
`cam_dist` 250, so the visible cube still covers only the middle quarter — the
same as step 7 always did. Filling the screen would need a magnification stage
between the perspective divide and the clip, and the low 16K has 512 bytes.
Dropping `cam_dist` for the wide steps instead is not the answer: `cam_dist`
IS the size tier, and ships would jump a size larger at the very step where
there are most of them.

The differential test in `test_phase1` runs the model against the metal at
**all twelve steps**, not just the neutral one. It has to: the plain steps and
the ×3 steps reject on different tests — a bound on the high byte against a
check on the scaled value — and either edge off by one puts a ship somewhere
it is not.

### Markers: the world points that are not ships

Three things share `src/gfx/mark.asm` because they are one problem — take a
world point no entity owns, project it, draw a handful of pixels, and record a
dirty rectangle so the next pass through that buffer erases them:

- the **reference plane at Y=0** (§4.1), a 4×4 lattice of blue dots;
- the **resource fields** (§7), a three-pixel cluster each;
- the **Mothership when it is off screen**, a marker on the border of the view
  showing which way it lies and how far above or below the camera it sits.

There is one marker vocabulary — `mark_dot`, `mark_bar`, `mark_cross`,
`mark_patch` — and every one of them appends its rectangle through
`phase4_add_rect`. The move disc, the sensor view's dots and crosses and the
explosion marks all go through it too; they each used to carry their own copy
of the same ten instructions, which was thirty bytes apiece in a low 16K that
has none.

**It costs nothing on the frames the camera has not moved.** None of these
points move — the lattice is fixed, a field is a fixed field, and the
Mothership holds station — so the projection runs against a hash of yaw,
pitch, zoom and the focus, exactly the way §5.4 caches the stars. Twenty-one
points through `proj_point` is about 100,000 T-states, a fifth of a frame, and
the player is not turning the camera on most frames. The cached half is
`gfx/markproj.asm` and it lives **in bank 4**, because it only ever runs with
the window at rest; it is the one piece of bank code reached from inside the
frame loop, and the rule it must not break is the one in `game/shipclass.asm`.

**The one thing NOT cached is a patch's ink**, because that is a function of a
stock that runs down while the camera sits still. A cached colour would be
telling the player yesterday's news about the only thing they have to act on.

#### Which two inks, and why

§2 gives three, and this is a real decision rather than a detail. Spending ink
3 on a resource field would make a rich patch read as a hostile, which is the
one mistake this palette cannot afford. So:

| Ink | Means |
|---|---|
| 2 | there is stock in it — scenery, in the scenery ink; nothing to decide |
| 1 | nearly mined out — the attention ink, because this is when the harvesters have to be sent somewhere else |

A patch with no stock is not drawn at all, which also disposes of the empty
slots: `mis_setup` zeroes the ones a mission does not use.

The **shape** carries the rest, because both inks already mean something else.
A patch is three pixels in a triangle: not a dot (the sensor view's fighters)
and not a cross (its capitals, and the move disc).

#### Which way an off-screen Mothership lies

`proj_point` tells you for free that a point is off screen, but its clip path
throws the rotated camera-space vector away — and past `PROJ_V_LIMIT` it never
computes one at all. Rather than a second projection pipeline, `moth_update`
**borrows the twelfth zoom step**: at `>>8` the visible radius is the whole
16-bit world and `proj_scale`'s range check is patched out altogether, so
`proj_deltas` cannot reject anything. Two LDIRs out and two back, on the frames
the camera moves; `src/main.asm` asserts that the last step really is that wide.

The border is a box twice as wide as it is tall, and the marker lands ON it by
construction: scale (dx, dy) until `max(|dx|, 2|dy|)` is the half-width and
whichever was the larger names the edge it touches. No dominance test and no
case analysis. The scaling is the perspective divide's own table — `recip[n]`
is `PROJ_K/n`, so `(v * recip[2m]) >> 7` is `v * 80 / m`, and the power-of-two
normalisation that puts `m` in 64..127 first is what keeps both the index and
the signed multiply inside a byte.

Three things worth knowing:

- **There is no front/behind test and none is needed.** `(rx, -ry)` is the
  direction to turn the camera whether the Mothership is in front or behind: a
  thing behind you and to the right is still found by turning right. Only
  straight along the view axis has no answer, and that draws nothing.
- **`160 + dx'` is SIGNED.** `dx'` reaches -160, so the high byte is `#FF` as
  often as it is 1. A clamp that tested "is the high byte zero" and treated
  everything else as 256.. put the left-hand marker on the RIGHT edge, and two
  pans that should have been mirror images came out identical. Found by
  screenshotting both, not by a test.
- Eight or sixteen fixed compass points was the cheaper option and was
  rejected: the marker would jump between them, and a bearing that jumps is one
  the eye stops believing.

The one case it does not cover is two points more than 32767 apart on one axis,
where the subtract inside `proj_deltas` overflows. `DISC_LIMIT` is 30000, so a
squadron sent to one end of the map with the Mothership past the middle can
just about do it. There is no marker then.

### Where 700 bytes came from

The three items above needed about 700 bytes across a low 16K with 512 and a
bank 4 with 74, and every one of them came out of something that was already
there twice. Worth reading as a list of the shapes to look for:

| Found | Bytes | What it was |
|---|---|---|
| `form_offsets` | 216 | Loose and Wall are the SAME 4×4 lattice, one flat and one on end; Wedge is flat so its Y is structurally zero. 384 bytes of `defw` became four numbers, sixteen pairs and one real 3D shape |
| `help_col_right` | ~120 | the help page's right column was the orders menu written out a second time. It now DRAWS `menu_entries`, stepping over the key id in front of each string |
| `title_star_table` | ~95 | forty stars as (x, y, pixel). The objection to generating them was TWINKLING, and twinkling comes from randomness — a xorshift reseeded to the same constant every frame lays the same field down every frame |
| `dist_manhattan` | ~90 | combat and the economy each had their own copy of the P/V test, the negate, the shift and the saturate |
| `phase4_add_rect` | ~80 | six things record dirty rectangles and every one carried its own ten instructions |
| `grid_lattice` | 96 | sixteen points made of four numbers. Stepped now, like `mark_lattice_step` |
| `mission_text_table` | 48 | twenty-four pointers at strings that were already in order and already zero-terminated |
| `phase4_step_toward` | ~55 | a harvester closing on a patch and a Vekhar closing on a target were the same fifty instructions |
| `phase4_set_fields` | ~40 | spawning a ship was "pop, push, load the offset, add, store" four times over, twice |
| `eco_patch_seed` | 32 | dead: `mis_setup` overwrote it before the first frame, every mission |
| `static_wipe` | ~30 | the briefing, the help page and the menu all began with the same six instructions |

**`code_end`'s `free:` figure is quantised and lies about how close you are.**
`gen/tables.asm` is page-aligned, so the number only moves in 256-byte steps —
the build now also prints where the HAND-WRITTEN code ends, and that is the one
to watch. The ceiling is `#31BF`: past it `sin7` pushes `scr_line_lo` onto the
next page, `code_end` jumps from `#3D00` to `#3E00`, and a dozen test classes
that have nothing to do with the change start failing because `test_sound`
reserves `#180` of scratch above `CODE_END`.

Both `print` statements now come BEFORE their asserts. RASM stops at a failing
assert, and "bank 4 contents overflow the window" without a number is a
question rather than an answer; the figure goes negative and says exactly how
much has to come back out.

### Six loops walked all 48 slots with `ent_addr`

`ent_addr` is a shift ladder and a `CALL` — about 120 T-states — and
`phase4_fly`, `phase4_project`, `cbt_update`, `cbt_move_enemies` and
`eco_run_harvesters` each called it once per slot per frame. They step a
pointer by `ENT_SIZE` now, which is one `ADD`, and that is about 21,000
T-states a frame back.

It was not an optimisation for its own sake. The markers cost about 2% of the
frame, and **`demo_wait_frame` quantises**: a game frame is a whole number of
50 Hz ticks, so work that was just under ten ticks and goes just over costs
eleven — a 2% change showing up as a 10% one. The frame-rate test failed at 4.5
fps against a 5.0 floor, measured 5.006 against 5.013 in a controlled
single-machine run, and the difference was entirely which side of a tick
boundary that particular fleet layout landed on. If a small change appears to
cost 10% of the frame, measure it on its own before believing it.

`cbt_update` walks a pointer of its OWN — `cbt_walk`, not `cbt_ent` — because
`cbt_ent` does not survive the body: `cbt_spawn_explosion` writes through it
when something dies.

### Consolidating a stack

At the wide steps a squadron is a handful of pixels, and a dozen ships drawn on
top of each other look exactly like one ship. `phase4_group` runs after the
z-sort and gathers them; the nearest keeps its sprite and gets `+n` beside it,
in its own ink. Below `CAM_ZOOM_GROUP_FROM` (step 8) nothing is consolidated at
all, so the four original steps look exactly as they did.

**The count is the whole group, not the remainder** — off a wide view the
number the player wants is how many ships are there.

**It has now been seen.** The tests passed from the start but nobody had ever
watched a `+n` appear, and the obvious way to make one -- piling the fleet on a
point -- does not work, because `phase4_fly` spreads it back into formation
within a few frames. The way that does: press `X` three times from the default
step, which takes the zoom past `CAM_ZOOM_GROUP_FROM` while the starting fleet
is still bunched at squadron 1's station. `+12` in white beside one interceptor
sprite, and `build/shots` has the picture.

Three decisions worth knowing:

- **A short list of heads, not a screen-space grid.** The grid was written
  first and looks cheaper. It puts a seam every 32 pixels, and a fleet sitting
  across one comes out as two groups eight pixels apart whose two labels
  overlap into `++7`. The screenshot is what killed it — there is no test that
  would have.
- **The merge distance IS the label's size**, three characters by one. Two
  heads that survive it are further apart than `+nn` is wide, so two counts of
  one class can never be drawn over each other *by construction*. This is the
  fix for the above, not a tuning knob.
- **The label takes no dirty-rectangle slot.** It widens the one the blit just
  wrote, and is skipped outright if the blit wrote none. A slot per entity in
  two buffers is 384 bytes, and over-erasing the gap between ship and label
  costs nothing — that rectangle is cleared and redrawn either way.

Side and class are both part of the key. Merging the two sides would put one
ink on a count that speaks for both, and §2 makes the ink the meaning.

Measured: **800 T-states** when consolidation is off — it is the `gcount` fill
and one compare — and **15,200 T** with sixteen entities at the widest step,
against `phase4_sort`'s 55,000. It pays for itself many times over: at the
widest zoom sixteen entities become two blits, and the frame rate goes UP,
from 4.75 fps to 6.25.

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
  pre-shift somewhere to land. Eight classes is **45 KB**, which is not one
  bank and never was — it is three, and only fits because banks 5-7 are read
  off the disc rather than carried in `DISC.BIN`. That is now settled rather
  than open; what is still open is what happens when a NINTH thing needs
  space, because there is no fourth spare bank. §14 lists the two answers: 6
  yaw views instead of 8 (−25% each), and tiers shared between classes.
  Adding the second pitch level §5.1 wants would double all of it and is
  currently impossible.
- **Tier A (8×6) barely distinguishes the classes.** Bow-on, a frigate is 6×2
  and an interceptor 4×2. Class identity at that size is carried by bulk, not
  shape, with a 2-pixel margin. Two tests in `test_ships.py` hold the line:
  no two classes may share an 8×6 mask at any yaw, and no class may collapse
  to fewer than six distinct views. Both have caught real models — the Salvage
  Corvette's first fork was vertical, which reads perfectly broadside and is
  byte-for-byte the Mothership head-on.
- **The enemy is all interceptors**, so the §8 balance triangle only ever
  applies to the player's own fleet. `campaign.asm`'s enemy rows are three
  words of position each; a fourth byte for the class would make the Vekhar
  field bombers and frigates, and that is the next thing worth doing to the
  campaign.
- **Two classes have their numbers but not their ROLE.** §8 gives the Salvage
  Corvette "ρυμουλκεί εχθρικά ναυάγια στο Mothership" and the Scout "μεγάλη
  εμβέλεια αισθητήρων". Both are buildable, both cost what §8 says, both have
  art — and both behave like every other ship. Towing needs something to set
  `ENT_F_DISABLED` (the flag exists and nothing writes it), a tow order, and a
  reward for delivering one; the Scout needs the sensor view to be
  range-limited before a longer range can mean anything. Neither is engineering
  the memory arrangement blocks; they are simply not written yet.
