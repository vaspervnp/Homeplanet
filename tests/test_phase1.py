"""Phase 1 acceptance tests -- the 3D pipeline.

The core test here is differential: tools/gentables.py contains a Python model
of the projection written to mirror the Z80 instruction for instruction, and
these tests run the REAL routines in the emulator and demand the two agree
BIT FOR BIT over thousands of random inputs.

That is stronger than checking the output "looks about right". Fixed-point
code fails by being off by one in one quadrant, at one shift, for negative
inputs only -- exactly the kind of thing an eyeball test sails past.
"""

from __future__ import annotations

import random
import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tools import gentables as g


def s16(v: int) -> bytes:
    return struct.pack("<h", v)


class EmuFixture(unittest.TestCase):
    """A booted machine plus the ability to call routines in it."""

    @classmethod
    def setUpClass(cls):
        cls.c = h.boot_quick(frames=30)
        cls.sym = h.symbols()

    def call(self, symbol: str, setup: bytes = b"", frames: int = 2):
        """Run `setup` then CALL the routine, and stop.

        The stub lives at #3000, which is free space between the end of the
        code and the stack.
        """
        addr = self.sym[symbol]
        stub = b"\xF3" + setup + bytes([0xCD, addr & 0xFF, addr >> 8, 0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(frames)

    def word(self, symbol: str) -> int:
        lo, hi = self.c.read_ram(self.sym[symbol], 2)
        return lo | (hi << 8)

    def byte(self, symbol: str, signed: bool = False) -> int:
        v = self.c.read_ram(self.sym[symbol], 1)[0]
        return v - 256 if signed and v >= 128 else v


class TestMultiply(EmuFixture):
    """The quarter-square routines, against Python's own multiplication."""

    def _mul(self, symbol: str, a: int, b: int, reg_hl: bool) -> int:
        # reg_hl: mul_u8 takes H=a L=b; the signed ones take B=a C=c
        setup = bytes([0x21, b & 0xFF, a & 0xFF]) if reg_hl else \
                bytes([0x01, b & 0xFF, a & 0xFF])
        self.call(symbol, setup)
        # the routines leave the result in HL; park it somewhere readable
        return None  # replaced below

    def _run_mul(self, symbol: str, a: int, b: int, reg_hl: bool) -> int:
        addr = self.sym[symbol]
        load = [0x21, b & 0xFF, a & 0xFF] if reg_hl else [0x01, b & 0xFF, a & 0xFF]
        stub = bytes([0xF3] + load
                     + [0xCD, addr & 0xFF, addr >> 8]
                     + [0x22, h.RESULT & 0xFF, h.RESULT >> 8]                # ld (#2F00),hl
                     + [0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(2)
        lo, hi = self.c.read_ram(h.RESULT, 2)
        return lo | (hi << 8)

    def test_mul_u8_exhaustive_edges(self):
        for a in (0, 1, 2, 127, 128, 200, 254, 255):
            for b in (0, 1, 2, 127, 128, 200, 254, 255):
                got = self._run_mul("MUL_U8", a, b, reg_hl=True)
                self.assertEqual(got, a * b, f"{a} * {b}")

    def test_mul_u8_random(self):
        rng = random.Random(1)
        for _ in range(150):
            a, b = rng.randrange(256), rng.randrange(256)
            self.assertEqual(self._run_mul("MUL_U8", a, b, reg_hl=True), a * b, f"{a}*{b}")

    def test_mul_s8_all_sign_combinations(self):
        for a in (-128, -127, -100, -1, 0, 1, 100, 127):
            for b in (-128, -127, -100, -1, 0, 1, 100, 127):
                got = self._run_mul("MUL_S8", a, b, reg_hl=False)
                want = (a * b) & 0xFFFF
                self.assertEqual(got, want, f"{a} * {b} -> #{got:04X}, want #{want:04X}")

    def test_mul_s8_random(self):
        rng = random.Random(2)
        for _ in range(150):
            a, b = rng.randrange(-128, 128), rng.randrange(-128, 128)
            self.assertEqual(self._run_mul("MUL_S8", a, b, reg_hl=False),
                             (a * b) & 0xFFFF, f"{a}*{b}")

    def test_mul_s8u8_covers_the_unsigned_range(self):
        """recip[] reaches 244, which would read back negative in mul_s8."""
        rng = random.Random(3)
        for _ in range(200):
            a, b = rng.randrange(-128, 128), rng.randrange(256)
            self.assertEqual(self._run_mul("MUL_S8U8", a, b, reg_hl=False),
                             (a * b) & 0xFFFF, f"{a}*{b}")


class TestShift(EmuFixture):
    def test_shr7_matches_an_arithmetic_shift(self):
        addr = self.sym["PROJ_SHR7"]
        for v in list(range(-32768, 32768, 617)) + [-32768, -1, 0, 1, 32767, 16256, -16384]:
            stub = bytes([0xF3, 0x21, v & 0xFF, (v >> 8) & 0xFF,
                          0xCD, addr & 0xFF, addr >> 8,
                          0x22, h.RESULT & 0xFF, h.RESULT >> 8, 0x18, 0xFE])
            self.c.write_ram(h.STUB, stub)
            self.c.set_pc(h.STUB)
            self.c.run_frames(2)
            lo, hi = self.c.read_ram(h.RESULT, 2)
            self.assertEqual(lo | (hi << 8), (v >> 7) & 0xFFFF, f"{v} >> 7")


class TestCameraMatrix(EmuFixture):
    """cam_build_matrix against camera_matrix() in the model."""

    def _build(self, yaw: int, pitch: int) -> list[int]:
        setup = bytes([0x3E, yaw & 0xFF, 0x32] + list(struct.pack("<H", self.sym["CAM_YAW"]))
                      + [0x3E, pitch & 0xFF, 0x32] + list(struct.pack("<H", self.sym["CAM_PITCH"])))
        self.call("CAM_BUILD_MATRIX", setup)
        raw = self.c.read_ram(self.sym["CAM_M"], 9)
        return [v - 256 if v >= 128 else v for v in raw]

    def test_matches_the_model(self):
        for yaw in range(0, 256, 11):
            for pitch in (-53, -32, -7, 0, 5, 31, 53):
                got = self._build(yaw, pitch)
                want = g.camera_matrix(yaw, pitch)
                self.assertEqual(got, want, f"yaw={yaw} pitch={pitch}")

    def test_row_zero_has_the_structural_zero(self):
        self.assertEqual(self._build(37, 12)[1], 0)


class TestProjection(EmuFixture):
    """proj_point against project() -- the whole pipeline, bit for bit."""

    def _project(self, point, focus, yaw, pitch, dist, zoom=None):
        sym = self.sym
        setup = bytearray()

        def poke_word(addr, value):
            setup.extend([0x21] + list(struct.pack("<H", value & 0xFFFF)))
            setup.extend([0x22] + list(struct.pack("<H", addr)))

        def poke_byte(addr, value):
            setup.extend([0x3E, value & 0xFF, 0x32] + list(struct.pack("<H", addr)))

        poke_byte(sym["CAM_YAW"], yaw)
        poke_byte(sym["CAM_PITCH"], pitch)
        #  A zoom step is six bytes patched into proj_scale's own instruction
        #  stream, so it has to be put in force by the routine that owns them
        #  rather than poked. cam_dist goes in AFTER, because order_apply_zoom
        #  writes that as well and the callers here choose it independently.
        #
        #  Applied unconditionally, and that matters: the patch is machine
        #  state that outlives the call, so a test that walked the ladder
        #  would leave the next one projecting at some other zoom.
        if zoom is None:
            zoom = g.ZOOM_DEFAULT
        poke_byte(sym["CAM_ZOOM"], zoom)
        apply_zoom = sym["ORDER_APPLY_ZOOM"]
        setup.extend([0xCD, apply_zoom & 0xFF, apply_zoom >> 8])
        poke_word(sym["CAM_DIST"], dist)
        for i, name in enumerate(("CAM_FOCUS_X", "CAM_FOCUS_Y", "CAM_FOCUS_Z")):
            poke_word(sym[name], focus[i])

        # the point itself goes in scratch RAM at #2F10
        self.c.write_ram(h.DATA, b"".join(s16(v) for v in point))

        build = sym["CAM_BUILD_MATRIX"]
        proj = sym["PROJ_POINT"]
        stub = bytes([0xF3]) + bytes(setup) + bytes([
            0xCD, build & 0xFF, build >> 8,
            0x21, h.DATA & 0xFF, h.DATA >> 8,                       # ld hl,#2F10
            0xCD, proj & 0xFF, proj >> 8,
            0x9F,                                   # sbc a,a  -> #FF if CF else 0
            0x32, h.RESULT & 0xFF, h.RESULT >> 8,                       # ld (#2F00),a
            0x18, 0xFE,
        ])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(3)

        if self.c.read_ram(h.RESULT, 1)[0] == 0:
            return None
        return (self.word("PROJ_SX"), self.byte("PROJ_SY"), self.byte("PROJ_Z"))

    def _clamp16(self, v):
        return max(-32768, min(32767, v))

    def test_matches_the_model_on_random_input(self):
        """Points drawn AROUND THE FOCUS, straddling proj_deltas' range check.

        The spread is deliberate. proj_deltas only accepts a delta of up to
        8191 world units per axis (see PROJ_V_BIAS), so drawing points from
        the whole 16-bit world would clip almost all of them and leave the
        pipeline itself barely exercised; drawing them from well inside would
        never touch the clip. +/-9000 does both.
        """
        rng = random.Random(11)
        checked = visible = 0
        for _ in range(120):
            yaw = rng.randrange(256)
            pitch = rng.randrange(-53, 54)
            dist = rng.choice((110, 150, 200, 250))
            focus = tuple(rng.randrange(-8000, 8000) for _ in range(3))
            point = tuple(self._clamp16(focus[i] + rng.randrange(-9000, 9000))
                          for i in range(3))

            got = self._project(point, focus, yaw, pitch, dist)
            want = g.project(point, focus, g.camera_matrix(yaw, pitch), dist)
            self.assertEqual(got, want,
                             f"point={point} focus={focus} yaw={yaw} pitch={pitch} dist={dist}")
            checked += 1
            visible += got is not None

        self.assertGreater(visible, checked // 4,
                           f"only {visible}/{checked} points survived clipping -- "
                           "the test is not exercising the projection")

    def test_matches_the_model_right_across_the_world(self):
        """The other half: points anywhere at all, so the clip is what is tested.

        Almost everything here is rejected by proj_deltas, and the point is
        that the Z80 and the model reject the SAME ones. Two ways to be out of
        range and both are covered -- the shifted delta leaving a byte, and
        the 16-bit subtract overflowing outright, which it does whenever two
        coordinates are more than 32767 apart. That second one is why
        DISC_LIMIT is 30000 and this matters: a fleet can be sent there.
        """
        rng = random.Random(29)
        checked = clipped = 0
        for _ in range(120):
            yaw = rng.randrange(256)
            pitch = rng.randrange(-53, 54)
            dist = rng.choice((110, 150, 200, 250))
            focus = tuple(rng.randrange(-30000, 30000) for _ in range(3))
            point = tuple(rng.randrange(-32768, 32768) for _ in range(3))

            got = self._project(point, focus, yaw, pitch, dist)
            want = g.project(point, focus, g.camera_matrix(yaw, pitch), dist)
            self.assertEqual(got, want,
                             f"point={point} focus={focus} yaw={yaw} pitch={pitch} dist={dist}")
            checked += 1
            clipped += got is None

        self.assertGreater(clipped, checked // 2,
                           "nothing was clipped -- the range check is not being reached")

    def test_matches_the_model_at_every_zoom_step(self):
        """The same bit-exact contract, but with proj_scale's ladder moving.

        The zoom is a self-modified shift ladder inside proj_deltas, so every
        step is a DIFFERENT projection with its own rounding and its own clip
        radius -- twelve of them, four of which multiply by three afterwards.
        The plain steps and the x3 steps reject on different tests (a byte on
        the high half against a check on the scaled value), and getting either
        edge off by one puts a ship somewhere it is not, which is the failure
        the range check exists to prevent. So run the model against the metal
        at all twelve rather than trusting the neutral one to speak for them.
        """
        rng = random.Random(7)
        for step, (dist, shift, mul3) in enumerate(g.ZOOM_STEPS):
            radius = g.zoom_radius(step)
            visible = 0
            for _ in range(24):
                yaw = rng.randrange(256)
                pitch = rng.randrange(-53, 54)
                focus = tuple(rng.randrange(-20000, 20000) for _ in range(3))
                #  Straddle this step's own clip radius, so both sides of it
                #  are exercised at every rung of the ladder.
                spread = min(32000, radius * 3 // 2)
                point = tuple(self._clamp16(focus[i] + rng.randrange(-spread, spread))
                              for i in range(3))

                got = self._project(point, focus, yaw, pitch, dist, zoom=step)
                want = g.project(point, focus, g.camera_matrix(yaw, pitch),
                                 dist, shift, mul3)
                self.assertEqual(got, want,
                                 f"zoom step {step} (>>{shift}{' x3' if mul3 else ''}): "
                                 f"point={point} focus={focus} yaw={yaw} pitch={pitch}")
                visible += got is not None
            self.assertGreater(visible, 0, f"zoom step {step} showed nothing at all")

    def test_zooming_out_widens_what_can_be_seen(self):
        """The point of the whole exercise, stated as a property.

        A longer cam_dist does NOT show more world -- the visible region is a
        +/-127 camera cube and cam_dist only decides how much of the screen it
        lands on, which is why steps 4 to 7 all have the same radius below.
        What has to grow monotonically along the ladder is how far off the
        focus a ship can be and still be drawn.
        """
        radii = [g.zoom_radius(i) for i in range(len(g.ZOOM_STEPS))]
        self.assertEqual(radii, sorted(radii), f"the ladder is not monotonic: {radii}")
        self.assertGreaterEqual(radii[-1], 32767,
                                "the widest step does not cover the 16-bit world")
        self.assertLessEqual(radii[0] * 4, radii[g.ZOOM_DEFAULT],
                             "the innermost step is not appreciably closer in")

        #  ...and on the metal, at a fixed cam_dist so nothing but the ladder
        #  can be responsible.
        far = (20000, 0, 0)
        self.assertIsNone(self._project(far, (0, 0, 0), 0, 0, 250, zoom=7),
                          "the old widest step already showed a ship 20000 units out")
        self.assertIsNotNone(self._project(far, (0, 0, 0), 0, 0, 250, zoom=11),
                             "the new widest step still cannot see it")

    def test_a_distant_entity_is_dropped_rather_than_wrapped(self):
        """The failure this replaces put the ship somewhere it was not.

        A delta of 8191 units is the last one that fits; 8192 does not, and
        without the check it would index f9 out of its nine-bit range and come
        back as a perfectly plausible screen position.
        """
        self.assertIsNotNone(self._project((8191, 0, 0), (0, 0, 0), 0, 0, 250))
        self.assertIsNone(self._project((8192, 0, 0), (0, 0, 0), 0, 0, 250))
        self.assertIsNone(self._project((0, 0, 0), (0, 30000, 0), 0, 0, 250))
        #  ...and the case where the subtract itself overflows, where the sign
        #  bit lies about which way the entity even is.
        self.assertIsNone(self._project((32767, 0, 0), (-32768, 0, 0), 0, 0, 250))

    def test_a_point_at_the_focus_lands_dead_centre(self):
        got = self._project((0, 0, 0), (0, 0, 0), 0, 0, 150)
        self.assertEqual(got, (160, 100, 150))

    def test_clips_behind_the_camera(self):
        """A point behind the focus must fall outside the NEAR PLANE.

        Kept inside proj_deltas' range on purpose, or this would be testing
        the distance clip instead: -8000 world units is -125 camera units, and
        cam_dist 110 leaves that a long way in front of Z_NEAR.
        """
        got = self._project((0, 0, -8000), (0, 0, 0), 0, 0, 110)
        self.assertIsNone(got)

    def test_depth_grows_with_distance_along_the_view_axis(self):
        #  World units, so a quarter of what they were: proj_deltas clips
        #  anything past 8191 and the old ladder would have been three
        #  rejections and a point.
        seen = []
        for pz in (-4096, -2048, 0, 2048, 4096):
            r = self._project((0, 0, pz), (0, 0, 0), 0, 0, 200)
            if r:
                seen.append(r[2])
        self.assertEqual(seen, sorted(seen), f"depth is not monotonic: {seen}")
        self.assertGreater(len(seen), 2)


#  TestPhase1Demo lived here and drove the 100-point lattice demo, which
#  Phase 3 replaced with the sprite fleet (tests/test_phase3.py). The maths
#  tests above and the cost guard below are what actually protected the
#  projection, and they call the routines directly, so they carry over
#  unchanged.


class TestProjectionCost(EmuFixture):
    """Guard the per-entity cost, which is what the frame budget turns on."""

    #  Measured with the branchless f9 multiply and the unrolled rotate.
    #  24 entities at this cost is ~109,000 T, 41% of a 265,000 T frame.
    PROJ_POINT_BUDGET_T = 5000

    def test_proj_point_stays_within_budget(self):
        import struct

        self.c.write_ram(h.DATA, struct.pack("<hhh", 4000, -2500, 6000))
        addr = self.sym["PROJ_POINT"]
        iters = 800
        body = [0x21, h.DATA & 0xFF, h.DATA >> 8, 0xCD, addr & 0xFF, addr >> 8]
        stub = ([0xF3] + [0x01] + list(struct.pack("<H", iters)) + [0xC5] + body
                + [0xC1, 0x0B, 0x78, 0xB1, 0x20, (256 - (len(body) + 7)) & 0xFF]
                + [0x3E, 0xAA, 0x32, h.DATA & 0xFF, h.DATA >> 8, 0x18, 0xFE])
        self.c.write_ram(h.DATA, b"\x00")
        self.c.write_ram(h.STUB, bytes(stub))
        self.c.set_pc(h.STUB)

        frames = 0
        while self.c.read_ram(h.DATA, 1)[0] != 0xAA and frames < 600:
            self.c.run_frames(1)
            frames += 1
        self.assertLess(frames, 600, "the timing loop never finished")

        t_states = frames * 20e-3 * 4e6 / iters - 40      # less loop overhead
        self.assertLess(
            t_states, self.PROJ_POINT_BUDGET_T,
            f"proj_point is {t_states:.0f} T, budget {self.PROJ_POINT_BUDGET_T} T",
        )


if __name__ == "__main__":
    unittest.main()
