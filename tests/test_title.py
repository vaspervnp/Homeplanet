"""The screen the game opens on.

HOMEPLANET across the full width, a starfield, a flight of ships, and the
credit line. Most of what is worth pinning here is the width: the title is
sized to the screen rather than centred on it, so ten glyphs at eight bytes
IS the eighty-byte line, and nothing in the drawing does any arithmetic to
make that true.

Everything the title owns lives in bank 4 -- the code as well as the strings,
because it runs once before the first mission and has no business competing
for the low 16K with the frame loop. So it is read through read_cpu here;
read_ram would hand back bank 1.
"""

from __future__ import annotations

import sys
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness as h
import cpc

SCR_BYTES_PER_LINE = 80
TXT_BIG_W_BYTES = 8
TITLE_Y = 20
TITLE_H = 32
CREDIT_Y = 186
PROMPT_Y = 160
HUD_TOP = h.symbols()["HUD_TOP"]


class TitleFixture(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.sym = h.symbols()

    def setUp(self):
        #  briefing=True: the harness would otherwise press ENTER past both
        #  this and the briefing behind it before the test got a look.
        self.c = h.boot_quick(frames=400, briefing=True)

    def tearDown(self):
        h.close(getattr(self, "c", None))

    def banked(self, name, size=1):
        return h.read_bank4(self.c, self.sym[name], size)

    def string(self, name, limit=40):
        raw = self.banked(name, limit)
        return raw.split(b"\x00")[0]

    def row_ink(self, y):
        """Lit pixels on one scanline of the visible screen."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        return sum(bin(ram[h.screen_offset(y, x)]).count("1") for x in range(80))


class TestItIsUpAtTheStart(TitleFixture):

    def test_the_game_opens_on_it(self):
        self.assertEqual(self.banked("TITLE_SHOWN")[0], 1,
                         "the game did not open on the title screen")

    def test_space_starts_the_game(self):
        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(25)
        self.c.key_up(cpc.KEY_SPACE)
        self.c.run_frames(30)
        self.assertEqual(self.banked("TITLE_SHOWN")[0], 0, "SPACE did not start the game")
        #  And what it hands over to is the first mission's briefing, which
        #  mis_init opened behind it before the player ever saw this screen.
        self.assertEqual(self.c.read_ram(self.sym["MIS_BRIEFING"], 1)[0], 1,
                         "the title did not hand over to the briefing")

    def test_nothing_simulates_behind_it(self):
        base = self.sym["ENTITIES"]
        before = [self.c.read_ram(base + s * 20, 6) for s in range(self.sym['ENT_MAX'])]
        self.c.run_frames(200)
        after = [self.c.read_ram(base + s * 20, 6) for s in range(self.sym['ENT_MAX'])]
        self.assertEqual(after, before, "the fleet was flying behind the title screen")


class TestTheWords(TitleFixture):

    def test_the_title_is_exactly_the_width_of_the_screen(self):
        """The reason the game is called a ten-letter word on this screen.

        src/main.asm asserts this at build time too; here it is measured on
        the machine, because the build-time version only checks the string
        and this checks what was drawn.
        """
        title = self.string("TITLE_TEXT")
        self.assertEqual(len(title) * TXT_BIG_W_BYTES, SCR_BYTES_PER_LINE,
                         f"{title!r} is not eighty bytes of glyphs")

        #  The tenth glyph has to be in the tenth cell, which starts at byte
        #  72. Not the last byte column: the font's face is five pixels in an
        #  eight-pixel cell, so every glyph carries three columns of tracking
        #  and the last three bytes of the line are blank by construction. The
        #  title is flush left and ends a tracking-width short of the right,
        #  which is what "spans the screen" means for this font.
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)

        def band_ink(column):
            return sum(bin(ram[h.screen_offset(y, column)]).count("1")
                       for y in range(TITLE_Y, TITLE_Y + TITLE_H))

        self.assertGreater(band_ink(0), 0,
                           "byte column 0 is blank -- the title is not flush left")
        last_cell = SCR_BYTES_PER_LINE - TXT_BIG_W_BYTES        # 72
        self.assertGreater(sum(band_ink(c) for c in range(last_cell, last_cell + 5)), 0,
                           "the last glyph is not in the last cell -- the title fell short")
        self.assertEqual(sum(band_ink(c) for c in range(last_cell + 5, SCR_BYTES_PER_LINE)), 0,
                         "something is drawn in the last glyph's tracking")

    def test_the_credit_line_is_there_and_centred(self):
        credit = self.string("TITLE_CREDIT")
        self.assertEqual(credit, b"REVIVE8BIT - 2026 - VASPER")

        #  Two bytes a glyph, and what is left over is split evenly.
        margin = (SCR_BYTES_PER_LINE - len(credit) * 2) // 2
        self.assertEqual(self.sym["TITLE_CREDIT_X"], margin,
                         "the credit line is not centred")

    def test_the_prompt_says_which_key(self):
        """A title screen that does not say how to leave it is a dead end."""
        self.assertEqual(self.string("TITLE_PROMPT"), b"PRESS SPACE TO START")
        margin = (SCR_BYTES_PER_LINE - len(b"PRESS SPACE TO START") * 2) // 2
        self.assertEqual(self.sym["TITLE_PROMPT_X"], margin,
                         "the prompt is not centred")

    def test_the_prompt_blinks(self):
        """It is drawn on some frames and not others, which on a screen that
        repaints in full every frame is all a blink needs to be."""
        seen = set()
        for _ in range(40):
            self.c.run_frames(4)
            seen.add(self.row_ink(PROMPT_Y + 3) > 10)
            if len(seen) == 2:
                return
        self.fail(f"the prompt never changed state: always {'on' if True in seen else 'off'}")

    def test_the_credit_sits_below_the_ships_at_the_bottom(self):
        self.assertGreater(CREDIT_Y, 160, "the credit line is not near the bottom")
        self.assertGreater(self.row_ink(CREDIT_Y + 3), 20,
                           "nothing is drawn on the credit line")


class TestTheGraphics(TitleFixture):

    def test_there_are_stars_and_ships(self):
        """Pen 2 is stars, pen 1 is hulls and letters -- the palette is
        semantic, so counting pens says what is actually on screen."""
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        pens = {}
        #  Below the title band, so the letters cannot be mistaken for ships.
        for y in range(TITLE_Y + TITLE_H, CREDIT_Y - 8):
            for x in range(80):
                byte = ram[h.screen_offset(y, x)]
                for shift in range(4):
                    pen = ((byte >> (7 - shift)) & 1) | (((byte >> (3 - shift)) & 1) << 1)
                    pens[pen] = pens.get(pen, 0) + 1

        self.assertGreater(pens.get(2, 0), 20, "no starfield")
        self.assertGreater(pens.get(1, 0), 60, "no ships")

    def test_it_is_repainted_every_frame(self):
        """The display page-flips, so a screen painted once alternates with
        whatever the other buffer still holds -- the title would strobe."""
        first = self.row_ink(TITLE_Y + 16)
        self.assertGreater(first, 0)
        for _ in range(6):
            self.c.run_frames(1)
            self.assertGreater(self.row_ink(TITLE_Y + 16), 0,
                               "the title flickered -- one buffer has it and the other does not")


class TestThePlanet(TitleFixture):
    """The game is named after it, and now it is on the screen.

    A dark disc with a lit limb, in ink 2, between the starfield and the
    flight -- so the ships cross in front of it and the stars do not show
    through it.
    """

    def geometry(self):
        s = self.sym
        return (s["TITLE_PLANET_CX"], s["TITLE_PLANET_CY"],
                s["TITLE_PLANET_RX"], s["TITLE_PLANET_RY"])

    def pen_at(self, ram, x, y):
        byte = ram[h.screen_offset(y, x >> 2)]
        shift = x & 3
        return ((byte >> (7 - shift)) & 1) | (((byte >> (3 - shift)) & 1) << 1)

    def test_the_half_width_table_is_the_ellipse_it_claims_to_be(self):
        """hw[dy] = round(RX * sqrt(1 - (dy / RY)^2)), re-derived.

        The table is hand-written -- thirty-five bytes, which is less than a
        third generated file would cost to carry -- so the formula in the
        comment above it is the specification and this is what holds the two
        together. Same arrangement as gen/tables.asm, which the tests also
        re-derive from tools/gentables.py rather than trust.
        """
        import math
        _, _, rx, ry = self.geometry()
        table = self.banked("TITLE_PLANET_HW", ry + 1)
        want = [round(rx * math.sqrt(max(0.0, 1 - (dy / ry) ** 2)))
                for dy in range(ry + 1)]
        self.assertEqual(list(table), want)
        self.assertEqual(table[0], rx, "the equator is not the full radius")
        self.assertEqual(table[ry], 0, "the pole is not a point")

    def test_it_is_a_disc_of_the_right_size_in_the_right_ink(self):
        """Read off the screen, along the equator and down the meridian.

        Not a pixel count: a starfield has plenty of ink 2 in it. The claim is
        that the two extreme points of the ellipse are lit and that four
        pixels beyond each of them is not -- which is a statement about a
        SHAPE, and the stars cannot satisfy it by accident because the disc's
        own interior is blacked before it is drawn.
        """
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)

        for x in (cx - rx, cx + rx):
            self.assertEqual(self.pen_at(ram, x, cy), 2,
                             f"the limb is not lit at x={x} on the equator")
        for y in (cy - ry, cy + ry):
            self.assertEqual(self.pen_at(ram, cx, y), 2,
                             f"the limb is not lit at y={y} on the meridian")

        #  ...and it stops. Four pixels out is outside the disc on every one
        #  of the four, and the fill rounds outward, so anything lit there is
        #  the planet spilling rather than a star: the black spill has just
        #  cleared the stars from exactly that band.
        for x in (cx - rx - 4, cx + rx + 4):
            self.assertEqual(self.pen_at(ram, x, cy), 0,
                             f"something is lit outside the limb at x={x}")

    def test_the_stars_do_not_show_through_it(self):
        """A planet you can see through is not a planet.

        WHAT THIS TEST IS AND IS NOT WORTH, because the difference matters.
        The starfield is forty stars over the whole 320x200 screen, laid down
        by a xorshift from a fixed seed -- so it is deterministic, but it is
        also SPARSE: about three and a half stars fall inside the disc and
        about a tenth of one inside the three-pixel band an inward-rounded
        fill would leave against the limb. Rounding the night side inward and
        running this does NOT fail, and that was checked rather than assumed.

        So this is a regression net over the whole night side -- it would
        catch the fill being dropped, mispositioned or made too small, which
        are the ways this actually breaks -- and it is not evidence for the
        outward rounding, which is argued on its own terms in
        title_planet_fill: black outside the disc is free, so spilling costs
        nothing and removes a whole class of luck.

        The starlight that WAS on the screen and was fixed is on the day side,
        between the lit fill and the limb, and test_it_is_a_disc... covers the
        run that closes it.

        Sampled well inside the night side, where the day side's ink cannot
        reach: the terminator is at cx + hw/2, so everything past it on a row
        is night.

        IT ASKS ABOUT INK 2 AND NOT ABOUT LIT PIXELS, and that is not a
        loosening -- it is the difference between the two things that can be
        there. A star is ink 2 and must not be; a SHIP is ink 1 and must,
        because the flight is drawn over the planet on purpose. The first
        version of this asked for black and failed on the interceptor at
        (275, 127), which is the picture being right.

        ...and then a SHIP'S OWN SHADING is ink 2 as well -- section 2 gives
        that ink to the stars, the grid and the shading alike -- so the flight
        has to be cut out of the sample rather than argued away by a pen
        number. The boxes come out of title_ship_table, so the day the flight
        is rearranged this follows it instead of failing.
        """
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        table = self.banked("TITLE_PLANET_HW", ry + 1)
        ships = self.ship_boxes()

        looked = 0
        for dy in range(0, ry - 6):
            hw = table[dy]
            #  From past the terminator up to the pixel BEFORE the limb -- the
            #  limb itself is ink 2 and is meant to be. Right up to it, and not
            #  two pixels short: an inward-rounded fill leaves its starlight in
            #  exactly the last three pixels of the row, so a sample that
            #  avoids them cannot see the thing this is about.
            lo, hi = cx + (hw >> 1) + 5, cx + hw
            if hi <= lo:
                continue
            for y in (cy - dy, cy + dy):
                for x in range(lo, hi):
                    if any(x0 <= x < x1 and y0 <= y < y1
                           for x0, y0, x1, y1 in ships):
                        continue
                    self.assertNotEqual(
                        self.pen_at(ram, x, y), 2,
                        f"({x}, {y}) is ink 2 inside the planet's night side: "
                        "a star is showing through")
                    looked += 1
        self.assertGreater(looked, 200, "the night side was never sampled")

    def ship_boxes(self):
        """Where the flight is, out of title_ship_table in bank 4.

        Eight bytes an entry: x in BYTE columns as a signed word, y, the
        sprite, its width in bytes, its height, and its bank.
        """
        n = self.sym["TITLE_SHIPS"]
        raw = self.banked("TITLE_SHIP_TABLE", n * 8)
        out = []
        for i in range(n):
            e = raw[i * 8:i * 8 + 8]
            x = int.from_bytes(e[0:2], "little", signed=True) * 4
            y, w, hgt = e[2], e[5] * 4, e[6]
            out.append((x, y, x + w, y + hgt))
        return out

    def test_the_day_side_is_solid_right_up_to_the_limb(self):
        """No gap between the lit face and the edge of the world.

        THIS IS THE ONE THAT WAS ON THE SCREEN. The day side's fill stops at
        the last whole byte inside the disc -- it must, because three pixels of
        blue OUTSIDE the limb is three pixels of ragged silhouette -- so it
        leaves nought to three pixels of nothing between itself and the limb,
        and what showed through them was black and the odd star. The planet
        read as a ring standing off a slightly-too-small disc. The run at the
        end of title_planet_rim fills them, and this is what says so: it fails
        with that run removed, which was checked.

        Every pixel from the limb inward to short of the terminator, so the
        byte-quantised terminator itself is never the thing under test.
        """
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        table = self.banked("TITLE_PLANET_HW", ry + 1)
        ships = self.ship_boxes()

        looked = 0
        for dy in range(0, ry - 6):
            hw = table[dy]
            lo, hi = cx - hw, cx + (hw >> 1) - 2
            if hi <= lo:
                continue
            for y in (cy - dy, cy + dy):
                for x in range(lo, hi):
                    if any(x0 <= x < x1 and y0 <= y < y1
                           for x0, y0, x1, y1 in ships):
                        continue
                    self.assertEqual(
                        self.pen_at(ram, x, y), 2,
                        f"({x}, {y}) is not lit on the planet's day side: "
                        "there is a hole between the fill and the limb")
                    looked += 1
        self.assertGreater(looked, 400, "the day side was never sampled")

    def test_the_flight_crosses_in_front_of_it(self):
        """Drawn between the stars and the ships, and the order is the point.

        After the stars because it blacks its own interior and has to take the
        ones inside it; before the ships so a hull is never rubbed out by the
        world behind it. Ink 1 inside the disc is a ship, because nothing else
        on this screen is ink 1 below the big letters.
        """
        cx, cy, rx, ry = self.geometry()
        ram = self.c.read_ram(h.front_buffer(self.c), 0x4000)
        hull = sum(1
                   for y in range(cy - ry, cy + ry + 1)
                   for x in range(cx - rx, cx + rx + 1)
                   if self.pen_at(ram, x, y) == 1)
        self.assertGreater(hull, 20,
                           "no ship is drawn over the planet -- either the "
                           "flight moved off it or the planet is drawn last")


class TestWhatItLeavesBehind(TitleFixture):
    """SPACE goes on to the first briefing, and nothing of this screen may
    survive under it.

    Reported as "στο κείμενο της πρώτης πίστας μένει από κάτω μέρος κειμένων
    του μενού" -- and what was down there is this screen's own last two lines,
    T FOR THE TUTORIAL at 172 and the credit at 186. Both sit in the strip the
    HUD normally owns, and a briefing's static_wipe deliberately stops short of
    it: every OTHER time a briefing is up, the fleet counts are down there and
    they are what the player is about to give an order about. The first time,
    nothing was ever going to take the title's lines off -- the HUD does not
    clear its strip, it draws labels onto it.

    title_key has always scheduled the wipe for exactly this and says so in a
    comment. What was missing is that mis_wipe_screen is called from
    demo_update's PLAYING path only, and the briefing goes up before the game
    reaches it, so the two frames sat unspent. mis_brief_draw spends them now.
    """

    def test_the_first_briefing_has_nothing_of_the_title_under_it(self):
        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(10)
        self.c.key_up(cpc.KEY_SPACE)
        for _ in range(120):
            #  read_ram, not read_bank4: mis_briefing is one of the bytes that
            #  deliberately stayed in the low 16K, and the test above reads it
            #  the same way.
            if self.c.read_ram(self.sym["MIS_BRIEFING"], 1)[0]:
                break
            self.c.run_frames(1)
        else:
            self.fail("SPACE did not open the first briefing")
        self.c.run_frames(200)

        #  BOTH buffers, and it has to be: the display page-flips, so a line
        #  cleared out of one and left in the other is on screen every other
        #  frame -- which is what this looked like on the machine.
        for base in (0x8000, 0xC000):
            ram = self.c.read_ram(base, 0x4000)
            lit = [y for y in range(HUD_TOP, 200)
                   if any(ram[h.screen_offset(y, x)] for x in range(80))]
            self.assertFalse(
                lit, f"buffer {base:#06x} is still carrying the title screen's "
                     f"last lines at {lit} under the first briefing")

    def test_and_the_briefing_is_gone_from_BOTH_buffers_once_it_is_dismissed(self):
        """The other end of the same debt, and the bug the fix above caused.

        A page closes by clearing its own flag inside its `_key` routine, and
        demo_update then draws it ONE MORE TIME in the same frame. So a
        mis_wipe_screen call placed in mis_brief_draw without a guard spends
        one of the two frames mis_brief_key has just scheduled for erasing the
        briefing itself -- one buffer is cleared, the other is not, and the
        display page-flips. The mission text was then on screen every OTHER
        frame for the rest of the mission: "αναβοσβήνει συνέχεια μπροστά".

        READING ONE BUFFER CANNOT SEE THIS AT ALL, which is why it is worth a
        test of its own rather than a line in the one above. Whichever buffer
        happened to be in front would look perfect half the time.
        """
        self.c.key_down(cpc.KEY_SPACE)
        self.c.run_frames(10)
        self.c.key_up(cpc.KEY_SPACE)
        for _ in range(120):
            if self.c.read_ram(self.sym["MIS_BRIEFING"], 1)[0]:
                break
            self.c.run_frames(1)
        self.c.run_frames(120)

        self.c.key_down(cpc.KEY_ENTER)
        self.c.run_frames(6)
        self.c.key_up(cpc.KEY_ENTER)
        self.c.run_frames(400)

        #  The briefing's own body rows. The tactical view draws there too, so
        #  this compares the two buffers against EACH OTHER rather than against
        #  zero: a fleet is in both, three lines of text are in one.
        top = self.sym["BRIEF_TEXT_Y"]
        counts = {}
        for base in (0x8000, 0xC000):
            ram = self.c.read_ram(base, 0x4000)
            counts[base] = sum(1 for y in range(top, top + 30)
                               for x in range(80)
                               if ram[h.screen_offset(y, x)])
        lo, hi = min(counts.values()), max(counts.values())
        self.assertLess(
            hi, lo + 200,
            f"one buffer is carrying far more than the other ({counts}): the "
            "briefing was wiped out of one of them and left in the other, so "
            "it is on screen every other frame")


class TestTheMusic(TitleFixture):
    """A tune on the menu screen and nowhere else.

    src/sys/music.asm was written a long time ago and deliberately left out of
    the build: it did not fit. It does now -- see todo.md section 2, which is
    the plan this follows line for line.

    IT WRITES NO PSG REGISTER AT ALL. snd_update owns the AY, runs from the
    50 Hz interrupt, rebuilds the mixer every tick and mutes every idle
    channel, so a second writer would be silenced within a tick whatever it
    wrote. The player fills the three VOICE BLOCKS instead -- a held note is
    already expressible as one -- and lets snd_update do what it always does.
    """

    def on(self):
        return self.c.read_ram(self.sym["SND_MUSIC_ON"], 1)[0]

    def streams(self):
        """Where the three note streams have got to."""
        return tuple(
            int.from_bytes(self.c.read_ram(self.sym[n], 2), "little")
            for n in ("MUS_V0", "MUS_V1", "MUS_V2"))

    def tap(self, key, frames=30):
        self.c.key_down(key)
        self.c.run_frames(frames)
        self.c.key_up(key)
        self.c.run_frames(frames)

    def test_it_plays_without_being_asked(self):
        """A tune nobody has turned on is a tune nobody knows is there. `M` is
        for the player who wants the silence back."""
        self.assertEqual(self.on(), 1, "the title screen came up silent")

    def test_the_streams_advance(self):
        """Not "a flag is set" -- the three note streams have to MOVE.

        Read out of RAM rather than off the chip, and that is not a shortcut:
        test_music's read_psg begins with DI and ends with HALT, so the first
        call leaves interrupts off for good. Sampling the AY in a loop measures
        a machine whose keyboard and 50 Hz counter have both stopped, which is
        exactly what it looked like the first time -- a tune that would not
        advance and an M that did nothing.
        """
        seen = set()
        for _ in range(40):
            seen.add(self.streams())
            self.c.run_frames(25)
        self.assertGreater(len(seen), 4,
                           f"the streams barely moved in twenty seconds: {seen}")

    def test_M_silences_it_and_brings_it_back(self):
        self.tap("m")
        self.assertEqual(self.on(), 0, "M did not silence the music")
        self.tap("m")
        self.assertEqual(self.on(), 1, "M did not bring it back")

    def test_M_does_not_leave_the_screen(self):
        """It is the only one of the three keys that toggles and falls
        through, so a player can silence the tune and go on reading."""
        self.tap("m")
        self.assertEqual(self.banked("TITLE_SHOWN")[0], 1,
                         "M started the game")

    def test_the_game_gets_the_tune_too_but_on_one_voice(self):
        """It used to stop dead at SPACE, and these two tests said so -- "the
        music followed the fleet into the game" was the failure message. The
        game has it now, on channel C alone: A and B are the shots and the
        explosions, and C is what section 12 keeps for alerts and the jump.
        """
        self.tap(cpc.KEY_SPACE, frames=25)
        self.c.run_frames(60)
        self.assertEqual(self.on(), 1, "the game came up silent")
        self.assertEqual(self.c.read_ram(self.sym["MUS_SOLO"], 1)[0], 1,
                         "the game is running the menu's three-voice mode")

    def test_and_the_tutorial_does_too(self):
        self.tap("t", frames=25)
        self.c.run_frames(60)
        self.assertEqual(self.c.read_ram(self.sym["MUS_SOLO"], 1)[0], 1,
                         "the tutorial kept the menu's three-voice mode")

    def test_a_mute_on_the_menu_survives_into_the_game(self):
        """One key with one meaning, and one ANSWER: a player who asked for
        silence on the menu must not have it come back when a mission starts.
        That is why mus_muted is a separate byte from snd_music_on -- the
        second is "is a tune filling voice blocks right now", which every
        screen change rewrites."""
        self.tap("m")
        self.assertEqual(self.on(), 0)
        self.tap(cpc.KEY_SPACE, frames=25)
        self.c.run_frames(60)
        self.assertEqual(self.on(), 0,
                         "the music came back by itself when the game started")

    def test_channel_B_is_a_tone_voice_while_the_music_has_it(self):
        """The ONE change in sound.asm, and the subtle one.

        Section 12 gives B to the noise generator -- explosions and hull breach
        -- and that assignment lives in snd_mix_mask. The tune has no
        percussion, so with the noise bit open its harmony comes out as a hiss.
        While snd_music_on is set the loop takes the other table.

        read_psg LAST and once: it takes the CPU away and leaves interrupts
        off, so anything measured after it is measuring a stopped machine.
        """
        from tests.test_music import read_psg
        self.c.run_frames(60)
        mixer = read_psg(self.c)[7]
        #  Bits 0-2 are tone A/B/C off, 3-5 are noise A/B/C off.
        self.assertEqual(mixer & 0b111, 0,
                         f"a tone channel is muted: R7 = {mixer:08b}")
        self.assertEqual(mixer & 0b111000, 0b111000,
                         f"the noise generator is open: R7 = {mixer:08b}")


if __name__ == "__main__":
    unittest.main()
