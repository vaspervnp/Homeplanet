# HOMEPLANET

A fleet-strategy game for the **Amstrad CPC 6128**, written in Z80 assembly.
Mode 1, 320×200, four inks, running from disc on a 4 MHz machine with 128 KB.

A convoy carrying sixty thousand sleepers runs from a lost world. The fleet
only ever shrinks — what is lost is lost — and every mission is a choice about
how much of it you are willing to spend.

Three documents, and they are not interchangeable:

| file | what it is |
|---|---|
| [Homeplanet.md](Homeplanet.md) | **the design document, and the spec.** In Greek. Section numbers quoted everywhere else refer to it |
| [CLAUDE.md](CLAUDE.md) | **how to work on it.** Every constraint, every bug worth remembering, and why each decision went the way it did. Read it before changing anything |
| [todo.md](todo.md) / [improvements.md](improvements.md) | what is not built yet, and designs agreed but not written |

This file is the entry point: what you need, how to build it, how to test it.

---

## What you need

| tool | where | what for |
|---|---|---|
| **RASM** 3.2.5 | `rasm` on PATH | the Z80 assembler. Writes EDSK images directly |
| **iDSK** 0.20 | `iDSK` on PATH | putting ordinary files on the `.dsk` and reading the catalogue |
| **cpcemu** | `~/repos/CPCTools/cpcemu` | headless CPC 6128 with a Python API. The whole test suite runs on it |
| **Python 3** | | **stdlib only** — no numpy, no pytest. Tests are `unittest` |
| **ffmpeg** | | the music converter and the demo recorder. Not needed for a plain build |
| **RetroTools** | `~/repos/retrotools` | the sprite editor. Only needed to retouch art |

PIL is used by the sprite and recording tools.

---

## Building

```bash
make                # generate tables, assemble, produce build/homeplanet.dsk
make clean
make dsk-list       # the AMSDOS catalogue of the built disc
```

`build/homeplanet.dsk` is the deliverable. Put it in an emulator and it boots.

The build **prints the four numbers that matter** and you should watch all of
them:

```
hand-written code ends at #30BD
code+tables: #40 .. #3C00  free: 768
bank 4: #4000 .. #6A2D  image: 7085  free: 5170
DISC.BIN: 23123 bytes, exec at #9A1A
```

- `free:` for the low 16K is **quantised to 256 bytes** because the generated
  tables are page-aligned, so it lies about how close you are — watch
  *"hand-written code ends at"* instead.
- `DISC.BIN` must finish below `#A700`, where AMSDOS keeps its workspace. That
  is a 26368-byte ceiling and it has been the binding constraint more than once.

Regenerating the derived sources:

```bash
make tables         # the lookup tables (tools/gentables.py)
make ships          # re-render the 3D ship models into art/ and src/gen/
make music          # re-analyse the ogg files and compose MUSIC3
```

`src/gen/` is generated and git-ignored, **except** the music note streams,
which are checked in so the repo builds without the 7 MB of source audio.

---

## Testing

```bash
make test                              # everything, about nine minutes
python3 -m unittest tests.test_phase0 -v   # one module
python3 -m unittest discover -s tests -t . # the same as make test
```

Around **540 tests**. They are slow for a specific reason: the sprite libraries
live on the disc as raw sectors, so every boot spins the drive up and reads
them — a second and a half of emulated time per machine, and there are about a
hundred machines. That is the price of testing the real loader instead of a
poke. **Do not add a fixture that boots per test method when a `setUpClass`
would do.**

The suite drives a real emulator: it presses real keys, reads real screen RAM,
and reads the AY's own registers back out of the chip. `tests/harness.py` is
the wrapper.

---

## Layout

```
src/            the game
  equ/          hardware and memory-map equates
  sys/          boot, interrupts, screen, keyboard, sound, music, FDC, bank loader
  math/         multiply, camera matrix, projection
  gfx/          sprite blitter, text, lines, markers
  game/         entities, squadrons, combat, economy, missions, salvage, UI screens
  demo/         phase4.asm -- the frame loop and the HUD
  gen/          GENERATED. Tables, sprites, music
  main.asm      the build: includes, bank layout, and every build-time assert
  disc.asm      the loader stub that puts the game at #0040
tools/          Python: table generation, sprite conversion, music, balance, recording
tests/          unittest, on the emulator
art/            checked-in RetroTools projects -- the source art
assets/         the splash screen and its BASIC loader
musicsamples/   source audio, NOT in git
build/          everything derived, including the .dsk
```

---

## Things that will bite you

These are the ones that cost real time here. The long versions are in
[CLAUDE.md](CLAUDE.md).

**Check that `make` actually succeeded.** Piping it to `/dev/null` once hid a
failed assembly, and the tests that followed ran against the *previous* `.dsk`
with a symbol file that no longer matched it. A test then fails for a reason
that has nothing to do with your change.

**Never run `rasm` by hand to look at an error.** It rewrites
`build/homeplanet.sym`, and if that assembly fails the symbol file is left
disagreeing with the binary `make` built. Use `make`, or `make clean` after.

**The `.dsk` is minted fresh every build, and the `rm -f` in the Makefile is
load-bearing.** RASM's `-eo` writes *into* an existing image, so overwriting in
place leaves the disc holding a mixture of builds — everything on disk correct,
the tests green, and the machine running last week's code.

**The game runs at `#0040`, and that is forced.** `#0000-#3FFF` is shadowed by
the lower ROM: writes go to RAM, reads come from ROM. `src/disc.asm` explains
the loader at length.

**Bank 4 is the resting state of the `#4000` window, not the only state.** Use
`harness.read_bank4()` rather than `read_cpu` for anything in it — about four
samples in forty land with a sprite library paged in.

**cpcemu cannot model the floppy controller's timing.** It resolves the µPD765
synchronously and will agree with any assumption you make. Two real bugs shipped
that every test passed and a real machine rejected. **Test the disc on Retro
Virtual Machine before believing the FDC works.**

**A screen test that reads only the front buffer is half a test.** The display
page-flips; anything drawn into one buffer and not the other is on screen every
*other* frame, which is a flicker on the machine and nothing at all in a test.

**Measure, do not estimate.** `demo_wait_frame` quantises to whole 50 Hz ticks,
so a 2% change in frame time can show up as a 10% change in frame rate. Before
believing a swing in `tools/balance.py`, run the control CLAUDE.md prescribes:
add 520 T-states of `djnz` to `demo_update`, change nothing else, and see
whether the swing reproduces.

---

## The measuring tools

Balance in this game is not an opinion, it is a script:

```bash
python3 tools/balance.py     # plays a whole campaign and prints what it cost
python3 tools/waverate.py 4  # the attack-wave win rate, against a 70% floor
python3 tools/run.py --shots 6 --every 5   # a strip of frames, to see motion
python3 tools/record.py      # records a round to mp4 (needs ffmpeg)
```

**The tactic is part of the number** — how expensive a campaign is depends
entirely on how it is played, so run the tool rather than quoting prose.

And **look at the result**. Several defects in this project's history were
found by watching a recording and by no test at all: a consolidation label that
read `++7`, an orders menu printed across the HUD, and a title screen drawing
its own code as pixels.
