"""Play the campaign straight through and report what the fleet costs.

Not a test -- a measuring stick, and the one the balance claims in CLAUDE.md
are quoted from. It exists because "how expensive is the campaign" turns out
to depend entirely on HOW it is played, and two people measuring with two
different scripts got two different answers: this one reached mission 8, and
another that also stationed the fleet and attacked lost the Mothership at
mission 5. Neither was wrong. So the tactic is written down here rather than
described in prose, and a number in the notes means "this script, this build".

The tactic: hold station over the Mothership and press A. Section 8 makes
losing the Mothership the end of the game, so abandoning it to chase is the
thing the design punishes -- see the notes on concentration in CLAUDE.md.

    python3 tools/balance.py
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import harness as h

ENT_SIZE = 20
ENT_HULL, ENT_FLAGS, ENT_CLASS = 10, 11, 9
F_ACTIVE, F_ENEMY = 1, 2
NAMES = {0: "int", 1: "moth", 2: "harv"}

s = h.symbols()
c = h.boot_quick(frames=300)
E = s["ENTITIES"]


def fleet():
    friendly, enemy, hull = {}, 0, 0
    for i in range(48):
        f = c.read_ram(E + i * ENT_SIZE + ENT_FLAGS, 1)[0]
        if not (f & F_ACTIVE):
            continue
        if f & F_ENEMY:
            enemy += 1
        else:
            k = c.read_ram(E + i * ENT_SIZE + ENT_CLASS, 1)[0]
            friendly[k] = friendly.get(k, 0) + 1
            hull += c.read_ram(E + i * ENT_SIZE + ENT_HULL, 1)[0]
    return friendly, enemy, hull


def total(d):
    return sum(d.values())


def show(d):
    return " ".join(f"{NAMES.get(k, k)}={v}" for k, v in sorted(d.items()))


print(f"{'mis':>3} {'enemy':>5} {'in':>3} {'out':>3} {'lost':>4}  {'hull':>5}  fleet")
for mission in range(8):
    before, enemy_start, hull_before = fleet()
    #  Play it the way the design intends: hold station over the Mothership
    #  rather than abandoning it, and press A to engage. Attacking is what
    #  lets a squadron concentrate; a fleet that only holds formation gets
    #  picked apart.
    c.write_ram(s["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
    c.key_down("a")
    c.run_frames(25)
    c.key_up("a")
    c.run_frames(12)

    frames = 0
    while frames < 9000:
        c.run_frames(60)
        frames += 60
        if c.read_ram(s["MIS_COMPLETE"], 1)[0] or c.read_ram(s["MIS_FAILED"], 1)[0]:
            break

    after, enemy_left, hull_after = fleet()
    failed = c.read_ram(s["MIS_FAILED"], 1)[0]
    ru = int.from_bytes(c.read_ram(s["ECO_RU"], 2), "little")
    lost = total(before) - total(after)
    print(f"{mission + 1:>3} {enemy_start:>5} {total(before):>3} {total(after):>3} "
          f"{lost:>4}  {hull_after:>5}  {show(after)}  RU={ru} "
          f"{'frames=' + str(frames)} {'FAILED' if failed else ''}"
          f"{' TIMEOUT' if frames >= 9000 else ''}")

    if failed:
        print("  -- campaign over: the Mothership was lost")
        break
    if not c.read_ram(s["MIS_COMPLETE"], 1)[0]:
        print("  -- never completed, stopping")
        break
    if mission < 7:
        h.jump_mission(c)

h.close(c)
