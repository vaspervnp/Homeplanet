"""The vortex chase between the jumps, and what losing it costs.

src/game/minigame.asm. Four things are being asserted here and they are
deliberately tested in two different ways, because they fail differently:

  * THE PENALTY -- how many ships, which ones, and that the Mothership is
    never one of them. Driven by CALLING mini_penalty from a poked stub, which
    is this project's cheapest real unit test (see harness.STUB and
    test_fill_rect_honours_width_and_height): the fleet is arranged exactly,
    the answer is read exactly, and nothing takes four minutes of emulated
    time to arrange.

  * THE CHASE ITSELF -- when it happens, and whether the cursor keys move the
    thing they are supposed to move. That cannot be poked: it is a keypress
    reaching a loop that is running inside mis_jump_now, so it is played, on
    the machine, by walking the campaign to the jump that has one.

minigame.md predicted the shape of the test that would look like coverage and
would not be any: "did the chase end", "was the enemy caught" and "how many
frames did it take" are all preserved by a build where the steering does
nothing. So TestSteering reads the LATERAL OFFSETS frame by frame and asserts
the gap responds to the key -- the same lesson as following squadrons by slot.
"""

import struct
import unittest

from tests import harness as h
from tests.harness import cpc

ENT_SIZE = 20
ENT_CLASS = 9
ENT_HULL = 10
ENT_FLAGS = 11
ENT_SQUAD = 12
ENT_TARGET = 14

F_ACTIVE = 0x01

CLASS_INTERCEPTOR = 0
CLASS_MOTHERSHIP = 1


class MiniFixture(unittest.TestCase):
    """One machine for the whole class; the fleet is rearranged per test."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.c = h.machine() if hasattr(h, "machine") else h.boot_quick(frames=300)

    @classmethod
    def tearDownClass(cls):
        h.close(cls.c)

    # -- reading and writing ------------------------------------------------
    def b(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def poke(self, name, value):
        self.c.write_ram(self.sym[name], bytes([value]))

    def ent(self, slot, off):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, 1)[0]

    def poke_ent(self, slot, off, value):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off,
                         bytes([value]))

    def call(self, name):
        """Poke a stub that CALLs a routine and halts, and run it.

        The chase runs FROM BANK 7 (see chase_run), so the stub pages it in
        before the call and leaves it in afterwards.
        """
        #  BANK 7 IN FIRST: the chase runs from there now, and so does its
        #  state -- and it is LEFT in, so that the reads that follow see it.
        self.c.write_ram(h.STUB, bytes([0xF3,                    # di
                                        0x01, 0xC7, 0x7F,        # ld bc,#7FC7
                                        0xED, 0x49,              # out (c),c
                                        0xCD]) + struct.pack("<H", self.sym[name])
                         + bytes([0x76]))                        # halt
        self.c.set_pc(h.STUB)
        self.c.run_frames(6)

    # -- arranging a fleet --------------------------------------------------
    def lay_out(self, hulls, mothership=None):
        """Wipe the player's region and put `hulls` in slots 0..n-1.

        `mothership` is the slot that gets CLASS_MOTHERSHIP, or None for a
        fleet with none at all. Returns nothing: the tests read slots back.
        """
        for slot in range(self.sym["ENT_PLAYER_MAX"]):
            self.poke_ent(slot, ENT_FLAGS, 0)
        for slot, hull in enumerate(hulls):
            base = self.sym["ENTITIES"] + slot * ENT_SIZE
            self.c.write_ram(base, struct.pack("<hhh", 0, 0, 0))
            klass = (CLASS_MOTHERSHIP if slot == mothership
                     else CLASS_INTERCEPTOR)
            self.poke_ent(slot, ENT_CLASS, klass)
            self.poke_ent(slot, ENT_HULL, hull)
            self.poke_ent(slot, ENT_SQUAD, 0 if slot == mothership else 1)
            self.poke_ent(slot, ENT_TARGET, 0xFF)
            self.poke_ent(slot, ENT_FLAGS, F_ACTIVE)

    def alive(self):
        return [s for s in range(self.sym["ENT_PLAYER_MAX"])
                if self.ent(s, ENT_FLAGS) & F_ACTIVE]

    def ambush(self, dist):
        """Run mini_penalty with `dist` left on the clock."""
        self.poke("MINI_DIST", dist)
        self.poke("MINI_LOST", 0)
        self.poke("MINI_FRAC", 0)
        self.call("MINI_PENALTY")


# ===========================================================================
#  The penalty: 10% to 50%, chosen by how close the chase got
# ===========================================================================
class TestWhatItCosts(MiniFixture):

    def test_the_worst_chase_costs_exactly_half_the_fleet(self):
        """dist untouched is MG_FRAC_MAX, and MG_FRAC_MAX is 128/256."""
        self.lay_out([255] * 17, mothership=16)
        self.ambush(self.sym["MG_DIST0"])
        self.assertEqual(self.b("MINI_FRAC"), self.sym["MG_FRAC_MAX"])
        #  Sixteen ships the ambush may take, half of them.
        self.assertEqual(self.b("MINI_LOST"), 8)
        self.assertEqual(len(self.alive()), 9)

    def test_the_best_chase_that_is_still_a_loss_costs_a_tenth(self):
        """One step short of the kill pays MG_FRAC_MIN, which is 10.2%."""
        self.lay_out([255] * 21, mothership=20)
        self.ambush(1)
        self.assertEqual(self.b("MINI_FRAC"), self.sym["MG_FRAC_MIN"] + 1)
        #  Twenty ships at 27/256 is 2.1, rounded to 2 -- ten per cent.
        self.assertEqual(self.b("MINI_LOST"), 2)

    def test_the_toll_never_leaves_the_ten_to_fifty_the_owner_asked_for(self):
        """Every distance the chase can end on, against a fleet of twenty."""
        for dist in range(1, self.sym["MG_DIST0"] + 1, 7):
            with self.subTest(dist=dist):
                self.lay_out([255] * 21, mothership=20)
                self.ambush(dist)
                lost = self.b("MINI_LOST")
                share = 100.0 * lost / 20
                self.assertGreaterEqual(
                    share, 9.0,
                    f"a failed chase at dist {dist} cost {lost} of 20 ships")
                self.assertLessEqual(
                    share, 51.0,
                    f"a failed chase at dist {dist} cost {lost} of 20 ships")

    def test_the_price_rises_with_the_distance_left(self):
        """It is a CURVE the player drove, not a roll: closer costs less."""
        seen = []
        for dist in (10, 40, 70, 102):
            self.lay_out([255] * 21, mothership=20)
            self.ambush(dist)
            seen.append(self.b("MINI_LOST"))
        self.assertEqual(seen, sorted(seen),
                         f"getting closer did not cost less: {seen}")
        self.assertLess(seen[0], seen[-1],
                        "every distance cost the same, so nothing is driving it")

    def test_it_is_deterministic(self):
        """Same chase, same fleet, same answer -- twice."""
        first = []
        for _ in range(2):
            self.lay_out([255] * 21, mothership=20)
            self.ambush(60)
            first.append((self.b("MINI_LOST"), tuple(self.alive())))
        self.assertEqual(first[0], first[1])


# ===========================================================================
#  Which ships, and the one that can never be taken
# ===========================================================================
class TestWhichShipsTheAmbushTakes(MiniFixture):

    def test_the_mothership_is_never_taken_even_when_it_is_the_weakest(self):
        """The rule is the CLASS, and this is the case that proves it.

        The ambush takes the most damaged ships first, so a Mothership at hull
        1 in a fleet of healthy interceptors is the FIRST thing a rule without
        the class test would reach for -- and section 8 makes losing it the end
        of the campaign. moth_slot is not consulted, deliberately:
        fleet_restore moves what it points at.
        """
        hulls = [255] * 8
        hulls[3] = 1
        self.lay_out(hulls, mothership=3)
        self.ambush(self.sym["MG_DIST0"])
        self.assertTrue(self.ent(3, ENT_FLAGS) & F_ACTIVE,
                        "the ambush took the Mothership")
        self.assertEqual(self.ent(3, ENT_CLASS), CLASS_MOTHERSHIP)
        #  ...and it is not merely alive: it was not counted either. Seven
        #  ships at half is three, not four.
        self.assertEqual(self.b("MINI_LOST"), 4)

    def test_a_fleet_of_nothing_but_the_mothership_loses_nothing(self):
        self.lay_out([255], mothership=0)
        self.ambush(self.sym["MG_DIST0"])
        self.assertEqual(self.b("MINI_LOST"), 0)
        self.assertEqual(self.alive(), [0])

    def test_the_wounded_go_first(self):
        """Followed BY SLOT, because a count is preserved by taking the wrong
        ships -- which is this project's oldest blind spot.

        Eight interceptors with hulls 10..80 and a Mothership. Half the fleet
        is four, and they have to be the four lowest hulls: slots 0, 1, 2, 3.
        """
        hulls = [10, 20, 30, 40, 50, 60, 70, 80, 255]
        self.lay_out(hulls, mothership=8)
        self.ambush(self.sym["MG_DIST0"])
        self.assertEqual(self.b("MINI_LOST"), 4)
        self.assertEqual(self.alive(), [4, 5, 6, 7, 8],
                         "the ambush did not take the four most damaged ships")

    def test_the_order_is_by_hull_and_not_by_slot(self):
        """The same fleet with the damage at the TOP of the region.

        A rule that walked the slots and took the first four would pass the
        test above and fail this one; that is the whole reason there are two.
        """
        hulls = [80, 70, 60, 50, 40, 30, 20, 10, 255]
        self.lay_out(hulls, mothership=8)
        self.ambush(self.sym["MG_DIST0"])
        self.assertEqual(self.b("MINI_LOST"), 4)
        self.assertEqual(self.alive(), [0, 1, 2, 3, 8],
                         "the ambush took slots rather than the wounded")


# ===========================================================================
#  Played, on the machine
# ===========================================================================
class ChaseFixture(unittest.TestCase):
    """Walk the campaign to the jump that has a chase in it."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.c = h.boot_quick(frames=300)
        #  Frozen, exactly as tests/test_regions.py walks the campaign: this
        #  is about the jump, not about whether the fleet survives the trip.
        cls.c.key_down(" ")
        cls.c.run_frames(25)
        cls.c.key_up(" ")
        cls.c.run_frames(25)

    @classmethod
    def tearDownClass(cls):
        h.close(cls.c)

    @classmethod
    def b(cls, name):
        return cls.c.read_ram(cls.sym[name], 1)[0]

    @classmethod
    def alive(cls):
        return [s for s in range(cls.sym["ENT_PLAYER_MAX"])
                if cls.c.read_ram(cls.sym["ENTITIES"] + s * ENT_SIZE
                                  + ENT_FLAGS, 1)[0] & F_ACTIVE]

    @classmethod
    def jump_and_watch(cls, drive=None, bound=3000):
        """Press J, let the spool run, and follow the chase frame by frame.

        `drive` is called with (x, ex) each frame and returns a key to hold,
        or None. It is how a test plays: the chase reads key_state, which the
        50 Hz scan keeps live, so a key held across frames simply steers.

        Returns the list of (x, ex, dist, left) readings.
        """
        h.clear_the_way_out(cls.c)
        #  THE FIRST CHASE OF A CAMPAIGN OPENS ON A PAGE THAT WAITS FOR ENTER.
        #  Whether this one will is decided BEFORE `J`, while the window is at
        #  rest: mini_shown is bank 4 and the chase blits, so it cannot be read
        #  reliably once the chase is running. The page is dismissed the moment
        #  the chase's flag goes up and nothing is traced until it has been, so
        #  trace[0] is still the chase's own first step.
        intro_due = not cls.c.read_ram(cls.sym["MINI_SHOWN"], 1)[0]    # low 16K now
        cls.c.key_down("j")
        cls.c.run_frames(40)
        cls.c.key_up("j")
        cls.c.run_frames(20)
        #  wait_out_the_countdown lifts a pause for the spool; do it by hand
        #  here because this wants to watch what happens inside the jump.
        cls.c.write_ram(cls.sym["ORDER_PAUSED"], b"\x00")

        held = None
        trace = []
        for _ in range(bound):
            cls.c.run_frames(1)
            if not cls.b("MINI_ACTIVE"):
                if trace:
                    break
                continue
            if intro_due:
                intro_due = False
                #  A few frames for the page to be on the screen before it is
                #  answered -- a human cannot press inside the first vsync, and
                #  a test that does is testing the paint order, not the page.
                cls.c.run_frames(8)
                cls.c.key_down(cpc.KEY_ENTER)
                cls.c.run_frames(6)
                cls.c.key_up(cpc.KEY_ENTER)
                cls.c.run_frames(2)
                continue
            x, ex = cls.b("MINI_X"), cls.b("MINI_EX")
            trace.append((x, ex, cls.b("MINI_DIST"), cls.b("MINI_LEFT")))
            if drive is None:
                continue
            want = drive(x, ex)
            if want != held:
                if held is not None:
                    cls.c.key_up(held)
                if want is not None:
                    cls.c.key_down(want)
                held = want
        if held is not None:
            cls.c.key_up(held)
        return trace

    @classmethod
    def walk_to_a_chase(cls):
        """Jump until the NEXT jump is one of the ones with a chase in it."""
        while (cls.b("MIS_INDEX") + 1) % cls.sym["MG_EVERY"]:
            cls.plain_jump()
            cls.c.write_ram(cls.sym["ORDER_PAUSED"], b"\x01")

    @classmethod
    def plain_jump(cls):
        h.clear_the_way_out(cls.c)
        was = cls.b("MIS_INDEX")
        cls.c.key_down("j")
        cls.c.run_frames(40)
        cls.c.key_up("j")
        cls.c.run_frames(40)
        h.dismiss_briefing(cls.c)
        cls.c.run_frames(60)
        h.wait_for_jump_wipe(cls.c)
        cls.c.run_frames(30)
        if cls.b("MIS_INDEX") != was + 1:
            raise AssertionError(
                "the jump was refused, so nothing after it means anything")


class TestTheIntro(ChaseFixture):
    """The page before the FIRST chase: what it is, which keys, and ENTER.

    "Πριν παίξει πρώτη φορά το minigame να δείχνεις τα πλήκτρα που χρειάζονται
    και να ξεκινάει με enter."

    Two chases on one machine, in order, because the claim has two halves and
    a build that showed the page before EVERY chase passes the first on its
    own: the first waits for ENTER and the second does not.
    """

    FIRST_CHAR, LAST_CHAR, CHAR_H = 32, 95, 8

    @classmethod
    def start_a_chase(cls):
        """J, the spool, and stop the instant the chase's flag goes up."""
        h.clear_the_way_out(cls.c)
        cls.c.key_down("j")
        cls.c.run_frames(40)
        cls.c.key_up("j")
        cls.c.run_frames(20)
        cls.c.write_ram(cls.sym["ORDER_PAUSED"], b"\x00")
        for _ in range(3000):
            cls.c.run_frames(1)
            if cls.b("MINI_ACTIVE"):
                return
        raise AssertionError("no chase started")

    @classmethod
    def finish_the_chase(cls):
        for _ in range(4000):
            cls.c.run_frames(2)
            if not cls.b("MINI_ACTIVE"):
                break
        h.dismiss_briefing(cls.c)
        cls.c.run_frames(40)
        h.wait_for_jump_wipe(cls.c)
        cls.c.run_frames(30)
        cls.c.write_ram(cls.sym["ORDER_PAUSED"], b"\x01")

    def row(self, y, x0, cells):
        """Text off the front buffer at (x0 bytes, y), from the machine's font.
        Stepped from x0 -- an odd column decoded from 0 reads as garbage."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (self.LAST_CHAR - self.FIRST_CHAR + 1) * self.CHAR_H))
        out = []
        for bx in range(x0, x0 + cells * 2, 2):
            cell = []
            for r in range(self.CHAR_H):
                a = ram[h.screen_offset(y + r, bx)]
                b = ram[h.screen_offset(y + r, bx + 1)]
                cell.append(((a | (a << 4)) & 0xF0) | (((b | (b << 4)) & 0xF0) >> 4))
            best, bd = " ", 999
            for ci in range(self.FIRST_CHAR, self.LAST_CHAR + 1):
                g = font[(ci - self.FIRST_CHAR) * self.CHAR_H:(ci - self.FIRST_CHAR + 1) * self.CHAR_H]
                d = sum(bin(p ^ q).count("1") for p, q in zip(g, cell))
                if d < bd:
                    bd, best = d, chr(ci)
            out.append(best if bd <= 2 else "?")
        return "".join(out)

    def test_the_first_chase_waits_on_the_page_and_enter_begins_it(self):
        self.walk_to_a_chase()
        self.start_a_chase()

        #  Nothing moves while the page is up, however long it is up.
        self.c.run_frames(300)
        self.assertEqual(self.b("MINI_LEFT"), self.sym["MG_STEPS"],
                         "the chase started without waiting for ENTER")
        self.assertEqual(self.b("MINI_ACTIVE"), 1)

        #  ...and it is the page, read off the PIXELS: the keys it names and
        #  the key that starts it.
        self.assertEqual(
            self.row(self.sym["MG_INTRO_GO_Y"], self.sym["MG_INTRO_GO_X"], 13),
            "ENTER - BEGIN")
        line2 = self.row(self.sym["MG_INTRO_Y"] + self.sym["MG_INTRO_STEP"],
                         self.sym["MG_INTRO_2_X"], 35)
        self.assertIn("LEFT AND RIGHT", line2, f"the keys are not named: {line2!r}")

        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)
        for _ in range(200):
            self.c.run_frames(2)
            if self.b("MINI_LEFT") < self.sym["MG_STEPS"]:
                break
        else:
            self.fail("ENTER did not begin the chase")
        self.finish_the_chase()

        #  THE SECOND CHASE HAS NO PAGE. Walk on to it and watch it run
        #  without a key being pressed.
        self.walk_to_a_chase()
        self.start_a_chase()
        for _ in range(200):
            self.c.run_frames(2)
            if self.b("MINI_LEFT") < self.sym["MG_STEPS"]:
                break
        else:
            self.fail("the second chase of the campaign waited for ENTER too")
        self.finish_the_chase()


class TestWhenItHappens(ChaseFixture):

    def test_it_is_every_MG_EVERYth_jump_and_no_other(self):
        """MG_EVERY is the whole of the answer to "twenty jumps is too many".

        Walked rather than reasoned about: mis_index is 0-based and the chase
        is keyed on the MISSION being left, so the off-by-one here is the one
        thing a table could not tell you.
        """
        every = self.sym["MG_EVERY"]
        saw = []
        for _ in range(every):
            mission = self.b("MIS_INDEX") + 1
            trace = self.jump_and_watch()
            if trace:
                saw.append(mission)
            h.dismiss_briefing(self.c)
            self.c.run_frames(40)
            h.wait_for_jump_wipe(self.c)
            self.c.run_frames(30)
            self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.assertEqual(saw, [every],
                         f"the chase ran on the jumps out of missions {saw}")


class TestSteering(ChaseFixture):
    """The one thing a count cannot see: does the key move the ship?

    ONE CHASE, TWO ASSERTIONS. Reaching a chase means walking MG_EVERY - 1
    jumps and each of those is a briefing, a ten-second spool and a seven-second
    wipe, so a trace is expensive and is taken once. The enemy's drift does not
    depend on the steering, so the same trace answers both questions.
    """

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.walk_to_a_chase()
        #  Hard left for the first third, hard right for the rest.
        state = {"n": 0}

        def drive(x, ex):
            state["n"] += 1
            return cpc.KEY_LEFT if state["n"] < 260 else cpc.KEY_RIGHT

        cls.trace = cls.jump_and_watch(drive)

    def test_left_and_right_move_you_and_the_ends_stop_you(self):
        self.assertTrue(self.trace, "there was no chase to steer")
        xs = [t[0] for t in self.trace]
        self.assertEqual(xs[0], self.sym["MG_X_MID"],
                         "the chase does not start in the middle")
        self.assertEqual(min(xs), self.sym["MG_X_MIN"],
                         f"holding LEFT did not reach the end stop: {min(xs)}")
        self.assertEqual(max(xs), self.sym["MG_X_MAX"],
                         f"holding RIGHT did not reach the end stop: {max(xs)}")
        #  ...and it went one way and then the other, rather than drifting.
        self.assertLess(xs[200], xs[0], "LEFT did not move you left")
        self.assertGreater(xs[-1], xs[200], "RIGHT did not move you right")

    def test_the_enemy_weaves_and_stays_inside_your_reach(self):
        """It is two sines, and both halves of that matter.

        A single sine is a metronome; and a drift that went further than the
        player's own end stops would be a chase that cannot be won at all.
        """
        exs = [t[1] for t in self.trace]
        self.assertGreater(max(exs) - min(exs), 60,
                           "the enemy barely moves; there is nothing to chase")
        self.assertGreaterEqual(min(exs), self.sym["MG_X_MIN"])
        self.assertLessEqual(max(exs), self.sym["MG_X_MAX"])
        #  Not a straight sweep: it turns round more than twice.
        #
        #  DE-DUPLICATED FIRST, because the trace is one reading per EMULATOR
        #  frame and a chase step is about eight of them -- so most consecutive
        #  pairs are the same number, every product is zero, and a count of
        #  sign changes over the raw trace is always nought whatever the enemy
        #  is doing. That is a test measuring the frame rate again.
        steps = [v for i, v in enumerate(exs) if i == 0 or v != exs[i - 1]]
        turns = sum(1 for a, b, c in zip(steps, steps[1:], steps[2:])
                    if (b - a) * (c - b) < 0)
        self.assertGreater(turns, 2, "the enemy's drift never changes direction")


class TestPlayingItDecidesTheOutcome(ChaseFixture):
    """The claim the whole feature rests on: steering changes what happens."""

    def test_chasing_it_down_catches_it_and_costs_nothing(self):
        self.walk_to_a_chase()
        before = self.alive()
        trace = self.jump_and_watch(
            lambda x, ex: (cpc.KEY_RIGHT if ex > x + 3
                           else (cpc.KEY_LEFT if ex < x - 3 else None)))
        self.assertTrue(trace, "there was no chase")
        self.assertEqual(trace[-1][2], 0,
                         "steering straight at it never closed the distance")
        self.assertEqual(self.b("MINI_LOST"), 0)
        self.assertEqual(self.alive(), before,
                         "a chase that was WON still cost ships")
        #  ...and it ended early, which is what winning means here.
        self.assertGreater(trace[-1][3], 0,
                           "the tunnel ran out; that is a loss, not a catch")


if __name__ == "__main__":
    unittest.main()
