"""Play the campaign straight through and report what the fleet costs.

Not a test -- a measuring stick, and the one the balance claims in CLAUDE.md
are quoted from. It exists because "how expensive is the campaign" turns out
to depend entirely on HOW it is played, and two people measuring with two
different scripts got two different answers: this one reached mission 8, and
another that also stationed the fleet and attacked lost the Mothership at
mission 5. Neither was wrong. So the tactic is written down here rather than
described in prose, and a number in the notes means "this script, this build".

THE DEFAULT TACTIC: hold station over the Mothership and press A. Section 8
makes losing the Mothership the end of the game, so abandoning it to chase is
the thing the design punishes -- see the notes on concentration in CLAUDE.md.

IT CANNOT FINISH THE CAMPAIGN ANY MORE, and that is not a fault in it. A jump
costs MIS_JUMP_COST out of the treasury, and this tactic never spends a unit
and never sends a harvester anywhere -- so it earns nothing, and ECO_START_RU
does not cover one jump. Read it now as what it has always literally been: the
cost of a campaign to a fleet that only ever shrinks, up to the mission where
the fare runs out. `--rebuild` is the one that plays the game this build has.

AND A SECOND ONE, `--rebuild`, because the default cannot measure the campaign
this project is now trying to have. It never spends a unit of RU and never
sends a harvester anywhere, so it measures a fleet that only ever SHRINKS --
which is exactly right for a campaign of eight tuned so that it nearly lasts,
and structurally blind to one of twenty, where improvements.md §4 says the
player "is expected to REBUILD, not merely survive". A measuring stick that
cannot express the intended play cannot be used to tune for it.

`--rebuild` adds three things to the default and changes nothing else: `H` at
the top of every mission, an order placed whenever the RU is there for one,
and -- the one that matters -- IT LINGERS AFTER THE OBJECTIVE IS MET.

That third thing is not a detail, it is the whole shape of the tactic. The
default jumps the instant it is allowed to, and its missions are over in 60 to
420 game frames; the first version of this spent nothing at all in a whole
campaign because the yard never had time to be reached, let alone to deliver.
YOU CANNOT REBUILD IF YOU JUMP IMMEDIATELY -- so rebuilding is not a policy
laid on top of the default tactic, it is a different relationship with the
clock, and it buys its ships with the thing "Attack waves, and the price of
staying" charges for. That is the trade a twenty-mission campaign is made of.

It keeps two harvesters alive and buys interceptors with the rest, which is the
dullest possible spending policy and therefore a FLOOR -- a player who picks
better does better, and the number means "this script, this build" as much as
the default's does.

    python3 tools/balance.py
    python3 tools/balance.py --rebuild
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import harness as h

REBUILD = "--rebuild" in sys.argv

ENT_SIZE = 20
ENT_HULL, ENT_FLAGS, ENT_CLASS = 10, 11, 9
F_ACTIVE, F_ENEMY = 1, 2
CLASS_INTERCEPTOR, CLASS_HARVESTER = 0, 2
#  src/game/classdata.asm. Mirrored rather than read because eco_class_cost is
#  in bank 4 and this tool has no reason to page it in.
COST = {CLASS_INTERCEPTOR: 35, CLASS_HARVESTER: 40}
WANT_HARVESTERS = 2

#  How long a rebuilding run stays after it could have left, in EMULATOR
#  frames. Past the first attack wave on purpose: mining is what pays for the
#  ships and loitering is what the waves charge for, so a linger that stopped
#  short of 600 game frames would be measuring the income without the bill.
LINGER = 5000
#  src/game/shipclass.asm. All eight of section 8's classes exist now, so a
#  run that spends its RU can show up as any of them.
NAMES = {0: "int", 1: "moth", 2: "harv", 3: "scout",
         4: "bomb", 5: "frig", 6: "salv", 7: "dest"}

s = h.symbols()
c = h.boot_quick(frames=300)
E = s["ENTITIES"]
#  Out of the build. It was 48 and the fleet's ceiling has since doubled, so a
#  fixed count stops looking exactly where the new slots are -- and this script
#  is a MEASURING tool, so it would have gone on printing a plausible campaign
#  with ships missing from it.
ENT_MAX = s["ENT_MAX"]
MIS_COUNT = s["MIS_COUNT"]


def fleet():
    friendly, enemy, hull = {}, 0, 0
    for i in range(ENT_MAX):
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


def treasury():
    return int.from_bytes(c.read_ram(s["ECO_RU"], 2), "little")


def hold(key, frames=25, release=12):
    c.key_down(key)
    c.run_frames(frames)
    c.key_up(key)
    c.run_frames(release)


#  eco_build_pick is an INDEX INTO eco_build_order, which is the buildable
#  classes CHEAPEST FIRST -- not a class number. Poking it with a class number
#  bought whatever happened to be that far up the price list, so a run that
#  asked for interceptors came home with thirty-two scouts and the fleet column
#  said so in plain sight for a whole campaign before anybody read it.
#
#  Read out of the machine rather than mirrored, because the order is a
#  function of the prices and the prices are section 8's to change.
PICK_OF = {cls: i for i, cls in
           enumerate(h.read_bank4(c, s["ECO_BUILD_ORDER"], 7))}


def order(ship_class):
    """Queue one ship of `ship_class`, by opening the panel and pressing ENTER.

    The PICK is poked rather than walked with `,`/`.`: the list steps over the
    classes that are not unlocked yet, so which key presses reach which class
    is a function of how far the campaign has got. eco_queue re-checks the pick
    itself, so a poke cannot buy something the yard would refuse.
    """
    import cpc
    hold("b")
    c.write_ram(s["ECO_BUILD_PICK"], bytes([PICK_OF[ship_class]]))
    hold(cpc.KEY_ENTER)
    hold("b")                               # ...and shut the panel again


def spend():
    """The dullest policy there is: two harvesters, then interceptors."""
    if not REBUILD:
        return
    live, _, _ = fleet()
    want = (CLASS_HARVESTER if live.get(CLASS_HARVESTER, 0) < WANT_HARVESTERS
            else CLASS_INTERCEPTOR)
    if treasury() < COST[want]:
        return
    if c.read_ram(s["ECO_QUEUE_LEN"], 1)[0] >= 9:
        return
    order(want)


def show(d):
    return " ".join(f"{NAMES.get(k, k)}={v}" for k, v in sorted(d.items()))


print(f"tactic: {'station + A + rebuild' if REBUILD else 'station + A'}")
print(f"{'mis':>3} {'enemy':>5} {'in':>3} {'out':>3} {'lost':>4}  {'hull':>5}  fleet")
for mission in range(MIS_COUNT):
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

    if REBUILD:
        hold("h")                           # whatever harvesters there are

    frames = 0
    while frames < 9000:
        c.run_frames(60)
        frames += 60
        if c.read_ram(s["MIS_COMPLETE"], 1)[0] or c.read_ram(s["MIS_FAILED"], 1)[0]:
            break

    #  ...and then stay, if that is the tactic. Everything below is the second
    #  half of the mission a rebuilding player actually plays.
    lingered = 0
    while (REBUILD and lingered < LINGER
           and not c.read_ram(s["MIS_FAILED"], 1)[0]):
        c.run_frames(120)
        lingered += 120
        spend()
        hold("h")                           # ...including anything delivered

    after, enemy_left, hull_after = fleet()
    failed = c.read_ram(s["MIS_FAILED"], 1)[0]
    ru = treasury()
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
    if mission < MIS_COUNT - 1:
        h.jump_mission(c)

h.close(c)
