from __future__ import annotations

import json
from hashlib import sha256
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

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


ROOT = Path(__file__).resolve().parents[3]


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
        canvas.showPage()
        canvas.setFont(font, 8)
        canvas.drawString(72, 800, "UNIFIED SCORE · 0—4")
        for index in range(30):
            canvas.drawString(
                40,
                770 - index * 18,
                f"SECOND CHAPTER MUST NEVER BE DENSE BODY {index} " * 8,
            )
        canvas.save()

    @staticmethod
    def _build_numbered_fixture(path: Path, page_count: int) -> None:
        canvas = Canvas(str(path), pagesize=A4)
        for page_number in range(1, page_count + 1):
            canvas.drawString(72, 760, f"PAGE {page_number}")
            if page_number < page_count:
                canvas.showPage()
        canvas.save()

    @staticmethod
    def _build_cli_fixture(path: Path) -> None:
        font = register_fonts().body
        canvas = Canvas(str(path), pagesize=A4)
        canvas.setFont(font, 12)
        canvas.drawString(72, 760, "CLI COVER · UNIFIED SCORE · 0—4")
        canvas.showPage()
        canvas.setFont(font, 9)
        for index in range(18):
            canvas.drawString(72, 760 - index * 20, f"CLI DENSE BODY {index} " * 8)
        canvas.save()

    def _run_visual_cli(
        self,
        pdf_path: Path,
        *,
        render_dir: Path,
        contact_dir: Path,
        grayscale_dir: Path,
        screening_report: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT / "tmp" / "pdfs")
        return subprocess.run(
            [
                sys.executable,
                "-m",
                "interview_question_bank.visual_review",
                str(pdf_path),
                "--render-dir",
                str(render_dir),
                "--contact-dir",
                str(contact_dir),
                "--grayscale-dir",
                str(grayscale_dir),
                "--screening-report",
                str(screening_report),
                "--dpi",
                "144",
            ],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_builds_complete_identity_bound_evidence(self) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        render_dir = self.root / "cli-render"
        contact_dir = self.root / "cli-contact"
        grayscale_dir = self.root / "cli-grayscale"
        screening_report = self.root / "cli-screening.json"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=render_dir,
            contact_dir=contact_dir,
            grayscale_dir=grayscale_dir,
            screening_report=screening_report,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(
            ["page-1.png", "page-2.png"],
            [path.name for path in sorted(render_dir.glob("page-*.png"))],
        )
        render_manifest = json.loads(
            (render_dir / "render-manifest.json").read_text(encoding="utf-8")
        )
        contact_manifest = json.loads(
            (contact_dir / "manifest.json").read_text(encoding="utf-8")
        )
        grayscale_manifest = json.loads(
            (grayscale_dir / "manifest.json").read_text(encoding="utf-8")
        )
        screening = json.loads(screening_report.read_text(encoding="utf-8"))
        summary = json.loads(completed.stdout)
        render_identity = {
            key: render_manifest[key]
            for key in contact_manifest["render_identity"]
        }

        self.assertEqual([1, 2], render_manifest["page_numbers"])
        self.assertEqual([[1, 2]], [
            sheet["pages"] for sheet in contact_manifest["sheets"]
        ])
        self.assertEqual(
            {"cover.png", "chapter.png", "dense-body.png"},
            {path.name for path in grayscale_dir.glob("*.png")},
        )
        self.assertEqual(
            render_identity,
            contact_manifest["render_identity"],
        )
        self.assertEqual(
            render_identity,
            grayscale_manifest["render_identity"],
        )
        self.assertEqual(
            render_identity,
            screening["render_identity"],
        )
        self.assertEqual(
            render_identity,
            summary["render_identity"],
        )
        self.assertEqual(2, summary["page_count"])
        self.assertEqual(2, summary["rendered_pages"])
        self.assertEqual(1, summary["contact_sheets"])
        self.assertEqual(
            ["chapter", "cover", "dense-body"],
            summary["grayscale_samples"],
        )
        self.assertEqual(str(screening_report.resolve()), summary["screening_report"])

    def test_cli_rejects_non_empty_evidence_directory_without_overwrite(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        render_dir = self.root / "existing-render"
        render_dir.mkdir()
        stale = render_dir / "stale.txt"
        stale.write_text("preserve me", encoding="utf-8")
        contact_dir = self.root / "unused-contact"
        grayscale_dir = self.root / "unused-grayscale"
        screening_report = self.root / "unused-screening.json"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=render_dir,
            contact_dir=contact_dir,
            grayscale_dir=grayscale_dir,
            screening_report=screening_report,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "evidence directory must not already exist",
            completed.stderr,
        )
        self.assertEqual("preserve me", stale.read_text(encoding="utf-8"))
        self.assertFalse(contact_dir.exists())
        self.assertFalse(grayscale_dir.exists())
        self.assertFalse(screening_report.exists())

    def test_cli_preflights_later_evidence_directories_before_rendering(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        render_dir = self.root / "must-not-render"
        contact_dir = self.root / "existing-contact"
        contact_dir.mkdir()
        stale = contact_dir / "contact-001-002.png"
        stale.write_bytes(b"old contact evidence")

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=render_dir,
            contact_dir=contact_dir,
            grayscale_dir=self.root / "must-not-grayscale",
            screening_report=self.root / "must-not-screen.json",
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "evidence directory must not already exist",
            completed.stderr,
        )
        self.assertEqual(b"old contact evidence", stale.read_bytes())
        self.assertFalse(render_dir.exists())

    def test_cli_rejects_screening_report_inside_any_evidence_directory(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        for report_parent_name in ("render", "contact", "grayscale"):
            with self.subTest(report_parent=report_parent_name):
                case_root = self.root / f"report-in-{report_parent_name}"
                directories = {
                    name: case_root / name
                    for name in ("render", "contact", "grayscale")
                }
                report_name = (
                    "manifest.json"
                    if report_parent_name == "contact"
                    else "screening.json"
                )
                screening_report = (
                    directories[report_parent_name] / report_name
                )

                completed = self._run_visual_cli(
                    pdf_path,
                    render_dir=directories["render"],
                    contact_dir=directories["contact"],
                    grayscale_dir=directories["grayscale"],
                    screening_report=screening_report,
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertIn(
                    "screening report must be outside evidence directories",
                    completed.stderr,
                )
                self.assertFalse(case_root.exists())

    def test_cli_rejects_equal_or_nested_evidence_directories_before_rendering(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        cases = {
            "all-same": ("evidence", "evidence", "evidence"),
            "render-parent": (
                "evidence",
                "evidence/contact",
                "grayscale",
            ),
            "contact-parent": (
                "evidence/render",
                "evidence",
                "grayscale",
            ),
            "grayscale-parent": (
                "render",
                "evidence/grayscale",
                "evidence",
            ),
        }
        for case_name, relative_paths in cases.items():
            with self.subTest(case=case_name):
                case_root = self.root / f"overlap-{case_name}"
                render_dir, contact_dir, grayscale_dir = (
                    case_root / relative_path
                    for relative_path in relative_paths
                )

                completed = self._run_visual_cli(
                    pdf_path,
                    render_dir=render_dir,
                    contact_dir=contact_dir,
                    grayscale_dir=grayscale_dir,
                    screening_report=self.root / f"{case_name}-screening.json",
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertIn(
                    "evidence directories must be disjoint",
                    completed.stderr,
                )
                self.assertFalse(case_root.exists())

    def test_cli_rejects_casefolded_equal_evidence_directories_before_rendering(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        case_root = self.root / "casefold-equal"
        screening_report = self.root / "casefold-equal-screening.json"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=case_root / "Evidence",
            contact_dir=case_root / "evidence",
            grayscale_dir=case_root / "grayscale",
            screening_report=screening_report,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "evidence directories must be disjoint",
            completed.stderr,
        )
        self.assertFalse(case_root.exists())
        self.assertFalse(screening_report.exists())

    def test_cli_rejects_casefolded_nested_evidence_directories_before_rendering(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        case_root = self.root / "casefold-nested"
        screening_report = self.root / "casefold-nested-screening.json"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=case_root / "Evidence",
            contact_dir=case_root / "eViDeNcE" / "contact",
            grayscale_dir=case_root / "grayscale",
            screening_report=screening_report,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "evidence directories must be disjoint",
            completed.stderr,
        )
        self.assertFalse(case_root.exists())
        self.assertFalse(screening_report.exists())

    def test_cli_rejects_screening_report_inside_casefolded_evidence_alias(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        case_root = self.root / "casefold-report"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=case_root / "Evidence",
            contact_dir=case_root / "contact",
            grayscale_dir=case_root / "grayscale",
            screening_report=case_root / "evidence" / "screening.json",
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "screening report must be outside evidence directories",
            completed.stderr,
        )
        self.assertFalse(case_root.exists())

    def test_cli_rejects_nfc_nfd_equivalent_evidence_directories_before_rendering(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        case_root = self.root / "unicode-equivalent"
        screening_report = self.root / "unicode-equivalent-screening.json"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=case_root / "Caf\u00e9",
            contact_dir=case_root / "Cafe\u0301",
            grayscale_dir=case_root / "grayscale",
            screening_report=screening_report,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn(
            "evidence directories must be disjoint",
            completed.stderr,
        )
        self.assertFalse(case_root.exists())
        self.assertFalse(screening_report.exists())

    def test_cli_rejects_any_preexisting_empty_evidence_directory(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        for existing_name in ("render", "contact", "grayscale"):
            with self.subTest(existing=existing_name):
                case_root = self.root / f"empty-{existing_name}"
                directories = {
                    name: case_root / name
                    for name in ("render", "contact", "grayscale")
                }
                directories[existing_name].mkdir(parents=True)

                completed = self._run_visual_cli(
                    pdf_path,
                    render_dir=directories["render"],
                    contact_dir=directories["contact"],
                    grayscale_dir=directories["grayscale"],
                    screening_report=case_root / "screening.json",
                )

                self.assertNotEqual(0, completed.returncode)
                self.assertIn(
                    "evidence directory must not already exist",
                    completed.stderr,
                )
                self.assertTrue(directories[existing_name].is_dir())
                self.assertEqual([], list(directories[existing_name].iterdir()))
                self.assertFalse(
                    any(
                        path.exists()
                        for name, path in directories.items()
                        if name != existing_name
                    )
                )

    def test_cli_rejects_existing_screening_report_without_overwrite(
        self,
    ) -> None:
        pdf_path = self.root / "cli-fixture.pdf"
        self._build_cli_fixture(pdf_path)
        screening_report = self.root / "existing-screening.json"
        screening_report.write_text('{"preserve": true}\n', encoding="utf-8")
        render_dir = self.root / "must-not-render"

        completed = self._run_visual_cli(
            pdf_path,
            render_dir=render_dir,
            contact_dir=self.root / "must-not-contact",
            grayscale_dir=self.root / "must-not-grayscale",
            screening_report=screening_report,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("screening report must not already exist", completed.stderr)
        self.assertEqual(
            '{"preserve": true}\n',
            screening_report.read_text(encoding="utf-8"),
        )
        self.assertFalse(render_dir.exists())

    def test_poppler_render_count_matches_pdf_pages(self) -> None:
        render_dir = self.root / "render"

        pages = render_pages_with_poppler(self.pdf_path, render_dir, dpi=144)

        self.assertEqual(len(pages), 5)
        self.assertTrue(all(path.parent == render_dir for path in pages))
        self.assertEqual(
            [
                "page-1.png",
                "page-2.png",
                "page-3.png",
                "page-4.png",
                "page-5.png",
            ],
            [path.name for path in pages],
        )
        manifest = json.loads(
            (render_dir / "render-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(str(self.pdf_path.resolve()), manifest["source_pdf"])
        self.assertEqual(sha256(self.pdf_path.read_bytes()).hexdigest(), manifest["pdf_sha256"])
        self.assertEqual(5, manifest["page_count"])
        self.assertEqual(144, manifest["dpi"])
        self.assertEqual([1, 2, 3, 4, 5], manifest["page_numbers"])
        self.assertEqual([path.name for path in pages], manifest["page_files"])
        self.assertEqual(2, len(manifest["dimensions"]))

    def test_poppler_render_rejects_non_empty_output_directory(self) -> None:
        render_dir = self.root / "render"
        render_dir.mkdir()
        (render_dir / "stale.png").write_bytes(b"stale")

        with self.assertRaisesRegex(ValueError, "empty"):
            render_pages_with_poppler(self.pdf_path, render_dir)

    def test_poppler_render_rejects_gapped_output_sequence(self) -> None:
        render_dir = self.root / "gapped-poppler"

        def write_gapped_pages(command, **_kwargs):
            prefix = Path(command[-1])
            Image.new("RGB", (120, 160), "white").save(
                prefix.parent / f"{prefix.name}-1.png"
            )
            Image.new("RGB", (120, 160), "white").save(
                prefix.parent / f"{prefix.name}-3.png"
            )
            return subprocess.CompletedProcess(command, 0, "", "")

        with patch(
            "interview_question_bank.visual_review.subprocess.run",
            side_effect=write_gapped_pages,
        ):
            with self.assertRaisesRegex(ValueError, "contiguous"):
                render_pages_with_poppler(self.pdf_path, render_dir, dpi=72)

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

        self.assertEqual(covered, [1, 2, 3, 4, 5])
        self.assertEqual(len(sheets), 1)
        self.assertEqual("contact-001-005.png", sheets[0].name)
        self.assertEqual(12, manifest["pages_per_sheet"])
        self.assertEqual(
            sha256(self.pdf_path.read_bytes()).hexdigest(),
            manifest["render_identity"]["pdf_sha256"],
        )

    def test_contact_sheet_last_sheet_does_not_drop_page(self) -> None:
        numbered_pdf = self.root / "numbered-13.pdf"
        self._build_numbered_fixture(numbered_pdf, 13)
        pages = render_pages_with_poppler(
            numbered_pdf,
            self.root / "numbered-render",
            dpi=72,
        )

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
        self.assertIn(10, manifest["sheets"][0]["pages"])

    def test_contact_sheets_reject_gapped_page_suffixes(self) -> None:
        page_dir = self.root / "gapped"
        page_dir.mkdir()
        first = page_dir / "page-1.png"
        third = page_dir / "page-3.png"
        Image.new("RGB", (120, 160), "white").save(first)
        Image.new("RGB", (120, 160), "white").save(third)

        with self.assertRaisesRegex(ValueError, "contiguous"):
            build_contact_sheets([third, first], self.root / "gapped-contact")

    def test_contact_sheets_reject_duplicate_page_suffixes(self) -> None:
        page_dir = self.root / "duplicate"
        page_dir.mkdir()
        first = page_dir / "page-1.png"
        Image.new("RGB", (120, 160), "white").save(first)

        with self.assertRaisesRegex(ValueError, "unique"):
            build_contact_sheets([first, first], self.root / "duplicate-contact")

    def test_contact_sheets_reject_non_numeric_page_suffix(self) -> None:
        page_dir = self.root / "wrong-suffix"
        page_dir.mkdir()
        page = page_dir / "page-final.png"
        Image.new("RGB", (120, 160), "white").save(page)

        with self.assertRaisesRegex(ValueError, "numeric suffix"):
            build_contact_sheets([page], self.root / "wrong-suffix-contact")

    def test_contact_sheets_require_render_manifest(self) -> None:
        page_dir = self.root / "manifestless"
        page_dir.mkdir()
        first = page_dir / "page-1.png"
        Image.new("RGB", (120, 160), "white").save(first)

        with self.assertRaisesRegex(ValueError, "render manifest"):
            build_contact_sheets([first], self.root / "manifestless-contact")

    def test_contact_sheets_reject_pdf_replaced_after_render(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "bound-render",
            dpi=72,
        )
        self._build_numbered_fixture(self.pdf_path, 1)

        with self.assertRaisesRegex(ValueError, "SHA256"):
            build_contact_sheets(pages, self.root / "replaced-contact")

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
        with Image.open(pages[4]) as second_chapter, Image.open(
            samples["dense-body"]
        ) as sample:
            self.assertIsNotNone(
                ImageChops.difference(second_chapter.convert("L"), sample).getbbox()
            )
        manifest = json.loads(
            (output_dir / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            sha256(self.pdf_path.read_bytes()).hexdigest(),
            manifest["render_identity"]["pdf_sha256"],
        )
        self.assertEqual(
            {"cover": 1, "chapter": 3, "dense-body": 4},
            manifest["selections"],
        )

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

        self.assertEqual(5, report["page_count"])
        self.assertEqual(5, len(report["dimensions"]))
        self.assertEqual(5, len(report["near_white_ratio"]))
        self.assertEqual(5, len(report["near_black_ratio"]))
        self.assertIn(2, report["footer_crossing_candidates"])
        self.assertIn(1, report["low_text_pages"])
        self.assertEqual(
            sorted(set(report["suspicious_pages"])),
            report["suspicious_pages"],
        )
        self.assertEqual(report, json.loads(report_path.read_text(encoding="utf-8")))
        self.assertIn("advisory", report["note"].lower())
        self.assertEqual(
            sha256(self.pdf_path.read_bytes()).hexdigest(),
            report["render_identity"]["pdf_sha256"],
        )

    def test_screening_rejects_existing_report_without_overwrite(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "exclusive-screening-render",
            dpi=72,
        )
        report_path = self.root / "existing-api-screening.json"
        report_path.write_text('{"preserve": true}\n', encoding="utf-8")

        with self.assertRaisesRegex(
            ValueError,
            "screening report must not already exist",
        ):
            screen_rendered_pages(pages, report_path=report_path)

        self.assertEqual(
            '{"preserve": true}\n',
            report_path.read_text(encoding="utf-8"),
        )

    def test_screening_rejects_inconsistent_rendered_page_size(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "mixed-render",
            dpi=72,
        )
        with Image.open(pages[1]) as source:
            source.resize((source.width + 1, source.height)).save(pages[1])

        with self.assertRaisesRegex(ValueError, "dimensions"):
            screen_rendered_pages(
                pages,
                report_path=self.root / "mixed-screening.json",
            )

    def test_screening_rejects_corrupt_png(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "corrupt-render",
            dpi=72,
        )
        pages[1].write_bytes(b"not a PNG")

        with self.assertRaisesRegex(ValueError, "unreadable rendered page"):
            screen_rendered_pages(
                pages,
                report_path=self.root / "corrupt-screening.json",
            )

    def test_screening_requires_render_manifest(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "manifestless-render",
            dpi=72,
        )
        (pages[0].parent / "render-manifest.json").unlink()

        with self.assertRaisesRegex(ValueError, "render manifest"):
            screen_rendered_pages(
                pages,
                report_path=self.root / "manifestless-screening.json",
            )

    def test_screening_rejects_forged_manifest_page_count(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "forged-count-render",
            dpi=72,
        )
        manifest_path = pages[0].parent / "render-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["page_count"] = 1
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "page_count"):
            screen_rendered_pages(
                pages,
                report_path=self.root / "forged-count-screening.json",
            )

    def test_grayscale_rejects_forged_manifest_sha(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "forged-sha-render",
            dpi=72,
        )
        manifest_path = pages[0].parent / "render-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["pdf_sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "SHA256"):
            build_grayscale_samples(
                self.pdf_path,
                pages,
                self.root / "forged-sha-grayscale",
            )

    def test_grayscale_rejects_an_unrelated_pdf_with_same_page_count(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.root / "wrong-pdf-render",
            dpi=72,
        )
        other_pdf = self.root / "unrelated.pdf"
        self._build_numbered_fixture(other_pdf, len(pages))

        with self.assertRaisesRegex(ValueError, "requested PDF"):
            build_grayscale_samples(
                other_pdf,
                pages,
                self.root / "wrong-pdf-grayscale",
            )

    def test_poppler_failure_is_reported_explicitly(self) -> None:
        error = subprocess.CalledProcessError(
            2,
            ["pdftoppm"],
            stderr="synthetic poppler failure",
        )

        with patch(
            "interview_question_bank.visual_review.subprocess.run",
            side_effect=error,
        ):
            with self.assertRaisesRegex(RuntimeError, "Poppler.*synthetic"):
                render_pages_with_poppler(
                    self.pdf_path,
                    self.root / "failed-render",
                    dpi=72,
                )


if __name__ == "__main__":
    unittest.main()
