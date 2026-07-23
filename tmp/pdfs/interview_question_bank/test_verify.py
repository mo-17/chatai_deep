from __future__ import annotations

import json
import os
import shutil
from io import BytesIO
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import pdfplumber
from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen.canvas import Canvas

import interview_question_bank.build as build_module
from interview_question_bank.document import build_pdf
from interview_question_bank.parser import parse_question_bank
from interview_question_bank.styles import register_fonts
import interview_question_bank.verify as verify_module
from interview_question_bank.verify import (
    REQUIRED_QUESTION_LABELS,
    analyze_maintenance_rules,
    analyze_question_fields,
    analyze_table_contracts,
    find_forbidden_tokens,
    question_label_expectations,
    source_table_section_titles,
    verify_pdf,
)


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "project-interview-question-bank.md"
_FRESH_TEMPORARY: TemporaryDirectory[str] | None = None
FRESH_PDF: Path
FRESH_RECEIPT: Path


def setUpModule() -> None:
    global _FRESH_TEMPORARY, FRESH_PDF, FRESH_RECEIPT
    _FRESH_TEMPORARY = TemporaryDirectory()
    directory = Path(_FRESH_TEMPORARY.name)
    FRESH_PDF = directory / "fresh.pdf"
    FRESH_RECEIPT = directory / "receipt.json"
    build_module.write_build_receipt(
        build_pdf(SOURCE, FRESH_PDF),
        FRESH_RECEIPT,
    )


def tearDownModule() -> None:
    if _FRESH_TEMPORARY is not None:
        _FRESH_TEMPORARY.cleanup()


class VerificationContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = FRESH_PDF.parent
        cls.pdf = FRESH_PDF
        cls.receipt_path = FRESH_RECEIPT

    def _matching_receipt(self, pdf: Path, destination: Path) -> Path:
        receipt = json.loads(self.receipt_path.read_text(encoding="utf-8"))
        receipt["sha256"] = sha256(pdf.read_bytes()).hexdigest()
        destination.write_text(
            json.dumps(receipt, ensure_ascii=False),
            encoding="utf-8",
        )
        return destination

    def _verify_or_raise(
        self,
        *,
        source: Path = SOURCE,
        pdf: Path | None = None,
        receipt: Path | None = None,
    ):
        report = verify_pdf(
            source,
            pdf or self.pdf,
            receipt_path=receipt or self.receipt_path,
        )
        if report.passed:
            return report
        return report.require_passed()

    def test_freshly_built_pdf_and_matching_receipt_pass(self) -> None:
        report = verify_pdf(SOURCE, self.pdf, receipt_path=self.receipt_path)

        self.assertTrue(report.passed, report.to_dict())
        self.assertEqual(80, report.pdf_question_count)
        self.assertEqual(80, len(set(report.question_pages.values())))
        self.assertEqual(12, report.section_count)
        self.assertEqual("0644", report.file_mode)
        self.assertIsNone(report.longest_answer_tail_issue)

    def test_rejects_wrong_metadata(self) -> None:
        reader = PdfReader(self.pdf)
        writer = PdfWriter()
        writer.clone_document_from_reader(reader)
        metadata = {
            str(key): str(value)
            for key, value in (reader.metadata or {}).items()
            if value is not None
        }
        metadata["/Title"] = "Wrong title"
        writer.add_metadata(metadata)
        tampered = self.directory / "wrong-metadata.pdf"
        writer.write(tampered)
        os.chmod(tampered, 0o644)
        receipt = self._matching_receipt(
            tampered,
            self.directory / "wrong-metadata-receipt.json",
        )

        report = verify_pdf(SOURCE, tampered, receipt_path=receipt)

        self.assertFalse(report.passed)
        self.assertEqual(
            {
                "expected": verify_module.EXPECTED_METADATA["title"],
                "actual": "Wrong title",
            },
            report.metadata_mismatches["title"],
        )

    def test_rejects_missing_source_sha(self) -> None:
        receipt = json.loads(self.receipt_path.read_text(encoding="utf-8"))
        receipt.pop("source_sha256")
        missing_sha = self.directory / "missing-source-sha.json"
        missing_sha.write_text(json.dumps(receipt), encoding="utf-8")

        report = verify_pdf(SOURCE, self.pdf, receipt_path=missing_sha)

        self.assertFalse(report.passed)
        self.assertEqual(
            {"expected": report.source_sha256, "actual": None},
            report.receipt_mismatches["source_sha256"],
        )

    def test_rejects_path_middle_traversal_on_non_reference_page(self) -> None:
        packet = BytesIO()
        canvas = Canvas(packet, pagesize=A4)
        canvas.setFont(register_fonts().body, 10)
        canvas.drawString(72, 300, "foo/../bar")
        canvas.save()
        packet.seek(0)
        writer = PdfWriter(clone_from=self.pdf)
        writer.pages[0].merge_page(PdfReader(packet).pages[0])
        tampered = self.directory / "relative-reference.pdf"
        writer.write(tampered)
        os.chmod(tampered, 0o644)
        receipt = self._matching_receipt(
            tampered,
            self.directory / "relative-reference-receipt.json",
        )

        report = verify_pdf(SOURCE, tampered, receipt_path=receipt)

        self.assertFalse(report.passed)
        self.assertIn("../", report.forbidden_tokens)
        self.assertEqual(
            ("reference path leakage: ../",),
            report.reference_entry_issues["document"],
        )

    def test_rejects_missing_longest_answer_tail(self) -> None:
        source_text = SOURCE.read_text(encoding="utf-8")
        mutated_source = self.directory / "mutated-source.md"
        mutated_source.write_text(
            source_text.replace(
                "证明远端从未收到调用。",
                "证明远端从未收到调用，并保留唯一负向尾句。",
                1,
            ),
            encoding="utf-8",
        )
        receipt = json.loads(self.receipt_path.read_text(encoding="utf-8"))
        receipt["source_sha256"] = sha256(
            mutated_source.read_bytes()
        ).hexdigest()
        mutated_receipt = self.directory / "mutated-source-receipt.json"
        mutated_receipt.write_text(json.dumps(receipt), encoding="utf-8")

        report = verify_pdf(
            mutated_source,
            self.pdf,
            receipt_path=mutated_receipt,
        )

        self.assertFalse(report.passed)
        self.assertEqual(
            "longest answer tail missing from extracted PDF text",
            report.longest_answer_tail_issue,
        )

    def test_require_passed_raises_for_a_failed_report(self) -> None:
        report = verify_pdf(SOURCE, self.pdf, receipt_path=self.receipt_path)
        failed = replace(
            report,
            metadata_mismatches={
                "title": {"expected": "Expected", "actual": "Actual"}
            },
        )

        with self.assertRaises(verify_module.VerificationError):
            failed.require_passed()

    def test_rejects_non_0644_release_mode(self) -> None:
        wrong_mode = self.directory / "wrong-mode.pdf"
        shutil.copyfile(self.pdf, wrong_mode)
        os.chmod(wrong_mode, 0o600)
        receipt = self._matching_receipt(
            wrong_mode,
            self.directory / "wrong-mode-receipt.json",
        )

        with self.assertRaisesRegex(verify_module.VerificationError, "0644"):
            self._verify_or_raise(pdf=wrong_mode, receipt=receipt)

    def test_receipt_exposes_summary_counts(self) -> None:
        receipt = json.loads(self.receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(80, receipt["question_count"])
        self.assertEqual(12, receipt["section_count"])

    def test_normalization_is_nfkc_whitespace_insensitive_and_punctuation_safe(
        self,
    ) -> None:
        normalize = getattr(verify_module, "normalize_for_match", None)
        self.assertTrue(callable(normalize), "normalize_for_match must be public")
        self.assertEqual("A。!", normalize("Ａ \n。 !"))
        self.assertNotEqual(normalize("。"), normalize("."))

    def test_source_last_sentence_uses_the_longest_production_field(self) -> None:
        bank = parse_question_bank(SOURCE.read_text(encoding="utf-8"))

        self.assertEqual(
            (
                "负向e2e要直接构造未发现的mcp__server__rawName,"
                "证明远端从未收到调用。"
            ),
            verify_module.source_last_sentence(bank),
        )


class AtomicBuildReleaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.output_directory = self.root / "output"
        self.receipt_directory = self.root / "receipts"
        self.output_directory.mkdir()
        self.receipt_directory.mkdir()
        self.source = self.root / "source.md"
        self.output = self.output_directory / "formal.pdf"
        self.receipt = self.receipt_directory / "receipt.json"
        self.source.write_text("# source\n", encoding="utf-8")
        self.old_pdf = b"old-formal-pdf"
        self.old_receipt = b'{"release":"old"}\n'
        self.output.write_bytes(self.old_pdf)
        self.receipt.write_bytes(self.old_receipt)
        os.chmod(self.output, 0o644)
        os.chmod(self.receipt, 0o644)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _candidate_receipt() -> dict[str, object]:
        return {
            "source_sha256": "source-sha",
            "sha256": "candidate-sha",
            "page_count": 97,
            "question_ids": ["C1", "C2"],
            "bookmark_titles": ["1. 使用方式"],
            "font_names": ["body", "heading", "code"],
            "font_roles": {},
            "generated_at": "2026-07-23T00:00:00+00:00",
            "release": "candidate",
        }

    def _builder(self):
        builder = getattr(build_module, "build_and_publish", None)
        self.assertTrue(
            callable(builder),
            "build_and_publish must orchestrate verified atomic release",
        )
        return builder

    def _assert_only_formal_files_remain(self) -> None:
        self.assertEqual(
            [self.output.name],
            sorted(path.name for path in self.output_directory.iterdir()),
        )
        self.assertEqual(
            [self.receipt.name],
            sorted(path.name for path in self.receipt_directory.iterdir()),
        )

    def test_failed_candidate_verification_preserves_old_release_pair(
        self,
    ) -> None:
        builder = self._builder()
        old_pdf_sha = sha256(self.output.read_bytes()).hexdigest()
        old_receipt_sha = sha256(self.receipt.read_bytes()).hexdigest()
        candidates: dict[str, Path] = {}
        failed_report = Mock()
        failed_report.require_passed.side_effect = (
            verify_module.VerificationError("candidate verification failed")
        )

        def fake_build(source: Path, destination: Path):
            self.assertEqual(self.source, Path(source))
            candidates["pdf"] = Path(destination)
            candidates["pdf"].write_bytes(b"unverified-candidate-pdf")
            return self._candidate_receipt()

        def fake_verify(
            source: Path,
            pdf: Path,
            *,
            receipt_path: Path,
        ):
            self.assertEqual(self.source, Path(source))
            candidates["receipt"] = Path(receipt_path)
            self.assertEqual(self.output.parent, Path(pdf).parent)
            self.assertEqual(self.receipt.parent, Path(receipt_path).parent)
            self.assertNotEqual(self.output, Path(pdf))
            self.assertNotEqual(self.receipt, Path(receipt_path))
            self.assertTrue(Path(pdf).is_file())
            self.assertTrue(Path(receipt_path).is_file())
            return failed_report

        with (
            patch.object(build_module, "build_pdf", side_effect=fake_build),
            patch.object(
                build_module,
                "verify_pdf",
                side_effect=fake_verify,
                create=True,
            ),
        ):
            with self.assertRaisesRegex(
                verify_module.VerificationError,
                "candidate verification failed",
            ):
                builder(
                    self.source,
                    self.output,
                    receipt_path=self.receipt,
                )

        self.assertEqual(self.old_pdf, self.output.read_bytes())
        self.assertEqual(self.old_receipt, self.receipt.read_bytes())
        self.assertEqual(
            old_pdf_sha,
            sha256(self.output.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            old_receipt_sha,
            sha256(self.receipt.read_bytes()).hexdigest(),
        )
        self.assertFalse(candidates["pdf"].exists())
        self.assertFalse(candidates["receipt"].exists())
        self._assert_only_formal_files_remain()

    def test_passing_candidate_is_verified_then_publishes_both_files(
        self,
    ) -> None:
        builder = self._builder()
        candidates: dict[str, Path] = {}
        report = Mock()
        report.require_passed.return_value = report

        def fake_build(source: Path, destination: Path):
            self.assertEqual(self.source, Path(source))
            candidates["pdf"] = Path(destination)
            candidates["pdf"].write_bytes(b"verified-candidate-pdf")
            return self._candidate_receipt()

        def fake_verify(
            source: Path,
            pdf: Path,
            *,
            receipt_path: Path,
        ):
            candidates["receipt"] = Path(receipt_path)
            self.assertEqual(self.source, Path(source))
            self.assertEqual(candidates["pdf"], Path(pdf))
            self.assertEqual(self.output.parent, Path(pdf).parent)
            self.assertEqual(self.receipt.parent, Path(receipt_path).parent)
            self.assertNotEqual(self.output, Path(pdf))
            self.assertNotEqual(self.receipt, Path(receipt_path))
            self.assertEqual(0o644, Path(pdf).stat().st_mode & 0o777)
            self.assertEqual(
                0o644,
                Path(receipt_path).stat().st_mode & 0o777,
            )
            return report

        with (
            patch.object(build_module, "build_pdf", side_effect=fake_build),
            patch.object(
                build_module,
                "verify_pdf",
                side_effect=fake_verify,
                create=True,
            ),
        ):
            payload = builder(
                self.source,
                self.output,
                receipt_path=self.receipt,
            )

        self.assertEqual(b"verified-candidate-pdf", self.output.read_bytes())
        self.assertEqual("candidate", payload["release"])
        self.assertEqual(
            payload,
            json.loads(self.receipt.read_text(encoding="utf-8")),
        )
        self.assertEqual(0o644, self.output.stat().st_mode & 0o777)
        self.assertEqual(0o644, self.receipt.stat().st_mode & 0o777)
        report.require_passed.assert_called_once_with()
        self.assertFalse(candidates["pdf"].exists())
        self.assertFalse(candidates["receipt"].exists())
        self._assert_only_formal_files_remain()

    def test_pdf_replace_failure_rolls_back_already_published_receipt(
        self,
    ) -> None:
        builder = self._builder()
        candidates: dict[str, Path] = {}
        report = Mock()
        report.require_passed.return_value = report

        def fake_build(source: Path, destination: Path):
            candidates["pdf"] = Path(destination)
            candidates["pdf"].write_bytes(b"candidate-pdf")
            return self._candidate_receipt()

        def fake_verify(
            source: Path,
            pdf: Path,
            *,
            receipt_path: Path,
        ):
            candidates["receipt"] = Path(receipt_path)
            return report

        real_replace = os.replace
        did_fail = False

        def fail_pdf_publish_once(source: Path, destination: Path) -> None:
            nonlocal did_fail
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                not did_fail
                and source_path == candidates["pdf"]
                and destination_path == self.output
            ):
                did_fail = True
                raise OSError("simulated PDF publish failure")
            real_replace(source, destination)

        with (
            patch.object(build_module, "build_pdf", side_effect=fake_build),
            patch.object(
                build_module,
                "verify_pdf",
                side_effect=fake_verify,
                create=True,
            ),
            patch.object(
                build_module.os,
                "replace",
                side_effect=fail_pdf_publish_once,
            ),
        ):
            with self.assertRaisesRegex(
                OSError,
                "simulated PDF publish failure",
            ):
                builder(
                    self.source,
                    self.output,
                    receipt_path=self.receipt,
                )

        self.assertTrue(did_fail)
        self.assertEqual(self.old_pdf, self.output.read_bytes())
        self.assertEqual(self.old_receipt, self.receipt.read_bytes())
        self.assertFalse(candidates["pdf"].exists())
        self.assertFalse(candidates["receipt"].exists())
        self._assert_only_formal_files_remain()

    def test_candidate_receipt_allocation_failure_cleans_candidate_pdf(
        self,
    ) -> None:
        builder = self._builder()
        real_temporary_path = build_module._temporary_release_path
        allocated: list[Path] = []

        def fail_second_allocation(
            destination: Path,
            suffix: str,
        ) -> Path:
            if allocated:
                raise OSError("simulated receipt candidate allocation failure")
            candidate = real_temporary_path(destination, suffix)
            allocated.append(candidate)
            return candidate

        with patch.object(
            build_module,
            "_temporary_release_path",
            side_effect=fail_second_allocation,
        ):
            with self.assertRaisesRegex(
                OSError,
                "simulated receipt candidate allocation failure",
            ):
                builder(
                    self.source,
                    self.output,
                    receipt_path=self.receipt,
                )

        self.assertEqual(1, len(allocated))
        self.assertFalse(allocated[0].exists())
        self.assertEqual(self.old_pdf, self.output.read_bytes())
        self.assertEqual(self.old_receipt, self.receipt.read_bytes())
        self._assert_only_formal_files_remain()

    def test_failed_receipt_rollback_preserves_recovery_backup(
        self,
    ) -> None:
        builder = self._builder()
        candidates: dict[str, Path] = {}
        recovery: dict[str, Path] = {}
        report = Mock()
        report.require_passed.return_value = report

        def fake_build(source: Path, destination: Path):
            candidates["pdf"] = Path(destination)
            candidates["pdf"].write_bytes(b"candidate-pdf")
            return self._candidate_receipt()

        def fake_verify(
            source: Path,
            pdf: Path,
            *,
            receipt_path: Path,
        ):
            candidates["receipt"] = Path(receipt_path)
            return report

        real_replace = os.replace
        pdf_publish_failed = False

        def fail_publish_and_receipt_rollback(
            source: Path,
            destination: Path,
        ) -> None:
            nonlocal pdf_publish_failed
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                not pdf_publish_failed
                and source_path == candidates["pdf"]
                and destination_path == self.output
            ):
                pdf_publish_failed = True
                raise OSError("simulated PDF publish failure")
            if (
                pdf_publish_failed
                and destination_path == self.receipt
                and source_path.suffix == ".backup"
            ):
                recovery["receipt"] = source_path
                raise OSError("simulated receipt rollback failure")
            real_replace(source, destination)

        with (
            patch.object(build_module, "build_pdf", side_effect=fake_build),
            patch.object(
                build_module,
                "verify_pdf",
                side_effect=fake_verify,
            ),
            patch.object(
                build_module.os,
                "replace",
                side_effect=fail_publish_and_receipt_rollback,
            ),
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                "rollback was incomplete",
            ) as caught:
                builder(
                    self.source,
                    self.output,
                    receipt_path=self.receipt,
                )

        self.assertTrue(pdf_publish_failed)
        self.assertEqual(self.old_pdf, self.output.read_bytes())
        self.assertEqual(
            "candidate",
            json.loads(self.receipt.read_text(encoding="utf-8"))["release"],
        )
        self.assertIn("receipt", recovery)
        self.assertTrue(recovery["receipt"].is_file())
        self.assertEqual(self.old_receipt, recovery["receipt"].read_bytes())
        self.assertIn(str(recovery["receipt"]), str(caught.exception))
        self.assertFalse(candidates["pdf"].exists())
        self.assertFalse(candidates["receipt"].exists())
        self.assertEqual(
            [self.output.name],
            sorted(path.name for path in self.output_directory.iterdir()),
        )
        self.assertEqual(
            sorted([self.receipt.name, recovery["receipt"].name]),
            sorted(path.name for path in self.receipt_directory.iterdir()),
        )


class VerificationLogicTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_text = SOURCE.read_text(encoding="utf-8")
        cls.bank = parse_question_bank(cls.source_text)

    def test_question_field_analysis_reports_only_the_missing_label(self) -> None:
        complete = "\n".join(
            ["C1 · 示例题", "问题", *REQUIRED_QUESTION_LABELS]
        )
        incomplete = "\n".join(
            [
                "C2 · 另一题",
                "问题",
                *(
                    label
                    for label in REQUIRED_QUESTION_LABELS
                    if label != "风险信号"
                ),
            ]
        )

        issues = analyze_question_fields(
            complete + "\n" + incomplete,
            ("C1", "C2"),
        )

        self.assertEqual((), issues["C1"])
        self.assertEqual(("风险信号",), issues["C2"])

    def test_structured_pair_labels_are_counted_once_and_keep_source_order(
        self,
    ) -> None:
        question = self.bank.questions[0]
        text = "\n".join(
            [
                f"{question.question_id} · {question.title}",
                "问题",
                "考察点",
                "答案要点",
                "追问 风险信号",
                "评分锚点",
                "参考入口",
                "面试官记录",
            ]
        )

        self.assertEqual(
            (),
            analyze_question_fields(text, (question,))[question.question_id],
        )
        self.assertEqual(
            {},
            verify_module.analyze_question_order(text, (question,)),
        )

    def test_swapped_structured_pair_labels_are_rejected(self) -> None:
        question = self.bank.questions[0]
        text = "\n".join(
            [
                f"{question.question_id} · {question.title}",
                "问题",
                "考察点",
                "答案要点",
                "风险信号 追问",
                "评分锚点",
                "参考入口",
                "面试官记录",
            ]
        )

        field_issues = analyze_question_fields(text, (question,))
        order_issues = verify_module.analyze_question_order(text, (question,))

        self.assertIn("追问", field_issues[question.question_id])
        self.assertIn("风险信号", field_issues[question.question_id])
        self.assertIn(question.question_id, order_issues)

    def test_continued_header_is_not_counted_as_a_second_question_opening(
        self,
    ) -> None:
        text = "\n".join(
            [
                "C1 · First question",
                "C1 · CONTINUED",
                "C2 · Second question",
            ]
        )

        self.assertEqual(
            ("C1", "C2"),
            tuple(
                match.group(1)
                for match in verify_module.QUESTION_HEADING_RE.finditer(text)
            ),
        )

    def test_question_openings_reject_two_questions_on_one_physical_page(
        self,
    ) -> None:
        analyzer = getattr(verify_module, "analyze_question_openings", None)
        self.assertTrue(callable(analyzer))

        issues = analyzer(
            ("C1", "C2", "C3"),
            (("C1", 8), ("C2", 8), ("C3", 9)),
        )

        self.assertEqual(
            {"expected": 3, "actual": 2},
            issues["question_opening_unique_pages"],
        )
        self.assertEqual(
            {"expected": "strictly increasing", "actual": [8, 8, 9]},
            issues["question_opening_page_order"],
        )

    def test_question_openings_reject_swapped_source_order(self) -> None:
        analyzer = getattr(verify_module, "analyze_question_openings", None)
        self.assertTrue(callable(analyzer))

        issues = analyzer(
            ("C1", "C2", "C3"),
            (("C1", 8), ("C3", 9), ("C2", 10)),
        )

        self.assertEqual(
            {
                "expected": ["C1", "C2", "C3"],
                "actual": ["C1", "C3", "C2"],
            },
            issues["pdf_question_order"],
        )
        self.assertNotIn("question_opening_page_order", issues)

    def test_expected_furniture_distinguishes_opening_and_continued_headers(
        self,
    ) -> None:
        question = self.bank.questions[0]
        page_texts = (
            "cover",
            "CAPABILITY BLUEPRINT / SECTION 03\nUNIFIED SCORE · 0—4",
            f"{question.question_id} · {question.title}",
            "continued body",
        )

        expected = verify_module._expected_page_headers(
            page_texts,
            ("3. 共享核心题",),
            {"3. 共享核心题": 2},
            (question,),
            {question.question_id: 3},
        )

        self.assertIsNone(expected[0])
        self.assertIsNone(expected[1])
        self.assertEqual(("3. 共享核心题", "C1"), expected[2])
        self.assertEqual(("3. 共享核心题", "C1 · CONTINUED"), expected[3])

    def test_forbidden_token_scan_covers_markup_entities_and_placeholders(self) -> None:
        text = "<details><summary>答案</summary>TODO &#8226; {{placeholder}}"

        self.assertEqual(
            (
                "<details>",
                "<summary>",
                "</summary>",
                "TODO",
                "&#8226;",
                "{{placeholder}}",
            ),
            find_forbidden_tokens(text),
        )

    def test_forbidden_token_scan_is_case_insensitive_and_covers_all_entities(self) -> None:
        text = (
            '<DeTaIlS open><SUMMARY class="x">答案</sUmMaRy></DETAILS> '
            "todo tBd FiXmE xxx &copy; &#169; &#xA9; {{ unresolved_name }}"
        )

        self.assertEqual(
            (
                '<DeTaIlS open>',
                '<SUMMARY class="x">',
                "</sUmMaRy>",
                "</DETAILS>",
                "todo",
                "tBd",
                "FiXmE",
                "xxx",
                "&copy;",
                "&#169;",
                "&#xA9;",
                "{{ unresolved_name }}",
            ),
            find_forbidden_tokens(text),
        )

    def test_forbidden_token_scan_rejects_path_middle_traversal_globally(self) -> None:
        self.assertEqual(("../",), find_forbidden_tokens("prefix foo/../bar suffix"))

    def test_forbidden_token_scan_does_not_flag_ordinary_ellipsis(self) -> None:
        self.assertEqual((), find_forbidden_tokens("等待... 然后继续。"))

    def test_optional_label_expectations_are_derived_from_source(self) -> None:
        expectations = question_label_expectations(self.bank.questions)

        self.assertEqual(
            21,
            sum("题前材料（盲面提供）" in labels for labels in expectations.values()),
        )
        self.assertEqual(
            33,
            sum("参考入口" in labels for labels in expectations.values()),
        )
        self.assertEqual(
            1,
            sum("项目情景" in labels for labels in expectations.values()),
        )

    def test_deleting_optional_labels_but_keeping_bodies_is_reported(self) -> None:
        expectations = question_label_expectations(self.bank.questions)
        cases = (
            ("AI2", "题前材料（盲面提供）"),
            ("C1", "参考入口"),
            ("C8", "项目情景"),
        )
        for question_id, deleted_label in cases:
            with self.subTest(question_id=question_id, label=deleted_label):
                question = next(q for q in self.bank.questions if q.question_id == question_id)
                block_lines = [f"{question_id} · {question.title}", question.prompt]
                for label in expectations[question_id]:
                    values = question.answer_fields.get(label, (f"{label} body",))
                    block_lines.append(f"{label}：{' '.join(values)}")
                complete_block = "\n".join(block_lines)
                mutated_block = complete_block.replace(f"{deleted_label}：", "", 1)

                issues = analyze_question_fields(mutated_block, (question,))

                self.assertIn(deleted_label, issues[question_id])
                for value in question.answer_fields[deleted_label]:
                    self.assertIn(value, mutated_block)

    def test_interviewer_record_analysis_rejects_an_incomplete_structured_panel(self) -> None:
        analyzer = getattr(verify_module, "analyze_interviewer_records", None)
        self.assertTrue(callable(analyzer))
        question = self.bank.questions[0]
        complete = "\n".join(
            [
                f"{question.question_id} · {question.title}",
                "问题",
                *REQUIRED_QUESTION_LABELS,
                "面试官记录",
                "证据",
                "风险",
                "评分 0 1 2 3 4",
            ]
        )
        mutated = complete.replace("评分 0 1 2 3 4", "评分 0 1 2 4")

        issues = analyzer(mutated, (question,))

        self.assertIn(question.question_id, issues)
        self.assertTrue(
            any("0 1 2 3 4" in issue for issue in issues[question.question_id])
        )

    def test_optional_field_order_analysis_rejects_c8_project_context_drift(self) -> None:
        analyzer = getattr(verify_module, "analyze_question_order", None)
        self.assertTrue(callable(analyzer))
        question = next(q for q in self.bank.questions if q.question_id == "C8")
        complete = "\n".join(
            [
                f"C8 · {question.title}",
                "问题",
                "项目情景",
                "考察点",
                "答案要点",
                "追问",
                "风险信号",
                "评分锚点",
                "面试官记录",
                "证据",
                "风险",
                "评分 0 1 2 3 4",
            ]
        )
        mutated = complete.replace(
            "项目情景\n考察点",
            "考察点\n项目情景",
        )

        issues = analyzer(mutated, (question,))

        self.assertIn("C8", issues)
        self.assertTrue(any("项目情景" in issue for issue in issues["C8"]))

    def test_reference_entry_analysis_rejects_markdown_and_relative_url_leakage(self) -> None:
        analyzer = getattr(verify_module, "analyze_reference_entries", None)
        self.assertTrue(callable(analyzer))
        question = self.bank.questions[0]
        complete = "\n".join(
            [
                f"C1 · {question.title}",
                "参考入口",
                (
                    "chatgpt_app_core/lib/app.dart · chatgpt_app_core/lib/app.dart、"
                    "pnpm-workspace.yaml · pnpm-workspace.yaml。"
                ),
                "面试官记录",
            ]
        )
        mutated = complete.replace(
            "chatgpt_app_core/lib/app.dart · chatgpt_app_core/lib/app.dart",
            "[chatgpt_app_core/lib/app.dart](../chatgpt_app_core/lib/app.dart)",
        )

        issues = analyzer(mutated, (question,))

        self.assertIn("C1", issues)
        self.assertTrue(
            any("Markdown" in issue or "relative" in issue for issue in issues["C1"])
        )

    def test_page_furniture_analysis_rejects_wrong_dynamic_header_and_footer(self) -> None:
        analyzer = getattr(verify_module, "analyze_page_furniture", None)
        self.assertTrue(callable(analyzer))
        expected_headers = (
            None,
            ("文档控制", "艾普项目面试题库"),
            ("3. 共享核心题", "C1"),
        )
        headers = (
            "",
            "文档控制 艾普项目面试题库",
            "3. 共享核心题 C2",
        )
        footers = (
            "",
            "面试官版 / 内部使用 2026-07-23 第 2 / 3 页",
            "面试官版 / 内部使用 2026-07-22 第 3 / 3 页",
        )

        issues = analyzer(headers, footers, expected_headers)

        self.assertIn(3, issues)
        self.assertTrue(any("header right" in issue for issue in issues[3]))
        self.assertTrue(any("footer exact" in issue for issue in issues[3]))

    def test_divider_analysis_rejects_missing_source_ability_keywords(self) -> None:
        analyzer = getattr(verify_module, "analyze_divider_contracts", None)
        self.assertTrue(callable(analyzer))
        capabilities = {
            row[0].replace(chr(96), ""): row[2]
            for row in self.bank.tables[0].rows[1:]
        }
        prefixes = ("C", "FE", "AI", "BE", "SEC", "PM", "QA", "OPS")
        page_texts = tuple(
            "\n".join(
                [
                    group.title.partition(".")[0].zfill(2),
                    group.title,
                    f"{prefix}1 - {prefix}10",
                    capabilities[prefix],
                ]
            )
            for group, prefix in zip(self.bank.question_groups, prefixes)
        )
        section_pages = {
            group.title: index
            for index, group in enumerate(self.bank.question_groups, start=1)
        }
        mutated = list(page_texts)
        mutated[4] = mutated[4].replace(capabilities["SEC"], "")

        issues = analyzer(tuple(mutated), self.bank, section_pages)

        self.assertIn(self.bank.question_groups[4].title, issues)
        self.assertTrue(
            any("keywords" in issue for issue in issues[self.bank.question_groups[4].title])
        )

    def test_font_role_analysis_rejects_missing_or_non_distinct_resources(self) -> None:
        analyzer = getattr(verify_module, "analyze_font_roles", None)
        self.assertTrue(callable(analyzer))
        reader = PdfReader(FRESH_PDF)
        fake_roles = SimpleNamespace(
            body_postscript_name="MissingBody",
            heading_postscript_name="MissingBody",
            code_postscript_name="MissingCodeMono",
            code_embedded=True,
        )

        issues = analyzer(reader, fake_roles, {"C1": 8})

        self.assertIn("distinct_roles", issues)
        self.assertIn("body", issues)
        self.assertIn("code", issues)

    def test_missing_maintenance_rule_on_maintenance_page_is_reported(self) -> None:
        rules = tuple(self.bank.maintenance_rules[0].blocks[0].items)
        page_texts = ("其他页面", "\n".join(rules))
        mutated = (page_texts[0], page_texts[1].replace(rules[2], "", 1))

        issues = analyze_maintenance_rules(mutated, rules, maintenance_page=2)

        self.assertEqual((rules[2],), issues)

    @staticmethod
    def _physical_table_fixture(bank) -> dict[int, list[list[list[str]]]]:
        logical = [[list(row) for row in table.rows] for table in bank.tables]
        role_weights = logical[3]
        split_left = [row[:5] for row in role_weights]
        split_right = [[row[0], *row[5:]] for row in role_weights]
        return {
            3: [logical[0], logical[1]],
            6: [logical[2]],
            95: [split_left, split_right],
        }

    def _table_issues(self, physical_tables):
        return analyze_table_contracts(
            self.bank.tables,
            source_table_section_titles(self.source_text),
            {
                "1. 使用方式": 3,
                "2. 七个岗位的抽题路线": 6,
                "11. 面试官综合评估表": 95,
            },
            physical_tables,
        )

    def test_missing_table_row_is_reported(self) -> None:
        physical = self._physical_table_fixture(self.bank)
        del physical[3][0][2]

        self.assertIn("table_1", self._table_issues(physical))

    def test_duplicated_table_row_is_reported(self) -> None:
        physical = self._physical_table_fixture(self.bank)
        physical[3][1].append(list(physical[3][1][1]))

        self.assertIn("table_2", self._table_issues(physical))

    def test_misplaced_table_is_reported(self) -> None:
        physical = self._physical_table_fixture(self.bank)
        physical[4] = [physical[6].pop()]

        self.assertIn("table_3", self._table_issues(physical))

    def test_extra_physical_table_on_a_table_section_page_is_reported(self) -> None:
        physical = self._physical_table_fixture(self.bank)
        physical[3].append(
            [
                ["unexpected", "table"],
                ["must", "fail"],
            ]
        )

        self.assertEqual(
            ("page 3 table 3",),
            self._table_issues(physical)["unexpected_physical_tables"],
        )

    def test_section_outline_rejects_an_extra_artifact_section(self) -> None:
        analyzer = getattr(verify_module, "analyze_section_outline_structure", None)
        self.assertTrue(callable(analyzer))
        expected = tuple(section.title for section in self.bank.level2_sections)
        entries = tuple(
            (1, SimpleNamespace(title=title))
            for title in (*expected, "13. 额外章节")
        )

        issues = analyzer(expected, entries)

        self.assertEqual(
            {
                "expected": list(expected),
                "actual": [*expected, "13. 额外章节"],
            },
            issues["section_outline_sequence"],
        )

    def test_section_outline_rejects_artifact_section_order_drift(self) -> None:
        analyzer = getattr(verify_module, "analyze_section_outline_structure", None)
        self.assertTrue(callable(analyzer))
        expected = tuple(section.title for section in self.bank.level2_sections)
        swapped = (expected[1], expected[0], *expected[2:])

        issues = analyzer(
            expected,
            tuple((1, SimpleNamespace(title=title)) for title in swapped),
        )

        self.assertEqual(list(swapped), issues["section_outline_sequence"]["actual"])

    def test_receipt_hash_mismatch_fails_verification(self) -> None:
        with TemporaryDirectory() as directory:
            receipt = json.loads(FRESH_RECEIPT.read_text(encoding="utf-8"))
            receipt["sha256"] = "0" * 64
            tampered_receipt = Path(directory) / "receipt.json"
            tampered_receipt.write_text(
                json.dumps(receipt, ensure_ascii=False),
                encoding="utf-8",
            )

            report = verify_pdf(SOURCE, FRESH_PDF, receipt_path=tampered_receipt)

        self.assertFalse(report.passed)
        self.assertIn("pdf_sha256", report.receipt_mismatches)


class FormalArtifactVerificationTest(unittest.TestCase):
    @staticmethod
    def _raw_outline_nodes(reader: PdfReader):
        def walk(reference):
            current = reference
            while current:
                node = current.get_object()
                yield node
                if node.get("/First"):
                    yield from walk(node["/First"])
                current = node.get("/Next")

        yield from walk(reader.trailer["/Root"]["/Outlines"]["/First"])

    @staticmethod
    def _write_matching_receipt(pdf: Path, destination: Path) -> Path:
        receipt = json.loads(FRESH_RECEIPT.read_text(encoding="utf-8"))
        receipt["sha256"] = sha256(pdf.read_bytes()).hexdigest()
        destination.write_text(json.dumps(receipt, ensure_ascii=False), encoding="utf-8")
        return destination

    def test_wrong_but_valid_outline_targets_fail_report(self) -> None:
        with TemporaryDirectory() as directory:
            reader = PdfReader(FRESH_PDF)
            nodes = list(self._raw_outline_nodes(reader))
            section = next(node for node in nodes if node.get("/Title") == "3. 共享核心题")
            question = next(node for node in nodes if str(node.get("/Title", "")).startswith("C1."))
            section[NameObject("/Dest")][0] = reader.pages[8].indirect_reference
            question[NameObject("/Dest")][0] = reader.pages[9].indirect_reference
            tampered_pdf = Path(directory) / "wrong-outline.pdf"
            writer = PdfWriter()
            writer.clone_document_from_reader(reader)
            writer.write(tampered_pdf)
            receipt = self._write_matching_receipt(
                tampered_pdf,
                Path(directory) / "receipt.json",
            )

            report = verify_pdf(SOURCE, tampered_pdf, receipt_path=receipt)

        self.assertFalse(report.passed)
        self.assertIn("3. 共享核心题", report.outline_destination_issues)
        self.assertIn("C1", report.outline_destination_issues)
        self.assertEqual({}, report.receipt_mismatches)

    def test_wrong_but_valid_toc_target_fails_report(self) -> None:
        with TemporaryDirectory() as directory:
            reader = PdfReader(FRESH_PDF)
            first_toc_link = reader.pages[4]["/Annots"][0].get_object()
            first_toc_link[NameObject("/Dest")][0] = reader.pages[3].indirect_reference
            tampered_pdf = Path(directory) / "wrong-toc-link.pdf"
            writer = PdfWriter()
            writer.clone_document_from_reader(reader)
            writer.write(tampered_pdf)
            receipt = self._write_matching_receipt(
                tampered_pdf,
                Path(directory) / "receipt.json",
            )

            report = verify_pdf(SOURCE, tampered_pdf, receipt_path=receipt)

        self.assertFalse(report.passed)
        self.assertIn("1. 使用方式", report.toc_link_issues)
        self.assertEqual({}, report.receipt_mismatches)

    def test_passed_property_includes_every_final_review_issue_collection(self) -> None:
        report = verify_pdf(SOURCE, FRESH_PDF, receipt_path=FRESH_RECEIPT)
        self.assertTrue(report.passed, report.to_dict())
        cases = {
            "question_record_issues": {"C1": ("missing 评分",)},
            "question_order_issues": {"C8": ("项目情景 order",)},
            "reference_entry_issues": {"C1": ("Markdown leakage",)},
            "page_furniture_issues": {2: ("footer mismatch",)},
            "divider_contract_issues": {"3. 共享核心题": ("keywords",)},
            "font_role_issues": {"body": ("missing",)},
        }
        self.assertTrue(
            all(hasattr(report, field_name) for field_name in cases),
            "VerificationReport must expose every final-review issue collection",
        )
        for field_name, value in cases.items():
            with self.subTest(field=field_name):
                mutated = replace(report, **{field_name: value})
                self.assertFalse(mutated.passed)

    def test_formal_pdf_passes_exhaustive_machine_contract(self) -> None:
        report = verify_pdf(SOURCE, FRESH_PDF, receipt_path=FRESH_RECEIPT)
        receipt = json.loads(FRESH_RECEIPT.read_text(encoding="utf-8"))

        self.assertTrue(report.passed, report.to_dict())
        self.assertEqual(receipt["page_count"], report.page_count)
        self.assertEqual(80, report.source_question_count)
        self.assertEqual(80, report.pdf_question_count)
        self.assertEqual(33, report.reference_entry_count)
        self.assertEqual(12, report.section_count)
        self.assertEqual(93, report.outline_count)
        self.assertEqual(80, report.question_outline_count)
        self.assertEqual(24, report.link_count)
        self.assertEqual(24, report.toc_link_count)
        self.assertEqual(0, len(report.page_size_issues))
        self.assertEqual(0, len(report.unexpected_near_blank_pages))
        self.assertEqual({}, report.metadata_mismatches)
        self.assertEqual({}, report.receipt_mismatches)
        self.assertEqual({}, report.question_label_issues)
        self.assertEqual({}, report.question_record_issues)
        self.assertEqual({}, report.question_order_issues)
        self.assertEqual({}, report.reference_entry_issues)
        self.assertEqual({}, report.page_furniture_issues)
        self.assertEqual({}, report.divider_contract_issues)
        self.assertEqual({}, report.font_role_issues)
        self.assertEqual({}, report.outline_destination_issues)
        self.assertEqual({}, report.toc_link_issues)
        self.assertEqual((), report.maintenance_rule_issues)
        self.assertEqual({}, report.table_contract_issues)
        self.assertEqual((), report.missing_record_fields)
        self.assertEqual((), report.forbidden_tokens)


if __name__ == "__main__":
    unittest.main()
