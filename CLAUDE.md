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
#4000-#7FFF   BANK WINDOW — extended banks 4-7
              sprite libraries, mission data, text, music
#8000-#BFFF   screen buffer B
#C000-#FFFF   screen buffer A
```

Everything touched per frame must live below `#4000`, because the `#4000`
window is being paged underneath it.

`src/main.asm` asserts at build time that code+tables stay clear of the stack,
and prints how many bytes are left. Watch that number.

Banking: `OUT (#7Fxx), #C4..#C7` pages extended bank 4..7 into `#4000`.
`#C0` is the power-on layout. Equates in `src/equ/hardware.asm`.

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

**`@` labels are scoped to the FILE, not to the enclosing routine.** Two
routines in one file cannot both have an `@positive`. Give them names that say
which routine they belong to.

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
| 24 entities projected | ~109,000 T (41% of a frame) | 29,000 T |

A general 3×3 rotation will not fit 1,200 T on a 4 MHz Z80: nine table-driven
multiplies alone are more than that. 24 entities still fit the frame, but
§6's total needs revising. The 100 background stars must use the cheap path in
§5.4 (no translation, no perspective divide, cached unless the camera moves) —
they cannot go through `proj_point`.

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
- **Phase 3 — partly done, out of order.** The sprite pipeline exists
  (`mkships.py` → `art/*.json` → `rt2sprite.py`) and three classes are drawn,
  but nothing blits them yet. That is Phase 2.
- **Phase 2 — next.** The masked sprite blitter and dirty rectangles for it.
  The data is already in the right layout: mask/data pairs, row-major, one
  block per (frame, pre-shift).

`src/demo/phase1.asm` is the Phase 1 acceptance test running on the CPC
itself. Delete it when Phase 4 puts real entities on screen.

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
