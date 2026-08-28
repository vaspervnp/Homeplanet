#!/usr/bin/env python3
"""Turn an ogg into three AY voices, and write them as a note stream.

WHAT THIS IS HONEST ABOUT
-------------------------
There is no ogg-to-AY converter anywhere, in this project or in
GravassistCPC, and there is no way for anyone working on this to LISTEN to
the source and write the notes down. So the pitches here are MEASURED, not
heard: the file is decoded, cut into frames, and each frame's strongest
partial in each of three frequency bands is taken as that band's note.

That measurement is reliable and can be checked -- `--report` prints what was
found, and the same run twice gives the same answer. What is NOT measurement
is the ARRANGEMENT: that there are three bands, where they are cut, and which
one gets which AY channel. Those are choices, they are in BANDS below, and
they are the first thing to change if a tune comes out wrong.

The precedent is GravassistCPC's tools/genmusic.py, which did the same thing
one step cruder -- energy and zero-crossing onto a drum grid -- and said so in
the same words: the positions were measured, the instrument behind each one
was a judgement.

HOW IT WORKS
------------
1. ffmpeg decodes to mono PCM. Each band gets its own sample rate, because a
   bass note at 55 Hz does not need 11 kHz and the analysis cost is linear in
   it -- decimating the bass band by eight makes it eight times cheaper for
   exactly the same answer.
2. One FFT per band per frame, and the semitones of that band are read out of
   its bins. An FFT serves every note in the band at once; a Goertzel per note
   costs about three times as much here and was written first.
3. A frame whose strongest partial does not stand clear of the rest of its
   band is a REST. That threshold is what decides whether a pad comes out as
   music or as mud.
4. Runs of the same note collapse into one note with a duration, which is what
   makes the data small: a bass note held for seven seconds is one entry, not
   seventy. This is why a four-minute piece fits in a bank.

OUTPUT
------
Three streams of (note index, volume, duration) triples, terminated by #FF,
plus the period table the indices point into. Same shape as Gravassist's,
because the shape is right: whole AY register blocks would cost four times as
much and the difference is a shift and an add in the player.

    python3 tools/genmusic.py --list
    python3 tools/genmusic.py --report tranquility
    python3 tools/genmusic.py                      # write every src/gen/mus_*.asm
"""

import argparse
import array
import cmath
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

#  The AY on the CPC: period = 125000 / f, and the register is 12 bits, so
#  anything below about 30 Hz cannot be played at all. That is a floor on how
#  low BANDS[0] is allowed to reach.
AY_CLOCK = 125000
AY_PERIOD_MAX = 4095

#  The player ticks at 50 Hz from the interrupt, and one analysis step is five
#  of those ticks -- a tenth of a second. Ten steps a second is fine for these
#  two pieces (nothing in either moves faster than a quaver at ~90 BPM) and it
#  is what keeps a duration inside one byte for anything up to five seconds.
STEPS_PER_SEC = 10
TICKS_PER_STEP = 50 // STEPS_PER_SEC
DUR_MAX = 250                       # one byte, with room for the #FF terminator


#  --- the arrangement, which is a choice and not a measurement -------------
#
#  Three bands, one AY channel each, cut so that they overlap by a few
#  semitones rather than butting up: a note sitting exactly on a boundary
#  otherwise flickers between two channels from frame to frame, which sounds
#  like a fault rather than like harmony.
#
#  The volumes are LOW and FLAT, for the reason the composed tune's section
#  gives at length: this is a bed, and a level that moves is the thing an ear
#  locks onto. They were 12/10/9 and are 8/6/7, about 12 dB down.
#
#  `rate` is the sample rate the band is analysed at. It has to be at least
#  twice the band's top note, and cheaper is better: the bass band at 1378 Hz
#  costs an eighth of what it would at 11025 for exactly the same answer.
BANDS = [
    #  name      lo   hi   rate   window   volume
    ("bass",     33,  55,  1378,  512,      8),   # A1  .. G3
    ("harmony",  50,  74,  2756,  512,      6),   # D3  .. D5
    ("lead",     62,  93, 11025, 2048,      7),   # D4  .. A6
]

#  A frame whose loudest partial holds less than this share of its band's
#  energy is called a rest. Measured on both pieces: at 0.10 the sustained
#  pads come through and the reverb tails between phrases do not.
PEAK_SHARE = 0.10

#  ...and a frame quieter than this share of the whole piece's mean energy is
#  a rest whatever its spectrum says, which is what keeps the fade-in and the
#  fade-out from being transcribed as notes.
QUIET_SHARE = 0.06

#  A note has to survive this many consecutive frames to be emitted. One frame
#  is a tenth of a second; two is the shortest thing either piece plays, and
#  it throws away the single-frame jitter that a shared harmonic produces when
#  two instruments cross.
MIN_FRAMES = 2


#  --- what to build --------------------------------------------------------
#
#  `loop` is the excerpt the GAME plays, and it has to be an excerpt: the
#  whole of MorningLight is four minutes, and while the note stream for it is
#  small enough to sit in a bank, the game does not want four minutes of
#  through-composed music behind a battle -- it wants something that comes
#  round. `full` is what the standalone MUSIC1/MUSIC2 play.
TUNES = [
    dict(name="tranquility", src="musicsamples/Tranquility.ogg",
         loop=(8.0, 40.0), disc="MUSIC1"),
    dict(name="morninglight", src="musicsamples/MorningLight.ogg",
         loop=(4.0, 36.0), disc="MUSIC2"),
]


#  --- MUSIC3: written here, not measured -----------------------------------
#
#  The other two tunes are transcriptions of somebody's recording. This one is
#  composed, in the same place and the same format, because the tool already
#  knows how to turn note names into AY periods and that is the only hard sum
#  in either job.
#
#  IT IS FOR THE FICTION. Homeplanet is a fleet running with sixty thousand
#  sleepers aboard and nothing it loses ever comes back. So this is not
#  "exciting space", it is cold, patient and unresolved, and three decisions
#  carry all of that:
#
#  1. NO THIRDS IN THE HARMONY. The two accompanying voices move in fifths,
#     fourths and octaves only, so the mode is never declared and the ear
#     cannot settle on major or minor. That is what makes it read as open
#     rather than as sad -- the same trick Gravassist's menu theme uses to
#     avoid stating a tonic colour, used here for the opposite mood.
#  2. THE BASS MOVES UNDER A HELD MELODY NOTE. Every drone change happens
#     while the lead is sustaining, so the harmony shifts without anything
#     starting. That is what makes it drift instead of progress; a bass that
#     changed on the melody's attack would sound like chords.
#  3. SILENCE IS THE THIRD VOICE. The lead is absent for a third of the cycle.
#     With three channels, taking one away is the largest dynamic change
#     available -- there is no volume envelope worth the name -- so the piece
#     breathes by dropping to two voices and back.
#
#  Slow: the cycle is 64 seconds and a phrase is 16. D Aeolian, centred on a
#  D2 drone; the melody touches the flat third and the bass never does.
#
#  4. THE LEVELS DO NOT MOVE, and that is a correction. The first version
#     wrote every held note as four entries whose volume rose and fell, on the
#     argument that an unshaped AY square wave reads as a test tone. It does
#     what it was meant to do and it was still wrong: over a four-second step
#     that is not an envelope, it is TREMOLO -- a slow wobble under
#     everything, and the one thing an ear locks onto and then cannot let go
#     of. Steady and quiet disappears behind a battle. Wavering and quiet does
#     not. The stream format still carries a volume per entry, so shaping is
#     free and can come back for something short; it must not come back for a
#     drone.

COMPOSE_NAME = "deepspace"
COMPOSE_DISC = "MUSIC3"

_S = 50                             # one second, in 50 Hz ticks

#  QUIET, AND FLAT. The AY's amplitude is roughly 3 dB a step, so these sit
#  about 12 dB under where a chiptune would put them -- this is a bed for a
#  strategy game, not a title theme, and it has to survive being on for an
#  hour.
#
#  AND NOT SHAPED. The first version wrote every held note as four entries
#  whose volume rose and fell, on the theory that an unshaped AY square wave
#  reads as a test tone rather than as a pad. It does the job it was meant to
#  and it was still wrong: at this tempo a swell over four seconds is not an
#  envelope, it is TREMOLO -- a slow wobble under everything, which is exactly
#  what you notice and then cannot stop noticing. Steady and quiet disappears
#  behind a battle; wavering and quiet does not.
#
#  The stream format still carries a volume per entry, so shaping costs
#  nothing and can come back for something short. It should not come back for
#  a drone.
VOL_BASS, VOL_HARMONY, VOL_LEAD = 7, 6, 8


def _hold(note, seconds, vol):
    return [(note, vol, seconds * _S)]


def _rest(seconds):
    return [(None, 0, seconds * _S)]


def composed():
    """The three voices of MUSIC3, as explicit (midi, volume, ticks)."""
    bass = (
        _hold("D2", 16, VOL_BASS) +
        _hold("A#1", 16, VOL_BASS) +
        _hold("C2", 16, VOL_BASS) +
        _hold("A1", 8, VOL_BASS) + _hold("D2", 8, VOL_BASS)
    )

    #  Fifths and fourths over each drone, two to a phrase. Never a third.
    harmony = (
        _hold("A3", 8, VOL_HARMONY) + _hold("D4", 8, VOL_HARMONY) +    # over D
        _hold("F3", 8, VOL_HARMONY) + _hold("A#3", 8, VOL_HARMONY) +   # over A#
        _hold("G3", 8, VOL_HARMONY) + _hold("C4", 8, VOL_HARMONY) +    # over C
        _hold("E4", 8, VOL_HARMONY) + _hold("A3", 8, VOL_HARMONY)      # A, then D
    )

    #  D Aeolian, and the only voice allowed the flat third.
    lead = (
        _rest(4) + _hold("A4", 3, VOL_LEAD) + _rest(1) +
        _hold("G4", 2, VOL_LEAD) + _hold("F4", 2, VOL_LEAD) + _rest(4) +

        _hold("D5", 3, VOL_LEAD) + _rest(1) + _hold("C5", 4, VOL_LEAD) +
        _rest(2) + _hold("A4", 4, VOL_LEAD) + _rest(2) +

        _rest(2) + _hold("G4", 4, VOL_LEAD) + _hold("A4", 2, VOL_LEAD) +
        _hold("C5", 4, VOL_LEAD) + _rest(4) +

        _hold("E5", 4, VOL_LEAD) + _rest(2) + _hold("D5", 6, VOL_LEAD) + _rest(4)
    )

    out = []
    for name, events in (("bass", bass), ("harmony", harmony), ("lead", lead)):
        out.append((name, [(None if n is None else name_midi(n), v, t)
                           for n, v, t in events]))
    return out


COMPOSE_NOTE = [
    "COMPOSED, not transcribed -- see tools/genmusic.py's COMPOSE section",
    "for the decisions: no thirds in the harmony, the bass moving under a",
    "held melody note, the lead dropping out for a third of the cycle, and",
    "volumes that are low and DO NOT MOVE -- a swell this slow is tremolo.",
]


def name_midi(name):
    """'A#3' -> a MIDI number. Octave 4 is the one with A4 = 440 Hz."""
    i = 2 if len(name) > 2 and name[1] == "#" else 1
    return 12 * (int(name[i:]) + 1) + NAMES.index(name[:i])


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def midi_name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"


def ay_period(m):
    return int(round(AY_CLOCK / midi_hz(m)))


# ---------------------------------------------------------------- decoding --

def decode(path, rate, start=None, dur=None):
    """ffmpeg to mono signed 16-bit at `rate`, as a list of floats."""
    cmd = ["ffmpeg", "-v", "error"]
    if start is not None:
        cmd += ["-ss", f"{start:.3f}"]
    cmd += ["-i", path]
    if dur is not None:
        cmd += ["-t", f"{dur:.3f}"]
    cmd += ["-ac", "1", "-ar", str(rate), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout
    a = array.array("h")
    a.frombytes(raw[:len(raw) // 2 * 2])
    return [x / 32768.0 for x in a]


# --------------------------------------------------------------------- FFT --

def fft(x):
    """Iterative radix-2, in place on a copy. Length must be a power of two.

    One of these per band per frame reads every semitone in the band at once.
    Written out rather than imported because the project has no numpy and this
    is thirty lines.
    """
    n = len(x)
    a = [complex(v, 0.0) for v in x]

    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]

    length = 2
    while length <= n:
        step = -2j * math.pi / length
        wl = cmath.exp(step)
        for i in range(0, n, length):
            w = 1 + 0j
            for k in range(i, i + length // 2):
                u = a[k]
                v = a[k + length // 2] * w
                a[k] = u + v
                a[k + length // 2] = u - v
                w *= wl
        length <<= 1
    return a


def hann(n):
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)]


# ---------------------------------------------------------------- analysis --

def score_band(samples, rate, window, lo, hi, mean_energy):
    """Per analysis step, {semitone: power} for the semitones lo..hi.

    Scores rather than a note, because the three bands OVERLAP on purpose and
    the choice has to be made across them -- see assign().
    """
    hop = max(1, rate // STEPS_PER_SEC)
    win = hann(window)

    #  Which FFT bin each semitone lands in, and the two either side of it, so
    #  a note slightly off concert pitch is still collected rather than split.
    bins = {}
    for m in range(lo, hi + 1):
        centre = midi_hz(m) * window / rate
        k = int(round(centre))
        if 1 <= k < window // 2 - 1:
            bins[m] = (k - 1, k, k + 1)

    out = []
    for off in range(0, max(0, len(samples) - window) + 1, hop):
        frame = samples[off:off + window]
        if len(frame) < window:
            break
        energy = sum(v * v for v in frame) / window
        if mean_energy and energy < mean_energy * QUIET_SHARE:
            out.append({})
            continue

        spec = fft([frame[i] * win[i] for i in range(window)])
        power = [abs(spec[k]) ** 2 for k in range(window // 2)]

        out.append({m: sum(power[k] for k in ks) for m, ks in bins.items()})
    return out


def assign(scored):
    """Choose one note per band per frame, highest band first.

    THE BANDS OVERLAP AND THIS IS WHY. Cut so they do not, a note sitting on a
    boundary flickers between two channels from frame to frame and sounds like
    a fault; overlapped and chosen independently, the lead and the harmony
    both pick the loudest thing in the piece and play it in unison, which
    wastes a third of the AY. Measured on Tranquility: harmony and lead came
    out with identical first bars, C5 G#4 A#4, note for note.

    So the lead picks first and what it takes is struck out of the bands
    below. The bass picks last and almost never competes, because nothing else
    reaches down there.
    """
    frames = min(len(s) for s in scored)
    chosen = [[] for _ in scored]
    for i in range(frames):
        taken = set()
        for b in reversed(range(len(scored))):        # lead, harmony, bass
            scores = {m: v for m, v in scored[b][i].items() if m not in taken}
            if not scores:
                chosen[b].append(None)
                continue
            total = sum(scores.values())
            best = max(scores, key=scores.get)
            if total and scores[best] / total >= PEAK_SHARE:
                chosen[b].append(best)
                taken.add(best)
            else:
                chosen[b].append(None)
    return chosen


def smooth(notes):
    """Drop anything that does not hold for MIN_FRAMES, and close one-frame
    holes inside a held note.

    Both halves matter. Without the first, a harmonic shared between two
    instruments produces a note that lasts a tenth of a second and reads as a
    click; without the second, one quiet frame in the middle of a held note
    splits it into two notes with a gap, which is worse than either.
    """
    out = list(notes)
    for i in range(1, len(out) - 1):
        if out[i] is None and out[i - 1] is not None and out[i - 1] == out[i + 1]:
            out[i] = out[i - 1]

    runs = []
    for n in out:
        if runs and runs[-1][0] == n:
            runs[-1][1] += 1
        else:
            runs.append([n, 1])

    keep = []
    for note, count in runs:
        keep.append([note if (note is None or count >= MIN_FRAMES) else None, count])

    merged = []
    for note, count in keep:
        if merged and merged[-1][0] == note:
            merged[-1][1] += count
        else:
            merged.append([note, count])
    return merged


def to_stream(runs, table, volume):
    """(note index, volume, duration in player ticks), durations split to fit
    a byte."""
    out = []
    for note, frames in runs:
        ticks = frames * TICKS_PER_STEP
        idx = 0 if note is None else table.index(note) + 1
        vol = 0 if note is None else volume
        while ticks > 0:
            step = min(ticks, DUR_MAX)
            out.append((idx, vol, step))
            ticks -= step
    return out


def analyse(path, start=None, dur=None):
    """Three bands of runs, and the set of notes they use."""
    scored = []
    for name, lo, hi, rate, window, volume in BANDS:
        samples = decode(path, rate, start, dur)
        if not samples:
            raise SystemExit(f"{path}: decoded to nothing at {rate} Hz")
        mean = sum(v * v for v in samples) / len(samples)
        scored.append(score_band(samples, rate, window, lo, hi, mean))

    chosen = assign(scored)
    return [(BANDS[b][0], BANDS[b][5], smooth(chosen[b]))
            for b in range(len(BANDS))]


# ----------------------------------------------------------------- emitting --

def emit_streams(fh, label, voices, note):
    """Write a period table and three streams of explicit triples.

    `voices` is [(name, [(midi or None, volume, ticks), ...]), ...]. Both the
    analysed tunes and the composed one come through here, so exactly one
    place knows the file format.
    """
    used = sorted({m for _, ev in voices for m, _, _ in ev if m is not None})
    playable = [m for m in used if ay_period(m) <= AY_PERIOD_MAX]
    dropped = [m for m in used if m not in playable]

    fh.write(f"; {'=' * 74}\n")
    fh.write(f";  {label} -- generated by tools/genmusic.py, do not edit\n")
    fh.write(f"; {'=' * 74}\n")
    for line in note:
        fh.write(f";  {line}\n")
    if dropped:
        fh.write(f";  Dropped, below the AY's 12-bit period floor: "
                 f"{', '.join(midi_name(m) for m in dropped)}\n")
    fh.write("\n")

    fh.write(f"{label}_periods:\n")
    for m in playable:
        fh.write(f"    defw {ay_period(m):5}                     ; {midi_name(m)}\n")
    fh.write(f"{label}_periods_end:\n\n")

    total = len(playable) * 2
    for name, events in voices:
        fh.write(f"{label}_{name}:\n")
        for m, vol, ticks in events:
            idx = 0 if (m is None or m not in playable) else playable.index(m) + 1
            v = 0 if idx == 0 else vol
            while ticks > 0:
                step = min(ticks, DUR_MAX)
                fh.write(f"    defb {idx:3},{v:3},{step:4}\n")
                total += 3
                ticks -= step
        fh.write("    defb #FF\n\n")
        total += 1
    return total, playable


ANALYSED_NOTE = [
    "Pitches are MEASURED off the source; the split into three",
    "voices is an arrangement choice. See the tool's header.",
]


def emit(fh, label, bands):
    """The analysed path: runs of (note, frames) become explicit triples."""
    voices = [(name, [(m, volume, frames * TICKS_PER_STEP) for m, frames in runs])
              for name, volume, runs in bands]
    return emit_streams(fh, label, voices, ANALYSED_NOTE)


def build(tune, whole, outdir):
    """Write one src/gen file.

    Two shapes, and the labels are the difference. The standalone MUSIC1 and
    MUSIC2 are separate binaries and only one is ever assembled at a time, so
    their streams are called plain `mus_` and src/musicplay.asm can name them
    without knowing which tune it got. The game's loops have to coexist, so
    they carry the tune's name.
    """
    src = os.path.join(ROOT, tune["src"])
    if not os.path.exists(src):
        raise SystemExit(f"missing {src}")

    if whole:
        label, stem = "mus", f"mus_full_{tune['name']}"
        start = dur = None
    else:
        label = stem = f"mus_loop_{tune['name']}"
        start, dur = tune["loop"][0], tune["loop"][1] - tune["loop"][0]

    bands = analyse(src, start, dur)
    path = os.path.join(outdir, f"{stem}.asm")
    with open(path, "w") as fh:
        size, playable = emit(fh, label, bands)
    return path, size, bands, playable


def report(tune, whole=False):
    src = os.path.join(ROOT, tune["src"])
    start, dur = (None, None) if whole else (tune["loop"][0],
                                             tune["loop"][1] - tune["loop"][0])
    bands = analyse(src, start, dur)
    print(f"\n=== {tune['name']}  {tune['src']}"
          f"  {'whole' if whole else f'{start:g}s..{start + dur:g}s'}")
    for name, volume, runs in bands:
        notes = [(n, c) for n, c in runs if n is not None]
        rests = sum(c for n, c in runs if n is None)
        span = (f"{midi_name(min(n for n, _ in notes))}.."
                f"{midi_name(max(n for n, _ in notes))}") if notes else "--"
        print(f"  {name:8} {len(notes):4} notes, {rests:4} rest frames, "
              f"span {span}, {len(runs) * 3 + 1:5} bytes")
        line = " ".join(f"{midi_name(n)}x{c}" if n else f"-x{c}"
                        for n, c in runs[:14])
        print(f"           {line}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", nargs="?", const="*", metavar="TUNE",
                    help="print what was found instead of writing anything")
    ap.add_argument("--whole", action="store_true",
                    help="the whole piece rather than the game's loop")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--outdir", default=os.path.join(ROOT, "src", "gen"))
    args = ap.parse_args()

    if args.list:
        for t in TUNES:
            print(f"{t['name']:14} {t['src']:34} loop {t['loop'][0]:g}s..{t['loop'][1]:g}s"
                  f"  disc {t['disc']}")
        return

    if args.report:
        for t in TUNES:
            if args.report in ("*", t["name"]):
                report(t, args.whole)
        return

    os.makedirs(args.outdir, exist_ok=True)
    #  Both shapes every time: the loops for the game and the whole pieces for
    #  the two standalone disc programs.
    for whole in (False, True):
        for t in TUNES:
            path, size, bands, playable = build(t, whole, args.outdir)
            print(f"{os.path.relpath(path, ROOT):34} {size:6} bytes, "
                  f"{len(playable):3} distinct notes")

    #  ...and the composed one, which needs no audio at all -- which is why it
    #  is the only tune here that a clone with no musicsamples/ can rebuild.
    path = os.path.join(args.outdir, f"mus_full_{COMPOSE_NAME}.asm")
    with open(path, "w") as fh:
        size, playable = emit_streams(fh, "mus", composed(), COMPOSE_NOTE)
    print(f"{os.path.relpath(path, ROOT):34} {size:6} bytes, "
          f"{len(playable):3} distinct notes")


if __name__ == "__main__":
    main()
