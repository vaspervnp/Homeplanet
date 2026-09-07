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


class TestTheyShootBack(RunFixture):
    """The flights fire on a roll, and a shot of theirs is in run_eshots. It
    was not, for the whole life of the run: run_enemies_step wrote the shot
    through an HL that sys_rand had just used as its state, so every shot a
    Vekhar fired went to two random bytes of the 64K instead. Found because
    the destroyer, built from the same lines, never fired either."""

    def test_a_flight_on_the_screen_fires_within_a_few_seconds(self):
        self.jump_into_the_run()
        self.begin()
        base = self.sym["RUN_ESHOTS"]
        for _ in range(60):
            self.step(1)
            shots = h.read_cpu(self.c, base, self.sym["RUN_ENEMY_MAX"] * 2)
            live = [(shots[i * 2], shots[i * 2 + 1]) for i in range(self.sym["RUN_ENEMY_MAX"]) if shots[i * 2]]
            if live:
                break
        else:
            self.fail("sixty steps with flights on the screen and not one shot fired back")
        for x, y in live:
            self.assertTrue(self.sym["MG_BODY_Y"] <= y < self.sym["MG_BODY_Y"] + self.sym["MG_BODY_H"],
                            f"a shot at y {y} is outside the lane")

    def test_their_shot_flies_left_and_leaves(self):
        self.jump_into_the_run()
        self.begin()
        base = self.sym["RUN_ESHOTS"]
        x0 = None
        for _ in range(80):
            self.step(1)
            s = h.read_cpu(self.c, base, 2)
            if s[0]:
                x0 = s[0]
                break
        else:
            self.fail("the first flight never fired")
        self.step(1)
        x1 = h.read_cpu(self.c, base, 1)[0]
        self.assertTrue(x1 == 0 or x1 < x0, f"their shot did not fly left: {x0} -> {x1}")


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


class TestTheDestroyer(RunFixture):
    """minigame2.md's "last thirty per cent": with RUN_BOSS_AT steps left a
    destroyer comes in from the right, crosses at a third of a fighter's
    speed, fires twice as often into a shot slot of its own, and takes
    RUN_BOSS_HITS hits -- worth RUN_BOSS_WORTH kills. It can be outlasted."""

    def boss(self):
        raw = h.read_cpu(self.c, self.sym["RUN_BOSS"], 4)
        return tuple(raw)                   # hits left, x, y0, theta

    def bring_it_in(self):
        self.jump_into_the_run()
        self.begin()
        self.poke7("RUN_LEFT", self.sym["RUN_BOSS_AT"] + 1)
        self.step(2)
        hits, x, y0, theta = self.boss()
        self.assertEqual(hits, self.sym["RUN_BOSS_HITS"], "the destroyer did not come in")
        return x

    def test_it_comes_in_from_the_right_with_its_hits_to_take(self):
        x = self.bring_it_in()
        self.assertGreaterEqual(x, self.sym["RUN_ENEMY_X0"] - 2 * self.sym["RUN_BOSS_DX"])
        self.assertEqual(self.boss()[2], self.sym["MG_CY"], "it is not along the middle of the lane")

    def test_it_crosses_slowly_leftwards(self):
        x0 = self.bring_it_in()
        self.step(6)
        x1 = self.boss()[1]
        self.assertLess(x1, x0, "the destroyer did not move left")
        self.assertLessEqual(x0 - x1, 6 * self.sym["RUN_BOSS_DX"] + 1, "it is faster than RUN_BOSS_DX")

    def test_three_shots_kill_it_and_it_pays_like_seven(self):
        self.bring_it_in()
        #  Let it come in off the edge first: a shot moves RUN_SHOT_DX before
        #  it is checked and one that ends past 160 is gone, not a hit.
        self.step(8)
        kills0 = self.b7("RUN_KILLS")
        for n in range(self.sym["RUN_BOSS_HITS"]):
            hits, x, y0, theta = self.boss()
            self.assertEqual(hits, self.sym["RUN_BOSS_HITS"] - n)
            #  A shot of ours on its centre line, a step short of it.
            h.write_cpu(self.c, self.sym["RUN_SHOTS"], bytes([x - self.sym["RUN_SHOT_DX"], y0]))
            self.step(1)
        self.assertEqual(self.boss()[0], 0, "three hits did not kill it")
        self.assertEqual(self.b7("RUN_KILLS"), kills0 + self.sym["RUN_BOSS_WORTH"],
                         "the destroyer was not worth RUN_BOSS_WORTH kills")

    def test_it_fires_into_its_own_slot(self):
        self.bring_it_in()
        slot = self.sym["RUN_ESHOTS"] + self.sym["RUN_ENEMY_MAX"] * 2
        for _ in range(60):
            self.step(1)
            if h.read_cpu(self.c, slot, 1)[0]:
                break
        else:
            self.fail("the destroyer never fired")
        y = h.read_cpu(self.c, slot + 1, 1)[0]
        self.assertTrue(self.sym["MG_BODY_Y"] <= y < self.sym["MG_BODY_Y"] + self.sym["MG_BODY_H"])

    def test_outlasted_it_pays_nothing(self):
        self.bring_it_in()
        kills0 = self.b7("RUN_KILLS")
        self.poke7("RUN_BOSS", 1)                # one hit from dead...
        h.write_cpu(self.c, self.sym["RUN_BOSS"] + 1, bytes([5]))   # ...and about to get past
        self.step(3)
        self.assertEqual(self.boss()[0], 0, "it did not get past")
        self.assertEqual(self.b7("RUN_KILLS"), kills0, "a destroyer that got past paid")


class TestTheyComeFromTheRight(RunFixture):
    """"In the R-Type minigame ships show up right in front of the player.
    They should always be coming from the other side." mini_blit kept the
    x in one byte, so a ship spawned at 316..372 pixels was drawn at 60..116
    -- in front of us -- until it had flown far enough to fit. Read off the
    pixels: a flight fresh off the right edge puts no enemy ink on the left
    half of the lane, and a ship at a hundred units is drawn at two hundred
    pixels."""

    def red_columns(self, x0, x1):
        """Byte columns in x0..x1 carrying pen-3 pixels inside the lane,
        below the hit marks."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        top = self.sym["MG_BODY_Y"] + 12
        bottom = self.sym["MG_BODY_Y"] + self.sym["MG_BODY_H"]
        cols = set()
        for y in range(top, bottom):
            for xb in range(x0, x1):
                b = ram[h.screen_offset(y, xb)]
                if (b & 0x0F) & ((b & 0xF0) >> 4):        # both planes: pen 3
                    cols.add(xb)
        return cols

    def one_enemy_at(self, x):
        base = self.sym["RUN_ENEMIES"]
        h.write_cpu(self.c, base, bytes([1, x, self.sym["MG_CY"], 0]))
        for i in range(1, self.sym["RUN_ENEMY_MAX"]):
            h.write_cpu(self.c, base + i * 4, b"\x00")
        h.write_cpu(self.c, self.sym["RUN_ESHOTS"], bytes(self.sym["RUN_ESHOT_N"] * 2))
        self.step(1)
        self.c.run_frames(4)

    def test_a_ship_past_the_right_edge_draws_nothing_on_the_left(self):
        self.jump_into_the_run()
        self.begin()
        self.one_enemy_at(175)                              # 350 pixels: off the right
        self.assertEqual(self.red_columns(0, 40), set(),
                         "enemy ink on the left half with the only enemy past the right edge")

    def test_a_ship_at_a_hundred_units_is_drawn_at_two_hundred_pixels(self):
        self.jump_into_the_run()
        self.begin()
        self.one_enemy_at(100)
        cols = self.red_columns(0, 80)
        self.assertTrue(cols, "the enemy was not drawn at all")
        self.assertTrue(all(42 <= c <= 58 for c in cols), f"enemy ink at columns {sorted(cols)}")
