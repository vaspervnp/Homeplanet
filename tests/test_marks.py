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
    """While a ship is flown, ONE enemy is drawn -- the one in the reticle,
    else the nearest -- always as a sprite, and nothing else at all: not
    the other hostiles, not the friendlies. The box is the lock's."""

    def fly_with_two_ahead(self):
        """The flown ship at the origin heading +Z (yaw 128), one hostile
        dead ahead inside the box and one off to the side, both close enough
        to be tier C on their depth alone. The one ahead is the nearer, so
        it is the one chosen; the one aside is not drawn at all."""
        self.clear_everything()
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.place(1, (0, 0, -30000), cls=1)                       # the base, far away
        self.poke(1, ENT_SQUAD, b"\x00")                           # ...and in no squadron, or the box spans it
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
        enemies = [v for v in vis if v["enemy"]]
        self.assertEqual(len(enemies), 1, f"expected the one chosen hostile, saw {vis}")
        self.assertLessEqual(abs(enemies[0]["sx"] - 160), self.sym["PILOT_BOX_HW"], "the chosen hostile is not the one ahead")
        return enemies[0]

    def test_the_chosen_enemy_is_a_sprite_and_the_other_is_not_drawn(self):
        ahead = self.fly_with_two_ahead()
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_TARGET"], 1)[0], self.PLAYER_MAX, "the nearer hostile was not the one chosen")
        self.assertNotEqual(ahead["tier"], self.MARK, "the chosen enemy was drawn as a mark")
        #  ...and outside the box it is STILL a sprite: the box is the lock's.
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 3200, my, mz + 6400))
        self.poke(self.PLAYER_MAX + 1, 0, struct.pack("<hhh", mx - 3200, my, mz + 6400))
        self.settle()
        enemies = [v for v in self.visible() if v["enemy"]]
        self.assertEqual(len(enemies), 1, f"expected the one chosen hostile, saw {enemies}")
        self.assertGreater(abs(enemies[0]["sx"] - 160), self.sym["PILOT_BOX_HW"], "the fixture did not move it out of the box")
        self.assertNotEqual(enemies[0]["tier"], self.MARK, "the chosen enemy outside the box was drawn as a mark")

    def test_a_friendly_in_the_box_is_not_drawn_from_the_cockpit(self):
        """"Θα αγνοεί τα φιλικά σκάφη, δεν θα τα εμφανίζει": a squadron mate
        dead ahead, inside the reticle, at a depth that would be a sprite."""
        self.fly_with_two_ahead()
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        self.place(2, (mx + 600, my, mz + 6400))
        self.settle()
        vis = self.visible()
        self.assertEqual([v for v in vis if not v["enemy"]], [], f"a friendly is drawn from the cockpit: {vis}")
        self.assertEqual(len([v for v in vis if v["enemy"]]), 1)

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
        #  The hostiles off to the sides, still flying: a sprite over a tick
        #  reads as the sprite's ink, and how far the ship has flown decides
        #  its size; but taking them away ends the fight, and the fight
        #  ending hands the ship back, reticle and all.
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 6000, my, mz + 6000))
        self.poke(self.PLAYER_MAX + 1, 0, struct.pack("<hhh", mx - 6000, my, mz + 6000))
        self.settle()
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


    def ticks(self):
        gap = self.sym["PILOT_RET_GAP"]
        cy = self.sym["PROJ_CENTRE_Y"]
        return [(160 - gap - 1, cy), (160 + gap + 1, cy), (160, cy - gap - 1), (160, cy + gap + 1)]

    def test_the_reticle_is_red_with_a_hostile_in_it_and_white_without(self):
        """The ticks are the alarm ink on a frame a FLYING hostile projects
        inside the box, and the fleet's ink otherwise -- a wreck in the box
        is not a lock. The hostile sits off the centre line so its own
        sprite is clear of the ticks and the pixels read are the ticks'."""
        self.fly_with_two_ahead()
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 1200, my, mz + 6400))   # in the box, right of centre
        self.poke(self.PLAYER_MAX + 1, 0, struct.pack("<hhh", mx - 6000, my, mz + 6000))  # off the screen
        self.settle()
        inside = [v for v in self.visible() if v["enemy"] and abs(v["sx"] - 160) <= self.sym["PILOT_BOX_HW"]]
        self.assertEqual(len(inside), 1, "the fixture did not put the hostile in the box")
        self.assertGreater(inside[0]["sx"] - 8, 160 + self.sym["PILOT_RET_GAP"] + 1, "the sprite lies over the ticks")
        for x, y in self.ticks():
            self.assertEqual(self.pen_at(x, y), 3, f"the tick at {(x, y)} is not red with a hostile in the box")
        #  The same hull, crippled: still in the box, still a sprite, no lock.
        self.poke(self.PLAYER_MAX, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | 4]))
        self.settle()
        for x, y in self.ticks():
            self.assertEqual(self.pen_at(x, y), 1, f"a wreck in the box locked the tick at {(x, y)}")
        #  ...and flying again but outside the box: white.
        self.poke(self.PLAYER_MAX, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 6000, my, mz + 6000))
        self.settle()
        for x, y in self.ticks():
            self.assertEqual(self.pen_at(x, y), 1, f"the tick at {(x, y)} stayed red with the box empty")


class TestTheBolt(MarkFixture):
    """The flown ship's own shot flies: from the reticle to the target over
    SHOT_BOLT_STEPS frames, aimed at where the target is each frame."""

    PEN1 = {0x80: 0, 0x40: 1, 0x20: 2, 0x10: 3}

    def dots_on(self, name):
        raw = h.read_cpu(self.c, self.sym[name], self.sym["SHOT_LIST_SIZE"])   # bank 4, at rest here
        out = []
        for i in range(raw[0]):
            addr = raw[1 + i * 3] | (raw[2 + i * 3] << 8)
            mask = raw[3 + i * 3]
            off = addr & 0x3FFF
            #  Screen offset -> (y, byte column): 0x800 a scanline within a
            #  character row, 80 a character row. A bolt's dot is the whole
            #  byte, #F0, and reads as its left pixel.
            y = (off // 0x800) + 8 * ((off % 0x800) // 80)
            xb = (off % 0x800) % 80
            out.append((xb * 4 + self.PEN1.get(mask, 0), y, mask))
        return out

    def test_the_pilots_shot_flies_from_the_reticle_to_the_enemy(self):
        self.clear_everything()
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.place(1, (0, 0, -30000), cls=1)
        self.poke(1, ENT_SQUAD, b"\x00")
        self.place(0, (0, 0, 0))
        self.poke(0, 6, bytes([128]))                              # +Z
        self.poke(0, ENT_TIMER, b"\x00")                           # place() leaves a gun cold for 255 frames
        self.place(self.ENT_MAX - 1, (0, 30000, 0), enemy=True)       # 30000 up: past PROJ_V_LIMIT, never listed   # a fight on, or V is refused
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
        #  One hostile ahead and to the right, inside gun range (a Manhattan
        #  2400 against CBT_RANGE's 2560) and inside the box, its own gun
        #  cold, so the only dots on the screen are ours.
        me = self.byte("PILOT_SLOT")
        mx, my, mz = struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + me * ENT_SIZE, 6))
        enemy = self.PLAYER_MAX
        self.place(enemy, (mx + 600, my, mz + 1800), enemy=True)
        self.settle()
        seen = [v for v in self.visible() if v["enemy"]]
        self.assertEqual(len(seen), 1, f"the hostile is not on the screen: {seen}")
        self.assertGreater(seen[0]["sx"], 170, "the fixture wants the hostile clear of the centre")
        #  Fire, and watch the dot lists frame by frame at the stable point,
        #  where the buffer just drawn is the back page and bank 4 is in.
        #  SPACE is tapped, a frame down and a frame up: the trigger is an
        #  edge, and the pause parked the timer at one, so the first frame's
        #  edge is spent before the gun is ready.
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        frames = []
        for i in range(12):
            if i % 2 == 0:
                self.c.key_down(cpc.KEY_SPACE)
            else:
                self.c.key_up(cpc.KEY_SPACE)
            h.run_to_stable_point(self.c, self.sym)
            back = self.c.read_ram(self.sym["SCR_BACK_PAGE"], 1)[0]
            name = "SHOT_DOTS_A" if back == self.sym["SCREEN_A"] >> 8 else "SHOT_DOTS_B"
            #  Where the bolt aims: shot_pos, the projection cache, which is
            #  stamped before mark_tier_for decides whether to LIST the ship.
            raw = h.read_cpu(self.c, self.sym["SHOT_POS"] + enemy * self.sym["SHOT_POS_SIZE"], 4)
            frames.append((self.byte("DEMO_FRAMES"), self.dots_on(name), (raw[0] | (raw[1] << 8), raw[2])))
            self.c.run_frames(1)
        self.c.key_up(cpc.KEY_SPACE)
        self.assertLess(self.c.read_ram(self.sym["ENTITIES"] + enemy * ENT_SIZE + ENT_HULL, 1)[0], 255,
                        "the shot never landed")
        bolt = [(f, dots, ex) for f, dots, ex in frames if dots]
        self.assertGreaterEqual(len(bolt), 2, f"the bolt was not seen in flight: {frames}")
        #  From the muzzle at the bottom centre of the view to the enemy: every
        #  dot within two pixels of that line, and further along it each frame.
        mx, my = 160, self.sym["SHOT_MUZZLE_Y"]
        last = -1
        for f, dots, (ex, ey) in bolt[:self.sym["SHOT_BOLT_STEPS"] - 1]:
            #  Two dots, each a byte wide and two lines tall: four entries.
            self.assertEqual(len(dots), 4, f"frame {f}: a bolt is two byte-wide, two-line dots, saw {dots}")
            vx, vy = ex - mx, ey - my
            length = (vx * vx + vy * vy) ** 0.5
            for x, y, mask in dots:
                self.assertEqual(mask, 0xF0, f"frame {f}: the bolt is not a byte of the fleet's ink")
                t = ((x - mx) * vx + (y - my) * vy) / (length * length)
                off = abs((x - mx) * vy - (y - my) * vx) / length
                self.assertTrue(-0.05 <= t <= 1.05, f"frame {f}: dot {(x, y)} is not between the muzzle and the enemy at {(ex, ey)}")
                self.assertLessEqual(off, 5, f"frame {f}: dot {(x, y)} is off the line to {(ex, ey)}")
            along = min(((x - mx) * vx + (y - my) * vy) / (length * length) for x, y, m in dots)
            self.assertGreater(along, last, f"frame {f}: the bolt did not move on ({along} after {last})")
            last = along


class TestTheLock(MarkFixture):
    """future.md item 8: with a flying hostile in the reticle, the gun aims at
    it and the ship matches its motion -- moves by what it moved -- while it
    is inside PILOT_HOLD_DIST; out of the box, dead, or further off, the ship
    flies forward on its own. Driven a frame at a time through a stub that
    runs pilot_frame, order_focus, cam_build_matrix and phase4_project and
    NOTHING else, so no enemy closes, shoots or re-targets under the test."""

    def stage(self, hostile_at):
        self.clear_everything()
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.place(1, (0, 0, -30000), cls=1)
        self.poke(1, ENT_SQUAD, b"\x00")
        self.place(0, (0, 0, 0))
        self.poke(0, 6, bytes([128]))                              # +Z
        self.poke(0, ENT_ORDER, bytes([self.sym["ENT_ORDER_PILOT"]]))
        self.ENEMY = self.PLAYER_MAX
        self.place(self.ENEMY, hostile_at, enemy=True)
        #  ...and one more, far off and never in the box, so that crippling
        #  the first does not END THE FIGHT and hand the ship back.
        self.place(self.PLAYER_MAX + 1, (20000, 0, -20000), enemy=True)
        self.c.write_ram(self.sym["PILOT_SLOT"], bytes([0]))
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        h.write_bank4(self.c, self.sym["AUTO_ARMED"], b"\x00")
        h.write_bank4(self.c, self.sym["PILOT_LOCKED"], b"\x00")
        h.write_bank4(self.c, self.sym["PILOT_PREV_SLOT"], b"\xff")
        h.write_bank4(self.c, self.sym["PILOT_FOUGHT"], b"\x00")

    def frame(self):
        calls = b"".join(bytes([0xCD, self.sym[n] & 0xFF, self.sym[n] >> 8])
                         for n in ("PILOT_FRAME", "ORDER_FOCUS", "CAM_BUILD_MATRIX", "PHASE4_PROJECT"))
        stub = bytes([0x01, self.sym["GA_BANK_4"], 0x7F, 0xED, 0x49]) + calls + bytes([0x18, 0xFE])
        self.c.write_ram(h.STUB, stub)
        self.c.set_pc(h.STUB)
        self.c.run_frames(2)

    def me(self):
        return struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"], 6))

    def enemy(self):
        return struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + self.ENEMY * ENT_SIZE, 6))

    def move_enemy(self, dx, dy, dz):
        x, y, z = self.enemy()
        self.poke(self.ENEMY, 0, struct.pack("<hhh", x + dx, y + dy, z + dz))

    def step(self):
        """A frame of own flight: 2 * ((127 * PILOT_STEP_HALF) >> 7), which
        is 198 and not 200, because cam_mul7 floors."""
        return 2 * ((127 * self.sym["PILOT_STEP_HALF"]) >> 7)

    def settle(self):
        """Frames until the ship stops moving: the lock taken, the target
        closed on to PILOT_HOLD_DIST, the first matched frame held."""
        for _ in range(12):
            was = self.me()
            self.frame()
            if self.me() == was:
                return
        self.fail(f"the ship never held: {self.me()} against {self.enemy()}")

    def test_the_gun_aims_at_the_ship_in_the_reticle(self):
        """2000 ahead: after the first frame's flight it is 1800 off, fourteen
        camera units past the nose and inside the box."""
        self.stage((0, 0, 2000))
        self.frame()                                               # projects: the lock is taken
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_LOCKED"], 1)[0], 2, "no lock with a hostile dead ahead")
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_TARGET"], 1)[0], self.ENEMY)
        self.frame()                                               # pilot_frame spends it
        self.assertEqual(self.c.read_ram(self.sym["ENTITIES"] + ENT_TARGET, 1)[0], self.ENEMY,
                         "the flown ship is not aiming at the locked hostile")

    def test_a_held_target_holds_the_ship_and_a_moving_one_carries_it(self):
        self.stage((0, 0, 2000))
        self.settle()
        gap0 = self.enemy()[2] - self.me()[2]
        self.assertLess(gap0, self.sym["PILOT_HOLD_DIST"] << 6, "held outside the hold distance")
        before = self.me()
        self.frame()
        self.assertEqual(self.me(), before, "the ship flew on with a target held in the reticle")
        for step in ((100, 0, 60), (-40, 30, 90), (0, 0, 120)):
            was = self.me()
            self.move_enemy(*step)
            self.frame()
            now = self.me()
            self.assertEqual(tuple(n - w for n, w in zip(now, was)), step,
                             f"the ship did not match the target's step {step}")
        #  ...and the gap is what it was when the hold began: matched, not chased.
        ex, ey, ez = self.enemy()
        mx, my, mz = self.me()
        self.assertEqual((ex - mx, ey - my, ez - mz), (0, 0, gap0))

    def test_a_target_out_of_the_box_or_dead_frees_the_ship(self):
        self.stage((0, 0, 2000))
        self.settle()
        #  Off to the side, out of the box: own flight along +Z again.
        self.move_enemy(3000, 0, 0)
        self.frame()                                               # projects: no lock
        was = self.me()
        self.frame()
        self.assertEqual(self.me()[2] - was[2], self.step(), "the ship did not fly on with the box empty")
        #  Back where it was, and crippled: a wreck in the box does not lock.
        self.move_enemy(-3000, 0, 2 * self.step())
        self.poke(self.ENEMY, ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY | 4]))
        self.frame()
        was = self.me()
        self.frame()
        self.assertEqual(self.me()[2] - was[2], self.step(), "a wreck in the reticle held the ship")

    def test_a_far_target_is_closed_on_before_it_is_matched(self):
        """4000 ahead is past PILOT_HOLD_DIST: locked and aimed at, and still
        flown at until it is near enough to hold."""
        self.stage((0, 0, 4000))
        self.frame()
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_LOCKED"], 1)[0], 2)
        was = self.me()
        self.frame()
        self.assertEqual(self.me()[2] - was[2], self.step(), "a far target stopped the ship")
        self.settle()
        hold = self.sym["PILOT_HOLD_DIST"] << 6
        gap = self.enemy()[2] - self.me()[2]
        self.assertLess(gap, hold, f"the ship held at {gap}, outside PILOT_HOLD_DIST")
        self.assertGreater(gap, hold - 2 * self.step(), f"the ship held at {gap}, well inside the hold distance")


class TestTheScanner(TestTheReticleBox):
    """The Elite-style scanner at the bottom right, while flying: an OVAL --
    the plane seen flat -- with the ship in the middle, every flying hostile
    a red mark placed by where it is relative to the ship's heading (up the
    oval is ahead, right is right) and a STALK from its point on the plane to
    its height above or below the ship, with a bar across the tip.

    Back, from BANK 7 (game/scanner.asm) through bankn_call, after the V
    redesign had put it out for room: the cockpit draws one enemy and an
    arrow towards it, and this is where all of them are. Every claim here
    is about pixels, so which bank draws them is not its business."""

    def oval(self):
        s = self.sym
        return s["SCAN_CX"], s["SCAN_CY"], s["SCAN_RX"], s["SCAN_RY"]

    def half_height(self, i):
        """scan_oval's entry, re-derived: round(RY * sqrt(1 - (i/RX)^2))."""
        import math
        _, _, rx, ry = self.oval()
        return int(round(ry * math.sqrt(max(0.0, 1 - (i / rx) ** 2))))

    def test_the_table_is_the_ellipse(self):
        rx = self.sym["SCAN_RX"]
        with open("build/bank7.raw", "rb") as f:
            image = f.read()
        off = self.sym["SCAN_OVAL"] - 0x4000
        table = image[off:off + rx + 1]
        self.assertEqual(list(table), [self.half_height(i) for i in range(rx + 1)])

    def test_the_oval_and_the_ship_are_drawn_while_flying(self):
        self.fly_with_two_ahead()
        cx, cy, rx, ry = self.oval()
        self.assertEqual(self.pen_at(cx, cy), 1, "no ship in the middle of the scanner")
        #  The four extremes of the oval, and a point on its curve either
        #  side, in the chrome ink; the inside black.
        for x, y in ((cx - rx, cy), (cx + rx, cy), (cx, cy - ry), (cx, cy + ry),
                     (cx + 20, cy - self.half_height(20)), (cx - 30, cy + self.half_height(30))):
            self.assertEqual(self.pen_at(x, y), 2, f"no oval at {(x, y)}")
        self.assertEqual(self.pen_at(cx + 10, cy - 5), 0, "the oval is not hollow")
        #  ...and it has no gaps on its steep sides: every row between the
        #  top and the middle has ink somewhere in the right-hand half.
        for y in range(cy - ry, cy + 1):
            self.assertTrue(any(self.pen_at(x, y) == 2 for x in range(cx, cx + rx + 1)),
                            f"row {y} of the oval's right side is empty")

    def mark_for(self, slot):
        """Where the scanner should put `slot`, modelled from the records:
        the deltas' high bytes shifted SCAN_SHIFT, rotated by the flown
        ship's yaw with sin7 and cam_mul7's arithmetic, `ahead` halved and
        kept inside the oval at that column, the height clamped to
        SCAN_HALF_V. Returns (plane point, tip). Modelled rather than
        written down because the flown ship FLIES during the frames V takes,
        so no fixed distance survives."""
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

        def clamp(v, lim):
            return max(-lim, min(lim, v))

        dx, dy, dz = hi(them[0] - me[0]), hi(them[1] - me[1]), hi(them[2] - me[2])
        sn, cs = sin7(yaw), sin7(yaw + 64)
        right = clamp(mul7(dz, sn) - mul7(dx, cs), self.sym["SCAN_HALF_W"])
        ahead = clamp((mul7(dx, sn) - mul7(dz, cs)) >> 1, self.half_height(abs(right)) - 1)
        dy = clamp(dy, self.sym["SCAN_HALF_V"])
        cx, cy, *_ = self.oval()
        return (cx + right, cy - ahead), (cx + right, cy - ahead - dy)

    def pos(self, slot):
        return struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE, 6))

    def field(self, slot, off):
        return self.c.read_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + off, 1)[0]

    def assert_mark(self, plane, tip):
        (px, py), (tx, ty) = plane, tip
        self.assertEqual(px, tx)
        for y in range(min(py, ty), max(py, ty) + 1):
            self.assertEqual(self.pen_at(px, y), 3, f"no stalk at {(px, y)} between {plane} and {tip}")
        self.assertEqual(self.pen_at(tx - 1, ty), 3, f"no bar left of the tip {tip}")
        self.assertEqual(self.pen_at(tx + 1, ty), 3, f"no bar right of the tip {tip}")

    def test_a_hostile_ahead_is_a_mark_above_the_ship_and_one_to_the_right_is_right_of_it(self):
        """The ship heads +Z, so ahead is up and +X is right -- and the
        model above says exactly which pixels, from where the ships ARE.
        Both level with the ship: a dash on the plane, no stalk. The fixture
        places its hostiles at y 0 and the flown ship is not there, so they
        are brought to its height first -- 150 units below is a pixel of
        stalk, because the shift floors."""
        self.fly_with_two_ahead()
        my = self.pos(self.byte("PILOT_SLOT"))[1]
        for slot in (self.PLAYER_MAX, self.PLAYER_MAX + 1):
            x, _, z = self.pos(slot)
            self.poke(slot, 0, struct.pack("<hhh", x, my, z))
        self.settle()
        cx, cy, *_ = self.oval()
        (ax, ay), atip = self.mark_for(self.PLAYER_MAX)
        (rx, ry), rtip = self.mark_for(self.PLAYER_MAX + 1)
        self.assertEqual(ax, cx, "the hostile dead ahead is not in the ship's column")
        self.assertLess(ay, cy, "the hostile dead ahead is not above the ship")
        self.assertGreater(rx, cx, "the hostile to the right is not right of it")
        self.assertEqual(atip, (ax, ay), "level with the ship, yet a stalk")
        self.assert_mark((ax, ay), atip)
        self.assert_mark((rx, ry), rtip)
        #  ...and nothing where a hostile is not: mirrored below, and left.
        self.assertEqual(self.pen_at(ax, 2 * cy - ay), 0)
        self.assertEqual(self.pen_at(2 * cx - rx, ry), 0)

    def test_it_turns_with_the_ship(self):
        """The same two hostiles with the ship heading +X (yaw 64): the one at
        +Z is now off the LEFT hand, the one at +X,+Z ahead-and-left."""
        self.fly_with_two_ahead()
        self.poke(0, 6, bytes([64]))                              # ENT_YAW: +X
        self.settle()
        cx, cy, *_ = self.oval()
        #  sin 64 is 127 and cos 64 is 0, so ahead = dx and right = dz: the
        #  ship's right hand is (-cos, sin) = (0, 1) = +Z. The hostile at +Z
        #  is now dead to the right; the one at +X,+Z ahead of that.
        (ax, ay), atip = self.mark_for(self.PLAYER_MAX)
        (rx, ry), rtip = self.mark_for(self.PLAYER_MAX + 1)
        self.assertGreater(ax, cx)
        self.assertEqual(ay, cy, "the +Z hostile is not dead on the right hand")
        self.assertLess(ry, cy, "the +X,+Z hostile is not ahead of it")
        self.assert_mark((ax, ay), atip)
        self.assert_mark((rx, ry), rtip)

    def test_the_height_is_a_stalk_up_for_above_and_down_for_below(self):
        """+Y is up: pilot_frame's UP adds to ENT_Y and proj_point's sy is the
        centre minus it. A hostile 5000 units above the ship gets a stalk
        rising from its plane point; one 5000 below, a stalk falling."""
        self.fly_with_two_ahead()
        me = self.byte("PILOT_SLOT")
        mx, my, mz = self.pos(me)
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 2000, my + 5000, mz + 8000))
        self.poke(self.PLAYER_MAX + 1, 0, struct.pack("<hhh", mx - 2000, my - 5000, mz + 8000))
        self.settle()
        (ux, uy), (utx, uty) = self.mark_for(self.PLAYER_MAX)
        (dx_, dy_), (dtx, dty) = self.mark_for(self.PLAYER_MAX + 1)
        #  The shifts FLOOR, so 5000 up is 9 pixels and 5000 down is 10.
        up = (5000 >> 8) >> self.sym["SCAN_SHIFT"]
        down = -((-5000 >> 8) >> self.sym["SCAN_SHIFT"])
        self.assertGreaterEqual(up, 3, "the fixture's height is too small to show")
        self.assertEqual(uty, uy - up, f"5000 units up is not a stalk of {up} pixels")
        self.assertEqual(dty, dy_ + down, f"5000 units down is not a stalk of {down} pixels")
        self.assert_mark((ux, uy), (utx, uty))
        self.assert_mark((dx_, dy_), (dtx, dty))
        #  ...and the plane point is where the stalk meets the plane, not
        #  the tip: the column above the tip is clear, and below the foot.
        self.assertEqual(self.pen_at(ux, uty - 1), 0)
        self.assertEqual(self.pen_at(ux, uy + 1), 0)

    def test_a_mark_stays_inside_the_oval(self):
        """A hostile far ahead and far to the right would land in the
        rectangle's corner; the mark is held to the oval's edge at its
        column instead."""
        self.fly_with_two_ahead()
        me = self.byte("PILOT_SLOT")
        mx, my, mz = self.pos(me)
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 30000, my, mz + 30000))
        self.poke(self.PLAYER_MAX + 1, 0, struct.pack("<hhh", mx - 30000, my, mz + 30000))
        self.settle()
        cx, cy, rx, ry = self.oval()
        for slot in (self.PLAYER_MAX, self.PLAYER_MAX + 1):
            (px, py), tip = self.mark_for(slot)
            self.assertEqual(abs(px - cx), self.sym["SCAN_HALF_W"])
            self.assertLess(cy - py, self.half_height(abs(px - cx)), "the mark is outside the oval")
            self.assert_mark((px, py), tip)

    def test_nothing_of_it_when_nobody_is_flying(self):
        self.fly_with_two_ahead()
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()
        cx, cy, rx, ry = self.oval()
        for x, y in ((cx, cy), (cx - rx, cy), (cx, cy - ry)):
            self.assertEqual(self.pen_at(x, y), 0, f"the scanner stayed at {(x, y)}")


class TestTheScaledSprites(MarkFixture):
    """From the cockpit the nearest ships are drawn larger than tier C --
    x2 under PILOT_X2_RAW camera units ahead, x4 under PILOT_X4_RAW -- by
    pixel replication in gfx/sprscale.asm, and only PILOT_SPRITES ships are
    drawn as sprites at all; the rest are the sensor view's marks."""

    def on_a_tick(self, x, y):
        """Is (x, y) one of the reticle's four ticks? They are drawn AFTER the
        ships, in the fleet's or the alarm ink, so a sprite pixel under one
        reads as the tick. Which pixels of a sprite that is depends on where
        the flown ship's flight put it, which the frame rate decides."""
        gap, ln = self.sym["PILOT_RET_GAP"], self.sym["PILOT_RET_LEN"]
        cx, cy = 160, self.sym["PROJ_CENTRE_Y"]
        half = ln // 2
        if y in range(cy - half, cy - half + ln) and x in (cx - gap - 1, cx + gap + 1):
            return True
        if x == cx and (y in range(cy - gap - ln, cy - gap) or y in range(cy + gap + 1, cy + gap + 1 + ln)):
            return True
        return False

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
        #  V is refused on a quiet board: one live hostile, far off and never
        #  projected, keeps the fight on -- and stays through the clear below,
        #  or the wrecks alone would end the fight and hand the ship back.
        self.place(self.ENT_MAX - 1, (0, 30000, 0), enemy=True)       # 30000 up: past PROJ_V_LIMIT, never listed
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
        for slot in range(self.PLAYER_MAX, self.ENT_MAX - 1):
            self.poke(slot, ENT_FLAGS, b"\x00")
        #  FLYING, and cold: a wreck is never the enemy the cockpit chooses.
        #  place() leaves the gun at 255 frames' cooldown; a hostile with
        #  no target yet closes on nobody, and the two frames leave every
        #  distance inside its band either way.
        for i, (x, d, cls) in enumerate(hostiles):
            px = int(round(mx + ahead[0] * d + right[0] * x))
            pz = int(round(mz + ahead[1] * d + right[1] * x))
            self.place(self.PLAYER_MAX + i, (px, my, pz), enemy=True, cls=cls)
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

    def test_past_the_bands_the_enemy_is_tier_c_unscaled(self):
        """A camera unit is 128 world units at the default zoom, and the
        ship flies 400 in the two frames: 5400 is 42 down to 39 camera
        units, past PILOT_X2_RAW (32), so tier C on its depth and unscaled.
        The three pixel-exact tests below are the x4, x3 and x2 bands."""
        vis = self.fly_at([(0, 5400, 0)])
        enemies = [v for v in vis if v["enemy"]]
        self.assertEqual(len(enemies), 1, vis)
        self.assertEqual((enemies[0]["scale"], enemies[0]["tier"]), (0, 2), enemies)

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
            if self.on_a_tick(x, y):
                continue                      # the reticle is drawn over the ships
            got = self.pen_at(x, y)
            expect = 3 if pen == 1 else pen
            if got != expect:
                wrong.append(((x, y), got, expect))
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {len(want)} pixels differ")

    def test_a_x3_hostile_is_the_block_tripled(self):
        """x3 is the shape with no shift in it: output byte k of a source
        byte is pixels (k, k+1) as AAAB, AABB, ABBB. Pixel for pixel."""
        vis = self.fly_at([(0, 3100, 0)])
        e = [v for v in vis if v["enemy"]][0]
        self.assertEqual(e["scale"], 3)
        want = self.expected_pixels(0, e["view"], 3)
        wrong = [((e["sx"] + dx, e["sy"] + dy), self.pen_at(e["sx"] + dx, e["sy"] + dy), 3 if pen == 1 else pen)
                 for (dx, dy), pen in want.items()
                 if 0 <= e["sx"] + dx < 320 and self.sym["CTX_BAR_H"] <= e["sy"] + dy < self.sym["HUD_TOP"]
                 and self.pen_at(e["sx"] + dx, e["sy"] + dy) != (3 if pen == 1 else pen)]
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {len(want)} pixels differ")

    def test_a_x2_hostile_is_the_block_doubled(self):
        vis = self.fly_at([(0, 4000, 0)])
        e = [v for v in vis if v["enemy"]][0]
        self.assertEqual(e["scale"], 1)
        want = self.expected_pixels(0, e["view"], 2)
        wrong = [((e["sx"] + dx, e["sy"] + dy), self.pen_at(e["sx"] + dx, e["sy"] + dy), 3 if pen == 1 else pen)
                 for (dx, dy), pen in want.items()
                 if 0 <= e["sx"] + dx < 320 and self.sym["CTX_BAR_H"] <= e["sy"] + dy < self.sym["HUD_TOP"]
                 and self.pen_at(e["sx"] + dx, e["sy"] + dy) != (3 if pen == 1 else pen)]
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {len(want)} pixels differ")

    def test_of_five_hostiles_only_the_nearest_is_drawn_and_it_is_a_sprite(self):
        """Five hostiles ahead, all inside the radius and the box: the
        nearest is the one chosen and the one drawn; the other four are
        not in the list at all -- not marks, nothing."""
        vis = self.fly_at([(0, 5400, 0), (2000, 6000, 0), (-2000, 6500, 0), (900, 7000, 0), (-900, 8000, 7)])
        enemies = [v for v in vis if v["enemy"]]
        self.assertEqual(len(enemies), 1, f"expected the one chosen hostile, saw {vis}")
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_TARGET"], 1)[0], self.PLAYER_MAX, "the nearest was not the one chosen")
        v = enemies[0]
        self.assertNotEqual(v["tier"], self.MARK)
        #  A sprite: many pixels about it, red OR blue -- an enemy sprite is
        #  red with blue shading; a mark is red only, a dot 2 and a cross 5.
        inked = sum(1 for dx in range(-8, 9) for dy in range(-6, 7)
                    if 0 <= v["sx"] + dx < 320 and self.pen_at(v["sx"] + dx, v["sy"] + dy) in (2, 3))
        self.assertGreater(inked, 6, f"the chosen hostile at depth {v['z']} is not a sprite")


class TestTheZoomLadderScales(MarkFixture):
    """"στο Zoom in βάλε και τα 3 επίπεδα με τα resized sprites": at the
    innermost zoom steps the nearest three ships are drawn x2, x3 and x4 by
    the step, and the rest of the squadron at tier C."""

    def zoom_to(self, step):
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        for _ in range(12):
            cur = self.byte("CAM_ZOOM")
            if cur == step:
                break
            self.c.key_down("z" if cur > step else "x")
            self.c.run_frames(20)
            self.c.key_up("z" if cur > step else "x")
            self.c.run_frames(20)
        self.assertEqual(self.byte("CAM_ZOOM"), step)
        self.settle()
        return self.visible()

    def test_the_default_step_scales_nothing(self):
        vis = self.zoom_to(self.sym["CAM_ZOOM_DEFAULT"])
        self.assertTrue(vis)
        self.assertEqual({v["scale"] for v in vis}, {0})

    FACTOR = {0: 1, 1: 2, 3: 3, 2: 4}

    def box_of(self, v, factor):
        """The screen box an entry drew into at `factor`."""
        hw, hh = {2: (12, 8), 1: (8, 5), 0: (4, 3), 3: (1, 1)}[v["tier"]]
        return (v["sx"] - hw * factor - 4, v["sx"] + hw * factor + 4, v["sy"] - hh * factor, v["sy"] + hh * factor)

    def draw_order(self, vis):
        """The visible-list indices in the order they were drawn -- back to
        front, phase4_order's -- so "the nearest three" is what the game
        meant by it, ties in depth and all."""
        n = len(vis)
        raw = self.c.read_ram(self.sym["PHASE4_ORDER"], n * 2)
        return [raw[i * 2] for i in range(n)]

    def drawn_factor(self, vis, v):
        """What mark_or_blit let an entry draw at: its listed scale if it
        was among the PILOT_SPRITES drawn last, and tier C otherwise."""
        if not v["scale"]:
            return 1
        order = self.draw_order(vis)
        last = order[-self.sym["PILOT_SPRITES"]:]
        return self.FACTOR[v["scale"]] if vis.index(v) in last else 1

    def check_drawn(self, vis, e, factor, min_checked=20, on_top=False):
        """e's pixels against its block at `factor`, skipping every pixel
        inside another entry's drawn box -- the fleet is a lattice and
        ships at one depth may be drawn in either order. A scaled blit is
        byte-aligned and a tier C one two-pixel-aligned, so the block sits
        up to three pixels left of the true centre, as the blitter puts it."""
        #  Drawn last, nothing lies over it: every pixel of it is checked.
        others = [] if on_top else [self.box_of(v, self.drawn_factor(vis, v)) for v in vis if v is not e]
        want = TestTheScaledSprites.expected_pixels(self, e["cls"], e["view"], factor)
        left = e["sx"] - 12 * factor
        shift = left % (4 if factor > 1 else 2)
        wrong, checked = [], 0
        for (dx, dy), pen in want.items():
            x, y = e["sx"] + dx - shift, e["sy"] + dy
            if not (0 <= x < 320 and self.sym["CTX_BAR_H"] <= y < self.sym["HUD_TOP"]):
                continue
            if any(x0 <= x < x1 and y0 <= y < y1 for x0, x1, y0, y1 in others):
                continue
            checked += 1
            if self.pen_at(x, y) != pen:
                wrong.append(((x, y), self.pen_at(x, y), pen))
        self.assertGreater(checked, min_checked - 1, "every pixel of it lies under another ship")
        self.assertEqual(wrong[:8], [], f"{len(wrong)} of {checked} pixels differ at x{factor}")

    def spread_five(self):
        """Five ships of the squadron in a line across the station, 800
        units apart and staggered in depth, the rest sent out of sight: a
        lattice at step 3 is too tight to see any one ship clear of the
        others, and this asks about individual ships."""
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        base = self.sym["ENTITIES"]
        sel = self.byte("SQUAD_SEL")
        ships = [s for s in range(self.PLAYER_MAX)
                 if self.c.read_ram(base + s * ENT_SIZE + ENT_FLAGS, 1)[0] & 1
                 and self.c.read_ram(base + s * ENT_SIZE + ENT_SQUAD, 1)[0] == sel]
        sx, sy, sz = struct.unpack("<hhh", self.c.read_ram(self.sym["SQUAD_DEST"] + (sel - 1) * 6, 6))
        for i, s in enumerate(ships):
            if i < 5:
                self.poke(s, 0, struct.pack("<hhh", sx + (i - 2) * 800, sy, sz + (i - 2) * 300))
            else:
                #  Out of the squadron as well as out of sight: the camera
                #  centres on the box round the squadron's ships now.
                self.poke(s, 0, struct.pack("<hhh", sx, sy + 20000, sz))
                self.poke(s, ENT_SQUAD, b"\x09")

    def test_three_steps_in_every_tier_c_entry_is_listed_x2_and_only_the_nearest_are_drawn_so(self):
        self.spread_five()
        vis = self.zoom_to(3)
        c_entries = [v for v in vis if v["tier"] == 2]
        self.assertTrue(c_entries)
        self.assertEqual({v["scale"] for v in c_entries}, {1}, "step 3 lists tier C as x2")
        order = self.draw_order(vis)
        #  The one drawn last is x2, and on top of everything...
        self.check_drawn(vis, vis[order[-1]], 2, on_top=True)
        #  ...and the one drawn first, past the nearest three, at tier C.
        self.assertGreater(len(c_entries), self.sym["PILOT_SPRITES"])
        self.check_drawn(vis, vis[order[0]], 1)

    def test_step_two_is_x3_and_step_one_x4(self):
        vis = self.zoom_to(2)
        self.assertEqual({v["scale"] for v in vis if v["scale"]}, {3})
        vis = self.zoom_to(1)
        self.assertEqual({v["scale"] for v in vis if v["scale"]}, {2})

    def test_a_x4_ship_of_ours_is_the_block_quadrupled_in_white(self):
        vis = self.zoom_to(0)
        e = vis[self.draw_order(vis)[-1]]                  # drawn last: on top, and among the three
        self.assertEqual(e["scale"], 2)
        self.check_drawn(vis, e, 4, on_top=True)



class CockpitFixture(MarkFixture):
    """A flown ship at the origin, heading +Z, the battle paused, with a
    hostile far up keeping the fight on and nothing else on the screen."""

    def fly(self):
        """The flown ship at the origin heading +Z (yaw 128): +X is its
        right, +Y is up. A hostile thirty thousand up keeps the fight on
        without ever being listed; the base far behind. Returns where the
        ship is after V, paused."""
        self.clear_everything()
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([1]))
        self.place(1, (0, 0, -30000), cls=1)
        self.poke(1, ENT_SQUAD, b"\x00")
        self.place(0, (0, 0, 0))
        self.poke(0, 6, bytes([128]))
        self.place(self.ENT_MAX - 1, (0, 30000, 0), enemy=True)
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
        return struct.unpack("<hhh", self.c.read_ram(self.sym["ENTITIES"], 6))

    def hand_back(self):
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")
        self.c.key_down("v")
        self.c.run_frames(30)
        self.c.key_up("v")
        self.c.run_frames(20)
        self.assertGreaterEqual(self.byte("PILOT_SLOT"), self.ENT_MAX)
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x01")
        self.settle()



class TestTheArrow(CockpitFixture):
    """"Θα δείχνει ένα μεγάλο βέλος στις άκρες της οθόνης προς τα που πρέπει
    να πας για να βρεις εχθρό": while the chosen enemy is off the screen, a
    red arrowhead at the edge of the view, one of eight, whose apex is in
    the middle of that edge or in the corner; none while it is on the
    screen, and none when nobody flies. The shapes are read out of the
    bank and the placement and the mirroring are the model here."""

    def shape(self, name):
        """(n, dt, db, b0) as arw_fan reads it: n columns from the apex,
        column k a run of b0 + db*k rows starting dt*k rows below it."""
        raw = h.read_bank4(self.c, self.sym[name], 4)
        s = lambda b: b - 256 if b >= 128 else b
        return raw[0], s(raw[1]), s(raw[2]), raw[3]

    def apex(self, hdir, vdir):
        return (160 + hdir * self.sym["ARROW_DX"], self.sym["PROJ_CENTRE_Y"] + vdir * self.sym["ARROW_DY"])

    def expected(self, hdir, vdir):
        """The pixels of the arrow for a direction, the sums the Z80 does:
        the sideways head for a level one, the up head -- both halves --
        for a straight one, else the corner's; each column's run mirrored
        about the apex when the head points down, the columns running the
        other way when it points left."""
        name = "ARROW_SIDE" if vdir == 0 else ("ARROW_UP" if hdir == 0 else "ARROW_CORNER")
        n, dt, db, b0 = self.shape(name)
        ax, ay = self.apex(hdir, vdir)
        halves = (1, -1) if hdir == 0 else (hdir,)
        out = set()
        for hh in halves:
            for k in range(n):
                top, rows = dt * k, b0 + db * k
                if vdir > 0:
                    top = -(top + rows - 1)
                out.update((ax - hh * k, ay + top + r) for r in range(rows))
        return out

    def red_about(self, ax, ay):
        box = self.sym["ARROW_BOX"]
        return {(x, y) for x in range(ax - box, ax + box + 1) for y in range(ay - box, ay + box + 1)
                if self.pen_at(x, y) == 3}

    def in_the_scanner(self, p):
        """The bottom-right corner arrow lands inside the scanner's oval
        (TestTheScanner), which draws its rim and its hostiles' marks in the
        same ink: both are drawn, each with its own rectangle, and red there
        that is not the arrow's is the scanner's."""
        x0, y0 = self.sym["SCAN_X_BYTES"] * 4, self.sym["SCAN_Y"]
        return x0 <= p[0] < x0 + self.sym["SCAN_W_BYTES"] * 4 and y0 <= p[1] < y0 + self.sym["SCAN_H"]

    def assert_arrow(self, hd, vd, msg=""):
        """Every pixel of the arrow is lit, and nothing else in its box is
        but the scanner's."""
        got, want = self.red_about(*self.apex(hd, vd)), self.expected(hd, vd)
        missing = want - got
        extra = {p for p in got - want if not self.in_the_scanner(p)}
        self.assertEqual((sorted(missing), sorted(extra)), ([], []),
                         f"the arrow at {(hd, vd)}: {len(got & want)} of {len(want)} pixels, {len(extra)} extra{': ' + msg if msg else ''}")

    def assert_no_arrow(self, hd, vd, msg=""):
        """Not the whole shape: the scanner's rim and marks can put a few red
        pixels in the corner's box, never seventy-eight particular ones."""
        got, want = self.red_about(*self.apex(hd, vd)), self.expected(hd, vd)
        self.assertFalse(want <= got, f"an arrow at {(hd, vd)}{': ' + msg if msg else ''}")

    def place_off_screen(self, me, dx, dy, dz=0):
        mx, my, mz = me
        self.place(self.PLAYER_MAX, (mx + dx, my + dy, mz + dz), enemy=True)
        self.settle()
        self.assertEqual([v for v in self.visible() if v["enemy"]], [], "the fixture's hostile is on the screen")
        self.assertEqual(h.read_cpu(self.c, self.sym["PILOT_TARGET"], 1)[0], self.PLAYER_MAX, "the hostile was not the one chosen")

    def test_a_hostile_to_the_right_is_an_arrow_pointing_right(self):
        me = self.fly()
        self.place_off_screen(me, 12000, 0)
        self.assert_arrow(1, 0)
        #  ...and nowhere else: the other seven edges are clear.
        for hd, vd in ((-1, 0), (0, -1), (0, 1), (1, -1), (-1, -1), (1, 1), (-1, 1)):
            self.assert_no_arrow(hd, vd, f"an arrow at {(hd, vd)} as well")

    def test_the_eight_directions(self):
        """One boot, the hostile moved round the ship: left, up, down and
        the four corners. The diagonals are placed at equal offsets, well
        inside the dead zone's three eighths either way."""
        me = self.fly()
        for (dx, dy), (hd, vd) in (((-12000, 0), (-1, 0)), ((0, 12000), (0, -1)), ((0, -12000), (0, 1)),
                                    ((8000, 8000), (1, -1)), ((-8000, 8000), (-1, -1)),
                                    ((8000, -8000), (1, 1)), ((-8000, -8000), (-1, 1))):
            self.place_off_screen(me, dx, dy)
            self.assert_arrow(hd, vd, f"a hostile at {(dx, dy)}")

    def test_a_hostile_beside_and_above_is_the_cardinal_when_it_is_mostly_one(self):
        """Three eighths is the dead zone: 12000 across and 3000 up is
        under it, and reads as RIGHT; 12000 across and 6000 up is over it,
        and reads as the corner."""
        me = self.fly()
        self.place_off_screen(me, 12000, 3000)
        self.assert_arrow(1, 0)
        self.place_off_screen(me, 12000, 6000)
        self.assert_arrow(1, -1)
        self.assert_no_arrow(1, 0)

    def test_no_arrow_while_the_enemy_is_on_the_screen_and_none_after_v(self):
        me = self.fly()
        mx, my, mz = me
        self.place(self.PLAYER_MAX, (mx, my, mz + 6400), enemy=True)
        self.settle()
        self.assertEqual(len([v for v in self.visible() if v["enemy"]]), 1, "the hostile ahead is not drawn")
        for hd, vd in ((1, 0), (-1, 0), (0, -1), (0, 1), (1, -1), (-1, -1), (1, 1), (-1, 1)):
            self.assert_no_arrow(hd, vd, f"an arrow at {(hd, vd)} with the enemy on the screen")
        #  Off the screen: the arrow; the stick handed back: gone.
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 12000, my, mz))
        self.settle()
        self.assert_arrow(1, 0)
        self.hand_back()
        self.assert_no_arrow(1, 0, "the arrow stayed after V")


class TestTheEnemysBar(CockpitFixture):
    """"Το σκάφος που θα αντιμετωπίζεις να έχει πάνω την μπάρα με την ισχύ
    του": PILOT_BAR_W bytes by PILOT_BAR_H lines, PILOT_BAR_UP above where
    the chosen enemy projects, a red trough with the hull over the class's
    full in white, in eighths."""

    def bar_rows(self, e):
        """The bar's bytes, row by row, out of the front buffer."""
        w, hgt, up = self.sym["PILOT_BAR_W"], self.sym["PILOT_BAR_H"], self.sym["PILOT_BAR_UP"]
        xb = min(max(e["sx"] // 4 - w // 2, 0), 80 - w)
        y0 = max(e["sy"] - up, self.sym["CTX_BAR_H"])
        buf = h.front_buffer(self.c)
        rows = []
        for y in range(y0, y0 + hgt):
            addr = buf + (y // 8) * 80 + (y % 8) * 0x800 + xb
            rows.append(self.c.read_ram(addr, w))
        return rows

    def the_enemy(self):
        enemies = [v for v in self.visible() if v["enemy"]]
        self.assertEqual(len(enemies), 1, enemies)
        return enemies[0]

    def test_the_bar_says_how_much_hull_the_enemy_has_left(self):
        me = self.fly()
        mx, my, mz = me
        self.place(self.PLAYER_MAX, (mx + 800, my, mz + 6400), enemy=True)   # off the centre, clear of the ticks
        self.settle()
        full = h.read_bank4(self.c, self.sym["CLASS_HULL"], 1)[0]
        self.assertEqual(full, 255, "the interceptor's full hull is not 255?")
        w = self.sym["PILOT_BAR_W"]
        for hull, white in ((255, 8), (128, 4), (16, 1), (200, 6)):
            self.poke(self.PLAYER_MAX, ENT_HULL, bytes([hull]))
            self.settle()
            e = self.the_enemy()
            want = bytes([0xF0] * white + [0xFF] * (w - white))
            for row in self.bar_rows(e):
                self.assertEqual(row, want, f"hull {hull}: the bar reads {row.hex()} where {want.hex()} was wanted")

    def test_the_bar_sits_above_the_sprite_and_goes_with_it(self):
        me = self.fly()
        mx, my, mz = me
        self.place(self.PLAYER_MAX, (mx + 800, my, mz + 6400), enemy=True)
        self.settle()
        e = self.the_enemy()
        up = self.sym["PILOT_BAR_UP"]
        self.assertGreater(up, 32, "a x4 sprite reaches 32 lines above its centre")
        #  The line just under the bar is not the bar's: the trough is not there.
        y = e["sy"] - up + self.sym["PILOT_BAR_H"]
        buf = h.front_buffer(self.c)
        xb = e["sx"] // 4 - self.sym["PILOT_BAR_W"] // 2
        under = self.c.read_ram(buf + (y // 8) * 80 + (y % 8) * 0x800 + xb, self.sym["PILOT_BAR_W"])
        self.assertNotIn(0xFF, under, "the bar is taller than PILOT_BAR_H")
        #  Off the screen: the bar is gone from where it was, in both buffers.
        rows_were = self.bar_rows(e)
        self.assertTrue(all(0xFF in r or 0xF0 in r for r in rows_were))
        self.poke(self.PLAYER_MAX, 0, struct.pack("<hhh", mx + 12000, my, mz))
        self.settle()
        for _ in range(2):
            self.assertEqual(set(b"".join(self.bar_rows(e))), {0}, "the bar was not erased")
            h.run_to_stable_point(self.c, self.sym)
            self.c.run_frames(1)


if __name__ == "__main__":
    unittest.main()
