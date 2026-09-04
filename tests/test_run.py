"""The run -- the R-Type between the jumps (game/run.asm, minigame2.md).

It runs from bank 7 like the chase, on the jumps into missions 3, 7, 11, 15
and 19, so every test here reaches it the honest way: mission 1 to 2 by the
harness, then J out of mission 2 and the countdown skipped. Its state is in
bank 7, which is the window while it runs, so it is read with read_cpu; the
two flags the game itself reads -- run_active, run_shown -- are the low 16K's.

Every claim is about a POSITION or a COUNT read by name, never "did the run
happen": a build where SPACE fired nothing and the enemies flew past
untouched ends on the clock exactly like a played one.
"""

import unittest

from tests import harness as h
from tests.harness import cpc


class RunFixture(unittest.TestCase):

    FIRST_CHAR, LAST_CHAR, CHAR_H = 32, 95, 8

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)
        h.jump_mission(self.c)                              # 1 -> 2: no minigame
        self.assertEqual(self.byte("MIS_INDEX"), 1)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def byte(self, name):
        return self.c.read_ram(self.sym[name], 1)[0]

    def b7(self, name):
        return h.read_cpu(self.c, self.sym[name], 1)[0]

    def poke7(self, name, value):
        h.write_cpu(self.c, self.sym[name], bytes([value & 0xFF]))

    def jump_into_the_run(self):
        """J out of mission 2 -- (1 + 1) mod MG_EVERY is 2 -- to its page."""
        h.clear_the_way_out(self.c)
        self.c.key_down("j")
        self.c.run_frames(40)
        self.c.key_up("j")
        h.skip_the_countdown(self.c)
        for _ in range(800):
            self.c.run_frames(5)
            if self.byte("RUN_ACTIVE"):
                break
        else:
            self.fail("the jump out of mission 2 never reached the run")
        self.c.run_frames(20)

    def begin(self):
        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)
        self.c.run_frames(12)

    def step(self, n=1):
        for _ in range(n):
            left = self.b7("RUN_LEFT")
            for _ in range(200):
                self.c.run_frames(1)
                if self.b7("RUN_LEFT") != left:
                    break

    def tap(self, key, frames=6):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)

    def row(self, y, x0, cells):
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        font = bytes(self.c.read_ram(
            self.sym["TXT_FONT"], (self.LAST_CHAR - self.FIRST_CHAR + 1) * self.CHAR_H))
        out = []
        for bx in range(x0, x0 + cells * 2, 2):
            cell = []
            for r in range(self.CHAR_H):
                a = ram[h.screen_offset(y + r, bx)]
                b = ram[h.screen_offset(y + r, bx + 1)]
                cell.append(((a | (a << 4)) & 0xF0) | (((b | (b << 4)) & 0xF0) >> 4))
            best, bd = " ", 999
            for ci in range(self.FIRST_CHAR, self.LAST_CHAR + 1):
                g = font[(ci - self.FIRST_CHAR) * self.CHAR_H:(ci - self.FIRST_CHAR + 1) * self.CHAR_H]
                d = sum(bin(p ^ q).count("1") for p, q in zip(g, cell))
                if d < bd:
                    bd, best = d, chr(ci)
            out.append(best if bd <= 2 else "?")
        return "".join(out)

    def enemies(self):
        base = self.sym["RUN_ENEMIES"]
        raw = h.read_cpu(self.c, base, self.sym["RUN_ENEMY_MAX"] * 4)
        return [tuple(raw[i * 4:i * 4 + 4]) for i in range(self.sym["RUN_ENEMY_MAX"])]

    def shots(self):
        raw = h.read_cpu(self.c, self.sym["RUN_SHOTS"], self.sym["RUN_SHOT_MAX"] * 2)
        return [(raw[i * 2], raw[i * 2 + 1]) for i in range(self.sym["RUN_SHOT_MAX"])]


class TestWhenAndThePage(RunFixture):

    def test_the_jump_out_of_mission_2_opens_on_the_page_and_enter_begins_it(self):
        self.jump_into_the_run()
        self.assertEqual(self.row(self.sym["MG_INTRO_GO_Y"], self.sym["MG_INTRO_GO_X"], 13),
                         "ENTER - BEGIN")
        line3 = self.row(self.sym["MG_INTRO_Y"] + 2 * self.sym["MG_INTRO_STEP"],
                         self.sym["RUN_INTRO_3_X"], 29)
        self.assertEqual(line3, "UP AND DOWN FLY. SPACE FIRES.")
        self.c.run_frames(200)
        self.assertEqual(self.b7("RUN_LEFT"), self.sym["RUN_STEPS"],
                         "the run started without waiting for ENTER")
        self.begin()
        self.step(2)
        self.assertLess(self.b7("RUN_LEFT"), self.sym["RUN_STEPS"], "ENTER did not start the run")
        self.assertEqual(self.byte("RUN_SHOWN"), 1)

    def test_the_line_names_the_key(self):
        self.jump_into_the_run()
        self.begin()
        self.step(2)
        self.assertEqual(self.row(self.sym["MG_TEXT_Y"], self.sym["RUN_RUN_X"], 29),
                         "CLEAR THE LANE.  SPACE FIRES.")


class TestFlyingAndFiring(RunFixture):

    def test_up_and_down_move_us_inside_the_lane(self):
        self.jump_into_the_run()
        self.begin()
        y0 = self.b7("RUN_Y")
        self.c.key_down(cpc.KEY_UP)
        self.step(3)
        self.c.key_up(cpc.KEY_UP)
        up = self.b7("RUN_Y")
        self.assertLess(up, y0, "UP did not move us up")
        self.c.key_down(cpc.KEY_DOWN)
        self.step(30)
        self.c.key_up(cpc.KEY_DOWN)
        self.assertEqual(self.b7("RUN_Y"), self.sym["RUN_YMAX"], "DOWN did not stop at the lane's edge")

    def test_space_fires_a_shot_that_flies_right_and_leaves(self):
        self.jump_into_the_run()
        self.begin()
        self.assertEqual(self.shots(), [(0, 0)] * self.sym["RUN_SHOT_MAX"])
        self.tap(cpc.KEY_SPACE)
        self.step(1)
        live = [s for s in self.shots() if s[0]]
        self.assertEqual(len(live), 1, f"SPACE did not fire exactly one shot: {self.shots()}")
        x0 = live[0][0]
        self.step(1)
        live = [s for s in self.shots() if s[0]]
        self.assertTrue(live and live[0][0] > x0, "the shot did not fly right")
        self.step(30)
        self.assertEqual([s for s in self.shots() if s[0]], [], "the shot never left the screen")

    def test_a_shot_on_an_enemy_kills_it_and_counts(self):
        self.jump_into_the_run()
        self.begin()
        #  Put an enemy right in front of the nose, straight and level, and
        #  fire once. run_near's box is RUN_HIT_UX by RUN_HIT_Y.
        base = self.sym["RUN_ENEMIES"]
        y = self.b7("RUN_Y")
        h.write_cpu(self.c, base, bytes([1, self.sym["RUN_UX"] + 20, y, 0]))    # alive, x, y0, theta 0: y = y0
        kills0 = self.b7("RUN_KILLS")
        self.tap(cpc.KEY_SPACE)
        self.step(4)
        self.assertEqual(self.b7("RUN_KILLS"), kills0 + 1, "the shot went through it")
        #  ...and the shot was SPENT on it -- not "the record is dead", because
        #  killing the last one flying makes run_spawn put a new flight into
        #  the same slots on the next step.
        self.assertEqual([s for s in self.shots() if s[0]], [], "the shot flew on through the enemy")

    def test_enemies_arrive_from_the_right_and_fly_left(self):
        self.jump_into_the_run()
        self.begin()
        self.step(3)
        alive = [e for e in self.enemies() if e[0]]
        self.assertGreaterEqual(len(alive), 1, "no flight arrived")
        x0 = alive[0][1]
        self.step(3)
        alive2 = [e for e in self.enemies() if e[0]]
        self.assertTrue(alive2 and alive2[0][1] < x0, "the enemy did not fly left")


class TestTheStakes(RunFixture):

    def test_three_hits_lose_it_and_cost_the_fleet(self):
        self.jump_into_the_run()
        self.begin()
        self.poke7("MINI_HITS", 2)
        #  ...and one of their shots on our nose, from the record beside the
        #  first enemy: x, y at ours.
        h.write_cpu(self.c, self.sym["RUN_ESHOTS"],
                    bytes([self.sym["RUN_UX"] + 5, self.b7("RUN_Y")]))
        for _ in range(12):
            self.step()
            if self.b7("RUN_MSG") == self.sym["RUN_MSG_LOST"]:
                break
        else:
            self.fail("the third hit did not end the run")
        self.assertGreater(self.byte("MINI_LOST"), 0, "the loss cost the fleet nothing")

    def test_the_clock_ends_it_won_and_the_kills_are_salvage(self):
        self.jump_into_the_run()
        self.begin()
        ru0 = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.poke7("RUN_KILLS", 3)
        self.poke7("RUN_LEFT", 2)
        for _ in range(12):
            self.step()
            if self.b7("RUN_MSG") == self.sym["RUN_MSG_WON"]:
                break
        else:
            self.fail("the clock did not end the run")
        ru = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.assertEqual(ru - ru0, 3 * self.sym["RUN_SALVAGE"], "the kills were not paid as salvage")
        self.assertEqual(self.byte("MINI_LOST"), 0, "a won run cost ships")

    def test_the_briefing_follows_and_the_page_is_not_shown_twice(self):
        self.jump_into_the_run()
        self.begin()
        self.poke7("RUN_LEFT", 1)
        for _ in range(600):
            self.c.run_frames(5)
            if self.byte("MIS_BRIEFING"):
                break
        else:
            self.fail("no briefing after the run")
        self.assertEqual(self.byte("MIS_INDEX"), 2, "the run did not arrive at mission 3")
        self.assertEqual(self.byte("RUN_ACTIVE"), 0)
        self.assertEqual(self.byte("RUN_SHOWN"), 1, "the page will be shown again next time")


if __name__ == "__main__":
    unittest.main()
