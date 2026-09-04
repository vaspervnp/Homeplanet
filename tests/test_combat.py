"""Phase 6: firing, damage, death and explosions.

Homeplanet.md phase 6's criterion is "πρώτη πραγματική σύγκρουση στόλων" -- so
the last test here drives an actual battle and insists it resolves. The ones
before it pin the pieces, and in particular pin the bug that made the fleet
open fire on itself.
"""

from __future__ import annotations

import struct
import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
from tools import gentables as g

#  Mirrored from src/game/entity.asm and src/game/combat.asm
ENT_SIZE = 20
#  Straight out of the build: the table got bigger when the fleet's
#  ceiling doubled, and a test that walks range(ENT_MAX) then stops looking
#  exactly where the new slots are.
ENT_MAX = h.symbols()["ENT_MAX"]
#  Where the fleet stops and the enemy starts. Tests that stage a
#  battle have to respect it: cbt_find_enemy searches one region.
PLAYER_MAX = h.symbols()["ENT_PLAYER_MAX"]
ENT_X, ENT_HULL, ENT_FLAGS, ENT_SQUAD, ENT_TARGET, ENT_TIMER = 0, 10, 11, 12, 14, 19
ENT_CLASS, ENT_ORDER = 9, 13
ENT_ORDER_NONE, ENT_ORDER_ATTACK = 0, 2
F_ACTIVE, F_ENEMY, F_DISABLED = 1, 2, 4
#  Mirrored from src/game/combat.asm.
CBT_RANGE = 40
CBT_COOLDOWN = 6
#  The game runs at 12.5fps on a 50Hz machine.
TICKS_PER_GAME_FRAME = 4
EXPL_MAX, EXPL_SIZE, EXPL_TIMER = 6, 7, 6
CBT_DAMAGE = 24


class CombatFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        self.c = h.boot_quick(frames=300)
        self.to_combat_mission()

    def to_combat_mission(self):
        """Jump forward to the first mission that has an enemy in it.

        The campaign opens on training and then on a mission the design
        describes as "καμία μάχη· μόνο περισυλλογή επιζώντων και σιωπή".
        Both are ARRIVE missions and complete immediately, so two jumps get
        here; there is nothing to shoot at before that.
        """
        for _ in range(2):
            h.jump_mission(self.c)
        self.assertGreater(self.counts()[1], 0, "no enemies after jumping to mission 3")

    def tearDown(self):
        #  Free it now; see harness.close.
        h.close(getattr(self, "c", None))

    # -- reading the fleet --------------------------------------------------
    def ent(self, slot, offset, size=1):
        addr = self.sym["ENTITIES"] + slot * ENT_SIZE + offset
        return self.c.read_ram(addr, size)

    def flags(self, slot):
        return self.ent(slot, ENT_FLAGS)[0]

    def position(self, slot):
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        return [int.from_bytes(self.c.read_ram(base + i * 2, 2), "little", signed=True)
                for i in range(3)]

    def closest_pair(self):
        """The nearest friendly/enemy pair, in the units cbt_distance uses.

        Manhattan on coordinates shifted down by WORLD_SHIFT -- the same
        saturating measure the Z80 uses, so the number is comparable with
        CBT_RANGE. The shift has to track WORLD_SHIFT: the world is authored
        four times smaller than it was, and against the old >>8 every ship
        would look four times closer than the game thinks it is.
        """
        friendly = [s for s in range(ENT_MAX) if (self.flags(s) & 3) == F_ACTIVE]
        enemy = [s for s in range(ENT_MAX) if (self.flags(s) & 3) == F_ACTIVE | F_ENEMY]
        if not friendly or not enemy:
            return 255
        return min(min(255, sum(abs(a - b) >> g.WORLD_SHIFT
                                for a, b in zip(self.position(f), self.position(e))))
                   for f in friendly for e in enemy)

    def hull(self, slot):
        return self.ent(slot, ENT_HULL)[0]

    def counts(self):
        """How many ships are FLYING on each side.

        A wreck is not one. slv_make_wreck leaves the hostile that just died
        ACTIVE with DISABLED set, and everything in the game agrees that is out
        of the fight: cbt_find_enemy will not target it, cbt_target_flying
        rejects it, mis_count_enemies masks it out of a CLEAR objective. Every
        enemy death leaves one now -- it used to need a live Salvage Corvette,
        which no fixture here builds, so this counter had never met one and
        "the attackers never killed the enemy they were sent at" was what a
        clean kill looked like from in here.
        """
        friendly = enemy = 0
        for slot in range(ENT_MAX):
            f = self.flags(slot)
            if (f & (F_ACTIVE | F_DISABLED)) != F_ACTIVE:
                continue
            if f & F_ENEMY:
                enemy += 1
            else:
                friendly += 1
        return friendly, enemy

    def shots(self):
        return self.c.read_ram(self.sym["CBT_SHOTS"], 1)[0]

    def kills(self):
        return self.c.read_ram(self.sym["CBT_KILLS"], 1)[0]

    def live_explosions(self):
        base = self.sym["CBT_EXPLOSIONS"]
        return sum(1 for i in range(EXPL_MAX)
                   if self.c.read_ram(base + i * EXPL_SIZE + EXPL_TIMER, 1)[0])

    # -- staging ------------------------------------------------------------
    def order_fleet_to(self, x, y, z):
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", x, y, z))

    def kill_all_enemies(self):
        for slot in range(ENT_MAX):
            if self.flags(slot) & F_ENEMY:
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_FLAGS, b"\x00")


class TestStartingState(CombatFixture):

    def test_both_fleets_are_present(self):
        """How many enemies is the mission's business; that there ARE some is ours."""
        friendly, enemy = self.counts()
        self.assertGreater(friendly, 10, "the player has no fleet")
        self.assertGreater(enemy, 0, "there is nobody to fight")

    def test_nobody_fires_until_someone_has_closed(self):
        """They start out of range, and the Vekhar have to come and get them.

        This used to be "no shots in the first 30 frames", which passed for
        the wrong reason: nothing had a target yet, because retargeting was
        round-robin at one ship a frame and took ENT_MAX frames to reach
        anybody. Once ships re-acquired promptly the picket started closing
        immediately and the battle opened inside those 30 frames -- correctly.
        The invariant worth holding is not a delay, it is that a shot implies
        contact: nobody can fire from where they spawn.
        """
        self.assertEqual(self.shots(), 0, "shots were fired at spawn")
        self.assertEqual(self.kills(), 0)
        self.assertGreater(self.closest_pair(), CBT_RANGE,
                           "the mission spawns the two fleets already in range")

        shots = 0
        for _ in range(90):
            self.c.run_frames(1)
            if self.shots() != shots:
                shots = self.shots()
                self.assertLessEqual(self.closest_pair(), CBT_RANGE,
                                     "a shot was fired with nobody in range")

    def test_nothing_is_ever_aimed_at_its_own_side(self):
        """A zeroed ENT_TARGET names slot 0, not 'nobody'.

        That is the field that made every fresh ship come up aimed at whatever
        was in the first slot. Checking for #FF stopped working once targeting
        stopped being range-limited -- ships now acquire at any distance, so
        by the time a test looks they all have one. The invariant that
        actually matters was always this one.
        """
        for slot in range(ENT_MAX):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            target = self.ent(slot, ENT_TARGET)[0]
            if target == 0xFF:
                continue
            self.assertLess(target, ENT_MAX,
                            f"slot {slot} targets nonexistent {target}")
            mine = self.flags(slot) & F_ENEMY
            theirs = self.flags(target) & F_ENEMY
            self.assertNotEqual(mine, theirs,
                                f"slot {slot} is aimed at slot {target} on its own side")


class TestNoFriendlyFire(CombatFixture):
    """The regression that matters most: the fleet shooting itself."""

    def test_with_no_enemies_alive_nothing_is_ever_fired(self):
        self.kill_all_enemies()
        self.c.write_ram(self.sym["CBT_SHOTS"], b"\x00")
        self.c.write_ram(self.sym["CBT_KILLS"], b"\x00")

        friendly_before, _ = self.counts()
        self.c.run_frames(400)

        self.assertEqual(self.shots(), 0,
                         "shots were fired with no enemy left to shoot at")
        friendly_after, _ = self.counts()
        self.assertEqual(friendly_after, friendly_before,
                         "the fleet lost ships with nobody fighting it")

    def test_a_target_on_your_own_side_is_refused(self):
        """Point a ship at its neighbour by hand and it must still hold fire.

        Checked at the moment of firing, not only when a target is picked: a
        slot index is just a number, and stale or recycled ones name something.
        """
        self.kill_all_enemies()
        self.c.write_ram(self.sym["CBT_SHOTS"], b"\x00")

        #  Slot 0 aims at slot 1, which is in the same formation and so well
        #  inside weapons range.
        self.c.write_ram(self.sym["ENTITIES"] + 0 * ENT_SIZE + ENT_TARGET, b"\x01")
        self.c.write_ram(self.sym["ENTITIES"] + 0 * ENT_SIZE + ENT_TIMER, b"\x00")
        hull_before = self.hull(1)

        self.c.run_frames(120)

        self.assertEqual(self.hull(1), hull_before, "a ship shot its own wingman")
        self.assertEqual(self.shots(), 0)


class TestBattle(CombatFixture):
    """Phase 6's acceptance criterion, driven end to end."""

    def _fight(self, max_frames=1600, until_kills=3):
        self.order_fleet_to(0, 0, 5500)
        for _ in range(max_frames // 40):
            self.c.run_frames(40)
            if self.kills() >= until_kills:
                return True
        return False

    def test_the_fleets_engage_and_ships_die(self):
        self.assertTrue(self._fight(), f"no engagement: {self.shots()} shots, {self.kills()} kills")
        friendly, enemy = self.counts()
        self.assertLess(enemy, 10, "the enemy picket is untouched")
        self.assertGreater(self.shots(), 20)

    def test_a_kill_frees_the_slot_and_updates_the_squadron_counts(self):
        """Parked at scr_wait_vsync first, and it has to be.

        squad_count is DERIVED -- squad_refresh zeroes all nine and counts them
        back up out of the entity table -- so a read taken wherever the
        emulator happened to stop can catch the walk half done and report a
        squadron one ship light. That is the same trap phase4_visible has, and
        the fix is the same: read a finished frame."""
        self._fight()
        h.run_to_stable_point(self.c, self.sym)
        #  ...EXCEPT A WRECK, which is ACTIVE with hull 0 BY CONSTRUCTION:
        #  slv_make_wreck sets DISABLED on the hostile that just died and
        #  leaves ENT_HULL at the zero that brought it there. Every enemy
        #  death leaves one now, up to SLV_WRECK_MAX -- it used to need a live
        #  Salvage Corvette, which no starting fleet has, so this loop had
        #  never met one.
        for slot in range(ENT_MAX):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            if self.flags(slot) & F_DISABLED:
                continue
            self.assertGreater(self.hull(slot), 0, f"slot {slot} is active with no hull")

        #  squad_count is derived, so it has to agree with the table.
        counted = [0] * 10
        for slot in range(ENT_MAX):
            if self.flags(slot) & F_ACTIVE:
                squadron = self.ent(slot, ENT_SQUAD)[0]
                if 1 <= squadron <= 9:
                    counted[squadron] += 1
        live = list(self.c.read_ram(self.sym["SQUAD_COUNT"], 10))
        self.assertEqual(live[1:], counted[1:],
                         "the HUD counts drifted from the entity table after a kill")

    def test_deaths_leave_explosions_that_expire(self):
        self.assertTrue(self._fight(until_kills=1))
        seen = 0
        for _ in range(30):
            self.c.run_frames(8)
            seen = max(seen, self.live_explosions())
        self.assertGreater(seen, 0, "nothing exploded")

        #  Stop the fighting and they must all burn out.
        self.kill_all_enemies()
        self.c.run_frames(200)
        self.assertEqual(self.live_explosions(), 0, "an explosion never expired")

    def test_nobody_ends_up_targeting_a_dead_ship(self):
        self._fight()
        for slot in range(ENT_MAX):
            if not (self.flags(slot) & F_ACTIVE):
                continue
            target = self.ent(slot, ENT_TARGET)[0]
            if target == 0xFF:
                continue
            self.assertLess(target, ENT_MAX)
            self.assertTrue(self.flags(target) & F_ACTIVE,
                            f"slot {slot} is still aiming at dead slot {target}")

    def test_enemies_draw_in_the_enemy_colour(self):
        """Section 2: enemy ships are ink 3, and it costs no extra sprite data.

        Pen 3 is both bit planes set, so an enemy ship puts bits in the LOW
        nibble of a screen byte, which nothing friendly ever does -- friendly
        ships are pens 1 and 2 and the HUD is pen 1.

        Stand the picket somewhere it can actually be seen first. Left where
        it starts it flies straight at the fleet and parks BEHIND it, and the
        painter's algorithm then correctly hides every enemy pixel behind
        sixteen friendly ships -- a blank screen that says nothing about the
        colour of a sprite. Nor is moving it sideways enough on its own: at
        the picket's own depth of z=5000 even a 1750-unit shift is four
        pixels on screen, so it has to come forward as well as across.
        """
        #  Do NOT send the fleet in: it would clear the picket and there
        #  would be nothing left to be the wrong colour. Just stand it above
        #  and beside the fleet, spread out, and look at it.
        placed = 0
        for slot in range(ENT_MAX):
            if self.flags(slot) & F_ENEMY:
                self.c.write_ram(
                    self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_X,
                    struct.pack("<hhh", -1250 + placed * 850, 1000, 750))
                placed += 1
        self.assertGreater(placed, 0, "the mission fielded no enemies to colour")
        self.c.run_frames(40)

        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        pen3 = 0
        for y in range(168):
            for x in range(80):
                byte = ram[h.screen_offset(y, x)]
                #  A pixel is pen 3 when both its planes are set.
                for shift in range(4):
                    if (byte >> (7 - shift)) & 1 and (byte >> (3 - shift)) & 1:
                        pen3 += 1
        self.assertGreater(pen3, 8, "no enemy-coloured pixels anywhere on screen")


class TestConcentration(CombatFixture):
    """A fleet has to be able to bring its guns to bear.

    Both tests here started as one symptom: eight friendly interceptors
    against eight enemy ones, identical hulls and identical guns, ended 8-0
    to the enemy every single time.
    """

    def even_duel(self, order):
        """Eight against eight, same class, same hull, at point-blank.

        Returns (friendly survivors, enemy survivors). Everything is wiped
        first so the mission's own ships cannot join in.

        PARKED AT A STABLE POINT FIRST, and that is not tidiness -- it is the
        difference between measuring the fight and measuring the phase. This
        duel is the knife edge CLAUDE.md describes: identical ships, identical
        guns, decided by which one re-targets on which game frame. TWO emulator
        frames of padding before the ships are placed turns 3-0 to us into 0-3
        to them, measured, with nothing else changed at all -- and the way that
        turned up was the jump reveal being made twice as fast, which shifted
        how many frames the two jumps above this took and flipped the coin.
        run_to_stable_point lands on a frame boundary, so the duel starts at
        the same point in the cycle whatever led up to it.
        """
        h.run_to_stable_point(self.c, self.sym)
        base = self.sym["ENTITIES"]
        for slot in range(ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        def place(slot, enemy, x):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", x, 0, 0))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))          # interceptor
            self.c.write_ram(addr + ENT_HULL, bytes([255]))
            self.c.write_ram(addr + ENT_FLAGS,
                             bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER,
                             bytes([ENT_ORDER_NONE if enemy else order]))
            self.c.write_ram(addr + ENT_TARGET, bytes([255]))

        #  THE HOSTILES GO IN THE HOSTILE REGION, and that is not tidiness.
        #  They used to be slots 8..15, which are the fleet's -- harmless while
        #  cbt_find_enemy swept the whole table and rejected the wrong side on
        #  a compare, and fatal now that it searches the other side's region:
        #  eight enemies nobody could see, and an even duel that ended 8-0
        #  because one side never fired. The partition has said where a hostile
        #  lives since it landed; the tests were simply free to ignore it.
        for i in range(8):
            place(i, False, -1000 + i * 200)
            place(PLAYER_MAX + i, True, 1000 + i * 200)

        #  Station the squadron where it stands, and keep the defeat check off
        #  a slot that is now an interceptor.
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))

        self.c.run_frames(2500)
        #  FLYING, not merely holding a slot. A crippled hull keeps ACTIVE and
        #  is out of the fight -- it does not shoot, is not shot at, and does
        #  not count towards an objective -- so counting it as alive says an
        #  even duel was lost when it was won.
        alive = lambda lo, hi: sum(1 for s in range(lo, hi)
                                   if (self.flags(s) & (F_ACTIVE | F_DISABLED))
                                   == F_ACTIVE)
        return alive(0, 8), alive(PLAYER_MAX, PLAYER_MAX + 8)

    def test_an_attack_order_closes_the_ship_on_its_target(self):
        """`A` used to set a target and nothing else.

        Section 9 lists `A` as "Επίθεση". The ship aimed from wherever its
        formation slot happened to be while the Vekhar -- who always close --
        massed on it, so the order the player reaches for in a fight was the
        one that did the least.
        """
        friendly, enemy = self.even_duel(ENT_ORDER_ATTACK)
        self.assertEqual(enemy, 0, "an attacking squadron failed to finish an even fight")
        self.assertGreater(friendly, 0, "the attackers were wiped out winning it")

    def test_a_ship_re_acquires_the_frame_its_target_dies(self):
        """Otherwise concentrating fire is punished instead of rewarded.

        Ships close together all pick the same nearest enemy, so one kill
        left the whole squadron holding a dead target. Retargeting was
        round-robin at one ship a frame, so they stood idle for up to ENT_MAX
        frames -- while a strung-out enemy, each ship aiming at a different
        target, only ever lost the few that had been aiming at the casualty.
        """
        base = self.sym["ENTITIES"]
        for slot in range(ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        #  One shooter, two enemies stacked on it. Kill the one it is aiming
        #  at and it must pick the other up at once, not in forty frames.
        for i, (enemy, hull) in enumerate([(False, 255), (True, 255), (True, 255)]):
            slot = PLAYER_MAX + i - 1 if enemy else 0
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", i * 200, 0, 0))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))
            self.c.write_ram(addr + ENT_HULL, bytes([hull]))
            self.c.write_ram(addr + ENT_FLAGS,
                             bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER, bytes([ENT_ORDER_NONE]))
            self.c.write_ram(addr + ENT_TARGET, bytes([255]))
        self.c.write_ram(self.sym["SQUAD_DEST"], struct.pack("<hhh", 0, 0, 0))
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))

        self.c.run_frames(60)
        aimed = self.ent(0, ENT_TARGET)[0]
        self.assertIn(aimed, (PLAYER_MAX, PLAYER_MAX + 1),
                      "the shooter never acquired anything")

        #  Take that target away. Re-acquisition happens when the ship is next
        #  ready to shoot, so allow the weapon to come off cooldown. The game
        #  ticks at 12.5fps on a 50Hz machine, so a game frame is FOUR of the
        #  emulator frames run_frames counts -- the cooldown is 24 of them,
        #  and the round-robin sweep this replaces is 192.
        self.c.write_ram(base + aimed * ENT_SIZE + ENT_FLAGS, b"\x00")
        self.c.run_frames((CBT_COOLDOWN + 4) * TICKS_PER_GAME_FRAME)

        other = (PLAYER_MAX + 1) if aimed == PLAYER_MAX else PLAYER_MAX
        self.assertEqual(self.ent(0, ENT_TARGET)[0], other,
                         "the shooter sat idle instead of switching to the survivor")


class TestTheFleetComesHomeWhenTheShootingStops(CombatFixture):
    """An attack order has to be SPENT when there is nothing left to attack.

    phase4_fly skips a ship whose ENT_ORDER is ENT_ORDER_ATTACK on purpose, so
    cbt_move_enemies can close it on its target without the two of them
    stepping it by PHASE4_STEP in opposite directions and cancelling. Nothing
    ever cleared the order, so once the last enemy died the ship was steered by
    nobody: it stopped dead wherever the fight had ended and stayed there for
    the rest of the mission, and fleet_save carried those coordinates into the
    next one.

    Every combat test before this one counts -- shots, kills, hulls, survivors
    -- and a count is precisely what this bug preserves. The right ships die,
    the right number come out, and every one of them is in the wrong place. So
    this follows ships BY SLOT and asks where they are, which is the same net
    the squadron tests had to grow for the same reason.
    """

    #  Far enough out that the two sides meet thousands of units from the
    #  station, so "the fleet never came home" and "the fleet never left" are
    #  not the same measurement -- and no further, because cbt_find_enemy
    #  starts cbt_best_dist at 255 and dist_manhattan SATURATES at 255, so an
    #  enemy more than 255 * 64 = 16320 world units away compares equal to
    #  "nothing found yet" and can never be picked up at all.
    ENEMY_Z = 15000
    #  Loose is a 4x4 lattice at FORM_SPACING on two axes, so the furthest slot
    #  sits 3 * 550 out along each of them: 3300 Manhattan from the station.
    #  Two PHASE4_STEPs of slop on top for a ship still closing.
    FORM_REACH = 3 * 550 * 2 + 2 * 150
    SHIPS = 6

    def stage_one_fight(self, enemy_hull=1):
        """Six attackers on station, one enemy a long way off."""
        base = self.sym["ENTITIES"]
        for slot in range(ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")

        def place(slot, enemy, pos, hull, order):
            addr = base + slot * ENT_SIZE
            self.c.write_ram(addr, struct.pack("<hhh", *pos))
            self.c.write_ram(addr + ENT_CLASS, bytes([0]))          # interceptor
            self.c.write_ram(addr + ENT_HULL, bytes([hull]))
            self.c.write_ram(addr + ENT_FLAGS,
                             bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
            self.c.write_ram(addr + ENT_SQUAD, bytes([255 if enemy else 1]))
            self.c.write_ram(addr + ENT_ORDER, bytes([order]))
            self.c.write_ram(addr + ENT_TARGET, bytes([255]))

        for i in range(self.SHIPS):
            place(i, False, (0, 0, 0), 255, ENT_ORDER_ATTACK)
        #  ...and the one enemy in the hostile region; see even_duel above.
        place(PLAYER_MAX, True, (0, 0, self.ENEMY_Z), enemy_hull, ENT_ORDER_NONE)

        self.order_fleet_to(0, 0, 0)
        #  Keep the defeat check off a slot that is now an ordinary interceptor.
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))
        self.c.run_frames(4)

    def from_station(self, slot):
        """Manhattan distance, in world units, from where the squadron lives."""
        dest = struct.unpack("<hhh", self.c.read_ram(self.sym["SQUAD_DEST"], 6))
        return sum(abs(a - b) for a, b in zip(self.position(slot), dest))

    def friendly_slots(self):
        return [s for s in range(ENT_MAX) if (self.flags(s) & 3) == F_ACTIVE]

    def fight_it_out(self, limit=2000):
        """Run until the enemy is gone. Returns the frame budget left."""
        spent = 0
        while spent < limit:
            self.c.run_frames(40)
            spent += 40
            if self.counts()[1] == 0:
                return limit - spent
        self.fail("the attackers never killed the one enemy they were sent at")

    def test_the_order_is_dropped_when_the_last_target_dies(self):
        """The order itself, before anything that depends on it."""
        self.stage_one_fight()
        crew = self.friendly_slots()
        self.assertEqual(len(crew), self.SHIPS)

        self.fight_it_out()
        #  Re-acquisition happens when a ship is next ready to shoot, so give
        #  every weapon time to come off cooldown. A game frame is four of the
        #  emulator frames run_frames counts.
        self.c.run_frames((CBT_COOLDOWN + 4) * TICKS_PER_GAME_FRAME)

        still_attacking = [s for s in crew
                           if self.ent(s, ENT_ORDER)[0] == ENT_ORDER_ATTACK]
        self.assertEqual(still_attacking, [],
                         f"slots {still_attacking} are still under an attack "
                         f"order with nothing left alive to attack")

    def test_a_ship_that_is_still_attacking_is_left_alone(self):
        """The fix must not undo concentration.

        The order is what makes an attacking squadron close and bring its guns
        to bear; it is the whole reason phase4_fly skips these ships, and
        without it an even eight-against-eight went 8-0 to the Vekhar. So the
        order has to stand for as long as the fight does -- checked every
        twenty frames while the enemy is still flying, rather than once at some
        arbitrary moment that might be after it died.
        """
        self.stage_one_fight(enemy_hull=255)
        crew = self.friendly_slots()

        reached = spent = 0
        while spent < 600:
            self.c.run_frames(20)
            spent += 20
            if self.counts()[1] == 0:
                break                       # it died; the order may go now
            reached = max(reached, max(self.from_station(s) for s in crew))
            dropped = [s for s in crew
                       if self.ent(s, ENT_ORDER)[0] != ENT_ORDER_ATTACK]
            self.assertEqual(dropped, [],
                             f"slots {dropped} were let off their attack order "
                             f"after {spent} frames, with the enemy still flying")

        self.assertGreater(reached, 3000,
                           "the attackers never left the station to engage")

    def test_every_ship_flies_back_to_its_station(self):
        """The one the player would report. Slot by slot, not a count.

        The fleet has to have GONE somewhere first, or "it is at the station"
        is true for the wrong reason -- so the distance at the moment of the
        kill is asserted too.
        """
        self.stage_one_fight()
        crew = self.friendly_slots()
        self.fight_it_out()

        away = {s: self.from_station(s) for s in crew}
        self.assertGreater(min(away.values()), 3000,
                           f"the fight ended next door to the station: {away}")

        #  phase4_fly steps PHASE4_STEP = 150 world units a game frame, so
        #  twelve thousand units is eighty of them and 320 emulator frames.
        self.c.run_frames(900)

        home = {s: self.from_station(s) for s in crew}
        self.assertEqual(sorted(home), sorted(away),
                         "ships went missing on the way home")
        stragglers = {s: d for s, d in home.items() if d > self.FORM_REACH}
        self.assertEqual(stragglers, {},
                         f"slots left stranded where the fight ended: {stragglers} "
                         f"(they were at {away})")


class TestRange(CombatFixture):

    def test_ships_only_fire_once_they_are_close(self):
        self.assertEqual(self.shots(), 0)

        #  Drop the whole fleet on top of the picket rather than flying it
        #  there, so the only variable is distance. The station has to move
        #  with them, or phase4_fly pulls them straight back out of range.
        self.order_fleet_to(0, 0, 5500)
        for slot in range(ENT_MAX):
            if (self.flags(slot) & F_ACTIVE) and not (self.flags(slot) & F_ENEMY):
                self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_X,
                                 struct.pack("<hhh", 0, 0, 5500))
        #  Retargeting is round-robin, one entity a frame, so give it time to
        #  come round to the ships that are now in contact.
        self.c.run_frames(300)
        self.assertGreater(self.shots(), 0, "point blank and still not firing")


class TestBothSidesLookInTheRightPlace(CombatFixture):
    """cbt_find_enemy searches ONE REGION, and it has to be the other one.

    It used to sweep the whole table and reject the wrong side on a compare.
    Searching by region instead is what made a fleet of 56 affordable -- the
    sweep was O(fleet x table), so it grew with the square of the ceiling --
    but it turns a comparison into a DECISION, and a decision can be made
    backwards.

    It was, in the first version of this: the two stores that set cbt_best and
    cbt_best_dist to #FF sit between the side being worked out and the side
    being tested, so the test read #FF and sent every searcher into the hostile
    region. A friendly ship still worked perfectly. An ENEMY looked for the
    player's fleet among the enemies, found nothing, and never fired again --
    and every count in this file would have been happy: the right number of
    ships, all of them alive, in a battle where one side had quietly stopped
    playing. The same blind spot the squadron and the attack-order sections of
    CLAUDE.md record.

    So this asserts on WHICH SLOT each side is aiming at, which is the thing
    the regions are about and the thing a count cannot see.
    """

    def test_each_side_targets_a_slot_in_the_others_region(self):
        player_max = self.sym["ENT_PLAYER_MAX"]
        no_target = 0xFF

        #  Sampled at the FIRST moment both sides are aiming, not after a
        #  fixed 400 frames. It used to be 400 -- long enough for the round-
        #  robin to have reached everybody -- and that was long enough for the
        #  fight to be OVER once a squadron shot at shoots back: the picket
        #  closes, the fleet answers, and by frame 400 mission 3's four
        #  hostiles are wrecks and every attack order has spent itself, so
        #  nobody is aiming at anything. "The game is too slow to have done it
        #  yet" as a precondition, the shape CLAUDE.md records under "Four
        #  tests whose precondition was...".
        def aiming_now():
            aiming = {"ours": [], "theirs": []}
            for slot in range(ENT_MAX):
                flags = self.flags(slot)
                if not flags & F_ACTIVE or flags & F_DISABLED:
                    continue
                target = self.ent(slot, ENT_TARGET)[0]
                if target == no_target:
                    continue
                side = "theirs" if flags & F_ENEMY else "ours"
                aiming[side].append((slot, target))
            return aiming

        for _ in range(40):
            self.c.run_frames(10)
            aiming = aiming_now()
            if aiming["ours"] and aiming["theirs"]:
                break

        self.assertTrue(aiming["ours"], "not one of ours had picked a target")
        self.assertTrue(
            aiming["theirs"],
            "NOT ONE HOSTILE HAD PICKED A TARGET -- cbt_find_enemy is looking "
            "for the player's fleet in the wrong half of the table")

        for slot, target in aiming["ours"]:
            self.assertGreaterEqual(
                target, player_max,
                f"friendly slot {slot} is aiming at {target}, which is one of ours")
        for slot, target in aiming["theirs"]:
            self.assertLess(
                target, player_max,
                f"hostile slot {slot} is aiming at {target}, which is one of theirs")


if __name__ == "__main__":
    unittest.main()


class TestAMovementOrderEndsAnAttackOrder(CombatFixture):
    """Reported as "χάνω τυχαία τον στόλο ... δεν απαντάει στις εντολές".

    phase4_fly skips a ship under ENT_ORDER_ATTACK on purpose, so while the
    order stands `R`, `F` and the move disc are not merely ineffective -- they
    are SILENTLY ineffective. Nothing on screen says so and `G` was the only
    key that ever recalled a squadron.

    Measured against the build this was reported on: one hostile alive at 7500
    units, press `A`, and twelve of sixteen ships fly out to it while four stay
    behind. Neither `R` nor `F` moved either group.
    """

    #  Far enough that the flight out is long and obvious, and inside the range
    #  cbt_distance can still express -- it saturates at 255 camera units, which
    #  is 16320 world units, and past that an enemy is never found at all.
    FAR = 7500

    def keep_a_hostile_alive(self, frames, step=20):
        """Run the game with one distant enemy that cannot be killed.

        The fleet reaches it and would destroy it in seconds otherwise, and
        then the attack order spends itself for the ordinary reason -- which
        is the thing this test must not measure.
        """
        slot = self.sym["ENT_PLAYER_MAX"] + 2
        base = self.sym["ENTITIES"] + slot * ENT_SIZE
        for _ in range(0, frames, step):
            self.c.write_ram(base, struct.pack("<hhh", self.FAR, 0, self.FAR))
            self.c.write_ram(base + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY]))
            self.c.write_ram(base + ENT_HULL, b"\xff")
            self.c.write_ram(base + ENT_CLASS, b"\x00")
            self.c.run_frames(step)

    def fleet_orders(self):
        return [self.ent(s, ENT_ORDER)[0]
                for s in range(self.sym["ENT_PLAYER_MAX"])
                if self.flags(s) & F_ACTIVE]

    def furthest_ship(self):
        return max(max(abs(v) for v in self.position(s))
                   for s in range(self.sym["ENT_PLAYER_MAX"])
                   if self.flags(s) & F_ACTIVE)

    def send_them_out(self):
        self.kill_all_enemies()
        self.keep_a_hostile_alive(40)
        started_within = self.furthest_ship()
        self.c.key_down("a")
        self.keep_a_hostile_alive(25)
        self.c.key_up("a")
        self.keep_a_hostile_alive(60)
        self.assertIn(ENT_ORDER_ATTACK, self.fleet_orders(),
                      "pressing A did not put the squadron under an attack order")
        return started_within

    def press(self, key):
        self.c.key_down(key)
        self.keep_a_hostile_alive(25)
        self.c.key_up(key)
        self.keep_a_hostile_alive(400)

    def test_the_station_key_recalls_a_squadron_that_is_attacking(self):
        home = self.send_them_out()
        self.press("r")
        self.assertNotIn(ENT_ORDER_ATTACK, self.fleet_orders(),
                         "R left the squadron attacking")
        self.assertLess(self.furthest_ship(), home + 1200,
                        "R was obeyed on paper and no ship came home")

    def test_the_formation_key_recalls_a_squadron_that_is_attacking(self):
        home = self.send_them_out()
        self.press("f")
        self.assertNotIn(ENT_ORDER_ATTACK, self.fleet_orders(),
                         "F left the squadron attacking")
        self.assertLess(self.furthest_ship(), home + 1200,
                        "F was obeyed on paper and no ship came home")

    def test_a_harvest_order_survives_a_movement_order(self):
        """The guard that makes this safe, and it is not hypothetical.

        A harvester in the selection carries ENT_ORDER_HARVEST, and an `R`
        that cleared orders unconditionally would send every miner home and
        stop the economy each time the player docked.
        """
        harvest = self.sym["ENT_ORDER_HARVEST"]
        slot = next(s for s in range(self.sym["ENT_PLAYER_MAX"])
                    if self.flags(s) & F_ACTIVE)
        self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_ORDER,
                         bytes([harvest]))
        self.c.key_down("r")
        self.c.run_frames(25)
        self.c.key_up("r")
        self.c.run_frames(30)
        self.assertEqual(self.ent(slot, ENT_ORDER)[0], harvest,
                         "docking took the harvest order off a miner")


class TestTheFleetCannotBeAimedAtItself(CombatFixture):
    """Reported as "χάνει το attack κάποιες φορές. Αντί να επιτίθενται
    κάθονται κάπου τα squadrons και αφήνουν να τα χτυπάνε".

    `,` and `.` walk order_target through every FLYING entity, and the
    player's own fleet is 56 of the 76 slots -- so the target lands on one of
    ours routinely. From the opening ORDER_NO_TARGET it lands on slot 0 on the
    very first press of `.`.

    `A` then writes that friendly index into every ship of the selection, and
    all three things that could steer a ship decline at once:

      - phase4_fly SKIPS a ship under ENT_ORDER_ATTACK, on purpose;
      - cbt_move_enemies finds the target flying and already inside
        CBT_RANGE -- it is in the same formation -- so it holds station;
      - cbt_fire_if_able reaches @cbt_aimed, cbt_hostile says "your own
        side", and it RETURNED there. It never reached @cbt_reacquire, so the
        target was never replaced and the order was never spent.

    cbt_retarget_one will not help either: the target is still flying, so it
    falls through to the ATTACK check and returns early, which is right --
    a target the player chose is not the AI's to overwrite.

    Nothing steers the ship, for the rest of the mission. Measured against the
    build this was reported on: fifteen of sixteen ships never moved once in
    1800 emulator frames, and the fleet was shot from sixteen down to eight
    while it sat there.
    """

    def selection(self):
        return [s for s in range(PLAYER_MAX) if self.flags(s) & F_ACTIVE]

    def stranded(self):
        """Ships under an attack order aimed at one of OUR OWN slots.

        BY SLOT, not a count. Every historical bug in this area was invisible
        to a test that counted ships, kills or shots, because a count is
        exactly what these bugs preserve -- the right number of ships, all of
        them alive, none of them doing anything.
        """
        return [s for s in self.selection()
                if self.ent(s, ENT_ORDER)[0] == ENT_ORDER_ATTACK
                and self.ent(s, ENT_TARGET)[0] < PLAYER_MAX]

    def press(self, key, hold=25, after=40):
        self.c.key_down(key)
        self.c.run_frames(hold)
        self.c.key_up(key)
        self.c.run_frames(after)

    def test_the_target_keys_never_land_on_one_of_our_own_ships(self):
        """The picker is for choosing something to ATTACK.

        Walking it onto the fleet is what let the order be given at all, and
        the first press of `.` from a fresh mission is enough to do it.
        """
        no_target = self.sym["ORDER_NO_TARGET"]
        seen = []
        for _ in range(8):
            self.press(".")
            seen.append(self.c.read_ram(self.sym["ORDER_TARGET"], 1)[0])
        ours = [t for t in seen if t < PLAYER_MAX]
        self.assertEqual(
            ours, [],
            f"`.` stepped the target onto our own slots {ours}; "
            f"the whole walk was {seen} and only >= {PLAYER_MAX} "
            f"(or {no_target}) is a thing to attack")

    def test_pressing_A_after_the_target_keys_does_not_strand_the_squadron(self):
        """The reproduction, through the keys, exactly as reported."""
        self.press(".")
        self.press("a")
        self.c.run_frames(400)
        self.assertEqual(
            self.stranded(), [],
            "slots %s are under an attack order aimed at one of ours; "
            "nothing steers them and nothing ever will"
            % self.stranded())

    def test_a_ship_aimed_at_its_own_side_is_handed_back_to_something(self):
        """The net at the point of use, arranged rather than pressed.

        Deliberately NOT through `,`/`.`: that route is closed now, and a
        guard tested only by the route that used to reach it stops being a
        guard the day another one opens. ENT_TARGET is a slot index, and a
        stale one, a recycled one and a mistaken one all name SOMETHING --
        which is the rule this file already keeps for cbt_hostile.

        The fleet is displaced from its stations first, so "something steers
        it" is a measurement and not a tautology: a ship already standing on
        its station does not move even when it is perfectly healthy.

        THE BOARD IS CLEARED FIRST, and that is what makes the reading
        unambiguous rather than tidy. With a hostile alive there are two
        correct outcomes -- re-acquire it, or spend the order -- and the first
        of them ends with the ship holding station inside CBT_RANGE, which is
        byte-for-byte what being stranded looks like from out here. Worse, the
        first attempt at this test destroyed its own premise: the hostiles
        closed and killed the ship being aimed at, and cbt_kill's forget loop
        then cleared the bad index out of every record for nothing to do with
        the fix. With nothing left to shoot at there is exactly one correct
        answer -- the order is spent and phase4_fly flies them home.
        """
        crew = self.selection()
        self.assertGreater(len(crew), 4, "no fleet to strand")
        self.kill_all_enemies()

        #  Somewhere a long way from every station, but well inside the range
        #  cbt_distance can still express -- it saturates at 255 camera units.
        AWAY = (6000, 0, 6000)
        for s in crew:
            base = self.sym["ENTITIES"] + s * ENT_SIZE
            self.c.write_ram(base, struct.pack("<hhh", *AWAY))
            self.c.write_ram(base + ENT_ORDER, bytes([ENT_ORDER_ATTACK, crew[0]]))
        parked = {s: self.position(s) for s in crew}

        self.c.run_frames(400)

        self.assertEqual(
            self.stranded(), [],
            "slots %s are still aiming at one of ours" % self.stranded())

        #  Ships in a SQUADRON. phase4_fly returns early on ENT_SQUAD 0 --
        #  "unassigned: the Mothership holds station" -- so the base does not
        #  move wherever you put it, and it is the one slot for which staying
        #  put is the correct answer rather than the symptom.
        alive = [s for s in crew
                 if self.flags(s) & F_ACTIVE and self.ent(s, ENT_SQUAD)[0]]
        self.assertGreater(len(alive), 4, "nothing left in a squadron to measure")
        frozen = [s for s in alive if self.position(s) == parked[s]]
        self.assertEqual(
            frozen, [],
            f"slots {frozen} have not moved a unit in 400 frames: "
            "phase4_fly skips them, cbt_move_enemies declines them, "
            "and nothing ever spent the order")


class TestASquadronShotAtShootsBack(CombatFixture):
    """"Aν επιτεθεί εχθρός σε squadron, αμέσως το squadron μπαίνει σε attack
    mode." game/retaliate.asm: the first hit on any ship of a squadron puts
    every IDLE ship in it under ATTACK with the shooter as the target.

    Every assertion is BY SLOT and reads the order and the target, because
    a count of shots or kills is exactly what this feature preserves. The
    fleet's own weapons are held (ENT_TIMER at 255) so the enemy is the only
    thing firing, and what the fleet does in answer is the whole question.
    """

    ENEMY = None  # set per staging: the hostile region's first slot

    def setUp(self):
        #  Mission 1 has no picket, so nothing but what is placed here fires.
        self.c = h.boot_quick(frames=300)

    def place(self, slot, *, enemy=False, pos=(0, 0, 0), squad=1, order=ENT_ORDER_NONE,
              cls=0, target=255, timer=0):
        addr = self.sym["ENTITIES"] + slot * ENT_SIZE
        self.c.write_ram(addr, struct.pack("<hhh", *pos))
        self.c.write_ram(addr + ENT_CLASS, bytes([cls]))
        self.c.write_ram(addr + ENT_HULL, bytes([255]))
        self.c.write_ram(addr + ENT_FLAGS, bytes([F_ACTIVE | F_ENEMY if enemy else F_ACTIVE]))
        self.c.write_ram(addr + ENT_SQUAD, bytes([squad]))
        self.c.write_ram(addr + ENT_ORDER, bytes([order]))
        self.c.write_ram(addr + ENT_TARGET, bytes([target]))
        self.c.write_ram(addr + ENT_TIMER, bytes([timer]))

    def stage(self, victim=0):
        """Four IDLE interceptors of squadron 1 on the origin and one hostile
        in range, aimed at `victim`, ready to fire. Slot 0 stands in for the
        Mothership in the defeat check, as stage_one_fight does."""
        base = self.sym["ENTITIES"]
        for slot in range(ENT_MAX):
            self.c.write_ram(base + slot * ENT_SIZE + ENT_FLAGS, b"\x00")
        for slot in range(4):
            self.place(slot, timer=255)
        self.ENEMY = PLAYER_MAX
        self.place(self.ENEMY, enemy=True, pos=(0, 0, 600), squad=255, target=victim)
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([0]))
        self.c.write_ram(self.sym["ORDER_PAUSED"], b"\x00")

    def order_of(self, slot):
        return self.ent(slot, ENT_ORDER)[0]

    def target_of(self, slot):
        return self.ent(slot, ENT_TARGET)[0]

    def let_the_enemy_shoot(self, frames=60):
        hull0 = self.hull(0)
        self.c.run_frames(frames)
        return hull0

    def test_a_hit_puts_every_idle_ship_of_the_squadron_on_the_shooter(self):
        self.stage(victim=0)
        hull0 = self.let_the_enemy_shoot()
        self.assertLess(self.hull(0), hull0, "the fixture's enemy never fired")
        for slot in range(4):
            self.assertEqual(self.order_of(slot), ENT_ORDER_ATTACK,
                             f"slot {slot} did not answer the attack")
            self.assertEqual(self.target_of(slot), self.ENEMY,
                             f"slot {slot} is aimed at {self.target_of(slot)}, not the shooter")

    def test_working_holding_and_other_squadrons_are_left_alone(self):
        """A harvester keeps mining, a GUARD ship holds, a ship already
        attacking keeps its target, squadron 2 is not squadron 1."""
        self.stage(victim=0)
        HARVEST, GUARD = 4, 3
        self.place(4, order=HARVEST, timer=255)
        self.place(5, order=GUARD, timer=255)
        self.place(6, order=ENT_ORDER_ATTACK, target=7, timer=255)
        self.place(7, squad=2, timer=255)
        self.let_the_enemy_shoot()
        self.assertEqual(self.order_of(0), ENT_ORDER_ATTACK, "the fixture did not fire")
        self.assertEqual((self.order_of(4), self.order_of(5)), (HARVEST, GUARD),
                         "a working or holding ship was pulled into the fight")
        self.assertEqual((self.order_of(6), self.target_of(6)), (ENT_ORDER_ATTACK, 7),
                         "a ship already attacking had its target overwritten")
        self.assertEqual(self.order_of(7), ENT_ORDER_NONE,
                         "another squadron answered an attack on this one")

    def test_the_fleets_own_hits_order_nobody(self):
        """The guard is the SHOOTER'S side. The enemy is given ENT_SQUAD 1
        here on purpose: a build that walked on every hit would read that
        as squadron 1 being attacked and turn the bystander around."""
        self.stage(victim=0)
        self.c.write_ram(self.sym["ENTITIES"] + self.ENEMY * ENT_SIZE + ENT_SQUAD, b"\x01")
        self.c.write_ram(self.sym["ENTITIES"] + self.ENEMY * ENT_SIZE + ENT_TIMER, b"\xff")
        self.place(0, order=ENT_ORDER_ATTACK, target=self.ENEMY)   # ours shoots
        self.place(1, pos=(20000, 0, 0), timer=255)               # the bystander, IDLE, out of range
        shots0 = self.shots()
        self.c.run_frames(60)
        self.assertGreater(self.shots(), shots0, "the fixture's attacker never fired")
        self.assertEqual(self.order_of(1), ENT_ORDER_NONE,
                         "our own hit on the enemy put the squadron on attack")

    def test_a_hit_on_the_mothership_orders_nobody(self):
        """The Mothership is not a squadron; the fleet defends it by being
        stationed on it, not by every ship leaving station when it is hit."""
        self.stage(victim=7)
        self.place(7, cls=1, squad=0, timer=255)     # the Mothership, SQUAD_NONE
        self.c.write_ram(self.sym["MOTH_SLOT"], bytes([7]))
        hull7 = self.hull(7)
        self.c.run_frames(60)
        self.assertLess(self.hull(7), hull7, "the fixture's enemy never fired")
        for slot in range(4):
            self.assertEqual(self.order_of(slot), ENT_ORDER_NONE,
                             f"slot {slot} left station over a hit on the Mothership")
        self.assertEqual(self.order_of(7), ENT_ORDER_NONE)

    def test_the_squadron_then_comes_home_when_the_shooter_is_dead(self):
        """The order is the ordinary attack order, so it spends itself."""
        self.stage(victim=0)
        for slot in range(4):
            self.c.write_ram(self.sym["ENTITIES"] + slot * ENT_SIZE + ENT_TIMER, b"\x00")
        self.c.write_ram(self.sym["ENTITIES"] + self.ENEMY * ENT_SIZE + ENT_HULL, b"\x30")
        for _ in range(60):
            self.c.run_frames(10)
            if self.counts()[1] == 0:
                break
        else:
            self.fail("the squadron never killed the one ship that shot it")
        self.c.run_frames(40)
        self.assertEqual([self.order_of(s) for s in range(4)], [ENT_ORDER_NONE] * 4,
                         "the retaliation order outlived its target")
