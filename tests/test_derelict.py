"""The Frigate is unlocked by salvaging a derelict.

From mission 4 a dead VEKHAR FRIGATE is adrift at the edge of the play area,
and towing it to the Mothership with a Salvage Corvette is the only way the
yard ever learns to build one. The mechanic is reverse-engineering rather than
fetching a token, which is why the derelict is a frigate and why it is salvage
that does it.

WHY NONE OF THIS ASSERTS "THE FRIGATE IS IN THE BUILD LIST"
-----------------------------------------------------------
That is exactly the assertion this feature would survive being completely
wrong by. It is true of a build that unlocks the Frigate at mission 4 whatever
the player did; it is true of one where ANY wreck at all sets the flag; it is
true of one where the flag is set the moment the derelict is placed. Counting
and flag-reading is this project's recurring blind spot -- the squadron tests
that counted ships while they flew to the wrong squadron, the combat tests that
counted kills while the fleet sat stranded, the title test that counted lit
pixels while the screen drew bank 4 as sprite data.

So the tests here are built out of four discriminating pairs:

  * the class is stepped over BEFORE and reachable AFTER, read off the CONTEXT
    BAR -- pixels, not a flag, because the bar is what the player sees;
  * an ORDINARY wreck towed home does not unlock it (TestOnlyAFrigateTeaches),
    which is the control for the tow test below;
  * the derelict is followed BY SLOT from where mis_setup put it to the moment
    its slot is freed, and the flag is asserted still clear on every sample
    until then;
  * the derelict is placed in missions 4, 5 and 6 and NOT in 1-3 or 7-8, and
    NOT again once it has been taken.

tests/test_campaign.TestEveryPicketFits holds the arithmetic that decides the
last of those: a derelict is an extra hostile-region entity, and mission 7's
twelve-ship picket plus a derelict plus a whole WAVE_MAX wave is 21 against
ENT_ENEMY_MAX's 20.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tests.test_ctxbar import BarFixture
import cpc

#  Mirrored from src/game/entity.asm
ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS = 9, 10, 11
ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_TOW, ENT_TIMER = 12, 13, 14, 16, 19
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4
ORDER_IDLE, ORDER_TOW = 0, 6
NO_TARGET = 0xFF

#  src/game/shipclass.asm
CLASS_INTERCEPTOR, CLASS_FRIGATE, CLASS_SALVAGE = 0, 5, 6
COST_INTERCEPTOR, COST_FRIGATE = 35, 120

MIS_SIZE = 20
MIS_ENEMY_COUNT = 12

#  Edge-triggered commands, and the game scans once a GAME frame -- ten 50 Hz
#  frames at the rate this really runs at.
HOLD, RELEASE = 30, 30


class DerelictFixture(unittest.TestCase):

    def give_the_yard_a_harvester(self, slot=25):
        return h.give_the_yard_a_harvester(self.c, self.sym, slot)

    """One machine per test. Every one of these either walks the campaign
    forward or unlocks a class, and both would be the next test's starting
    state."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.FROM = cls.sym["MIS_DERELICT_FROM"]
        cls.UNTIL = cls.sym["MIS_DERELICT_UNTIL"]
        cls.UNLOCK_FRIGATE = cls.sym["CAMP_UNLOCK_FRIGATE"]
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.ENT_MAX = cls.sym["ENT_MAX"]

    def setUp(self):
        self.c = h.boot_quick(frames=300)
        self.E = self.sym["ENTITIES"]

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- reading ------------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def unlocks(self):
        return self.byte("CAMPAIGN_UNLOCKS")

    def ru(self):
        return int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")

    def ent(self, slot, offset):
        return self.c.read_ram(self.E + slot * ENT_SIZE + offset, 1)[0]

    def set_ent(self, slot, offset, value):
        self.c.write_ram(self.E + slot * ENT_SIZE + offset, bytes([value]))

    def pos(self, slot):
        base = self.E + slot * ENT_SIZE
        return tuple(int.from_bytes(self.c.read_ram(base + i * 2, 2),
                                    "little", signed=True) for i in range(3))

    def set_pos(self, slot, xyz):
        base = self.E + slot * ENT_SIZE
        for i, v in enumerate(xyz):
            self.c.write_ram(base + i * 2, int(v).to_bytes(2, "little", signed=True))

    @staticmethod
    def apart(a, b):
        return sum(abs(p - q) for p, q in zip(a, b))

    def active(self):
        return {s for s in range(self.ENT_MAX) if self.ent(s, ENT_FLAGS) & F_ACTIVE}

    def hulls(self):
        """Every crippled enemy hull on the board, by slot.

        A derelict and a combat wreck are byte-for-byte the same thing, which
        is the whole design -- so this finds both, and the tests that need to
        tell them apart do it by CLASS.
        """
        want = F_ACTIVE | F_ENEMY | F_DISABLED
        return {s for s in range(self.ENT_MAX)
                if (self.ent(s, ENT_FLAGS) & want) == want}

    def derelicts(self):
        return {s for s in self.hulls() if self.ent(s, ENT_CLASS) == CLASS_FRIGATE}

    def hostiles(self):
        return {s for s in range(self.ENT_MAX)
                if (self.ent(s, ENT_FLAGS) & (F_ACTIVE | F_ENEMY))
                == (F_ACTIVE | F_ENEMY)}

    def descriptor(self, index):
        base = self.sym["MISSION_TABLE"] + index * MIS_SIZE
        return h.read_bank4(self.c, base, MIS_SIZE)

    # -- pressing -----------------------------------------------------------
    def hold(self, key, frames=HOLD, release=RELEASE):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def settle_after_a_jump(self):
        """Wait the jump's reveal out before sending another command.

        Copied from tests/test_regions.py for the reason given there:
        mis_brief_key clears the briefing a frame BEFORE the sweep starts, so
        dismiss_briefing's poll can return with the reveal about to begin --
        and the reveal stops the world for hundreds of frames, so the next `J`
        is simply lost. That looks exactly like a jump being refused.
        """
        self.c.run_frames(60)
        h.wait_for_jump_wipe(self.c)
        self.c.run_frames(30)

    def jump_once(self):
        """Clear the objective the crude way and press J."""
        #  All three of mis_gate's conditions, not just the objective: a
        #  mission cannot be left before its third wave or with anything
        #  hostile flying. tests/test_campaign.TestTheWayOut is the rule.
        h.clear_the_way_out(self.c)
        was = self.byte("MIS_INDEX")
        self.hold("j", frames=40, release=40)
        h.dismiss_briefing(self.c)
        self.settle_after_a_jump()
        self.assertEqual(self.byte("MIS_INDEX"), was + 1,
                         "the jump was refused, so nothing after this means anything")

    def jump_to(self, index):
        while self.byte("MIS_INDEX") < index:
            self.jump_once()

    # -- arranging ----------------------------------------------------------
    def make_corvette(self, near=None):
        """Turn one of the fleet's interceptors into a Salvage Corvette.

        Converted rather than bought, exactly as tests/test_salvage.py does it
        and for the same reason: the yard takes 90 game frames over a corvette
        and the queue is not what is under test.
        """
        moth = self.byte("MOTH_SLOT")
        slot = next(s for s in sorted(self.active())
                    if s != moth and self.ent(s, ENT_CLASS) == CLASS_INTERCEPTOR)
        self.set_ent(slot, ENT_CLASS, CLASS_SALVAGE)
        self.set_ent(slot, ENT_HULL, 220)
        self.set_ent(slot, ENT_TOW, NO_TARGET)
        if near is not None:
            self.set_pos(slot, near)
        return slot

    def clear_the_board(self, keep):
        """Leave only `keep`, the Mothership and every crippled HULL flying.

        tests/test_salvage.py's strip_the_fleet takes everything, which is
        right there because it runs before any wreck exists. Here it would
        take the DERELICT with it -- mis_setup put the hull in the hostile
        region, so a sweep of "everything active" wipes the very thing under
        test, slv_find_wreck comes back empty, and the tow order spends itself
        on the first frame. That failure reads as "T did not work", which is
        the wrong diagnosis entirely.

        The picket goes, because a corvette and a Mothership alone against
        mission 4's eight hostiles is a fight rather than a tow.
        """
        moth = self.byte("MOTH_SLOT")
        hulls = self.hulls()
        for s in list(self.active()):
            if s in keep or s == moth or s in hulls:
                continue
            self.set_ent(s, ENT_FLAGS, 0)
        self.c.run_frames(4)


class TestWhereTheDerelictIs(DerelictFixture):
    """What mis_setup places, and where."""

    def test_there_is_none_before_mission_four(self):
        """The class is not gated on the mission at all, so a derelict turning
        up early would be the first three missions handing out a class the
        campaign means to charge for."""
        for i in range(self.FROM):
            self.assertEqual(self.derelicts(), set(),
                             f"mission {i + 1} already has a derelict")
            self.jump_once()

    def test_it_is_a_crippled_vekhar_frigate_in_the_hostile_region(self):
        self.jump_to(self.FROM)
        found = self.derelicts()
        self.assertEqual(len(found), 1,
                         f"mission {self.FROM + 1} placed {len(found)} derelicts")
        slot = found.pop()

        #  Byte for byte what slv_make_wreck produces, which is what makes all
        #  four of a wreck's exclusions free -- see mis_spawn_derelict.
        self.assertEqual(self.ent(slot, ENT_FLAGS),
                         F_ACTIVE | F_ENEMY | F_DISABLED,
                         "the derelict is not flagged as a crippled enemy hull")
        self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_FRIGATE)
        self.assertEqual(self.ent(slot, ENT_HULL), 0,
                         "the derelict has hull left, so it is a ship")
        self.assertEqual(self.ent(slot, ENT_TARGET), NO_TARGET)
        self.assertEqual(self.ent(slot, ENT_ORDER), ORDER_IDLE)

        self.assertGreaterEqual(
            slot, self.PLAYER_MAX,
            "the derelict landed in the FLEET's region, where mis_clear_enemies "
            "will not touch it and the next mission spawns on top of it")

    def test_it_is_drawn_at_the_zoom_the_mission_opens_on(self):
        """MEASURED ON THE SCREEN, not against the clip radius, and the first
        version of this test did the second and passed while the ship was
        invisible.

        proj_deltas rejects a world delta past PROJ_V_LIMIT per axis, and
        (-7000, 250, -6500) clears that on every axis -- and was never drawn,
        because proj_mag magnifies by a little MORE than fills the width on
        purpose, so the outer rim of the visible radius clips off the sides
        and two axes near the rim at once is the corner that goes. It first
        appeared three presses of `X` out from where the player starts.

        So the assertion is phase4_visible with the hull on the board against
        phase4_visible without it: the projection's own answer to "is this on
        the screen". Parked at scr_wait_vsync first, because phase4_project
        zeroes that count and builds it back up.

        The picket goes and the world is PAUSED before the two samples are
        taken. Both matter: eight hostiles closing on the fleet cross the
        frustum's edge while they fly, so a count taken sixty frames after
        another differs by more than the one entity being asked about, and the
        difference is then a statement about nothing.
        """
        self.jump_to(self.FROM)
        slot = self.derelicts().pop()
        for other in self.hostiles() - {slot}:
            self.set_ent(other, ENT_FLAGS, 0)
        self.c.run_frames(200)              # let the fleet settle into formation
        self.hold(" ")
        self.assertEqual(self.byte("ORDER_PAUSED"), 1, "SPACE did not pause")

        def visible():
            self.c.run_frames(60)
            h.run_to_stable_point(self.c, self.sym)
            return self.byte("PHASE4_VISIBLE")

        with_it = visible()
        self.set_ent(slot, ENT_FLAGS, 0)
        without = visible()
        self.assertEqual(with_it, without + 1,
                         "the derelict is not on the screen at the zoom step "
                         "every mission opens on -- the briefing points at "
                         "something the player cannot see")

    def test_it_is_not_where_the_picket_is(self):
        """Fetching it has to be a decision to send a corvette AWAY from the
        battle. Every enemy layout in campaign.asm sits at +z; if the derelict
        did too, it would be salvaged by accident on the way in."""
        self.jump_to(self.FROM)
        derelict = self.pos(self.derelicts().pop())
        picket = [self.pos(s) for s in self.hostiles() - self.hulls()]
        self.assertGreater(len(picket), 0, "mission 4 has no picket to be away from")
        for p in picket:
            self.assertGreater(self.apart(derelict, p), 6000,
                               f"the derelict sits {self.apart(derelict, p)} "
                               f"units from a hostile at {p}")


class TestItDoesNotTrapThePlayer(DerelictFixture):
    """The trap that has now been avoided three times -- ENT_F_WAVE, then the
    salvage wrecks, and now this. mis_count_enemies counts entities whose flags
    equal ACTIVE+ENEMY; a derelict that stayed in that set would make mission
    4's CLEAR objective uncompletable for ever, `J` would never be offered, and
    the reward for reading the briefing would be being stuck in the mission.

    Verified rather than assumed, which is the instruction.
    """

    def test_a_clear_mission_completes_with_the_derelict_untouched(self):
        self.jump_to(self.FROM)
        self.assertEqual(self.descriptor(self.FROM)[18], 0,
                         "mission 4 is no longer a CLEAR mission, so this test "
                         "is no longer about anything")
        self.assertEqual(len(self.derelicts()), 1)

        #  Kill the picket and leave the hull alone.
        for slot in self.hostiles() - self.hulls():
            self.set_ent(slot, ENT_FLAGS, 0)
        self.c.run_frames(60)

        self.assertEqual(len(self.derelicts()), 1,
                         "the derelict went away on its own, so nothing was tested")
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "the derelict kept a CLEAR objective open")

    def test_and_the_jump_is_actually_offered(self):
        """mis_complete is the flag; `J` is what the player presses. They are
        the same thing today and a test that only reads the flag would not
        notice the day they stop being."""
        self.jump_to(self.FROM)
        for slot in self.hostiles() - self.hulls():
            self.set_ent(slot, ENT_FLAGS, 0)
        self.c.run_frames(60)
        self.assertEqual(len(self.derelicts()), 1)

        #  ...and the OTHER two things mis_gate asks, because this test is
        #  about the derelict and not about the waves. Without it the refusal
        #  would come from the wave count and the assertion below would be
        #  true for a reason that has nothing to do with a hull on the board.
        self.c.write_ram(self.sym["WAVE_COUNT"],
                         bytes([self.sym["WAVE_BEFORE_JUMP"]]))
        self.c.run_frames(24)
        self.assertEqual(self.byte("MIS_LEAVE_OK"), 1,
                         "the derelict closed the way out")

        self.hold("j", frames=40, release=40)
        h.dismiss_briefing(self.c)
        self.settle_after_a_jump()
        self.assertEqual(self.byte("MIS_INDEX"), self.FROM + 1,
                         "J was refused with only a derelict left on the board")

    def test_an_attack_order_aimed_at_it_does_not_strand_the_fleet(self):
        """The other half of the same hazard, and it is REAL rather than
        theoretical: order_target_step walks ent_is_active, so `,` and `.`
        will happily step onto a derelict exactly as they will onto any wreck,
        and `A` then writes it into every ship of the squadron.

        phase4_fly skips a ship under an attack order so that cbt_move_enemies
        can steer it, and cbt_move_enemies declines to move a ship with no
        flying target. Together, on a target nothing can shoot, they mean
        nothing steers the squadron at all -- it stops where it stands for the
        rest of the mission and fleet_save carries those coordinates into the
        next one. cbt_target_flying is what stops that.

        THE STATE IS POKED RATHER THAN PRESSED, and finding out why is worth
        a line. Pressing `A` at the hull does produce it -- and then
        cbt_fire_if_able spends the order inside the same game frame, which is
        the feature working and is invisible to any sampling a test can do. So
        the ships are displaced and given the order directly, which is the
        harsh version of what a player's keypress makes for one frame: the
        question is whether they ever come home from it.
        """
        self.jump_to(self.FROM)
        for slot in self.hostiles() - self.hulls():
            self.set_ent(slot, ENT_FLAGS, 0)
        self.c.run_frames(60)
        derelict = self.derelicts().pop()

        moth = self.byte("MOTH_SLOT")
        station = self.pos(moth)
        away = (station[0] + 6000, station[1], station[2] + 6000)
        sent = sorted(s for s in self.active() if s != moth and s != derelict)
        self.assertGreater(len(sent), 1, "there is no fleet to strand")
        for s in sent:
            self.set_pos(s, away)
            self.set_ent(s, ENT_ORDER, self.sym["ENT_ORDER_ATTACK"])
            self.set_ent(s, ENT_TARGET, derelict)

        self.c.run_frames(900)

        still = [s for s in sent
                 if self.ent(s, ENT_ORDER) == self.sym["ENT_ORDER_ATTACK"]]
        self.assertEqual(still, [],
                         "the attack order is still standing over a hull that "
                         "cannot be shot")
        stranded = {s: self.apart(self.pos(s), station) for s in sent
                    if self.ent(s, ENT_FLAGS) & F_ACTIVE
                    and self.apart(self.pos(s), station) > 4000}
        self.assertEqual(stranded, {},
                         "ships are still parked six thousand units out, aimed "
                         "at a wreck")
        self.assertIn(derelict, self.derelicts(),
                      "the fleet destroyed the hull it was supposed to salvage")


class TestTheYardWillNotTakeAFrigateYet(DerelictFixture):
    """The second door. eco_pick_step walks past a class it cannot offer, and
    eco_queue asks again at ENTER because the pick is a byte in RAM that the
    orders menu can move -- so a gate that only lived in the stepper would be
    reachable by pressing ESC and choosing BUILD."""

    def frigate_pick(self):
        order = h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
                             self.sym["CLASS_BUILDABLE"])
        return order.index(CLASS_FRIGATE)

    def order_the_pick(self):
        """Put the panel on the frigate BEHIND the stepper's back and press
        ENTER, which is what the orders menu's injected key amounts to."""
        #  The yard takes nothing but harvesters while there are none flying,
        #  and that refusal would stand in for the UNLOCK this is about --
        #  test_enter_is_refused_and_charges_nothing would pass for the wrong
        #  reason and its twin would fail, which is exactly the pair this class
        #  exists to keep honest.
        self.give_the_yard_a_harvester()
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")
        self.c.write_ram(self.sym["ECO_BUILD_PICK"], bytes([self.frigate_pick()]))
        before = self.ru()
        self.hold(cpc.KEY_ENTER)
        return before, self.ru()

    def test_enter_is_refused_and_charges_nothing(self):
        self.c.write_ram(self.sym["ECO_RU"], (2000).to_bytes(2, "little"))
        before, after = self.order_the_pick()
        self.assertEqual(after, before,
                         "the yard charged for a frigate it will not build")
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), 0xFF,
                         "a locked frigate went on the slipway")
        self.assertEqual(self.byte("ECO_QUEUE_LEN"), 0)

    def test_and_is_taken_once_the_hull_has_been_salvaged(self):
        """The same keystrokes against the same machine with one bit set. If
        this passed and the one above did too, the gate would be doing nothing
        at all -- which is why they are a pair."""
        self.c.write_ram(self.sym["ECO_RU"], (2000).to_bytes(2, "little"))
        self.c.write_ram(self.sym["CAMPAIGN_UNLOCKS"], bytes([self.UNLOCK_FRIGATE]))
        before, after = self.order_the_pick()
        self.assertEqual(before - after, COST_FRIGATE,
                         "the frigate was not charged for at section 8's price")
        self.assertEqual(self.byte("ECO_BUILD_CLASS"), CLASS_FRIGATE,
                         "the frigate did not reach the slipway")


class TestTheDestroyerGateStillWorks(DerelictFixture):
    """eco_pick_allowed became a TABLE for this feature, and the class that was
    already gated is the thing a table most easily breaks. Section 8:
    "διαθέσιμο από την 5η αποστολή"."""

    def destroyer_pick(self):
        order = h.read_bank4(self.c, self.sym["ECO_BUILD_ORDER"],
                             self.sym["CLASS_BUILDABLE"])
        return order.index(self.sym["CLASS_DESTROYER"])

    def try_to_order_a_destroyer(self):
        self.c.write_ram(self.sym["ECO_RU"], (2000).to_bytes(2, "little"))
        #  The yard takes nothing but harvesters while there are none flying,
        #  and that refusal would stand in for the MISSION gate this is about.
        self.give_the_yard_a_harvester()
        self.hold("b")
        self.c.write_ram(self.sym["ECO_BUILD_PICK"], bytes([self.destroyer_pick()]))
        self.hold(cpc.KEY_ENTER)
        return self.byte("ECO_BUILD_CLASS")

    def test_not_before_the_mission_section_eight_names(self):
        self.assertEqual(self.byte("MIS_INDEX"), 0)
        self.assertEqual(self.try_to_order_a_destroyer(), 0xFF,
                         "a destroyer was ordered in mission 1")

    def test_and_yes_from_it(self):
        self.jump_to(self.sym["CLASS_DESTROYER_MIS"])
        self.assertEqual(self.try_to_order_a_destroyer(),
                         self.sym["CLASS_DESTROYER"],
                         "the destroyer is still refused at mission 5")


class TestOnlyAFrigateTeachesTheYard(DerelictFixture):
    """The control for the tow test, and the one that says "any wreck at all"
    is not what happens.

    A whole ordinary tow -- corvette built, hostile crippled, hull towed to the
    Mothership, RU paid -- and the class is still locked at the end of it.
    """

    def test_towing_an_ordinary_wreck_unlocks_nothing(self):
        corvette = self.make_corvette()
        self.clear_the_board({corvette})
        moth = self.pos(self.byte("MOTH_SLOT"))

        #  Made by the game, never poked: whether a kill leaves a hull at all
        #  is the decision this rests on.
        victim = self.spawn_hostile(moth, hull=8)
        for _ in range(30):
            self.c.run_frames(30)
            if victim in self.hulls():
                break
        else:
            self.fail("the hostile was never crippled")
        self.assertEqual(self.ent(victim, ENT_CLASS), CLASS_INTERCEPTOR)

        before = self.ru()
        self.hold("t")
        for _ in range(60):
            self.c.run_frames(30)
            if not (self.ent(victim, ENT_FLAGS) & F_ACTIVE):
                break
        else:
            self.fail("the wreck was never delivered")

        self.assertEqual(self.ru() - before, COST_INTERCEPTOR,
                         "the delivery did not pay out, so nothing was towed")
        self.assertEqual(self.unlocks(), 0,
                         "towing an interceptor hull taught the yard to build "
                         "frigates")

    def spawn_hostile(self, xyz, hull=8):
        """A Vekhar interceptor, soft enough to die quickly.

        ENT_TIMER is cleared because the slot is a recycled one and the timer
        is a weapon cooldown -- a stale 200 is twenty seconds of a hostile that
        never fires. tests/test_salvage.py records that it cost an afternoon.
        """
        slot = next(s for s in range(self.PLAYER_MAX, self.ENT_MAX)
                    if not (self.ent(s, ENT_FLAGS) & F_ACTIVE))
        self.set_pos(slot, xyz)
        self.set_ent(slot, ENT_CLASS, CLASS_INTERCEPTOR)
        self.set_ent(slot, ENT_HULL, hull)
        self.set_ent(slot, ENT_SQUAD, 0)
        self.set_ent(slot, ENT_ORDER, ORDER_IDLE)
        self.set_ent(slot, ENT_TARGET, NO_TARGET)
        self.set_ent(slot, ENT_TIMER, 0)
        self.set_ent(slot, ENT_FLAGS, F_ACTIVE | F_ENEMY)
        return slot


class TestTheSalvage(DerelictFixture):
    """The journey, followed by slot from mis_setup to the Mothership's door.

    This is the test the feature exists to pass, and every assertion in it
    names a slot: THAT corvette closed on THAT hull, THAT hull moved with it,
    and the flag was still clear on every sample until the slot was freed.
    """

    def test_the_derelict_is_towed_home_and_the_flag_flips_at_arrival(self):
        self.jump_to(self.FROM)
        derelict = self.derelicts().pop()
        where = self.pos(derelict)

        corvette = self.make_corvette()
        self.clear_the_board({corvette})
        start = self.apart(self.pos(corvette), where)
        #  PHASE4_STEP is 150 world units a game frame, so this is forty-odd
        #  frames out and forty back -- a journey rather than an arrival, which
        #  is what makes "it went and got it" answerable at all.
        self.assertGreater(start, 5000,
                           "the corvette starts on top of the derelict, so "
                           "'it went and got it' is unanswerable")

        self.hold("t")
        self.assertEqual(self.ent(corvette, ENT_ORDER), ORDER_TOW,
                         "T did not put the corvette under a tow order")

        #  TEN FRAMES A SAMPLE, NOT THIRTY, and that is the difference between
        #  a measurement and a coincidence. The corvette covers up to 450 world
        #  units of Manhattan distance per GAME frame and a game frame is about
        #  ten emulator frames, so at thirty the whole approach -- 5,950 units
        #  of it -- happens inside the first two samples and "it closed on the
        #  hull" is a comparison of the starting distance with itself.
        closest = start
        picked_up = None
        for step in range(240):
            self.c.run_frames(10)

            if not (self.ent(derelict, ENT_FLAGS) & F_ACTIVE):
                break

            #  Still on the board, so nothing may have been learned yet. This
            #  is the "and not before" half, and it is checked on every sample
            #  rather than once at the end.
            self.assertEqual(self.unlocks(), 0,
                             f"the frigate was unlocked at step {step}, with the "
                             f"hull still adrift at {self.pos(derelict)}")

            just_picked = False
            if self.ent(corvette, ENT_TOW) == derelict and picked_up is None:
                picked_up = step
                just_picked = True

            if picked_up is None:
                closest = min(closest, self.apart(self.pos(corvette), where))
            elif not just_picked:
                #  slv_drag copies six bytes: the hull goes where the tug goes.
                self.assertEqual(self.pos(derelict), self.pos(corvette),
                                 "the hull stopped following the corvette")
            #  NOT on the sample the tow first appears in. slv_tow_step's
            #  @slv_outbound writes ENT_TOW and RETURNS -- slv_drag does not run
            #  until the next frame -- so there is exactly one frame in which
            #  the tow is set and the hull has not moved yet. A ten-frame sample
            #  landing in it made this test fail depending on where the frame
            #  boundary fell: it fails on a pristine build too, given 2,600
            #  T-states of djnz in demo_update and nothing else changed.
        else:
            self.fail(f"the derelict was never delivered "
                      f"(corvette at {self.pos(corvette)}, "
                      f"hull at {self.pos(derelict)}, "
                      f"tow {self.ent(corvette, ENT_TOW)})")

        self.assertIsNotNone(picked_up, "the corvette never got a line on it")
        #  Half the distance under its own power before it takes hold. Not
        #  tighter than that: the tow latches inside eco_range_check's reach,
        #  which is ECO_HARVEST_RANGE shifted up by WORLD_SHIFT -- about 1,500
        #  world units -- plus however far the corvette travels between two
        #  samples. A quarter would sit inside that slop and fail on the
        #  arithmetic rather than on the corvette.
        #  ...and only when there WAS a distance to close. `closest` is
        #  updated on the samples before the pickup, so a corvette that takes
        #  hold on the very first one leaves it at its starting value -- which
        #  is not a corvette that failed to move, it is one that was already
        #  inside the tow's reach. Whether that happens is decided by the frame
        #  rate: a nearly empty board runs at the full 12.5 fps rather than the
        #  5 this fixture's comments assume, so ten emulator frames can be one
        #  game frame or two. Asserting unconditionally made the test depend on
        #  which.
        if picked_up > 0:
            self.assertLess(closest, start // 2,
                            f"the corvette closed only to {closest} of {start}")

        moth = self.pos(self.byte("MOTH_SLOT"))
        self.assertLess(self.apart(self.pos(corvette), moth), 3000,
                        "the hull was cashed in somewhere other than the "
                        "Mothership")
        self.assertEqual(self.unlocks(), self.UNLOCK_FRIGATE,
                         "the hull arrived and the yard learned nothing")

    def test_it_pays_out_as_well_as_unlocking(self):
        """A frigate hull is worth what the yard would have charged to build
        one. Separate from the test above deliberately: the unlock is the
        point, and a payout that stopped working would otherwise hide behind
        it."""
        self.jump_to(self.FROM)
        derelict = self.derelicts().pop()
        corvette = self.make_corvette()
        self.clear_the_board({corvette})
        before = self.ru()

        self.hold("t")
        for _ in range(80):
            self.c.run_frames(30)
            if not (self.ent(derelict, ENT_FLAGS) & F_ACTIVE):
                break
        else:
            self.fail("the derelict was never delivered")
        self.assertEqual(self.ru() - before, COST_FRIGATE)


class TestItComesBackUntilItIsTaken(DerelictFixture):
    """Losing a whole class to a briefing that was not read is a punishment for
    not reading rather than for playing badly, so there are three chances --
    and exactly three, because a derelict is an extra hostile-region entity and
    mission 7's picket has no room for one. See test_campaign for that."""

    def test_it_is_placed_again_in_every_mission_of_the_range(self):
        self.jump_to(self.FROM)
        for i in range(self.FROM, self.UNTIL + 1):
            self.assertEqual(self.byte("MIS_INDEX"), i)
            self.assertEqual(len(self.derelicts()), 1,
                             f"mission {i + 1} is inside the derelict's range "
                             f"and has none")
            self.jump_once()

    def test_and_not_after_it(self):
        self.jump_to(self.UNTIL + 1)
        self.assertEqual(self.derelicts(), set(),
                         f"mission {self.UNTIL + 2} still fields a derelict, "
                         f"which is one hostile slot the picket and a wave need")

    def test_and_never_again_once_it_has_been_salvaged(self):
        """The flag is what stops it, so this is the same test as "it comes
        back" run against the other value of the same bit."""
        self.jump_to(self.FROM)
        self.assertEqual(len(self.derelicts()), 1)
        self.c.write_ram(self.sym["CAMPAIGN_UNLOCKS"], bytes([self.UNLOCK_FRIGATE]))
        self.jump_once()
        self.assertEqual(self.derelicts(), set(),
                         "a second derelict appeared after the first was taken")


class TestTheUnlockSurvivesAJump(DerelictFixture):
    """In RAM, across mis_setup and fleet_save/fleet_restore. The disc half is
    tests/test_persistence.py."""

    def test_a_jump_does_not_forget_it(self):
        self.c.write_ram(self.sym["CAMPAIGN_UNLOCKS"], bytes([self.UNLOCK_FRIGATE]))
        self.jump_once()
        self.assertEqual(self.unlocks(), self.UNLOCK_FRIGATE,
                         "the jump cleared what the campaign had unlocked")
        self.jump_once()
        self.assertEqual(self.unlocks(), self.UNLOCK_FRIGATE)


class TestTheBarNamesTheFrigateOnlyWhenItCanBeBought(BarFixture):
    """Read off the CONTEXT BAR, in pixels, because the bar is the whole of
    what the player can see of the build list -- the panel steps OVER a class
    it cannot offer, so "the frigate is locked" and "the frigate does not
    exist" look identical from the outside and that is deliberate.

    A test on eco_build_pick would pass with the bar drawing the wrong word.
    """

    def walk_the_list(self):
        """Every class name the bar shows as `.` goes right round the list."""
        #  ...and there has to BE a list. With no harvester flying the yard
        #  offers exactly one class -- see tests/test_economy's
        #  TestTheEconomyComesFirst -- so without this the walk finds one word
        #  and "the frigate was not offered" would be true for the wrong
        #  reason, which is the failure mode this whole class exists to avoid.
        self.give_the_yard_a_harvester()
        self.hold("b")
        self.assertEqual(self.byte("ECO_BUILD_OPEN"), 1, "B did not open the yard")
        seen, first = [], None
        for _ in range(self.sym["CLASS_BUILDABLE"] + 2):
            pick = self.byte("ECO_BUILD_PICK")
            if first is None:
                first = pick
            elif pick == first:
                break
            seen.append(self.strip_text())
            self.hold(".", frames=20, release=20)
        return seen

    def test_it_is_stepped_over_before_the_derelict_is_salvaged(self):
        shown = self.walk_the_list()
        self.assertTrue(any("SCOUT" in s for s in shown),
                        f"the panel never named a class at all: {shown}")
        self.assertFalse(any("FRIGATE" in s for s in shown),
                         f"the bar offered a FRIGATE before it was unlocked: {shown}")
        self.assertFalse(any("DESTROYER" in s for s in shown),
                         f"the bar offered a DESTROYER in mission 1: {shown}")

    def test_and_reachable_after(self):
        self.c.write_ram(self.sym["CAMPAIGN_UNLOCKS"],
                         bytes([self.sym["CAMP_UNLOCK_FRIGATE"]]))
        shown = self.walk_the_list()
        named = [s for s in shown if "FRIGATE" in s]
        self.assertEqual(len(named), 1,
                         f"the bar named the frigate {len(named)} times: {shown}")
        self.assertIn("120", named[0],
                      "the frigate is on the list without section 8's price")


class TestTheBriefingSaysSo(BarFixture):
    """A feature the player cannot find does not exist. This project has a
    context bar because that lesson was learned expensively, and the build
    panel steps over a locked class rather than showing it -- so there is
    nothing whatever on the screen to make anyone wonder. The briefing is the
    one place the player is told what to do, and it is the cheapest.

    Read off the briefing screen through the machine's own font, the same way
    the bar is.
    """

    def jump_once(self, dismiss=True):
        """Clear the objective the crude way and press J.

        The last jump of the walk does NOT dismiss what comes up, because the
        briefing is the thing being read.
        """
        h.clear_the_way_out(self.c)
        was = self.byte("MIS_INDEX")
        self.hold("j", frames=40, release=40)
        h.wait_for_briefing(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), was + 1, "the jump was refused")
        if dismiss:
            h.dismiss_briefing(self.c)
            #  The reveal stops the world; a J pressed into it is lost.
            self.c.run_frames(60)
            h.wait_for_jump_wipe(self.c)
            self.c.run_frames(30)

    def briefing_text(self, tries=16):
        """The briefing's three text rows, from the buffer on show.

        SAMPLED RATHER THAN READ ONCE, and for the reason test_squadinfo
        records: mis_brief_draw calls static_wipe and repaints inside ONE game
        frame, which is about ten emulator frames, so a read at an arbitrary
        boundary lands between the wipe and the repaint often enough to look
        deterministic. It came back as two spaces the first time.
        """
        rows = range(self.sym["BRIEF_TEXT_Y"],
                     self.sym["BRIEF_TEXT_Y"]
                     + self.sym["BRIEF_LINES"] * self.sym["BRIEF_LINE_STEP"],
                     self.sym["BRIEF_LINE_STEP"])
        best = ""
        for _ in range(tries):
            text = " ".join(self.strip_text(y=y, cells=40) for y in rows)
            if len(text) > len(best):
                best = text
            if "FRIGATE" in best and "SALVAGE" in best:
                break
            self.c.run_frames(3)
        return best

    def test_mission_four_names_the_hull_and_what_it_is_for(self):
        target = self.sym["MIS_DERELICT_FROM"]
        for _ in range(target - 1):
            self.jump_once()
        self.jump_once(dismiss=False)

        self.assertEqual(self.byte("MIS_INDEX"), target)
        self.assertEqual(self.byte("MIS_BRIEFING"), 1, "no briefing came up")

        text = self.briefing_text()
        self.assertIn("FRIGATE", text,
                      f"mission 4's briefing does not mention the hull: {text!r}")
        self.assertIn("SALVAGE", text,
                      f"mission 4's briefing does not say what to do with it: "
                      f"{text!r}")


if __name__ == "__main__":
    unittest.main()
