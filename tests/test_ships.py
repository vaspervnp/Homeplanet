"""Tests for the ship-sprite generator.

The generator is a renderer, so most of what it produces can only be judged by
looking at it -- `python3 tools/mkships.py --contact-sheet`, then open the
PNGs. What can be tested is everything that has to be true before looking is
worth doing, and in particular the two failure modes that are invisible in a
contact sheet but fatal on a CPC:

  * a pen 0 pixel inside the silhouette. Pen 0 is empty space in this game's
    palette, so a hull pixel that is pen 0 punches a hole in the ship that you
    will only notice when a star shines through it.
  * a silhouette that has fallen into pieces, so the blitter draws two loose
    blocks with a gap between them.

The blit itself is checked the same way tests/test_sprites.py checks it: run
the bytes through the emulator's own Mode 1 decoder and simulate
`screen = (screen AND mask) OR data`.
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from tests import harness  # noqa: E402,F401  (puts cpc.py on the path)
import cpc  # noqa: E402
from tools import mkships, rt2sprite  # noqa: E402


def frame_grid(sprite, frame):
    """(pens, mask) as [y][x] grids of ints."""
    w, h = sprite["width"], sprite["height"]
    pens = base64.b64decode(frame["pixels"])
    mask = base64.b64decode(frame["mask"])
    return ([list(pens[y * w:(y + 1) * w]) for y in range(h)],
            [list(mask[y * w:(y + 1) * w]) for y in range(h)])


def components(mask):
    """8-connected blobs in a mask grid, as a list of pixel counts."""
    h, w = len(mask), len(mask[0])
    seen = [[False] * w for _ in range(h)]
    sizes = []
    for y in range(h):
        for x in range(w):
            if not mask[y][x] or seen[y][x]:
                continue
            stack, n = [(x, y)], 0
            seen[y][x] = True
            while stack:
                bx, by = stack.pop()
                n += 1
                for dx, dy in mkships.NEIGHBOURS_8:
                    nx, ny = bx + dx, by + dy
                    if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            sizes.append(n)
    return sizes


class ShipProjects(unittest.TestCase):
    """Shared base: render every class for both factions exactly once.

    Rendering is a couple of seconds for the lot, which is fine once and not
    fine per test method.
    """

    docs: dict = {}

    @classmethod
    def setUpClass(cls):
        if ShipProjects.docs:
            return
        for key in mkships.SHIPS:
            for faction in mkships.FACTION_PEN:
                ShipProjects.docs[(key, faction)] = mkships.build_project(key, faction)

    def friendly(self):
        for key in sorted(mkships.SHIPS):
            yield key, self.docs[(key, "friendly")]

    def every(self):
        for (key, faction), doc in sorted(self.docs.items()):
            yield key, faction, doc


class TestTiers(unittest.TestCase):

    def test_every_tier_width_is_a_multiple_of_four(self):
        """Mode 1 packs 4 pixels per byte and rt2sprite refuses anything else."""
        for tier in mkships.TIERS:
            self.assertEqual(tier.w % 4, 0, f"tier {tier.key} is {tier.w} wide")

    def test_tiers_are_the_sizes_the_design_document_specifies(self):
        self.assertEqual([(t.key, t.w, t.h) for t in mkships.TIERS],
                         [("a", 8, 6), ("b", 16, 10), ("c", 24, 16)])

    def test_a_bad_tier_width_is_rejected_at_construction(self):
        with self.assertRaises(ValueError):
            mkships.Tier("x", 6, 6, coverage=0.5, contrast=1.0, gamma=1.0)


class TestProjectShape(ShipProjects):

    def test_one_sprite_per_tier_at_the_declared_size(self):
        for key, faction, doc in self.every():
            self.assertEqual(len(doc["sprites"]), len(mkships.TIERS), key)
            for tier, sprite in zip(mkships.TIERS, doc["sprites"]):
                where = f"{key}/{faction} tier {tier.key}"
                self.assertEqual(sprite["width"], tier.w, where)
                self.assertEqual(sprite["height"], tier.h, where)
                self.assertTrue(sprite["hasMask"], where)
                self.assertEqual(len(sprite["frames"]), mkships.YAW_STEPS, where)
                self.assertEqual([f["index"] for f in sprite["frames"]],
                                 list(range(mkships.YAW_STEPS)), where)

    def test_buffers_are_exactly_one_byte_per_pixel(self):
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                want = sprite["width"] * sprite["height"]
                for frame in sprite["frames"]:
                    for field in ("pixels", "mask"):
                        self.assertEqual(len(base64.b64decode(frame[field])), want,
                                         f"{sprite['name']} frame {frame['index']} {field}")

    def test_sprite_names_are_usable_as_assembler_labels(self):
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                self.assertEqual(rt2sprite.identifier(sprite["name"]), sprite["name"])

    def test_the_eight_yaw_views_are_actually_different(self):
        """A rotation bug would give eight identical frames and still pass
        every other test in this file."""
        for key, doc in self.friendly():
            for sprite in doc["sprites"]:
                blobs = {f["pixels"] for f in sprite["frames"]}
                self.assertGreaterEqual(len(blobs), 6,
                                        f"{sprite['name']}: only {len(blobs)} distinct views")

    def test_rendering_is_deterministic(self):
        again = mkships.build_project("interceptor", "friendly")
        self.assertEqual(again, self.docs[("interceptor", "friendly")])

    def test_pitch_levels_are_a_parameter_not_a_rewrite(self):
        """Section 5.1's second pitch level has to be one tuple away."""
        doc = mkships.build_project("interceptor", "friendly",
                                    tiers=[mkships.TIERS[0]],
                                    pitch_angles=(0.0, -30.0))
        frames = doc["sprites"][0]["frames"]
        self.assertEqual(len(frames), 2 * mkships.YAW_STEPS)
        # Frame index is (pitch * yaw_steps + yaw), so the level-0 frames must
        # still be the same frames at the same indices.
        flat = self.docs[("interceptor", "friendly")]["sprites"][0]["frames"]
        self.assertEqual([f["pixels"] for f in frames[:mkships.YAW_STEPS]],
                         [f["pixels"] for f in flat])


class TestPalette(ShipProjects):

    def test_the_project_palette_is_the_games(self):
        for key, faction, doc in self.every():
            self.assertEqual(rt2sprite.check_palette(doc, strict=True), [],
                             f"{key}/{faction}")

    def test_pen_0_never_appears_inside_a_silhouette(self):
        """Pen 0 is empty space. A pen 0 pixel under an opaque mask bit is a
        hole in the hull that the background will shine through."""
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    pens, mask = frame_grid(sprite, frame)
                    for y, row in enumerate(mask):
                        for x, opaque in enumerate(row):
                            if opaque:
                                self.assertNotEqual(
                                    pens[y][x], mkships.PEN_SPACE,
                                    f"{sprite['name']} frame {frame['index']}: "
                                    f"pen 0 at ({x},{y}) inside the hull")

    def test_outside_the_silhouette_is_pen_0(self):
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    pens, mask = frame_grid(sprite, frame)
                    for y, row in enumerate(mask):
                        for x, opaque in enumerate(row):
                            if not opaque:
                                self.assertEqual(pens[y][x], mkships.PEN_SPACE,
                                                 f"{sprite['name']} ({x},{y})")

    def test_each_faction_dithers_between_shadow_and_its_own_lit_pen(self):
        want = {"friendly": {mkships.PEN_SHADE, mkships.PEN_FRIEND},
                "enemy": {mkships.PEN_SHADE, mkships.PEN_ENEMY}}
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    used = set(base64.b64decode(frame["pixels"])) - {mkships.PEN_SPACE}
                    self.assertTrue(used <= want[faction],
                                    f"{sprite['name']}: pens {sorted(used)} "
                                    f"for a {faction} ship")

    def test_both_factions_use_the_shading_pen_somewhere(self):
        """If contrast were ever cranked to the point of two flat tones the
        dither would silently stop existing."""
        for key, faction, doc in self.every():
            pens = set()
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    pens |= set(base64.b64decode(frame["pixels"]))
            self.assertIn(mkships.PEN_SHADE, pens, f"{key}/{faction} has no shading")

    def test_the_factions_differ_only_in_which_pen_is_lit(self):
        """Same geometry, same mask, same dither -- so the enemy data is a pen
        swap of the friendly data, which is what lets the Z80 derive one from
        the other if the bank space is ever needed."""
        swap = {mkships.PEN_FRIEND: mkships.PEN_ENEMY}
        for key in mkships.SHIPS:
            friend = self.docs[(key, "friendly")]
            enemy = self.docs[(key, "enemy")]
            for fs, es in zip(friend["sprites"], enemy["sprites"]):
                for ff, ef in zip(fs["frames"], es["frames"]):
                    self.assertEqual(ff["mask"], ef["mask"],
                                     f"{key}: masks differ between factions")
                    fp = base64.b64decode(ff["pixels"])
                    ep = base64.b64decode(ef["pixels"])
                    self.assertEqual(bytes(swap.get(p, p) for p in fp), ep,
                                     f"{key}: the dither differs between factions")


class TestSilhouette(ShipProjects):

    def test_every_frame_has_a_ship_in_it(self):
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    _, mask = frame_grid(sprite, frame)
                    n = sum(sum(row) for row in mask)
                    self.assertGreater(n, 0,
                                       f"{sprite['name']} frame {frame['index']} is empty")

    def test_a_ship_is_one_connected_shape(self):
        """Two blobs with a gap between them is not a ship, it is debris."""
        for key, faction, doc in self.every():
            for sprite in doc["sprites"]:
                for frame in sprite["frames"]:
                    _, mask = frame_grid(sprite, frame)
                    sizes = components(mask)
                    self.assertEqual(len(sizes), 1,
                                     f"{sprite['name']} frame {frame['index']}: "
                                     f"{len(sizes)} pieces, sizes {sizes}")

    def test_even_the_smallest_tier_is_more_than_a_dot(self):
        """At 8x6 a class has to be at least a shape. Below about six pixels
        it is a speck, and section 5.1 already has a cheaper way to draw a
        speck -- one pixel and no sprite at all."""
        tier_a = mkships.TIERS[0]
        for key, doc in self.friendly():
            sprite = doc["sprites"][0]
            self.assertEqual((sprite["width"], sprite["height"]), (tier_a.w, tier_a.h))
            for frame in sprite["frames"]:
                _, mask = frame_grid(sprite, frame)
                n = sum(sum(row) for row in mask)
                self.assertGreaterEqual(n, 6,
                                        f"{sprite['name']} frame {frame['index']}: "
                                        f"only {n} pixels")

    def test_the_classes_read_differently_at_the_smallest_tier(self):
        """8x6 is the whole design constraint, and the only thing carrying a
        class at that size is proportion. The three MVP classes are meant to
        be, in order: a small chip, a tall block, a long bar. If the size fit
        ever collapsed into 'normalise everything into the box' -- which is the
        obvious thing to write and the wrong thing -- all three become the same
        smudge and this is the test that notices."""
        area, widest, tallest = {}, {}, {}
        for key, doc in self.friendly():
            sprite = doc["sprites"][0]
            area[key] = widest[key] = tallest[key] = 0
            for frame in sprite["frames"]:
                _, mask = frame_grid(sprite, frame)
                area[key] += sum(sum(row) for row in mask)
                widest[key] = max(widest[key], max(sum(row) for row in mask))
                tallest[key] = max(tallest[key],
                                   sum(1 for row in mask if any(row)))

        self.assertLess(area["interceptor"], area["bomber"], area)
        self.assertLess(area["interceptor"], area["frigate"], area)
        #  The frigate is the longest thing on the board...
        self.assertGreater(widest["frigate"], widest["interceptor"], widest)
        self.assertGreaterEqual(widest["frigate"], widest["bomber"], widest)
        #  ...and the bomber the deepest. Note that these are different axes:
        #  the bomber covers MORE pixels than the frigate at tier A, because
        #  the frigate is a two-row line and the bomber is a four-row mass.
        self.assertGreater(tallest["bomber"], tallest["frigate"], tallest)
        self.assertGreater(tallest["bomber"], tallest["interceptor"], tallest)

    def test_no_two_classes_share_a_silhouette_at_the_smallest_tier(self):
        for view in range(mkships.YAW_STEPS):
            seen = {}
            for key, doc in self.friendly():
                frame = doc["sprites"][0]["frames"][view]
                clash = seen.setdefault(frame["mask"], key)
                self.assertEqual(clash, key,
                                 f"yaw {view * 45}: {key} and {clash} are the "
                                 f"same 8x6 shape")
                seen[frame["mask"]] = key


class TestConversion(ShipProjects):
    """The projects have to survive tools/rt2sprite.py, on disc, for real."""

    def test_every_project_loads_and_converts(self):
        for key, faction, doc in self.every():
            with tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, f"{doc['name']}.retrotools.json")
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(doc, f)
                loaded = rt2sprite.load_project(path)
                warnings = rt2sprite.check_palette(loaded, strict=True)
                text = rt2sprite.convert(loaded, rt2sprite.DEFAULT_SHIFTS, warnings)
            self.assertIn("defb", text)
            for sprite in doc["sprites"]:
                self.assertIn(f"{sprite['name']}:", text)
                self.assertIn(f"{sprite['name']}_frames    equ {mkships.YAW_STEPS}", text)

    def test_the_emitted_byte_count_matches_the_memory_budget(self):
        """block_bytes() is what the summary table and the section 5.1 check
        are built on, so it has to agree with what actually comes out."""
        doc = self.docs[("frigate", "friendly")]
        for tier, sprite in zip(mkships.TIERS, doc["sprites"]):
            text = rt2sprite.convert({**doc, "sprites": [sprite]},
                                     rt2sprite.DEFAULT_SHIFTS, [])
            emitted = sum(len(line.split("defb")[1].split(","))
                          for line in text.splitlines() if "defb" in line)
            self.assertEqual(emitted, len(sprite["frames"]) * mkships.block_bytes(tier),
                             f"{sprite['name']}")

    def test_a_dark_hull_pixel_survives_the_blit(self):
        """The whole reason the mask is written out explicitly.

        Blit a frame over a background of the OTHER faction's pen and check
        every mask bit: opaque pixels must land, including pen 2 ones, and
        transparent pixels must let the background through. The decoder is the
        emulator's, as in tests/test_sprites.py.
        """
        for key, faction, doc in self.every():
            background = 3 if faction == "friendly" else 1
            bg_byte = rt2sprite.encode_mode1_byte([background] * 4)
            for sprite in doc["sprites"]:
                w, h = sprite["width"], sprite["height"]
                out_w = w + 4
                frame = sprite["frames"][2]           # broadside: the biggest
                pens, opaque = rt2sprite.frame_grids(sprite, frame)
                sp, so = rt2sprite.shift_grid(pens, opaque, 2, out_w)
                block = rt2sprite.encode_block(sp, so)

                i = 0
                for y in range(h):
                    row = []
                    for _ in range(out_w // 4):
                        row += cpc._decode_byte((bg_byte & block[i]) | block[i + 1], 1)
                        i += 2
                    for x in range(out_w):
                        want = sp[y][x] if so[y][x] else background
                        self.assertEqual(row[x], want,
                                         f"{sprite['name']} ({x},{y}): "
                                         f"pen {row[x]}, wanted {want}")


class TestWriting(unittest.TestCase):
    """The CLI has to actually put files where it says it does."""

    def _run(self, argv):
        with io.StringIO() as quiet, contextlib.redirect_stdout(quiet):
            return mkships.main(argv)

    def test_main_writes_a_project_an_asm_and_a_contact_sheet(self):
        with tempfile.TemporaryDirectory() as tmp:
            art = os.path.join(tmp, "art")
            gen = os.path.join(tmp, "gen")
            png = os.path.join(tmp, "png")
            rc = self._run(["--ship", "interceptor", "--tier", "a",
                            "--art-dir", art, "--asm-dir", gen,
                            "--png-dir", png, "--contact-sheet", "--zoom", "2"])
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.exists(
                os.path.join(art, "interceptor.retrotools.json")))
            self.assertTrue(os.path.exists(os.path.join(gen, "spr_interceptor.asm")))
            self.assertTrue(os.path.exists(os.path.join(png, "interceptor.png")))

    def test_the_enemy_variant_lands_under_its_own_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._run(["--ship", "bomber", "--tier", "a", "--faction", "enemy",
                       "--art-dir", tmp, "--asm-dir", tmp, "--no-asm"])
            self.assertTrue(os.path.exists(
                os.path.join(tmp, "bomber_enemy.retrotools.json")))


if __name__ == "__main__":
    unittest.main()
