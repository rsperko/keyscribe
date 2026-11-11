import argparse
from html import escape
from pathlib import Path
from urllib.parse import urljoin

from markdown_it import MarkdownIt
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Table, TableStyle


ROOT = Path(__file__).resolve().parents[1]
INK = colors.HexColor("#203138")
ACCENT = colors.HexColor("#275B60")
MUTED = colors.HexColor("#526166")


def inline(tokens, base_url):
    parts = []
    for token in tokens:
        if token.type == "text":
            parts.append(escape(token.content))
        elif token.type == "code_inline":
            parts.append(f'<font name="Helvetica-Bold">{escape(token.content)}</font>')
        elif token.type in ("softbreak", "hardbreak"):
            parts.append(" " if token.type == "softbreak" else "<br/>")
        elif token.type == "html_inline" and token.content.lower() in ("<br>", "<br/>", "<br />"):
            parts.append("<br/>")
        elif token.type in ("strong_open", "strong_close", "em_open", "em_close"):
            tag = "b" if token.type.startswith("strong") else "i"
            parts.append(f"<{'' if token.nesting == 1 else '/'}{tag}>")
        elif token.type == "link_open":
            href = escape(urljoin(base_url, token.attrGet("href")), quote=True)
            parts.append(f'<link href="{href}" color="#275B60">')
        elif token.type == "link_close":
            parts.append("</link>")
        else:
            raise ValueError(f"Unsupported inline Markdown: {token.type}")
    return "".join(parts)


def styles():
    body = ParagraphStyle("body", fontName="Helvetica", fontSize=10.2, leading=14,
                          textColor=INK, spaceAfter=8)
    return {
        "body": body,
        "cell": ParagraphStyle("cell", parent=body, fontSize=10, leading=13, spaceAfter=0),
        "header": ParagraphStyle("header", parent=body, fontName="Helvetica-Bold",
                                 fontSize=9, leading=12, textColor=colors.white, spaceAfter=0),
        "h1": ParagraphStyle("h1", parent=body, fontName="Helvetica-Bold", fontSize=25,
                             leading=29, spaceAfter=7, keepWithNext=True),
        "h2": ParagraphStyle("h2", parent=body, fontName="Helvetica-Bold", fontSize=19,
                             leading=23, textColor=ACCENT, spaceBefore=5, spaceAfter=9, keepWithNext=True),
        "h3": ParagraphStyle("h3", parent=body, fontName="Helvetica-Bold", fontSize=11,
                             leading=15, spaceBefore=7, spaceAfter=4, keepWithNext=True),
    }


def story(markdown, width, base_url):
    tokens = MarkdownIt("commonmark").enable("table").parse(markdown)
    sheet_styles = styles()
    flow = []
    current_style = "body"
    rows = None
    row = None
    header = False
    for token in tokens:
        if token.type == "heading_open":
            current_style = token.tag
        elif token.type == "heading_close":
            current_style = "body"
        elif token.type == "table_open":
            rows = []
            header = True
        elif token.type == "thead_close":
            header = False
        elif token.type == "tr_open":
            row = []
        elif token.type == "tr_close":
            if len(row) != 3:
                raise ValueError("Cheat sheet tables must have three columns")
            rows.append(row)
            row = None
        elif token.type == "table_close":
            table = Table(rows, colWidths=[width * n for n in (0.36, 0.23, 0.41)],
                          repeatRows=1, hAlign="LEFT", spaceAfter=9)
            table.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), INK),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F2F5F5")]),
                ("LINEBELOW", (0, 1), (-1, -1), 0.35, colors.HexColor("#CDD6D8")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]))
            flow.append(table)
            rows = None
        elif token.type == "inline":
            style = "header" if header else "cell" if row is not None else current_style
            markup = inline(token.children, base_url)
            if row == [] and not header and "<br/>" in markup:
                phrase, alternatives = markup.split("<br/>", 1)
                markup = f'{phrase}<br/><font size="8.7" color="#526166">{alternatives}</font>'
            paragraph = Paragraph(markup, sheet_styles[style])
            if row is not None:
                row.append(paragraph)
            else:
                flow.append(paragraph)
        elif token.type == "hr":
            flow.append(PageBreak())
        elif token.type not in {
            "paragraph_open", "paragraph_close", "thead_open", "tbody_open", "tbody_close",
            "th_open", "th_close", "td_open", "td_close",
        }:
            raise ValueError(f"Unsupported block Markdown: {token.type}")
    return flow


def page_frame(product):
    def draw(canvas, document):
        frame(canvas, document, product)
    return draw


def frame(canvas, document, product):
    width, height = document.pagesize
    canvas.saveState()
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica-Bold", 8)
    canvas.drawString(36, height - 29, f"{product.upper()} / WHAT YOU CAN SAY")
    canvas.setFont("Helvetica", 8)
    canvas.drawRightString(width - 36, height - 29, "DESK REFERENCE")
    canvas.setStrokeColor(colors.HexColor("#CDD6D8"))
    canvas.setLineWidth(0.5)
    canvas.line(36, 31, width - 36, 31)
    canvas.drawString(36, 19, "Default phrases. Your modes and saved commands may differ.")
    canvas.drawRightString(width - 36, 19, str(document.page))
    canvas.restoreState()


def main():
    parser = argparse.ArgumentParser(description="Print the voice cheat sheet from its Markdown source.")
    parser.add_argument("--source", type=Path, default=ROOT / "docs/cheat_sheet.md")
    parser.add_argument("--output", type=Path, default=ROOT / "output/pdf/keyscribe-cheat-sheet-letter.pdf")
    parser.add_argument("--paper", choices=("letter", "a4"), default="letter")
    parser.add_argument("--product", default="KeyScribe")
    parser.add_argument("--repo-url", default="https://github.com/rsperko/keyscribe/blob/main/")
    args = parser.parse_args()
    page_size = letter if args.paper == "letter" else A4
    args.output.parent.mkdir(parents=True, exist_ok=True)
    document = SimpleDocTemplate(str(args.output), pagesize=page_size, leftMargin=36, rightMargin=36,
                                 topMargin=47, bottomMargin=42, title=f"{args.product} - What you can say",
                                 author=args.product, subject="Spoken phrases, contexts, and effects")
    source = args.source.resolve()
    base_url = urljoin(args.repo_url, "docs/")
    if source.is_relative_to(ROOT):
        base_url = urljoin(args.repo_url, str(source.relative_to(ROOT)))
    document.build(story(source.read_text(encoding="utf-8"), document.width, base_url),
                   onFirstPage=page_frame(args.product), onLaterPages=page_frame(args.product))
    print(args.output)


if __name__ == "__main__":
    main()
