from __future__ import annotations

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from PIL import Image, ImageChops
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen.canvas import Canvas

from interview_question_bank.styles import register_fonts
from interview_question_bank.visual_review import (
    build_contact_sheets,
    build_grayscale_samples,
    render_pages_with_poppler,
    screen_rendered_pages,
)


class VisualReviewPipelineTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.pdf_path = self.root / "fixture.pdf"
        self._build_fixture(self.pdf_path)

    def tearDown(self) -> None:
        self._temporary.cleanup()

    @staticmethod
    def _build_fixture(path: Path) -> None:
        font = register_fonts().body
        canvas = Canvas(str(path), pagesize=A4)
        canvas.setFont(font, 12)
        canvas.drawString(72, 760, "COVER")
        canvas.showPage()
        canvas.setFont(font, 10)
        canvas.drawString(72, 760, "BODY " * 30)
        safe_y = 17 * mm
        canvas.rect(80, safe_y - 5, 18, 10, stroke=0, fill=1)
        canvas.showPage()
        canvas.setFont(font, 12)
        canvas.drawString(72, 760, "UNIFIED SCORE · 0—4")
        canvas.showPage()
        canvas.setFont(font, 9)
        for index in range(18):
            canvas.drawString(72, 760 - index * 20, f"DENSE BODY {index} " * 8)
        canvas.save()

    def test_poppler_render_count_matches_pdf_pages(self) -> None:
        render_dir = self.root / "render"

        pages = render_pages_with_poppler(self.pdf_path, render_dir, dpi=144)

        self.assertEqual(len(pages), 4)
        self.assertTrue(all(path.parent == render_dir for path in pages))
        self.assertEqual(
            ["page-1.png", "page-2.png", "page-3.png", "page-4.png"],
            [path.name for path in pages],
        )
        self.assertTrue((render_dir / "render-manifest.json").is_file())

    def test_poppler_render_rejects_non_empty_output_directory(self) -> None:
        render_dir = self.root / "render"
        render_dir.mkdir()
        (render_dir / "stale.png").write_bytes(b"stale")

        with self.assertRaisesRegex(ValueError, "empty"):
            render_pages_with_poppler(self.pdf_path, render_dir)

    def test_contact_sheets_cover_every_page_once(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "render",
            dpi=144,
        )
        contact_dir = self.root / "contact"

        sheets = build_contact_sheets(pages, contact_dir, pages_per_sheet=12)
        manifest = json.loads(
            (contact_dir / "manifest.json").read_text(encoding="utf-8")
        )
        covered = [
            page_number
            for sheet in manifest["sheets"]
            for page_number in sheet["pages"]
        ]

        self.assertEqual(covered, [1, 2, 3, 4])
        self.assertEqual(len(sheets), 1)
        self.assertEqual("contact-001-004.png", sheets[0].name)
        self.assertEqual(12, manifest["pages_per_sheet"])

    def test_contact_sheet_last_sheet_does_not_drop_page(self) -> None:
        page_dir = self.root / "fake-pages"
        page_dir.mkdir()
        pages = []
        for page_number in range(1, 14):
            path = page_dir / f"page-{page_number}.png"
            Image.new("RGB", (120, 160), "white").save(path)
            pages.append(path)

        contact_dir = self.root / "contact"
        sheets = build_contact_sheets(pages, contact_dir)
        manifest = json.loads(
            (contact_dir / "manifest.json").read_text(encoding="utf-8")
        )
        covered = [
            page_number
            for sheet in manifest["sheets"]
            for page_number in sheet["pages"]
        ]

        self.assertEqual(list(range(1, 14)), covered)
        self.assertEqual(2, len(sheets))
        self.assertEqual([13], manifest["sheets"][-1]["pages"])

    def test_grayscale_samples_select_cover_chapter_and_dense_body(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "render",
            dpi=144,
        )
        output_dir = self.root / "grayscale"

        samples = build_grayscale_samples(
            self.pdf_path,
            pages,
            output_dir,
        )

        self.assertEqual({"cover", "chapter", "dense-body"}, set(samples))
        for path in samples.values():
            with Image.open(path) as image:
                self.assertEqual("L", image.mode)
        with Image.open(pages[2]) as chapter, Image.open(samples["chapter"]) as sample:
            self.assertIsNone(ImageChops.difference(chapter.convert("L"), sample).getbbox())
        with Image.open(pages[3]) as dense, Image.open(samples["dense-body"]) as sample:
            self.assertIsNone(ImageChops.difference(dense.convert("L"), sample).getbbox())

    def test_screening_reports_advisory_metrics_and_sorted_suspicious_pages(
        self,
    ) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "render",
            dpi=144,
        )
        report_path = self.root / "screening.json"

        report = screen_rendered_pages(pages, report_path=report_path)

        self.assertEqual(4, report["page_count"])
        self.assertEqual(4, len(report["dimensions"]))
        self.assertEqual(4, len(report["near_white_ratio"]))
        self.assertEqual(4, len(report["near_black_ratio"]))
        self.assertIn(2, report["footer_crossing_candidates"])
        self.assertIn(1, report["low_text_pages"])
        self.assertEqual(
            sorted(set(report["suspicious_pages"])),
            report["suspicious_pages"],
        )
        self.assertEqual(report, json.loads(report_path.read_text(encoding="utf-8")))
        self.assertIn("advisory", report["note"].lower())

    def test_screening_reports_dimension_mismatch(self) -> None:
        page_dir = self.root / "mixed"
        page_dir.mkdir()
        first = page_dir / "page-1.png"
        second = page_dir / "page-2.png"
        Image.new("RGB", (120, 160), "white").save(first)
        Image.new("RGB", (121, 160), "white").save(second)

        report = screen_rendered_pages(
            [second, first],
            report_path=self.root / "mixed-screening.json",
        )

        self.assertEqual([2], report["dimension_mismatch_pages"])
        self.assertEqual(sorted(report["suspicious_pages"]), report["suspicious_pages"])


if __name__ == "__main__":
    unittest.main()
