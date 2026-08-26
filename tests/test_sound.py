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

  - the scratch addresses are derived from CODE_END rather than hard-coded.
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
FIRE_TICKS = 8
EXPLOSION_TICKS = 24
HIT_TICKS = 6

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

        #  Free space between the end of the code+tables and the stack margin.
        base = cls.sym["CODE_END"]
        limit = 0x4000 - 256
        assert base + 0x180 < limit, (
            f"no room for the test scratch: CODE_END is #{base:04X}")
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

    def tick(self, n: int = 1):
        """Run snd_update n times, the way the interrupt would."""
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

    def ticks_until_silent(self, limit: int = 80) -> int:
        """How many further ticks before every channel is off. None if never."""
        for n in range(1, limit + 1):
            self.tick()
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
        """
        busy = struct.pack("<BBBBHH", 255, 3, 255, 0, 0x0200, 0)
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
        busy = struct.pack("<BBBBHH", 255, 3, 255, 0, 0x0200, 0)
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

    def test_everything_lives_below_the_bank_window(self):
        """snd_update runs every frame, so none of it may be paged out."""
        for name in ("SND_INIT", "SND_UPDATE", "SND_FIRE", "SND_EXPLOSION",
                     "SND_HIT", "SND_VOICE_A", "SND_MIXER", "SND_MIX_MASK"):
            self.assertLess(self.sym[name], 0x4000, name)

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
#  from CODE_END the way SoundFixture does above. It is not done here because
#  those files are not this change's to edit.
#  --------------------------------------------------------------------------


if __name__ == "__main__":
    unittest.main()
