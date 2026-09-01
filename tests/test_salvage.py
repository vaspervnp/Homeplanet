"""The Salvage Corvette's job: "ρυμουλκεί εχθρικά ναυάγια στο Mothership".

WHY NONE OF THIS COUNTS ANYTHING
--------------------------------
"The RU went up" is the assertion this feature would survive being completely
broken by. It is true of a corvette that never moves and a wreck that is paid
for where it lies; it is true of a delivery made by an interceptor; it is true
if the hull is cashed in the instant it is crippled. Counting is this project's
recurring blind spot -- the squadron tests that counted ships while they went
to the wrong squadrons, the combat tests that counted kills while the fleet was
stranded four thousand units from home -- and the answer both times was to
follow individual entities BY SLOT and ask where they are.

So: every test below names slots. The wreck is a slot, the corvette is a slot,
and what is asserted is that THAT corvette moved to THAT wreck, that the wreck
moved with it, that both of them ended up on the Mothership, and that the money
arrived at the moment the wreck's slot was freed and not before.

HOW A WRECK IS MADE, AND WHY IT IS NOT POKED
--------------------------------------------
The tests do not write ENT_F_DISABLED. They put a corvette in the fleet, put a
hostile in front of the guns and let the game cripple it -- because the
condition that decides whether a wreck happens at all (is a corvette flying?)
is the whole safety argument, and a test that pokes the flag is blind to it.
TestNoCorvetteNoWrecks is the other half of that, and it is the one that says a
player who has not bought into this is exactly where they were.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

#  Mirrored from src/game/entity.asm
ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walked a fixed forty-eight would
#  stop looking exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_X, ENT_CLASS, ENT_HULL, ENT_FLAGS = 0, 9, 10, 11
ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_TOW, ENT_TIMER = 12, 13, 14, 16, 19
F_ACTIVE, F_ENEMY, F_DISABLED, F_WAVE = 1, 2, 4, 8
ORDER_IDLE, ORDER_ATTACK, ORDER_HARVEST, ORDER_TOW = 0, 2, 4, 6
NO_TARGET = 0xFF

#  src/game/shipclass.asm and src/game/classdata.asm
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP, CLASS_SALVAGE = 0, 1, 6
COST_INTERCEPTOR, COST_SALVAGE = 35, 90

#  src/game/salvage.asm
WRECK_MAX = 4


class SalvageFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)
        self.E = self.sym["ENTITIES"]

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading ------------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def ent(self, slot, offset):
        return self.c.read_ram(self.E + slot * ENT_SIZE + offset, 1)[0]

    def set_ent(self, slot, offset, value):
        self.c.write_ram(self.E + slot * ENT_SIZE + offset, bytes([value]))

    def pos(self, slot):
        base = self.E + slot * ENT_SIZE
        return tuple(int.from_bytes(self.c.read_ram(base + i * 2, 2), "little", signed=True)
                     for i in range(3))

    def set_pos(self, slot, xyz):
        base = self.E + slot * ENT_SIZE
        for i, v in enumerate(xyz):
            self.c.write_ram(base + i * 2, int(v).to_bytes(2, "little", signed=True))

    def ru(self):
        return int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")

    def active(self):
        return {s for s in range(ENT_MAX) if self.ent(s, ENT_FLAGS) & F_ACTIVE}

    def wrecks(self):
        return {s for s in range(ENT_MAX)
                if (self.ent(s, ENT_FLAGS) & (F_ACTIVE | F_ENEMY | F_DISABLED))
                == (F_ACTIVE | F_ENEMY | F_DISABLED)}

    def free_slot(self):
        """A free slot in the HOSTILE region, because that is what this is for.

        It used to search from zero, and every caller here is spawning a
        Vekhar. That was harmless while cbt_find_enemy swept the whole table
        and rejected the wrong side on a compare; it searches the OTHER SIDE'S
        REGION now, so a hostile parked among the fleet is one nothing can see
        -- invisible, and it looks like the guns not working.
        """
        for s in range(self.sym["ENT_PLAYER_MAX"], ENT_MAX):
            if not (self.ent(s, ENT_FLAGS) & F_ACTIVE):
                return s
        self.fail("the hostile region is full")

    def moth(self):
        return self.byte("MOTH_SLOT")

    @staticmethod
    def apart(a, b):
        return sum(abs(p - q) for p, q in zip(a, b))

    # -- pressing -----------------------------------------------------------
    def hold(self, key, frames=25):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        #  Long enough for key_scan to see the release: every command is
        #  edge-triggered and a game frame is about ten emulator frames.
        self.c.run_frames(30)

    # -- arranging ----------------------------------------------------------
    def make_corvette(self, near=None):
        """Turn one of the fleet's interceptors into a Salvage Corvette.

        Converted rather than BUILT: the yard takes 90 game frames over a
        corvette, which is most of a minute of emulated time, and the build
        queue is not what is under test here. TestBuyingOne is where the yard
        is exercised.

        Returns its slot.
        """
        moth = self.moth()
        slot = next(s for s in sorted(self.active())
                    if s != moth and self.ent(s, ENT_CLASS) == CLASS_INTERCEPTOR)
        self.set_ent(slot, ENT_CLASS, CLASS_SALVAGE)
        self.set_ent(slot, ENT_HULL, 220)
        self.set_ent(slot, ENT_TOW, NO_TARGET)
        if near is not None:
            self.set_pos(slot, near)
        return slot

    def strip_the_fleet(self, keep):
        """Leave only `keep` (plus the Mothership) flying.

        The starting fleet is fifteen interceptors and they kill a lone
        hostile in a couple of frames from wherever they happen to be, which
        makes "did THIS corvette do it" unanswerable. So the tests that follow
        one ship take the crowd off the board first.
        """
        moth = self.moth()
        for s in list(self.active()):
            if s in keep or s == moth:
                continue
            self.set_ent(s, ENT_FLAGS, 0)
        self.c.run_frames(4)

    def spawn_hostile(self, xyz, hull=8):
        """A Vekhar interceptor, placed, and soft enough to die quickly.

        ENT_TIMER is zeroed and that is not tidiness: the slot is a RECYCLED
        one, the timer is a weapon cooldown in game frames, and a stale 200
        left there by whatever died in this slot last is twenty seconds of a
        hostile that never fires. It cost an afternoon once already.
        """
        slot = self.free_slot()
        self.set_pos(slot, xyz)
        self.set_ent(slot, ENT_CLASS, CLASS_INTERCEPTOR)
        self.set_ent(slot, ENT_HULL, hull)
        self.set_ent(slot, ENT_SQUAD, 0)
        self.set_ent(slot, ENT_ORDER, ORDER_IDLE)
        self.set_ent(slot, ENT_TARGET, NO_TARGET)
        self.set_ent(slot, ENT_TIMER, 0)
        self.set_ent(slot, ENT_FLAGS, F_ACTIVE | F_ENEMY)
        return slot

    def cripple_one(self, corvette, where=None, hull=8, frames=900):
        """Put a hostile in front of the guns and wait for it to become a wreck.

        Returns its slot. The flag is never poked: whether a kill leaves a
        wreck at all is the decision under test, so it has to be the game that
        makes one.
        """
        moth = self.moth()
        where = where or self.pos(moth)
        victim = self.spawn_hostile(where, hull=hull)
        for _ in range(frames // 30):
            self.c.run_frames(30)
            if victim in self.wrecks():
                return victim
        self.fail(f"slot {victim} never became a wreck "
                  f"(flags {self.ent(victim, ENT_FLAGS):#04x}, "
                  f"corvette {corvette} class {self.ent(corvette, ENT_CLASS)})")


class TestWhatMakesAWreck(SalvageFixture):
    """Which kills leave a hull behind, and which do not."""

    def test_a_hostile_killed_with_a_corvette_in_the_fleet_leaves_a_wreck(self):
        corvette = self.make_corvette()
        victim = self.cripple_one(corvette)
        flags = self.ent(victim, ENT_FLAGS)
        self.assertTrue(flags & F_ACTIVE, "the wreck's slot was freed")
        self.assertTrue(flags & F_ENEMY,
                        "the wreck stopped being hostile, so it would count "
                        "towards the fleet's own hull and scale the waves up")
        self.assertTrue(flags & F_DISABLED, "the hull is not marked crippled")
        self.assertEqual(self.ent(victim, ENT_HULL), 0)
        self.assertEqual(self.ent(victim, ENT_TARGET), NO_TARGET,
                         "the wreck kept the ship it was aiming at")

    def test_no_more_than_four_hulls_are_ever_adrift(self):
        """The cap is the frame budget, not a difficulty knob: a wreck is a
        whole entity through project, sort and draw.

        Past the cap a kill goes back to being an ordinary kill, which is the
        half that matters: the alternative to a cap is not "no wrecks", it is
        a twelve-ship picket leaving twelve of them.
        """
        corvette = self.make_corvette()
        moth = self.pos(self.moth())
        for n in range(WRECK_MAX):
            self.cripple_one(corvette, where=moth)
            self.assertEqual(len(self.wrecks()), n + 1,
                             f"{len(self.wrecks())} hulls adrift after {n + 1} kills")

        for n in range(3):
            victim = self.spawn_hostile(moth, hull=8)
            for _ in range(30):
                self.c.run_frames(30)
                if not (self.ent(victim, ENT_FLAGS) & F_ACTIVE):
                    break
            else:
                self.fail(f"the {n + 1}th hostile past the cap never died")
            self.assertEqual(len(self.wrecks()), WRECK_MAX,
                             "a kill past the cap still left a hull")

    def test_the_fleets_own_losses_leave_nothing(self):
        """Section 1: what is lost is lost. A fleet that could salvage itself
        would undo the one claim the whole campaign rests on."""
        corvette = self.make_corvette()
        moth = self.moth()
        doomed = next(s for s in sorted(self.active())
                      if s not in (moth, corvette))
        #  The duel has to be ARRANGED, and every line of it is load-bearing.
        #  Left to itself the fleet -- or even the Mothership alone, at 40 hull
        #  a shot -- cripples the hostile long before it can land one, which is
        #  the feature working and says nothing about our own losses. So: the
        #  two of them alone, ten thousand units from the Mothership and the
        #  corvette so neither is in range of anything; the hostile aimed and
        #  its cooldown clear so it fires on its first update; and ours held off
        #  the trigger long enough that it cannot win the exchange.
        self.strip_the_fleet({corvette, doomed})
        away = tuple(v + 10000 for v in self.pos(moth))
        self.set_pos(doomed, away)
        self.set_ent(doomed, ENT_HULL, 4)
        self.set_ent(doomed, ENT_ORDER, ORDER_ATTACK)   # so phase4_fly leaves it
        self.set_ent(doomed, ENT_TIMER, 250)
        enemy = self.spawn_hostile(away, hull=255)
        self.set_ent(enemy, ENT_TARGET, doomed)

        for _ in range(40):
            self.c.run_frames(30)
            self.assertFalse(self.ent(doomed, ENT_FLAGS) & F_DISABLED,
                             "one of our own was crippled rather than destroyed")
            if not (self.ent(doomed, ENT_FLAGS) & F_ACTIVE):
                break
        else:
            self.fail(f"slot {doomed} never died (enemy {enemy}, "
                      f"hull {self.ent(enemy, ENT_HULL)})")

        self.assertEqual(self.ent(doomed, ENT_FLAGS), 0,
                         "a friendly loss left something behind")
        self.assertEqual(self.wrecks(), set(), "our own loss became a wreck")
        #  ...and the corvette was there throughout, so "no wreck" is a
        #  statement about the side that died and not about the fleet.
        self.assertTrue(self.ent(corvette, ENT_FLAGS) & F_ACTIVE)


class TestNoCorvetteNoWrecks(SalvageFixture):
    """A player who has not built one is exactly where they were.

    This is the whole safety argument for the feature, stated as a test. A
    wreck is an ACTIVE entity: it holds a slot, and it is projected, sorted and
    drawn every frame. Wrecks nobody can tow would be a frame-rate bill charged
    to a player who never opted in.
    """

    def test_a_fleet_with_no_corvette_leaves_no_hulls(self):
        self.assertEqual(
            [s for s in self.active() if self.ent(s, ENT_CLASS) == CLASS_SALVAGE],
            [], "the starting fleet already has a corvette")
        victim = self.spawn_hostile(self.pos(self.moth()), hull=8)
        for _ in range(30):
            self.c.run_frames(30)
            if not (self.ent(victim, ENT_FLAGS) & F_ACTIVE):
                break
        else:
            self.fail("the hostile never died")
        self.assertEqual(self.wrecks(), set(),
                         "a fleet with no salvage ship left a hull adrift")

    def test_the_last_hostile_dying_still_completes_a_clear_mission(self):
        """The trap this feature could have walked into, from the side where
        it does not even apply. mis_count_enemies counts ACTIVE+ENEMY; if the
        DISABLED bit were not in its mask a wreck would keep a CLEAR objective
        open for ever. Here there is no corvette and so no wreck, which is the
        control for the test of the same name below."""
        h.jump_mission(self.c)
        h.jump_mission(self.c)                      # mission 3: the first fight
        for _ in range(60):
            self.c.run_frames(30)
            if self.byte("MIS_COMPLETE"):
                return
        self.fail("mission 3 never completed with no wrecks in play")


class TestACrippledHullIsNotAShip(SalvageFixture):
    """Four things a wreck must not do, each of which lives in a different
    routine. Every one of them was a real hazard before it was a test."""

    def test_it_does_not_keep_a_clear_mission_open(self):
        """The one that would have made this feature actively hostile: a
        player who built a corvette would be trapped in the mission, `J` never
        offered, because the hull they crippled still counted as a hostile."""
        h.jump_mission(self.c)
        h.jump_mission(self.c)                      # mission 3: MIS_OBJ_CLEAR
        corvette = self.make_corvette()
        for _ in range(80):
            self.c.run_frames(30)
            if self.byte("MIS_COMPLETE"):
                break
        else:
            self.fail(f"mission 3 never completed; {len(self.wrecks())} hulls adrift")
        self.assertGreater(len(self.wrecks()), 0,
                           "no wreck was ever made, so the mask was never tested")

    def test_it_is_not_shot_at(self):
        """A wreck that still read as a target would be destroyed by the next
        volley, and the tow would be a race the fleet always won."""
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        wreck = self.cripple_one(corvette, where=self.pos(self.moth()))
        #  Put the guns back and sit on it. The Mothership alone fires 40 a hit.
        self.c.run_frames(600)
        self.assertIn(wreck, self.wrecks(),
                      "the fleet shot the wreck it was supposed to be towing")
        for s in self.active():
            self.assertNotEqual(self.ent(s, ENT_TARGET), wreck,
                                f"slot {s} is still aiming at the wreck")

    def test_it_does_not_fire(self):
        """It keeps the target it was aiming at when it died, and the side it
        was on, so nothing but the ACTIVE+DISABLED test in cbt_update stops it
        going on shooting at the fleet that crippled it."""
        corvette = self.make_corvette()
        wreck = self.cripple_one(corvette)
        #  Aim it back at one of ours and watch that ship's hull.
        target = next(s for s in sorted(self.active())
                      if s != self.moth() and s not in self.wrecks())
        self.set_ent(wreck, ENT_TARGET, target)
        self.set_pos(wreck, self.pos(target))
        self.set_ent(target, ENT_HULL, 200)
        before = self.ent(target, ENT_HULL)
        self.c.run_frames(400)
        self.assertGreaterEqual(self.ent(target, ENT_HULL), before,
                                "the wreck went on firing")

    def test_it_does_not_move_itself(self):
        """cbt_move_enemies closes anything hostile on its target. A wreck
        drifts; the only thing that moves it is a tow."""
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        wreck = self.cripple_one(corvette, where=self.pos(self.moth()))
        #  Give it a target far away, which is what would make it fly.
        self.set_pos(wreck, (9000, 0, 9000))
        self.set_ent(wreck, ENT_TARGET, self.moth())
        #  ...and take the corvette off it, so nothing is towing.
        self.set_ent(corvette, ENT_ORDER, ORDER_IDLE)
        self.set_ent(corvette, ENT_TOW, NO_TARGET)
        where = self.pos(wreck)
        self.c.run_frames(400)
        self.assertEqual(self.pos(wreck), where,
                         "the wreck flew off under its own power")

    def test_it_is_not_part_of_the_fleets_hull(self):
        """wave_hull is what the attack waves are sized against. A captured
        enemy hull counting towards it would make the next wave BIGGER, which
        is the opposite of a reward -- and it is free to get right only because
        the wreck keeps ENT_F_ENEMY."""
        corvette = self.make_corvette()
        before = int.from_bytes(self.c.read_ram(self.sym["WAVE_HULL"], 2), "little")
        self.cripple_one(corvette)
        self.c.run_frames(60)                       # WAVE_READ_EVERY is 4 game frames
        after = int.from_bytes(self.c.read_ram(self.sym["WAVE_HULL"], 2), "little")
        self.assertLessEqual(after, before,
                             "crippling an enemy added to the fleet's own hull")


class TestTheFleetStillComesHome(SalvageFixture):
    """The bug CLAUDE.md spends a section on, arriving by a new road.

    phase4_fly skips a ship under an ATTACK order so cbt_move_enemies can steer
    it; nothing else steers it. If a wreck read as something still worth
    shooting at, cbt_fire_if_able would never re-acquire, the order would never
    be spent, and the squadron would sit over the hull it made for the rest of
    the mission -- with fleet_save carrying those coordinates into the next.
    """

    def test_an_attack_order_is_spent_over_the_wreck_it_made(self):
        corvette = self.make_corvette()
        moth = self.moth()
        station = self.pos(moth)
        far = (station[0] + 6000, station[1], station[2] + 6000)
        victim = self.spawn_hostile(far, hull=60)

        self.hold(",")                              # walk the target...
        self.hold("a")                              # ...and send the squadron
        attackers = [s for s in sorted(self.active())
                     if self.ent(s, ENT_ORDER) == ORDER_ATTACK]
        self.assertGreater(len(attackers), 1, "`A` gave nobody an attack order")

        for _ in range(60):
            self.c.run_frames(30)
            if victim in self.wrecks():
                break
        else:
            self.fail("the hostile was never crippled")

        self.c.run_frames(900)
        still_attacking = [s for s in attackers
                           if self.ent(s, ENT_ORDER) == ORDER_ATTACK]
        self.assertEqual(still_attacking, [],
                         "the attack order was never spent over the wreck")
        stranded = {s: self.apart(self.pos(s), station) for s in attackers
                    if self.ent(s, ENT_FLAGS) & F_ACTIVE
                    and self.apart(self.pos(s), station) > 4000}
        self.assertEqual(stranded, {},
                         "ships are still parked where the wreck was made")


class TestTheTow(SalvageFixture):
    """The journey, followed by slot from one end to the other."""

    def arrange_one_tow(self, out=9000):
        """A lone corvette, a lone wreck some way off, and the order given.

        Returns (corvette slot, wreck slot). The rest of the fleet is taken
        off the board so that "the corvette went and got it" is a statement
        about one ship.
        """
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        moth = self.pos(self.moth())
        wreck = self.cripple_one(corvette, where=moth)
        #  Move the hull out to where it has to be fetched from, AFTER it has
        #  been made -- the corvette has to be near the kill to make one.
        self.set_pos(wreck, (moth[0] + out, moth[1], moth[2] + out))
        self.hold("t")
        return corvette, wreck

    def test_t_only_orders_the_corvettes(self):
        """Section 9 marks `H` "(harvesters)" for the reason this mirrors:
        sending fifteen interceptors to stand over a hull none of them can tow
        is the same mistake as sending them to a resource patch.

        There has to be a hull adrift for the order to still be there when it
        is read: with nothing to fetch, slv_tow_step spends the order on the
        very next frame, which is a different test two classes down.
        """
        corvette = self.make_corvette()
        moth = self.pos(self.moth())
        wreck = self.cripple_one(corvette, where=moth)
        self.set_pos(wreck, (moth[0] + 9000, moth[1], moth[2] + 9000))
        self.hold("t")
        towing = [s for s in sorted(self.active())
                  if self.ent(s, ENT_ORDER) == ORDER_TOW]
        self.assertEqual(towing, [corvette],
                         "`T` ordered something that is not a salvage corvette")

    def test_t_leaves_another_squadron_alone(self):
        corvette = self.make_corvette()
        self.cripple_one(corvette, where=self.pos(self.moth()))
        self.set_ent(corvette, ENT_SQUAD, 5)
        self.c.run_frames(20)
        self.hold("t")
        self.assertNotEqual(self.ent(corvette, ENT_ORDER), ORDER_TOW,
                            "`T` ordered a corvette in a squadron that is not selected")

    def test_the_corvette_flies_to_the_wreck_and_takes_hold_of_it(self):
        corvette, wreck = self.arrange_one_tow()
        started = self.apart(self.pos(corvette), self.pos(wreck))
        self.assertGreater(started, 4000, "the two were not far enough apart to prove anything")

        for _ in range(60):
            self.c.run_frames(30)
            if self.ent(corvette, ENT_TOW) == wreck:
                break
        else:
            self.fail(f"the corvette never took hold: ENT_TOW is "
                      f"{self.ent(corvette, ENT_TOW)}, "
                      f"{self.apart(self.pos(corvette), self.pos(wreck))} units apart")
        self.assertLess(self.apart(self.pos(corvette), self.pos(wreck)), 2000,
                        "it took hold of a wreck it had not reached")

    def test_the_wreck_is_dragged_rather_than_left_where_it_was(self):
        """Two positions, both followed by slot: the hull has to MOVE, and it
        has to move with the ship that has hold of it. A wreck paid for where
        it lies passes every test that reads RU."""
        corvette, wreck = self.arrange_one_tow(out=14000)
        for _ in range(90):
            self.c.run_frames(10)
            if self.ent(corvette, ENT_TOW) == wreck:
                break
        else:
            self.fail("the corvette never took hold")

        picked_up_at = self.pos(wreck)
        self.c.run_frames(120)
        self.assertIn(wreck, self.wrecks(), "the wreck was delivered too early to watch")
        self.assertNotEqual(self.pos(wreck), picked_up_at, "the wreck was left behind")
        self.assertLess(self.apart(self.pos(wreck), self.pos(corvette)), 400,
                        "the wreck is not with the ship towing it")
        self.assertLess(self.apart(self.pos(wreck), self.pos(self.moth())),
                        self.apart(picked_up_at, self.pos(self.moth())),
                        "the tow is not heading for the Mothership")

    def test_it_ends_at_the_mothership_and_pays_there(self):
        """The money and the place, in one assertion each, and the ORDER of
        them: the slot is freed and the RU arrives together, at the Mothership
        and not before."""
        corvette, wreck = self.arrange_one_tow()
        before = self.ru()

        for _ in range(120):
            self.c.run_frames(30)
            if wreck not in self.wrecks():
                break
            self.assertEqual(self.ru(), before,
                             "the yard paid for a hull that is still adrift")
        else:
            self.fail("the wreck was never delivered")

        self.assertEqual(self.ent(wreck, ENT_FLAGS), 0, "the wreck's slot was not freed")
        self.assertEqual(self.ru(), before + COST_INTERCEPTOR,
                         "an interceptor hull did not pay an interceptor's price")
        self.assertLess(self.apart(self.pos(corvette), self.pos(self.moth())), 2500,
                        "the hull was cashed in somewhere other than the Mothership")
        self.assertEqual(self.ent(corvette, ENT_TOW), NO_TARGET,
                         "the corvette still thinks it is holding something")

    def test_two_hulls_are_fetched_one_after_the_other(self):
        """One trip could be an accident of where things happened to be. Two
        means the corvette goes back out."""
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        moth = self.pos(self.moth())
        first = self.cripple_one(corvette, where=moth)
        second = self.cripple_one(corvette, where=moth)
        for w, d in ((first, 4000), (second, 5000)):
            self.set_pos(w, (moth[0] + d, moth[1], moth[2] - d))
        self.hold("t")

        before = self.ru()
        for _ in range(200):
            self.c.run_frames(30)
            if not self.wrecks():
                break
        else:
            self.fail(f"only {2 - len(self.wrecks())} of two hulls came home")
        self.assertEqual(self.ru(), before + 2 * COST_INTERCEPTOR,
                         "two hulls did not pay for two hulls")

    def test_the_order_is_spent_when_there_is_nothing_left_to_fetch(self):
        """The same shape as the attack order, and the same bug if it is
        missed: phase4_fly skips a towing ship, so a corvette under an order it
        can never satisfy is steered by nobody and stops dead for the rest of
        the mission -- with fleet_save carrying that into the next one."""
        corvette = self.make_corvette()
        self.assertEqual(self.wrecks(), set())
        self.hold("t")
        self.c.run_frames(60)
        self.assertEqual(self.ent(corvette, ENT_ORDER), ORDER_IDLE,
                         "a tow order with nothing to tow was not spent")

    def test_a_corvette_with_nothing_to_do_goes_back_to_its_formation(self):
        """The other half of the above, and the half that a flag cannot show.
        An unsteered ship is one that never comes home."""
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        station = self.pos(self.moth())
        self.set_pos(corvette, (station[0] + 7000, station[1], station[2] + 7000))
        self.hold("t")
        self.c.run_frames(900)
        self.assertLess(self.apart(self.pos(corvette), station), 4000,
                        "the corvette was left stranded where the order found it")

    def test_a_stale_tow_index_does_not_teleport_a_hull(self):
        """ENT_TOW is a slot index and a slot index names something whatever is
        in it. A corvette that believed a stale byte would drag a hull on the
        far side of the map onto itself the first frame it was ordered out."""
        corvette = self.make_corvette()
        self.strip_the_fleet({corvette})
        moth = self.pos(self.moth())
        wreck = self.cripple_one(corvette, where=moth)
        far = (moth[0] + 12000, moth[1], moth[2] + 12000)
        self.set_pos(wreck, far)
        #  Plant the lie, and put the corvette nowhere near it.
        self.set_ent(corvette, ENT_TOW, wreck)
        self.set_pos(corvette, moth)
        self.hold("t")
        self.c.run_frames(20)
        self.assertGreater(self.apart(self.pos(wreck), moth), 8000,
                           "the wreck was teleported to the corvette")


class TestBuyingOne(SalvageFixture):
    """The yard end of it: 90 RU has to be a purchase somebody would make."""

    def test_a_corvette_can_be_ordered_and_costs_what_section_8_says(self):
        self.c.write_ram(self.sym["ECO_RU"], (500).to_bytes(2, "little"))
        self.hold("b")
        order = list(h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"], 7))
        want = order.index(CLASS_SALVAGE)
        for _ in range(len(order)):
            if self.byte("ECO_BUILD_PICK") == want:
                break
            self.hold(".", frames=20)
        self.assertEqual(self.byte("ECO_BUILD_PICK"), want,
                         "the panel would not walk round to the corvette")
        before = self.ru()
        self.hold(cpc.KEY_ENTER, frames=25)
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_SALVAGE)
        self.assertEqual(self.ru(), before - COST_SALVAGE)

    def test_three_hulls_pay_for_the_ship_that_fetched_them(self):
        """The whole economic claim, measured rather than asserted in prose.
        90 RU against an interceptor's 35 is only a sensible purchase if the
        corvette earns its price back inside a mission, and a mission fields
        four to twelve hostiles."""
        self.assertGreaterEqual(3 * COST_INTERCEPTOR, COST_SALVAGE,
                                "three interceptor hulls do not pay for a corvette")
        #  ...and the payout is really the class's build price, read off the
        #  machine rather than copied out of the source.
        costs = h.read_bank4(self.c, self.sym["ECO_CLASS_COST"], 8)
        self.assertEqual(costs[CLASS_INTERCEPTOR], COST_INTERCEPTOR)
        self.assertEqual(costs[CLASS_SALVAGE], COST_SALVAGE)


class TestItStaysOutOfTheHarvestersWay(SalvageFixture):
    """Both work orders come out of one loop now. Neither may catch the other's
    ships -- the failure mode is silent, because both leave the formation and
    both fly somewhere."""

    def test_h_does_not_order_the_corvettes(self):
        corvette = self.make_corvette()
        self.hold("h")
        self.assertNotEqual(self.ent(corvette, ENT_ORDER), ORDER_HARVEST,
                            "`H` sent a salvage corvette to mine")

    def test_a_harvester_still_mines_with_a_corvette_in_the_fleet(self):
        """The control for the above: eco_run_workers dispatches on ENT_ORDER,
        so a mistake there stops the economy rather than breaking salvage."""
        corvette = self.make_corvette()
        moth = self.moth()
        slot = next(s for s in sorted(self.active())
                    if s not in (moth, corvette))
        self.set_ent(slot, ENT_CLASS, 2)            # CLASS_HARVESTER
        self.hold("h")
        self.assertEqual(self.ent(slot, ENT_ORDER), ORDER_HARVEST)

        before = self.ru()
        for _ in range(14):
            self.c.run_frames(200)
            if self.ru() > before:
                return
        self.fail("no resources came back with a corvette in the fleet")


if __name__ == "__main__":
    unittest.main()
