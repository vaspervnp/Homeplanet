"""Far ships are marks (game/farmarks.asm), and so is everything outside the
reticle while a ship is being flown.

Every claim is about ONE ship, by slot, and about pixels: which tier the
visible list gave it, what was drawn where its centre projects, in which
ink, and that the next frame took it off again. A count of lit bytes would
be satisfied by a sprite and by garbage alike.
"""

import struct
import unittest

from tests import harness as h
from tests.harness import cpc

ENT_SIZE = 20
ENT_CLASS, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_ORDER, ENT_TARGET, ENT_TIMER = 9, 10, 11, 12, 13, 14, 19
F_ACTIVE, F_ENEMY = 1, 2
VIS_SIZE = 6


class MarkFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()
        cls.ENT_MAX = cls.sym["ENT_MAX"]
        cls.PLAYER_MAX = cls.sym["ENT_PLAYER_MAX"]
        cls.MARK = cls.sym["MARK_TIER"]
        cls.MARK_Z = cls.sym["MARK_MIN_Z"]

    def setUp(self):
        self.c = h.boot_quick(frames=250)
        h.let_the_game_draw(self.c, self.sym)
        #  The battle frozen, so a ship stays where it is put; orders and the
        #  projection still run.
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")

    def tearDown(self):
        h.close(getattr(self, "c", None))

    # -- the machine ----------------------------------------------------------
    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def poke(self, slot, off, data):
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, data)

    def clear_everything(self):
        base = self.sym["ENTITIES"]
        for slot in range(self.ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

    def place(self, slot, pos, enemy=False, cls=0):
        self.poke(slot, 0, struct.pack("<hhh", *pos))
        self.poke(slot, ENT_CLASS, bytes([cls]))
        self.poke(slot, ENT_HULL, b"\xff")
        self.poke(slot, ENT_SQUAD, b"\xff" if enemy else b"\x01")
        self.poke(slot, ENT_ORDER, b"\x00")
        self.poke(slot, ENT_TARGET, b"\xff")
        self.poke(slot, ENT_TIMER, b"\xff")
        self.poke(slot, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))

    def visible(self):
        """The visible list, parked at the frame loop so it is whole."""
        h.run_to_stable_point(self.c, self.sym)
        n = self.byte("PHASE4_VISIBLE")
        base = self.sym["PHASE4_VIS"]
        out = []
        for i in range(n):
            e = self.c.read_ram(base + i * VIS_SIZE, VIS_SIZE)
            out.append({"sx": e[0] | (e[1] << 8), "sy": e[2], "z": e[3],
                        "view": e[4], "enemy": e[5] >> 7,
                        "cls": (e[5] >> 2) & 7, "tier": e[5] & 3,
                        "scale": (e[5] >> 5) & 3})
        return out

    def pen_at(self, x, y):
        """The pen of pixel (x, y) in the FRONT buffer."""
        buf = h.front_buffer(self.c)
        addr = buf + (y // 8) * 80 + (y % 8) * 0x800 + x // 4
        b = self.c.read_ram(addr, 1)[0]
        shift = 3 - (x % 4)
        return ((b >> (shift + 4)) & 1) | (((b >> shift) & 1) << 1)

    def settle(self):
        """Two game frames, so both buffers carry the current picture."""
        for _ in range(2):
            h.run_to_stable_point(self.c, self.sym)
            self.c.run_frames(1)
        h.run_to_stable_point(self.c, self.sym)

    def the_one(self, vis, enemy):
        """The one ship of that side that is not the Mothership, which the
        far-band fixture keeps for the camera and the defeat check."""
        ships = [v for v in vis if v["enemy"] == enemy and v["cls"] != 1]
        self.assertEqual(len(ships), 1, f"expected one ship of that side, saw {ships}")
        return ships[0]


class TestTheFarBand(MarkFixture):
    """Depth alone: past MARK_MIN_Z a ship is a dot, before it a sprite."""

    def far_and_near(self):
        """The Mothership at the origin for the camera, one hostile far out
        along +Z, one friendly nearer, both on the view axis so both project.

        ONE STEP OUT FIRST. At the default zoom the whole visible radius
        projects between depths 137 and 214 -- measured, and it is why
        MARK_MIN_Z sits where it does: the far band begins one zoom step out,
        where cam_dist is 200 and the far half of what is visible is past it.
        """
        self.clear_everything()
        moth = self.byte("MOTH_SLOT")
        self.place(moth, (0, 0, 0), cls=1)
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        self.c.key_down("x")
        self.c.run_frames(20)
        self.c.key_up("x")
        self.c.run_frames(20)
        #  Measured at cam_dist 200: 5200 along +Z is a depth of about 239,
        #  2000 about 215 -- either side of MARK_MIN_Z.
        self.place(self.PLAYER_MAX, (600, 0, 5200), enemy=True)   # far
        self.place(0, (-600, 0, 2000))                             # near
        self.settle()
        vis = self.visible()
        return self.the_one(vis, 1), self.the_one(vis, 0)

    def test_a_ship_past_the_threshold_is_the_mark_tier(self):
        far, near = self.far_and_near()
        self.assertGreaterEqual(far["z"], self.MARK_Z, "the fixture did not put the hostile far enough")
        self.assertEqual(far["tier"], self.MARK, "a far ship was not marked")
        self.assertLess(near["z"], self.MARK_Z)
        self.assertNotEqual(near["tier"], self.MARK, "a near ship was marked")

    def test_the_mark_is_two_pixels_in_the_sides_ink_where_the_ship_is(self):
        far, near = self.far_and_near()
        x, y = far["sx"], far["sy"]
        pens = {(x, y - 1): self.pen_at(x, y - 1), (x, y): self.pen_at(x, y)}
        self.assertEqual(set(pens.values()), {3}, f"the hostile's mark reads {pens}")
        #  ...one pixel wide: nothing of it in the neighbouring columns.
        self.assertEqual(self.pen_at(x - 1, y), 0)
        self.assertEqual(self.pen_at(x + 1, y), 0)
        #  ...and a friendly's would be white: the near one is a sprite, so
        #  ask its tier instead of its pixels.
        self.assertIn(near["tier"], (0, 1, 2))

    def test_two_steps_out_the_far_half_of_the_world_is_marks_not_nothing(self):
        """cam_dist is 250 two steps out and a byte of depth left five camera
        units past the focus, so a picket four thousand units past the fleet
        VANISHED there -- measured, and it had always been so. proj_point
        clamps to Z_FAR now, and what is past the byte is a mark."""
        self.clear_everything()
        moth = self.byte("MOTH_SLOT")
        self.place(moth, (0, 0, 0), cls=1)
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        for _ in range(2):
            self.c.key_down("x")
            self.c.run_frames(20)
            self.c.key_up("x")
            self.c.run_frames(20)
        self.place(self.PLAYER_MAX, (600, 0, 4000), enemy=True)
        self.settle()
        far = self.the_one(self.visible(), 1)
        self.assertEqual(far["z"], self.sym["Z_FAR"], "the far plane is not where it was clamped")
        self.assertEqual(far["tier"], self.MARK)
        self.assertEqual(self.pen_at(far["sx"], far["sy"]), 3, "no mark where the far hostile is")

    def test_the_mark_is_erased_when_the_ship_moves(self):
        far, near = self.far_and_near()
        x, y = far["sx"], far["sy"]
        self.assertEqual(self.pen_at(x, y), 3)
        #  Move it well aside and let both buffers catch up.
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", 600 - 2400, 0, 5200))
        self.settle()
        self.assertEqual(self.pen_at(x, y), 0, "the old mark was not erased")
        self.assertEqual(self.pen_at(x, y - 1), 0, "the old mark was not erased")
        now = self.the_one(self.visible(), 1)
        self.assertNotEqual((now["sx"], now["sy"]), (x, y))
        self.assertEqual(self.pen_at(now["sx"], now["sy"]), 3, "the mark did not follow the ship")


class TestTheReticleBox(MarkFixture):
    """While a ship is flown, only what is inside the reticle is a sprite."""

    def fly_with_two_ahead(self):
        """The flown ship at the origin heading +Z (yaw 128), one hostile
        dead ahead inside the box and one off to the side, both close enough
        to be tier C on their depth alone."""
        self.clear_everything()
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.place(1, (0, 0, -30000), cls=1)                       # the base, far away
        self.place(0, (0, 0, 0))
        self.poke(0, 6, bytes([128]))                              # ENT_YAW: +Z
        #  THE NEAR PLANE IS 84 CAMERA UNITS, 5376 WORLD UNITS: anything
        #  nearer than that is not drawn from a cockpit at all. 6400 along +Z
        #  is 100 units, a depth of about 183 -- tier B -- and 3200 to the
        #  side of that lands about a hundred pixels right of the centre,
        #  well outside PILOT_BOX_HW.
        self.place(self.PLAYER_MAX, (0, 0, 6400), enemy=True)      # dead ahead
        self.place(self.PLAYER_MAX + 1, (3200, 0, 6400), enemy=True)   # off to the right
        h.write_bank4(self.c, self.sym["AUTO_ARMED"], b"\x00")
        self.c.write_ram(self.sym["SQUAD_SEL"], b"\x01")
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.assertEqual(self.byte("PILOT_SLOT"), 0, "V did not take the ship")
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()
        vis = self.visible()
        ahead = [v for v in vis if v["enemy"] and abs(v["sx"] - 160) <= self.sym["PILOT_BOX_HW"]]
        aside = [v for v in vis if v["enemy"] and abs(v["sx"] - 160) > self.sym["PILOT_BOX_HW"]]
        self.assertEqual(len(ahead), 1, f"expected one hostile in the box, saw {vis}")
        self.assertEqual(len(aside), 1, f"expected one hostile outside it, saw {vis}")
        return ahead[0], aside[0]

    def test_inside_the_box_a_sprite_outside_it_a_mark(self):
        ahead, aside = self.fly_with_two_ahead()
        self.assertLess(aside["z"], self.MARK_Z, "the side ship is far enough to be a mark on depth alone")
        self.assertNotEqual(ahead["tier"], self.MARK, "the ship in the reticle was marked")
        self.assertEqual(aside["tier"], self.MARK, "the ship outside the reticle was drawn as a sprite")

    def test_nothing_behind_the_nose_is_drawn_from_the_cockpit(self):
        """The eye is PILOT_CAM_DIST behind the flown ship, inside the near
        plane, so without this a ship a thousand units BEHIND the pilot was
        drawn in front of them -- the squadron they had just left, and the
        flown ship itself, which lags the focus by a frame."""
        self.fly_with_two_ahead()
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        self.place(2, (mx + 300, my, mz - 1500))                   # behind, and off the axis
        self.settle()
        vis = self.visible()
        ours = [v for v in vis if not v["enemy"]]
        self.assertEqual(ours, [], f"something of ours is drawn from the cockpit: {ours}")
        #  ...and the same ship IS drawn once the stick is handed back.
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()
        self.assertGreater(len([v for v in self.visible() if not v["enemy"]]), 0,
                           "the squadron is not drawn from the orbit camera either")

    def test_the_reticle_is_drawn_while_flying_and_not_otherwise(self):
        self.fly_with_two_ahead()
        gap, ln = self.sym["PILOT_RET_GAP"], self.sym["PILOT_RET_LEN"]
        cy = self.sym["PROJ_CENTRE_Y"]
        ticks = [(160 - gap - 1, cy), (160 + gap + 1, cy), (160, cy - gap - 1), (160, cy + gap + 1)]
        for x, y in ticks:
            self.assertEqual(self.pen_at(x, y), 1, f"no tick at {(x, y)}")
        #  Hand the ship back: the ticks go with it.
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.assertGreaterEqual(self.byte("PILOT_SLOT"), self.ENT_MAX)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()
        for x, y in ticks:
            self.assertEqual(self.pen_at(x, y), 0, f"a tick stayed at {(x, y)}")


class TestTheScanner(TestTheReticleBox):
    """The Elite-style box at the bottom right, while flying: the ship in the
    middle, every flying hostile a red dot placed by where it is relative to
    the ship's heading -- up is ahead, right is right."""

    def box(self):
        s = self.sym
        return (s["SCAN_CX"], s["SCAN_CY"], s["SCAN_X_BYTES"] * 4, s["SCAN_Y"],
                s["SCAN_W_BYTES"] * 4, s["SCAN_H"])

    def test_the_box_and_the_ship_are_drawn_while_flying(self):
        self.fly_with_two_ahead()
        cx, cy, x0, y0, w, hgt = self.box()
        self.assertEqual(self.pen_at(cx, cy), 1, "no ship in the middle of the scanner")
        for x, y in ((x0, cy), (x0 + w - 1, cy), (cx, y0), (cx, y0 + hgt - 1)):
            self.assertEqual(self.pen_at(x, y), 2, f"no frame at {(x, y)}")

    def dot_for(self, slot):
        """Where the scanner should put `slot`, modelled from the records:
        the deltas' high bytes shifted SCAN_SHIFT, rotated by the flown
        ship's yaw with sin7 and cam_mul7's arithmetic, clamped to the box.
        Modelled rather than written down because the flown ship FLIES
        during the frames V takes, so no fixed distance survives."""
        import math
        me = self.pos(self.byte("PILOT_SLOT"))
        them = self.pos(slot)
        yaw = self.field(self.byte("PILOT_SLOT"), 6)

        def hi(d):
            d = max(-32768, min(32767, d))
            return (d >> 8) >> self.sym["SCAN_SHIFT"]

        def sin7(a):
            return int(round(127 * math.sin(2 * math.pi * (a & 255) / 256)))

        def mul7(a, b):
            return ((a * b) * 2) >> 8

        dx, dz = hi(them[0] - me[0]), hi(them[2] - me[2])
        sn, cs = sin7(yaw), sin7(yaw + 64)
        ahead = mul7(dx, sn) - mul7(dz, cs)
        right = mul7(dz, sn) - mul7(dx, cs)
        w, h = self.sym["SCAN_HALF_W"], self.sym["SCAN_HALF_H"]
        ahead = max(-h, min(h, ahead))
        right = max(-w, min(w, right))
        cx, cy, *_ = self.box()
        return cx + right, cy - ahead

    def pos(self, slot):
        return struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE, 6))

    def field(self, slot, off):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, 1)[0]

    def test_a_hostile_ahead_is_a_dot_above_the_ship_and_one_to_the_right_is_right_of_it(self):
        """The ship heads +Z, so ahead is up and +X is right -- and the
        model above says exactly which pixel, from where the ships ARE."""
        self.fly_with_two_ahead()
        cx, cy, *_ = self.box()
        ax, ay = self.dot_for(self.PLAYER_MAX)
        rx, ry = self.dot_for(self.PLAYER_MAX + 1)
        self.assertEqual(ax, cx, "the hostile dead ahead is not in the ship's column")
        self.assertLess(ay, cy, "the hostile dead ahead is not above the ship")
        self.assertGreater(rx, cx, "the hostile to the right is not right of it")
        self.assertEqual(self.pen_at(ax, ay), 3, f"no dot at {(ax, ay)} for the hostile ahead")
        self.assertEqual(self.pen_at(rx, ry), 3, f"no dot at {(rx, ry)} for the hostile to the right")
        #  ...and nothing where a hostile is not: mirrored below, and left.
        self.assertEqual(self.pen_at(ax, 2 * cy - ay), 0)
        self.assertEqual(self.pen_at(2 * cx - rx, ry), 0)

    def test_it_turns_with_the_ship(self):
        """The same two hostiles with the ship heading +X (yaw 64): the one at
        +Z is now off the LEFT hand, the one at +X,+Z ahead-and-left."""
        self.fly_with_two_ahead()
        self.poke(0, 6, bytes([64]))                              # ENT_YAW: +X
        self.settle()
        cx, cy, *_ = self.box()
        #  sin 64 is 127 and cos 64 is 0, so ahead = dx and right = dz: the
        #  ship's right hand is (-cos, sin) = (0, 1) = +Z. The hostile at +Z
        #  is now dead to the right; the one at +X,+Z ahead of that.
        ax, ay = self.dot_for(self.PLAYER_MAX)
        rx, ry = self.dot_for(self.PLAYER_MAX + 1)
        self.assertGreater(ax, cx)
        self.assertEqual(ay, cy, "the +Z hostile is not dead on the right hand")
        self.assertLess(ry, cy, "the +X,+Z hostile is not ahead of it")
        self.assertEqual(self.pen_at(ax, ay), 3, f"no dot at {(ax, ay)}")
        self.assertEqual(self.pen_at(rx, ry), 3, f"no dot at {(rx, ry)}")

    def test_nothing_of_it_when_nobody_is_flying(self):
        self.fly_with_two_ahead()
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()
        cx, cy, x0, y0, w, hgt = self.box()
        for x, y in ((cx, cy), (x0, cy), (cx, y0)):
            self.assertEqual(self.pen_at(x, y), 0, f"the scanner stayed at {(x, y)}")


class TestTheScaledSprites(MarkFixture):
    """From the cockpit the nearest ships are drawn larger than tier C --
    x2 under PILOT_X2_RAW camera units ahead, x4 under PILOT_X4_RAW -- by
    pixel replication in gfx/sprscale.asm, and only PILOT_SPRITES ships are
    drawn as sprites at all; the rest are the sensor view's marks."""

    def fly_at(self, hostiles):
        """V on the fleet's lead ship, then `hostiles` -- (across, ahead,
        class) in world units -- laid out RELATIVE TO THE SHIP'S POSITION
        AND HEADING as they stand after V, as wrecks so they neither close
        nor shoot, and two game frames run UNPAUSED. Returns the visible
        list of the second frame, whose picture is in the front buffer.

        Not paused: order_focus does not move the cockpit's focus while the
        game is paused, so a ship poked to a new position was seen from
        where it used to be. The flown ship flies 200 units a frame, so
        every distance is placed mid-band with room for two frames.
        """
        import math
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        h.write_bank4(self.c, self.sym["AUTO_ARMED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(10)
        me = self.byte("PILOT_SLOT")
        self.assertLess(me, self.PLAYER_MAX, "V did not take a ship")
        h.run_to_stable_point(self.c, self.sym)
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        yaw = self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE + 6, 1)[0]
        a = 2 * math.pi * yaw / 256
        ahead = (math.sin(a), -math.cos(a))
        right = (-math.cos(a), math.sin(a))
        for slot in range(self.PLAYER_MAX, self.ENT_MAX):
            self.poke(slot, ENT_FLAGS, b"\x00")
        for i, (x, d, cls) in enumerate(hostiles):
            px = int(round(mx + ahead[0] * d + right[0] * x))
            pz = int(round(mz + ahead[1] * d + right[1] * x))
            self.place(self.PLAYER_MAX + i, (px, my, pz), enemy=True, cls=cls)
            self.poke(self.PLAYER_MAX + i, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | 4]))   # a wreck: it stays put
        for _ in range(2):
            self.c.run_frames(1)
            h.run_to_stable_point(self.c, self.sym)
        return self.visible()

    def hostile(self, vis, i):
        """The entry of the i-th hostile placed, found by its slot's x."""
        pos = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + (self.PLAYER_MAX + i) * ENT_SIZE, 6))
        cands = [v for v in vis if v["enemy"]]
        #  Nearer is deeper in the list's z... match on class and order of depth.
        cands.sort(key=lambda v: v["z"])
        return cands, pos

    def test_the_scale_bits_follow_the_distance(self):
        """A camera unit is 128 world units at the default zoom, and the
        ship flies 400 in the two frames: 2300 is 18 down to 15 camera
        units, x4 (under PILOT_X4_RAW, 16); 3600 is 28 down to 25, x2;
        5400 is 42 down to 39, tier C on its depth, unscaled."""
        vis = self.fly_at([(0, 2300, 0), (0, 3600, 0), (0, 5400, 0)])
        enemies = sorted([v for v in vis if v["enemy"]], key=lambda v: v["z"])
        self.assertEqual(len(enemies), 3, vis)
        self.assertEqual([v["scale"] for v in enemies], [2, 1, 0], enemies)
        self.assertEqual([v["tier"] for v in enemies], [2, 2, 2], "a scaled ship is tier C scaled")

    def expected_pixels(self, cls, view, scale):
        """The tier C block of `cls` at `view`, pre-shift 0, out of the bank
        image on disc, replicated `scale` times each way: a dict of
        (dx, dy) -> pen for the drawn pixels, about the centre."""
        names = ["interceptor", "mothership", "harvester", "scout", "bomber", "frigate", "salvage", "destroyer"]
        name = names[cls]
        bank = h.read_bank4  # unused; the raw images are what the disc holds
        base = self.sym[f"{name.upper()}_C"]
        block = self.sym[f"{name.upper()}_C_BLOCK_SZ"]
        w_bytes = self.sym[f"{name.upper()}_C_W_BYTES"]
        hgt = self.sym[f"{name.upper()}_C_H"]
        which = {"interceptor": 7, "destroyer": 7, "salvage": 5, "mothership": 5, "harvester": 5,
                 "scout": 6, "bomber": 6, "frigate": 6}[name]
        with open(f"build/bank{which}.raw", "rb") as f:
            image = f.read()
        off = base - 0x4000 + view * 2 * block
        rows = []
        for r in range(hgt):
            row = image[off + r * w_bytes * 2: off + (r + 1) * w_bytes * 2]
            pixels = []
            for b in range(6):                        # the seventh byte is the pre-shift's
                m, d = row[b * 2], row[b * 2 + 1]
                for k in range(4):
                    sh = 3 - k
                    mm = ((m >> (sh + 4)) & 1) | (((m >> sh) & 1) << 1)
                    dd = ((d >> (sh + 4)) & 1) | (((d >> sh) & 1) << 1)
                    pixels.append(None if mm == 3 else dd)   # a mask of 11 keeps the screen
            rows.append(pixels)
        out = {}
        for y, row in enumerate(rows):
            for x, pen in enumerate(row):
                if pen is None:
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        out[(x * scale + dx - 12 * scale, y * scale + dy - 8 * scale)] = pen
        return out

    def test_a_x4_hostile_is_the_tier_c_block_with_every_pixel_quadrupled(self):
        """Pixel for pixel against the block in build/bank7.raw, at the
        screen position the entry names, with pen 1 read as pen 3 -- the
        blitter's recolour, done on the expanded data."""
        vis = self.fly_at([(0, 2000, 0)])
        e = [v for v in vis if v["enemy"]][0]
        self.assertEqual(e["scale"], 2)
        want = self.expected_pixels(0, e["view"], 4)
        self.assertGreater(len(want), 200, "the block has no drawn pixels?")
        wrong = []
        for (dx, dy), pen in want.items():
            x, y = e["sx"] + dx, e["sy"] + dy
            if not (0 <= x < 320 and self.sym["CTX_BAR_H"] <= y < self.sym["HUD_TOP"]):
                continue
            got = self.pen_at(x, y)
            expect = 3 if pen == 1 else pen
            if got != expect:
                wrong.append(((x, y), got, expect))
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {len(want)} pixels differ")

    def test_a_x2_hostile_is_the_block_doubled(self):
        vis = self.fly_at([(0, 3600, 0)])
        e = [v for v in vis if v["enemy"]][0]
        self.assertEqual(e["scale"], 1)
        want = self.expected_pixels(0, e["view"], 2)
        wrong = [((e["sx"] + dx, e["sy"] + dy), self.pen_at(e["sx"] + dx, e["sy"] + dy), 3 if pen == 1 else pen)
                 for (dx, dy), pen in want.items()
                 if 0 <= e["sx"] + dx < 320 and self.sym["CTX_BAR_H"] <= e["sy"] + dy < self.sym["HUD_TOP"]
                 and self.pen_at(e["sx"] + dx, e["sy"] + dy) != (3 if pen == 1 else pen)]
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {len(want)} pixels differ")

    def test_only_the_nearest_three_are_sprites_and_the_rest_are_the_sensors_marks(self):
        """Five hostiles ahead: the three nearest are drawn as sprites, the
        two furthest as a fighter's dot and a destroyer's cross, whatever
        their depth says."""
        K = self.sym["PILOT_SPRITES"]
        #  Nothing past 8191 world units projects at all, so the far two sit
        #  just inside that, at tiers C and B -- marks only by the
        #  nearest-three rule, well inside the reticle's box. The near three
        #  are unscaled, tier C and B, and spread wide, so that no sprite
        #  lies over the pixels beside a far one's dot: the first version
        #  put a x4 sprite in the middle and read its pixels as the dot's.
        vis = self.fly_at([(0, 5400, 0), (2000, 6000, 0), (-2000, 6500, 0), (900, 7000, 0), (-900, 8000, 7)])
        enemies = sorted([v for v in vis if v["enemy"]], key=lambda v: v["z"])
        self.assertEqual(len(enemies), 5, vis)
        self.assertEqual(K, 3)
        far_fighter, far_capital = enemies[3], enemies[4]
        self.assertLess(far_fighter["z"], self.MARK_Z, "the fixture's far fighter is a mark on depth alone")
        #  A dot: one pixel wide, two tall, nothing beside it.
        x, y = far_fighter["sx"], far_fighter["sy"]
        self.assertEqual({self.pen_at(x, y - 1), self.pen_at(x, y)}, {3}, "no dot for the fourth hostile")
        self.assertEqual(self.pen_at(x - 2, y), 0, "the fourth hostile is more than a dot")
        self.assertEqual(self.pen_at(x + 2, y), 0)
        #  A cross: the centre and its four neighbours, and nothing diagonal.
        x, y = far_capital["sx"], far_capital["sy"]
        for dx, dy in ((0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)):
            self.assertEqual(self.pen_at(x + dx, y + dy), 3, f"no cross at {(dx, dy)} for the destroyer")
        for dx, dy in ((-2, -2), (2, 2), (-2, 2), (2, -2)):
            self.assertEqual(self.pen_at(x + dx, y + dy), 0, "the destroyer is more than a cross")
        #  ...and the nearest three ARE sprites: many red pixels about them.
        for v in enemies[:3]:
            reds = sum(1 for dx in range(-8, 9) for dy in range(-6, 7)
                       if 0 <= v["sx"] + dx < 320 and self.pen_at(v["sx"] + dx, v["sy"] + dy) == 3)
            self.assertGreater(reds, 6, f"the hostile at depth {v['z']} is not a sprite")   # a dot is 2, a cross 5


if __name__ == "__main__":
    unittest.main()
