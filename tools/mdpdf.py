"""manual.md -> docs/manual.pdf, straight from Markdown with fpdf2.

    python3 tools/mdpdf.py manual.md docs/manual.pdf

A small Markdown reader -- headings, paragraphs, bullet lists, pipe tables,
images, and **bold**, *italic* and `code` inline -- feeding fpdf2's own
layout. It went through HTML and LibreOffice first, and the writer_web
filter sized every table column to its shortest word whatever width it was
given; this is a hundred lines that do exactly what the manual needs.
"""

import os
import re
import sys

from fpdf import FPDF
from fpdf.fonts import FontFace

FONTS = "/usr/share/fonts/truetype/dejavu"
NAVY = (26, 61, 143)


class Manual(FPDF):
    def __init__(self):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.add_font("dv", "", f"{FONTS}/DejaVuSans.ttf")
        self.add_font("dv", "B", f"{FONTS}/DejaVuSans-Bold.ttf")
        self.add_font("dv", "I", f"{FONTS}/DejaVuSans-Oblique.ttf")
        self.add_font("dv", "BI", f"{FONTS}/DejaVuSans-BoldOblique.ttf")
        self.set_margins(20, 18, 20)
        self.set_auto_page_break(True, margin=18)
        self.title_text = "HOMEPLANET"

    def footer(self):
        self.set_y(-12)
        self.set_font("dv", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 6, f"{self.title_text}  ·  {self.page_no()}", align="C")
        self.set_text_color(0, 0, 0)


def md_inline(s: str) -> str:
    """Markdown as fpdf2's markdown wants it: `code` and *em* become its own marks."""
    s = re.sub(r"`([^`]+)`", r"**\1**", s)
    s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"__\1__", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1", s)
    return s


def render(pdf: Manual, md: str, base: str) -> None:
    width = pdf.w - pdf.l_margin - pdf.r_margin
    para, table, lst_kind = [], [], None

    def flush_para():
        if para:
            pdf.set_font("dv", "", 10)
            pdf.multi_cell(width, 5.2, md_inline(" ".join(para)), markdown=True)
            pdf.ln(2.5)
            para.clear()

    def flush_table():
        if not table:
            return
        head, *rows = table
        n = len(head)
        widths = {2: [28, 72], 3: [24, 12, 64], 4: [10, 40, 10, 40]}.get(n, [100 // n] * n)
        if n == 4 and head[0].lower().startswith("class"):
            widths = [24, 10, 10, 56]
        if n == 2 and "reads" in head[0].lower():
            widths = [56, 44]
        pdf.set_font("dv", "", 9)
        with pdf.table(col_widths=widths, text_align="LEFT", line_height=4.6,
                       markdown=True, borders_layout="HORIZONTAL_LINES",
                       headings_style=FontFace(emphasis="BOLD", fill_color=(221, 228, 245)),
                       padding=1.2) as t:
            r = t.row()
            for c in head:
                r.cell(md_inline(c))
            for row in rows:
                r = t.row()
                for c in row + [""] * (n - len(row)):
                    r.cell(md_inline(c))
        pdf.ln(3)
        table.clear()

    for line in md.split("\n") + [""]:
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not all(re.fullmatch(r":?-+:?", c) for c in cells):
                table.append(cells)
            continue
        flush_table()
        m = re.match(r"^(#{1,3}) (.*)", line)
        if m:
            flush_para()
            level, text = len(m.group(1)), m.group(2)
            if level == 1:
                pdf.set_font("dv", "B", 22)
                pdf.set_text_color(*NAVY)
                pdf.multi_cell(width, 11, text)
                pdf.set_draw_color(*NAVY)
                pdf.set_line_width(0.8)
                pdf.line(pdf.l_margin, pdf.get_y() + 1, pdf.l_margin + width, pdf.get_y() + 1)
                pdf.ln(6)
            elif level == 2:
                if pdf.get_y() > pdf.h - 60:
                    pdf.add_page()
                pdf.ln(3)
                pdf.set_font("dv", "B", 14)
                pdf.set_text_color(*NAVY)
                pdf.multi_cell(width, 8, text)
                pdf.set_draw_color(170, 170, 190)
                pdf.set_line_width(0.3)
                pdf.line(pdf.l_margin, pdf.get_y(), pdf.l_margin + width, pdf.get_y())
                pdf.ln(3)
            else:
                if pdf.get_y() > pdf.h - 45:
                    pdf.add_page()
                pdf.ln(1.5)
                pdf.set_font("dv", "B", 11)
                pdf.set_text_color(30, 30, 30)
                pdf.multi_cell(width, 6.5, text)
                pdf.ln(1)
            pdf.set_text_color(0, 0, 0)
            continue
        if line.strip() == "---":
            flush_para()
            pdf.ln(2)
            continue
        img = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$", line.strip())
        if img:
            flush_para()
            path = os.path.join(base, img.group(2))
            if os.path.exists(path):
                w = min(width, 120)
                if pdf.get_y() + w * 0.71 > pdf.h - 25:
                    pdf.add_page()
                pdf.image(path, x=pdf.l_margin + (width - w) / 2, w=w)
                pdf.set_font("dv", "I", 8)
                pdf.set_text_color(90, 90, 90)
                pdf.cell(width, 5, img.group(1), align="C")
                pdf.ln(7)
                pdf.set_text_color(0, 0, 0)
            continue
        bullet = re.match(r"^\s*([-*]|\d+\.) (.*)", line)
        if bullet:
            flush_para()
            mark = "•" if bullet.group(1) in ("-", "*") else bullet.group(1)
            pdf.set_font("dv", "", 10)
            x = pdf.get_x()
            pdf.cell(7, 5.2, mark, align="R")
            pdf.set_x(x + 9)
            pdf.multi_cell(width - 9, 5.2, md_inline(bullet.group(2)), markdown=True)
            pdf.ln(1)
            lst_kind = "list"
            continue
        if line.startswith("  ") and lst_kind == "list" and line.strip():
            #  a wrapped bullet line: continue it, indented
            pdf.set_x(pdf.l_margin + 9)
            pdf.multi_cell(width - 9, 5.2, md_inline(line.strip()), markdown=True)
            pdf.ln(1)
            continue
        if line.strip() == "":
            flush_para()
            lst_kind = None
            continue
        para.append(line.strip())
    flush_para()
    flush_table()


def main(src: str, dst: str) -> int:
    md = open(src, encoding="utf-8").read()
    pdf = Manual()
    pdf.set_title("HOMEPLANET — Player's Manual")
    pdf.set_author("Revive8bit / Vasper")
    pdf.add_page()
    render(pdf, md, os.path.dirname(os.path.abspath(src)))
    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    pdf.output(dst)
    print(f"wrote {dst}, {pdf.page} pages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
