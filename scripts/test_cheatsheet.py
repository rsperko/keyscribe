import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from markdown_it import MarkdownIt
from pypdf import PdfReader


ROOT = Path(__file__).resolve().parents[1]


class CheatSheetTests(unittest.TestCase):
    def render(self, source, paper="letter"):
        folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        markdown = folder / "sheet.md"
        markdown.write_text(source, encoding="utf-8")
        output = folder / "sheet.pdf"
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/cheatsheet.py"),
             "--source", str(markdown), "--output", str(output), "--paper", paper],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return PdfReader(output)

    def test_print_sections_and_literal_symbols_survive_on_both_paper_sizes(self):
        source = """# What you can say

## First context

| Say | Works in | What happens |
| --- | --- | --- |
| `begin [name]`<br>Also: `launch [name]` | **Dictation** | Inserts `<CR>` & `**bold**`. |

---

## Second context

See [help](https://example.org/help).
"""
        for paper, width, height in [("letter", 612, 792), ("a4", 595, 842)]:
            with self.subTest(paper=paper):
                document = self.render(source, paper)
                self.assertEqual(len(document.pages), 2)
                first, second = [page.extract_text() for page in document.pages]
                for text in ["begin [name]", "Also: launch [name]", "<CR> & **bold**"]:
                    self.assertIn(text, first)
                self.assertNotIn("Second context", first)
                self.assertIn("Second context", second)
                self.assertAlmostEqual(float(document.pages[0].mediabox.width), width, delta=1)
                self.assertAlmostEqual(float(document.pages[0].mediabox.height), height, delta=1)
                links = [annotation.get_object().get("/A", {}).get("/URI")
                         for annotation in document.pages[1].get("/Annots", [])]
                self.assertIn("https://example.org/help", links)

    def test_long_tables_repeat_headers_without_losing_rows(self):
        rows = "\n".join(f"| Action {i:03} | Dictation | Effect {i:03} |" for i in range(90))
        document = self.render("# Actions\n\n| Say | Works in | What happens |\n| --- | --- | --- |\n" + rows)
        pages = [page.extract_text() for page in document.pages]
        self.assertGreater(len(pages), 1)
        for page in pages:
            self.assertIn("What happens", page)
        text = "\n".join(pages)
        for i in range(90):
            self.assertEqual(text.count(f"Action {i:03}"), 1)
            self.assertEqual(text.count(f"Effect {i:03}"), 1)

    def test_desk_reference_keeps_contexts_and_all_content_on_both_paper_sizes(self):
        source = (ROOT / "docs/cheat_sheet.md").read_text(encoding="utf-8")
        tokens = MarkdownIt("commonmark").enable("table").parse(source)
        headings = [tokens[i + 1].content for i, token in enumerate(tokens)
                    if token.type == "heading_open" and token.tag == "h2"]
        fragments = [child.content for token in tokens for child in token.children or []
                     if child.type in ("text", "code_inline") and child.content.strip()]
        for paper in ["letter", "a4"]:
            with self.subTest(paper=paper):
                document = self.render(source, paper)
                pages = [" ".join(page.extract_text().split()) for page in document.pages]
                self.assertEqual(len(pages), len(headings))
                for page, heading in zip(pages, headings):
                    self.assertIn(heading, page)
                text = " ".join(pages)
                for fragment in fragments:
                    self.assertIn(" ".join(fragment.split()), text)


if __name__ == "__main__":
    unittest.main()
