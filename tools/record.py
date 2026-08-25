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
print("loading from the disc", flush=True)
c.type_text("|DISC\n")
record(60)
c.type_text('RUN"DISC\n')
#  Most of the load is a black screen while the stub relocates the game to
#  #0040. Run it, do not film it.
c.run_frames(150)
record(60, "RUN\"DISC")

# ------------------------------------------------------------------ title ---
record(200, "title screen")
press(cpc.KEY_SPACE, note="SPACE -> mission 1 briefing")
record(200, "briefing")
press(cpc.KEY_ENTER, note="ENTER -> into the game")
record(80)

# ------------------------------------------------------------ the controls ---
press(cpc.KEY_RIGHT, down=90, up=20, note="orbit the camera")
press("z", down=40, up=20, note="zoom in")
press("x", down=40, up=20, note="zoom out")
press("f", down=25, up=30, note="F -- change formation")
record(120)

press("/", note="? -- the key list")
record(240, "reading the controls")
press(cpc.KEY_ESC, note="ESC -- back to the battle")
record(60)

# ------------------------------------------------------- through to a fight ---
for mission in (1, 2):
    press("j", note=f"J -- jump to mission {mission + 1}")
    record(200, "briefing")
    press(cpc.KEY_ENTER, note="ENTER")
    record(60)

print(f"  mission {byte('MIS_INDEX') + 1}: {fleet()[0]} ours, {fleet()[1]} theirs",
      flush=True)

# ------------------------------------------------------------------ battle ---
#  Close the camera in before the shooting: at the widest zoom the whole
#  battle is a dozen lit pixels and reads as nothing at all.
press("z", down=30, up=25, note="zoom in")
press("z", down=30, up=25, note="zoom in again")
record(60)

press("a", note="A -- attack")
for _ in range(16):
    record(70)
    friendly, enemy = fleet()
    print(f"    {friendly} ours, {enemy} theirs", flush=True)
    if enemy == 0:
        break

record(150, "the picket is gone")
print(f"  mission complete: {byte('MIS_COMPLETE')}", flush=True)

# -------------------------------------------------------------- and onward ---
press("j", note="J -- jump onward")
record(260, "the next briefing")

ff.stdin.close()
ff.wait()
print(f"\n{shot} frames -> {OUT}  ({shot / FPS:.0f}s)", flush=True)
