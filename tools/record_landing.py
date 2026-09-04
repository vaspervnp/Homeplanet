"""Record the end of the journey -- the landing and the victory page -- to mp4.

    python3 tools/record_landing.py [build/landing.mp4]

Same pipe as tools/record.py: raw RGB frames down to ffmpeg, every other
emulator frame, so the video is 25 fps real time. Boots the quick way, puts
the campaign on its last mission with the way out open, presses J, and lets
the countdown run for a couple of seconds before skipping the rest of it --
the countdown is a mechanic, and the video is about what comes after it: the
LAND, the Mothership setting down, and the page.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, "/home/vasilhs/repos/CPCTools/cpcemu")

from tests import harness as h  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/landing.mp4"
EVERY = 2
FPS = 50 // EVERY

sym = h.symbols()
c = h.boot_quick(frames=300)
h.let_the_game_draw(c, sym, 3)

#  The last mission, with the way out open: LAND on the HUD.
c.write_ram(sym["MIS_INDEX"], bytes([sym["MIS_COUNT"] - 1]))
c.write_ram(sym["PHASE4_HUD_SHADOW_MIS"], bytes([0xFF]))
h.clear_the_way_out(c)
h.let_the_game_draw(c, sym, 4)

w, hgt = c.image(aspect=True).size
ff = subprocess.Popen(
    ["ffmpeg", "-y", "-loglevel", "error",
     "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{hgt}", "-r", str(FPS),
     "-i", "-",
     "-c:v", "libx264", "-preset", "slow", "-crf", "20",
     "-pix_fmt", "yuv420p", OUT],
    stdin=subprocess.PIPE)


def record(frames, note=None):
    if note:
        print(f"  {note}", flush=True)
    for _ in range(frames // EVERY):
        c.run_frames(EVERY)
        ff.stdin.write(c.image(aspect=True).convert("RGB").tobytes())


record(50, "the last mission, LAND on offer")
c.key_down("j")
record(20, "J: LANDING counts down")
c.key_up("j")
record(100)
#  ...two seconds of it is the idea; the rest is skipped.
h.skip_the_countdown(c)
record(60)
record(360, "the Mothership sets down")
for _ in range(200):
    record(10)
    if h.read_bank4(c, sym["MIS_WON"], 1)[0]:
        break
record(200, "the page")

ff.stdin.close()
ff.wait()
print(f"wrote {OUT}")
