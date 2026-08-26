#!/usr/bin/env python3
"""Generate HOMEPLANET's lookup tables as a RASM include file.

This module is the *specification* for every table the engine reads. The tests
import it and re-derive the same numbers, then compare them against what is
actually sitting in the emulator's RAM -- so a table that silently changes
shape here fails the build's tests rather than corrupting the projection.

Usage:  python3 tools/gentables.py [--out src/gen/tables.asm]
"""

from __future__ import annotations

import argparse
import math
import os
import sys

# --- geometry, mirrored from src/equ/memmap.asm -----------------------------
SCR_WIDTH_PX = 320
SCR_HEIGHT_PX = 200
SCR_BYTES_PER_LINE = 80
SCR_CENTRE_X = 160
SCR_CENTRE_Y = 100

# --- fixed point ------------------------------------------------------------
#  Trig is 8.8: 1.0 is stored as 256. Values therefore span -256..+256, which
#  needs 16 bits, which is why sin is split into two byte planes.
TRIG_ONE = 256
TRIG_STEPS = 256                     # a full turn in 256 brads
TRIG_QUARTER = TRIG_STEPS // 4       # cos(a) == sin(a + quarter)

# ---------------------------------------------------------------------------
#  The projection pipeline.
#
#  Everything below is the specification for src/math/*.asm. The Python here
#  and the Z80 there must agree BIT FOR BIT -- every shift is written the way
#  the Z80 actually does it, including where it truncates. tests/test_phase1.py
#  runs the real routines in the emulator and compares against project().
# ---------------------------------------------------------------------------

#  Rotation matrix entries are signed bytes with 127 == 1.0.
#
#  Why 127 and not 128: 128 does not fit in a signed byte. The cost is a
#  uniform 127/128 scale on the whole matrix -- a 0.8% zoom, invisible, and
#  absorbed into PROJ_K below. The benefit is that the accumulator cannot
#  overflow: |m.v| <= 127 * 128*sqrt(3) = 28156, comfortably inside 16 bits.
MAT_ONE = 127

#  How far down a world coordinate is shifted to become a camera-space one.
#
#  It was 8 -- free on a Z80, since >>8 is just "take H" -- and that mapped the
#  whole 16-bit world onto a +/-128 camera cube. With cam_dist at 110..250 the
#  widest zoom then showed essentially all of it, which is why the play area
#  felt small. At 6 the same 16 bits span +/-512 camera units, four times the
#  extent per axis, and every authored position and speed in src/game/ was
#  divided by four to match so that ships are the same size on screen as
#  before. The extra room is the coordinate space that freed up.
WORLD_SHIFT = 6

#  ...but ONE delta still has to fit a signed byte, so what you can see at once
#  did not grow: anything further than PROJ_V_MAX << WORLD_SHIFT (8191 world
#  units) from the focus on any axis is clipped outright.
#
#  Two independent reasons, both about MAT_ONE:
#
#    * MULACC indexes the signed quarter-square table with m+v as a NINE-bit
#      two's complement number. |m| reaches MAT_ONE, so |m| + |v| must stay
#      inside 256 or the index wraps and the entity reappears somewhere it is
#      not.
#    * The rotation accumulator is bounded by MAT_ONE * |v|max * sqrt(3), which
#      is 28156 at |v| = 128 and 56312 at 256. The second does not fit 16 bits.
#
#  proj_deltas does the clipping, which is also a saving: a rejected entity
#  never reaches the ~2,790 T-state proj_rotate.
PROJ_V_MIN = -128
PROJ_V_MAX = 127

#  sx = 160 + ((x * recip[z]) >> PROJ_SHIFT), and recip[z] = PROJ_K / z.
#
#  PROJ_K is set so that x == z (45 degrees off axis) lands exactly on the
#  screen edge, i.e. a 90 degree horizontal field of view:
#      (z * (PROJ_K/z)) >> PROJ_SHIFT == 160   =>   PROJ_K = 160 << PROJ_SHIFT
#
#  PROJ_SHIFT is 7 rather than 8 because recip must stay inside a byte: at
#  shift 8 the near plane would have to sit at z=161, leaving a depth range of
#  only 1.6:1 and a picture with almost no perspective in it. Shift 7 buys a
#  3:1 range instead. It is also cheap on the Z80 -- see proj_shr7.
PROJ_SHIFT = 7
PROJ_K = 160 << PROJ_SHIFT           # 20480

#  Z_NEAR is the smallest z where recip still fits in a byte (20480/84 = 244).
Z_NEAR = 84
Z_FAR = 255

#  Size tiers (Homeplanet.md section 5.1). Tier 2 is the 24x16 close-up, 1 the
#  16x10 middle distance, 0 the 8x6 far one. Chosen so the apparent size of a
#  ship changes at roughly the point where the next tier down would be drawing
#  the same number of lit pixels anyway.
TIER_C_MAX_Z = 130                   # nearer than this -> 24x16
TIER_B_MAX_Z = 190                   # nearer than this -> 16x10
                                     # anything further -> 8x6

# ---------------------------------------------------------------------------
#  The zoom ladder (Homeplanet.md section 4.3, extended)
# ---------------------------------------------------------------------------
#  ZOOMING OUT IS NOT A LONGER cam_dist, and finding that out is the whole
#  story of this table.
#
#  proj_deltas has to fit one axis of (P - focus) into a signed byte, so the
#  camera can only ever see a +/-127 CAMERA-UNIT cube around its focus, and
#  cam_dist decides only how much of the SCREEN that cube covers. Measure it:
#  at cam_dist 250 the whole cube lands between sx 120 and sx 200 -- the middle
#  quarter of a 320-pixel screen. So the four distances 110..250 are not four
#  amounts of world, they are one amount of world drawn at four sizes, and
#  three of them show exactly the same 8191-unit radius. That is the
#  "everything is far away and tiny" complaint, and no amount of extra
#  cam_dist fixes it: past 255 the perspective divide runs out of byte.
#
#  What DOES change how much world is visible is how far a world delta is
#  shifted down on its way into that cube. One more bit of shift is one more
#  doubling of the radius, at exactly the same screen positions and the same
#  size tiers -- which is precisely what was asked for: the same small or
#  large ships, more world between them.
#
#  Powers of two alone would be a coarse ladder -- four steps out would be
#  16x -- so half-steps come from a second form:
#
#      v = 3 * (delta >> S)           instead of     v = delta >> S
#
#  The x3 form saturates at v = +/-126 rather than +/-127, so its radius is
#  42<<S against the plain form's 128<<S. Put the two together and the ladder
#  goes ... 128<<S, 42<<(S+2), 128<<(S+1) ... which is alternating steps of
#  4/3 and 3/2 -- about 1.4x a notch, twelve notches, 36x end to end. Both
#  forms are a shift and at most two adds; neither needs a multiply. See
#  proj_scale.
#
#  Radius here is the largest world delta per axis that still projects, and it
#  is what "how much can I see" means. The 16-bit world is +/-32767, so the
#  widest step covers all of it and there is deliberately no step past that.
#
#      idx  dist  radius   world units per screen pixel
#        0   110    2048    11
#        4   110    8192    44          <- the old step 0
#        5   150    8192    60          <- the old step 1, still the default
#        7   250    8192   100          <- the old step 3
#       11   250   32768   400
#
#  (dist, shift, mul3)
ZOOM_STEPS = [
    (110, 4, False),                 # 0  in  x16
    (110, 6, True),                  # 1
    (110, 5, False),                 # 2
    (110, 7, True),                  # 3
    (110, 6, False),                 # 4  the old four steps begin here
    (150, 6, False),                 # 5  ...and this is where the game starts
    (200, 6, False),                 # 6
    (250, 6, False),                 # 7  the old widest
    (250, 8, True),                  # 8  out
    (250, 7, False),                 # 9
    (250, 9, True),                  # 10
    (250, 8, False),                 # 11 the whole 16-bit world at once
]

#  Where the game starts, and the step whose scaling is plain >> WORLD_SHIFT --
#  src/main.asm asserts those are the same step, because everything that pokes
#  cam_dist without touching the zoom (the differential tests, mostly) is
#  relying on the boot-time patch state being the neutral one.
ZOOM_DEFAULT = 5

#  Consolidation (todo item 3) turns on here: the steps that were added, not
#  the ones that were already there. Below this the picture is unchanged.
ZOOM_GROUP_FROM = 8


def zoom_radius(step: int) -> int:
    """Largest world delta per axis that still projects, at this zoom step."""
    _, shift, mul3 = ZOOM_STEPS[step]
    return 42 << shift if mul3 else 128 << shift


#  Bytes of proj_scale, by name, so the table below reads as instructions
#  rather than as hex.
_Z80_ADD_A_N = 0xC6
_Z80_AND_N = 0xE6
_Z80_CP_N = 0xFE
_Z80_ADD_HL_HL = 0x29
_Z80_NOP = 0x00
_Z80_SRA_A = (0xCB, 0x2F)
_Z80_SCF_RET = (0x37, 0xC9)
_Z80_JR_0 = (0x18, 0x00)             # to the instruction immediately after

ZOOM_RECORD = 14                     # exactly what it holds; see order_apply_zoom


def zoom_patch(step: int) -> list[int]:
    """The record order_apply_zoom LDIRs into proj_scale's instruction stream.

        +0   cam_dist, a word
        +2   the range check: `add a,bias : cp limit`, or `and 0 : cp 1`
        +6   the shift ladder: four `add hl,hl`, each NOP'd out or not
        +10  `sra a`, or two NOPs
        +12  `scf : ret`, or a `jr` into the x3 tail

    Deriving it here rather than writing twelve rows of magic numbers by hand
    is the point: the shift is the only thing ZOOM_STEPS states.
    """
    dist, shift, mul3 = ZOOM_STEPS[step]

    #  HL >> shift, as `<< (8 - shift)` and then "take H" when that fits, and
    #  as "take H" and then arithmetic halvings when it does not.
    n = max(0, 8 - shift)                # left shifts before taking H
    m = max(0, shift - 8)                # halvings of A after taking H
    assert n <= 4 and m <= 1, f"zoom step {step}: shift {shift} is off the ladder"

    #  The left shift is only safe while the top n+1 bits of HL agree, which
    #  on the high byte is h in -2^(shift-1) .. 2^(shift-1)-1. That bound is a
    #  whole number of 256s, so the byte test is EXACT rather than a
    #  conservative one -- and for the plain form it is also exactly the
    #  "v fits a signed byte" test, so one check does both jobs.
    if n:
        bias = 1 << (shift - 1)
        check = [_Z80_ADD_A_N, bias, _Z80_CP_N, (bias * 2) & 0xFF]
    else:
        #  Nothing to reject: v is H itself (or half of it), which is a byte
        #  by construction. `and 0 : cp 1` passes everything and costs the
        #  same as the check it replaces, so there is no branch to skip it.
        check = [_Z80_AND_N, 0, _Z80_CP_N, 1]

    ladder = [_Z80_ADD_HL_HL] * n + [_Z80_NOP] * (4 - n)
    halve = list(_Z80_SRA_A) if m else [_Z80_NOP, _Z80_NOP]
    tail = list(_Z80_JR_0) if mul3 else list(_Z80_SCF_RET)

    rec = [dist & 0xFF, dist >> 8] + check + ladder + halve + tail
    assert len(rec) == ZOOM_RECORD
    return rec


def screen_line_offsets() -> list[int]:
    """Byte offset of each pixel line from the base of a screen buffer.

    The CPC interleaves: line L of character row R lives L*0x800 bytes into
    the buffer plus R*80. Stored as an offset rather than an address so the
    same table serves both buffers -- see scr_line_addr.
    """
    return [
        ((y & 7) * 0x800) + ((y >> 3) * SCR_BYTES_PER_LINE)
        for y in range(SCR_HEIGHT_PX)
    ]


def quarter_squares() -> list[int]:
    """f(n) = floor(n^2 / 4), for n in 0..511.

    The Z80 has no multiplier. The identity

        a * b = f(a + b) - f(a - b)

    turns an 8x8 multiply into two table reads and a subtraction, roughly 70
    T-states against ~200 for shift-and-add (Homeplanet.md section 4.2).

    One table covers both terms: a+b reaches 510, and |a-b| never exceeds 255,
    so the difference term indexes the same array. 512 entries, split into a
    low and a high byte plane, each page-aligned.
    """
    return [(n * n) // 4 for n in range(512)]


def signed_quarter_squares() -> list[int]:
    """f(s) = floor(s^2 / 4), indexed by s as a 9-bit TWO'S COMPLEMENT number.

    This is the table that makes the rotation loop branchless.

    f is even, so the quarter-square identity works on signed operands
    unchanged -- a*b = f(a+b) - f(a-b) -- and it stays exact under floor
    division because a+b and a-b always have the same parity, so their
    remainders cancel.

    The only awkward part is the index: for signed bytes, a+b spans -255..254
    and a-b spans -255..255, so it needs nine bits. Storing f of the SIGNED
    index rather than f of the magnitude means the Z80 never has to work out
    an absolute value: the 16-bit sum it already has in HL is the index, with
    bit 8 being `H AND 1` (H is #00 or #FF and nothing else in this range).

    Entries 256..511 therefore hold f of the negative values.
    """
    return [((i if i < 256 else i - 512) ** 2) // 4 for i in range(512)]


def tier_table() -> list[int]:
    """Which sprite size tier to draw at each camera depth."""
    return [
        2 if z < TIER_C_MAX_Z else 1 if z < TIER_B_MAX_Z else 0
        for z in range(256)
    ]


def sin7_table() -> list[int]:
    """sin(angle) * 127, one signed byte per angle.

    The matrix build wants single-byte trig, not the 8.8 pair: it multiplies
    these together with the ordinary signed 8x8 routine and shifts back by 7.

    This is the MODEL. What is emitted is sin7_quarter() -- see there.
    """
    return [
        round(MAT_ONE * math.sin(2.0 * math.pi * i / TRIG_STEPS))
        for i in range(TRIG_STEPS)
    ]


def sin7_quarter() -> list[int]:
    """The first quadrant of sin7, entries 0..TRIG_QUARTER inclusive.

    A full turn is four copies of this with two reflections, and cam_sin does
    the folding: 191 bytes of a low 16K that has none, for about 40 T-states
    in a routine called FOUR TIMES A FRAME. It would be a bad trade in
    proj_rotate and it is an obvious one here.

    The symmetry is exact rather than approximate, which is what makes this
    safe: sin(pi - x) == sin(x) and sin(-x) == -sin(x) hold in the reals, and
    round() is symmetric about zero, so folding an angle cannot land a
    different byte than the full table held. sin7_table() above stays the
    model the tests compare the FOLDED result against.
    """
    return sin7_table()[:TRIG_QUARTER + 1]


def recip_table() -> list[int]:
    """recip[z] = PROJ_K / z, one unsigned byte per depth.

    Entry 0 is never read -- anything nearer than Z_NEAR is clipped first --
    but it has to hold something, so it holds the clamp value.
    """
    out = [255]
    for z in range(1, 256):
        out.append(min(255, (PROJ_K + z // 2) // z))
    return out


# ---------------------------------------------------------------------------
#  Reference model. Mirrors src/math/ instruction for instruction.
# ---------------------------------------------------------------------------

def _i16(v: int) -> int:
    v &= 0xFFFF
    return v - 65536 if v >= 32768 else v


def mul7(a: int, b: int) -> int:
    """(a * b) >> 7 on a signed 16-bit product, as the Z80 does it.

    Python's >> on negative integers floors, and so does an arithmetic shift,
    so these agree without any special casing.
    """
    return (a * b) >> 7


def camera_matrix(yaw: int, pitch: int) -> list[int]:
    """The 3x3 world-to-camera rotation as nine signed bytes at MAT_ONE scale.

    Orbit camera: yaw about Y, then pitch about X, so M = Rx(pitch).Ry(yaw).
    Row 0 has a structural zero in the middle -- cam_build_matrix stores it
    anyway so the projection loop can stay a flat nine-multiply run.
    """
    s = sin7_table()
    sy, cy = s[yaw & 255], s[(yaw + TRIG_QUARTER) & 255]
    sp, cp = s[pitch & 255], s[(pitch + TRIG_QUARTER) & 255]
    return [
        cy,             0,   sy,
        mul7(sp, sy),   cp,  -mul7(sp, cy),
        -mul7(cp, sy),  sp,  mul7(cp, cy),
    ]


def scale_delta(d: int, shift: int = WORLD_SHIFT, mul3: bool = False):
    """One world delta into a camera-space component, or None if out of range.

    The model for proj_scale. `mul3` is the half-step form: three times a
    delta shifted two bits further, which reaches 4/3 as far as the plain
    form for the price of two adds.
    """
    t = d >> shift                           # arithmetic, and so is the Z80's
    if mul3:
        #  3*43 is 129, which is not a signed byte, so 42 is the last one in.
        return None if t < -42 or t > 42 else 3 * t
    return None if t < PROJ_V_MIN or t > PROJ_V_MAX else t


def project(point, focus, matrix, cam_dist, shift=WORLD_SHIFT, mul3=False):
    """One entity through the whole pipeline.

    Returns (sx, sy, z) or None if it was clipped. `z` is the camera-space
    depth the size tier is chosen from. `shift`/`mul3` are the zoom step's
    scaling -- see ZOOM_STEPS; the defaults are the neutral step.
    """
    #  v = (P - focus) scaled down, CLIPPED rather than truncated -- see
    #  PROJ_V_MAX. Two ways to be out of range, and the Z80 tests for both:
    #  the 16-bit subtract itself can overflow (SBC HL,DE sets P/V, and the
    #  sign bit lies when it does), and the scaled result can leave a byte.
    v = []
    for i in range(3):
        d = point[i] - focus[i]
        if d < -32768 or d > 32767:
            return None
        c = scale_delta(d, shift, mul3)
        if c is None:
            return None
        v.append(c)

    rotated = []
    for row in range(3):
        acc = sum(matrix[row * 3 + col] * v[col] for col in range(3))
        rotated.append(_i16(acc))

    x = rotated[0] >> 8                      # ld a,h
    y = rotated[1] >> 8
    z = (rotated[2] >> 8) + cam_dist

    if z < Z_NEAR or z > Z_FAR:
        return None

    r = recip_table()[z]
    sx = SCR_CENTRE_X + ((x * r) >> PROJ_SHIFT)
    sy = SCR_CENTRE_Y - ((y * r) >> PROJ_SHIFT)

    if not (0 <= sx < SCR_WIDTH_PX and 0 <= sy < SCR_HEIGHT_PX):
        return None
    return sx, sy, z


# ---------------------------------------------------------------------------
#  Emission
# ---------------------------------------------------------------------------

def _split_planes(values: list[int]) -> tuple[list[int], list[int]]:
    """Split signed/unsigned 16-bit values into low and high byte planes."""
    lo, hi = [], []
    for v in values:
        w = v & 0xFFFF
        lo.append(w & 0xFF)
        hi.append(w >> 8)
    return lo, hi


def _defb_block(name: str, data: list[int], per_line: int = 16) -> str:
    """Emit bytes. Signed values are masked to two's complement first --
    RASM will not parse `#-19`."""
    out = [f"{name}:"]
    for i in range(0, len(data), per_line):
        chunk = ",".join("#%02X" % (b & 0xFF) for b in data[i:i + per_line])
        out.append(f"    defb {chunk}")
    return "\n".join(out)


def _defw_block(name: str, data: list[int], per_line: int = 8) -> str:
    out = [f"{name}:"]
    for i in range(0, len(data), per_line):
        chunk = ",".join("#%04X" % (w & 0xFFFF) for w in data[i:i + per_line])
        out.append(f"    defw {chunk}")
    return "\n".join(out)


def render_zoom() -> str:
    """gen/zoom.asm -- cam_zoom_table, for the bank-4 section of src/main.asm.

    Its own file because it is the one generated thing that does NOT belong in
    the low 16K: order_apply_zoom reads it on a keypress, with bank 4 at rest
    under the window, so it costs nothing to reach and the low 16K has nothing
    to spare.
    """
    lines = [
        "; " + "=" * 74,
        ";  gen/zoom.asm -- GENERATED by tools/gentables.py, do not edit",
        "; " + "=" * 74,
        ";  cam_zoom_table -- one CAM_ZOOM_RECORD-byte record per zoom step:",
        ";",
        ";    +0   cam_dist, a word",
        ";    +2   the range check:  `add a,bias : cp limit`, or `and 0 : cp 1`",
        ";    +6   the shift ladder: four `add hl,hl`, NOP'd out or not",
        ";    +10  `sra a`, or two NOPs",
        ";    +12  `scf : ret`, or a `jr` into the x3 tail",
        ";",
        ";  Twelve of the fourteen bytes are Z80 INSTRUCTIONS: order_apply_zoom",
        ";  LDIRs them into the middle of proj_scale, which is where the zoom",
        ";  actually happens. Radius below is the largest world delta per axis",
        ";  that still projects -- what \"how much can I see\" means.",
        "; " + "=" * 74,
        "",
        "cam_zoom_table:",
    ]
    for i, (dist, shift, mul3) in enumerate(ZOOM_STEPS):
        kind = "3*(d>>%d)" % shift if mul3 else "d>>%d" % shift
        lines.append("    ; %2d: dist %3d, %-9s radius %d"
                     % (i, dist, kind, zoom_radius(i)))
        lines.append("    defb " + ",".join("#%02X" % b for b in zoom_patch(i)))
    lines += ["cam_zoom_table_end:", ""]
    return "\n".join(lines) + "\n"


def render() -> str:
    lines = [
        "; " + "=" * 74,
        ";  gen/tables.asm -- GENERATED by tools/gentables.py, do not edit",
        ";",
        ";  Regenerate with `make tables`. The generator is the readable",
        ";  specification; this file is just its output.",
        "; " + "=" * 74,
        "",
    ]

    # --- the zoom ladder ----------------------------------------------------
    #  The equates only. The TABLE itself goes to gen/zoom.asm and lives in
    #  bank 4, because it is read on a keypress and the low 16K is full; see
    #  render_zoom below.
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  The zoom ladder. cam_zoom_table itself is in gen/zoom.asm, in bank 4.",
        ";  See tools/gentables.py's ZOOM_STEPS for why cam_dist cannot zoom out:",
        ";  what you can see is a +/-127 cube, and cam_dist only decides how much",
        ";  of the screen it lands on.",
        "; ---------------------------------------------------------------------------",
        f"CAM_ZOOM_STEPS   equ {len(ZOOM_STEPS)}",
        f"CAM_ZOOM_DEFAULT equ {ZOOM_DEFAULT}",
        f"CAM_ZOOM_GROUP_FROM equ {ZOOM_GROUP_FROM}",
        f"CAM_ZOOM_RECORD  equ {ZOOM_RECORD}",
        f"CAM_ZOOM_DEFAULT_SHIFT equ {ZOOM_STEPS[ZOOM_DEFAULT][1]}",
        ";  The widest step's radius, which the Mothership indicator borrows: it",
        ";  reprojects at this step because proj_scale's range check is patched",
        ";  out there, so proj_deltas cannot reject a point however far off it is.",
        f"CAM_ZOOM_LAST_RADIUS equ {zoom_radius(len(ZOOM_STEPS) - 1)}",
        "",
    ]

    # --- single-byte trig, FIRST and unaligned ------------------------------
    #  Before the page-aligned run, deliberately. It is 65 bytes and cam_sin
    #  indexes it by adding rather than by paging, so it does not want an
    #  `align 256` of its own -- and put AFTER the aligned tables it would sit
    #  in front of one and the next `align` would give the 191 bytes straight
    #  back. Here it lands in the slack the alignment was going to waste.
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  sin7 -- the FIRST QUADRANT of sin(a) * 127, one signed byte per angle.",
        ";  cam_sin folds the other three onto it; see sin7_quarter() for why that",
        ";  is exact, and cam_sin for what it costs (nothing that matters).",
        "; ---------------------------------------------------------------------------",
        f"MAT_ONE equ {MAT_ONE}",
        f"TRIG_STEPS   equ {TRIG_STEPS}",
        f"TRIG_QUARTER equ {TRIG_QUARTER}",
        "",
        ";  Emitted so src/main.asm can assert that proj_deltas' hand-written",
        ";  range check still matches the model's WORLD_SHIFT.",
        f"WORLD_SHIFT  equ {WORLD_SHIFT}",
        "",
        _defb_block("sin7", sin7_quarter()),
        f"SIN7_ENTRIES equ {TRIG_QUARTER + 1}",
        "",
    ]

    # --- screen line offsets ------------------------------------------------
    offsets = screen_line_offsets()
    line_lo, line_hi = _split_planes(offsets)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  scr_line_lo / scr_line_hi -- byte offset of pixel line y from a buffer base.",
        ";",
        ";  Two byte planes on CONSECUTIVE pages, not one word table. That lets",
        ";  scr_line_addr index them with `ld h,page : ld l,y` and step between the",
        ";  planes with `inc h`, so it never needs a 16-bit register pair for the base",
        ";  -- which means it never clobbers DE, which callers hold their parameters in.",
        ";",
        ";  The offset never reaches #4000, so the buffer's high byte can be OR'd on",
        ";  rather than added.",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("scr_line_lo", line_lo),
        "    align 256",
        _defb_block("scr_line_hi", line_hi),
        "",
        f"SCR_LINE_TABLE_ENTRIES equ {len(offsets)}",
        "",
    ]

    # --- quarter squares ----------------------------------------------------
    qsq = quarter_squares()
    qsq_lo, qsq_hi = _split_planes(qsq)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  qsq_lo / qsq_hi -- f(n) = n*n/4, n = 0..511, as two byte planes.",
        ";  a*b = f(a+b) - f(a-b). Both planes are page-aligned, so a 9-bit index is",
        ";      ld h,HIGH(qsq_lo) : ld l,a : jr nc,$+3 : inc h",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("qsq_lo", qsq_lo),
        "    align 256",
        _defb_block("qsq_hi", qsq_hi),
        "",
    ]

    #  The 8.8 sine table that used to live here is gone. cam_build_matrix
    #  wants single-byte trig and reads sin7 below; nothing ever read the
    #  two-plane 8.8 version, and it was 512 bytes of the low 16K.

    # --- signed quarter squares --------------------------------------------
    f9 = signed_quarter_squares()
    f9_lo, f9_hi = _split_planes(f9)
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  f9_lo / f9_hi -- f(s) for s as a 9-bit two's complement index.",
        ";  What the rotation loop uses: m*v = f9[(m+v) & 1FF] - f9[(m-v) & 1FF],",
        ";  with no absolute values, no sign tracking and no branches at all.",
        "; ---------------------------------------------------------------------------",
        "    align 256",
        _defb_block("f9_lo", f9_lo),
        "    align 256",
        _defb_block("f9_hi", f9_hi),
        "",
    ]

    # --- perspective --------------------------------------------------------
    lines += [
        "; ---------------------------------------------------------------------------",
        ";  recip -- PROJ_K / z, one unsigned byte per depth.",
        f";  sx = 160 + ((x * recip[z]) >> {PROJ_SHIFT}),  sy = 100 - (likewise)",
        f";  Valid for z in {Z_NEAR}..{Z_FAR}; nearer than that and the byte would clamp,",
        ";  so proj_point clips first.",
        "; ---------------------------------------------------------------------------",
        f"PROJ_SHIFT equ {PROJ_SHIFT}",
        f"PROJ_K     equ {PROJ_K}",
        f"Z_NEAR     equ {Z_NEAR}",
        f"Z_FAR      equ {Z_FAR}",
        "",
        "    align 256",
        _defb_block("recip", recip_table()),
        "",
        "; ---------------------------------------------------------------------------",
        ";  Sprite size tier per depth: 2 = 24x16, 1 = 16x10, 0 = 8x6.",
        ";",
        ";  This was a 256-byte page-aligned table, read with three instructions.",
        ";  It holds three distinct values with two edges in it, so phase4_tier_for",
        ";  does the two compares instead -- the same ~20 T-states, and 256 bytes",
        ";  of the low 16K back, which is what paid for the zoom ladder and the",
        ";  grouping pass. tier_table() below is still the model the tests check.",
        "; ---------------------------------------------------------------------------",
        f"TIER_C_MAX_Z equ {TIER_C_MAX_Z}",
        f"TIER_B_MAX_Z equ {TIER_B_MAX_Z}",
        "",
    ]

    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=os.path.join(here, "src", "gen", "tables.asm"))
    ap.add_argument("--out-zoom", default=os.path.join(here, "src", "gen", "zoom.asm"),
                    help="cam_zoom_table, which is assembled into bank 4")
    args = ap.parse_args(argv)

    for path, text in ((args.out, render()), (args.out_zoom, render_zoom())):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {path} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
