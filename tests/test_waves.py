"""Attack waves, and the fleet-hull readout that shares their arithmetic.

Stay in a mission more than two minutes and the Vekhar start arriving, in
waves of random size at random spacing, and they never stop. The point is that
`J` should be a decision rather than a formality -- section 10's campaign is
about a fleet that only ever shrinks, and nothing used to make staying cost
anything.

WHAT THESE TESTS ARE AND ARE NOT
--------------------------------
They are not the balance. "At least a 70% chance of winning" is a rate, and a
rate is measured by tools/waverate.py over dozens of played-out missions, not
asserted in a unit test. What is here is everything the rate DEPENDS on and
that a unit test can pin down exactly: the clock, what arrives, that it is
scaled to the fleet, that it does not block the objective, and that the number
on the screen is the number the arithmetic produced.

Following the squadron lesson in CLAUDE.md, the scaling tests follow SLOTS --
which entity appeared, where, with what in it -- rather than counting hostiles.
A count is preserved by a wave that spawns in the wrong place with the wrong
hull, and the whole defect would be invisible.

DETERMINISM
-----------
Every test that spawns a wave pins the generator first. src/sys/rand.asm seeds
itself from sys_tick_50hz on the FIRST keypress and never again, and
boot_quick has already spent that on the title and the briefing -- so
h.pin_rng owns the sequence from then on. A test here that forgot to call it
would be a genuinely flaky test, which is why TestTheGenerator checks the
"never again" part directly.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walked a fixed forty-eight would
#  stop looking exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
ENT_X, ENT_Y, ENT_Z = 0, 2, 4
ENT_YAW, ENT_CLASS, ENT_HULL, ENT_FLAGS = 6, 9, 10, 11
F_ACTIVE, F_ENEMY, F_WAVE = 1, 2, 8
CLASS_INTERCEPTOR, CLASS_MOTHERSHIP = 0, 1

FIRST_CHAR, LAST_CHAR = 32, 90
CHAR_H, CHAR_W_BYTES = 8, 2

#  Mirrored from src/game/waves.asm. Anything here that drifts from the source
#  is a test that has stopped describing the game.
#
#  ...which is why BOTH CLOCKS are read rather than copied. They are wall-clock
#  figures now -- mis_timer counts 50 Hz TICKS, not game frames -- so they no
#  longer drift when the frame rate does, and that is the point of the change.
#  They are still read rather than mirrored because they have been set three
#  times and may be again.
WAVE_FIRST_TICKS = h.symbols()["WAVE_FIRST_TICKS"]
WAVE_GAP_MIN = h.symbols()["WAVE_GAP_MIN"]

#  The spread is 12 * a random byte, which is the one thing here that has to be
#  mirrored: it is the SHAPE of the arithmetic and not a number the build
#  exports.
WAVE_GAP_MAX = WAVE_GAP_MIN + 255 * 12
WAVE_MAX = 8
WAVE_HULL_MIN, WAVE_HULL_MAX = 120, 247
SYS_RAND_SEED = 0x7C4D

#  About ten emulator frames to a game frame at the rate this actually runs.
TICKS_PER_GAME_FRAME = 10

#  src/game/waves.asm: the fleet's hull is read on one game frame in four, so
#  nothing that pokes a hull sees the readout move for up to that long.
WAVE_READ_EVERY = 4


class WaveFixture(unittest.TestCase):
    """One machine per test. Nearly all of these spawn hostiles or damage the
    fleet, and either would be the next test's starting state."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.pin_rng(self.c, 0x1234)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def restart(self):
        """A second machine for the same test -- one at a time.

        Two live CPC instances in one process interfere: keystrokes stop
        registering in one of them and the symptom surfaces in whichever test
        runs next. Calling setUp() again without this leaves the first one
        alive, and the comparison tests below quietly compared a machine
        against itself.
        """
        h.close(self.c)
        self.c = None
        self.setUp()

    # -- reading the machine ------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def word(self, name):
        return int.from_bytes(self.c.read_ram(self.sym[name], 2), "little")

    def ent(self, slot, offset):
        return self.c.read_ram(
            self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 1)[0]

    def coord(self, slot, offset):
        raw = self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset, 2)
        return struct.unpack("<h", bytes(raw))[0]

    def poke_ent(self, slot, offset, value):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + offset,
                         bytes([value]))

    def slots(self, predicate):
        return [s for s in range(ENT_MAX) if predicate(self.ent(s, ENT_FLAGS))]

    def friendly(self):
        return self.slots(lambda f: f & F_ACTIVE and not f & F_ENEMY)

    def riders(self):
        """Slots holding a ship that arrived with a wave."""
        return self.slots(lambda f: f & F_ACTIVE and f & F_ENEMY and f & F_WAVE)

    def picket(self):
        """Slots holding one of the MISSION'S own hostiles."""
        return self.slots(
            lambda f: f & F_ACTIVE and f & F_ENEMY and not f & F_WAVE)

    # -- driving it ---------------------------------------------------------
    def hold(self, key, frames=30, release=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(release)

    def set_timer(self, value):
        self.c.write_ram(self.sym["MIS_TIMER"], struct.pack("<H", value))

    def force_wave(self, frames=40):
        """Bring the next wave forward and let it land."""
        h.force_wave(self.c, self.sym)
        self.c.run_frames(frames)

    def wait_for_a_fresh_hull_reading(self, want):
        """Run until wave_health has NOTICED what the test just poked.

        A wave is sized against the fleet's summed hull, and wave_health takes
        that reading on one game frame in WAVE_READ_EVERY -- four. A game frame
        is seven to fourteen 50 Hz frames, so a poke can be forty emulator
        frames away from being seen, and a fixed `run_frames(20)` before
        forcing a wave is a bet on the frame rate rather than a wait.

        It was a losing bet the moment the title screen's music shifted the
        boot: a fleet cut to the Mothership alone still read 4080 -- sixteen
        ships -- and got a wave of two where the test wanted one. The message
        was "2 != 1", which says nothing whatever about scaling.
        """
        for _ in range(200):
            if self.word("WAVE_HULL") == want:
                return
            self.c.run_frames(2)
        self.fail(f"wave_health never saw the fleet change: it still reads "
                  f"{self.word('WAVE_HULL')}, not {want}")

    def kill_the_picket(self):
        """Free the mission's own hostiles, so the objective can be met."""
        for slot in self.picket():
            self.poke_ent(slot, ENT_FLAGS, 0)

    # -- reading the HUD's top row back as text ------------------------------
    def font(self):
        if not hasattr(self, "_font"):
            self._font = bytes(self.c.read_ram(
                self.sym["TXT_FONT"], (LAST_CHAR - FIRST_CHAR + 1) * CHAR_H))
        return self._font

    @staticmethod
    def _to_pen1(b):
        """One screen byte, normalised back to the pen-1 bit pattern.

        txt_pen_map puts the same pixels in the high nibble (ink 1), the low
        one (ink 2) or both (ink 3), so folding the low nibble up recovers the
        glyph whichever ink it was drawn in -- which is what lets one decoder
        read a white HULL and a red INCOMING without being told which.
        """
        return (b | (b << 4)) & 0xF0

    def hull_row(self, base=None, cells=40):
        """Decode HUD row C back into characters. '?' for anything unknown."""
        if base is None:
            base = h.front_buffer(self.c)
        y = self.sym["HUD_ROW_C_Y"]
        ram = self.c.read_ram(base, 0x4000)
        rows = [[self._to_pen1(ram[h.screen_offset(y + r, x)]) for x in range(80)]
                for r in range(CHAR_H)]
        out = []
        for cell in range(cells):
            x = cell * CHAR_W_BYTES
            if x + 1 >= 80:
                break
            want = [(rows[r][x], rows[r][x + 1]) for r in range(CHAR_H)]
            out.append(self._match(want))
        return "".join(out).rstrip()

    def _match(self, cell):
        f = self.font()
        for code in range(FIRST_CHAR, LAST_CHAR + 1):
            i = (code - FIRST_CHAR) * CHAR_H
            bits = f[i:i + CHAR_H]
            if all(cell[r] == (bits[r] & 0xF0, (bits[r] << 4) & 0xF0)
                   for r in range(CHAR_H)):
                return chr(code)
        return "?"

    # -- the model ----------------------------------------------------------
    def expected_percent(self):
        """What wave_percent should be saying, computed from the table itself.

        class_hull is in bank 4, so it is read through the CPU's view. Reading
        it out of the machine rather than copying the numbers here is the point:
        a class whose hull changes must not need this file edited.
        """
        table = h.read_bank4(self.c, self.sym["CLASS_HULL"], 8)
        hull = full = 0
        for slot in self.friendly():
            hull += self.ent(slot, ENT_HULL)
            full += table[self.ent(slot, ENT_CLASS)]
        if full == 0:
            return 0
        if hull >= full:
            return 100
        return ((256 * hull) // full) * 100 // 256


class TestTheGenerator(WaveFixture):
    """The waves are only random if the generator is, and the tests are only
    trustworthy if it can be pinned. Both halves of that are here."""

    def setUp(self):
        #  NOT the fixture's: this class is about the state before any key has
        #  been pressed, and boot_quick presses two.
        self.c = h.boot_quick(frames=250, briefing=True)

    def test_an_untouched_machine_has_not_been_seeded(self):
        """A machine nobody has touched is reproducible, so a failure that
        happens before the player's first keypress can be reproduced."""
        self.assertEqual(self.word("SYS_RNG"), SYS_RAND_SEED)
        self.assertEqual(self.byte("SYS_RAND_SEEDED"), 0)

    def test_the_first_keypress_stirs_the_clock_in(self):
        """sys_tick_50hz at the moment a human presses a key is where the
        entropy comes from -- free-running at 50 Hz, so it is worth most of a
        byte, and key_consume already knows a key went down."""
        h.dismiss_title(self.c)
        self.assertEqual(self.byte("SYS_RAND_SEEDED"), 1)
        self.assertNotEqual(self.word("SYS_RNG"), SYS_RAND_SEED)

    def test_it_is_stirred_once_and_never_again(self):
        """This is the property the whole suite's determinism rests on: a test
        that pins SYS_RNG after boot must not have it stirred out from under it
        by the next key it presses."""
        h.dismiss_briefing(self.c)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")    # see below
        h.pin_rng(self.c, 0x5A5A)
        for key in ("z", "x", "p", "f"):
            self.hold(key)
        #  NOT "still 0x5A5A": cbt_prey_roll draws one byte a playing frame for
        #  the unarmed-prey coin, so the state moves every frame the battle
        #  runs. What must not happen is a RE-SEED -- the tick stirred in
        #  again -- and with the battle paused nothing draws at all, so the
        #  value has to be exactly the seed. The coin's own tests are in
        #  test_combat.
        self.assertEqual(self.word("SYS_RNG"), 0x5A5A,
                         "something re-seeded the generator after the first key")
        self.assertEqual(self.byte("SYS_RAND_SEEDED"), 1)


class TestTheClock(WaveFixture):
    """A minute, then one to two minutes between waves -- in 50 Hz TICKS,
    because that is what mis_timer counts now.

    THE UNIT IS THE POINT. It counted game frames, and a game frame is not a
    fixed length, so every figure derived from it was a conversion against a
    frame rate somebody had measured once -- and drifted three times without a
    line of the source changing. A tick is a fiftieth of a second, always.

    Which also fixes the arithmetic in here: a margin and a run_frames are in
    the SAME unit now, because run_frames counts 50 Hz frames and so does the
    clock. The margins below used to be game frames against an emulator-frame
    run, which is a factor of ten -- and the first of these failed the moment
    the unit changed, on twenty ticks of margin it read as twenty frames.
    """

    def test_nothing_arrives_before_the_minute_is_up(self):
        """The whole design is that the FIRST stretch of a mission is quiet.
        A wave one tick early is a wave in the middle of the picket fight."""
        self.set_timer(WAVE_FIRST_TICKS - 200)
        self.c.run_frames(100)                  # ...still a hundred ticks short
        self.assertEqual(self.byte("WAVE_COUNT"), 0)
        self.assertEqual(self.riders(), [])

    def test_the_wave_lands_when_the_clock_reaches_it(self):
        self.set_timer(WAVE_FIRST_TICKS - 2)
        self.c.run_frames(100)
        self.assertEqual(self.byte("WAVE_COUNT"), 1)
        self.assertGreater(len(self.riders()), 0)

    def test_the_gap_to_the_next_one_stays_inside_its_range(self):
        """Random spacing is the point -- a fixed gap is a rhythm the player
        holds station through -- but it has to stay inside the range the design
        asked for at both ends."""
        gaps = []
        for _ in range(6):
            self.force_wave()
            gaps.append(self.word("WAVE_NEXT") - self.word("MIS_TIMER"))
        for gap in gaps:
            #  WAVE_NEXT is read a few game frames after wave_send wrote it
            #  and mis_timer has moved on by then; a game frame is seven to
            #  ten ticks, so the slack is a few of them.
            self.assertGreaterEqual(gap, WAVE_GAP_MIN - 64)
            self.assertLessEqual(gap, WAVE_GAP_MAX)
        self.assertGreater(len(set(gaps)), 1,
                           f"the spacing is not random: {gaps}")

    def test_the_clock_starts_again_on_a_jump(self):
        """Two minutes is per MISSION. mis_setup zeroes mis_timer and calls
        wave_init, so a player who loitered through six waves in mission 3
        arrives in mission 4 with a fresh two minutes rather than an
        immediate wave."""
        self.force_wave()
        self.assertEqual(self.byte("WAVE_COUNT"), 1)
        self.assertNotEqual(self.word("WAVE_NEXT"), WAVE_FIRST_TICKS)

        self.kill_the_picket()
        self.c.run_frames(60)
        h.jump_mission(self.c)

        self.assertEqual(self.byte("MIS_INDEX"), 1)
        self.assertEqual(self.byte("WAVE_COUNT"), 0)
        self.assertEqual(self.word("WAVE_NEXT"), WAVE_FIRST_TICKS)
        self.assertEqual(self.riders(), [],
                         "the last mission's wave came through the jump")

    def test_a_tactical_pause_stops_the_clock(self):
        """SPACE freezes the battle (section 9), and a clock that kept running
        would mean the safest thing a cornered player can do is also the thing
        that brings the next wave forward."""
        #  PAUSE FIRST, THEN SET THE CLOCK. It was the other way round, with the
        #  timer left twenty ticks short of the wave -- and `hold` takes thirty
        #  frames down and thirty up, every one of which is a tick the clock is
        #  still running for, because the pause does not exist until key_scan
        #  sees the edge. Twenty ticks was never a margin against that; it was a
        #  bet on how many game frames a keypress takes, which is the assumption
        #  this file's own header warns about, and it came in one day when the
        #  boot got faster. Pausing first makes the setup say what it means.
        self.hold(" ")
        self.assertEqual(self.byte("ORDER_PAUSED"), 1)
        self.set_timer(WAVE_FIRST_TICKS - 20)
        frozen = self.word("MIS_TIMER")
        self.c.run_frames(30 * TICKS_PER_GAME_FRAME)
        self.assertEqual(self.word("MIS_TIMER"), frozen)
        self.assertEqual(self.byte("WAVE_COUNT"), 0)


class TestWhatArrives(WaveFixture):
    """What a wave IS: marked hostiles, at one bearing, on a shell around the
    Mothership."""

    def moth(self):
        slot = self.byte("MOTH_SLOT")
        return (self.coord(slot, ENT_X), self.coord(slot, ENT_Y),
                self.coord(slot, ENT_Z))

    def test_every_wave_ship_is_a_marked_hostile(self):
        self.force_wave()
        arrivals = self.riders()
        self.assertGreater(len(arrivals), 0)
        self.assertLessEqual(len(arrivals), WAVE_MAX)
        for slot in arrivals:
            self.assertEqual(self.ent(slot, ENT_FLAGS),
                             F_ACTIVE | F_ENEMY | F_WAVE)
            self.assertEqual(self.ent(slot, ENT_CLASS), CLASS_INTERCEPTOR)

    def test_one_wave_is_one_hull(self):
        """The strength is per WAVE, not per ship: a wave the player can read
        as 'that one was soft' is a wave they can make a decision about."""
        self.force_wave()
        hulls = {self.ent(s, ENT_HULL) for s in self.riders()}
        self.assertEqual(len(hulls), 1, f"a wave came in mixed hulls: {hulls}")
        hull = hulls.pop()
        self.assertGreaterEqual(hull, WAVE_HULL_MIN)
        self.assertLessEqual(hull, WAVE_HULL_MAX)

    def test_successive_waves_differ_in_strength(self):
        hulls = []
        for _ in range(6):
            self.force_wave()
            hulls.append(self.ent(self.riders()[-1], ENT_HULL))
        self.assertGreater(len(set(hulls)), 1,
                           f"every wave came in at the same hull: {hulls}")

    def test_they_arrive_on_a_shell_around_the_mothership(self):
        """Around the Mothership rather than around the camera or the selected
        squadron: the Mothership is the thing that must not be lost, and a wave
        that always arrived where the player happened to be looking would be a
        different mechanic. Far enough out to be seen coming -- the picket in
        mission 3 sits at 5000 -- and inside the 8191 the projection can see."""
        self.force_wave()
        mx, my, mz = self.moth()
        for slot in self.riders():
            dx = self.coord(slot, ENT_X) - mx
            dy = self.coord(slot, ENT_Y) - my
            dz = self.coord(slot, ENT_Z) - mz
            flat = (dx * dx + dz * dz) ** 0.5
            self.assertGreater(flat, 4000, f"slot {slot} arrived on top of us")
            self.assertLess(flat, 7000, f"slot {slot} arrived outside the view")
            self.assertLess(abs(dy), 700, f"slot {slot} arrived from overhead")

    def test_a_wave_comes_from_one_direction(self):
        """One bearing for the whole wave, jittered inside a 45 degree arc. A
        wave that arrived from all round at once reads as ships appearing out
        of nowhere; one that arrives from a direction reads as an attack, and
        the player can turn to face it."""
        self.force_wave()
        mx, _, mz = self.moth()
        import math
        bearings = []
        for slot in self.riders():
            dx = self.coord(slot, ENT_X) - mx
            dz = self.coord(slot, ENT_Z) - mz
            bearings.append(math.degrees(math.atan2(dx, dz)) % 360)
        if len(bearings) < 2:
            self.skipTest("this wave was a single ship")
        lo, hi = min(bearings), max(bearings)
        spread = min(hi - lo, 360 - (hi - lo))
        self.assertLess(spread, 70, f"the wave came from everywhere: {bearings}")

    def test_they_arrive_facing_the_fleet(self):
        """ENT_YAW is what phase4_cache draws the view straight off. A wave
        pointing outward reads as debris rather than as an attack."""
        self.force_wave()
        mx, _, mz = self.moth()
        import math
        for slot in self.riders():
            dx = self.coord(slot, ENT_X) - mx
            dz = self.coord(slot, ENT_Z) - mz
            #  ENT_YAW is 256ths of a turn; the ship should be looking back
            #  down the vector it arrived along.
            outward = (math.degrees(math.atan2(dx, dz)) % 360) / 360 * 256
            yaw = self.ent(slot, ENT_YAW)
            off = min((yaw - outward) % 256, (outward - yaw) % 256)
            self.assertGreater(off, 96,
                               f"slot {slot} is facing away from the fleet")

    def test_the_same_seed_sends_the_same_wave(self):
        """Determinism is a property of the game, not only a convenience for
        the tests: without it a bug report cannot be reproduced. Two machines,
        one at a time -- two live emulators in one process interfere."""
        def run_one():
            c = h.boot_quick(frames=250)
            try:
                h.pin_rng(c, 0x4321)
                h.force_wave(c, self.sym)
                c.run_frames(40)
                E = self.sym["ENTITIES"]
                out = []
                for slot in range(ENT_MAX):
                    f = c.read_ram(E + slot * ENT_SIZE + ENT_FLAGS, 1)[0]
                    if f == F_ACTIVE | F_ENEMY | F_WAVE:
                        out.append((slot,
                                    bytes(c.read_ram(E + slot * ENT_SIZE, 8)),
                                    c.read_ram(E + slot * ENT_SIZE + ENT_HULL, 1)[0]))
                return out
            finally:
                h.close(c)

        h.close(self.c)
        self.c = None
        first = run_one()
        second = run_one()
        self.assertGreater(len(first), 0)
        self.assertEqual(first, second)


class TestTheWaveIsScaledToTheFleet(WaveFixture):
    """The heart of it. A wave is a fraction of the hull the player still has,
    so that a fleet which has lost half of itself faces half a wave -- which is
    what makes the 70% hold in mission 7 as well as mission 1."""

    #  A RUN of waves rather than one, and that is not belt and braces. The
    #  size is (strength * a random 1..4 + 8) >> 4, so the multiplier decides
    #  the answer as much as the fleet does: on the lowest roll a whole fleet
    #  and half a fleet both come out at two, and a test that compared single
    #  draws would be asserting on which multiplier the generator happened to
    #  hand it. Comparing the total over eight draws asks the question that was
    #  meant -- is the wave scaled -- rather than a question about the seed.
    WAVES = 8

    def wave_sizes(self):
        """Take WAVES waves off a pinned generator, clearing each one away."""
        h.pin_rng(self.c, 0x2468)
        self.c.run_frames(20)
        out = []
        for _ in range(self.WAVES):
            self.force_wave(frames=25)
            out.append(self.byte("WAVE_SIZE"))
            for slot in self.riders():
                self.poke_ent(slot, ENT_FLAGS, 0)
            self.c.run_frames(10)
        return out

    def hurt_the_fleet(self, to):
        for slot in self.friendly():
            if self.ent(slot, ENT_CLASS) != CLASS_MOTHERSHIP:
                self.poke_ent(slot, ENT_HULL, to)

    def test_a_hurt_fleet_faces_a_smaller_wave(self):
        """Hull rather than headcount, and this is the case that separates
        them: not one ship has been lost here, so anything counting ships would
        send the same wave to a fleet that is one volley from dead."""
        whole = self.wave_sizes()
        self.restart()
        self.hurt_the_fleet(64)
        quarter = self.wave_sizes()
        self.assertLess(sum(quarter), sum(whole),
                        f"a quarter-strength fleet got {quarter} "
                        f"against a whole one's {whole}")
        self.assertLessEqual(max(quarter), max(whole))

    def test_a_smaller_fleet_faces_a_smaller_wave(self):
        """The other half of the same claim, and the one the design document
        cares about: losses are permanent, so by mission 7 the fleet IS half
        the size."""
        whole = self.wave_sizes()

        self.restart()
        for n, slot in enumerate(self.friendly()):
            if self.ent(slot, ENT_CLASS) != CLASS_MOTHERSHIP and n % 2:
                self.poke_ent(slot, ENT_FLAGS, 0)
        half = self.wave_sizes()
        self.assertLess(sum(half), sum(whole),
                        f"half a fleet got {half} against a whole one's {whole}")

    def test_a_fleet_of_one_still_gets_a_wave(self):
        """Plus one, always. A fleet down to the Mothership is not left alone
        -- it is the reason the waves exist, and the moment `J` matters most."""
        moth = None
        for slot in self.friendly():
            if self.ent(slot, ENT_CLASS) != CLASS_MOTHERSHIP:
                self.poke_ent(slot, ENT_FLAGS, 0)
            else:
                moth = slot
        self.wait_for_a_fresh_hull_reading(self.ent(moth, ENT_HULL))
        self.force_wave()
        self.assertEqual(len(self.riders()), 1)

    def test_no_wave_ever_fills_the_table(self):
        """WAVE_MAX is a hard cap whatever the arithmetic says. The table is the
        whole entity table and the later missions already field twelve
        hostiles; a wave that filled it would cost the frame rate far more than
        it cost the fleet."""
        for _ in range(8):
            self.force_wave(frames=20)
            self.assertLessEqual(self.byte("WAVE_SIZE"), WAVE_MAX)


class TestTheObjective(WaveFixture):
    """A wave is pressure to LEAVE, so it must never be the reason you cannot."""

    def test_a_wave_does_not_keep_a_clear_objective_from_completing(self):
        """The objective is the mission's own picket. If the arrivals counted,
        a CLEAR mission would become uncompletable the moment the first wave
        landed, `J` would never be offered, and the mechanic that exists to
        push the player onward would trap them instead."""
        self.kill_the_picket()          # mission 1 has none; be explicit anyway
        self.force_wave()
        self.assertGreater(len(self.riders()), 0)
        self.c.run_frames(60)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1,
                         "the wave is being counted as part of the objective")

    def test_the_jump_is_offered_with_a_wave_on_the_screen(self):
        """The end of the same argument, at the level the player sees: `J` has
        to work while they are being shot at, because that is exactly when they
        want it."""
        self.kill_the_picket()
        self.force_wave()
        self.c.run_frames(60)
        self.assertGreater(len(self.riders()), 0)
        h.jump_mission(self.c)
        self.assertEqual(self.byte("MIS_INDEX"), 1)

    def test_waves_keep_coming_after_the_objective_is_met(self):
        """They are the reason to jump, so they do not stop when the player has
        earned the right to. mis_update returns early once mis_complete is set,
        which is why wave_update is called from demo_update and not from
        inside it."""
        self.c.run_frames(120)
        self.assertEqual(self.byte("MIS_COMPLETE"), 1)
        self.force_wave()
        self.assertEqual(self.byte("WAVE_COUNT"), 1)
        self.force_wave()
        self.assertEqual(self.byte("WAVE_COUNT"), 2)


def _w(value):
    return [value & 0xFF, (value >> 8) & 0xFF]


class TestWhatItCosts(WaveFixture):
    """The frame budget, measured rather than reasoned about.

    This class exists because the first version of wave_health was written
    without one and cost nearly a whole per cent of the frame: it reloaded the
    record base out of memory four times a slot and did an `add hl,de` for
    every field, which is 174 T-states on an EMPTY slot and there are usually
    thirty of those. Measured end to end, 5.00 fps became 4.85 over two
    thousand frames -- a real regression, not the tick-boundary quantisation
    CLAUDE.md warns about, and the frame-rate test caught it.

    The technique is test_sound's: loop the routine a few hundred times and
    count PAL frames. The gate array steals cycles, so this reads 25-30% above
    a hand count of the instruction table -- which is the number that matters,
    because it is what the frame actually pays.
    """

    DONE = h.RESULT
    STUB = h.STUB

    #  A whole frame is about 530,000 T-states at the 24 entities section 6
    #  budgets for. wave_health runs on one game frame in WAVE_READ_EVERY, so
    #  its share of a frame is this over four -- under a quarter of a per cent
    #  at the bound below. Generous against the ~5,000 T it measures, because
    #  the point is to catch a rewrite that goes back to walking records, not
    #  to pin a number.
    BUDGET_T = 9000

    #  push bc, pop bc, dec bc, ld a,b, or c, jr
    LOOP_T = 11 + 10 + 6 + 4 + 4 + 12

    def tail(self):
        return [0xF3] + [0x3E, 0xAA, 0x32] + _w(self.DONE) + [0x18, 0xFE]

    def measure(self, symbol, iters=200):
        addr = self.sym[symbol]
        body = [0xC5, 0xCD] + _w(addr) + [0xC1, 0x0B, 0x78, 0xB1]
        code = [0xF3, 0x01] + _w(iters) + body
        code += [0x20, (-(len(body) + 2)) & 0xFF]       # jr nz
        self.c.write_ram(self.DONE, b"\x00")
        self.c.write_ram(self.STUB, bytes(code + self.tail()))
        self.c.set_pc(self.STUB)
        for frames in range(1, 400):
            self.c.run_frames(1)
            if self.c.read_ram(self.DONE, 1)[0] == 0xAA:
                return frames * 20e-3 * 4e6 / iters - self.LOOP_T
        self.fail("the stub never finished")

    def test_reading_the_fleets_hull_is_affordable(self):
        """A full table -- 16 friendly, and the rest empty, which is the shape
        the walk is optimised for."""
        t = self.measure("WAVE_HEALTH")
        self.assertLess(t, self.BUDGET_T,
                        f"wave_health costs {t:.0f} T, budget {self.BUDGET_T}")
        self.assertGreater(t, 500, f"{t:.0f} T is not a plausible measurement")
        print(f"\n    wave_health + wave_percent:      {t:.0f} T-states")

    def test_a_frame_that_takes_no_reading_is_nearly_free(self):
        """Three frames in four do not walk the table at all -- they decrement
        a counter, tick INCOMING down and compare the clock. If this ever
        approaches the figure above, the throttle has stopped working."""
        #  Land on a frame that will NOT read: wave_tick counts down to 1.
        self.c.write_ram(self.sym["WAVE_TICK"], b"\x04")
        t = self.measure("WAVE_UPDATE", iters=200)
        self.assertLess(t, self.BUDGET_T / 2,
                        f"a quiet frame costs {t:.0f} T")
        print(f"\n    wave_update, averaged over four: {t:.0f} T-states")


class TestTheMothershipsOwnFigure(WaveFixture):
    """BASE nnn%, at the other end of row C from the fleet's HULL nnn%.

    "Να φαίνεται κάπου ξεχωριστά η υγεία του mothership" -- and the reason it
    has to be separate is the whole of this class. Section 8 makes losing the
    Mothership the end of the campaign, and the fleet's figure is an AVERAGE
    over seventeen ships: it can read 94% with the one ship that matters at a
    tenth of its hull.
    """

    def moth_slot(self):
        return self.byte("MOTH_SLOT")

    def moth_full(self):
        return h.read_bank4(self.c, self.sym["CLASS_HULL"], 8)[CLASS_MOTHERSHIP]

    def test_a_whole_mothership_reads_a_hundred_per_cent(self):
        self.c.run_frames(60)
        self.assertEqual(self.byte("WAVE_MOTH_PCT"), 100)
        self.assertIn("BASE 100%", self.hull_row())

    def test_it_is_in_both_screen_buffers(self):
        self.c.run_frames(60)
        for base in (0x8000, 0xC000):
            self.assertIn("BASE 100%", self.hull_row(base=base),
                          f"the Mothership's hull is missing from "
                          f"buffer {base:#06x}")

    def test_it_is_the_mothership_and_not_the_fleet(self):
        """THE POINT, and it fails against a readout that shows the average.

        One ship of seventeen at a tenth of its hull moves the fleet's figure
        by a few points and the Mothership's by ninety. Both are read off the
        SCREEN, so this is also a statement about which of the two is drawn
        where -- a swapped pair of x positions would pass every assertion on
        the variables.
        """
        full = self.moth_full()
        self.poke_ent(self.moth_slot(), ENT_HULL, full // 10)
        self.c.run_frames(80)

        fleet, moth = self.byte("WAVE_PCT"), self.byte("WAVE_MOTH_PCT")
        self.assertGreater(fleet, 80,
                           "one damaged ship should barely move the fleet's "
                           f"average, and it read {fleet}%")
        self.assertLess(moth, 20,
                        f"the Mothership is at a tenth and BASE reads {moth}%")

        row = self.hull_row()
        self.assertIn(f"HULL {fleet:>3}%", row, f"row C reads {row!r}")
        self.assertIn(f"BASE {moth:>3}%", row, f"row C reads {row!r}")

    def test_it_repaints_when_only_the_mothership_moves(self):
        """wave_changed compares a shadow per figure, and the Mothership needs
        its own: a wave that goes straight for it can take a fifth of its hull
        without the fleet's average moving a whole point, and the row would
        then sit there showing the old number.
        """
        self.c.run_frames(60)
        before = self.hull_row()
        self.assertIn("BASE 100%", before)

        full = self.moth_full()
        self.poke_ent(self.moth_slot(), ENT_HULL, full * 3 // 4)
        self.c.run_frames(80)
        self.assertNotEqual(self.hull_row(), before,
                            "row C never repainted, so the Mothership's "
                            "figure is still the old one")
        self.assertIn(f"BASE {self.byte('WAVE_MOTH_PCT'):>3}%", self.hull_row())

    def test_a_vacated_slot_reads_zero_and_not_its_stale_hull(self):
        """The flags byte is what is asked, not the hull.

        fleet_restore packs survivors down and mis_setup spawns into the freed
        slots, so moth_slot can be left pointing at a vacated record that still
        holds somebody else's hull -- "Never trust a slot index", which this
        project has been caught by twice. An inactive slot reads 0 whatever is
        in ENT_HULL.

        DRIVEN DIRECTLY RATHER THAN THROUGH THE GAME, and the reason is worth
        writing down. The obvious version -- clear the Mothership's flags and
        wait -- does not work and its failure is the game being RIGHT: killing
        the Mothership sets mis_failed, the game-over screen takes over, and
        wave_update is on the playing path and stops running. So the readout
        keeps the last value it had, which was 100. There is no arrangement of
        keys that reaches this branch, so it is poked and CALLed: a stub, a
        set_pc and three frames, which is what CLAUDE.md calls the cheapest
        real unit test of real Z80 code.
        """
        slot = self.moth_slot()
        self.poke_ent(slot, ENT_HULL, 200)
        self.poke_ent(slot, ENT_FLAGS, 0)

        addr = self.sym["WAVE_MOTH_PERCENT"]
        self.c.write_ram(h.STUB, bytes([
            0xCD, addr & 0xFF, addr >> 8,       # call wave_moth_percent
            0x18, 0xFE,                         # jr $
        ]))
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)
        self.assertEqual(self.byte("WAVE_MOTH_PCT"), 0)

    def test_and_the_same_stub_reads_a_live_one_correctly(self):
        """...which is what stops the test above passing on a routine that
        always writes zero.

        The expected figure is the machine's OWN arithmetic rather than a
        rounded half: wave_pct_of is eight steps of a restoring divide into
        256ths and then a quarter-square multiply by 100, so half of an odd
        hull comes back as 49 and not 50. Writing 50 here and calling 49 a bug
        would have been asserting on Python's idea of division.
        """
        slot = self.moth_slot()
        full = self.moth_full()
        hull = full // 2
        self.poke_ent(slot, ENT_HULL, hull)

        addr = self.sym["WAVE_MOTH_PERCENT"]
        self.c.write_ram(h.STUB, bytes([
            0xCD, addr & 0xFF, addr >> 8,
            0x18, 0xFE,
        ]))
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)
        self.assertEqual(self.byte("WAVE_MOTH_PCT"),
                         ((256 * hull // full) * 100) >> 8)


class TestTheReadout(WaveFixture):
    """The percentage on the screen, read back as PIXELS.

    Asserting on WAVE_PCT would pass just as happily if nothing were drawn, or
    if it were drawn off the edge of the strip, or into one buffer of two. The
    economy's four-digit RU bug is the precedent: every test asserted on the
    variable, the variable was right, and 300 RU was displayed as 044.
    """

    def test_a_whole_fleet_reads_a_hundred_per_cent(self):
        self.c.run_frames(60)
        self.assertIn("HULL 100%", self.hull_row())

    def test_it_is_in_both_screen_buffers(self):
        """The display page-flips, so a row painted into one buffer and not the
        other is on screen every OTHER frame -- which looks like flicker on the
        machine and like nothing at all in a test that reads the front one.
        The context bar shipped exactly that bug."""
        self.c.run_frames(60)
        for base in (0x8000, 0xC000):
            self.assertIn("HULL 100%", self.hull_row(base=base),
                          f"the hull row is missing from buffer {base:#06x}")

    def test_damage_moves_the_figure(self):
        """And moves it to the value the machine's own class_hull table says,
        not merely to something smaller."""
        for slot in self.friendly()[:6]:
            self.poke_ent(slot, ENT_HULL, 60)
        self.c.run_frames(80)
        want = self.expected_percent()
        self.assertLess(want, 100)
        self.assertEqual(self.byte("WAVE_PCT"), want)
        self.assertIn(f"HULL {want:>3}%", self.hull_row())

    def test_the_figure_tracks_the_table_over_a_whole_sweep(self):
        """The divide is the only one in the game -- eight steps of a restoring
        divide and a quarter-square multiply -- so it is worth walking rather
        than sampling. Off-by-one at either end of the sweep would put a
        healthy fleet at 99% or a dying one at 1%.

        THE WAIT IS A WHOLE READING PERIOD AND USED TO BE LESS THAN ONE.
        wave_health runs on one game frame in WAVE_READ_EVERY, which is four,
        and a game frame is about ten emulator frames -- so a poke can be up to
        43 emulator frames away from being noticed, measured, and this waited
        40. It passed on the phase happening to suit: the sibling test above
        already used 80 for the same reason, and this row of the same file did
        not. Nothing in the game moved when it started failing -- the readout
        catches up in the same 41 to 43 frames, and demo_frames matches
        frame-for-frame, on the build that passes and the one that does not.
        """
        for hull in (255, 200, 128, 64, 32, 8, 1):
            for slot in self.friendly():
                self.poke_ent(slot, ENT_HULL, hull)
            self.c.run_frames(2 * WAVE_READ_EVERY * TICKS_PER_GAME_FRAME)
            self.assertEqual(self.byte("WAVE_PCT"), self.expected_percent(),
                             f"at a fleet-wide hull of {hull}")

    def test_an_arriving_wave_says_so(self):
        """A wave lands six thousand units out and the player may be looking
        the other way; without a word on the screen the first they know of it
        is a hull figure falling for no reason they can see."""
        self.force_wave(frames=60)
        self.assertIn("INCOMING", self.hull_row())

    def test_the_message_row_can_say_more_than_one_thing(self):
        """Section 5.5 asks for a message line and this row was it with exactly
        one message in it. The Frigate unlock is the second, and what it needed
        was for wave_say to stop BEING the message and start counting one down.

        Driven through the state rather than through a three-mission tow --
        tests/test_derelict.py is what proves the unlock reaches here. What
        this asks is the half that lives on this row: that wave_msg chooses
        the words."""
        self.c.write_ram(self.sym["WAVE_NEXT"], struct.pack("<H", 0xFFFF))
        self.c.write_ram(self.sym["WAVE_MSG"],
                         bytes([self.sym["WAVE_MSG_FRIGATE"]]))
        self.c.write_ram(self.sym["WAVE_SAY"],
                         bytes([self.sym["WAVE_SAY_FRAMES"]]))
        self.c.run_frames(4 * TICKS_PER_GAME_FRAME)

        row = self.hull_row()
        self.assertIn("YARD: FRIGATE", row)
        self.assertNotIn("INCOMING", row, "the row said both messages at once")

    def test_the_two_messages_do_not_share_an_ink(self):
        """They share the same eighteen characters of the row, so the ink is
        the only thing telling them apart at a glance. Section 2 gives ink 3 to
        the thing that wants attention -- INCOMING is a threat and keeps it;
        the unlock is news about the player's own fleet and is ink 1, the
        fleet's own ink.

        THE ROW DECODER CANNOT SEE THIS, deliberately: it folds the low nibble
        up so that one decoder reads a white HULL and a red INCOMING without
        being told which. So the ink is read straight off the planes here, the
        way tests/test_ctxbar.py does it."""
        self.c.write_ram(self.sym["WAVE_NEXT"], struct.pack("<H", 0xFFFF))

        inks = {}
        for name in ("WAVE_MSG_INCOMING", "WAVE_MSG_FRIGATE"):
            self.c.write_ram(self.sym["WAVE_MSG"], bytes([self.sym[name]]))
            self.c.write_ram(self.sym["WAVE_SAY"],
                             bytes([self.sym["WAVE_SAY_FRAMES"]]))
            self.c.run_frames(4 * TICKS_PER_GAME_FRAME)
            inks[name] = self.ink_of_the_message()

        self.assertEqual(inks["WAVE_MSG_INCOMING"], 3,
                         "INCOMING is not in the attention ink any more")
        self.assertEqual(inks["WAVE_MSG_FRIGATE"], 1,
                         "the unlock is drawn in the ink that means a threat")

    def ink_of_the_message(self):
        """The pen the message field is drawn in.

        Ink 1 is %01, so its pixels land in the high nibble; ink 2 is %10 and
        the low one; ink 3 is both. Read over the whole glyph height and take
        whichever planes carry any ink at all."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        hi = lo = 0
        for r in range(CHAR_H):
            for x in range(self.sym["HUD_SAY_X"], self.sym["HUD_MOTH_X"]):
                b = ram[h.screen_offset(self.sym["HUD_ROW_C_Y"] + r, x)]
                hi |= b & 0xF0
                lo |= b & 0x0F
        self.assertTrue(hi or lo, "nothing is drawn on the message row at all")
        return (1 if hi else 0) | (2 if lo else 0)

    def test_the_word_goes_away_again(self):
        self.force_wave(frames=60)
        self.assertIn("INCOMING", self.hull_row())
        #  WAVE_SAY_FRAMES is 40 game frames; give it more than that and stop
        #  the next wave from landing on top of the check.
        self.c.write_ram(self.sym["WAVE_NEXT"], struct.pack("<H", 0xFFFF))
        self.c.run_frames(60 * TICKS_PER_GAME_FRAME)
        self.assertNotIn("INCOMING", self.hull_row())

    def test_a_shot_landing_does_not_repaint_the_whole_hud(self):
        """The bargain that makes the HUD affordable is that it is repainted
        only when it changes -- about ninety thousand T-states a time, twice,
        once per buffer. The hull figure moves every time a shot lands, so it
        keeps its own dirty flag; hanging it off phase4_hud_dirty would undo
        the whole thing in the middle of a battle."""
        self.c.run_frames(80)
        self.assertEqual(self.byte("PHASE4_HUD_DIRTY"), 0)
        before = self.byte("WAVE_PCT")

        self.poke_ent(self.friendly()[0], ENT_HULL, 40)

        #  POLLED, not counted. wave_health reads the fleet on one game frame
        #  in WAVE_READ_EVERY, and a game frame is seven to fourteen 50 Hz
        #  ones -- so "two game frames" of emulator frames is a bet on the
        #  frame rate, and it lost the day the title screen got music. The
        #  failure was "100 == 100", which reads as the figure being stuck.
        for _ in range(200):
            if self.byte("WAVE_PCT") != before:
                break
            self.c.run_frames(2)
        self.assertNotEqual(self.byte("WAVE_PCT"), before,
                            "the hull figure never noticed the damage")
        self.assertEqual(self.byte("PHASE4_HUD_DIRTY"), 0,
                         "a hull change is repainting the squadron list")

    def test_the_row_survives_a_briefing(self):
        """Every full-screen page clears from line 0 and pays for it with
        mis_wipe, which clears all 200 lines -- including this row, which
        nothing else would ever put back. The help page is the cheapest one to
        open and close."""
        self.c.run_frames(60)
        self.assertIn("HULL", self.hull_row())
        self.hold("/")                          # `?` -- the key list
        self.c.run_frames(30)
        self.hold("\x1b")                       # ESC
        self.c.run_frames(90)
        for base in (0x8000, 0xC000):
            self.assertIn("HULL", self.hull_row(base=base),
                          f"the help page took the hull row out of {base:#06x}")


if __name__ == "__main__":
    unittest.main()
