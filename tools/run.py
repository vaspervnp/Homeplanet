#!/usr/bin/env python3
"""Run the game in the headless emulator and take screenshots.

    python3 tools/run.py                    one shot after 2 seconds
    python3 tools/run.py --frames 300       let it run longer first
    python3 tools/run.py --shots 6 --every 5   a strip, to see motion
    python3 tools/run.py --disc             boot from the .dsk like a user

Screenshots land in build/shots/.
"""

from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from tests import harness  # noqa: E402

SHOTS = os.path.join(ROOT, "build", "shots")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--frames", type=int, default=100, help="frames before the first shot")
    ap.add_argument("--shots", type=int, default=1)
    ap.add_argument("--every", type=int, default=5, help="frames between shots")
    ap.add_argument("--disc", action="store_true", help="boot from the .dsk instead")
    ap.add_argument("--prefix", default="frame")
    args = ap.parse_args(argv)

    os.makedirs(SHOTS, exist_ok=True)

    c = harness.boot_disc(frames=args.frames) if args.disc else harness.boot_quick(frames=args.frames)

    for i in range(args.shots):
        if i:
            c.run_frames(args.every)
        path = os.path.join(SHOTS, f"{args.prefix}{i:02d}.png")
        # aspect=True doubles the height: the framebuffer stores one row per
        # scanline, so the raw image is vertically squashed against what a CPC
        # monitor actually shows.
        c.screenshot(path, aspect=True)
        print(f"{path}   displaying #{harness.crtc_page(c):04X}  pc=#{c.pc:04X}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
