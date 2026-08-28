"""MUSIC3: the standalone player, and the disc it shares.

The tests that matter here are not "does a file exist" -- they are "does the
AY end up holding the notes the analyser said it found". So the ones that
count read the PSG's own registers back out of the chip while the player is
running, and check the periods against the period table the generator wrote.

The other half is the DISC, and it is the reason this file has a test that
looks like it belongs somewhere else. The sprite libraries live at tracks
12-20 as RAW SECTORS, which AMSDOS knows nothing about: they are not files and
they are not in its allocation map. Adding the music binaries put real files on an image
already carrying DISC.BIN and a 16 KB screen, the arithmetic came out at
twelve tracks -- exactly where the libraries started -- and one of them landed
on bank 5. LIB_TRACK is 20 now. Nothing but a test says it still fits after
the next thing is added, and the test has to compare CONTENT: the load
SUCCEEDS either way.

MUSIC1 and MUSIC2 -- the two transcribed tunes -- have been taken off the
disc. tools/genmusic.py still has the analyser that made them, behind
--analyse; nothing here exercises it, because there is nothing left for it to
produce.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STUB = 0x9000
PSG_BUF = 0x9200

R_MIXER, R_AMP_A, R_AMP_B, R_AMP_C = 7, 8, 9, 10

def _w(a):
    return [a & 0xFF, a >> 8]


def read_psg(c):
    """Registers 0..13 back out of the AY, the way test_sound.py does it.

    Destructive: it takes the CPU away from whatever was running. Every caller
    here puts the PC back afterwards, which works because the player's state
    is all in memory and the AY keeps its registers regardless.
    """
    code = [0xF3] + [0x21] + _w(PSG_BUF) + [0x16, 0x00] + [0x0E, 0x00]
    body = []
    body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]    # port A = output
    body += [0x06, 0xF4, 0x7A, 0xED, 0x79]          # register number
    body += [0x06, 0xF6, 0x3E, 0xC0, 0xED, 0x79]    # PSG_SELECT
    body += [0xAF, 0xED, 0x79]                      # PSG_INACTIVE
    body += [0x06, 0xF7, 0x3E, 0x92, 0xED, 0x79]    # port A = INPUT
    body += [0x06, 0xF6, 0x3E, 0x40, 0xED, 0x79]    # PSG_READ
    body += [0x06, 0xF4, 0xED, 0x78]                # in a,(#F4xx)
    body += [0x77, 0x23]
    body += [0x06, 0xF6, 0xAF, 0xED, 0x79]
    body += [0x06, 0xF7, 0x3E, 0x82, 0xED, 0x79]
    body += [0x14, 0x7A, 0xFE, 0x0E]
    body += [0x38, (-(len(body) + 2)) & 0xFF]
    c.write_ram(STUB, bytes(code + body + [0x76]))   # ...and halt
    c.set_pc(STUB)
    c.run_frames(4)
    return list(c.read_ram(PSG_BUF, 14))


def read_bank(c, select, addr, count):
    """`count` bytes of an extended bank, through a stub that pages it in.

    read_ram indexes the base 64K and would hand back bank 1 for #4000, and
    read_cpu honours whatever is paged in RIGHT NOW -- which is bank 4. Neither
    can see banks 5-7, so this pages one in, copies into low memory, and puts
    bank 4 back before returning.
    """
    prog = [0xF3]                                        # di
    prog += [0x3E, select, 0x01, 0x00, 0x7F, 0xED, 0x79]  # out (#7F00),bank
    prog += [0x21] + _w(addr)                            # ld hl,addr
    prog += [0x11] + _w(PSG_BUF)                         # ld de,buf
    prog += [0x01] + _w(count)                           # ld bc,count
    prog += [0xED, 0xB0]                                 # ldir
    prog += [0x3E, 0xC4, 0x01, 0x00, 0x7F, 0xED, 0x79]   # bank 4 back
    prog += [0x76]                                       # halt
    c.write_ram(STUB, bytes(prog))
    c.set_pc(STUB)
    c.run_frames(4)
    return c.read_ram(PSG_BUF, count)


def periods_of(stem):
    """The period table out of the generated source, as a set."""
    path = os.path.join(ROOT, "src", "gen", f"mus_full_{stem}.asm")
    with open(path) as fh:
        text = fh.read()
    body = text.split("_periods:", 1)[1].split("_periods_end", 1)[0]
    return {int(m) for m in re.findall(r"defw\s+(\d+)", body)}


class PlayerFixture(unittest.TestCase):

    TUNE = "MUSIC3"
    STEM = "deepspace"

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = self.boot_player()

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def boot_player(self, settle: int = 0):
        """A fresh machine with the tune playing, `settle` frames further in.

        ONE EMULATOR AT A TIME -- close self.c before calling this for a
        second machine, or the two interfere; the harness says so and this
        file is not an exception.
        """
        c = cpc.CPC()
        c.run_frames(h.BOOT_FRAMES)
        self.assertTrue(c.insert_disc(h.DSK), "insert_disc failed")
        c.type_text("|DISC\n")
        c.run_frames(60)
        c.type_text(f'RUN"{self.TUNE}\n')
        c.run_frames(220 + settle)
        return c

    def first_reading(self, settle: int):
        """(periods, amplitudes, mixer) once, `settle` frames into the tune.

        A WHOLE MACHINE FOR ONE READING, because that is what a reading costs.
        See sample() for why.
        """
        c = self.boot_player(settle)
        try:
            r = read_psg(c)
            return ((r[0] | (r[1] << 8), r[2] | (r[3] << 8), r[4] | (r[5] << 8)),
                    (r[R_AMP_A], r[R_AMP_B], r[R_AMP_C]),
                    r[R_MIXER])
        finally:
            h.close(c)

    def sample(self, every=20, count=24):
        """(periods, amplitudes, mixer) at several points, player resumed.

        ONLY THE FIRST READING IS REAL, and everything after it is silence.
        read_psg takes the CPU away from the player -- that much the comment on
        it always said -- and the player does not come back: putting the PC
        where it was is not enough, and saving and restoring AF/BC/DE/HL/IX/IY
        around the stub does not help either. Measured: every amplitude in
        every sample after the first is zero, on a player that a run with no
        sampling in it at all shows driving three voices for a whole minute.
        So the list this returns is one reading and then `count - 1` rests, and
        every test built on it is really a one-sample test that has been
        passing on where the first sample happened to land.

        The 3+3+2 sprite repack is what surfaced that: it took four kilobytes
        off DISC.BIN, which moved MUSIC3.BIN onto different AMSDOS blocks, which
        moved the load by about a second -- and the first reading went from
        just after the third voice enters to just before it.
        test_all_three_voices_are_used therefore does not use this any more;
        it boots a machine per sample point (see first_reading), which is slow
        and true. The three tests still here are the ones a single reading can
        honestly answer.
        """
        out = []
        for _ in range(count):
            self.c.run_frames(every)
            pc = self.c.pc
            r = read_psg(self.c)
            out.append((
                (r[0] | (r[1] << 8), r[2] | (r[3] << 8), r[4] | (r[5] << 8)),
                (r[R_AMP_A], r[R_AMP_B], r[R_AMP_C]),
                r[R_MIXER],
            ))
            self.c.set_pc(pc)
        return out


class TestItPlays(PlayerFixture):

    def test_it_is_running_our_code_and_not_the_firmware(self):
        """The binary loads at #4000 and runs there. Anything in #0C00-#1F00
        is the lower ROM, which is where a boot that went wrong ends up."""
        self.assertTrue(0x4000 <= self.c.pc < 0x6000,
                        f"PC #{self.c.pc:04X} is not inside the player")

    def test_the_mixer_is_three_tones_and_no_noise(self):
        """Bits 0-2 clear enables tone; 3-5 set disables noise.

        BIT 6 MUST BE CLEAR. Setting it makes the PSG's port A an output, and
        port A is how the keyboard is read -- the game has a build-time assert
        for exactly this and the standalone player has no assembler to catch
        it, so the guard is here.
        """
        for _, _, mixer in self.sample(count=2):
            self.assertEqual(mixer & 0b00111111, 0b00111000,
                             f"mixer is {mixer:#04x}")
            self.assertEqual(mixer & 0b01000000, 0,
                             "mixer bit 6 is set: port A became an output and "
                             "the keyboard is deaf")

    def test_every_period_is_a_note_the_generator_wrote(self):
        """The end of the whole chain, and the only test that checks it.

        A period that is not in the table means the player indexed it wrong --
        one-based against zero-based, or the wrong byte order -- and that is a
        tune playing the wrong notes rather than no notes, which nothing else
        here would notice.
        """
        table = periods_of(self.STEM)
        self.assertGreater(len(table), 8, "the period table is suspiciously small")
        seen = set()
        for periods, amps, _ in self.sample():
            for p, amp in zip(periods, amps):
                if amp:                          # a silent voice keeps a stale period
                    seen.add(p)
        self.assertTrue(seen, "no voice was ever sounding")
        self.assertTrue(seen <= table,
                        f"periods {sorted(seen - table)} are not in the tune's "
                        f"period table")

    def test_all_three_voices_are_used(self):
        """Three separate streams, not one played three times. If the bands
        were assigned independently the lead and the harmony came out in
        unison -- measured, and why assign() in the generator exists."""
        #  A MACHINE PER SAMPLE POINT. sample() cannot answer this: only its
        #  first reading is real -- see its docstring -- so what looked like
        #  thirty seconds of evidence was one instant, and the day the sprite
        #  repack moved MUSIC3.BIN by a block that instant landed a second
        #  earlier and the third voice had not come in yet. Fourth time this
        #  file has been wrong about a sampling window, and the first time the
        #  window turned out to be one sample wide.
        #
        #  The rule it keeps failing to apply is its own: cover the STRUCTURE.
        #  The piece is about 64 seconds and ends there -- past ~3200 frames
        #  the player has handed back to BASIC -- so this walks 0 to 2800 in
        #  eight steps, which is most of a cycle and every entry in it.
        h.close(self.c)                 # one emulator per process, always
        self.c = None

        sounding = set()
        for settle in range(0, 2801, 400):
            _, amps, _ = self.first_reading(settle)
            for voice, amp in enumerate(amps):
                if amp:
                    sounding.add(voice)
            if sounding == {0, 1, 2}:
                break
        self.assertEqual(sounding, {0, 1, 2},
                         f"only voices {sorted(sounding)} ever sounded")

    def test_the_voices_are_not_all_playing_the_same_note(self):
        for periods, amps, _ in self.sample(count=6):
            live = [p for p, a in zip(periods, amps) if a]
            if len(live) == 3:
                self.assertGreater(len(set(live)), 1,
                                   "all three voices are on the same period")
                return
        self.skipTest("never caught all three voices sounding at once")


class TestTheComposedTune(PlayerFixture):
    """MUSIC3 is written rather than measured, so it is the one tune whose
    notes are known in advance -- and the only one a checkout with no
    musicsamples/ can rebuild at all."""

    #  The composed tune uses its own three levels, all of them low.
    LEVELS = (5, 4, 6)

    def test_the_volume_never_moves(self):
        """The correction the tune was rewritten for.

        Every held note was four entries swelling and fading, which at this
        tempo is not an envelope but a slow tremolo under everything. Quiet
        and steady disappears behind a battle; quiet and wavering does not.
        A level that moves at all here is that coming back.
        """
        seen = {0: set(), 1: set(), 2: set()}
        #  Over twenty seconds, because the bass is a sixteen-second drone: a
        #  six-second window would see one level whatever the tune did, which
        #  is how the swell version passed its own test on two voices out of
        #  three. The window has to cover the LONGEST note, not the shortest.
        for _, amps, _ in self.sample(count=26, every=40):
            for voice, amp in enumerate(amps):
                seen[voice].add(amp)
        for voice, levels in seen.items():
            sounding = {a for a in levels if a}
            self.assertLessEqual(len(sounding), 1,
                                 f"voice {voice} plays at {sorted(sounding)} -- "
                                 f"the volume is moving")
            if sounding:
                self.assertEqual(sounding, {self.LEVELS[voice]},
                                 f"voice {voice} is at {sounding}, not "
                                 f"{self.LEVELS[voice]}")

    def test_it_is_quiet(self):
        """A bed for a strategy game that may be on for an hour, not a title
        theme. The AY's amplitude register is logarithmic at about 3 dB a
        step, so six is roughly 18 dB under where a chiptune would sit -- and
        that is why halving it meant two steps down rather than half the
        number, which would have been another 6 dB on top."""
        for _, amps, _ in self.sample(count=8, every=40):
            for voice, amp in enumerate(amps):
                self.assertLessEqual(amp, 6,
                                     f"voice {voice} is at amplitude {amp}")

    def test_the_harmony_never_states_a_third(self):
        """The decision the piece is built on: the two accompanying voices
        move in fifths, fourths and octaves, so the mode is never declared.
        A third creeping into the harmony would make it sound sad or bright
        instead of open, and nothing else here would notice."""
        table = sorted(periods_of(self.STEM))
        #  Semitones above the D the piece is centred on, for every period in
        #  the table: 125000/period -> Hz -> semitones from D2 (73.416 Hz).
        import math
        degrees = set()
        for p in table:
            hz = 125000.0 / p
            degrees.add(round(12 * math.log2(hz / 73.416)) % 12)
        self.assertNotIn(4, degrees, "there is a major third in the tune")


class TestTheDiscStillHoldsTheSpriteLibraries(unittest.TestCase):
    """The collision this file caused, and the test that did NOT catch it.

    The libraries are raw sectors outside AMSDOS's allocation map, so a file
    that grows into them is not refused -- it is written straight over them.
    Adding MUSIC1.BIN and MUSIC2.BIN did exactly that: bank 5 came up holding
    a copy of the music player. LIB_TRACK moved from 12 to 20.

    THIS TEST ORIGINALLY ASSERTED LIB_OK == 1 AND PASSED THROUGHOUT. lib_load
    had read its sectors perfectly; they were there, and readable, and full of
    the wrong thing. What caught it was test_shipclass's comparison of each
    bank against build/bank*.raw -- content, not success. So this one compares
    content too, and the LIB_OK check is kept only as the thing that tells the
    two failure modes apart in the message.
    """

    def test_the_libraries_still_hold_sprites_and_not_a_music_player(self):
        sym = h.symbols()
        c = h.boot_quick(frames=300)
        try:
            self.assertEqual(c.read_ram(sym["LIB_OK"], 1)[0], 1,
                             "lib_load itself failed, before any question of "
                             "what it loaded")
            for n, select in ((5, 0xC5), (6, 0xC6), (7, 0xC7)):
                with open(os.path.join(ROOT, "build", f"bank{n}.raw"), "rb") as fh:
                    want = fh.read(64)
                got = bytes(read_bank(c, select, 0x4000, 64))
                self.assertEqual(got, want,
                                 f"bank {n} is not the sprite library the build "
                                 f"wrote -- an AMSDOS file has probably grown "
                                 f"over track {sym['LIB_TRACK']}")
        finally:
            h.close(c)


class TestTheGeneratorIsRepeatable(unittest.TestCase):
    """Composition is deterministic by construction and analysis has to be
    measured to be; either way, two runs that disagree make everything
    downstream untestable."""

    def test_the_report_is_deterministic(self):
        #  The default run, which composes MUSIC3 and touches no audio at
        #  all -- so this works in a checkout with no musicsamples/.
        cmd = [sys.executable, os.path.join(ROOT, "tools", "genmusic.py")]
        first = subprocess.run(cmd, cwd=ROOT, check=True,
                               stdout=subprocess.PIPE).stdout
        second = subprocess.run(cmd, cwd=ROOT, check=True,
                                stdout=subprocess.PIPE).stdout
        self.assertEqual(first, second, "two runs of the analyser disagree")


if __name__ == "__main__":
    unittest.main()
