#!/usr/bin/env python3
"""Render HOMEPLANET's ship sprites from 3D models, in pure Python.

    python3 tools/mkships.py                    # every ship, friendly
    python3 tools/mkships.py --ship interceptor
    python3 tools/mkships.py --faction enemy
    python3 tools/mkships.py --contact-sheet    # PNG previews at 8x zoom

Design document section 5.2 asks for "model in a 3D program -> render 8 views";
section 14's mitigation cut that to SIX -- see YAW_STEPS.
There is no 3D program here and no numpy either, so the models are convex
polyhedra written out in code and the renderer is the two hundred lines below:
orthographic projection, a z-buffer, flat shading, supersampled and box-
downscaled, then Floyd-Steinberg dithered into two pens.

Doing it in code rather than in Blender is not a compromise. The whole design
constraint is that a ship must still read as itself at **8x6 pixels**, and the
only way to iterate on that is to change a number, re-run, and look. A ship is
twenty lines of `prism()` calls; tweaking a fin is one edit away from a new
contact sheet.

Output
------
* `art/<ship>[_enemy].retrotools.json` -- the source art, git-tracked. It is a
  real RetroTools project: open it in the editor and hand-retouch the tier A
  frames if the renderer gets a silhouette wrong. Re-running this tool will
  overwrite it, so save retouched work under a different name.
* `src/gen/spr_<ship>[_enemy].asm` -- via tools/rt2sprite.py, generated.
* `build/ships/<ship>[_enemy].png` -- contact sheets, gitignored.

The palette is semantic (CLAUDE.md)
-----------------------------------
    pen 0  black         EMPTY SPACE -- transparent
    pen 1  bright white  lit surface, friendly
    pen 2  sky blue      shadowed surface, and the dither partner for both
    pen 3  bright red    lit surface, enemy

So the shading is dithered between pen 2 and the faction's lit pen, and pen 0
never appears inside a hull -- a dark pixel is pen 2, not a hole. The mask is
written into the project explicitly rather than leaning on rt2sprite's "pen 0
is transparent" fallback, because a legitimately dark hull pixel must stay
opaque.

The mask is identical for both factions, and so is the dither pattern: only
the lit pen changes. Which means the enemy sprite data is derivable from the
friendly data at runtime, if the memory is ever needed --

    pen 1 is (b0=1, b1=0), pen 3 is (b0=1, b1=1), pen 2 is (b0=0, b1=1)

  and a Mode 1 byte holds the b0 bits in the high nibble and b1 in the low, so
  `data OR ((data >> 4) AND #0F)` turns every pen 1 into pen 3 and leaves pens
  0 and 2 alone. Three instructions and no second copy. `--faction enemy` is
  still here because a hand-retouched enemy variant is a thing you might want.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools import rt2sprite  # noqa: E402

# ---------------------------------------------------------------------------
#  Constants
# ---------------------------------------------------------------------------

PEN_SPACE = 0
PEN_FRIEND = 1
PEN_SHADE = 2
PEN_ENEMY = 3

FACTION_PEN = {"friendly": PEN_FRIEND, "enemy": PEN_ENEMY}

MODE1_PIXELS_PER_BYTE = 4

#  Mode 1 is 320x200 on a 4:3 display, so a pixel is 0.833 as wide as it is
#  tall. Stretching X by the reciprocal keeps a model's proportions on the
#  actual screen instead of in the pixel grid.
PIXEL_ASPECT = 1.2

#  View direction is -Z: the camera sits at +Z looking at the origin. A model's
#  nose points at +Z, so yaw 0 is head-on and yaw 90 is broadside-to-the-right.
#
#  Light in VIEW space, not model space -- it must not rotate with the ship, or
#  every yaw view would be shaded identically and the fleet would look flat.
#  It is deliberately mostly horizontal: with pitch 0 the visible faces are the
#  ones facing the camera, whose normals are nearly horizontal, so a light from
#  straight above would leave every one of them equally dark.
LIGHT = (-0.62, 0.30, 0.72)     # from upper-left, slightly behind the camera
AMBIENT = 0.14

#  A soft top-to-bottom fill on top of the flat shading, in view space.
#
#  Flat shading gives every pixel of a face the same value, so dithering it can
#  only ever produce a uniform screen over a large area -- which at 24x16 does
#  not read as a shaded surface, it reads as static. This term varies within a
#  face, so Floyd-Steinberg has a ramp to work on and the dither lands where a
#  dither belongs: a band across the hull, dense at the bottom, thinning out
#  towards the top. It is also just what a ship near a star looks like.
SKY_FILL = 0.45

#  SIX views, 60 degrees apart. Section 5.1 asks for eight; section 14 lists
#  "6 yaw views instead of 8" as the mitigation for "the sprite libraries do
#  not fit", and they did not: eight classes at eight views is 45 KB against
#  three banks of 16 KB, with bank 4 down to nine spare bytes and no fourth
#  bank in the #7Fxx window to reach for.
#
#  Six is a quarter off every library (5760 -> 4320 bytes) and it costs a
#  coarser turn. It is affordable here and not everywhere: at tier C a ship
#  turns through six poses instead of eight, which reads as a turn because the
#  silhouettes are still all different -- see the contact sheets. What it is
#  NOT is free at tier A, where 8x6 has barely enough pixels to tell the
#  classes apart in the first place.
#
#  SIX IS NOT A POWER OF TWO, which is the part that reaches into the Z80:
#  phase4_cache used to pick a view with a shift and a mask. It multiplies
#  now -- see the comment there.
YAW_STEPS = 6

#  TODO: section 5.1 wants 2 pitch levels ("horizontal / from above-below").
#  Adding them is this tuple plus a bigger frame count -- render_frames(),
#  view_angles() and the frame indexing below already take pitch as a
#  parameter, and nothing else in the pipeline knows how many frames there are.
#  Frame index is (pitch_index * yaw_steps + yaw_index), so appending an angle
#  here keeps the existing frames at the same indices.
#  Cost check before doing it: it doubles every number in the byte table that
#  this tool prints, i.e. ~4.2 KB -> ~8.4 KB per class. Six yaw views has
#  already been spent -- it is what bought the room the eight-view libraries
#  did not have -- so the second pitch level would have to find its 34 KB
#  somewhere else entirely.
PITCH_ANGLES = (0.0,)


class Tier:
    """One of the three distance tiers from design section 5.1.

    `coverage` is how much of a pixel the hull must cover before that pixel is
    part of the silhouette. It is looser on the small tiers because at 8x6 a
    wing is a third of a pixel thick and a half-coverage rule deletes it.

    `contrast` pushes the shading away from mid-grey before it is dithered.
    Without it the whole hull lands near 50% and Floyd-Steinberg turns it into
    a checkerboard -- at 24x16 that reads as static, not as a lit surface. With
    it the hull goes mostly solid and the dither survives only in the
    terminator, which is where you actually want it.

    `gamma` is applied after; below 1 it brightens. The small tiers get
    brightened because two or three pixels of hull have no room to spend on
    shadow -- a tier A ship wants to read as a shape, not as a lighting study.
    """

    def __init__(self, key, w, h, coverage, contrast, gamma, supersample=8):
        self.key = key
        self.w = w
        self.h = h
        self.coverage = coverage
        self.contrast = contrast
        self.gamma = gamma
        self.supersample = supersample
        if w % MODE1_PIXELS_PER_BYTE:
            raise ValueError(
                f"tier {key}: width {w} is not a multiple of "
                f"{MODE1_PIXELS_PER_BYTE}, which Mode 1 requires"
            )

    def __repr__(self):
        return f"<Tier {self.key} {self.w}x{self.h}>"


TIERS = [
    Tier("a", 8, 6, coverage=0.34, contrast=3.2, gamma=0.80),
    Tier("b", 16, 10, coverage=0.42, contrast=1.9, gamma=0.90),
    Tier("c", 24, 16, coverage=0.48, contrast=1.8, gamma=1.00),
]

TIERS_BY_KEY = {t.key: t for t in TIERS}


# ---------------------------------------------------------------------------
#  Geometry helpers
# ---------------------------------------------------------------------------

def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _normalize(v):
    n = math.sqrt(_dot(v, v))
    if n < 1e-12:
        return None
    return (v[0] / n, v[1] / n, v[2] / n)


def slab(z0, z1, sec0, sec1):
    """A hexahedron between two four-cornered cross-sections at z0 and z1.

    `sec` is [(x, y)] x 4, listed around the section. The sections need not be
    axis-aligned, which is the whole point: a canted wing is a slab whose
    section is a tilted rectangle. Either section may collapse to a point for a
    nose cone -- the degenerate faces fall out in the triangulator.
    """
    verts = [(x, y, z0) for x, y in sec0] + [(x, y, z1) for x, y in sec1]
    faces = [
        (0, 1, 2, 3),       # back cap
        (4, 5, 6, 7),       # front cap
        (0, 1, 5, 4),
        (1, 2, 6, 5),
        (2, 3, 7, 6),
        (3, 0, 4, 7),
    ]
    return verts, faces


def prism(z0, z1, hw0, hh0, hw1=None, hh1=None,
          x0=0.0, x1=None, y0=0.0, y1=None):
    """A slab whose sections are axis-aligned rectangles.

    `hw`/`hh` are HALF width and height; `x`/`y` offset the section's centre.
    Most of every ship is one of these.
    """
    hw1 = hw0 if hw1 is None else hw1
    hh1 = hh0 if hh1 is None else hh1
    x1 = x0 if x1 is None else x1
    y1 = y0 if y1 is None else y1
    return slab(
        z0, z1,
        [(x0 - hw0, y0 - hh0), (x0 + hw0, y0 - hh0),
         (x0 + hw0, y0 + hh0), (x0 - hw0, y0 + hh0)],
        [(x1 - hw1, y1 - hh1), (x1 + hw1, y1 - hh1),
         (x1 + hw1, y1 + hh1), (x1 - hw1, y1 + hh1)],
    )


def mirror_x(part):
    """The same part on the other side of the hull."""
    verts, faces = part
    return [(-x, y, z) for (x, y, z) in verts], faces


class Ship:
    """A ship class: a bag of convex parts plus how big it draws.

    `span` is the fraction of the sprite box the ship fills. It is what keeps
    a frigate looking bigger than an interceptor: without it every class would
    be normalised to the same 8x6 box and the size cue -- which is most of what
    you have at this resolution -- would be thrown away. It is not to scale
    either; true relative sizes would leave the interceptor as a single pixel.
    """

    def __init__(self, key, name, span, parts, note=""):
        self.key = key
        self.name = name
        self.span = span
        self.note = note

        # Recentre on the bounding box so the sprite's centre is the ship's
        # centre and yaw does not make it swing around off-frame.
        allv = [v for verts, _ in parts for v in verts]
        cx = (min(v[0] for v in allv) + max(v[0] for v in allv)) / 2
        cy = (min(v[1] for v in allv) + max(v[1] for v in allv)) / 2
        cz = (min(v[2] for v in allv) + max(v[2] for v in allv)) / 2

        self.tris = []
        for verts, faces in parts:
            verts = [(x - cx, y - cy, z - cz) for (x, y, z) in verts]
            pcx = sum(v[0] for v in verts) / len(verts)
            pcy = sum(v[1] for v in verts) / len(verts)
            pcz = sum(v[2] for v in verts) / len(verts)
            centre = (pcx, pcy, pcz)
            for face in faces:
                for i in range(1, len(face) - 1):
                    a, b, c = verts[face[0]], verts[face[i]], verts[face[i + 1]]
                    n = _normalize(_cross(_sub(b, a), _sub(c, a)))
                    if n is None:
                        continue            # collapsed section, no area
                    tc = ((a[0] + b[0] + c[0]) / 3,
                          (a[1] + b[1] + c[1]) / 3,
                          (a[2] + b[2] + c[2]) / 3)
                    # The part is convex, so "outward" is "away from its
                    # centroid". This makes the winding order of the face
                    # tables irrelevant, which removes a whole class of
                    # invisible-ship bugs.
                    if _dot(n, _sub(tc, centre)) < 0:
                        n = (-n[0], -n[1], -n[2])
                    self.tris.append((a, b, c, n))

        if not self.tris:
            raise ValueError(f"{key}: no renderable geometry")

        verts_all = [v for t in self.tris for v in t[:3]]
        #  The widest the ship can ever project to under yaw is its radius in
        #  the XZ plane, so normalising against that keeps the apparent size
        #  constant across the yaw views instead of pulsing.
        self.radius_xz = max(math.hypot(v[0], v[2]) for v in verts_all)
        self.half_y = max(abs(v[1]) for v in verts_all)

    def scale_for(self, tier: Tier) -> float:
        """Model units -> supersampled pixels, for one tier."""
        ss = tier.supersample
        wide = (tier.w * ss) * self.span / (2 * self.radius_xz * PIXEL_ASPECT)
        tall = (tier.h * ss) * self.span / (2 * max(self.half_y, 1e-6))
        return min(wide, tall)


# ---------------------------------------------------------------------------
#  The ships
#
#  Model space: +X right, +Y up, +Z forward (the nose). Units are arbitrary;
#  only the ratios inside one ship matter, `span` handles the rest.
#
#  Everything below is aimed at the 8x6 tier, because that is the hard one.
#
#  The rule that decides these shapes: with pitch 0 the camera sits in the
#  ship's horizontal plane, so the silhouette is the ship's SIDE ELEVATION,
#  squeezed horizontally as yaw turns it away. A flat horizontal wing is seen
#  edge-on from every one of the yaw views and contributes a one-pixel stick and
#  nothing else -- the first version of the interceptor had a big delta wing
#  and it vanished entirely at tier A. So:
#
#    * vertical structure (fins, spines, towers, keels) is what a ship is made
#      of at this resolution;
#    * wings must be CANTED, so they show span head-on and depth broadside;
#    * beam matters as much as length, or the head-on view collapses to a dot
#      while the broadside view fills the box, and the ship appears to pulse as
#      it turns.
#
#  What is left to tell the classes apart is bulk and proportion. Measured off
#  the tier A output, broadside: interceptor 4x2 (a chip), bomber 7x4 (a mass),
#  frigate 8x2-3 (a bar from edge to edge, with a step amidships). Those are
#  the three things an 8x6 sprite can be, and they are all it can be.
# ---------------------------------------------------------------------------

def _canted_wing(z_root, z_tip, x_in, x_out, drop, thick, tip_out, tip_drop):
    """One anhedral wing panel: out and down, so it reads from every yaw."""
    return slab(
        z_root, z_tip,
        [(x_in, 0.04), (x_out, 0.04 - drop),
         (x_out, 0.04 - drop - thick), (x_in, 0.04 - thick)],
        [(x_in, 0.02), (tip_out, 0.02 - tip_drop),
         (tip_out, 0.02 - tip_drop - thick * 0.8), (x_in, 0.02 - thick * 0.8)],
    )


def _interceptor() -> Ship:
    """A dart: pointed, small, canted wings, one fin. Fast and disposable."""
    #  The wings are thick out of all proportion to a real aircraft's. A 0.10
    #  wing -- 9% of the ship's height -- covered a fifth of a pixel at tier A
    #  and the coverage test deleted it, so the head-on view came out as a two
    #  pixel dot. Anything that has to survive to 8x6 has to be about a fifth
    #  of the ship thick. This is the single most important lesson in the file.
    wing = _canted_wing(z_root=-1.00, z_tip=0.40, x_in=0.11, x_out=0.92,
                        drop=0.46, thick=0.22, tip_out=0.34, tip_drop=0.16)
    parts = [
        # fuselage, tapering to a point at the nose
        prism(-1.00, 1.15, hw0=0.18, hh0=0.22, hw1=0.0, hh1=0.0),
        # engine block, squared off at the tail
        prism(-1.16, -0.76, hw0=0.22, hh0=0.20, hw1=0.24, hh1=0.23),
        wing, mirror_x(wing),
        # dorsal fin, swept back
        prism(-1.00, -0.30, hw0=0.07, hh0=0.30, y0=0.32,
              hw1=0.05, hh1=0.11, y1=0.20),
    ]
    return Ship("interceptor", "Interceptor", span=0.82, parts=parts,
                note="anti-fighter; 35 RU (section 8)")


def _bomber() -> Ship:
    """Heavy and blunt. Short, thick, wide-shouldered, with a raised spine."""
    body = prism(-0.78, 0.68, hw0=0.42, hh0=0.38, hw1=0.36, hh1=0.32)
    nose = prism(0.68, 0.98, hw0=0.36, hh0=0.32, hw1=0.24, hh1=0.18)
    spine = prism(-0.60, 0.34, hw0=0.20, hh0=0.28, y0=0.60,
                  hw1=0.15, hh1=0.18, y1=0.50)
    pod = prism(-0.92, 0.30, hw0=0.16, hh0=0.20, x0=0.60,
                hw1=0.13, hh1=0.17, x1=0.56)
    parts = [body, nose, spine, pod, mirror_x(pod)]
    return Ship("bomber", "Bomber", span=0.92, parts=parts,
                note="anti-capital; 55 RU (section 8)")


def _frigate() -> Ship:
    """A long slab. Fills the sprite box broadside and steps up amidships."""
    #  The hull is deliberately deep for its length. A 2-pixel-tall slab is
    #  where dithering falls apart: the top row goes solid and the bottom row
    #  lands on 50%, and a 50% screen one pixel tall is a dashed line, not a
    #  shadow. Four pixels of hull at tier C is the minimum that reads.
    hull = prism(-1.55, 1.60, hw0=0.30, hh0=0.34, hw1=0.14, hh1=0.16)
    stern = prism(-1.72, -1.45, hw0=0.34, hh0=0.38, hw1=0.33, hh1=0.36)
    #  The tower is tall enough to claim a third pixel row at tier A even
    #  bow-on. Without it a frigate seen end-on and an interceptor seen end-on
    #  are byte-for-byte the same 4x2 blob -- which was true of the first four
    #  versions of these models.
    tower = prism(-0.95, -0.10, hw0=0.24, hh0=0.26, y0=0.56,
                  hw1=0.17, hh1=0.16, y1=0.44)
    belly = prism(-0.70, 0.50, hw0=0.21, hh0=0.14, y0=-0.46,
                  hw1=0.15, hh1=0.10, y1=-0.38)
    #  Wide sponsons purely so the bow-on and stern-on views do not collapse
    #  to a 2x2 dot at tier A. They cost nothing in length: they sit amidships,
    #  so they never touch the XZ radius the size fit is normalised against.
    #  These reach all the way in to the hull on purpose. An earlier version
    #  had them as narrow sponsons standing off the side, and bow-on at tier C
    #  that left a one-pixel gap between hull and sponson: two loose blocks
    #  floating beside the ship, which largest_component then deleted.
    fin = prism(-0.80, 0.20, hw0=0.47, hh0=0.24, x0=0.68,
                hw1=0.34, hh1=0.16, x1=0.56)
    parts = [hull, stern, tower, belly, fin, mirror_x(fin)]
    return Ship("frigate", "Frigate", span=1.00, parts=parts,
                note="battle line; 120 RU (section 8)")


def _scout() -> Ship:
    """A needle with a sensor head. The smallest thing in the fleet.

    It has to be told apart from the interceptor, which is also a small dart,
    and at these sizes "smaller" is not available -- `span` normalises every
    class into the same box. So the difference is PROPORTION: the interceptor
    is a wedge that is widest at the back, the scout is a stick with a bulb on
    the front and a mast on top. Broadside it reads as a T; the interceptor
    reads as a triangle.
    """
    #  The dish is a ring seen edge-on from every yaw, which is what makes the
    #  bulb survive to tier B. A sphere would have been a blob.
    dish = prism(0.62, 0.80, hw0=0.42, hh0=0.44, hw1=0.34, hh1=0.36)
    boom = prism(-0.95, 0.66, hw0=0.11, hh0=0.13, hw1=0.09, hh1=0.10)
    mast = prism(-0.42, 0.10, hw0=0.06, hh0=0.40, y0=0.48,
                 hw1=0.05, hh1=0.30, y1=0.40)
    keel = prism(-0.30, 0.20, hw0=0.06, hh0=0.24, y0=-0.34,
                 hw1=0.05, hh1=0.18, y1=-0.28)
    tail = prism(-1.12, -0.88, hw0=0.19, hh0=0.21)
    parts = [dish, boom, mast, keel, tail]
    return Ship("scout", "Scout", span=0.72, parts=parts,
                note="reconnaissance; 25 RU (section 8)")


def _harvester() -> Ship:
    """A catamaran: two hoppers either side of an open scoop. No weapons.

    Deliberately the only WIDE-AND-FLAT class. The bomber is also blunt, but
    it is blunt with a raised spine, so at tier A the bomber is a mass with a
    bump on top and the harvester is a mass with a notch in the middle. That
    notch is the whole silhouette: the gap between the hoppers is a real hole
    in the sprite, and largest_component would delete a hopper if the two ever
    stopped touching, so the cross-beams below are not decoration.
    """
    hopper = prism(-0.86, 0.52, hw0=0.30, hh0=0.42, x0=0.62,
                   hw1=0.26, hh1=0.34, x1=0.58)
    #  The beams tie the two hulls together, and they are deep rather than
    #  wide so they still read when the ship is seen bow-on.
    beam_f = prism(0.16, 0.44, hw0=0.66, hh0=0.13, y0=-0.10)
    beam_r = prism(-0.72, -0.44, hw0=0.66, hh0=0.15, y0=-0.06)
    #  The scoop hangs UNDER the gap, so head-on the ship is two blocks and a
    #  bar rather than two loose blocks.
    scoop = prism(-0.30, 0.86, hw0=0.34, hh0=0.24, y0=-0.40,
                  hw1=0.44, hh1=0.30, y1=-0.44)
    parts = [hopper, mirror_x(hopper), beam_f, beam_r, scoop]
    return Ship("harvester", "Harvester", span=0.94, parts=parts,
                note="resource collection; 40 RU (section 8)")


def _salvage() -> Ship:
    """A tug: a heavy engine block behind a two-pronged grapple.

    The fork is the identity -- nothing else in the fleet has a hole at the
    bow. It has to be a SIDEWAYS fork, x0 = +-0.40 with a gap between, and
    that is not obvious: the first version put one prong above the centreline
    and one below, both at x = 0, which reads perfectly broadside and turns
    into a solid blob head-on. At 8x6 head-on the corvette was then byte-for-
    byte the Mothership, and tests/test_ships.py said so.

    Made of vertical plates rather than horizontal ones for the reason at the
    top of this section: a flat panel is seen edge-on from every one of the
    every yaw view and contributes a one-pixel stick.
    """
    prong = prism(0.15, 1.10, hw0=0.15, hh0=0.34, x0=0.40,
                  hw1=0.12, hh1=0.26, x1=0.46)
    #  The yoke ties the prongs to the hull. Without it they are two loose
    #  blocks and largest_component deletes one of them.
    yoke = prism(0.10, 0.42, hw0=0.56, hh0=0.20)
    spine = prism(-0.60, 0.25, hw0=0.22, hh0=0.26, hw1=0.18, hh1=0.30)
    #  Squat, wide, and unmistakably the back end: a tug is all engine.
    block = prism(-1.10, -0.50, hw0=0.40, hh0=0.46, hw1=0.34, hh1=0.40)
    #  A derrick over the engine block, leaning forward. Without it the ship
    #  is symmetric about both the vertical AND the fore-aft axis at 8x6, and
    #  the yaw views collapse into fewer distinct shapes than there are views,
    #  and a rotation that repeats a picture is one the player reads as
    #  stuttering.
    #  Vertical structure is what survives to tier A; see the note at the top
    #  of this section.
    derrick = prism(-0.80, -0.10, hw0=0.10, hh0=0.34, y0=0.66,
                    hw1=0.08, hh1=0.20, y1=0.52)
    parts = [prong, mirror_x(prong), yoke, spine, block, derrick]
    return Ship("salvage", "Salvage Corvette", span=0.88, parts=parts,
                note="capture; 90 RU (section 8)")


def _destroyer() -> Ship:
    """The heavy capital: a deep hull carrying TWO towers.

    The frigate is the other long class, so the pair have to be told apart at
    a glance. The frigate is a bar with one tower amidships; the destroyer is
    a deeper bar with a tower at each end and a gap between them. Two bumps
    against one is a cue that survives the dither, which a difference of
    proportion alone would not.
    """
    hull = prism(-1.60, 1.50, hw0=0.40, hh0=0.50, hw1=0.24, hh1=0.30)
    stern = prism(-1.85, -1.50, hw0=0.44, hh0=0.54, hw1=0.42, hh1=0.52)
    #  Both towers stand a full half-hull proud, with a hull-length gap
    #  between them. Anything shorter merged into one bump at tier B and the
    #  destroyer became a fat frigate.
    tower_f = prism(0.10, 0.85, hw0=0.26, hh0=0.42, y0=0.78,
                    hw1=0.20, hh1=0.30, y1=0.66)
    tower_r = prism(-1.40, -0.65, hw0=0.28, hh0=0.46, y0=0.82,
                    hw1=0.22, hh1=0.34, y1=0.70)
    keel = prism(-1.10, 0.70, hw0=0.24, hh0=0.22, y0=-0.66,
                 hw1=0.17, hh1=0.16, y1=-0.58)
    #  Same trick as the frigate's sponsons: amidships, so they never touch
    #  the XZ radius the size fit normalises against, and they keep the
    #  bow-on view from collapsing to a dot.
    battery = prism(-1.00, 0.10, hw0=0.50, hh0=0.28, x0=0.72,
                    hw1=0.36, hh1=0.20, x1=0.60)
    parts = [hull, stern, tower_f, tower_r, keel, battery, mirror_x(battery)]
    return Ship("destroyer", "Destroyer", span=1.00, parts=parts,
                note="heavy capital; 250 RU, from mission 5 (section 8)")


def _mothership() -> Ship:
    """Sixty thousand sleepers in a box.

    Not a warship and it must not look like one: no fins, no nose, nothing
    swept. A deep rectangular slab with a spine along the top and a bank of
    engines across the stern -- the only class whose silhouette is basically
    a rectangle, which is exactly the read wanted for "the thing you are
    protecting". The tier bias in shipclass.asm draws it a size larger again.
    """
    core = prism(-1.30, 1.30, hw0=0.62, hh0=0.72, hw1=0.54, hh1=0.62)
    bow = prism(1.30, 1.62, hw0=0.54, hh0=0.62, hw1=0.44, hh1=0.46)
    spine = prism(-1.10, 0.95, hw0=0.30, hh0=0.26, y0=0.92,
                  hw1=0.26, hh1=0.22, y1=0.86)
    ventral = prism(-0.90, 0.80, hw0=0.34, hh0=0.24, y0=-0.90,
                    hw1=0.28, hh1=0.20, y1=-0.84)
    #  The engine bank is wider than the hull, so the stern-on view is the
    #  widest thing the fleet has and the Mothership is identifiable even
    #  when it is running away.
    engines = prism(-1.62, -1.24, hw0=0.86, hh0=0.52, hw1=0.80, hh1=0.46)
    parts = [core, bow, spine, ventral, engines]
    return Ship("mothership", "Mothership", span=1.00, parts=parts,
                note="base, construction, jump; not buildable (section 8)")


#  All eight classes of section 8. Adding one is a function above and a row in
#  src/game/shipclass.asm; where its library LIVES is the Makefile's business.
SHIPS = {s.key: s for s in (
    _interceptor(), _bomber(), _frigate(), _scout(),
    _harvester(), _salvage(), _destroyer(), _mothership(),
)}


# ---------------------------------------------------------------------------
#  Software renderer
# ---------------------------------------------------------------------------

def view_angles(yaw_steps=YAW_STEPS, pitch_angles=PITCH_ANGLES):
    """(yaw, pitch) in radians, in frame order: pitch major, yaw minor."""
    out = []
    for pitch in pitch_angles:
        for i in range(yaw_steps):
            out.append((2 * math.pi * i / yaw_steps, math.radians(pitch)))
    return out


def _rotate(p, sy, cy, sp, cp):
    """Yaw about +Y, then pitch about +X. Camera stays at +Z looking at -Z."""
    x, y, z = p
    x1 = x * cy + z * sy
    z1 = -x * sy + z * cy
    y2 = y * cp + z1 * sp
    z2 = -y * sp + z1 * cp
    return (x1, y2, z2)


def render_view(ship: Ship, tier: Tier, yaw: float, pitch: float):
    """One view -> (intensity, coverage), both tier.h x tier.w grids of floats.

    Orthographic, z-buffered, flat-shaded, rendered at `tier.supersample` times
    the final resolution and box-downscaled. The supersampling is not a nicety:
    at 8x6 a one-pixel error in the silhouette is a sixth of the ship.
    """
    ss = tier.supersample
    W, H = tier.w * ss, tier.h * ss
    scale = ship.scale_for(tier)
    cx, cy = W / 2.0, H / 2.0

    sy, cyaw = math.sin(yaw), math.cos(yaw)
    sp, cp = math.sin(pitch), math.cos(pitch)

    NEG = -1e30
    zbuf = [NEG] * (W * H)
    ibuf = [0.0] * (W * H)

    for a, b, c, n in ship.tris:
        nr = _rotate(n, sy, cyaw, sp, cp)
        if nr[2] <= 0.0:
            continue                        # back face of a convex part
        shade = AMBIENT + (1.0 - AMBIENT) * max(0.0, _dot(nr, LIGHT))

        pts = []
        for v in (a, b, c):
            rx, ry, rz = _rotate(v, sy, cyaw, sp, cp)
            pts.append((cx + rx * scale * PIXEL_ASPECT, cy - ry * scale, rz))
        _raster_tri(pts, shade, W, H, zbuf, ibuf)

    # Box downscale. Coverage is the fraction of subpixels the hull reached;
    # intensity is the mean over the covered ones only, so a half-covered edge
    # pixel keeps the surface's real brightness instead of being darkened
    # towards the background.
    #  SKY_FILL is a linear function of view-space Y, and view-space Y is a
    #  linear function of the screen row, so it costs one add per subpixel
    #  here instead of an interpolated attribute in the inner loop.
    half_px = max(ship.half_y * scale, 1e-6)
    fill = [SKY_FILL * 0.5 * ((cy - (r + 0.5)) / half_px) for r in range(H)]

    inten = [[0.0] * tier.w for _ in range(tier.h)]
    cover = [[0.0] * tier.w for _ in range(tier.h)]
    denom = float(ss * ss)
    for oy in range(tier.h):
        for ox in range(tier.w):
            total = 0.0
            hits = 0
            for sy_ in range(oy * ss, oy * ss + ss):
                base = sy_ * W + ox * ss
                g = fill[sy_]
                for i in range(base, base + ss):
                    if zbuf[i] > NEG:
                        hits += 1
                        total += ibuf[i] + g
            if hits:
                inten[oy][ox] = total / hits
                cover[oy][ox] = hits / denom
    return inten, cover


def _raster_tri(pts, shade, W, H, zbuf, ibuf):
    """Barycentric scan of one triangle into the z-buffer. Bigger z is nearer."""
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = pts
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if area == 0.0:
        return
    if area < 0:                            # force CCW so the sign tests hold
        x1, y1, z1, x2, y2, z2 = x2, y2, z2, x1, y1, z1
        area = -area
    inv = 1.0 / area

    lo_x = max(0, int(math.floor(min(x0, x1, x2))))
    hi_x = min(W - 1, int(math.ceil(max(x0, x1, x2))))
    lo_y = max(0, int(math.floor(min(y0, y1, y2))))
    hi_y = min(H - 1, int(math.ceil(max(y0, y1, y2))))
    if lo_x > hi_x or lo_y > hi_y:
        return

    for py in range(lo_y, hi_y + 1):
        sy = py + 0.5
        row = py * W
        for px in range(lo_x, hi_x + 1):
            sx = px + 0.5
            w0 = ((x1 - sx) * (y2 - sy) - (x2 - sx) * (y1 - sy)) * inv
            if w0 < 0.0:
                continue
            w1 = ((x2 - sx) * (y0 - sy) - (x0 - sx) * (y2 - sy)) * inv
            if w1 < 0.0:
                continue
            w2 = 1.0 - w0 - w1
            if w2 < 0.0:
                continue
            z = w0 * z0 + w1 * z1 + w2 * z2
            i = row + px
            if z > zbuf[i]:
                zbuf[i] = z
                ibuf[i] = shade


# ---------------------------------------------------------------------------
#  Silhouette and dithering
# ---------------------------------------------------------------------------

NEIGHBOURS_8 = ((-1, -1), (0, -1), (1, -1), (-1, 0),
                (1, 0), (-1, 1), (0, 1), (1, 1))


def largest_component(mask, w, h):
    """Keep only the biggest 8-connected blob.

    Thresholding coverage can strand a wingtip clear of the hull. On screen
    that reads as dirt, not as a ship, and the blitter would happily draw it.

    Eight-connected and not four: a swept wing meeting a fuselage crosses the
    pixel grid diagonally, and at tier B the interceptor's wingtips touch the
    body only at a corner. That is ordinary pixel art and reads as one solid
    ship; deleting both wings because of it does not. Returns
    (mask, dropped_pixel_count).
    """
    seen = [[False] * w for _ in range(h)]
    best = []
    dropped = 0
    for y in range(h):
        for x in range(w):
            if not mask[y][x] or seen[y][x]:
                continue
            stack = [(x, y)]
            seen[y][x] = True
            blob = []
            while stack:
                bx, by = stack.pop()
                blob.append((bx, by))
                for dx, dy in NEIGHBOURS_8:
                    nx, ny = bx + dx, by + dy
                    if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if len(blob) > len(best):
                dropped += len(best)
                best = blob
            else:
                dropped += len(blob)

    out = [[0] * w for _ in range(h)]
    for bx, by in best:
        out[by][bx] = 1
    return out, dropped


def floyd_steinberg(values, mask, w, h):
    """Two-level Floyd-Steinberg, confined to the silhouette.

    Error is only pushed into pixels that are part of the ship -- diffusing it
    into empty space would both lose it and, worse, tempt the quantiser to
    light up a pixel outside the hull. Error that has nowhere to go is dropped
    rather than renormalised: on a 3-pixel-wide hull, renormalising turns one
    bright edge pixel into a bright edge column.

    Returns a grid of 0 (shadow, pen 2) and 1 (lit).
    """
    acc = [row[:] for row in values]
    bits = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            old = acc[y][x]
            if old < -0.6:
                old = -0.6              # a runaway pixel must not poison a
            elif old > 1.6:             # whole row of a 6-pixel-tall sprite
                old = 1.6
            new = 1 if old >= 0.5 else 0
            bits[y][x] = new
            err = old - new
            for dx, dy, k in ((1, 0, 7 / 16), (-1, 1, 3 / 16),
                              (0, 1, 5 / 16), (1, 1, 1 / 16)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and mask[ny][nx]:
                    acc[ny][nx] += err * k
    return bits


def _tone(v: float, tier: Tier) -> float:
    """Lambert term -> the value the ditherer sees. Contrast, then gamma."""
    v = 0.5 + (v - 0.5) * tier.contrast
    v = min(1.0, max(0.0, v))
    return v ** tier.gamma


class Frame:
    """One rendered view: the silhouette and which pixels are lit."""

    def __init__(self, index, yaw, pitch, bits, mask):
        self.index = index
        self.yaw = yaw
        self.pitch = pitch
        self.bits = bits
        self.mask = mask

    def pens(self, lit_pen):
        return [[(lit_pen if self.bits[y][x] else PEN_SHADE) if self.mask[y][x]
                 else PEN_SPACE
                 for x in range(len(self.mask[0]))]
                for y in range(len(self.mask))]


def render_frames(ship: Ship, tier: Tier, yaw_steps=YAW_STEPS,
                  pitch_angles=PITCH_ANGLES, warn=None) -> list[Frame]:
    """Every view of one ship at one tier, faction-independent."""
    frames = []
    for index, (yaw, pitch) in enumerate(view_angles(yaw_steps, pitch_angles)):
        inten, cover = render_view(ship, tier, yaw, pitch)
        mask = [[1 if cover[y][x] >= tier.coverage else 0 for x in range(tier.w)]
                for y in range(tier.h)]
        mask, dropped = largest_component(mask, tier.w, tier.h)
        if dropped and warn:
            warn(f"{ship.key} tier {tier.key} frame {index}: dropped "
                 f"{dropped} disconnected pixel(s)")
        if not any(any(row) for row in mask):
            raise ValueError(
                f"{ship.key} tier {tier.key} frame {index}: empty silhouette -- "
                f"the model is too small for the tier or coverage is too strict"
            )
        vals = [[_tone(inten[y][x], tier) for x in range(tier.w)]
                for y in range(tier.h)]
        bits = floyd_steinberg(vals, mask, tier.w, tier.h)
        frames.append(Frame(index, yaw, pitch, bits, mask))
    return frames


# ---------------------------------------------------------------------------
#  RetroTools project emission
# ---------------------------------------------------------------------------

def sprite_name(ship: Ship, tier: Tier, faction: str) -> str:
    suffix = "" if faction == "friendly" else "_enemy"
    return f"{ship.key}{suffix}_{tier.key}"


def project_name(ship: Ship, faction: str) -> str:
    return ship.key if faction == "friendly" else f"{ship.key}_enemy"


def build_project(ship_key: str, faction: str = "friendly", tiers=None,
                  yaw_steps=YAW_STEPS, pitch_angles=PITCH_ANGLES,
                  warn=None) -> dict:
    """A complete .retrotools.json document: one sprite per tier."""
    if faction not in FACTION_PEN:
        raise ValueError(f"unknown faction {faction!r}")
    ship = SHIPS[ship_key]
    lit = FACTION_PEN[faction]
    tiers = tiers or TIERS

    sprites = []
    for order, tier in enumerate(tiers):
        frames = render_frames(ship, tier, yaw_steps, pitch_angles, warn=warn)
        out_frames = []
        for f in frames:
            pens = f.pens(lit)
            flat_pens = bytes(p for row in pens for p in row)
            flat_mask = bytes(m for row in f.mask for m in row)
            out_frames.append({
                "index": f.index,
                "durationMs": 100,
                "pixels": base64.b64encode(flat_pens).decode(),
                # Written out explicitly: a shadowed hull pixel is pen 2, but a
                # LIT pixel of a dark model could be pen 0 in some future
                # palette, and either way the silhouette is a fact about the
                # geometry, not about the pens.
                "mask": base64.b64encode(flat_mask).decode(),
            })
        sprites.append({
            "id": order + 1,
            "name": sprite_name(ship, tier, faction),
            "width": tier.w,
            "height": tier.h,
            "hasMask": True,
            "sortOrder": order,
            "frames": out_frames,
        })

    return {
        "format": "retrotools-project",
        "version": 1,
        "generator": "homeplanet/tools/mkships.py",
        "name": project_name(ship, faction),
        "platformCode": "cpc",
        "modeCode": "cpc.mode1",
        "palette": [{"slot": i, "color": c}
                    for i, c in enumerate(rt2sprite.GAME_PALETTE)],
        "groups": [],
        "spriteMaps": [],
        "sprites": sprites,
    }


def block_bytes(tier: Tier, shifts=len(rt2sprite.DEFAULT_SHIFTS)) -> int:
    """What rt2sprite will emit for one frame of this tier, all pre-shifts.

    The +4 is the pre-shift spill: a 2-pixel shift needs somewhere to land, so
    every sprite is stored one byte wider than it is. Section 5.1's table does
    not count it -- see the summary this tool prints.
    """
    w_bytes = (tier.w + MODE1_PIXELS_PER_BYTE) // MODE1_PIXELS_PER_BYTE
    return w_bytes * 2 * tier.h * shifts


# ---------------------------------------------------------------------------
#  Contact sheets
# ---------------------------------------------------------------------------

#  Firmware colours as the CRTC would put them on a monitor.
PEN_RGB = {
    PEN_SPACE: (0, 0, 0),
    PEN_FRIEND: (255, 255, 255),
    PEN_SHADE: (0, 128, 255),
    PEN_ENEMY: (255, 0, 0),
}


def contact_sheet(doc: dict, path: str, zoom: int = 8):
    """A PNG of every frame of every tier, for looking at with human eyes.

    Transparent pixels are a checkerboard, so "black hole in the hull" and
    "background" are told apart at a glance -- which is the exact bug the
    explicit mask exists to prevent.
    """
    from PIL import Image, ImageDraw       # imported here so the tests, and

    gutter, pad, header = 56, 6, 16        # anyone without PIL, need not care
    rows = []
    for sprite in doc["sprites"]:
        w, h = sprite["width"], sprite["height"]
        n = len(sprite["frames"])
        rows.append((sprite, w * zoom, h * zoom, n))

    sheet_w = gutter + max(n * (rw + pad) for _, rw, _, n in rows) + pad
    sheet_h = header + sum(rh + pad + 10 for _, _, rh, _ in rows) + pad
    img = Image.new("RGB", (sheet_w, sheet_h), (18, 18, 22))
    draw = ImageDraw.Draw(img)
    #  The step is whatever the project actually has in it, not YAW_STEPS: a
    #  sheet is drawn from a loaded .json as often as from a fresh render, and
    #  a caption that lies about the angles is worse than none.
    views = max(n for _, _, _, n in rows)
    step = 360 // views
    draw.text((6, 4),
              f"{doc['name']}  --  yaw 0..{step * (views - 1)} in {step} deg steps",
              fill=(200, 200, 210))

    y = header
    for sprite, rw, rh, n in rows:
        draw.text((6, y + rh // 2 - 4),
                  f"{sprite['name']}", fill=(190, 190, 200))
        draw.text((6, y + rh // 2 + 6),
                  f"{sprite['width']}x{sprite['height']}", fill=(120, 120, 130))
        for i, frame in enumerate(sprite["frames"]):
            x0 = gutter + i * (rw + pad)
            w, h = sprite["width"], sprite["height"]
            pixels = base64.b64decode(frame["pixels"])
            mask = base64.b64decode(frame["mask"])
            cell = Image.new("RGB", (w * zoom, h * zoom))
            cp = cell.load()
            for py in range(h * zoom):
                for px in range(w * zoom):
                    sx, sy = px // zoom, py // zoom
                    if mask[sy * w + sx]:
                        cp[px, py] = PEN_RGB[pixels[sy * w + sx]]
                    else:
                        checker = ((px // zoom) + (py // zoom)) & 1
                        cp[px, py] = (34, 34, 40) if checker else (26, 26, 30)
            img.paste(cell, (x0, y))
            draw.rectangle([x0 - 1, y - 1, x0 + rw, y + rh],
                           outline=(60, 60, 70))
            draw.text((x0, y + rh + 1), f"{i * step}", fill=(110, 110, 120))
        y += rh + pad + 10

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    img.save(path)
    return path


# ---------------------------------------------------------------------------
#  CLI
# ---------------------------------------------------------------------------

def write_project(doc: dict, art_dir: str) -> str:
    os.makedirs(art_dir, exist_ok=True)
    path = os.path.join(art_dir, f"{doc['name']}.retrotools.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    return path


def write_asm(doc: dict, json_path: str, asm_dir: str) -> str:
    warnings = rt2sprite.check_palette(doc, strict=True)
    text = rt2sprite.convert(doc, rt2sprite.DEFAULT_SHIFTS, warnings)
    os.makedirs(asm_dir, exist_ok=True)
    path = os.path.join(asm_dir, f"spr_{rt2sprite.identifier(doc['name'])}.asm")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ship", action="append", choices=sorted(SHIPS),
                    help="only this class (repeatable); default is all")
    ap.add_argument("--faction", choices=sorted(FACTION_PEN), default="friendly",
                    help="which pen is 'lit': 1 friendly (default), 3 enemy")
    ap.add_argument("--tier", action="append", choices=sorted(TIERS_BY_KEY),
                    help="only this size tier (repeatable); default is all")
    ap.add_argument("--art-dir", default=os.path.join(ROOT, "art"),
                    help="where the .retrotools.json projects go")
    ap.add_argument("--asm-dir", default=os.path.join(ROOT, "src", "gen"),
                    help="where the converted .asm goes")
    ap.add_argument("--png-dir", default=os.path.join(ROOT, "build", "ships"),
                    help="where the contact sheets go")
    ap.add_argument("--contact-sheet", action="store_true",
                    help="also write PNG contact sheets for review")
    ap.add_argument("--zoom", type=int, default=8,
                    help="contact sheet magnification (default 8)")
    ap.add_argument("--no-asm", action="store_true",
                    help="write the projects but do not run the converter")
    args = ap.parse_args(argv)

    keys = args.ship or sorted(SHIPS)
    tiers = [TIERS_BY_KEY[k] for k in (args.tier or [t.key for t in TIERS])]

    def warn(msg):
        print(f"warning: {msg}", file=sys.stderr)

    total = 0
    print(f"{'sprite':<22}{'px':>8}{'frames':>8}{'bytes':>8}"
          f"{'  (section 5.1 table)'}")
    for key in keys:
        ship = SHIPS[key]
        print(f"{ship.name} -- {ship.note}" if ship.note else ship.name)
        doc = build_project(key, args.faction, tiers=tiers, warn=warn)
        json_path = write_project(doc, args.art_dir)
        ship_total = 0
        for tier, sprite in zip(tiers, doc["sprites"]):
            n = len(sprite["frames"])
            size = n * block_bytes(tier)
            bare = n * (tier.w // MODE1_PIXELS_PER_BYTE) * 2 * tier.h * \
                len(rt2sprite.DEFAULT_SHIFTS)
            ship_total += size
            print(f"{sprite['name']:<22}{tier.w:>4}x{tier.h:<3}{n:>8}"
                  f"{size:>8}{bare:>10} without the spill byte")
        total += ship_total
        print(f"{'':<22}{'':>8}{'total':>8}{ship_total:>8}"
              f"  = {ship_total / 1024:.2f} KB  -> {json_path}")
        if not args.no_asm:
            print(f"{'':<22}{'':>8}{'':>8}{'':>8}  -> "
                  f"{write_asm(doc, json_path, args.asm_dir)}")
        if args.contact_sheet:
            png = os.path.join(args.png_dir, f"{doc['name']}.png")
            print(f"{'':<22}{'':>8}{'':>8}{'':>8}  -> "
                  f"{contact_sheet(doc, png, args.zoom)}")
    print(f"\n{len(keys)} class(es), {total} bytes = {total / 1024:.2f} KB "
          f"of bank space")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
