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


def drawn_y(sym, y0, theta):
    """Where run_draw puts a ship whose record says (y0, theta)."""
    import math
    return y0 + int(127 * math.sin(theta / 256 * 2 * math.pi)) * sym["RUN_ENEMY_AMP"] // 128


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
    """minigame2.md's "last thirty per cent", as asked for: with RUN_BOSS_AT
    steps left a destroyer comes in from the right to the MIDDLE of the lane
    and holds there, fires twice as often into a shot slot of its own, takes
    RUN_BOSS_HITS hits -- worth RUN_BOSS_WORTH kills -- and the clock waits
    for it: "να μην τελειώνει το παιχνίδι μέχρι να τον καταστρέψω"."""

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
        #  ...and the flight that was already on the screen is gone: a shot
        #  meant for the destroyer is spent on whichever fighter it crosses
        #  first, and the fifth of nine did exactly that.
        h.write_cpu(self.c, self.sym["RUN_ENEMIES"], bytes(self.sym["RUN_ENEMY_MAX"] * 4))
        return x

    def test_it_comes_in_from_the_right_with_its_hits_to_take(self):
        x = self.bring_it_in()
        self.assertGreaterEqual(x, self.sym["RUN_ENEMY_X0"] - 2 * self.sym["RUN_BOSS_DX"])
        self.assertEqual(self.boss()[2], self.sym["MG_CY"], "it is not along the middle of the lane")

    def test_it_comes_in_at_its_own_speed_and_holds_in_the_middle(self):
        x0 = self.bring_it_in()
        self.step(6)
        x1 = self.boss()[1]
        self.assertLess(x1, x0, "the destroyer did not move left")
        self.assertLessEqual(x0 - x1, 6 * self.sym["RUN_BOSS_DX"] + 1, "it is faster than RUN_BOSS_DX")
        for _ in range(60):
            self.step(1)
            if self.boss()[1] == self.sym["RUN_BOSS_STOP"]:
                break
        else:
            self.fail(f"it never reached the middle: x {self.boss()[1]}")
        self.step(5)
        self.assertEqual(self.boss()[1], self.sym["RUN_BOSS_STOP"], "it did not hold in the middle")

    def test_no_more_flights_once_it_is_in(self):
        self.bring_it_in()
        base = self.sym["RUN_ENEMIES"]
        h.write_cpu(self.c, base, bytes(self.sym["RUN_ENEMY_MAX"] * 4))   # the last flight, gone
        self.step(6)
        alive = [e for e in self.enemies() if e[0]]
        self.assertEqual(alive, [], f"a flight spawned with the destroyer in: {alive}")

    def test_nine_shots_kill_it_and_it_pays_like_seven(self):
        self.bring_it_in()
        self.step(8)
        kills0 = self.b7("RUN_KILLS")
        for n in range(self.sym["RUN_BOSS_HITS"]):
            hits, x, y0, theta = self.boss()
            self.assertEqual(hits, self.sym["RUN_BOSS_HITS"] - n)
            #  ...at the y it is DRAWN at, which is y0 only at theta 0.
            h.write_cpu(self.c, self.sym["RUN_SHOTS"],
                        bytes([x - self.sym["RUN_SHOT_DX"], drawn_y(self.sym, y0, theta)]))
            self.step(1)
        self.assertEqual(self.boss()[0], 0, "nine hits did not kill it")
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

    def test_the_clock_waits_for_it_and_the_kill_ends_the_run(self):
        self.bring_it_in()
        #  Out of its line of fire: it shoots at twice a fighter's odds along
        #  a sine about the middle, which is where we start, and three of
        #  those over the seconds this takes is a loss rather than the win
        #  the test is about.
        self.poke7("RUN_Y", self.sym["RUN_YMIN"])
        self.poke7("RUN_LEFT", 1)
        self.step(6)
        self.assertEqual(self.byte("RUN_ACTIVE"), 1, "the run ended with the destroyer alive")
        self.assertEqual(self.boss()[0], self.sym["RUN_BOSS_HITS"])
        self.assertGreaterEqual(self.b7("RUN_LEFT"), 1)
        self.poke7("RUN_BOSS", 1)                       # one hit from dead
        hits, x, y0, theta = self.boss()
        ru0 = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        h.write_cpu(self.c, self.sym["RUN_SHOTS"],
                    bytes([x - self.sym["RUN_SHOT_DX"], drawn_y(self.sym, y0, theta)]))
        #  Not step(): the clock reads 1 at every step boundary while it is
        #  held, so "RUN_LEFT changed" never comes. The run ENDING is the
        #  claim, and its end is in the low 16K.
        for _ in range(120):
            self.c.run_frames(20)
            if not self.byte("RUN_ACTIVE"):
                break
        else:
            self.fail("the kill did not end the run")
        ru = int.from_bytes(self.c.read_ram(self.sym["ECO_RU"], 2), "little")
        self.assertGreaterEqual(ru - ru0, self.sym["RUN_BOSS_WORTH"] * self.sym["RUN_SALVAGE"],
                                "the run ended without the destroyer's salvage: it was not won")
        self.assertEqual(self.byte("MINI_LOST"), 0, "the run ended as a loss")


if __name__ == "__main__":
    unittest.main()


class TestShotsHitWhereTheShipIs(RunFixture):
    """"Οι σφαίρες περνάνε από μέσα του." The hit test compared a shot with
    the ship's y0, the centre line of its sine, while the ship is drawn
    RUN_ENEMY_AMP lines above or below it. Staged at theta 64 -- the top of
    the swing -- a shot at y0 must miss and a shot at the drawn y must hit;
    every earlier test had theta 0, where the two are the same line."""

    def drawn_y(self, y0, theta):
        return drawn_y(self.sym, y0, theta)

    def one_enemy(self, y0, theta):
        base = self.sym["RUN_ENEMIES"]
        h.write_cpu(self.c, base, bytes([1, self.sym["RUN_UX"] + 20, y0, theta]))
        for i in range(1, self.sym["RUN_ENEMY_MAX"]):
            h.write_cpu(self.c, base + i * 4, b"\x00")

    def shoot_at(self, x, y):
        h.write_cpu(self.c, self.sym["RUN_SHOTS"], bytes([x, y]))
        self.step(1)

    def test_a_shot_on_the_centre_line_misses_a_fighter_at_the_top_of_its_swing(self):
        self.jump_into_the_run()
        self.begin()
        y0 = self.b7("RUN_Y")
        self.one_enemy(y0, 64)
        kills0 = self.b7("RUN_KILLS")
        self.shoot_at(self.sym["RUN_UX"] + 20 - self.sym["RUN_SHOT_DX"], y0)
        self.assertEqual(self.b7("RUN_KILLS"), kills0, "a shot twenty lines under the ship killed it")

    def test_a_shot_at_the_drawn_y_hits_it(self):
        self.jump_into_the_run()
        self.begin()
        y0 = self.b7("RUN_Y")
        self.one_enemy(y0, 64)
        kills0 = self.b7("RUN_KILLS")
        self.shoot_at(self.sym["RUN_UX"] + 20 - self.sym["RUN_SHOT_DX"], self.drawn_y(y0, 64))
        self.assertEqual(self.b7("RUN_KILLS"), kills0 + 1, "a shot where the ship is drawn went through it")

    def test_the_destroyer_is_hit_where_it_is_drawn_too(self):
        self.jump_into_the_run()
        self.begin()
        self.poke7("RUN_LEFT", self.sym["RUN_BOSS_AT"] + 1)
        self.step(2)
        boss = self.sym["RUN_BOSS"]
        h.write_cpu(self.c, boss, bytes([self.sym["RUN_BOSS_HITS"], self.sym["RUN_BOSS_STOP"], self.sym["MG_CY"], 64]))
        y = self.drawn_y(self.sym["MG_CY"], 64 + self.sym["RUN_BOSS_SPIN"])
        self.shoot_at(self.sym["RUN_BOSS_STOP"] - self.sym["RUN_SHOT_DX"], y)
        self.assertEqual(h.read_cpu(self.c, boss, 1)[0], self.sym["RUN_BOSS_HITS"] - 1,
                         "a shot where the destroyer is drawn went through it")


class TestTheLivesAreShips(RunFixture):
    """"Οι ζωές να φαίνονται και να αφαιρούνται. Να είναι μικρά σκάφη." Three
    small white ships top left of the band, one fewer per hit, in both
    minigames -- mini_hit_marks is one routine. Read off the pixels."""

    def white_top_left(self):
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        n = 0
        for y in range(self.sym["MG_BODY_Y"], self.sym["MG_BODY_Y"] + 12):
            for xb in range(0, 18):
                b = ram[h.screen_offset(y, xb)]
                n += bin(b & 0xF0 & ~((b & 0x0F) << 4) & 0xFF).count("1")   # pen 1 only
        return n

    def test_three_ships_then_two(self):
        self.jump_into_the_run()
        self.begin()
        self.step(2)
        three = self.white_top_left()
        self.assertGreater(three, 30, "no lives drawn")     # three tier B ships
        self.poke7("MINI_HITS", 1)
        self.step(2)
        two = self.white_top_left()
        self.assertLess(two, three, "a hit did not take a ship away")
        self.assertGreater(two, three // 3, "more than one ship went")
        self.poke7("MINI_HITS", 2)
        self.step(2)
        one = self.white_top_left()
        self.assertLess(one, two)
