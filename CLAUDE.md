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

418 tests, about **seven minutes**. It doubled when the sprite libraries moved
onto the disc: every `boot_quick` spins the drive up and reads `LIB_SECTORS`
per bank, which is a second and a half of emulated time per machine and there
are about a hundred machines. That is the price of testing the real loader
instead of a poke, and it is worth it -- but do not add a fixture that boots
per test method when a `setUpClass` would do.

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
- **A test that counts lit bytes must count the PLAYFIELD**, not "everything
  above the HUD". There is permanent chrome at both ends of the screen now —
  the context bar is ~330 lit bytes and the HUD another hundred — and counting
  either swamps whatever the test was asking about. `harness.playfield_lit`
  is the one copy; three tests started failing the day the bar arrived and
  every one of them was counting the same 330 bytes on both sides of its own
  comparison.
- **A screen test that only reads the front buffer is half a test.** The
  display page-flips, so anything drawn into one buffer and not the other is
  on screen every *other* frame — which looks like flicker on the machine and
  like nothing at all in `read_ram(front_buffer(c))`. The context bar shipped
  that bug and `tests/test_ctxbar.py` reads `0x8000` and `0xC000` both.
- **`run_to_stable_point`'s budget is in GAME frames, not emulator frames**,
  and the two are ten apart. It was 400,000 microseconds, which sounds
  generous and is *two* game frames — and it is called immediately after
  `boot_quick`, which is exactly when the two heaviest frames the game ever
  runs happen (`mis_wipe` clears 16,000 bytes twice, the HUD repaints into
  both buffers, the context bar and the hull row do the same). So the whole
  budget could be spent inside one `demo_update` without the loop ever
  reaching `scr_wait_vsync`. Adding half a per cent to the frame tipped it
  over and six tests about bank paging and size tiers failed with "never
  caught the frame loop", which says nothing whatever about what was wrong.
  It is `STABLE_POINT_US`, two seconds, and raising it costs nothing because
  the search returns the moment it lands.
- Two `CPC` instances in one process interfere. One emulator per process.
  **`setUp()` called a second time inside a test does NOT close the first
  one** — `tests/test_waves.py` has a `restart()` for that, and without it two
  of its comparison tests were quietly comparing a machine against itself.
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
**1536 bytes of which about 1100 are reachable**, and bank 4 has **307**.
Before six yaw views they were 512 and 9; see "Six yaw views, and where the
space went" for what that bought. The short version is that the low 16K
stopped being desperate and bank 4 is the place most new code should go by
default. The help text, the mission table, the formation shapes, the per-class
data, the cached half of the marker pass, the context bar, the player's
commands and the campaign's setup and teardown all live there.

**Bank 4 is the tight one again.** The context bar spent 595 of its 1032 on
code and words and the magnification another 78 — six bytes a zoom record,
twelve records, plus the LDIR that carries them. The low 16K is still comfortable, and the two are not
interchangeable — see "The one rule" below for what may go where.

The attack waves went the other way and are the exception worth knowing about:
they are **681 bytes of the LOW 16K** and gave bank 4 eight back, because
`title_rand`'s xorshift moved down here to be shared with them. That is
deliberate — see "Attack waves, and the price of staying" — and it is the same
reasoning that kept `game/combat.asm` and `game/economy.asm` out of the bank.

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
| 4 | interceptor + frigate sprites; mission table; help, menu and title CODE; the §9 command code and the campaign's setup/teardown CODE; the cached marker projection; per-class data; formation shapes; the zoom table; the fleet buffer | inside `DISC.BIN` |
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

**The test that decides whether something may go in the bank is narrower than
"does it run while the game is stopped".** It is: *can this ever run between
`class_tier_addr` and `class_blit_done`?* Nothing but `spr_blit` and
`phase4_add_rect` can, so the frame loop's own simulation would be legal
there too. `game/ordercmd.asm`, `game/squadcmd.asm` and `game/campaignrun.asm`
went across on that reasoning; `game/combat.asm` and `game/economy.asm` did
not, and the line is deliberate rather than forced — the low 16K is not
desperate any more, and having the per-frame simulation in one place is worth
more than the bytes. If it gets desperate again, those two are next and they
are safe.

`game/ctxbar.asm` is the newest thing across that line and the clearest case
of the narrow test: it runs **once every frame**, at the very end, and it is
still bank code because nothing pages bank 4 out between `phase4_hud` and the
frame counter. `gfx/markproj.asm` is the other one.

**Code moves for free; data costs a hundred test call sites.** Every one of
the three files above was SPLIT rather than moved: the routines went to the
bank and the equates and variables stayed in the low 16K. Not because the
frame loop cannot read a bank variable — it can, bank 4 is at rest — but
because a variable in the bank has to be read with `read_cpu` rather than
`read_ram`, and `order_paused`, `squad_count`, `disc_active`, `mis_index` and
`moth_slot` are watched by half the suite.

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

**Some characters are not keys.** `?` is SHIFT + `/` and `+` is SHIFT + `;`;
the matrix only ever reports the PHYSICAL key, so `KEY_SLASH` and `KEY_PLUS`
are the unshifted positions and catch the shifted character for free. Check
nothing else wants the unshifted key before taking it.

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
- The interrupt handler saves `AF` and `HL` and touches nothing else itself.
  **Anything it CALLS that wants more registers saves them itself** —
  `snd_update` and `key_scan` both push `BC`/`DE`. That is 42 T-states of the
  ~6,000 the 50 Hz tick spends, and it keeps the contract in one place instead
  of making the handler guess what its callees need.
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
| `proj_point` (one entity, full pipeline) | ~4,853 T | 1,200 T |
| `proj_point` at a magnifying zoom step | ~4,867 T | — |
| `proj_point` (rejected by the distance clip) | ~260 T | — |
| `proj_rotate` (9 multiplies, m01 skipped) | ~2,790 T | — |
| `cam_build_matrix` (once per frame) | ~3,360 T | — |
| `phase4_group` (consolidation off) | ~800 T | — |
| `phase4_group` (16 entities, widest zoom) | ~15,200 T | — |
| paging a class's bank in and bank 4 back | ~30 T per entity | — |
| `wave_health` + `wave_percent` (one reading of the fleet) | ~7,950 T | — |
| `wave_update` (averaged over its four-frame cycle) | ~2,350 T | — |

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
which renders `YAW_STEPS` yaw views per size tier — **six**, 60° apart —
dithers them, and writes a
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
wings must be CANTED or they are seen edge-on from every view, and beam
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

### Six yaw views, and where the space went

§5.1 asks for eight views. §14 lists "6 όψεις yaw αντί για 8" as the
mitigation for "the sprite libraries do not fit", and they did not: eight
classes at eight views is 45 KB across three banks, bank 4 was down to **nine**
spare bytes, and there is no fourth bank in the `#7Fxx` window to reach for.

Six is a quarter off every library — **5760 bytes a class → 4320**, 45 KB →
33.75 KB — and one number in `tools/mkships.py`. What it bought, measured:

| | eight views | six views |
|---|---|---|
| library, per class | 5760 | 4320 |
| bank 4 free | 9 | 1032 |
| low 16K free | 512 | 2304 |
| hand-written code ends at | `#31B3` | `#2A7A` |
| `DISC.BIN` | 25179 | 23951 |
| sectors read at boot | 69 | 51 |

(Those are the figures on the day. The context bar has since spent 595 of the
bank and one page of the low 16K; today's numbers are in "Memory map".)

**The low 16K figure is the point, and it is not a direct consequence.**
Freeing bank 4 does nothing on its own; what it does is make room for code to
LEAVE the low 16K. `game/ordercmd.asm` (the §9 commands), `game/squadcmd.asm`
(the squadron commands) and `game/campaignrun.asm` (mission setup, the
objective check, jumping, the fleet block) are about 1900 bytes that moved
across, and the low 16K went from 512 free to 2304. Freeing a bank is half a
job.

#### Six is not a power of two

`phase4_cache` used to pick a view with `rrca` five times and `and 7`. There is
no shift that divides by six, so it now does

```
view = round(diff * 6 / 256) = (diff * 6 + 128) >> 8
```

three `add hl,*` for the multiply and one for the rounding, plus a `cp 6` for
the single range of inputs (heading ≥ 235) that rounds up to a whole turn.
Hand-counted, that block goes from 121 T-states to 178 — **+57 per visible
entity**, about 1,400 T of a 530,000 T frame, a quarter of one percent.
Measured end to end against a pristine build of the previous commit, the frame
rate is unchanged: the same `4.75, 5.00, 5.00, 5.00, 5.00` five-sample series
on both — which `demo_wait_frame` quantising to whole 50 Hz ticks all but
guarantees for a change this size.

A table was the obvious alternative and is what this change exists to avoid.
256 entries is a page, which is most of what six views just freed. 32 entries
indexed by `diff >> 3` is affordable at 32 bytes and no faster once the index
is built — and it rounds **twice**, so eight of the 256 headings come out one
view away from where the arithmetic puts them.

> **The rounding is a repair, not a translation, and it is the bug this found.**
> Taking the top three bits *truncates*: it gives the pose the ship last
> PASSED, not the nearest one, so every ship in the fleet was drawn up to 45°
> behind its heading and always in the same direction. At six views that
> becomes a whole 60° step — a fleet visibly flying crabwise. `+128` costs four
> bytes and halves the worst case. `tests/test_phase4_fleet.TestViewIndex`
> drives `phase4_cache` over all 256 headings and checks every one against the
> model.

`PHASE4_VIEWS` in `src/demo/phase4.asm` is the Z80's copy of the number and
`src/main.asm` asserts it against the generated `*_frames` equates, per tier,
for all eight classes. Get them out of step and the blitter does not draw the
wrong picture — it steps `view * shifts` blocks off the end of its own tier
into the next one.

#### What six views actually costs, on screen

Looked at, at tier C, one full turn per class, eight against six. It still
reads as a turn: apparent length grows from head-on to oblique and shrinks
back to stern-on, all six silhouettes are different, and the shading swaps
side across the 180° mark so bow and stern are told apart.

**The specific loss is that 90° and 270° are never sampled**, so no ship is
ever seen exactly broadside. That falls unevenly:

- **The Frigate loses most.** Its identity is "a long bar", and its 8-pixel
  broadside at tier A becomes a 7-pixel three-quarter. The Salvage Corvette is
  second, for the same reason — the derrick reads best side-on.
- **The Mothership and Destroyer lose least.** Their identity is bulk, and
  bulk survives any angle.
- The Interceptor is unaffected in kind: it was a chevron head-on and a sliver
  obliquely, and still is.

`tools/mkships.py --contact-sheet` is how to look. The comparison sheets this
was judged on are not checked in — regenerate them by rendering `art/` with
`YAW_STEPS = 8` into a scratch directory and putting the tier C rows side by
side.

### The RU figure is sixteen bits, and was not

`phase4_hud` used to do `ld a,(eco_ru)` into a three-digit field, with a
comment saying RU never goes near 65535. `eco_ru` has always been a word and
every add has always been 16-bit — only the *readout* took the low byte, so
300 RU showed as `044`.

**The assumption was sound when it was written and was invalidated from
somewhere else entirely.** Nothing cost more than 40 until all eight of §8's
classes landed and made the Destroyer buyable at 250 — so a player has to save
past 255 to afford one, and the counter read zero exactly when they got there.

`txt_draw_num4` draws HL in four digits by subtracting powers of ten, most
significant first: 36 subtractions at worst. The 8-bit `txt_draw_num` divides
by ten by repeated subtraction, which is 25 iterations and cheaper than a
table — at 16 bits that would be 6553, which is why the two are different
shapes rather than one general routine. A general one was written first and
cost 250 bytes, nearly all of it right-aligning into a narrower field that
nothing asked for.

`HUD_RU_X` moved 56 → 54 to fit the fourth digit: the squadron list ends at
byte 52 and `?HELP` starts at 70.

**Every economy test passed while this was broken**, because they all assert on
`ECO_RU` — which was correct. `TestTheReadout` reads the pixels instead, and
its sharpest case is that 300 and 44 must not be drawn identically. Against the
old build they are byte-for-byte the same.

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
that demands an action, in the ink §2 reserves for attention. The context bar
follows the same reading: `PAUSED` and `ENTER BUY` in ink 3, the `RU` caption
in ink 2, everything else white.

**A test can read the words back off the screen whichever ink they are in**,
because the three inks are one pixel pattern in three positions: folding a
screen byte's low nibble up with `(b | (b << 4)) & 0xF0` recovers the pen-1
glyph. `tests/test_ctxbar.py` decodes the whole bar that way and compares
against the machine's own font table, so "the bar says NEED MORE RU" is a
statement about pixels rather than about a flag.

> **The comma and the full stop used to differ by ONE PIXEL**, and the bar's
> `, . PICK` therefore read as `. . PICK` -- which says nothing at all about
> which keys walk the build list. The comma now sits a row higher with its
> tail below, and both stay inside rows 0-6 so row 7 is still blank leading.
> Look at a glyph before spending a line of the screen on it.

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

  **Loitering now costs.** Three minutes into a mission the Vekhar start
  arriving in waves, so `J` is a decision rather than a formality — see
  "Attack waves, and the price of staying" for the scaling rule, the measured
  win rate, and the three design decisions behind it.
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
  each a model in `tools/mkships.py` and a 4.22 KB sprite library. Nothing
  wears a stand-in any more except when the disc cannot be read; see the
  banking section for where they live. Capital ships (Mothership, Frigate,
  Destroyer) get a **tier bias** so they draw a size larger than their distance
  alone would give — without it a Mothership at 200 units is exactly as big as
  a fighter at 200 units and the fleet reads as a swarm of identical specks.
- **The reference plane at Y=0, the resource fields and the off-screen
  Mothership indicator all draw through one pass** — see "Markers" below. All
  three are fixed world points, so all three are cached against a hash of the
  camera and cost nothing on the frames it has not moved.
- **The screen has a strip at each end now.** The HUD owns everything below
  line 168 and the **context bar** everything above line 10, and both are
  redrawn only when what they say changes. The bar is what tells the player
  which keys are live, and in the build panel it names the class and its price
  — see "The context bar". **The projection centres on the middle of that
  band, line 89, not on the middle of the screen.**
- **The playfield uses the whole width now.** It used to be arithmetically
  incapable of it: at the five widest zoom steps no point of the visible world
  could project further than 79 pixels off centre, of a half-width of 160. See
  "Using the width of the screen", which is also where the eleven lines above
  come from.

`src/demo/phase4.asm` is the acceptance test running on the CPC itself.

**A ninth class fits now, and so do a tenth and an eleventh.** It did not
before: bank 4 had nine bytes left, and banks 5-7 held two 5760-byte libraries
each with `LIB_SECTORS` sizing their disc image at exactly that. Six yaw views
made a library 4320 bytes, so **three** of them are 12960 — inside the 16 KB
window, and 26 sectors against the 27 that `LIB_TRACKS_PER_BANK` already
reserves. Nine libraries across banks 5-7 without asking the 6128 for a bank
it does not have.

`LIB_SECTORS` is 17 today, which is what two libraries need; a third per bank
takes it to 26. Adding a class is the Makefile's `SHIP_CLASSES`, an `include`
in the right `BANK` section of `src/main.asm`, a row in
`class_sprite`/`class_bank`, and an entry in every table in
`game/classdata.asm`. §14's other mitigation, tiers shared between classes, is
not needed and should stay unspent.

### Controls

| Key | Effect |
|---|---|
| `1`-`9` | select a squadron (see below) |
| `0` | centre on the Mothership, clearing any pan |
| cursor keys | orbit the camera; drive the move disc while it is open |
| `Z` / `X` or `+` / `-` | zoom in / out, **twelve** steps |
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

**The context bar at the top of the screen names whichever of these are live
right now** — see its own section. That is where a player is meant to find
out that `,` and `.` have changed meaning, rather than from this table.

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

#### A squadron is born where its ships are

`squad_dest` — where a squadron is stationed, and the only thing a move order
changes — used to be nine FIXED points, copied out of `order_home` once at
boot and fanned out up to 6000 units apart. **Only row 1 was ever near the
fleet**, because `phase4_spawn_fleet` puts the whole fleet on squadron 1's
station. So the instant `d`, `m`, `n` or `O` put a ship into any other number,
`phase4_fly` began dragging it towards a point it had never been sent to.
Divide a formation and half of it turned and flew off the screen.

The player reported it as **"selecting squadrons mixes them up"** and narrowed
it to after the reshaping commands, which is exactly right and is the whole
diagnosis: those are the only things that put a ship into a number that has
never been given an order. Plain `1`-`9` moves no ship, so it cannot trigger
it; `O` can and does, and looked innocent only because the starting fleet is
all interceptors and therefore all still squadron 1.

The rule now, and it is the same shape as `squad_count` being derived rather
than maintained:

> **An empty squadron has no station.** It acquires one by being made — from
> the ship that made it — and its formation from the squadron that ship left.

`squad_born` in `game/squadcmd.asm` is the whole of it, 61 bytes of bank 4, on
the one path every reassignment goes through (`squad_move_ship`) plus the one
that does not (`squad_by_class`, which writes `ENT_SQUAD` itself). The guard
is `squad_count`, which still holds the value it had before the command
started — nothing calls `squad_refresh` until the command has finished — so a
divide that peels seven ships runs it seven times and the last one wins. All
seven were inside the parent's formation, so any of them will do.

Three things worth knowing:

- **`B` and `C` have to survive it.** `squad_split` and `squad_combine` both
  loop on `squad_move_ship` with the two squadron numbers in `BC`, so the
  `LDIR` that copies the six bytes of station has to sit inside a `push bc`.
  Without it a divide moves one ship and stops.
- **`game/formation.asm` had claimed the formation was inherited since the day
  it was written** — "Splitting a squadron gives the new half the same shape,
  which is what you would expect of ships peeling off in formation" — and
  nothing implemented it. `form_init` set all nine to Loose and `form_cycle`
  was the only thing that ever wrote one. A comment is not a test.
- **`order_home`'s other eight rows are now only the layout a RESTORED fleet
  fans out into.** `order_init` runs once, from `demo_init`, so `squad_dest`
  survives a jump and a squadron carried between missions keeps the station it
  was given. They are 48 bytes of the low 16K and they can go the day a
  restored fleet is given something better; they are not the bug.

**Every squadron test asserted on `SQUAD_COUNT`, and that is why this lived so
long.** A count is preserved by a swap that puts the wrong ships in the wrong
squadrons, and it is preserved *absolutely* by a station that is wrong — the
entire defect is invisible to a test that counts. There are two nets now.
`TestWhichShipsEndUpWhere` follows individual ships **by slot** across each
command and says what each command is allowed to touch; it passed before the
fix as well as after, which is the point — the membership arithmetic was never
what was broken, and now there is something saying so. `TestANewSquadronIsBornWhereItsShipsAre`
reads `squad_dest`, then lets the fleet fly and measures how far apart it ends
up. Against HEAD all six of its cases fail by 2× to 4×: a divided squadron
stationed 5950 units from the nearest of its own ships, and a fleet that goes
from 3300 units across to **19000** after one keypress.

**`tools/balance.py` is unaffected and has to be**: the script holds station
and presses `A`, and never presses `d`, `m`, `n`, `c` or `O` — so the fleet is
one squadron from the first frame to the last and `squad_born` never runs in
it. It prints the same campaign as the two entries above, losing the
Mothership at mission 7. Nothing in the frame loop changed; this is a keypress
path.

**And one test was leaning on the bug.** `test_all_three_size_tiers_get_used`
pressed `dd` and relied on the resulting squadrons sitting at genuinely
different depths — which they did, because `order_home` scattered them. It
writes the two stations it wants now. A test that gets its preconditions from
a defect passes for the wrong reason and fails the day the defect goes, which
is what it did.

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
with; it is currently 24889, ending just under `#A0E9`, and that is **about
1.5 KB of headroom**. One RLE-packed library is 2-3 KB. That arithmetic is the
whole reason six of the eight classes are read off the disc into banks 5-7
instead of travelling in the file — it is not a stylistic choice, and no amount
of better packing gets 34 KB of sprites under a 1.5 KB gap.

**Watch this figure, not just the bank's.** It is the second ceiling on bank 4
and it moves with it: every byte added to the bank-4 image costs `DISC.BIN`
whatever it packs down to. The context bar's 595 bytes cost the file 861,
because code does not compress.

The bank-4 image stays RLE-compressed (`tools/packsprites.py`, 15000 → 10793
bytes); without it the file would not fit at all. It packs worse than it used
to — 72% rather than 62% — because most of what six yaw views freed there was
promptly filled with CODE, and code does not have runs of `#FF,#00` in it. Uninitialised bank data (the
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

### Attack waves, and the price of staying

Stay in a mission more than three minutes and the Vekhar start arriving, in
waves of random size at random spacing, and they never stop. `src/game/waves.asm`,
in the **low 16K** with the rest of the frame loop's simulation.

**It exists because nothing made staying cost anything.** §10's campaign is
about a fleet that only ever shrinks and §1 says the same in prose — what is
lost is lost — but once the picket was dead a mission was a room with the
lights on: mine the fields dry, build what the RU will buy, jump when you feel
like it. `J` was a formality rather than a decision.

#### The scaling rule, and why it is HULL

> **A wave is a fraction of the hull the player still has: a sixteenth to a
> quarter of it, plus one, rounded.**

The requirement is not "waves are hard", it is **"at least a 70% chance of
winning"** — and that has to hold for a fleet that has already lost half of
itself by mission 7. So the wave cannot be an absolute number.

Of the things that could stand for "what the player still has", hull is the
honest one and headcount is not. Headcount says a fleet of fifteen ships at
twenty hull each is as strong as fifteen fresh ones; it is not, it dies to the
first volley. **Summed `ENT_HULL` falls when a ship is lost AND when a ship is
hurt**, which are exactly the two ways a fleet becomes less able to take a
wave, and it needs no second table — it is one byte per entity that is already
there. Divided by 256 it reads directly as "ships' worth of fleet left",
because an interceptor's hull is 255. The readout on the screen is the same
number, so the player can see what they are being measured by.

What it does not capture is the balance triangle: a harvester counts nearly as
much as an interceptor and shoots for 4 rather than 24. That is a real
approximation, it errs towards a wave too big for a fleet of harvesters, and no
script or sane player fields one. `tools/waverate.py` is what says whether the
approximation holds — it is measured, not argued.

**The rounding is not tidiness.** A plain `>>4` gives a small fleet the same
answer whatever it rolls: half a fleet is three ships' worth, three times four
is twelve, and twelve shifted down four is zero for every multiplier there is.
So the late campaign — the whole reason the wave is scaled at all — would get a
wave of exactly one ship every time and the randomness would quietly stop
existing at the end where it matters most. `+8` before the shift costs one
`add hl,de`. Same shape as `phase4_cache`'s view index.

#### The measured win rate

`tools/waverate.py`. It reaches each mission with `balance.py`'s tactic and no
loitering, **photographs the entity table**, loiters through three waves, and
puts the photograph back before jumping — so mission 6's number means "loiter
in mission 6 with the fleet you would actually have there", not "with whatever
five previous loiters left". Each mission is then run twice: once with the
fleet it has, and once **crippled to half the ships at half hull**, which is
the mission-7 condition arranged rather than played into.

WIN means: after three waves the Mothership is alive *and* the objective is met,
so the player can actually press `J`. LOSS is `mis_failed`, which in this game
is one thing — the Mothership gone and sixty thousand sleepers with it. §8
makes that the end of the campaign, so it is the floor and nothing softer is
worth measuring.

Eight campaigns, ninety-six mission trials, `python3 tools/waverate.py 8`:

```
mis       whole fleet      half a fleet
  1       8/8    100%       7/8     88%
  2       8/8    100%       7/8     88%
  3       8/8    100%       8/8    100%
  4       8/8    100%       7/8     88%
  5       8/8    100%       8/8    100%
  6       8/8    100%       7/8     88%
     whole: 48/48 = 100%
    halved: 44/48 = 92%
     all: 92/96 = 96%   -- the floor is 70%
```

**Missions 7 and 8 have no samples and that is not the waves.** The picket at
THE GATE takes the Mothership before any wave lands, in this build and in the
one before it, for the frame-boundary reasons the balance section documents and
tells you not to tune. That is exactly what the "half a fleet" column is for:
it arranges the mission-7 condition — half the ships at half hull — instead of
playing into it, and it is the only column where the waves ever win.

**The margin is the point, not the number.** 96% is not "too easy": three waves
still cost a whole fleet 10-15% of its hull, permanently, and hull never comes
back. Loiter in EVERY mission and the campaign dies around mission 5 — measured,
and printed by the tool's own header. What the margin buys is that a rate
measured over ninety-six trials at 96% is a rate you can believe is above 70%;
one measured at 71% is not.

**The first configuration measured 71% and was thrown away.** It was an eighth
to a half of the fleet rather than a sixteenth to a quarter, and 71% over
thirty trials is the floor with no margin — indistinguishable from a
configuration that is actually below it. Every loss had the same shape and it
is worth knowing: a wave arrives on the Mothership, every ship in it picks the
nearest target — which is the Mothership, because that is what the fleet is
stationed on — and seven interceptors take 255 hull off at ten a hit faster
than fifteen of ours can kill seven of theirs. **That is the concentration
argument in "A fleet has to be able to concentrate", running the other way.**

#### The bug the measurement found, which is not in this feature at all

The first campaign-length run died at **mission 5 in six runs out of six**, at
full hull, with no wave on the screen. It was not the waves.

> **An `ENT_ORDER_ATTACK` ship is skipped by `phase4_fly` — deliberately, so
> `cbt_move_enemies` can close it on its target without the two systems
> cancelling — and NOTHING clears the order when the target dies.**

So a fleet that has just killed a wave six thousand units out stays there,
permanently, and `fleet_save` carries those coordinates into the next mission.
Loiter through three waves in mission 4 and the fleet begins mission 5 scattered
around wherever the last wave happened to arrive, with the Mothership alone at
the origin and THE NEBULA's eight hostiles spawning on top of it.

This is pre-existing and the waves only exposed it: any fight leaves the fleet
displaced. `G` is what a player presses to disengage and it puts the ships back
under formation flight, so `waverate.py` presses it — but a player who does not
know that is one mission from losing the game. It is the next thing worth
fixing in `game/combat.asm` and it is deliberately not fixed here.

#### The clock, converted honestly

`mis_timer` counts **game frames**, and the game measures 5.0 fps against
§2's 12.5 target. So three minutes is `180 * 5.0 = 900` game frames, one minute
is 300 and four is 1200, and the spacing is `300 + 3.5 * a random byte` which
reaches 1192. Three and a half is two adds and a shift; `900/256` exactly would
be a multiply for a quarter of a frame's difference.

It is honest to a few per cent and no better — the frame rate falls as the
entity count rises, so three minutes with a wave already on screen is nearer
three and a half. Making it exact means a second counter on `sys_tick_50hz`,
and `mis_timer` is already a word that already resets in exactly the right
place: **`mis_setup` zeroes it, so the three minutes are per mission by
construction**, and `demo_update` skips `mis_update` while `order_paused`, so
SPACE stops the clock along with the battle.

#### Three decisions, written down

- **A wave does not count towards the objective.** `ENT_F_WAVE` is a fourth
  flag bit and `mis_count_enemies` folds it into its mask, which costs nothing:
  a wave ship's flags no longer equal `ACTIVE+ENEMY` so the compare rejects it.
  Count them and a CLEAR mission becomes uncompletable the moment the first
  wave lands, `J` is never offered, and "loitering costs you" becomes
  "loitering traps you" — the opposite of the point.
- **Waves keep coming after the objective is met.** They are the reason to
  jump. `mis_update` returns early once `mis_complete` is set, which is why
  `wave_update` is called from `demo_update` beside it rather than from inside
  it.
- **They arrive from ONE bearing, on a shell around the Mothership.** Around
  the Mothership because that is the thing that must not be lost and a wave
  that always arrived where the camera was pointing would be a different
  mechanic; one bearing because ships appearing all round at once reads as
  nothing, and an attack from a direction is something the player can turn to
  face. Each ship is jittered inside 45° of it, and `ENT_YAW` is set to face
  inward — nothing requires that (the mission table's own hostiles inherit
  whatever yaw the slot last held) but a wave pointing outward reads as debris.

#### `tools/balance.py` is unaffected, and here is the proof

Its missions **peak at 44 game frames of the 900** — the script jumps the
moment it is allowed to, so no wave has ever fired in it and `WAVE_COUNT` is 0
at the end of a whole campaign. Any difference in its output is the frame
boundary moving, which CLAUDE.md already tells you not to tune for. It still
ends at mission 7 with the Mothership lost, exactly as it did before this
landed:

```
mis enemy  in out lost   hull  fleet
  4     8  16  16    0   3408  int=15 moth=1
  6     6  16  15    1   2755  int=14 moth=1
  7    12  15  11    4   2325  int=11  FAILED -- the Mothership was lost
```

#### Randomness, and how a test pins it

`src/sys/rand.asm`. A 16-bit xorshift — the same eight instructions the title
screen's starfield already used, which is why the **step** lives there now and
is shared. The **state** is not, and must not be: `title_draw_stars` reseeds to
a constant at the top of every frame so the field does not twinkle, and a wave
generator that restarted like that would send the same wave in every mission of
every campaign.

`sys_rng` starts at a fixed constant and the **first keypress of the run** stirs
`sys_tick_50hz` into it. That counter free-runs at 50 Hz and wraps every 5.12
seconds, so the moment a human presses a key is worth most of eight bits for
the cost of a load, and `key_consume` is the one place that already knows a key
went down.

**It happens once and never again, and that is what makes the suite
deterministic** rather than merely repeatable. Every `boot_quick` presses SPACE
past the title and ENTER past the briefing, so the stir is already spent by the
time a test is handed the machine — and a test that then writes `SYS_RNG` owns
the sequence for the rest of the run. `harness.pin_rng` is that write and
`tests/test_waves.TestTheGenerator` checks the "never again" part directly,
because everything else in that file rests on it.

### The fleet's hull, on the screen

`HULL nnn%` at `HUD_ROW_C_Y`, a **third HUD row**, in ink 2 for the caption and
ink 1 for the figure — ink 3 below `HUD_HP_ALARM` (33%), which is §2's ink for
the thing that wants attention and is the moment "one more wave or jump now"
changes its answer.

**Where it went was the decision, and the room was already there.** §5.5
budgets a 32-pixel strip and the two rows of squadron counts sit at 178 and
188, so **lines 168–177 have been part of the HUD and black since the strip was
drawn**. Neither existing row had four characters to spare: row A runs
squadrons to byte 51, RU to 67 and `?HELP` to 79, and row B runs squadrons to
41, the yard to 51 and `M n JUMP` to 71. The context bar was the other
candidate and was rejected — it says what the KEYS do, and a hull figure is not
a key. §5.5 had already asked for two of the things this row now carries: a
"μπάρα ενέργειας Mothership", generalised from the Mothership to the fleet
because a number is smaller than a bar and says more, and a "γραμμή μηνυμάτων",
which today carries one message: `INCOMING`.

168 and not 169, which is what it was first. The strip's three rows want the
same gap or they read as two blocks rather than three lines; at 169 the gap to
row A is two scanlines and A to B is three. At 168 all three are three, and the
cost is glyphs sitting hard against the playfield's last line — which is the
line a sprite is already clipped in half on.

**It keeps its own dirty flag**, and that is the point rather than tidiness.
The percentage moves every time a shot lands; flagging `phase4_hud_dirty` would
repaint the whole strip — ~90,000 T-states, twice, once per buffer — several
times a second in a battle and undo the entire bargain that makes the HUD
affordable. This is nine characters. `phase4_hud` sets `wave_dirty` when it
repaints, because a `mis_wipe` clears all 200 lines including this row and
nothing else would put it back.

#### The only division in the game

`pct = 100 * hull / full`, where `full` is what the same ships would have
undamaged, summed out of `class_hull`. There is no general divide in this
project and there should not be — `txt_draw_num` divides by ten by repeated
subtraction and `txt_draw_num4` subtracts powers of ten, because in both cases
the divisor is a constant. Here it is whatever fleet the player has, so:

- eight steps of a **restoring divide** give `C = floor(256 * hull / full)`.
  Both operands stay inside sixteen bits by construction — HL is left below DE
  at the top of every step and DE is at most `ENT_MAX * 255` = 12240, so the
  doubling cannot run out of register;
- then `(C * 100) >> 8` is one `mul_u8` and taking `H`.

**It is measured against the current roster, not the mission's starting one**,
and the consequence is worth stating: killing off a badly damaged ship raises
the percentage. That is the honest reading of the question it answers — *how
battered is the fleet I still have* — and the squadron counts beside it answer
*how much fleet is there*. One number cannot answer both without lying about
one of them.

#### It cost 0.9% of the frame and now costs 0.4%

The first version walked the entity table **every frame** and reloaded the
record base out of memory four times a slot: 174 T-states on an EMPTY slot, and
there are usually thirty of those. Measured end to end, **5.00 fps became 4.85
over two thousand frames** — a real regression, not the tick-boundary
quantisation this file warns about elsewhere, and `test_frame_rate_does_not_regress`
caught it. Two changes:

- **The pointer walks the `ENT_FLAGS` byte, not the record.** Starting at
  `entities + ENT_FLAGS` and stepping by `ENT_SIZE` makes the common case
  `ld a,(hl)` and a compare — 57 T — and `ENT_HULL` and `ENT_CLASS` are the two
  bytes immediately *before* the flags, so a live slot reaches them with two
  `DEC`s and no arithmetic at all. That adjacency is §7's record layout being
  convenient rather than designed, so `src/main.asm` asserts it: move
  `ENT_CLASS` and the fleet's hull is silently summed out of `ENT_SPEED`.
- **One reading in four** (`WAVE_READ_EVERY`). Nothing is lost: at five game
  frames a second a figure that moves five times a second and one that moves
  once are the same figure to a human eye, and `wave_send` takes its own
  reading at the moment it sizes a wave, so the number the scaling uses is
  never stale by even one frame. Every fourth frame rather than "when something
  changed", deliberately — the things that move the fleet's hull are combat, a
  death, a ship being BUILT and a mission being set up, and a trigger that had
  to list all four would be wrong the first time a fifth was added.

Measured after: **7,953 T for a reading, 2,353 T averaged over the cycle**, and
5.000 / 4.950 / 4.975 fps over 400 / 1000 / 2000 frames — the same 5.0 the
build had before. `tests/test_waves.TestWhatItCosts` holds that line with
test_sound's loop-and-count technique.

### The keyboard is scanned from the interrupt, and why it has to be

`key_scan` runs at **50 Hz from the IM 1 handler**, not once per game frame.

It used to run from the main loop, which meant one scan per *game* frame — and
the game runs at about 5 fps, so the keyboard was sampled every 200 ms. A key
that went down *and* up between two scans was never seen at all. Measured, by
holding SPACE (which toggles `order_paused`, so one press is one visible
change) for a fixed time, six trials each:

| held | before | after |
|---|---|---|
| 20 ms | — | 6/6 |
| 40 ms | 2/6 | 6/6 |
| 80 ms | 4/6 | 6/6 |
| 120 ms | 6/6 | 6/6 |

A normal quick keypress is 50–100 ms, so **roughly half of them vanished.**

**No test caught it, and every test agreed with the bug**: they all hold their
key for 25 or more emulator frames, which is a half-second press. A keyboard
test that does not press *briefly* is not testing the keyboard. There is one
now.

`key_edge` therefore means "accumulated since the main loop last consumed it"
rather than "went down at the last scan", and something has to clear it at the
right moment — a key held across frames must still act once, because every
command in the game is edge-triggered and `d` dividing a squadron once a frame
would be a disaster.

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
instructions folded in. A second copy of every sprite library would be 4.2 KB
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
   `ordercmd.asm` and read only by `cbt_retarget_one`, to stop the AI overwriting
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

**And it happened again, exactly as predicted, so here is the whole
experiment.** The context bar costs ~2,500 T-states a frame and the campaign
now ends at mission **7** rather than 8 — the Mothership is lost there instead
of surviving with four ships. Three runs of `tools/balance.py`, same day, same
machine:

| build | mis 1-6 lost | mission 7 | mission 8 |
|---|---|---|---|
| HEAD | 1 | 7 lost, survives | fleet lost |
| HEAD + 520 T of `djnz` and nothing else | 1 | 9 lost, survives | fleet lost |
| HEAD + the context bar | 2 | **Mothership lost** | — |

520 T-states of pure delay moves mission 7 from seven ships to nine. The bar's
2,500 pushes it past the edge. **Nothing about the balance changed** — no
number in `classdata.asm` or `campaign.asm` moved — and the middle row is the
proof. Do not tune anything in response to this; if the campaign is to reach
mission 8 again it is because the frame got faster, not because a hull got
bigger.

**And the frame did get faster, by about the same 2,500 T, and mission 8 did
NOT come back.** Inlining `qsq_f` and folding `proj_point`'s two per-axis calls
into one is ~100 T an entity — see "It came out CHEAPER" — and against that
build `tools/balance.py` prints the campaign line for line identically, losing
the Mothership at mission 7 with the same hulls at every mission before it. So
a T-state is not a currency you can spend back: `demo_wait_frame` quantises to
whole 50 Hz ticks, the game runs at 5.00 fps either side, and it is which side
of a tick boundary a *particular* frame lands on that decides the fight. The
row above is still the right way to read this — it just does not run backwards.

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
`tools/gentables.py` is the table; it states only `(dist, shift, mul3, mag)`
and derives everything else. The fourth column is the magnification, and it is
a different mechanism entirely — see "Using the width of the screen".

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
`cam_zoom_table` — five now, the fifth being `proj_mag`. Measured when it
landed: **4,960 T**, up 200 from 4,760.

Two things that bound the ends of the ladder:

- **The innermost step is `>>4`, a radius of 2048 world units.** `FORM_SPACING`
  is 550, so a squadron fills the screen. Going further in is possible and is
  not useful.
- **The widest step is `>>8`, a radius of 32768 — the whole 16-bit world.**
  There is deliberately no step past it: `DISC_LIMIT` is 30000 and the
  subtract overflows past 32767 anyway, so a thirteenth step would show more
  empty space and nothing else.

**What this did NOT fix was the wasted screen**, and that is now its own
section below — the magnification stage this paragraph said the low 16K had no
room for turned out to be six patched bytes. What is still true, and is why
that was the shape it took, is that **dropping `cam_dist` for the wide steps
is not the answer**: `cam_dist` IS the size tier, and ships would jump a size
larger at the very step where there are most of them.

The differential test in `test_phase1` runs the model against the metal at
**all twelve steps**, not just the neutral one. It has to: the plain steps and
the ×3 steps reject on different tests — a bound on the high byte against a
check on the scaled value — and either edge off by one puts a ship somewhere
it is not.

### Using the width of the screen

The outer half of the screen was not empty, it was **unreachable**, and that
is the difference between a content problem and an arithmetic one.

`PROJ_K` is `160 << PROJ_SHIFT`, chosen so that `x == z` — 45° off axis —
lands exactly on the screen edge. Nothing in this game ever gets near 45° off
axis once `cam_dist` is long, because what can be seen at all is a ±127 camera
cube and `cam_dist` pushes that cube away from the eye. Measured, as the
largest `|sx - 160|` any point of the cube can produce over every yaw and
pitch:

| `cam_dist` | 110 | 150 | 200 | 250 |
|---|---|---|---|---|
| reach, of a half-width of 160 | 172 | 170 | 107 | **79** |

At 250 — steps 7 to 11, **five of the twelve** — the picture was confined to
the middle half of the screen by construction. No amount of flying about could
have put a ship in the outer half.

`proj_mag` multiplies the projected offset **after the perspective divide and
before the centre is added**, by 1, 1.5 or 2 depending on the step, which
brings all four reaches to 158-172. That is the whole change.

**It is not zoom and the distinction is worth holding on to.** `proj_deltas`'
clip radius is untouched, so the same world is visible; `proj_z` is untouched,
so every ship's size tier is exactly what it was. The screenshots at step 7
before and after show the reference lattice at twice the spread with the same
sprites drawn on it.

**Vertically the same factor, because the projection has to stay isotropic.**
An anisotropic one would fill the width perfectly and change a formation's
shape as the camera orbited. The playfield is 158 lines against 320 columns,
so filling the width overfills the height twice over — which costs very little
here because the content is essentially planar: §4.1's reference plane, the
formations and the resource fields all sit near Y=0.

#### The eleven lines the projection was low

The other half of the job, and it was free. `sy = 100 - offset` centred the
picture on the middle of the **screen** while the band a ship may be drawn in
is `CTX_BAR_H`..`HUD_TOP`, 10..167, whose middle is **89**. So everything was
eleven lines low and closer to the HUD than to the bar. `PROJ_CENTRE_Y` is 89
now, and `src/main.asm` asserts it against `(CTX_BAR_H + HUD_TOP) / 2` and
against the model's own copy, because all three are literals.

`MOTH_CENTRE_Y` was stale in the same way and by the same amount — a literal
84, the middle of 0..168, which is what the tactical view was before the
context bar took the top ten lines. It is `PROJ_CENTRE_Y` now: the off-screen
Mothership marker says which way to turn from the middle of the view, so a box
centred anywhere else points a few degrees off everything else on screen.

#### Six patched bytes, and why it is the same shape as `proj_scale`

`proj_mag` sits in `proj_offset` and is **six bytes of instruction stream**,
LDIR'd in by `order_apply_zoom` as a fifth run out of the same zoom record:

```
    ld d,h : ld e,l          ; DE = t, always
    sra d  : rr e            ; or four NOPs
    add hl,hl                ; or NOP
    add hl,de                ; or NOP
```

which is `HL = (t << j) + (t >> k)` and reaches 1, 1.5, 2, 2.5 and 3. No
branch, for the reason `proj_scale` has none: a `JR` to skip the ×1 case costs
more than the two NOPs it skips. `ZOOM_MAG_FORMS` in `tools/gentables.py` is
the mapping and the record went from 14 bytes to 20.

**Powers of two alone are too coarse and finding that out is most of the
design.** `cam_dist` steps 110 → 150 → 200 → 250, ratios of about 1.3, so a
ladder of 1, 2, 4 cannot follow it: whichever way you round, one step spreads
the picture out as you zoom *out*. 1.5 is what makes the sequence read as a
zoom, and `sra d : rr e` is what makes 1.5 affordable.

#### It came out CHEAPER, and that is where it was paid for

`proj_point` is **4,853 T-states at the default step and 4,867 T at a
magnifying one, against 4,960 before** — the guard is 5,000 and had forty
T-states of headroom. Two things paid for the magnification and then some:

- **`qsq_f` is gone**, inlined into its only caller. It was an eleven-byte
  routine reached by `CALL`/`RET` twice per `mul_u8`, which is 54 T of pure
  overhead per multiply; `proj_point` runs two and `cam_build_matrix` nine. The
  second copy also loses the `jr nc`, because the second index is eight bits by
  construction. Net cost: **one byte**.
- **`proj_offset`** is one routine per axis instead of two. `proj_point` used
  to `call mul_s8u8` and then `call proj_shr7`; folding the pair into one call
  with the shift written out gives back another 27 T an axis. `proj_shr7`
  stays, because `gfx/markproj.asm` still calls it — and note that it must NOT
  contain the magnify slot: `moth_scale` uses it to place a border marker and
  would be magnified twice.

Measured at 24 entities that is ~2,500 T a frame back, which is almost exactly
what the context bar cost. It is **not** enough to move a `demo_wait_frame`
tick boundary: the frame rate is 5.00 fps over 1000 frames before and after,
and `tools/balance.py` prints the same campaign line for line, mission 7 and
all. Mission 8 did not come back and nothing was tuned to try.

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
the window at rest; it is one of the two pieces of bank code reached from
inside the frame loop — `game/ctxbar.asm` is the other — and the rule neither
may break is the one in `game/shipclass.asm`.

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
| `title_rand` | ~8 of bank 4 | ...and then the attack waves needed the same eight instructions with the opposite habit. `sys_rand_step` takes the word in HL and hands it back, so the STEP is shared and the STATE is not — which is the whole distinction, and sharing the state would have made every campaign send the same waves |
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

That was the ceiling for a long time and the hand-written code sat at `#31B3`,
four bytes under it. It is `#2B04` now — see "Six yaw views, and where the
space went" — so there are six whole pages of room before that edge is
anywhere near again. The table above is still the list of shapes to look for
when it is.

**And the 256-byte step is real, so budget for it.** The context bar's top
clip added 70 bytes to the low 16K and cost a whole page: `free:` went from
2304 to 2048 for 70 bytes of `spr_blit` and `mark_store`. Measure `CODE_END`,
not `free:`, and expect the bill in units of 256.

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

Three rows now, not two: `HUD_ROW_C_Y` at 168 carries the fleet's hull
percentage and `INCOMING`, in ten lines of the strip that had been black since
the day it was drawn. See "The fleet's hull, on the screen".

Owns the strip below `HUD_TOP` (line 168). `spr_clip_bottom` keeps the
tactical view out of it, which is what lets the HUD be redrawn only when it
changes rather than every frame — worth ~90,000 T. `phase4_hud_changed`
compares the counts against a shadow copy rather than having each command
remember to flag itself, because ships dying will change the counts with
nobody pressing anything.

### The context bar

One line across the top of the screen saying what the keys do **right now**.
It is the mirror of the HUD in every respect — it owns a strip, ships are
clipped out of it, and it is repainted only when what it says changes.

`src/game/ctxbar.asm`, in bank 4. `CTX_BAR_H` is 10 and the text sits at
`CTX_Y` 1, so the playfield is lines 10..167 rather than 0..167 — which moves
the middle of the visible band from y=84 to y=89 and therefore *closer* to the
y=100 the projection centres on, not further from it.

| context | what it says |
|---|---|
| playing | `ESC MENU  ENTER MOVE  B BUILD  , . TARGET` |
| `order_paused` | `PAUSED` in ink 3, then `SPACE RESUME   ESC MENU` |
| `disc_active` | `ARROWS MOVE  SHIFT UP/DN  ENTER OK  ESC` |
| `eco_build_open` | the class by NAME, its cost in RU, `, . PICK`, and whether ENTER will work |
| title, briefing, help, orders menu | nothing: suppressed |

**It exists because of a specific failure.** A player who had been told the
build panel is `B`, then `,`/`.`, then ENTER, asked **twice** how to choose
what to build. The yard's whole readout was `>SCT` in the corner of the bottom
strip: no name, no price, and nothing to say `,` and `.` were live at all —
and those two keys mean "step the target" with the panel shut and "step the
price list" with it open, with no way to see which. So the build context is
the one the layout is built around, and it is the only one with fields rather
than a single string.

**Why `PAUSED` is here and not in the bottom strip.** It is the same idea —
the game telling the player what state it is in — and a word in the HUD would
only have had to move up here two days later. Ink 3, because §2 reserves it
for the thing that wants attention and a paused fleet does not look paused, it
looks broken: it simply stops obeying.

**The build panel's three refusals are eco_queue's own, re-derived.**
`ctx_build_state` walks the same checks in the same order — yard busy first,
then the cost — because `eco_queue` does not leave a flag to read and a bar
that says `ENTER BUY` to a yard that says no is worse than no bar.
`ENTER BUY` is ink 3, like `JUMP`: the one key on screen asking to be pressed.
The refusals stay white, because they are an answer rather than an alarm.

#### The full-screen pages are suppressed, and that is a decision

The title, the briefing, the help page and the orders menu each own the whole
screen and each already draws its own prompt — `PRESS SPACE TO START`,
`ENTER`, `ESC - BACK`, `UP/DOWN  ENTER  ESC` under the list it belongs to. Two
prompts for one screen is one of them being wrong the first time the other
changes.

It also costs nothing to implement: every one of those pages clears from line
0, so putting the page up IS taking the bar down, and coming back is a context
change like any other.

> **The bug that came out of that, and it is the one worth reading.** A page
> closes by clearing its own flag inside its `_key` routine, and `demo_update`
> then draws the page **one more time in the same frame**. So on that frame
> the context already said "playing" while the screen still held the briefing.
> The bar got painted there, into whichever buffer that frame owned — and the
> two frames of `mis_wipe` that follow then cleared it out of the *other* one,
> with `ctx_dirty` already spent. Front buffer only, it looked perfect; the
> display page-flips, so on the machine the bar was there every **other**
> frame for the rest of the mission. `@p4_static_done` therefore calls
> `ctx_changed` and not `ctx_bar`: notice the change, leave the paint to the
> first genuinely playing frame, which is after both wipes.
>
> `tests/test_ctxbar.TestTheFullScreenPages` reads BOTH buffers. A screen test
> that only looks at the front one cannot see this class of bug at all.

#### `spr_clip_top`

The mirror of `spr_clip_bottom`, in `gfx/sprite.asm`, and it had to be
threaded through **three** places, not one:

- `spr_blit`'s vertical clip. The old code treated "y is negative" as the skip
  case; it now computes `clip_top - y` and skips that many rows, which is the
  same arithmetic with `clip_top` of 0.
- `gfx_vline`, which every marker, the move disc and the sensor view draw
  through.
- **`mark_store`, and this is the one that is easy to miss.** `gfx_vline`
  clips what is DRAWN, but `mark_bar`/`mark_cross`/`mark_patch` work their
  dirty rectangle out from the *unclipped* position — so a marker half off the
  top recorded a rectangle reaching into the bar, and next frame's
  `phase4_erase` scrubbed a row out of it. Nothing would ever repair that: the
  bar comes back only when the context changes.

  **The same was quietly true at the bottom and had been all along.** A
  lattice dot at y=190 was taking a bite out of the HUD, which does not clear
  its strip but draws labels onto it, so the erased pixels stayed erased.
  Clamping in `mark_store` fixes both, once, for every marker there is.

`spr_clip_top` and `spr_clip_bottom` **must both stay in the low 16K** —
`spr_blit` is the only thing that runs with a foreign bank under the window
and it reads both on every sprite. `src/main.asm` asserts that, and also that
they are ADJACENT, because `mark_store` and `gfx_vline` read the second with
an `INC HL`.

`title_draw_ships` opens both ends to the whole screen and closes both again
itself, for the reason the title section explains.

#### Hoisting the clip out of `gfx_vline` is a pessimisation

Written first, and reverted. Clipping the run once and dropping the test from
the row loop costs ~100 T-states either way, and **almost everything drawn
through `gfx_vline` is one row**: the reference plane is sixteen single-pixel
dots and a resource patch is three more. Break-even is three rows and only the
move disc's stem is ever long. The per-row version with an `INC HL` for the
second bound is ~20 T a row and wins outright.

#### What it costs, and the tick boundary it landed on

About 2,500 T-states a frame — 0.4% — nearly all of it the two extra bounds
tests in `spr_blit`, `gfx_vline` and `mark_store`. The bar's own `ctx_changed`
is a handful of byte compares and its paint happens twice per context change.

That 0.4% moved the frame-rate test from 5.00 to 4.75 fps, which is the
quantisation trap this file already documents in "Six loops walked all 48
slots". Measured over 1000 frames instead of 200 the two builds are the same
5.0: `4.95, 5.0, 5.0, 5.05` — one game frame lost at the start and one made up
later. The frames right after a briefing is dismissed are the heaviest the
game ever runs (`mis_wipe` clears all 16,000 bytes twice, the HUD repaints
into both buffers, the bar does the same), two of them cross a tick boundary,
and `demo_frames` is an integer — so 19.8 game frames counted as 19.
`test_frame_rate_does_not_regress` now settles for 100 frames and measures
over 400.

### Known open questions

- **Enemy sprites need no separate storage.** In Mode 1 the pen bit-0 plane is
  the high nibble and bit-1 the low, so `data OR ((data >> 4) AND #0F)` turns
  every pen 1 into pen 3 and leaves pens 0 and 2 alone — three instructions in
  the blitter instead of a second 4.2 KB copy per class. `--faction enemy`
  exists for hand-retouched variants; do not ship both sets by default.
- **Sprite memory is under §5.1's budget now** — 4.22 KB a class against
  4.8 KB — and it is worth knowing why the two numbers do not line up cleanly.
  Every sprite is stored one byte wider than it is, to give the 2-pixel
  pre-shift somewhere to land, which is 17% over what §5.1's table counts;
  §14's six yaw views takes 25% off. The two nearly cancel and the second one
  wins. Eight classes is **33.75 KB**, still three banks, still only fitting
  because banks 5-7 are read off the disc rather than carried in `DISC.BIN`.
  This is no longer an open question: the ninth class fits, and so do the
  tenth and eleventh. §14's other mitigation — tiers shared between classes —
  is unspent and should stay that way.

  **The second pitch level §5.1 wants is still out of reach.** It doubles
  everything: 33.75 KB → 67.5 KB, which is more than four banks and there are
  three. Six yaw views was the money that would have paid for it, and it has
  been spent.
- **Tier A (8×6) barely distinguishes the classes.** Bow-on, a frigate is 6×2
  and an interceptor 4×2. Class identity at that size is carried by bulk, not
  shape, with a 2-pixel margin. Two tests in `test_ships.py` hold the line:
  no two classes may share an 8×6 mask at any yaw, and **every one of the six
  views must be distinct**. That second one used to allow two of the eight
  views to coincide; at six there is no slack to give away, and every class
  clears it today. Both have caught real models — the Salvage Corvette's first
  fork was vertical, which reads perfectly broadside and is byte-for-byte the
  Mothership head-on.

  Six views made this tier harder in one specific way: **90° is never
  sampled**, so no class is ever seen exactly broadside, and the frigate's
  8-pixel bar — the widest thing in the game at 8×6 — became a 7-pixel
  three-quarter. It is still the widest, but the margin over the bomber is
  gone.
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
