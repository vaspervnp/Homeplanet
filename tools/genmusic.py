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
#  `rate` is the sample rate the band is analysed at. It has to be at least
#  twice the band's top note, and cheaper is better: the bass band at 1378 Hz
#  costs an eighth of what it would at 11025 for exactly the same answer.
BANDS = [
    #  name      lo   hi   rate   window   volume
    ("bass",     33,  55,  1378,  512,     12),   # A1  .. G3
    ("harmony",  50,  74,  2756,  512,     10),   # D3  .. D5
    ("lead",     62,  93, 11025, 2048,     11),   # D4  .. A6
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

def emit(fh, label, bands):
    used = sorted({n for _, _, runs in bands for n, _ in runs if n is not None})
    playable = [m for m in used if ay_period(m) <= AY_PERIOD_MAX]
    dropped = [m for m in used if m not in playable]

    fh.write(f"; {'=' * 74}\n")
    fh.write(f";  {label} -- generated by tools/genmusic.py, do not edit\n")
    fh.write(f"; {'=' * 74}\n")
    fh.write(";  Pitches are MEASURED off the source; the split into three\n")
    fh.write(";  voices is an arrangement choice. See the tool's header.\n")
    if dropped:
        fh.write(f";  Dropped, below the AY's 12-bit period floor: "
                 f"{', '.join(midi_name(m) for m in dropped)}\n")
    fh.write("\n")

    fh.write(f"{label}_periods:\n")
    for m in playable:
        fh.write(f"    defw {ay_period(m):5}                     ; {midi_name(m)}\n")
    fh.write(f"{label}_periods_end:\n\n")

    total = 0
    for name, volume, runs in bands:
        runs = [(n if n in playable else None, c) for n, c in runs]
        stream = to_stream(runs, playable, volume)
        fh.write(f"{label}_{name}:\n")
        for idx, vol, dur in stream:
            fh.write(f"    defb {idx:3},{vol:3},{dur:4}\n")
        fh.write("    defb #FF\n\n")
        total += len(stream) * 3 + 1
    total += len(playable) * 2
    return total, playable


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


if __name__ == "__main__":
    main()
