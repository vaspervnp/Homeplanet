"""Loiter in every mission until the waves come, and report how often you win.

The sibling of tools/balance.py, and it exists for the same reason: "is the
game fair" is not a constant somebody writes down, it is a rate somebody
measures. balance.py answers "what does the campaign cost if you jump the
moment you are allowed to". This one answers the question the attack waves
raise -- what does it cost if you DON'T -- and the requirement it checks is a
floor: at least a 70% chance of coming out of a loiter alive.

    python3 tools/waverate.py            # 8 campaigns, the default
    python3 tools/waverate.py 16 -q      # more samples, less chatter

WHAT COUNTS AS WINNING
----------------------
A mission is WON if, after WAVES_PER_MISSION waves have arrived and been fought
to a standstill, the Mothership is still alive AND the objective is met -- so
the player can actually press `J` and leave. It is LOST if mis_failed is set,
which in this game means one thing: the Mothership is gone and sixty thousand
sleepers with it. Section 8 makes that the end of the campaign, so it is the
floor, and nothing softer is worth measuring.

Surviving ONE wave is too weak a bar -- a fleet can absorb a single volley and
still be dead on its feet -- so the run keeps loitering, and each wave lands on
what the last one left. Three is what a player who has decided to mine a
mission dry would sit through.

THE TRIAL IS PER MISSION, AND THE FLEET IS PUT BACK AFTERWARDS
---------------------------------------------------------------
Each mission is reached with balance.py's tactic and NO loitering, the entity
table is photographed, the loiter is played out, and then the photograph is put
back before the jump. So mission 6's number means "loiter in mission 6 with the
fleet you would actually have there", not "loiter in mission 6 with whatever
five previous loiters left" -- which is a different and much harsher question,
and one where every mission's rate is conditional on having survived the last.

That harsher question has an answer and it is worth knowing: loiter through
three waves in EVERY mission and the campaign dies around mission 5, because
hull never regenerates and twenty-four waves is more attrition than a fleet
that cannot repair can absorb. That is the design working -- loitering is
supposed to cost -- but it is not what the 70% is about.

THE TACTIC, AND THE ONE THING IT ADDS TO balance.py's
-----------------------------------------------------
Station the fleet on the Mothership and press `A`, exactly as balance.py does
and for the same reason: section 8 makes abandoning the Mothership the thing
the design punishes. Then, when a wave is dead, wait for the fleet to come
home before letting the next one arrive.

It used to press `G` there, and that `G` was a WORKAROUND rather than a tactic
-- which is how this tool found a bug that had nothing to do with the waves.
An ENT_ORDER_ATTACK ship is skipped by phase4_fly, deliberately, so
cbt_move_enemies can close it on its target without the two systems
cancelling, and nothing cleared the order when the target died. So a fleet
that had just killed a wave six thousand units out stayed there, and
fleet_save carried those coordinates into the next mission: loiter through
three waves in mission 4 and the fleet began mission 5 scattered around
wherever the last wave happened to arrive, with the Mothership alone at the
origin and THE NEBULA's eight hostiles spawning on top of it. Measured with
the `G` taken out, the campaign died at mission 5 in six runs out of six, at
full hull, with no wave on the screen.

cbt_fire_if_able now spends the order itself the moment there is nothing left
to shoot at, so the `G` is gone from here on purpose: a measuring stick that
works around a bug measures the workaround. See "An attacking ship never comes
home" in CLAUDE.md.

WHAT IT DOES NOT MEASURE
------------------------
The clock, in its default mode. WAVE_FIRST_FRAMES is 426 game frames, there
are three waves a mission and eight missions a campaign, and waiting all of it
out is more emulated time than anyone will sit through. So the run writes
wave_next to bring each arrival forward: it moves WHEN a wave lands and touches
nothing about what lands or how big it is. tests/test_waves.TestTheClock is
what checks the clock itself.

AND THAT MADE THE DEFAULT MODE BLIND TO THE SPACING, WHICH --overlap FIXED
--------------------------------------------------------------------------
The default forces a wave, fights it until nothing of it is flying, waits for
the fleet to come home, and only then forces the next. So it measures three
SEPARATE fights however far apart the game would really have put them -- which
was honest while WAVE_GAP_MIN was 300 game frames, longer than any fight, and
stopped being honest the moment the spacing was cut to a third of that.

IT IS HONEST AGAIN. WAVE_GAP_MIN is 426 -- a minute, on the design owner's
instruction that the waves be one to two minutes apart -- and a minute is
longer than any fight, so the default protocol once more measures the shape the
game actually has. --overlap now measures a spacing this build does not use;
keep it, because the spacing has been set three times and may be again, but do
not read it as this build's number.

    python3 tools/waverate.py 4 --overlap

runs the same trials on the GAME's clock: the first wave is still brought
forward, and after that wave_next is left exactly where wave_send put it, so
wave two lands whenever the game says it does -- on top of wave one if that is
what 100 + 1.125r comes to.

READ IT AS A FLOOR, NOT AS A DELTA. There is no comparable figure for the old
spacing, and there cannot be one from this tool: at 300 + 3.5r a wave was up to
1192 game frames behind the last, so three of them on the real clock is three
or four times the emulated time OVERLAP_WAVE_FRAMES allows and the trial would
simply be truncated. The default mode is the before-and-after; this mode is the
one that answers "does the 70% still hold when they arrive on top of each
other", which is a question the default cannot ask at all. The wave count
actually reached is printed in the `waves` column, so a truncated trial is
visible rather than silently counted as a win.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import harness as h

ENT_SIZE = 20
#  Out of the build: it was a fixed 48 and the fleet's ceiling has since
#  doubled. This is a MEASURING tool, so a stale count does not fail -- it
#  prints a plausible win rate with ships missing from both the reading and
#  the photograph it puts back.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_HULL, ENT_FLAGS, ENT_CLASS = 10, 11, 9
F_ACTIVE, F_ENEMY, F_WAVE = 1, 2, 8

#  READ, NOT WRITTEN DOWN, for the same reason ENT_MAX above it is. The
#  campaign was eight missions when this was a literal and is twenty now, and a
#  measuring tool with a stale count does not fail -- it prints a plausible
#  table with the late campaign silently missing from it, which is worse than
#  an error because somebody will quote it.
MISSIONS = h.symbols()["MIS_COUNT"]
WAVES_PER_MISSION = 3

#  Emulator frames, not game frames: about ten of the first to one of the
#  second at the rate this game runs at.
WAVE_FIGHT_FRAMES = 1500
OBJECTIVE_FRAMES = 3000
#  Long enough for a squadron six thousand units out to fly home: phase4_fly
#  steps PHASE4_STEP = 150 units a game frame.
REGROUP_FRAMES = 600

#  --overlap only. Emulator frames to allow per wave: the game's own spacing is
#  100..386 GAME frames, so three waves is at most 1158 of them and about ten
#  emulator frames go to each. 4500 leaves room for the last fight on top.
OVERLAP_WAVE_FRAMES = 4500

#  What a trial photographs and puts back. The entity table is the fleet; the
#  other four are the things derived from it that nothing would recompute on
#  its own inside one frame.
SNAPSHOT = ["MOTH_SLOT", "MIS_FAILED", "MIS_COMPLETE", "SQUAD_SEL"]


def fleet(c, E):
    """(friendly ships, friendly hull, hostile wave ships still flying)."""
    ships = hull = riders = 0
    for i in range(ENT_MAX):
        f = c.read_ram(E + i * ENT_SIZE + ENT_FLAGS, 1)[0]
        if not (f & F_ACTIVE):
            continue
        if f & F_ENEMY:
            if f & F_WAVE:
                riders += 1
        else:
            ships += 1
            hull += c.read_ram(E + i * ENT_SIZE + ENT_HULL, 1)[0]
    return ships, hull, riders


def photograph(c, s, E):
    snap = {"entities": c.read_ram(E, ENT_MAX * ENT_SIZE)}
    for name in SNAPSHOT:
        snap[name] = c.read_ram(s[name], 1)
    snap["squad_count"] = c.read_ram(s["SQUAD_COUNT"], 10)
    return snap


def put_back(c, s, E, snap):
    c.write_ram(E, snap["entities"])
    for name in SNAPSHOT:
        c.write_ram(s[name], snap[name])
    c.write_ram(s["SQUAD_COUNT"], snap["squad_count"])


def cripple(c, s, E):
    """Make the fleet look like mission 7's: half the ships, half the hull.

    The requirement the waves have to meet is not "a fresh fleet survives" --
    it is that a fleet which has already lost half of itself still has its 70%.
    That is what the scaling rule is FOR, and it is the one condition the
    campaign cannot reliably be played into: the picket at THE GATE takes the
    Mothership before any wave lands, in this build and in the one before it,
    for the frame-boundary reasons CLAUDE.md documents and says not to tune.

    So it is arranged instead. Every second ship is struck off and the rest are
    put at half hull, which halves wave_hull and therefore halves the wave --
    which is the whole claim under test.
    """
    keep = True
    for i in range(ENT_MAX):
        base = E + i * ENT_SIZE
        f = c.read_ram(base + ENT_FLAGS, 1)[0]
        if not (f & F_ACTIVE) or (f & F_ENEMY):
            continue
        if c.read_ram(base + ENT_CLASS, 1)[0] == 1:      # CLASS_MOTHERSHIP
            c.write_ram(base + ENT_HULL, bytes([128]))
            continue
        keep = not keep
        if keep:
            c.write_ram(base + ENT_HULL, bytes([max(1, c.read_ram(base + ENT_HULL, 1)[0] // 2)]))
        else:
            c.write_ram(base + ENT_FLAGS, bytes([0]))
    #  squad_count is left stale on purpose. It is derived, nothing recounts it
    #  until the next kill, and the only things that read it are the HUD and
    #  squad_select -- phase4_fly hands out formation slots by walking the
    #  table, so the flying is right from the first frame. Pressing a squadron
    #  command to force a recount would restation the fleet, which is a much
    #  bigger lie than a HUD digit that is briefly wrong.
    c.run_frames(2)


def press(c, key, frames=25):
    c.key_down(key)
    c.run_frames(frames)
    c.key_up(key)
    c.run_frames(12)


def regroup(c):
    """Wait for the fleet to fly home.

    Nothing is pressed. The attack order spends itself when the last target
    dies -- that is the whole of the fix this tool asked for -- so all that is
    left to do is give phase4_fly the frames to walk the fleet back.
    """
    c.run_frames(REGROUP_FRAMES)


def win_the_mission(c, s, E):
    """Play the mission as balance.py would, and stop when it is decided."""
    c.write_ram(s["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
    press(c, "a")
    spent = 0
    while spent < OBJECTIVE_FRAMES:
        c.run_frames(60)
        spent += 60
        if c.read_ram(s["MIS_COMPLETE"], 1)[0] or c.read_ram(s["MIS_FAILED"], 1)[0]:
            break
    if not c.read_ram(s["MIS_FAILED"], 1)[0]:
        regroup(c)


def loiter(c, s, E):
    """Sit in the mission through WAVES_PER_MISSION waves. Returns (won, sizes)."""
    sizes = []
    for _ in range(WAVES_PER_MISSION):
        if c.read_ram(s["MIS_FAILED"], 1)[0]:
            break
        h.force_wave(c, s)
        c.run_frames(30)
        sizes.append(c.read_ram(s["WAVE_SIZE"], 1)[0])
        press(c, "a")

        spent = 0
        while spent < WAVE_FIGHT_FRAMES:
            c.run_frames(60)
            spent += 60
            if c.read_ram(s["MIS_FAILED"], 1)[0]:
                break
            if fleet(c, E)[2] == 0:
                break
        if not c.read_ram(s["MIS_FAILED"], 1)[0]:
            regroup(c)

    failed = c.read_ram(s["MIS_FAILED"], 1)[0]
    complete = c.read_ram(s["MIS_COMPLETE"], 1)[0]
    return (not failed) and bool(complete), sizes


def loiter_overlap(c, s, E):
    """The same loiter on the GAME's clock, so waves may land on each other.

    Only the first arrival is brought forward; after that wave_next is left
    exactly where wave_send put it. So the second and third waves come when
    WAVE_GAP_MIN + 1.125r says they do, which at today's spacing is well inside
    the time it takes to kill the one already on the screen.

    Nothing is waited for and nothing is regrouped: the fleet is told to attack
    once and then simply left in the mission for as long as three waves would
    take, which is what a player who has decided to mine a field dry is doing.
    The budget is generous on purpose -- the point of the run is what the fleet
    looks like at the end of it, not how quickly it got there.
    """
    h.force_wave(c, s)
    c.run_frames(30)
    press(c, "a")

    budget = WAVES_PER_MISSION * OVERLAP_WAVE_FRAMES
    spent = 0
    while spent < budget:
        c.run_frames(60)
        spent += 60
        if c.read_ram(s["MIS_FAILED"], 1)[0]:
            break
        if c.read_ram(s["WAVE_COUNT"], 1)[0] >= WAVES_PER_MISSION:
            #  All three have arrived; the trial is over when the last of them
            #  is dead or has killed us.
            if fleet(c, E)[2] == 0:
                break

    sizes = [c.read_ram(s["WAVE_COUNT"], 1)[0]]
    failed = c.read_ram(s["MIS_FAILED"], 1)[0]
    complete = c.read_ram(s["MIS_COMPLETE"], 1)[0]
    return (not failed) and bool(complete), sizes


def trial(c, s, E, verbose, mission, label, damage, overlap=False):
    """One loiter, with the fleet put back exactly as it was afterwards."""
    snap = photograph(c, s, E)
    if damage:
        cripple(c, s, E)
    before = fleet(c, E)
    won, sizes = (loiter_overlap if overlap else loiter)(c, s, E)
    after = fleet(c, E)
    if verbose:
        print(f"    mis {mission + 1} {label:<6} in {before[0]:>2} ships"
              f" {before[1]:>5} hull  waves {str(sizes):<12}"
              f" out {after[0]:>2} ships {after[1]:>5} hull"
              f"  {'WON' if won else 'LOST'}")
    put_back(c, s, E, snap)
    c.run_frames(30)
    return won


def campaign(seed, verbose, overlap=False):
    """One playthrough. Returns [(mission, label, won)] -- two trials a mission."""
    s = h.symbols()
    E = s["ENTITIES"]
    c = h.boot_quick(frames=300)
    h.pin_rng(c, seed)
    out = []
    try:
        for mission in range(MISSIONS):
            win_the_mission(c, s, E)
            if c.read_ram(s["MIS_FAILED"], 1)[0]:
                #  The mission was lost with no wave in it. That is
                #  balance.py's campaign failing, not this one's question, so
                #  it is reported and not counted.
                if verbose:
                    print(f"    mis {mission + 1}  -- lost before any wave; "
                          f"not a wave trial, stopping")
                break

            for label, damage in (("whole", False), ("halved", True)):
                out.append((mission + 1, label,
                            trial(c, s, E, verbose, mission, label, damage,
                                  overlap)))
            if mission < MISSIONS - 1:
                h.jump_mission(c)
    finally:
        h.close(c)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    runs = int(args[0]) if args else 8
    verbose = "-q" not in sys.argv
    overlap = "--overlap" in sys.argv

    #  Seeds spread across the word. sys_rand's first draw is the high byte, so
    #  seeds that agree up there start alike.
    seeds = [(0x1000 + i * 0x0947) & 0xFFFF or 1 for i in range(runs)]
    labels = ("whole", "halved")
    tally = {(m, k): [0, 0] for m in range(1, MISSIONS + 1) for k in labels}

    for n, seed in enumerate(seeds):
        if verbose:
            print(f"campaign {n + 1}/{runs}, seed #{seed:04X}"
                  f"{'  (overlapping waves)' if overlap else ''}")
        for mission, label, won in campaign(seed, verbose, overlap):
            tally[(mission, label)][0] += 1
            tally[(mission, label)][1] += int(won)

    print()
    print(f"{'mis':>3}  {'whole fleet':>16}  {'half a fleet':>16}")
    totals = {k: [0, 0] for k in labels}
    for mission in range(1, MISSIONS + 1):
        cells = []
        for label in labels:
            n, w = tally[(mission, label)]
            totals[label][0] += n
            totals[label][1] += w
            cells.append(f"{w:>3}/{n:<3} {100 * w / n:>4.0f}%" if n else "      --   ")
        if any(tally[(mission, k)][0] for k in labels):
            print(f"{mission:>3}  {cells[0]:>16}  {cells[1]:>16}")
    n = sum(totals[k][0] for k in labels)
    w = sum(totals[k][1] for k in labels)
    for label in labels:
        tn, tw = totals[label]
        if tn:
            print(f"{label:>10}: {tw}/{tn} = {100 * tw / tn:.0f}%")
    if n:
        print(f"     all: {w}/{n} = {100 * w / n:.0f}%   -- the floor is 70%")


if __name__ == "__main__":
    main()
