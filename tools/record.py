"""Record a round of HOMEPLANET straight out of the emulator into an mp4.

Frames go down a pipe to ffmpeg as raw RGB rather than through a few thousand
PNGs. The emulator runs at 50Hz and we take every other frame, so the video is
25fps and real time -- the game itself ticks at a quarter of that, which is
what makes a CPC strategy game look like one.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, "/home/vasilhs/repos/CPCTools/cpcemu")

import cpc
from tests import harness as h

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/homeplanet-demo.mp4"
EVERY = 2                      # emulator frames per recorded frame
FPS = 50 // EVERY

sym = h.symbols()

c = cpc.CPC()
c.run_frames(h.BOOT_FRAMES)
if not c.insert_disc(h.DSK):
    raise SystemExit("insert_disc failed")

w, hgt = c.image(aspect=True).size
ff = subprocess.Popen(
    ["ffmpeg", "-y", "-loglevel", "error",
     "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{hgt}", "-r", str(FPS),
     "-i", "-",
     "-c:v", "libx264", "-preset", "slow", "-crf", "20",
     "-pix_fmt", "yuv420p", OUT],
    stdin=subprocess.PIPE)

shot = 0


def record(frames, note=None):
    """Run the machine and push what it displays into ffmpeg."""
    global shot
    if note:
        print(f"  {note}", flush=True)
    for _ in range(frames // EVERY):
        c.run_frames(EVERY)
        ff.stdin.write(c.image(aspect=True).convert("RGB").tobytes())
        shot += 1


def press(key, down=25, up=30, note=None):
    """A keypress, recorded. The release has to be long enough for key_scan
    to see it -- every command in the game is edge-triggered."""
    if note:
        print(f"  {note}", flush=True)
    c.key_down(key)
    record(down)
    c.key_up(key)
    record(up)


def byte(name):
    return c.read_ram(sym[name], 1)[0]


def word(name):
    return int.from_bytes(c.read_ram(sym[name], 2), "little")


def fleet():
    friendly = enemy = 0
    for slot in range(48):
        f = c.read_ram(sym["ENTITIES"] + slot * 20 + 11, 1)[0]
        if f & 1:
            if f & 2:
                enemy += 1
            else:
                friendly += 1
    return friendly, enemy


# ---------------------------------------------------------------- loading ---
#  Through HOME.BAS rather than straight to DISC.BIN, because that is what a
#  player gets: the splash sits there for ten seconds or until SPACE.
print("loading from the disc", flush=True)
c.type_text("|DISC\n")
record(60)
c.type_text('RUN"HOME\n')
record(300, "the splash screen")
press(cpc.KEY_SPACE, down=25, up=20, note="SPACE -- skip the rest of the ten seconds")
#  Most of what follows is a black screen while the stub relocates the game to
#  #0040. Run it, do not film it.
c.run_frames(200)
record(60)

# ------------------------------------------------------------------ title ---
record(220, "title screen")
press(cpc.KEY_SPACE, note="SPACE -> mission 1 briefing")
record(220, "briefing")
press(cpc.KEY_ENTER, note="ENTER -> into the game")
record(100, "playing: the context bar names the live keys")

# -------------------------------------------------- the width of the screen ---
#  The playfield reaches the edges at EVERY zoom step now, not just at the
#  narrow ones -- see "Using the width of the screen" in CLAUDE.md. Walk the
#  ladder right out and back so it can be seen rather than asserted.
press(cpc.KEY_RIGHT, down=110, up=20, note="orbit the camera")
for n in range(5):
    press("-", down=22, up=26, note=f"- zoom out ({n + 1})")
record(200, "the fleet still spans the screen at the widest step")
for n in range(4):
    press(";", down=22, up=26, note=f"+ zoom in ({n + 1})")   # + is SHIFT + ;
record(140)

# ------------------------------------------------------- the context bar ---
press(cpc.KEY_SPACE, note="SPACE -- tactical pause")
record(160, "PAUSED, in the attention ink")
press(cpc.KEY_SPACE, note="SPACE -- and on again")
record(60)

press(cpc.KEY_ENTER, note="ENTER -- the move disc")
record(80, "the bar changes: ARROWS MOVE  SHIFT HEIGHT  ENTER OK  ESC")
press(cpc.KEY_RIGHT, down=70, up=20, note="drive the disc")
press(cpc.KEY_ESC, note="ESC -- cancel it")
record(60)

# -------------------------------------------------------- the build panel ---
#  The thing the bar was built for: the yard used to say ">SCT" in a corner
#  and nothing else, and a player asked twice how to choose what to build.
print(f"  RU in hand: {word('ECO_RU')}", flush=True)
press("b", note="B -- the build panel")
record(120, "the class by name, its price, and whether ENTER will work")
for n in range(3):
    press(".", down=22, up=28, note=f". -- up the price ladder ({n + 1})")
    record(70)
press(",", down=22, up=28, note=", -- back down one")
record(90)
press(cpc.KEY_ENTER, note="ENTER -- order it")
record(120, "the yard is busy now, and the bar says so")
print(f"  RU after ordering: {word('ECO_RU')}", flush=True)
press("b", note="B -- close the panel")
record(60)

# ------------------------------------------------------------- squadrons ---
press("f", note="F -- change formation")
record(150)
press("d", note="d -- divide the squadron")
record(400, "both halves hold together, and each keeps its own station")
press("2", note="2 -- the new half")
record(120)
press("1", note="1 -- the old half")
record(120)
press("c", note="c -- put them back together")
record(200)

# ------------------------------------------------------------ the orders ---
press(cpc.KEY_ESC, note="ESC -- the orders menu")
record(100, "the orders, with their shortcuts")
for _ in range(3):
    press(cpc.KEY_DOWN, down=25, up=28)
record(80)
press(cpc.KEY_ESC, note="ESC -- back out of it")
record(50)

press("/", note="? -- the key list")
record(220, "reading the controls")
press(cpc.KEY_ESC, note="ESC -- back to the battle")
record(60)

# ------------------------------------------------------ through to a fight ---
for mission in (1, 2):
    press("j", note=f"J -- jump to mission {mission + 1}")
    record(220, "briefing")
    press(cpc.KEY_ENTER, note="ENTER")
    record(70)

friendly, enemy = fleet()
print(f"  mission {byte('MIS_INDEX') + 1}: {friendly} ours, {enemy} theirs", flush=True)

# ------------------------------------------------------------------ battle ---
#  Close the camera in before the shooting: at the widest zoom the whole
#  battle is a dozen lit pixels and reads as nothing at all.
press(";", down=28, up=24, note="+ zoom in")
press(";", down=28, up=24, note="+ zoom in again")
record(60)

press("a", note="A -- attack")
for _ in range(18):
    record(70)
    friendly, enemy = fleet()
    print(f"    {friendly} ours, {enemy} theirs, hull {byte('WAVE_PCT')}%",
          flush=True)
    if enemy == 0:
        break

record(200, "the picket is gone -- the order spends itself and the fleet re-forms")
print(f"  mission complete: {byte('MIS_COMPLETE')}", flush=True)

# -------------------------------------------------------------- and onward ---
press("j", note="J -- jump onward")
record(280, "the next briefing")

ff.stdin.close()
ff.wait()
print(f"\n{shot} frames -> {OUT}  ({shot / FPS:.0f}s)", flush=True)
