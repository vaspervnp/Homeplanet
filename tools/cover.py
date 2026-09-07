"""The disc cover, late-eighties style: docs/cover.png and docs/cover.pdf.

    python3 tools/cover.py

Front, spine and back of a 3-inch disc box inlay, composed with PIL out of
the game's own title screen and screenshots, at the proportions of the
Amstrad boxes of the day: a dark field, a chrome-lit name in big blocky
capitals, a diagonal band, the machine's badge in the corner, and a back
that sells the game in three paragraphs and six screenshots. The PDF is
one A4 landscape sheet at print size.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
DPI = 300
MM = DPI / 25.4
#  The inlay: back 130 mm, spine 14 mm, front 130 mm, all 180 mm tall.
BACK_W, SPINE_W, FRONT_W, H = int(130 * MM), int(14 * MM), int(130 * MM), int(180 * MM)
W = BACK_W + SPINE_W + FRONT_W

NAVY = (8, 12, 40)
INK = (245, 240, 225)
CYAN = (60, 200, 255)
RED = (230, 50, 40)
YELLOW = (255, 210, 60)
GREY = (150, 150, 165)


def font(size, bold=False, mono=False):
    cands = (["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf" if bold else
              "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"] if mono else
             ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"])
    for c in cands:
        if os.path.exists(c):
            return ImageFont.truetype(c, size)
    return ImageFont.load_default()


def starfield(img, seed=7, n=900):
    import random
    rnd = random.Random(seed)
    px = img.load()
    w, h = img.size
    for _ in range(n):
        x, y = rnd.randrange(w), rnd.randrange(h)
        v = rnd.choice([120, 160, 200, 255, 255])
        px[x, y] = (v, v, min(255, v + 20))
        if v == 255 and rnd.random() < 0.3:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                if 0 <= x + dx < w and 0 <= y + dy < h:
                    px[x + dx, y + dy] = (140, 140, 170)


def blocky(draw, xy, text, size, fill, shadow=None, spacing=0.08):
    """Big blocky capitals with a drop shadow, letter by letter."""
    f = font(size, bold=True)
    x, y = xy
    for ch in text:
        w = draw.textlength(ch, font=f)
        if shadow:
            draw.text((x + size * 0.06, y + size * 0.06), ch, font=f, fill=shadow)
        draw.text((x, y), ch, font=f, fill=fill)
        x += w + size * spacing
    return x


def chrome_title(base, xy, text, size):
    """The name in chrome: a vertical gradient through a mask, over its shadow."""
    f = font(size, bold=True)
    mask = Image.new("L", base.size, 0)
    md = ImageDraw.Draw(mask)
    x, y = xy
    for ch in text:
        md.text((x, y), ch, font=f, fill=255)
        x += md.textlength(ch, font=f) + size * 0.08
    bbox = mask.getbbox()
    grad = Image.new("RGB", base.size, (0, 0, 0))
    gd = ImageDraw.Draw(grad)
    top, bottom = bbox[1], bbox[3]
    for yy in range(top, bottom + 1):
        t = (yy - top) / max(1, bottom - top)
        #  chrome: white -> pale blue -> dark blue -> white again
        if t < 0.45:
            c = (int(255 - 60 * t / 0.45), int(255 - 40 * t / 0.45), 255)
        elif t < 0.55:
            c = (40, 60, 160)
        else:
            u = (t - 0.55) / 0.45
            c = (int(120 + 135 * u), int(140 + 115 * u), 255)
        gd.line([(0, yy), (base.size[0], yy)], fill=c)
    shadow = mask.filter(ImageFilter.GaussianBlur(size * 0.08))
    base.paste((0, 0, 0), mask=shadow.point(lambda v: min(255, v * 2)))
    off = Image.new("L", base.size, 0)
    off.paste(mask, (int(size * 0.07), int(size * 0.07)))
    base.paste((10, 20, 90), mask=off)
    base.paste(grad, mask=mask)
    return bbox


def front(img):
    d = ImageDraw.Draw(img)
    x0 = BACK_W + SPINE_W
    panel = Image.new("RGB", (FRONT_W, H), NAVY)
    starfield(panel, seed=3, n=1400)
    #  The diagonal band, the eighties' favourite shape.
    bd = ImageDraw.Draw(panel)
    band = [(0, int(H * 0.78)), (FRONT_W, int(H * 0.62)), (FRONT_W, int(H * 0.70)), (0, int(H * 0.86))]
    bd.polygon(band, fill=RED)
    band2 = [(0, int(H * 0.87)), (FRONT_W, int(H * 0.71)), (FRONT_W, int(H * 0.735)), (0, int(H * 0.895))]
    bd.polygon(band2, fill=YELLOW)
    #  The planet, big, lit from the upper left, with the title screen's own
    #  gibbous shading.
    r = int(FRONT_W * 0.34)
    cx, cy = int(FRONT_W * 0.66), int(H * 0.50)
    planet = Image.new("RGBA", (2 * r + 4, 2 * r + 4), (0, 0, 0, 0))
    pd = ImageDraw.Draw(planet)
    for i in range(r, 0, -1):
        t = i / r
        c = (int(30 + 40 * (1 - t)), int(120 + 90 * (1 - t)), int(210 + 45 * (1 - t)))
        pd.ellipse([r + 2 - i, r + 2 - i, r + 2 + i, r + 2 + i], fill=c + (255,))
    #  the night side
    night = Image.new("L", planet.size, 0)
    nd = ImageDraw.Draw(night)
    nd.ellipse([2, 2, 2 * r + 2, 2 * r + 2], fill=255)
    dx, dy = -int(r * 0.42), -int(r * 0.30)          # lit from the upper left
    nd.ellipse([2 + dx, 2 + dy, 2 * r + 2 + dx, 2 * r + 2 + dy], fill=0)
    night = night.filter(ImageFilter.GaussianBlur(r * 0.03))
    dark = Image.new("RGBA", planet.size, (4, 8, 30, 235))
    planet.paste(dark, mask=night)
    panel.paste(planet, (cx - r - 2, cy - r - 2), planet)
    #  A flight of ships, white chevrons in echelon, crossing the planet.
    for i, (fx, fy, s) in enumerate([(0.18, 0.44, 1.0), (0.30, 0.50, 0.85), (0.40, 0.42, 0.7), (0.52, 0.55, 0.6)]):
        px, py = int(FRONT_W * fx), int(H * fy)
        k = int(FRONT_W * 0.055 * s)
        bd.polygon([(px, py - k // 2), (px + k, py), (px, py + k // 2), (px + k // 3, py)], fill=INK, outline=(90, 110, 160))
        bd.line([(px - k, py), (px - k // 6, py)], fill=(120, 200, 255), width=max(2, k // 10))
    img.paste(panel, (x0, 0))
    #  The name, in chrome, across the top.
    chrome_title(img, (x0 + int(FRONT_W * 0.05), int(H * 0.06)), "HOMEPLANET", int(FRONT_W * 0.094))
    d = ImageDraw.Draw(img)
    d.text((x0 + int(FRONT_W * 0.06), int(H * 0.20)), "THE SLEEPERS' FLEET", font=font(int(H * 0.022), bold=True), fill=CYAN)
    #  On the band.
    d.text((x0 + int(FRONT_W * 0.06), int(H * 0.815)), "FLEET STRATEGY IN 3-D", font=font(int(H * 0.026), bold=True), fill=INK)
    d.text((x0 + int(FRONT_W * 0.06), int(H * 0.905)), "20 MISSIONS  •  8 SHIP CLASSES  •  2 ARCADE INTERLUDES",
           font=font(int(H * 0.0135), bold=True), fill=INK)
    #  The badge, bottom right, and the publisher.
    bw, bh = int(FRONT_W * 0.36), int(H * 0.055)
    bx, by = x0 + FRONT_W - bw - int(FRONT_W * 0.05), H - bh - int(H * 0.025)
    d.rectangle([bx, by, bx + bw, by + bh], fill=INK, outline=(0, 0, 0), width=4)
    d.text((bx + bw * 0.05, by + bh * 0.22), "AMSTRAD", font=font(int(bh * 0.40), bold=True), fill=(20, 20, 40))
    d.text((bx + bw * 0.60, by + bh * 0.26), "CPC 6128", font=font(int(bh * 0.34), bold=True), fill=RED)
    d.text((x0 + int(FRONT_W * 0.06), H - int(H * 0.06)), "DISK", font=font(int(H * 0.03), bold=True), fill=YELLOW)
    d.text((x0 + int(FRONT_W * 0.06), H - int(H * 0.03)), "REVIVE8BIT", font=font(int(H * 0.018), bold=True), fill=GREY)


def spine(img):
    d = ImageDraw.Draw(img)
    x0 = BACK_W
    d.rectangle([x0, 0, x0 + SPINE_W, H], fill=RED)
    txt = Image.new("RGB", (H, SPINE_W), RED)
    td = ImageDraw.Draw(txt)
    f = font(int(SPINE_W * 0.55), bold=True)
    td.text((int(H * 0.04), int(SPINE_W * 0.18)), "HOMEPLANET", font=f, fill=INK)
    td.text((int(H * 0.60), int(SPINE_W * 0.30)), "AMSTRAD CPC 6128", font=font(int(SPINE_W * 0.34), bold=True), fill=INK)
    img.paste(txt.rotate(90, expand=True), (x0, 0))


def back(img):
    d = ImageDraw.Draw(img)
    panel = Image.new("RGB", (BACK_W, H), NAVY)
    starfield(panel, seed=11, n=700)
    img.paste(panel, (0, 0))
    m = int(BACK_W * 0.06)
    y = int(H * 0.04)
    blocky(d, (m, y), "HOMEPLANET", int(BACK_W * 0.07), INK, shadow=(0, 0, 0))
    y += int(BACK_W * 0.10)
    body = font(int(H * 0.0155))
    lines = [
        "Nine generations ago a world was lost. What was saved of it",
        "sleeps in the hold of one Mothership: sixty thousand people,",
        "and the fleet that guards them. You command that fleet across",
        "twenty jumps to a planet that is only a name.",
        "",
        "The Vekhar hold the lanes. They will come at every stop, in waves",
        "that never end, and the fleet only ever shrinks - a ship that is",
        "lost is lost. Mine, build, salvage the enemy's wrecks, and decide",
        "at every jump how much of the fleet you are willing to spend.",
        "",
        "Orbit the battle in three dimensions. Give orders by squadron.",
        "Take the stick of one fighter yourself. Chase a runner through",
        "the vortex, and clear the lane in an arcade run between the jumps.",
    ]
    for ln in lines:
        d.text((m, y), ln, font=body, fill=INK if ln else INK)
        y += int(H * 0.021) if ln else int(H * 0.012)
    #  Six screenshots in two columns, with thin chrome frames.
    shots = ["shot-battle.png", "shot-title.png", "shot-chase.png", "shot-run.png"]
    sw = int((BACK_W - 3 * m) / 2)
    sh = int(sw * 200 / 320 * 1.15)   # a screen is 4:3 with the border cropped
    y += int(H * 0.01)
    for i, name in enumerate(shots):
        path = os.path.join(DOCS, name)
        if not os.path.exists(path):
            continue
        im = Image.open(path).convert("RGB")
        w, h = im.size
        im = im.crop((int(w * 0.07), int(h * 0.10), int(w * 0.93), int(h * 0.90))).resize((sw, sh), Image.NEAREST)
        x = m + (i % 2) * (sw + m)
        yy = y + (i // 2) * (sh + int(H * 0.012))
        d.rectangle([x - 4, yy - 4, x + sw + 4, yy + sh + 4], fill=(200, 200, 215))
        img.paste(im, (x, yy))
    y += 2 * (sh + int(H * 0.012)) + int(H * 0.012)
    small = font(int(H * 0.013))
    d.text((m, y), "REQUIRES AN AMSTRAD CPC 6128 WITH 128K AND A DISC DRIVE. JOYSTICK NOT SUPPORTED.", font=small, fill=GREY)
    y += int(H * 0.019)
    d.text((m, y), "Z80 ASSEMBLY, MODE 1, FOUR INKS. WRITTEN BY VASPER FOR REVIVE8BIT, 2026.", font=small, fill=GREY)
    #  The barcode, which every back had, and a catalogue number.
    bx, by = BACK_W - m - int(BACK_W * 0.22), H - int(H * 0.075)
    import random
    rnd = random.Random(1988)
    x = bx
    for _ in range(46):
        w = rnd.choice([2, 2, 3, 4, 5])
        d.rectangle([x, by, x + w, by + int(H * 0.04)], fill=INK)
        x += w + rnd.choice([2, 3, 4])
    d.text((bx, by + int(H * 0.043)), "R8B-1988-CPC", font=font(int(H * 0.011), mono=True), fill=INK)


def main() -> int:
    img = Image.new("RGB", (W, H), NAVY)
    back(img)
    spine(img)
    front(img)
    d = ImageDraw.Draw(img)
    #  Fold marks.
    for x in (BACK_W, BACK_W + SPINE_W):
        d.line([(x, 0), (x, int(H * 0.015))], fill=INK, width=2)
        d.line([(x, H - int(H * 0.015)), (x, H)], fill=INK, width=2)
    os.makedirs(DOCS, exist_ok=True)
    png = os.path.join(DOCS, "cover.png")
    img.save(png, dpi=(DPI, DPI))
    #  ...and the sheet: A4 landscape, the inlay centred at print size.
    from fpdf import FPDF
    pdf = FPDF(orientation="L", unit="mm", format="A4")
    pdf.add_page()
    total_w = W / MM
    pdf.image(png, x=(297 - total_w) / 2, y=(210 - 180) / 2, w=total_w)
    pdf.set_font("Helvetica", size=7)
    pdf.set_text_color(120, 120, 120)
    pdf.text(10, 205, "HOMEPLANET disc inlay -- back, spine, front -- 130 + 14 + 130 x 180 mm. Cut on the outer edge, fold on the marks.")
    pdf.output(os.path.join(DOCS, "cover.pdf"))
    print("wrote", png, "and docs/cover.pdf")
    return 0


if __name__ == "__main__":
    sys.exit(main())
