"""The AY-3-8912 effects player -- src/sys/sound.asm.

Everything here asserts on the PSG's own registers, read back out of the chip
by the CPC itself. The AY lets you read a register you have written, so a stub
poked into RAM walks registers 0..13 through exactly the handshake key_scan
uses to read register 14 -- PPI control word to A-input, port C to PSG_READ,
IN from port A -- and drops the fourteen bytes somewhere Python can pick them
up. That is a genuine observation of the hardware state and not of the OUT
sequence: if snd_update programmed the chip through the wrong port, or left
port A pointing the wrong way, nothing would come back.

The C emulator (chips/ay38910.h) implements the read side properly -- reg[addr]
for every address below 16, with the port-A input callback only for 14 -- so
these values are the real thing.

Two consequences worth knowing about while reading the tests:

  - the envelope tests all run with interrupts OFF, stepping snd_update one
    tick at a time from a stub, so they know exactly where in a sound they
    are. The PPI-contention tests install their own IM 1 handler instead --
    shaped exactly like the shipped sys_irq, key_scan and then snd_update on
    every sixth interrupt -- because what they are testing is the two of them
    sharing PPI port A.

  - the scratch addresses are derived from LOW_END rather than hard-coded.
    The lookup tables in src/gen are `align 256`, so adding code slides them
    up a page at a time, and a fixed scratch address that is free today lands
    in the middle of a table tomorrow. (The older test modules do hard-code
    #2E00/#2F00/#3000, and those are already inside f9_lo/f9_hi -- see the
    note at the bottom of this file.)
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h

#  Mixer register R7 is active LOW: a 0 bit lets that generator through.
MIX_TONE_A = 1 << 0
MIX_TONE_B = 1 << 1
MIX_TONE_C = 1 << 2
MIX_NOISE_A = 1 << 3
MIX_NOISE_B = 1 << 4
MIX_NOISE_C = 1 << 5
MIX_PORT_A_OUT = 1 << 6

R_PERIOD_A, R_PERIOD_A_HI = 0, 1
R_PERIOD_B, R_PERIOD_B_HI = 2, 3
R_PERIOD_C, R_PERIOD_C_HI = 4, 5
R_NOISE = 6
R_MIXER = 7
R_AMP_A, R_AMP_B, R_AMP_C = 8, 9, 10

ALL_MUTED = 0x3F

#  Lengths from the descriptors in src/sys/sound.asm, as ticks. The tests use
#  them as the bound a sound must stop inside, never as the answer they expect.
#
#  A DESCRIPTOR'S TIMER IS IN STEPS AND NOT IN TICKS since the prescaler went
#  in, so a length in ticks is timer * slow. The two jumps are the only things
#  that use it: 100 steps of 3 ticks and 220 of 4, for the ten-times-slower
#  wipe they have to sit under.
FIRE_TICKS = 8
EXPLOSION_TICKS = 24
HIT_TICKS = 6
#  Read out of the descriptors rather than written down: a sound's length is
#  its timer times its PRESCALER, and halving the reveal halved the prescaler.
#  Written down, these two rot silently into a budget nothing is measured
#  against -- 880 was the arrival's length until the reveal was made twice as
#  fast, and a test asserting "under 880" would have passed for ever after.
JUMP_OUT_TICKS = 300
JUMP_IN_TICKS = 440

#  The vanish's shortest possible length is arithmetic now rather than a
#  measurement, which is the one thing the slowdown made easier: every one of
#  JFX_VANISH_PASSES passes waits out JFX_VANISH_DWELL whole vertical blanks
#  whatever is on the screen, and then there are two dark passes. 14 * 23 + 2.
#  mis_jump runs the vanish to completion BEFORE fleet_disc_save, which holds
#  DI for the whole transfer, so the out sound has to be over inside that or
#  its tail freezes mid-envelope across the disc write.
SHORTEST_VANISH_TICKS = 324

KEY_ROWS = 10


def _w(value: int) -> list[int]:
    return [value & 0xFF, (value >> 8) & 0xFF]


_MACHINE = None


def machine():
    """One emulator for this whole module, booted once.

    CLAUDE.md's "one emulator per process" is not just a performance note. The
    fixtures below are seven classes and unittest calls setUpClass on each, so
    booting per class leaves seven live CPC handles around for the rest of the
    run -- and the suite then aborts, in a LATER module, with

        cpc_key_up: Assertion `sys && sys->valid' failed

    which looks like a keyboard bug in test_keyboard.py and is not one. Every
    test here puts the machine back to a known state anyway: setUp calls
    snd_init, and the contention fixture restores the interrupt vector.
    """
    global _MACHINE
    if _MACHINE is None:
        _MACHINE = h.boot_quick(frames=30)
    return _MACHINE


class SoundFixture(unittest.TestCase):
    """A booted machine, plus the ability to step the player and read the PSG."""

    @classmethod
    def setUpClass(cls):
        cls.c = machine()
        cls.sym = h.symbols()

        #  Free space between the end of the low 16K and the stack margin.
        #  LOW_END and not CODE_END: the entity table and the visible list sit
        #  between the two now -- see harness._scratch_base.
        base = cls.sym["LOW_END"]
        limit = 0x4000 - 256
        assert base + 0x180 < limit, (
            f"no room for the test scratch: LOW_END is #{base:04X}")
        cls.DONE = base
        cls.PSG_BUF = base + 0x10
        cls.SAVE = base + 0x30
        cls.IRQ_DIV = base + 0x50
        cls.IRQ_STUB = base + 0x60
        cls.STUB = base + 0xA0

        cls.irq_vector_orig = bytes(cls.c.read_ram(0x0039, 2))

    def setUp(self):
        self.silence()

    # ------------------------------------------------------------------ Z80

    def tail(self) -> list[int]:
        """Stop the machine dead and flag that the stub finished.

        The DI matters: it freezes whatever the player did, so a readback
        taken afterwards cannot drift while Python is polling for the flag.
        """
        return [0xF3] + [0x3E, 0xAA, 0x32] + _w(self.DONE) + [0x18, 0xFE]

    def run_stub(self, code, max_frames: int = 120) -> int:
        """Poke `code` (which must end in tail()), run it, wait for the flag.

        Returns how many PAL frames it took, which is what the cost test
        measures with.
        """
        self.c.write_ram(self.DONE, b"\x00")
        self.c.write_ram(self.STUB, bytes(code))
        self.c.set_pc(self.STUB)
        for frames in range(1, max_frames + 1):
            self.c.run_frames(1)
            if self.c.read_ram(self.DONE, 1)[0] == 0xAA:
                return frames
        self.fail(f"the stub never finished within {max_frames} frames")

    def call(self, symbol: str):
        addr = self.sym[symbol]
        self.run_stub([0xF3, 0xCD] + _w(addr) + self.tail())

    def silence(self):
        self.call("SND_INIT")

    def fire(self):
        self.call("SND_FIRE")

    def explosion(self):
        self.call("SND_EXPLOSION")

    def hit(self):
        self.call("SND_HIT")

    def jump_out(self):
        self.call("SND_JUMP_OUT")

    def jump_in(self):
        self.call("SND_JUMP_IN")

    def tick(self, n: int = 1):
        """Run snd_update n times, the way the interrupt would.

        The stub counts in B, so a run longer than 255 is several stubs. That
        is not a detail any more: the jump in is 880 ticks, and a caller that
        had to know about the 255 would be doing this arithmetic at half a
        dozen call sites.
        """
        assert n >= 1
        while n:
            self._tick_block(min(n, 255))
            n -= min(n, 255)

    def _tick_block(self, n: int):
        assert 1 <= n <= 255
        addr = self.sym["SND_UPDATE"]
        body = [0xC5, 0xCD] + _w(addr) + [0xC1]
        code = [0xF3, 0x06, n] + body
        code += [0x10, (-(len(body) + 2)) & 0xFF]       # djnz
        self.run_stub(code + self.tail())

    # ------------------------------------------------------------- the PSG

    def psg(self) -> list[int]:
        """Read PSG registers 0..13 back out of the chip.

        Same handshake key_scan uses for register 14, one register at a time:
        hand the AY an address with port A as an output, flip port A to an
        input, put the PSG control lines in READ, and IN. Port A is left as an
        output again afterwards, which is the resting state both key_scan and
        snd_update expect to find.
        """
        buf = self.PSG_BUF
        code = [0xF3]                                   # di
        code += [0x21] + _w(buf)                        # ld hl,buf
        code += [0x16, 0x00]                            # ld d,0   register no.
        code += [0x0E, 0x00]                            # ld c,0   port low byte
        body = []
        body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]    # PPI: port A = output
        body += [0x06, 0xF4, 0x7A, 0xED, 0x79]          # register number out
        body += [0x06, 0xF6, 0x3E, 0xC0, 0xED, 0x79]    # PSG_SELECT: latch it
        body += [0xAF, 0xED, 0x79]                      # PSG_INACTIVE
        body += [0x06, 0xF7, 0x3E, 0x92, 0xED, 0x79]    # PPI: port A = INPUT
        body += [0x06, 0xF6, 0x3E, 0x40, 0xED, 0x79]    # PSG_READ
        body += [0x06, 0xF4, 0xED, 0x78]                # in a,(#F4xx)
        body += [0x77, 0x23]                            # ld (hl),a : inc hl
        body += [0x06, 0xF6, 0xAF, 0xED, 0x79]          # PSG_INACTIVE
        body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]    # PPI: port A = output
        body += [0x14, 0x7A, 0xFE, 0x0E]                # inc d : ld a,d : cp 14
        body += [0x38, (-(len(body) + 2)) & 0xFF]       # jr c,-> next register
        self.run_stub(code + body + self.tail())
        return list(self.c.read_ram(buf, 14))

    def amps(self) -> tuple[int, int, int]:
        r = self.psg()
        return r[R_AMP_A], r[R_AMP_B], r[R_AMP_C]

    def mixer(self) -> int:
        return self.psg()[R_MIXER]

    def assert_silent(self, why: str = ""):
        r = self.psg()
        self.assertEqual(
            (r[R_AMP_A], r[R_AMP_B], r[R_AMP_C]), (0, 0, 0),
            f"{why}: amplitudes are {r[R_AMP_A]}/{r[R_AMP_B]}/{r[R_AMP_C]}")
        self.assertEqual(
            r[R_MIXER], ALL_MUTED,
            f"{why}: mixer is #{r[R_MIXER]:02X}, expected #{ALL_MUTED:02X}")

    def sweep_c(self, ticks: int, every: int = 1) -> list[tuple[int, int]]:
        """(tone period, amplitude) off channel C, once every `every` ticks.

        The whole sound, sampled at the rate it MOVES at, out of the chip's own
        registers. Every assertion about a jump is made against one of these
        lists rather than against the descriptor bytes: a descriptor is a
        statement of intent and this is what the AY was actually told.

        `every` is the voice's own prescaler, so a sample is one STEP of the
        sound and the list is the sequence of values it actually took. It is
        not only economy -- though it is that as well: reading fourteen PSG
        registers a tick through a stub for 880 ticks is a minute of wall
        clock, and the 878 samples in between the 220 steps are copies of their
        neighbours by construction.
        """
        out = []
        for _ in range(ticks // every):
            self.tick(every)
            r = self.psg()
            out.append((r[R_PERIOD_C] | (r[R_PERIOD_C_HI] << 8), r[R_AMP_C]))
        return out

    def slow_of(self, name: str) -> int:
        """A descriptor's prescaler, off the build rather than copied here."""
        return self.c.read_ram(self.sym[name] + self.sym["SND_V_SLOW"], 1)[0]

    @staticmethod
    def audible(sweep):
        """The part of a sweep with the amplitude off zero, as (period, amp)."""
        return [s for s in sweep if s[1] > 0]

    def ticks_until_silent(self, limit: int = 80, every: int = 1) -> int:
        """How many further ticks before every channel is off. None if never.

        `every` is the granularity of the answer, and a caller that passes the
        voice's prescaler gets an answer that is exact to within one step --
        which is all the resolution the sound has. The jump halves are 300 and
        880 ticks, so asking this a tick at a time would be twelve hundred PSG
        reads through a stub to learn something a sixth of that says.
        """
        for n in range(every, limit + 1, every):
            self.tick(every)
            r = self.psg()
            if (r[R_AMP_A], r[R_AMP_B], r[R_AMP_C]) == (0, 0, 0) \
                    and r[R_MIXER] == ALL_MUTED:
                return n
        return None


class TestInit(SoundFixture):
    """snd_init has one job and it is the one the player is judged on."""

    def test_every_channel_is_silent(self):
        self.assert_silent("after snd_init")

    def test_the_hardware_envelope_is_not_in_use(self):
        """Amplitude bit 4 selects the AY's single shared envelope generator.

        There is only one of it, so if two channels ever asked for it they
        would retrigger each other. The player decays in software instead, and
        this is the assertion that keeps it that way.
        """
        r = self.psg()
        for reg, name in ((R_AMP_A, "A"), (R_AMP_B, "B"), (R_AMP_C, "C")):
            self.assertEqual(r[reg] & 0x10, 0,
                             f"channel {name} is using the hardware envelope")

    def test_the_mixer_leaves_the_psg_port_an_input(self):
        """Mixer bit 6 is the PSG's own port A direction, not a sound bit.

        Set it and the keyboard columns stop reaching the CPU -- the sound
        would be perfect and the machine would stop responding to keys, with
        nothing in keyboard.asm to blame.
        """
        self.assertEqual(self.mixer() & MIX_PORT_A_OUT, 0)

    def test_it_is_idempotent(self):
        for _ in range(3):
            self.silence()
            self.assert_silent("after repeated snd_init")

    def test_it_silences_a_sound_in_progress(self):
        self.explosion()
        self.tick(2)
        self.assertGreater(self.amps()[1], 0)
        self.silence()
        self.assert_silent("snd_init over a live explosion")


class TestFire(SoundFixture):
    """Channel A, a tone: Homeplanet.md section 12."""

    def test_it_is_audible_on_channel_a(self):
        self.fire()
        self.tick()
        r = self.psg()
        self.assertGreater(r[R_AMP_A], 0, "channel A is silent after snd_fire")
        self.assertEqual(r[R_MIXER] & MIX_TONE_A, 0, "tone A is still muted")
        self.assertNotEqual((r[R_PERIOD_A], r[R_PERIOD_A_HI]), (0, 0),
                            "channel A has no pitch")

    def test_it_is_a_tone_and_not_noise(self):
        self.fire()
        self.tick()
        self.assertEqual(self.mixer() & MIX_NOISE_A, MIX_NOISE_A,
                         "snd_fire opened the noise generator on channel A")

    def test_it_leaves_the_other_channels_alone(self):
        self.fire()
        self.tick()
        _, b, c = self.amps()
        self.assertEqual((b, c), (0, 0))

    def test_the_pitch_falls(self):
        """A discharge sweeps down; a constant period would be a beep."""
        self.fire()
        self.tick()
        first = self.psg()
        self.tick(4)
        later = self.psg()
        p0 = first[R_PERIOD_A] | (first[R_PERIOD_A_HI] << 8)
        p1 = later[R_PERIOD_A] | (later[R_PERIOD_A_HI] << 8)
        self.assertGreater(p1, p0,
                           "the tone period did not rise, so the pitch did "
                           f"not fall: {p0} -> {p1}")

    def test_it_decays_and_stops(self):
        """The classic bug is a sound that never ends. Bound it."""
        self.fire()
        self.tick()
        self.assertGreater(self.amps()[0], 0, "nothing to decay from")
        n = self.ticks_until_silent(limit=FIRE_TICKS * 4)
        self.assertIsNotNone(
            n, f"channel A was still on after {FIRE_TICKS * 4} ticks")
        self.assertLessEqual(n + 1, FIRE_TICKS + 1,
                             f"snd_fire ran for {n + 1} ticks, budget "
                             f"{FIRE_TICKS}")

    def test_it_stays_stopped(self):
        self.fire()
        self.tick(FIRE_TICKS + 1)
        self.assert_silent("when the fire effect ended")
        self.tick(30)
        self.assert_silent("30 ticks after the fire effect ended")

    def test_the_volume_only_goes_down(self):
        self.fire()
        seen = []
        for _ in range(FIRE_TICKS):
            self.tick()
            seen.append(self.amps()[0])
        self.assertEqual(seen, sorted(seen, reverse=True),
                         f"the envelope is not monotonic: {seen}")
        self.assertEqual(seen[-1], 0, f"it did not reach zero: {seen}")

    def test_firing_again_retriggers_it(self):
        self.fire()
        self.tick(FIRE_TICKS - 2)
        quiet = self.amps()[0]
        self.fire()
        self.tick()
        self.assertGreater(self.amps()[0], quiet,
                           "a second shot did not restart the envelope")


class TestExplosion(SoundFixture):
    """Channel B, the NOISE generator: section 12 again."""

    def test_it_engages_the_noise_generator_not_a_tone(self):
        self.explosion()
        self.tick()
        r = self.psg()
        self.assertEqual(r[R_MIXER] & MIX_NOISE_B, 0,
                         f"noise B is muted: mixer #{r[R_MIXER]:02X}")
        self.assertEqual(r[R_MIXER] & MIX_TONE_B, MIX_TONE_B,
                         f"tone B is open, so this is a pitched note and not "
                         f"an explosion: mixer #{r[R_MIXER]:02X}")
        self.assertGreater(r[R_AMP_B], 0, "channel B is silent")

    def test_the_noise_period_is_programmed_and_in_range(self):
        self.explosion()
        self.tick()
        noise = self.psg()[R_NOISE]
        self.assertGreater(noise, 0, "R6 is 0, the noise generator has no rate")
        self.assertLessEqual(noise, 31, "R6 is only five bits wide")

    def test_the_noise_period_sweeps(self):
        """A crack collapsing into a rumble, not a flat hiss."""
        self.explosion()
        self.tick()
        early = self.psg()[R_NOISE]
        self.tick(12)
        late = self.psg()[R_NOISE]
        self.assertGreater(late, early,
                           f"the noise period did not sweep: {early} -> {late}")
        self.assertLessEqual(late, 31)

    def test_it_does_not_touch_a_or_c(self):
        self.explosion()
        self.tick(3)
        a, _, c = self.amps()
        self.assertEqual((a, c), (0, 0))
        m = self.mixer()
        self.assertEqual(m & MIX_TONE_A, MIX_TONE_A)
        self.assertEqual(m & MIX_TONE_C, MIX_TONE_C)

    def test_it_decays_and_stops(self):
        self.explosion()
        self.tick()
        self.assertGreater(self.amps()[1], 0)
        n = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.assertIsNotNone(
            n, f"channel B was still on after {EXPLOSION_TICKS * 3} ticks")
        self.assertLessEqual(n + 1, EXPLOSION_TICKS + 1,
                             f"the explosion ran for {n + 1} ticks")

    def test_it_lasts_longer_than_a_hit(self):
        self.explosion()
        long = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.silence()
        self.hit()
        short = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.assertGreater(long, short,
                           f"a death ({long} ticks) is no longer than a graze "
                           f"({short} ticks)")


class TestHit(SoundFixture):
    """Section 12 puts a hull breach on channel B's noise, beside the deaths."""

    def test_it_is_noise_on_channel_b(self):
        self.hit()
        self.tick()
        r = self.psg()
        self.assertEqual(r[R_MIXER] & MIX_NOISE_B, 0, "noise B is muted")
        self.assertEqual(r[R_MIXER] & MIX_TONE_B, MIX_TONE_B, "tone B is open")
        self.assertGreater(r[R_AMP_B], 0)

    def test_it_decays_and_stops(self):
        self.hit()
        n = self.ticks_until_silent(limit=HIT_TICKS * 5)
        self.assertIsNotNone(n, "channel B never went quiet after snd_hit")
        self.assertLessEqual(n, HIT_TICKS + 1, f"snd_hit ran {n} ticks")

    def test_it_sounds_different_from_an_explosion(self):
        """Same channel, same generator -- so the timbre has to carry it.

        If both effects produced the same noise period and the same volume,
        the player would be telling the player 'something happened' and
        nothing more.
        """
        self.hit()
        self.tick()
        hit = self.psg()
        self.silence()
        self.explosion()
        self.tick()
        boom = self.psg()
        self.assertNotEqual(
            (hit[R_NOISE], hit[R_AMP_B]), (boom[R_NOISE], boom[R_AMP_B]),
            "a hit and a death are the same sound")


class TestTheJump(SoundFixture):
    """One sound going out and one coming in -- and they are a PAIR.

    "One sound for the jump out and one for the jump in." So the assertions
    that matter here are not "an effect was started" -- that survives the wrong
    channel, the wrong pitch, a sweep running backwards and outright silence.
    Every one of them is made against the PERIODS AND AMPLITUDES OVER TIME,
    read back out of the AY a tick at a time, and the sharpest is the last one
    in the class: the two sounds have to traverse the same span of pitch in
    opposite directions, or they are two unrelated noises rather than a
    departure and an arrival.
    """

    #  --- the channel, which is a decision and not an accident ---------------

    def test_both_halves_are_a_tone_on_channel_c(self):
        """Section 12's own assignment: C is "the menu / JUMP / mission-end".

        A tone and not noise, because a jump is a drive spooling up and not an
        explosion -- and channel C specifically, because it is the one voice
        nothing else in the game has ever used, so the jump can neither be cut
        off by a shot on A nor mute a death on B.
        """
        for start, name in ((self.jump_out, "out"), (self.jump_in, "in")):
            with self.subTest(half=name):
                self.silence()
                start()
                self.tick()
                r = self.psg()
                self.assertGreater(r[R_AMP_C], 0,
                                   f"the jump {name} is silent on channel C")
                self.assertEqual(r[R_MIXER] & MIX_TONE_C, 0,
                                 f"tone C is muted: mixer #{r[R_MIXER]:02X}")
                self.assertEqual(
                    r[R_MIXER] & MIX_NOISE_C, MIX_NOISE_C,
                    f"the jump opened the noise generator on C, so it is an "
                    f"explosion and not a drive: mixer #{r[R_MIXER]:02X}")
                self.assertNotEqual(
                    (r[R_PERIOD_C], r[R_PERIOD_C_HI]), (0, 0),
                    f"the jump {name} has no pitch")

    def test_neither_half_disturbs_the_battle(self):
        """A and B belong to the guns. The jump must not go near them."""
        for start, name in ((self.jump_out, "out"), (self.jump_in, "in")):
            with self.subTest(half=name):
                self.silence()
                start()
                self.tick(3)
                a, b, _ = self.amps()
                self.assertEqual((a, b), (0, 0),
                                 f"the jump {name} made a noise on A or B")
                m = self.mixer()
                self.assertEqual(m & MIX_TONE_A, MIX_TONE_A)
                self.assertEqual(m & MIX_NOISE_B, MIX_NOISE_B)

    def test_a_battle_cannot_take_the_channel_from_a_jump(self):
        """Not by priority -- by living somewhere else entirely.

        Priorities are only ever compared WITHIN a channel, so SND_PRI_JUMP
        outranking the three battle effects is a statement about a future in
        which C also carries the alerts section 12 promises it. What actually
        protects the jump today is that nothing else uses C at all, and that is
        what this checks: a full battle over the top of a jump leaves it
        playing, and sweeping.
        """
        self.jump_out()
        self.tick(2)
        before = self.psg()
        for _ in range(4):
            self.fire()
            self.explosion()
            self.hit()
            self.tick(2)
        after = self.psg()
        self.assertGreater(after[R_AMP_C], 0,
                           "a battle silenced the jump on channel C")
        p0 = before[R_PERIOD_C] | (before[R_PERIOD_C_HI] << 8)
        p1 = after[R_PERIOD_C] | (after[R_PERIOD_C_HI] << 8)
        self.assertNotEqual(p1, p0,
                            f"the jump's sweep froze while the guns ran: "
                            f"period {p0} both times")

    #  --- the gesture --------------------------------------------------------

    def test_the_out_sweeps_up_while_it_thins_away(self):
        """The fleet dissolving: the pitch climbs as the level falls off it.

        Period DOWN is pitch UP -- the AY divides by it -- so a test that only
        watched the number go one way would be happy with the sound running
        backwards. Both directions are stated, and both are read off the chip.
        """
        slow = self.slow_of("SND_FX_JUMP_OUT")
        self.jump_out()
        sweep = self.sweep_c(JUMP_OUT_TICKS, every=slow)
        aud = self.audible(sweep)
        self.assertGreater(len(aud), 20,
                           f"only {len(aud)} steps of the out are audible")

        periods = [p for p, _ in aud]
        self.assertEqual(periods, sorted(periods, reverse=True),
                         f"the out's period is not monotonically falling, so "
                         f"the pitch does not climb: {periods}")
        self.assertGreater(periods[0], periods[-1] * 4,
                           f"the out barely moves: {periods[0]} -> "
                           f"{periods[-1]}, under two octaves")

        amps = [a for _, a in sweep]
        self.assertEqual(amps, sorted(amps, reverse=True),
                         f"the out's level does not only fall: {amps}")
        self.assertEqual(amps[-1], 0, f"it does not fade out: {amps}")

    def test_the_in_sweeps_down_and_settles(self):
        """The mirror: something falling into place."""
        slow = self.slow_of("SND_FX_JUMP_IN")
        self.jump_in()
        sweep = self.sweep_c(JUMP_IN_TICKS, every=slow)
        aud = self.audible(sweep)
        self.assertGreater(len(aud), 60,
                           f"only {len(aud)} steps of the in are audible")

        periods = [p for p, _ in aud]
        self.assertEqual(periods, sorted(periods),
                         f"the in's period is not monotonically rising, so the "
                         f"pitch does not fall: {periods}")
        self.assertGreater(periods[-1], periods[0] * 4,
                           f"the in barely moves: {periods[0]} -> "
                           f"{periods[-1]}")

        amps = [a for _, a in sweep]
        self.assertEqual(amps, sorted(amps, reverse=True),
                         f"the in's level does not only fall: {amps}")
        self.assertEqual(amps[-1], 0, f"it does not fade out: {amps}")

    def test_they_are_one_gesture_run_both_ways(self):
        """The whole point of the pair, stated as an assertion on the chip.

        A player has to hear "left" and "arrived" rather than two unrelated
        noises, and what makes that true is that both halves cross the SAME
        span of pitch. So: the out ends where the in begins and the in ends
        where the out began, to within a tick of sweep at each end -- and they
        go opposite ways, which the two tests above have already established
        separately and this one states about the pair.
        """
        self.silence()
        self.jump_out()
        out = self.audible(self.sweep_c(JUMP_OUT_TICKS,
                                        every=self.slow_of("SND_FX_JUMP_OUT")))
        self.silence()
        self.jump_in()
        into = self.audible(self.sweep_c(JUMP_IN_TICKS,
                                         every=self.slow_of("SND_FX_JUMP_IN")))

        out_lo, out_hi = out[0][0], out[-1][0]          # period: low pitch first
        in_hi, in_lo = into[0][0], into[-1][0]          # ...and high pitch first

        def close(a, b, why):
            #  A fifth: wide enough that neither descriptor has to be tuned to
            #  the other, narrow enough that a different sweep fails it.
            self.assertLess(
                max(a, b) / min(a, b), 1.5,
                f"{why}: periods {a} and {b} are more than a fifth apart, so "
                f"the two halves are not the same gesture")

        close(out_hi, in_hi, "the out ends and the in begins")
        close(out_lo, in_lo, "the out begins and the in ends")

        self.assertGreater(out_lo, out_hi, "the out does not rise in pitch")
        self.assertGreater(in_lo, in_hi, "the in does not fall in pitch")

    #  --- the lengths, and the disc write ------------------------------------

    def test_the_out_ends_inside_the_shortest_vanish_there_is(self):
        """The one timing trap in this feature, and it is not on the screen.

        mis_jump calls jfx_vanish, which runs to completion, and only then
        fleet_disc_save -- which holds DI across the whole transfer, measured
        at 24 emulator frames. snd_update does not run inside that, so a sound
        still going would freeze mid-envelope and resume half a second later.

        The vanish is ten times longer than it was and so is the sound, so the
        trap is exactly where it was: 300 ticks against a vanish that cannot be
        shorter than 324 whatever is on the screen. The level reaches zero
        before the timer does either way, which is the second net -- a frozen
        channel at amplitude 0 is silence.
        """
        slow = self.slow_of("SND_FX_JUMP_OUT")
        self.jump_out()
        n = self.ticks_until_silent(limit=SHORTEST_VANISH_TICKS + 60,
                                    every=slow)
        self.assertIsNotNone(
            n, "channel C never went quiet after the jump out")
        self.assertLessEqual(
            n, SHORTEST_VANISH_TICKS,
            f"the jump out runs {n} ticks and the shortest vanish is "
            f"{SHORTEST_VANISH_TICKS} -- its tail lands in the disc write's DI")
        self.assertLessEqual(n, JUMP_OUT_TICKS + slow,
                             f"the jump out ran {n} ticks, budget "
                             f"{JUMP_OUT_TICKS}")

    def test_the_arrival_is_the_long_one(self):
        """Vanish 7.2 s, reveal 9.4 s. The sounds are the same shape."""
        out_slow = self.slow_of("SND_FX_JUMP_OUT")
        in_slow = self.slow_of("SND_FX_JUMP_IN")
        self.jump_out()
        short = self.ticks_until_silent(limit=JUMP_IN_TICKS, every=out_slow)
        self.silence()
        self.jump_in()
        long = self.ticks_until_silent(limit=JUMP_IN_TICKS + 40, every=in_slow)
        self.assertIsNotNone(long, "the arrival never stopped")
        #  LONGER, and not "more than twice as long". The ratio was 300 against
        #  880 and is now 300 against 440, because the reveal was made twice as
        #  fast and the sound went with it -- the property is that the arrival
        #  is the longer half and that each sound finishes inside its own half
        #  of the wipe, which is what the budget below says. A ratio is a
        #  figure from the day it was written.
        self.assertGreater(long, short,
                           f"the arrival ({long} ticks) is not the longer half "
                           f"against the departure ({short})")
        self.assertLessEqual(long, JUMP_IN_TICKS + in_slow,
                             f"the arrival ran {long} ticks, budget "
                             f"{JUMP_IN_TICKS}")

    def test_neither_half_is_left_droning(self):
        """...and the timer, not the decay, is what stops it.

        The prescaler made this one sharper rather than weaker: a sound now
        outlives its own silence by design -- the out is quiet from tick 279
        and its timer does not expire until 300 -- so "is it silent" and "has
        it let the channel go" are genuinely different questions. The second
        tick() here is what asks the second one.
        """
        for start, name in ((self.jump_out, "out"), (self.jump_in, "in")):
            with self.subTest(half=name):
                self.silence()
                start()
                self.tick(JUMP_IN_TICKS + 8)
                self.assert_silent(f"when the jump {name} ended")
                self.tick(40)
                self.assert_silent(f"40 ticks after the jump {name} ended")

    def test_arriving_takes_the_channel_from_a_departure(self):
        """Same priority, so "at least" lets one retrigger the other.

        Nothing in the game overlaps them -- the briefing sits between the two
        halves -- but a shared priority that REFUSED would leave the arrival
        silent the first time anything did, and that is a failure mode with no
        symptom other than a missing sound.
        """
        self.jump_out()
        #  HALFWAY, not four ticks off the end. The out is now silent for its
        #  last twenty-odd ticks by design, and "louder than silence" is not
        #  the question -- the question is whether it takes a channel that is
        #  still sounding.
        self.tick(JUMP_OUT_TICKS // 2)
        faded = self.amps()[2]
        self.assertGreater(faded, 0, "the out is already silent halfway "
                                     "through: nothing to take the channel from")
        self.jump_in()
        self.tick()
        self.assertGreater(self.amps()[2], faded,
                           "the arrival did not take channel C from a "
                           "departure that was still fading")


class TestThePrescaler(SoundFixture):
    """A voice steps every `slow` ticks, and that is what buys a long sound.

    The timer is one byte and it is the only thing that ends a sound, so before
    this the engine could not play anything longer than 255 ticks -- 5.1
    seconds. The jump wants 300 going out and 880 coming back. Every assertion
    here is read off the CHIP while the player runs, because the interesting
    claim is not "there is a byte at +8" but "the AY was told the same thing
    three ticks running and then a different thing".
    """

    def period_c(self):
        r = self.psg()
        return r[R_PERIOD_C] | (r[R_PERIOD_C_HI] << 8)

    def test_a_slowed_voice_holds_its_pitch_between_steps(self):
        """The mechanism itself: `slow` ticks of one value, then a new one.

        Read against the descriptor's own `slow` rather than against 4, so it
        follows the sound if the constant is retuned -- and it fails if the
        prescaler is bypassed altogether, because then every tick moves.

        IT ASKS FOR A PATTERN AND NOT FOR A PARTICULAR TICK, and that is the
        repair rather than a flourish. It used to start counting at the first
        tick after the sound was started and assert that ticks 2..slow held --
        which is only true if no tick has gone by in between, and `jump_in`
        does not promise that. At slow 4 the assumption landed inside the hold
        window and the test passed; halving `slow` to make the sound twice as
        fast moved the phase by one and it failed, saying "the prescaler is not
        holding it" about a prescaler that was working perfectly.

        The phase-free statement is the one that was meant all along: over a
        long enough stretch, every run of equal periods is `slow` long.
        """
        slow = self.slow_of("SND_FX_JUMP_IN")
        self.assertGreater(slow, 1, "the in is not prescaled at all, so this "
                                    "test cannot observe anything")
        self.silence()
        self.jump_in()

        seen = []
        for _ in range(slow * 5 + 1):
            self.tick()
            seen.append(self.period_c())

        runs = []
        for p in seen:
            if runs and runs[-1][0] == p:
                runs[-1][1] += 1
            else:
                runs.append([p, 1])
        self.assertGreater(len(runs), 2,
                           f"the period never moved at all over {len(seen)} "
                           f"ticks: {seen}")
        #  The first and last runs are cut off by where the sampling started
        #  and stopped, so only the whole ones in between can be measured.
        for value, length in runs[1:-1]:
            self.assertEqual(
                length, slow,
                f"period {value} was held for {length} ticks on a voice that "
                f"steps every {slow}: the prescaler is not holding it. "
                f"{seen}")

    def test_the_level_is_held_too_and_not_only_the_pitch(self):
        """Both halves of the envelope are behind the same counter.

        A prescaler on the sweep alone would leave `dvol` running at 50 Hz,
        and the decay would then reach silence a quarter of the way through
        the sound it belongs to -- which is a bug with no symptom other than a
        transition that plays in silence for thirteen seconds.
        """
        slow = self.slow_of("SND_FX_JUMP_IN")
        self.silence()
        self.jump_in()
        self.tick()
        first = self.amps()[2]
        self.assertGreater(first, 0)
        for i in range(1, slow):
            self.tick()
            self.assertEqual(self.amps()[2], first,
                             f"the level moved on tick {i + 1} of {slow}")

    def test_it_is_what_makes_a_sound_longer_than_a_byte_of_ticks(self):
        """255 is the wall this exists to get over, and both jumps are past it.

        The claim is about the CHIP and not about the descriptor: the in is
        still sounding well after the longest sound a one-tick-per-step engine
        could possibly play, whatever it put in its timer.
        """
        self.silence()
        self.jump_in()
        self.tick(255)
        self.assertGreater(
            self.amps()[2], 0,
            "channel C is silent after 255 ticks, which is every tick a "
            "one-byte timer can count -- the prescaler is not working")
        self.assertGreater(JUMP_IN_TICKS, 255)

    def test_the_battle_effects_are_not_prescaled(self):
        """slow 1 everywhere else, so nothing else changed shape.

        These three are 6, 8 and 24 ticks and want every one of them; the
        prescaler is a jump feature that the other descriptors pay one byte
        for. A stray `slow` of 2 on the fire would double every laser shot and
        nothing else in the suite would notice.
        """
        for name in ("SND_FX_FIRE", "SND_FX_EXPLOSION", "SND_FX_HIT"):
            with self.subTest(effect=name):
                self.assertEqual(self.slow_of(name), 1,
                                 f"{name} is prescaled")

    def test_every_descriptor_starts_its_countdown_at_one(self):
        """+9 is 1 in every descriptor, and 0 would be read as 256.

        snd_step decrements slowc and steps when it hits zero, so a descriptor
        that shipped a 0 there would hold the sound silent-and-still for five
        seconds before its first step -- and the timer, which only counts
        steps, would then run for 256 times as long as it says.
        """
        for name in ("SND_FX_FIRE", "SND_FX_EXPLOSION", "SND_FX_HIT",
                     "SND_FX_JUMP_OUT", "SND_FX_JUMP_IN"):
            with self.subTest(effect=name):
                at = self.sym[name] + self.sym["SND_V_SLOWC"]
                self.assertEqual(self.c.read_ram(at, 1)[0], 1,
                                 f"{name} does not step on its first tick")


class TestChannelArbitration(SoundFixture):
    """Two things at once -- the case that leaves a channel droning."""

    def test_fire_and_explosion_play_together(self):
        self.fire()
        self.explosion()
        self.tick()
        r = self.psg()
        self.assertGreater(r[R_AMP_A], 0, "the shot was lost")
        self.assertGreater(r[R_AMP_B], 0, "the explosion was lost")
        self.assertEqual(r[R_MIXER] & MIX_TONE_A, 0)
        self.assertEqual(r[R_MIXER] & MIX_NOISE_B, 0)

    def test_the_shorter_one_ending_does_not_take_the_other_with_it(self):
        """Independent envelopes, which is the whole reason they are software."""
        self.fire()
        self.explosion()
        self.tick(FIRE_TICKS + 2)
        r = self.psg()
        self.assertEqual(r[R_AMP_A], 0, "the shot outlived its timer")
        self.assertEqual(r[R_MIXER] & MIX_TONE_A, MIX_TONE_A,
                         "tone A is still open with the amplitude at zero")
        self.assertGreater(r[R_AMP_B], 0,
                           "the shot ending killed the explosion too")

    def test_neither_channel_is_left_stuck_on(self):
        self.fire()
        self.explosion()
        n = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.assertIsNotNone(n, "a channel was left on after both effects")
        self.tick(20)
        self.assert_silent("20 ticks after both effects finished")

    def test_a_graze_cannot_cut_a_death_short(self):
        """Both live on channel B, so one of them has to lose. Not this one.

        Without the priority check, a ship taking a scratch two ticks after a
        neighbour blew up would replace a 24-tick explosion with a 6-tick
        crunch, and the biggest event on screen would be the quietest.
        """
        self.explosion()
        self.tick(2)
        self.hit()
        self.tick(HIT_TICKS + 2)
        self.assertGreater(
            self.amps()[1], 0,
            "the hit took channel B from the explosion and has already ended")
        n = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.assertIsNotNone(n)

    def test_a_death_takes_the_channel_from_a_graze(self):
        self.hit()
        self.tick(1)
        self.explosion()
        self.tick(HIT_TICKS + 3)
        self.assertGreater(self.amps()[1], 0,
                           "the explosion did not take over from the hit")
        n = self.ticks_until_silent(limit=EXPLOSION_TICKS * 3)
        self.assertIsNotNone(n, "and then it never stopped")

    def test_a_stream_of_overlapping_effects_still_ends(self):
        """The realistic case: a battle, and then it is over."""
        for i in range(12):
            self.fire()
            if i % 3 == 0:
                self.explosion()
            if i % 4 == 0:
                self.hit()
            self.tick(2)
        n = self.ticks_until_silent(limit=EXPLOSION_TICKS * 4)
        self.assertIsNotNone(n, "the battle never went quiet")


class TestPpiContention(SoundFixture):
    """snd_update and key_scan on the same 50 Hz tick, one PSG between them.

    This is the test the whole exercise turns on. PPI port A is the data bus
    between the CPU and the PSG and it points one way at a time; key_scan needs
    it pointing in, the player needs it pointing out.

    They used to be on opposite sides of the interrupt -- the player in it, the
    scan in the main loop -- and the risk was one of them landing in the middle
    of the other's handshake. That risk is gone: the scan moved into the
    interrupt when it turned out a scan per game frame drops half of every
    keypress, so the two now run back to back on the same tick and nothing else
    in the game touches the PPI at all.

    What has NOT gone is the resting-state contract, and this class is still
    where breaking it surfaces. So the rig now mirrors the shipped sys_irq
    exactly: an IM 1 handler, saving AF and HL and nothing else, calling
    key_scan and then snd_update every sixth interrupt. The "main loop" does
    what the real one does, which is not touch the PSG -- it just burns time
    while the two of them take turns.
    """

    #  How long `run_ticks` spins per tick it is asked for: one PAL frame is
    #  20 ms of a 4 MHz Z80, and the delay loop below is 26 T-states an
    #  iteration. The divider is 6 against a 300 Hz interrupt, so one 50 Hz
    #  tick is one PAL frame.
    SPIN_PER_TICK = int(20e-3 * 4e6 / 26)

    def setUp(self):
        super().setUp()
        self.install_sound_irq()

    def tearDown(self):
        self.c.key_up("1")
        self.c.write_ram(0x0039, self.irq_vector_orig)
        self.c.run_frames(2)

    def install_sound_irq(self):
        """An IM 1 handler shaped exactly like the shipped sys_irq.

        Deliberately saves AF and HL and nothing else -- that is the contract
        both callees have to live inside, so the handler must not paper over
        it. key_scan is called first, for the same reason sys_irq calls it
        first: it leaves the PPI in the resting state, and snd_update's
        defensive re-assert of the port direction then has something real to
        do.
        """
        scan = self.sym["KEY_SCAN"]
        upd = self.sym["SND_UPDATE"]
        code = [0xF5, 0xE5]                             # push af : push hl
        code += [0x21] + _w(self.IRQ_DIV)               # ld hl,divider
        code += [0x35]                                  # dec (hl)
        code += [0x20, 0x08]                            # jr nz,@not_50hz
        code += [0x36, 0x06]                            # ld (hl),6
        code += [0xCD] + _w(scan)                       # call key_scan
        code += [0xCD] + _w(upd)                        # call snd_update
        code += [0xE1, 0xF1, 0xFB, 0xED, 0x4D]          # pop/pop/ei/reti
        self.c.write_ram(self.IRQ_STUB, bytes(code))
        self.c.write_ram(self.IRQ_DIV, b"\x06")
        self.c.write_ram(0x0039, struct.pack("<H", self.IRQ_STUB))

    def run_ticks(self, ticks: int):
        """Let the machine run for about `ticks` 50 Hz ticks, interrupts live.

        A plain delay loop, because the main loop's part in this is now to stay
        out of the way. It must not use the PSG or the PPI: if it did, the
        thing under test would be the test's own handshake and not the game's.
        """
        count = ticks * self.SPIN_PER_TICK
        body = [0x0B, 0x78, 0xB1]                       # dec bc : ld a,b : or c
        code = [0xFB, 0x01] + _w(count)                 # ei : ld bc,count
        code += body + [0x20, (-(len(body) + 2)) & 0xFF]
        self.run_stub(code + self.tail(), max_frames=ticks * 2 + 20)

    def key_state(self) -> list[int]:
        return list(self.c.read_ram(self.sym["KEY_STATE"], KEY_ROWS))

    def bits_down(self) -> int:
        return sum(bin(b).count("1") for b in self.key_state())

    def id_is_down(self, key_id: int) -> bool:
        return bool(self.key_state()[key_id >> 3] & (1 << (key_id & 7)))

    #  --- the interrupt on its own ------------------------------------------

    def test_the_interrupt_really_does_drive_the_player(self):
        """Guard the rig itself: everything below assumes this works.

        The divider means one tick per PAL frame, so run_ticks has to spin for
        at least a frame or the handler never gets a look in and every
        assertion below would pass by never running.
        """
        self.explosion()
        before = self.amps()[1]
        self.run_ticks(5)
        self.assertGreater(self.amps()[1], 0,
                           "the installed handler never called snd_update")
        self.assertEqual(before, 0,
                         "the explosion was already audible before any tick, "
                         "so this proves nothing about the interrupt")

    def test_the_tick_preserves_everything_sys_irq_does_not_save(self):
        """sys_irq saves AF and HL. The other twelve bytes are ours to keep.

        A callee that quietly used DE from the interrupt would corrupt whatever
        the main loop happened to be holding, at a rate of fifty times a second
        and never in the same place twice. That is not a bug anyone debugs from
        the symptom, so it gets caught here.

        It covers BOTH callees now. key_scan moved into the interrupt and needs
        BC and DE as much as snd_update does -- it walks a port in BC and two
        array pointers in HL and DE -- so it pushes them itself rather than
        widening the handler's contract for everyone.
        """
        sentinels = {
            "bc": 0x1234, "de": 0x5678, "ix": 0x9ABC, "iy": 0xDEF0,
            "bc'": 0x0F1E, "de'": 0x2D3C, "hl'": 0x4B5A,
        }
        s = self.SAVE
        code = [0xF3]                                   # di
        code += [0xD9]                                  # exx
        code += [0x01] + _w(sentinels["bc'"])
        code += [0x11] + _w(sentinels["de'"])
        code += [0x21] + _w(sentinels["hl'"])
        code += [0xD9]                                  # exx
        code += [0x01] + _w(sentinels["bc"])
        code += [0x11] + _w(sentinels["de"])
        code += [0xDD, 0x21] + _w(sentinels["ix"])
        code += [0xFD, 0x21] + _w(sentinels["iy"])
        code += [0xFB]                                  # ei
        #  Spin on HL and AF alone -- the two the handler is allowed to use --
        #  for long enough to take a few hundred interrupts.
        code += [0x21, 0xFF, 0xFF]                      # ld hl,#FFFF
        spin = [0x2B, 0x7C, 0xB5]                       # dec hl : ld a,h : or l
        code += spin + [0x20, (-(len(spin) + 2)) & 0xFF]
        code += [0xF3]                                  # di
        code += [0xED, 0x43] + _w(s + 0)                # ld (s+0),bc
        code += [0xED, 0x53] + _w(s + 2)                # ld (s+2),de
        code += [0xDD, 0x22] + _w(s + 4)                # ld (s+4),ix
        code += [0xFD, 0x22] + _w(s + 6)                # ld (s+6),iy
        code += [0xD9]                                  # exx
        code += [0xED, 0x43] + _w(s + 8)
        code += [0xED, 0x53] + _w(s + 10)
        code += [0x22] + _w(s + 12)                     # ld (s+12),hl
        code += [0xD9]                                  # exx

        self.explosion()
        self.run_stub(code + self.tail(), max_frames=200)

        got = struct.unpack("<7H", self.c.read_ram(s, 14))
        for (name, want), have in zip(sentinels.items(), got):
            self.assertEqual(
                have, want,
                f"snd_update clobbered {name.upper()}: #{have:04X}, "
                f"expected #{want:04X}")

    #  --- the collision -----------------------------------------------------

    def test_the_keyboard_still_works_while_a_sound_is_playing(self):
        """Press a key, start an explosion, and let both sides run.

        The failure this is looking for is key_scan reading #FF from every row
        because the player left PPI port A pointing the wrong way, or left the
        PSG's address latch somewhere other than where key_scan expects to put
        it. Either way the keyboard goes dead and the sound is perfect.
        """
        self.c.key_down("1")
        self.explosion()
        self.run_ticks(4)

        self.assertTrue(self.id_is_down(self.sym["KEY_1"]),
                        f"'1' was held throughout and key_scan missed it; "
                        f"state={self.key_state()}")
        self.assertEqual(self.bits_down(), 1,
                         f"the scan invented keypresses: {self.key_state()}")

    def test_the_sound_still_plays_while_a_key_is_held(self):
        """The same collision from the other side.

        key_scan flips PPI port A to an input and puts the PSG in READ, and it
        runs immediately before snd_update on every tick. If the player did not
        re-assert the direction, every register write it made would go nowhere
        -- and the give-away is that the registers stop CHANGING, not that they
        are wrong. So this samples twice and demands the envelope moved.
        """
        self.c.key_down("1")
        self.explosion()

        #  Long enough to be several 50 Hz ticks apart: the decay is finer
        #  than one PSG volume step, so two samples one tick apart could
        #  legitimately be equal and the test would be flaky rather than wrong.
        self.run_ticks(6)
        first = self.psg()
        self.run_ticks(6)
        second = self.psg()

        self.assertGreater(first[R_AMP_B], 0,
                           "the explosion was silent during the first scans")
        self.assertEqual(first[R_MIXER] & MIX_NOISE_B, 0,
                         "key_scan closed the noise generator")
        self.assertLess(second[R_AMP_B], first[R_AMP_B],
                        f"the envelope froze across the scans: "
                        f"{first[R_AMP_B]} then {second[R_AMP_B]} -- the "
                        f"player's writes are not reaching the PSG")
        self.assertGreater(second[R_NOISE], first[R_NOISE],
                           "the noise sweep froze across the scans")

    def test_a_sound_started_from_the_main_loop_survives_the_scans(self):
        """snd_fire runs from the main loop while the tick runs from the IRQ.

        They share the voice block, which is why snd_start copies it inside
        DI. Nothing here can prove the race is impossible, but a torn copy
        shows up as a channel that never stops -- so start a lot of them.
        """
        self.c.key_down("1")
        for _ in range(10):
            self.fire()
            self.run_ticks(3)
        self.assertTrue(self.id_is_down(self.sym["KEY_1"]))

        #  Let everything run out, then check nothing is left droning.
        self.run_ticks(5)
        self.run_ticks(5)
        self.run_ticks(5)
        self.assert_silent("after ten shots interleaved with key scanning")

    def test_the_mixer_never_makes_the_psg_port_an_output(self):
        """The one bit that would kill the keyboard silently. Watch it."""
        self.c.key_down("1")
        self.explosion()
        for _ in range(6):
            self.run_ticks(3)
            self.assertEqual(self.psg()[R_MIXER] & MIX_PORT_A_OUT, 0,
                             "mixer bit 6 came on")

    def test_it_recovers_a_ppi_left_pointing_the_wrong_way(self):
        """snd_update asserts the port A direction instead of assuming it.

        Nothing in the shipped game leaves port A as an input outside the
        interrupt's own key_scan, so this cannot be provoked by running the
        game -- which is exactly why it needs a test that provokes it
        directly.
        Without the control word at the top of snd_update, every OUT below it
        writes into a port that is not driving the bus, and the machine goes
        quiet with nothing wrong in the source.
        """
        self.fire()
        upd = self.sym["SND_UPDATE"]
        code = [0xF3]                                   # di
        code += [0x01, 0x92, 0xF7, 0xED, 0x49]          # PPI: port A = INPUT
        code += [0xCD] + _w(upd)                        # call snd_update
        self.run_stub(code + self.tail())
        self.assertGreater(
            self.amps()[0], 0,
            "snd_update was entered with PPI port A as an input and its "
            "register writes went nowhere")

    def test_the_ppi_is_left_the_way_key_scan_expects_to_find_it(self):
        """Thirty ticks in a row must agree, with a sound playing throughout.

        tests/test_keyboard.py has this test with the scan driven by hand and
        the interrupt off. This is the same assertion with the player running
        beside it on every tick, which is the configuration the game ships.
        """
        self.c.key_down("1")
        self.explosion()
        for i in range(10):
            self.run_ticks(3)
            self.assertTrue(self.id_is_down(self.sym["KEY_1"]),
                            f"scan burst {i} lost the key")
            self.assertEqual(self.bits_down(), 1,
                             f"scan burst {i}: {self.key_state()}")

    def test_a_key_pressed_and_released_is_seen_through_the_noise(self):
        self.explosion()
        self.run_ticks(3)
        self.assertEqual(self.bits_down(), 0, "a key appeared from nowhere")

        self.c.key_down("1")
        self.run_ticks(3)
        self.assertTrue(self.id_is_down(self.sym["KEY_1"]))

        self.c.key_up("1")
        self.c.run_frames(2)
        self.run_ticks(3)
        self.assertEqual(self.bits_down(), 0,
                         f"the release was lost: {self.key_state()}")


class TestCost(SoundFixture):
    """What the 50 Hz tick costs. Section 6 budgets 15,000 T a frame for sound.

    The tick is not only sound any more -- key_scan is on it too, fifty times a
    second whether or not a key is down -- so the whole of it is measured here,
    together, because together is how the frame pays for it.
    """

    BUDGET_T = 15000

    #  The gate array steals cycles from the CPU, so a hand count of the
    #  instruction table runs 25-30% under what this measures. The number that
    #  actually bounds the tick is the interrupt PERIOD: the gate array raises
    #  one every 52 scanlines, i.e. every 4e6/300 = 13,333 T-states, and a
    #  handler that ran past that would start dropping them.
    IRQ_PERIOD_T = 4e6 / 300

    #  Loop overhead around the CALL: push bc, pop bc, dec bc, ld a,b, or c, jr
    LOOP_T = 11 + 10 + 6 + 4 + 4 + 12

    def measure(self, symbol: str = "SND_UPDATE", iters: int = 250) -> float:
        addr = self.sym[symbol]
        body = [0xC5, 0xCD] + _w(addr) + [0xC1, 0x0B, 0x78, 0xB1]
        code = [0xF3, 0x01] + _w(iters) + body
        code += [0x20, (-(len(body) + 2)) & 0xFF]       # jr nz
        frames = self.run_stub(code + self.tail(), max_frames=400)
        return frames * 20e-3 * 4e6 / iters - self.LOOP_T

    def test_a_busy_tick_stays_inside_the_budget(self):
        """All three voices live, which is the most work a tick can be.

        Channel B costs one register more than the others (the noise period),
        so a full three-channel tick is eleven PSG writes plus three envelope
        steps. The voices are poked directly with long timers and no decay so
        that every one of the 250 iterations takes the live path -- calling
        snd_fire would only give eight.

        THE POKE HAS TO BE A WHOLE VOICE BLOCK, and getting that wrong is a
        measurement that silently goes DOWN. When the prescaler took the block
        from eight bytes to ten this still packed eight, so +9 was left at
        whatever snd_init had zeroed it to -- and snd_step reads a zero
        countdown as 256, so all three voices took the cheap held path for the
        whole run and the tick came out 4113 T against the 4433 it had been.
        A cost test that gets cheaper after work is added is not measuring the
        work. The assert below is why it cannot happen again.
        """
        busy = struct.pack("<BBBBHHBB", 255, 3, 255, 0, 0x0200, 0, 1, 1)
        assert len(busy) == self.sym["SND_VOICE_SIZE"], (
            "a partial voice block leaves the prescaler at 0 and measures the "
            "held path instead of the live one")
        for name in ("SND_VOICE_A", "SND_VOICE_B", "SND_VOICE_C"):
            self.c.write_ram(self.sym[name], busy)

        t = self.measure()
        self.assertLess(t, self.BUDGET_T,
                        f"snd_update costs {t:.0f} T, budget {self.BUDGET_T} T")
        #  Not a real lower bound, just a guard against measuring nothing --
        #  eleven PSG writes cannot possibly be free.
        self.assertGreater(t, 300, f"{t:.0f} T is not a plausible measurement")
        print(f"\n    snd_update, three live channels: {t:.0f} T-states")

    def test_an_idle_tick_is_cheaper_still(self):
        """Silence is the common case: no battle, fifty ticks a second."""
        self.silence()
        t = self.measure()
        self.assertLess(t, self.BUDGET_T, f"an idle tick costs {t:.0f} T")
        print(f"\n    snd_update, all channels idle:   {t:.0f} T-states")

    def test_the_whole_50hz_tick_fits_between_two_interrupts(self):
        """key_scan joined snd_update on the tick. Both of them, together.

        Charged to EVERY frame whether or not a key is down, and at 50 Hz
        against a game running near 5 fps that is about ten ticks a frame -- so
        a thousand T-states here is ten thousand off the frame. The bound is
        the interrupt period rather than a budget invented for the purpose: run
        past 13,333 T and the handler is still going when the gate array raises
        the next one.

        Held to half of it, which leaves the same margin again for whatever
        goes on the tick next.
        """
        busy = struct.pack("<BBBBHHBB", 255, 3, 255, 0, 0x0200, 0, 1, 1)
        assert len(busy) == self.sym["SND_VOICE_SIZE"]
        for name in ("SND_VOICE_A", "SND_VOICE_B", "SND_VOICE_C"):
            self.c.write_ram(self.sym[name], busy)

        scan = self.measure("KEY_SCAN")
        snd = self.measure("SND_UPDATE")
        print(f"\n    key_scan:                        {scan:.0f} T-states"
              f"\n    a whole 50 Hz tick (worst case): {scan + snd:.0f} T-states"
              f" of {self.IRQ_PERIOD_T:.0f} available")

        self.assertGreater(scan, 300,
                           f"{scan:.0f} T is not a plausible measurement for "
                           f"ten rows of PPI handshake")
        self.assertLess(
            scan + snd, self.IRQ_PERIOD_T / 2,
            f"the 50 Hz tick costs {scan + snd:.0f} T (key_scan {scan:.0f}, "
            f"snd_update {snd:.0f}) against an interrupt every "
            f"{self.IRQ_PERIOD_T:.0f} T")


class TestLayout(unittest.TestCase):
    """Assertions about the build, so a refactor cannot quietly break them."""

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def test_the_voices_are_contiguous_and_in_channel_order(self):
        size = self.sym["SND_VOICE_SIZE"]
        a = self.sym["SND_VOICE_A"]
        self.assertEqual(self.sym["SND_VOICE_B"], a + size)
        self.assertEqual(self.sym["SND_VOICE_C"], a + 2 * size)

    def test_the_prescaler_fields_are_the_last_two_of_the_block(self):
        """A descriptor IS a voice block -- snd_start LDIRs one over the other.

        So the two prescaler bytes have to be inside SND_VOICE_SIZE and at the
        end of it: a field past the size is never copied, and the sound would
        run at whatever the previous effect on that channel left there.
        """
        size = self.sym["SND_VOICE_SIZE"]
        self.assertEqual(self.sym["SND_V_SLOWC"], size - 1)
        self.assertEqual(self.sym["SND_V_SLOW"], size - 2)

    def test_everything_lives_below_the_bank_window(self):
        """snd_update runs every frame, so none of it may be paged out.

        The two jump descriptors are in the low 16K with the other three rather
        than in bank 4, which had the room. They are 16 bytes; keeping all five
        under one comment block is worth that, and both call sites are bank-4
        code -- so a descriptor IN bank 4 would be an LDIR whose source is the
        window, which works only for as long as nobody moves the call.
        """
        for name in ("SND_INIT", "SND_UPDATE", "SND_FIRE", "SND_EXPLOSION",
                     "SND_HIT", "SND_JUMP_OUT", "SND_JUMP_IN",
                     "SND_FX_JUMP_OUT", "SND_FX_JUMP_IN",
                     "SND_VOICE_A", "SND_MIXER", "SND_MIX_MASK"):
            self.assertLess(self.sym[name], 0x4000, name)

    def test_a_jump_outranks_every_battle_effect(self):
        """A rare, deliberate, world-stopping event against a laser shot.

        It cannot be observed today -- priorities are only compared within a
        channel and the jump has C to itself -- which is exactly why it is
        stated here rather than left to a runtime test that would pass whatever
        the number was. Section 12 promises C the alerts as well, and on the
        day they arrive this is the line that decides who wins.
        """
        jump = self.sym["SND_PRI_JUMP"]
        for name in ("SND_PRI_HIT", "SND_PRI_FIRE", "SND_PRI_EXPLOSION"):
            self.assertGreater(jump, self.sym[name],
                               f"a jump does not outrank {name}")

    def test_the_mixer_masks_only_ever_clear_bits(self):
        """Each channel unmutes itself and nothing else, bit 6 included."""
        base = self.sym["SND_MIXER_OFF"]
        self.assertEqual(base & MIX_PORT_A_OUT, 0)
        self.assertEqual(base, ALL_MUTED)


#  --------------------------------------------------------------------------
#  A note for whoever runs the whole suite
#
#  tests/test_keyboard.py and tests/test_phase1.py put their stubs and results
#  at #2E00, #2F00 and #3000. Those were free once; they are now inside f9_lo
#  and f9_hi, because src/gen/tables.asm is `align 256` and the code has grown
#  underneath it. The symptom is that test_phase1's bit-exact projection
#  comparisons pass or fail depending on how big the rest of the build is --
#  they were already failing before this file existed, and adding the sound
#  player moves the tables another page, which changes WHICH of them fail.
#
#  The fix is one line in each of those modules: derive the scratch addresses
#  from LOW_END the way SoundFixture does above. It is not done here because
#  those files are not this change's to edit.
#  --------------------------------------------------------------------------


if __name__ == "__main__":
    unittest.main()
