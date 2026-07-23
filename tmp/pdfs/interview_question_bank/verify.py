"""Exhaustive machine verification for the formal interview-handbook PDF."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
from hashlib import sha256
import json
from pathlib import Path
import re
from typing import Iterable, Mapping, Sequence
import unicodedata

import pdfplumber
from pypdf import PdfReader
from pypdf.generic import ContentStream
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm

from interview_question_bank.parser import ListBlock, Question, TableBlock, parse_question_bank
from interview_question_bank.styles import (
    FontSet,
    printable_inline_text,
    register_fonts,
)


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_RECEIPT_PATH = ROOT / "tmp" / "pdfs" / "build-receipt.json"
REPORT_PATH = ROOT / "tmp" / "pdfs" / "verification-report.json"

EXPECTED_METADATA = {
    "title": "艾普项目高级岗位面试题库",
    "author": "Aipu Project",
    "subject": "高级岗位内部面试与评分手册",
    "keywords": "interview, engineering, internal",
}
REQUIRED_QUESTION_LABELS = ("考察点", "答案要点", "追问", "风险信号", "评分锚点")
REQUIRED_RECORD_FIELDS = (
    "候选人：",
    "目标岗位：",
    "面试时长：",
    "抽取题号：",
    "最强证据：",
    "主要风险：",
    "安全专项：",
    "可靠性专项：",
    "沟通与权衡：",
    "题目平均分（0～4）",
    "换算分（平均分 × 25）：",
    "建议：",
    "建议下一轮重点：",
)
QUESTION_ID_PATTERN = r"(?:C|FE|AI|BE|SEC|PM|QA|OPS)\d+"
QUESTION_HEADING_RE = re.compile(
    rf"(?m)^({QUESTION_ID_PATTERN})\s*·\s+(?!CONTINUED(?:\s|$))"
)
QUESTION_OUTLINE_RE = re.compile(rf"^({QUESTION_ID_PATTERN})\.\s+")
MARKDOWN_QUESTION_RE = re.compile(rf"^###\s+({QUESTION_ID_PATTERN})\.\s+", re.MULTILINE)
PDF_SECTION_HEADING_RE = re.compile(r"(?m)^(?:[1-9]|1[0-2])\.\s+\S.*$")
ARTIFACT_SECTION_HEADING_RE = re.compile(r"^([1-9]\d*)\.\s+(\S.*)$")
BLUEPRINT_SECTION_MARKER_RE = re.compile(
    r"^CAPABILITY\s+BLUEPRINT\s*/\s*SECTION\s+(\d{2})$",
    re.IGNORECASE,
)
FORBIDDEN_LITERAL_TOKENS = (
    "<details>",
    "</details>",
    "<summary>",
    "</summary>",
    "TODO",
    "TBD",
    "FIXME",
    "XXX",
    "&#8226;",
)


class VerificationError(RuntimeError):
    """Raised by callers that require a passing release-verification report."""


@dataclass(frozen=True)
class VerificationReport:
    source_path: str
    pdf_path: str
    receipt_path: str
    source_sha256: str
    pdf_sha256: str
    file_size_bytes: int
    page_count: int
    source_question_count: int
    pdf_question_count: int
    reference_entry_count: int
    section_count: int
    outline_count: int
    question_outline_count: int
    link_count: int
    toc_link_count: int
    metadata: Mapping[str, str | None]
    metadata_mismatches: Mapping[str, Mapping[str, object]]
    structural_mismatches: Mapping[str, Mapping[str, object]]
    receipt_mismatches: Mapping[str, Mapping[str, object]]
    missing_question_ids: tuple[str, ...]
    unexpected_question_ids: tuple[str, ...]
    duplicate_question_ids: tuple[str, ...]
    missing_sections: tuple[str, ...]
    missing_non_question_headings: tuple[str, ...]
    missing_outline_sections: tuple[str, ...]
    missing_question_outline_ids: tuple[str, ...]
    duplicate_question_outline_ids: tuple[str, ...]
    invalid_outline_destinations: tuple[str, ...]
    outline_destination_issues: Mapping[str, Mapping[str, object]]
    toc_link_issues: Mapping[str, Mapping[str, object]]
    question_label_issues: Mapping[str, tuple[str, ...]]
    question_record_issues: Mapping[str, tuple[str, ...]]
    question_order_issues: Mapping[str, tuple[str, ...]]
    reference_entry_issues: Mapping[str, tuple[str, ...]]
    page_furniture_issues: Mapping[int, tuple[str, ...]]
    divider_contract_issues: Mapping[str, tuple[str, ...]]
    font_role_issues: Mapping[str, tuple[str, ...]]
    question_content_issues: Mapping[str, tuple[str, ...]]
    missing_table_cells: tuple[str, ...]
    table_contract_issues: Mapping[str, tuple[str, ...]]
    maintenance_rule_issues: tuple[str, ...]
    missing_record_fields: tuple[str, ...]
    forbidden_tokens: tuple[str, ...]
    page_size_issues: tuple[Mapping[str, object], ...]
    page_text_char_counts: tuple[int, ...]
    near_blank_pages: tuple[int, ...]
    unexpected_near_blank_pages: tuple[int, ...]
    question_pages: Mapping[str, int]
    file_mode: str
    file_mode_issue: str | None
    longest_answer_tail_issue: str | None

    @property
    def passed(self) -> bool:
        issue_collections = (
            self.metadata_mismatches,
            self.structural_mismatches,
            self.receipt_mismatches,
            self.missing_question_ids,
            self.unexpected_question_ids,
            self.duplicate_question_ids,
            self.missing_sections,
            self.missing_non_question_headings,
            self.missing_outline_sections,
            self.missing_question_outline_ids,
            self.duplicate_question_outline_ids,
            self.invalid_outline_destinations,
            self.outline_destination_issues,
            self.toc_link_issues,
            self.question_label_issues,
            self.question_record_issues,
            self.question_order_issues,
            self.reference_entry_issues,
            self.page_furniture_issues,
            self.divider_contract_issues,
            self.font_role_issues,
            self.question_content_issues,
            self.missing_table_cells,
            self.table_contract_issues,
            self.maintenance_rule_issues,
            self.missing_record_fields,
            self.forbidden_tokens,
            self.page_size_issues,
            self.unexpected_near_blank_pages,
            self.file_mode_issue,
            self.longest_answer_tail_issue,
        )
        return not any(issue_collections)

    def to_dict(self) -> dict[str, object]:
        payload = asdict(self)
        payload["passed"] = self.passed
        return payload

    def require_passed(self) -> "VerificationReport":
        if not self.passed:
            raise VerificationError(
                json.dumps(self.to_dict(), ensure_ascii=False, sort_keys=True)
            )
        return self


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_for_match(value: str) -> str:
    """Normalize compatibility forms and ignore only whitespace."""
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value))


def last_normalized_sentence(value: str) -> str:
    sentences = [
        part.strip()
        for part in re.split(r"(?<=[。！？.!?])", value)
        if part.strip()
    ]
    if not sentences:
        return normalize_for_match(value)
    return normalize_for_match(sentences[-1])


def _question_field_values(question: Question) -> Iterable[str]:
    yield question.title
    yield question.prompt
    yield from question.preface
    for values in question.answer_fields.values():
        yield from values


def source_last_sentence(question_bank) -> str:
    """Return the last sentence of the longest normalized production field."""
    values = (
        value
        for question in question_bank.questions
        for value in _question_field_values(question)
        if value.strip()
    )
    longest = max(values, key=lambda value: len(normalize_for_match(value)))
    return last_normalized_sentence(printable_inline_text(longest))


def _normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("`", "").replace("\x7f", "")
    text = re.sub(r"<br\s*/?>", "", text, flags=re.IGNORECASE)
    return re.sub(r"\s+", "", text)


def _normalized_form_text(text: str) -> str:
    """Ignore printable form rules that pdfplumber may interleave with labels."""
    return _normalized(text).replace("_", "")


def _ordered_unique(values: Iterable[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(values))


def find_forbidden_tokens(text: str) -> tuple[str, ...]:
    """Return leaked markup, entities and unfinished-work placeholders."""
    patterns = (
        re.compile(r"</?\s*(?:details|summary)\b[^>]*>", re.IGNORECASE),
        re.compile(r"file://", re.IGNORECASE),
        re.compile(r"\.\./"),
        re.compile(r"\b(?:TODO|TBD|FIXME|XXX)\b", re.IGNORECASE),
        re.compile(r"&(?:#[xX][0-9A-Fa-f]+|#\d+|[A-Za-z][A-Za-z0-9]+);"),
        re.compile(r"\{\{[^{}\n]+\}\}"),
    )
    positioned = sorted(
        (match.start(), match.group(0))
        for pattern in patterns
        for match in pattern.finditer(text)
    )
    return _ordered_unique(value for _, value in positioned)


def question_label_expectations(
    questions: Sequence[Question],
) -> dict[str, tuple[str, ...]]:
    """Return the labels expected in each question block."""
    return {
        question.question_id: (
            *REQUIRED_QUESTION_LABELS,
            *(
                label
                for label in question.answer_fields
                if label not in REQUIRED_QUESTION_LABELS
            ),
        )
        for question in questions
    }


def analyze_question_openings(
    expected_question_ids: Sequence[str],
    opening_records: Sequence[tuple[str, int]],
) -> dict[str, Mapping[str, object]]:
    """Require exact source order and one strictly ordered opening page per question."""
    expected_ids = tuple(expected_question_ids)
    actual_ids = tuple(question_id for question_id, _ in opening_records)
    opening_pages = tuple(page_number for _, page_number in opening_records)
    issues: dict[str, Mapping[str, object]] = {}
    if actual_ids != expected_ids:
        issues["pdf_question_order"] = _mismatch(
            list(expected_ids),
            list(actual_ids),
        )
    if len(set(opening_pages)) != len(expected_ids):
        issues["question_opening_unique_pages"] = _mismatch(
            len(expected_ids),
            len(set(opening_pages)),
        )
    if any(
        current_page >= next_page
        for current_page, next_page in zip(opening_pages, opening_pages[1:])
    ):
        issues["question_opening_page_order"] = _mismatch(
            "strictly increasing",
            list(opening_pages),
        )
    return issues


def _question_blocks(extracted_text: str) -> dict[str, str]:
    matches = list(QUESTION_HEADING_RE.finditer(extracted_text))
    blocks: dict[str, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(extracted_text)
        next_section = PDF_SECTION_HEADING_RE.search(extracted_text, match.end(), end)
        if next_section:
            end = next_section.start()
        blocks[match.group(1)] = extracted_text[match.start():end]
    return blocks


def analyze_question_fields(
    extracted_text: str,
    expected_questions: Sequence[str | Question],
) -> dict[str, tuple[str, ...]]:
    """Map every question id to the required labels missing from its own block."""
    blocks = _question_blocks(extracted_text)
    issues: dict[str, tuple[str, ...]] = {}
    expectations = question_label_expectations(
        tuple(item for item in expected_questions if isinstance(item, Question))
    )
    for expected in expected_questions:
        question_id = expected.question_id if isinstance(expected, Question) else expected
        block = blocks.get(question_id, "")
        expected_labels = expectations.get(question_id, REQUIRED_QUESTION_LABELS)
        invalid_counts = tuple(
            label
            for label in expected_labels
            if len(_exact_label_positions(block, label)) != 1
        )
        issues[question_id] = invalid_counts
    return issues


def _exact_label_positions(block: str, label: str) -> tuple[tuple[int, int], ...]:
    expected = _normalized(label)
    structured_pair = tuple(_normalized(item) for item in ("追问", "风险信号"))
    combined_pair = "".join(structured_pair)
    positions: list[tuple[int, int]] = []
    for index, line in enumerate(block.splitlines()):
        normalized_line = _normalized(line)
        if normalized_line == expected:
            positions.append((index, 0))
        elif label in ("追问", "风险信号") and normalized_line == combined_pair:
            positions.append(
                (
                    index,
                    0 if expected == structured_pair[0] else len(structured_pair[0]),
                )
            )
    return tuple(positions)


def _exact_label_indices(block: str, label: str) -> tuple[int, ...]:
    return tuple(index for index, _ in _exact_label_positions(block, label))


def _record_label_indices(block: str, label: str) -> tuple[int, ...]:
    expected = _normalized(label)
    return tuple(
        index
        for index, line in enumerate(block.splitlines())
        if _normalized(line) == expected
        or (
            label == "评分"
            and _normalized(line).startswith(expected)
            and not _normalized(line).startswith(_normalized("评分锚点"))
        )
    )


def analyze_interviewer_records(
    extracted_text: str,
    questions: Sequence[Question],
) -> dict[str, tuple[str, ...]]:
    """Require one structured evidence/risk/score panel per question."""
    blocks = _question_blocks(extracted_text)
    issues: dict[str, tuple[str, ...]] = {}
    for question in questions:
        block = blocks.get(question.question_id, "")
        lines = block.splitlines()
        panel_issues: list[str] = []
        for label in ("面试官记录", "证据", "风险", "评分"):
            count = len(_record_label_indices(block, label))
            if count != 1:
                panel_issues.append(f"{label} count expected 1 actual {count}")
        score_indices = _record_label_indices(block, "评分")
        if len(score_indices) == 1:
            score_index = score_indices[0]
            score_text = _normalized(
                "\n".join(lines[score_index : score_index + 3])
            )
            if not re.search(r"0.*1.*2.*3.*4", score_text):
                panel_issues.append("评分 choices expected 0 1 2 3 4")
        else:
            panel_issues.append("评分 choices expected 0 1 2 3 4")
        if panel_issues:
            issues[question.question_id] = tuple(panel_issues)
    return issues


def _desired_question_labels(question: Question) -> tuple[str, ...]:
    blind_labels = tuple(
        label
        for label in question.answer_fields
        if label.startswith("题前材料")
    )
    project = ("项目情景",) if "项目情景" in question.answer_fields else ()
    references = ("参考入口",) if "参考入口" in question.answer_fields else ()
    return (
        *blind_labels,
        "问题",
        *project,
        *REQUIRED_QUESTION_LABELS,
        *references,
        "面试官记录",
    )


def analyze_question_order(
    extracted_text: str,
    questions: Sequence[Question],
) -> dict[str, tuple[str, ...]]:
    """Validate blind material, C8 context, standard fields and record order."""
    blocks = _question_blocks(extracted_text)
    issues: dict[str, tuple[str, ...]] = {}
    for question in questions:
        block = blocks.get(question.question_id, "")
        labels = _desired_question_labels(question)
        positions: list[tuple[str, tuple[int, int]]] = []
        question_issues: list[str] = []
        for label in labels:
            label_positions = _exact_label_positions(block, label)
            if len(label_positions) != 1:
                question_issues.append(
                    f"{label} order unavailable: expected one label, found {len(label_positions)}"
                )
            else:
                positions.append((label, label_positions[0]))
        for (left_label, left), (right_label, right) in zip(
            positions,
            positions[1:],
        ):
            if left >= right:
                question_issues.append(
                    f"{left_label} must precede {right_label}"
                )
        if question_issues:
            issues[question.question_id] = tuple(question_issues)
    return issues


def analyze_reference_entries(
    extracted_text: str,
    questions: Sequence[Question],
) -> dict[str, tuple[str, ...]]:
    """Validate all source references as clean printable repository paths."""
    blocks = _question_blocks(extracted_text)
    issues: dict[str, tuple[str, ...]] = {}
    for question in questions:
        values = question.answer_fields.get("参考入口", ())
        if not values:
            continue
        block = blocks.get(question.question_id, "")
        reference_issues: list[str] = []
        if len(_exact_label_indices(block, "参考入口")) != 1:
            reference_issues.append("参考入口 label count mismatch")
        for index, value in enumerate(values):
            expected = printable_inline_text(value)
            if _normalized(expected) not in _normalized(block):
                reference_issues.append(f"reference body {index} mismatch")
        start_indices = _exact_label_indices(block, "参考入口")
        end_indices = _exact_label_indices(block, "面试官记录")
        if start_indices:
            start = start_indices[0]
            end = end_indices[0] if end_indices else len(block.splitlines())
            reference_text = "\n".join(block.splitlines()[start:end])
            if "](" in reference_text or "[" in reference_text:
                reference_issues.append("Markdown reference syntax leaked")
            if "../" in reference_text or "file://" in reference_text:
                reference_issues.append("relative or local reference URL leaked")
        if reference_issues:
            issues[question.question_id] = tuple(reference_issues)
    return issues


def analyze_page_furniture(
    header_texts: Sequence[str],
    footer_texts: Sequence[str],
    expected_headers: Sequence[tuple[str, str] | None],
) -> dict[int, tuple[str, ...]]:
    """Validate exact dynamic header and three-part footer contracts."""
    issues: dict[int, tuple[str, ...]] = {}
    total_pages = len(expected_headers)
    for page_number, expected in enumerate(expected_headers, start=1):
        header = header_texts[page_number - 1] if page_number <= len(header_texts) else ""
        footer = footer_texts[page_number - 1] if page_number <= len(footer_texts) else ""
        page_issues: list[str] = []
        if expected is None:
            if any(
                _normalized(token) in _normalized(header + "\n" + footer)
                for token in (
                    "面试官版 / 内部使用",
                    f"第 {page_number} / {total_pages} 页",
                )
            ):
                page_issues.append("full-page template contains Body furniture")
        else:
            expected_left, expected_right = expected
            expected_header = _normalized(expected_left + expected_right)
            if _normalized(header) != expected_header:
                page_issues.append(f"header left mismatch: {expected_left}")
                page_issues.append(f"header right mismatch: {expected_right}")
            footer_contract = (
                "面试官版 / 内部使用",
                "2026-07-23",
                f"第 {page_number} / {total_pages} 页",
            )
            expected_footer = _normalized("".join(footer_contract))
            if _normalized(footer) != expected_footer:
                page_issues.append(
                    "footer exact mismatch: "
                    + " | ".join(footer_contract)
                )
        if page_issues:
            issues[page_number] = tuple(page_issues)
    return issues


def _expected_page_headers(
    page_texts: Sequence[str],
    section_titles: Sequence[str],
    section_pages: Mapping[str, int],
    questions: Sequence[Question],
    question_pages: Mapping[str, int],
) -> tuple[tuple[str, str] | None, ...]:
    expected: list[tuple[str, str] | None] = [None]
    section_starts = sorted(
        (page, title)
        for title, page in section_pages.items()
        if page > 0
    )
    question_starts = sorted(
        (question_pages[question.question_id], question.question_id)
        for question in questions
        if question.question_id in question_pages
    )
    question_context: dict[int, str] = {}
    all_section_pages = sorted(page for page, _ in section_starts)
    for index, (start, question_id) in enumerate(question_starts):
        next_question = (
            question_starts[index + 1][0]
            if index + 1 < len(question_starts)
            else len(page_texts) + 1
        )
        next_section = min(
            (page for page in all_section_pages if page > start),
            default=len(page_texts) + 1,
        )
        for page_number in range(start, min(next_question, next_section)):
            question_context[page_number] = (
                question_id
                if page_number == start
                else f"{question_id} · CONTINUED"
            )

    for page_number in range(2, len(page_texts) + 1):
        page_text = page_texts[page_number - 1]
        if (
            _normalized("CAPABILITY BLUEPRINT / SECTION") in _normalized(page_text)
            and _normalized("UNIFIED SCORE · 0—4") in _normalized(page_text)
        ):
            expected.append(None)
            continue
        if page_number == 2:
            section = "文档控制"
        elif any(
            _normalized(line) == _normalized("目录")
            for line in page_texts[page_number - 1].splitlines()
        ):
            section = "目录"
        else:
            section = next(
                (
                    title
                    for page, title in reversed(section_starts)
                    if page <= page_number
                ),
                section_titles[0] if section_titles else "文档控制",
            )
        expected.append(
            (
                section,
                question_context.get(page_number, "艾普项目面试题库"),
            )
        )
    return tuple(expected)


def analyze_divider_contracts(
    page_texts: Sequence[str],
    bank,
    section_pages: Mapping[str, int],
    page_rects: Mapping[int, Sequence[Mapping[str, object]]] | None = None,
) -> dict[str, tuple[str, ...]]:
    """Validate eight source-derived divider content and color-block contracts."""
    capabilities = {
        row[0].replace(chr(96), "").strip(): row[2].strip()
        for row in bank.tables[0].rows[1:]
        if len(row) >= 3
    }
    prefixes = ("C", "FE", "AI", "BE", "SEC", "PM", "QA", "OPS")
    issues: dict[str, tuple[str, ...]] = {}
    for group, prefix in zip(bank.question_groups, prefixes):
        page_number = section_pages.get(group.title, 0)
        text = (
            page_texts[page_number - 1]
            if 1 <= page_number <= len(page_texts)
            else ""
        )
        divider_issues: list[str] = []
        expectations = {
            "section number": group.title.partition(".")[0].zfill(2),
            "group name": group.title.partition(".")[2].strip(),
            "question range": f"{prefix}1 - {prefix}10",
            "keywords": capabilities.get(prefix, ""),
        }
        for name, expected in expectations.items():
            if not expected or _normalized(expected) not in _normalized(text):
                divider_issues.append(f"{name} mismatch: {expected}")
        if page_rects is not None:
            rects = page_rects.get(page_number, ())
            full_page_navy = any(
                float(rect.get("width", 0)) >= A4[0] - 0.5
                and float(rect.get("height", 0)) >= A4[1] - 0.5
                and isinstance(rect.get("non_stroking_color"), (list, tuple))
                and len(rect.get("non_stroking_color") or ()) == 3
                and all(
                    abs(float(actual) - expected) <= 0.002
                    for actual, expected in zip(
                        rect.get("non_stroking_color") or (),
                        (0.05098, 0.14902, 0.243137),
                    )
                )
                for rect in rects
            )
            full_height_accent = any(
                10 * mm <= float(rect.get("width", 0)) <= 12 * mm
                and float(rect.get("height", 0)) >= A4[1] - 0.5
                and isinstance(rect.get("non_stroking_color"), (list, tuple))
                and len(rect.get("non_stroking_color") or ()) == 3
                and all(
                    abs(float(actual) - expected) <= 0.002
                    for actual, expected in zip(
                        rect.get("non_stroking_color") or (),
                        (0.184314, 0.435294, 0.929412),
                    )
                )
                for rect in rects
            )
            if not (full_page_navy and full_height_accent):
                divider_issues.append("Blueprint full-page evidence missing")
        if divider_issues:
            issues[group.title] = tuple(divider_issues)
    return issues


def analyze_font_roles(
    reader: PdfReader,
    fonts: FontSet,
    question_pages: Mapping[str, int],
) -> dict[str, tuple[str, ...]]:
    """Inspect fonts that actually draw text in PDF content streams."""
    by_page: dict[int, tuple[tuple[str, bool], ...]] = {}
    content_stream_issues: list[str] = []
    unresolved_font_issues: set[str] = set()
    for page_number, page in enumerate(reader.pages, start=1):
        records: set[tuple[str, bool]] = set()
        visited_forms: set[
            tuple[
                tuple[int, int] | int,
                tuple[str, bool] | None,
                tuple[int, int] | int,
            ]
        ] = set()

        def resolve(value):
            return value.get_object() if hasattr(value, "get_object") else value

        def object_identity(value) -> tuple[int, int] | int:
            if hasattr(value, "idnum"):
                return value.idnum, value.generation
            resolved = resolve(value)
            reference = getattr(resolved, "indirect_reference", None)
            if reference is not None and hasattr(reference, "idnum"):
                return reference.idnum, reference.generation
            return id(resolved)

        def font_record(reference) -> tuple[str, bool]:
            font = resolve(reference)
            base = str(font.get("/BaseFont", ""))
            subtype = str(font.get("/Subtype", ""))

            def descriptor_has_font_stream(descriptor) -> bool:
                descriptor = resolve(descriptor)
                if not hasattr(descriptor, "get"):
                    return False
                return any(
                    hasattr(resolve(descriptor.get(key)), "get_data")
                    for key in ("/FontFile", "/FontFile2", "/FontFile3")
                    if descriptor.get(key) is not None
                )

            if subtype == "/Type0":
                descendants = tuple(
                    resolve(descendant)
                    for descendant in resolve(font.get("/DescendantFonts") or ())
                )
                embedded = bool(descendants) and all(
                    descriptor_has_font_stream(
                        descendant.get("/FontDescriptor")
                    )
                    for descendant in descendants
                )
            elif subtype == "/Type3":
                char_procs = resolve(font.get("/CharProcs") or {})
                embedded = bool(char_procs) and all(
                    hasattr(resolve(char_proc), "get_data")
                    for char_proc in char_procs.values()
                )
            else:
                embedded = descriptor_has_font_stream(
                    font.get("/FontDescriptor")
                )
            return base, embedded

        def has_text_operand(operands) -> bool:
            for operand in operands:
                if isinstance(operand, (str, bytes, bytearray)) and operand:
                    return True
                if isinstance(operand, (list, tuple)) and has_text_operand(operand):
                    return True
            return False

        def collect_used_fonts(content, resources, inherited_font=None) -> None:
            if content is None:
                return
            resources = resolve(resources or {})
            try:
                operations = ContentStream(resolve(content), reader).operations
            except Exception as error:
                content_stream_issues.append(
                    f"page {page_number}: {type(error).__name__}: {error}"
                )
                return
            current_font = inherited_font
            font_stack = []
            for operands, operator in operations:
                if operator == b"Tf" and operands:
                    font_resources = resolve(resources.get("/Font") or {})
                    reference = font_resources.get(operands[0])
                    current_font = (
                        font_record(reference)
                        if reference is not None
                        else (f"<unresolved font resource {operands[0]}>", False)
                    )
                    continue
                if operator == b"q":
                    font_stack.append(current_font)
                    continue
                if operator == b"Q":
                    current_font = font_stack.pop() if font_stack else inherited_font
                    continue
                if operator == b"gs" and operands:
                    ext_gstates = resolve(resources.get("/ExtGState") or {})
                    reference = ext_gstates.get(operands[0])
                    ext_gstate = resolve(reference) if reference is not None else {}
                    font_entry = resolve(ext_gstate.get("/Font")) if ext_gstate else None
                    if font_entry:
                        current_font = font_record(font_entry[0])
                    continue
                if operator in {b"Tj", b"TJ", b"'", b'"'} and has_text_operand(operands):
                    visible_font = current_font or (
                        "<unresolved: no active font>",
                        False,
                    )
                    records.add(visible_font)
                    if visible_font[0].startswith("<unresolved"):
                        unresolved_font_issues.add(
                            f"{visible_font[0]} on page {page_number}"
                        )
                    continue
                if operator != b"Do" or not operands:
                    continue
                xobjects = resolve(resources.get("/XObject") or {})
                reference = xobjects.get(operands[0])
                if reference is None:
                    continue
                form = resolve(reference)
                if str(form.get("/Subtype", "")) != "/Form":
                    continue
                identity = object_identity(reference)
                form_resources = form.get("/Resources")
                if form_resources is None:
                    form_resources = resources
                visit_key = (
                    identity,
                    current_font,
                    object_identity(form_resources),
                )
                if visit_key in visited_forms:
                    continue
                visited_forms.add(visit_key)
                collect_used_fonts(
                    form,
                    form_resources,
                    current_font,
                )

        collect_used_fonts(page.get_contents(), page.get("/Resources"))
        by_page[page_number] = tuple(sorted(records))

    role_names = {
        "body": fonts.body_postscript_name,
        "heading": fonts.heading_postscript_name,
        "code": fonts.code_postscript_name,
    }
    issues: dict[str, tuple[str, ...]] = {}
    if content_stream_issues:
        issues["content_streams"] = tuple(content_stream_issues)
    if unresolved_font_issues:
        issues["unresolved_fonts"] = tuple(sorted(unresolved_font_issues))
    if len(set(role_names.values())) != 3:
        issues["distinct_roles"] = ("body, heading and code faces must differ",)
    all_records = tuple(record for records in by_page.values() for record in records)
    unembedded_pages: dict[str, set[int]] = {}
    for page_number, records in by_page.items():
        for base, embedded in records:
            if not embedded:
                unembedded_pages.setdefault(base, set()).add(page_number)
    if unembedded_pages:
        issues["unembedded_resources"] = tuple(
            f"{base} on pages {', '.join(str(page) for page in sorted(pages))}"
            for base, pages in sorted(unembedded_pages.items())
        )
    for role, postscript_name in role_names.items():
        matches = tuple(
            embedded
            for base, embedded in all_records
            if postscript_name and postscript_name in base
        )
        role_issues: list[str] = []
        if not matches:
            role_issues.append(f"missing PDF font resource: {postscript_name}")
        expected_embedded = role != "code" or fonts.code_embedded
        if expected_embedded and matches and not all(matches):
            role_issues.append(f"unembedded PDF font resource: {postscript_name}")
        if role == "body" and "Black" in postscript_name:
            role_issues.append("body face must not be Songti Black")
        if role_issues:
            issues[role] = tuple(role_issues)
    c1_page = question_pages.get("C1")
    if c1_page:
        code_present = any(
            fonts.code_postscript_name in base
            for base, _ in by_page.get(c1_page, ())
        )
        if not code_present:
            issues["code_question_page"] = (
                f"code role missing on representative question page {c1_page}",
            )
    return issues


def analyze_maintenance_rules(
    page_texts: Sequence[str],
    rules: Sequence[str],
    *,
    maintenance_page: int,
) -> tuple[str, ...]:
    """Return maintenance rules missing from the maintenance page."""
    if not 1 <= maintenance_page <= len(page_texts):
        return tuple(rules)
    normalized_page = _normalized(page_texts[maintenance_page - 1])
    return tuple(rule for rule in rules if _normalized(rule) not in normalized_page)


def source_table_section_titles(source_text: str) -> tuple[str, ...]:
    """Return the nearest level-two section title for each source table."""
    lines = source_text.splitlines()
    current_section = ""
    sections: list[str] = []
    index = 0
    while index < len(lines):
        section_match = re.match(r"^##\s+(.+?)\s*$", lines[index])
        if section_match:
            current_section = section_match.group(1)
        if (
            lines[index].lstrip().startswith("|")
            and index + 1 < len(lines)
            and all(
                re.fullmatch(r":?-{3,}:?", cell.strip())
                for cell in lines[index + 1].strip().strip("|").split("|")
            )
        ):
            sections.append(current_section)
            index += 2
            while index < len(lines) and lines[index].lstrip().startswith("|"):
                index += 1
            continue
        index += 1
    return tuple(sections)


def _normalized_table(
    rows: Sequence[Sequence[str | None]],
) -> tuple[tuple[str, ...], ...]:
    return tuple(tuple(_normalized(cell or "") for cell in row) for row in rows)


def _expected_physical_tables(
    table: TableBlock,
) -> tuple[tuple[tuple[str, ...], ...], ...]:
    rows = tuple(tuple(cell for cell in row) for row in table.rows)
    if rows and len(rows[0]) == 8:
        return (
            _normalized_table(tuple(row[:5] for row in rows)),
            _normalized_table(tuple((row[0], *row[5:]) for row in rows)),
        )
    return (_normalized_table(rows),)


def _expected_question_layout_tables(
    questions: Sequence[Question],
    question_pages: Mapping[str, int],
) -> Counter[tuple[int, tuple[tuple[str, ...], ...]]]:
    expected: Counter[
        tuple[int, tuple[tuple[str, ...], ...]]
    ] = Counter()
    for question in questions:
        expected_page = question_pages.get(question.question_id)
        if expected_page is None:
            continue
        fields = dict(question.answer_fields)
        preface = [
            item
            for item in question.preface
            if item != "参考答案、追问与评分"
        ]
        for label in tuple(fields):
            if label.startswith("题前材料"):
                preface.extend(fields.pop(label))
        panels: list[tuple[str, Sequence[str]]] = []
        if preface:
            panels.append(("题前材料（盲面提供）", tuple(preface)))
        panels.append(("问题", (question.prompt,)))
        panels.extend(fields.items())
        for label, values in panels:
            body = "".join(
                printable_inline_text(
                    value.replace("<br/>", "\n").replace("<br>", "\n")
                )
                for value in values
            )
            expected[
                (
                    expected_page,
                    _normalized_table(
                        (
                            (label,),
                            (body or "—",),
                        )
                    ),
                )
            ] += 1
    return expected


def _generated_layout_table_counts(
    questions: Sequence[Question],
    question_pages: Mapping[str, int],
    printable_form_page: int | None,
) -> Counter[tuple[int, tuple[tuple[str, ...], ...]]]:
    interviewer_record = _normalized_table(
        (
            ("面试官记录", ""),
            ("证据", ""),
            ("风险", ""),
            ("评分", "□ 0　□ 1　□ 2　□ 3　□ 4"),
        )
    )
    printable_form = _normalized_table(
        (
            ("候选人：", "____________________________________________"),
            ("目标岗位：", "____________________________________________"),
            ("面试时长：", "____________________________________________"),
            ("抽取题号：", "____________________________________________"),
            ("", ""),
            ("最强证据：", "____________________________________________"),
            ("", "____________________________________________"),
            ("", ""),
            ("主要风险：", "____________________________________________"),
            ("", "____________________________________________"),
            ("", ""),
            ("安全专项：", "□ 通过　□ 需复核　□ 不通过"),
            ("可靠性专项：", "□ 通过　□ 需复核　□ 不通过"),
            ("沟通与权衡：", "□ 通过　□ 需复核　□ 不通过"),
            ("", ""),
            ("题目平均分（0～4）：", "____________________________________________"),
            ("换算分（平均分 × 25）：", "____________________________________________"),
            ("建议：", "□ 推进　□ 补充面试　□ 暂缓"),
            ("建议下一轮重点：", "____________________________________________"),
        )
    )
    expected: Counter[
        tuple[int, tuple[tuple[str, ...], ...]]
    ] = Counter()
    for question in questions:
        expected_page = question_pages.get(question.question_id)
        if expected_page is not None:
            expected[(expected_page, interviewer_record)] += 1
    if printable_form_page is not None:
        expected[(printable_form_page, printable_form)] += 1
    return expected


def _decorative_layout_kind(
    rows: tuple[tuple[str, ...], ...],
) -> str | None:
    row_count = len(rows)
    column_count = max((len(row) for row in rows), default=0)
    flattened = _normalized(
        "".join(cell for row in rows for cell in row)
    )
    if (
        row_count == 25
        and column_count == 18
        and _normalized("ENGINEERING INTERVIEW HANDBOOK") in flattened
    ):
        return "cover"
    if not (
        row_count == 27
        and column_count == 19
        and _normalized("CAPABILITY BLUEPRINT / SECTION") in flattened
        and _normalized("UNIFIED SCORE · 0—4") in flattened
    ):
        return None
    marker = re.search(
        rf"{re.escape(_normalized('CAPABILITY BLUEPRINT / SECTION'))}(\d{{2}})",
        flattened,
    )
    return f"blueprint:{marker.group(1)}" if marker else None


def _expected_decorative_layout_tables(
    section_pages: Mapping[str, int],
) -> Counter[tuple[int, str]]:
    expected: Counter[tuple[int, str]] = Counter({(1, "cover"): 1})
    for title, page_number in section_pages.items():
        match = ARTIFACT_SECTION_HEADING_RE.fullmatch(title)
        if match and 3 <= int(match.group(1)) <= 10:
            expected[(page_number, f"blueprint:{int(match.group(1)):02d}")] += 1
    return expected


def _layout_table_label(rows: tuple[tuple[str, ...], ...]) -> str:
    return next(
        (
            cell
            for row in rows
            for cell in row
            if cell
        ),
        "layout table",
    )


def analyze_table_contracts(
    source_tables: Sequence[TableBlock],
    table_section_titles: Sequence[str],
    section_pages: Mapping[str, int],
    physical_tables_by_page: Mapping[int, Sequence[Sequence[Sequence[str | None]]]],
    *,
    questions: Sequence[Question] = (),
    question_pages: Mapping[str, int] | None = None,
    printable_form_page: int | None = None,
    require_complete_layout: bool = False,
) -> dict[str, tuple[str, ...]]:
    """Validate logical table structure, multiplicity and placement."""
    actual_tables = tuple(
        (page_number, table_index, _normalized_table(rows))
        for page_number, tables in physical_tables_by_page.items()
        for table_index, rows in enumerate(tables)
        if rows
    )
    issues: dict[str, tuple[str, ...]] = {}
    consumed_tables: set[tuple[int, int]] = set()
    matched_logical_tables = 0
    for logical_index, table in enumerate(source_tables, start=1):
        key = f"table_{logical_index}"
        table_issues: list[str] = []
        section_title = (
            table_section_titles[logical_index - 1]
            if logical_index <= len(table_section_titles)
            else ""
        )
        expected_page = section_pages.get(section_title)
        if expected_page is None:
            table_issues.append(f"missing expected section page: {section_title}")
        for part_index, expected_rows in enumerate(
            _expected_physical_tables(table),
            start=1,
        ):
            expected_header = expected_rows[0] if expected_rows else ()
            exact = tuple(
                (page, index)
                for page, index, actual_rows in actual_tables
                if actual_rows == expected_rows
            )
            same_header = tuple(
                (page, index)
                for page, index, actual_rows in actual_tables
                if actual_rows and actual_rows[0] == expected_header
            )
            part = f"part {part_index}"
            if len(same_header) != 1:
                table_issues.append(
                    f"{part} multiplicity expected 1 actual {len(same_header)}"
                )
            if not exact:
                table_issues.append(f"{part} rows/header mismatch")
            elif len(exact) > 1:
                table_issues.append(f"{part} exact duplicates: {list(exact)}")
            if expected_page is not None and exact:
                actual_pages = tuple(page for page, _ in exact)
                if actual_pages != (expected_page,):
                    table_issues.append(
                        f"{part} placement expected page {expected_page} actual {list(actual_pages)}"
                    )
                elif len(exact) == 1:
                    consumed_tables.add(exact[0])
        if table_issues:
            issues[key] = tuple(table_issues)
        else:
            matched_logical_tables += 1
    if matched_logical_tables != len(source_tables):
        issues["matched_logical_tables"] = (
            f"expected {len(source_tables)} actual {matched_logical_tables}",
        )
    expected_question_pages = question_pages or {}
    allowed_layout_tables = _expected_question_layout_tables(
        questions,
        expected_question_pages,
    )
    allowed_layout_tables.update(
        _generated_layout_table_counts(
            questions,
            expected_question_pages,
            printable_form_page,
        )
    )
    allowed_decorative_tables = _expected_decorative_layout_tables(
        section_pages
    )
    unexpected_tables: list[str] = []
    for page_number, table_index, rows in actual_tables:
        if (page_number, table_index) in consumed_tables:
            continue
        decorative_kind = _decorative_layout_kind(rows)
        if decorative_kind is not None:
            decorative_key = (page_number, decorative_kind)
            if allowed_decorative_tables[decorative_key] > 0:
                allowed_decorative_tables[decorative_key] -= 1
                continue
        layout_key = (page_number, rows)
        if allowed_layout_tables[layout_key] > 0:
            allowed_layout_tables[layout_key] -= 1
            continue
        unexpected_tables.append(
            f"page {page_number} table {table_index + 1}"
        )
    unexpected = tuple(unexpected_tables)
    if unexpected:
        issues["unexpected_physical_tables"] = unexpected
    if require_complete_layout:
        missing_layout_tables = [
            f"page {page_number} {_layout_table_label(rows)} x{count}"
            for (page_number, rows), count in allowed_layout_tables.items()
            if count > 0
        ]
        missing_layout_tables.extend(
            f"page {page_number} {kind} x{count}"
            for (page_number, kind), count in allowed_decorative_tables.items()
            if count > 0
        )
        if missing_layout_tables:
            issues["missing_layout_tables"] = tuple(missing_layout_tables)
    return issues


def _heading_pages(
    page_texts: Sequence[str],
    headings: Sequence[str],
) -> dict[str, int]:
    pages: dict[str, int] = {}
    for heading in headings:
        normalized_heading = _normalized(heading)
        matches = tuple(
            page_number
            for page_number, text in enumerate(page_texts, start=1)
            if any(
                _normalized(line) == normalized_heading
                for line in text.splitlines()
            )
        )
        if matches:
            pages[heading] = matches[0]
    return pages


def _section_pages(
    page_texts: Sequence[str],
    bank,
) -> dict[str, int]:
    """Resolve Body headings and strict Blueprint chapter markers."""
    titles = tuple(section.title for section in bank.level2_sections)
    pages = _heading_pages(page_texts, titles)
    for group in bank.question_groups:
        section_number, _, group_name = group.title.partition(".")
        marker = f"CAPABILITY BLUEPRINT / SECTION {section_number.zfill(2)}"
        matches = tuple(
            page_number
            for page_number, text in enumerate(page_texts, start=1)
            if _normalized(marker) in _normalized(text)
            and _normalized(group_name.strip()) in _normalized(text)
            and _normalized("UNIFIED SCORE · 0—4") in _normalized(text)
        )
        if len(matches) == 1:
            pages[group.title] = matches[0]
    return pages


def _destination_page(reader: PdfReader, destination: object) -> int | None:
    try:
        return reader.get_destination_page_number(destination) + 1
    except Exception:
        return None


def _link_destination_page(reader: PdfReader, annotation: object) -> int | None:
    destination = annotation.get("/Dest")
    if destination is None and annotation.get("/A"):
        destination = annotation["/A"].get("/D")
    if destination is None:
        return None
    if isinstance(destination, str):
        named = reader.named_destinations.get(destination)
        return _destination_page(reader, named) if named else None
    try:
        page_reference = destination[0]
        page_object = page_reference.get_object()
        return reader.get_page_number(page_object) + 1
    except Exception:
        return None


def _question_content_issues(
    extracted_text: str,
    questions: Sequence[Question],
    *,
    question_pages: Mapping[str, int] | None = None,
    page_text_variants: Mapping[int, Sequence[str]] | None = None,
) -> dict[str, tuple[str, ...]]:
    blocks = _question_blocks(extracted_text)
    issues: dict[str, tuple[str, ...]] = {}
    ordered_starts = sorted(
        (
            question_pages[question.question_id],
            question.question_id,
        )
        for question in questions
        if question_pages and question.question_id in question_pages
    )
    page_ranges = {
        question_id: (
            start,
            (
                ordered_starts[index + 1][0] - 1
                if index + 1 < len(ordered_starts)
                else max(page_text_variants or {start: ()})
            ),
        )
        for index, (start, question_id) in enumerate(ordered_starts)
    }
    for question in questions:
        variants = [blocks.get(question.question_id, "")]
        if page_text_variants and question.question_id in page_ranges:
            start, end = page_ranges[question.question_id]
            variant_count = max(
                (
                    len(page_text_variants.get(page_number, ()))
                    for page_number in range(start, end + 1)
                ),
                default=0,
            )
            variants.extend(
                "\n".join(
                    page_text_variants.get(page_number, ())[variant_index]
                    for page_number in range(start, end + 1)
                    if variant_index < len(page_text_variants.get(page_number, ()))
                )
                for variant_index in range(variant_count)
            )
        normalized_variants = tuple(_normalized(value) for value in variants)
        missing: list[str] = []
        if not any(_normalized(question.title) in value for value in normalized_variants):
            missing.append("title")
        if not any(_normalized(question.prompt) in value for value in normalized_variants):
            missing.append("prompt")
        for label, values in question.answer_fields.items():
            for index, value in enumerate(values):
                expected_value = (
                    printable_inline_text(value)
                    if label == "参考入口"
                    else value
                )
                if not any(
                    _normalized(expected_value) in variant
                    for variant in normalized_variants
                ):
                    missing.append(f"{label}[{index}]")
        if missing:
            issues[question.question_id] = tuple(missing)
    return issues


def _flatten_outline(items, depth: int = 0):
    for item in items:
        if isinstance(item, list):
            yield from _flatten_outline(item, depth + 1)
        elif getattr(item, "title", None):
            yield depth, item


def _line_max_font_size(line: Mapping[str, object]) -> float:
    return max(
        (
            float(char.get("size", 0.0))
            for char in (line.get("chars") or ())
            if isinstance(char, Mapping)
        ),
        default=0.0,
    )


def _line_uses_font(
    line: Mapping[str, object],
    postscript_name: str,
) -> bool:
    return any(
        postscript_name in str(char.get("fontname", ""))
        for char in (line.get("chars") or ())
        if isinstance(char, Mapping)
    )


def _line_is_at_content_left(line: Mapping[str, object]) -> bool:
    try:
        x0 = float(line.get("x0", -1.0))
    except (TypeError, ValueError):
        return False
    return 18 * mm <= x0 <= 22 * mm


def extract_artifact_section_titles(
    text_lines_by_page: Mapping[
        int,
        Sequence[Mapping[str, object]],
    ],
    fonts: FontSet,
) -> tuple[str, ...]:
    """Recover section-like headings from PDF text, font and geometry evidence."""
    candidates: list[tuple[int, float, str]] = []
    for page_number in sorted(text_lines_by_page):
        lines = text_lines_by_page[page_number]
        for line in lines:
            text = str(line.get("text", "")).strip()
            match = ARTIFACT_SECTION_HEADING_RE.fullmatch(text)
            try:
                top = float(line.get("top", -1.0))
            except (TypeError, ValueError):
                top = -1.0
            if (
                match
                and _line_uses_font(line, fonts.heading_postscript_name)
                and 18.0 <= _line_max_font_size(line) <= 24.0
            ):
                candidates.append(
                    (
                        page_number,
                        top,
                        f"{int(match.group(1))}. {match.group(2)}",
                    )
                )

        marker_numbers = tuple(
            match.group(1)
            for line in lines
            if (
                match := BLUEPRINT_SECTION_MARKER_RE.fullmatch(
                    str(line.get("text", "")).strip()
                )
            )
        )
        if len(marker_numbers) != 1:
            continue
        marker_number = marker_numbers[0]
        has_large_number = any(
            str(line.get("text", "")).strip() == marker_number
            and _line_max_font_size(line) >= 60.0
            and _line_is_at_content_left(line)
            for line in lines
        )
        has_score_marker = any(
            _normalized("UNIFIED SCORE · 0—4")
            in _normalized(str(line.get("text", "")))
            for line in lines
        )
        divider_titles = tuple(
            line
            for line in lines
            if (
                _line_uses_font(line, fonts.heading_postscript_name)
                and 22.0 <= _line_max_font_size(line) <= 30.0
                and _line_is_at_content_left(line)
                and 220.0 <= float(line.get("top", -1.0)) <= 330.0
            )
        )
        if has_large_number and has_score_marker and len(divider_titles) == 1:
            title_line = divider_titles[0]
            candidates.append(
                (
                    page_number,
                    float(title_line.get("top", 0.0)),
                    (
                        f"{int(marker_number)}. "
                        f"{str(title_line.get('text', '')).strip()}"
                    ),
                )
            )
    return tuple(
        title
        for _, _, title in sorted(candidates)
    )


def analyze_artifact_section_structure(
    expected_section_titles: Sequence[str],
    artifact_section_titles: Sequence[str],
) -> dict[str, Mapping[str, object]]:
    """Require exact section title order and multiplicity in the PDF artifact."""
    expected = tuple(expected_section_titles)
    actual = tuple(artifact_section_titles)
    if actual == expected:
        return {}
    return {
        "artifact_section_sequence": _mismatch(
            list(expected),
            list(actual),
        )
    }


def analyze_section_outline_structure(
    expected_section_titles: Sequence[str],
    outline_entries: Sequence[tuple[int, object]],
) -> dict[str, Mapping[str, object]]:
    """Require the artifact's level-two section bookmarks in exact source order."""
    expected = tuple(expected_section_titles)
    actual = tuple(
        str(item.title)
        for depth, item in outline_entries
        if depth == 1
    )
    if actual == expected:
        return {}
    return {
        "section_outline_sequence": _mismatch(
            list(expected),
            list(actual),
        )
    }


def _metadata(reader: PdfReader) -> dict[str, str | None]:
    metadata = reader.metadata
    return {
        "title": metadata.title if metadata else None,
        "author": metadata.author if metadata else None,
        "subject": metadata.subject if metadata else None,
        "keywords": metadata.get("/Keywords") if metadata else None,
    }


def _mismatch(expected: object, actual: object) -> dict[str, object]:
    return {"expected": expected, "actual": actual}


def _receipt_mismatches(
    receipt_path: Path,
    *,
    source_sha256: str,
    pdf_sha256: str,
    page_count: int,
    question_ids: Sequence[str],
    section_titles: Sequence[str],
    fonts: FontSet,
) -> dict[str, Mapping[str, object]]:
    if not receipt_path.is_file():
        return {"receipt_exists": _mismatch(True, False)}
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {"receipt_json": _mismatch("valid JSON", str(error))}
    expected_values = {
        "source_sha256": source_sha256,
        "pdf_sha256": pdf_sha256,
        "page_count": page_count,
        "question_ids": list(question_ids),
        "bookmark_titles": list(section_titles),
        "question_count": len(question_ids),
        "section_count": len(section_titles),
    }
    receipt_keys = {
        "source_sha256": "source_sha256",
        "pdf_sha256": "sha256",
        "page_count": "page_count",
        "question_ids": "question_ids",
        "bookmark_titles": "bookmark_titles",
        "question_count": "question_count",
        "section_count": "section_count",
    }
    issues: dict[str, Mapping[str, object]] = {}
    for report_key, receipt_key in receipt_keys.items():
        actual = receipt.get(receipt_key)
        expected = expected_values[report_key]
        if actual != expected:
            issues[report_key] = _mismatch(expected, actual)
    generated_at = receipt.get("generated_at")
    if not isinstance(generated_at, str) or not generated_at.strip():
        issues["generated_at"] = _mismatch("non-empty ISO-8601 string", generated_at)
    font_names = receipt.get("font_names")
    expected_font_names = [fonts.body, fonts.heading, fonts.code]
    if font_names != expected_font_names:
        issues["font_names"] = _mismatch(expected_font_names, font_names)
    expected_font_roles = {
        "body": {
            "registered_name": fonts.body,
            "source": fonts.body_source,
            "postscript_name": fonts.body_postscript_name,
            "subfont_index": fonts.body_subfont_index,
            "embedded": True,
        },
        "heading": {
            "registered_name": fonts.heading,
            "source": fonts.heading_source,
            "postscript_name": fonts.heading_postscript_name,
            "subfont_index": fonts.heading_subfont_index,
            "embedded": True,
        },
        "code": {
            "registered_name": fonts.code,
            "source": fonts.code_source,
            "postscript_name": fonts.code_postscript_name,
            "subfont_index": fonts.code_subfont_index,
            "embedded": fonts.code_embedded,
        },
    }
    if receipt.get("font_roles") != expected_font_roles:
        issues["font_roles"] = _mismatch(
            expected_font_roles,
            receipt.get("font_roles"),
        )
    return issues


def _non_question_headings(source_text: str) -> tuple[str, ...]:
    headings = []
    for match in re.finditer(r"^###\s+(.+?)\s*$", source_text, re.MULTILINE):
        title = match.group(1)
        if not re.match(rf"^{QUESTION_ID_PATTERN}\.\s+", title):
            headings.append(title)
    return tuple(headings)


def _table_cells(bank) -> tuple[str, ...]:
    cells: list[str] = []
    for table in bank.tables:
        for row in table.rows:
            cells.extend(cell for cell in row if cell.strip())
    return _ordered_unique(cells)


def _expected_low_density_page(text: str, page_number: int) -> bool:
    if page_number == 1:
        return True
    normalized = _normalized(text)
    return (
        _normalized("UNIFIED SCORE · 0—4") in normalized
        and _normalized("CAPABILITY BLUEPRINT / SECTION") in normalized
    ) or _normalized("可打印面试记录表") in normalized


def verify_pdf(
    source: Path,
    pdf: Path,
    *,
    receipt_path: Path | None = None,
) -> VerificationReport:
    """Verify content, structure, metadata, geometry, links and build receipt."""
    source = Path(source)
    pdf = Path(pdf)
    receipt_path = Path(receipt_path or DEFAULT_RECEIPT_PATH)
    source_text = source.read_text(encoding="utf-8")
    source_hash = sha256(source_text.encode("utf-8")).hexdigest()
    pdf_hash = _file_sha256(pdf)
    bank = parse_question_bank(source_text)
    fonts = register_fonts()
    expected_question_ids = tuple(question.question_id for question in bank.questions)
    section_titles = tuple(section.title for section in bank.level2_sections)

    reader = PdfReader(pdf)
    with pdfplumber.open(pdf) as opened_pdf:
        page_texts_list: list[str] = []
        page_sizes_list: list[tuple[object, object]] = []
        header_texts_list: list[str] = []
        footer_texts_list: list[str] = []
        page_rects: dict[int, Sequence[Mapping[str, object]]] = {}
        page_text_variants: dict[int, tuple[str, ...]] = {}
        physical_tables_by_page: dict[
            int,
            Sequence[Sequence[Sequence[str | None]]],
        ] = {}
        text_lines_by_page: dict[
            int,
            Sequence[Mapping[str, object]],
        ] = {}
        for page_number, page in enumerate(opened_pdf.pages, start=1):
            full_text = page.extract_text() or ""
            page_texts_list.append(full_text)
            text_lines_by_page[page_number] = tuple(
                page.extract_text_lines(return_chars=True)
            )
            page_sizes_list.append((page.width, page.height))
            midpoint = float(page.width) / 2
            page_text_variants[page_number] = (
                full_text,
                page.crop(
                    (20 * mm, 0, midpoint - 2 * mm, float(page.height))
                ).extract_text()
                or "",
                page.crop(
                    (midpoint + 2 * mm, 0, float(page.width) - 20 * mm, float(page.height))
                ).extract_text()
                or "",
            )
            header_texts_list.append(
                page.crop((0, 0, float(page.width), 16 * mm)).extract_text()
                or ""
            )
            footer_texts_list.append(
                page.crop(
                    (
                        0,
                        float(page.height) - 16 * mm,
                        float(page.width),
                        float(page.height),
                    )
                ).extract_text()
                or ""
            )
            page_rects[page_number] = tuple(page.rects)
            extracted_tables = page.extract_tables()
            if extracted_tables:
                physical_tables_by_page[page_number] = extracted_tables
        page_texts = tuple(page_texts_list)
        page_sizes = tuple(page_sizes_list)
        header_texts = tuple(header_texts_list)
        footer_texts = tuple(footer_texts_list)
    extracted_text = "\n".join(page_texts)
    normalized_extracted = _normalized(extracted_text)

    question_opening_records = tuple(
        (match.group(1), page_number)
        for page_number, text in enumerate(page_texts, start=1)
        for match in QUESTION_HEADING_RE.finditer(text)
    )
    pdf_question_ids = tuple(
        question_id
        for question_id, _ in question_opening_records
    )
    source_id_set = set(expected_question_ids)
    pdf_id_set = set(pdf_question_ids)
    missing_question_ids = tuple(qid for qid in expected_question_ids if qid not in pdf_id_set)
    unexpected_question_ids = _ordered_unique(qid for qid in pdf_question_ids if qid not in source_id_set)
    duplicate_question_ids = _ordered_unique(
        qid for qid in pdf_question_ids if pdf_question_ids.count(qid) > 1
    )
    section_pages = _section_pages(page_texts, bank)
    question_pages: dict[str, int] = {}
    for question_id, page_number in question_opening_records:
        question_pages.setdefault(question_id, page_number)

    metadata = _metadata(reader)
    metadata_mismatches = {
        key: _mismatch(expected, metadata.get(key))
        for key, expected in EXPECTED_METADATA.items()
        if metadata.get(key) != expected
    }

    expected_width, expected_height = A4
    page_size_issues = tuple(
        {
            "page": page_number,
            "expected": [round(expected_width, 3), round(expected_height, 3)],
            "actual": [round(float(width), 3), round(float(height), 3)],
        }
        for page_number, (width, height) in enumerate(page_sizes, start=1)
        if abs(float(width) - expected_width) > 0.5
        or abs(float(height) - expected_height) > 0.5
    )

    outline_entries = tuple(_flatten_outline(reader.outline))
    outline_titles = tuple(item.title for _, item in outline_entries)
    question_outline_records = tuple(
        (match.group(1), item)
        for _, item in outline_entries
        if (match := QUESTION_OUTLINE_RE.match(item.title))
    )
    question_outline_ids = tuple(qid for qid, _ in question_outline_records)
    missing_outline_sections = tuple(title for title in section_titles if title not in outline_titles)
    missing_question_outline_ids = tuple(
        qid for qid in expected_question_ids if qid not in question_outline_ids
    )
    duplicate_question_outline_ids = _ordered_unique(
        qid for qid in question_outline_ids if question_outline_ids.count(qid) > 1
    )
    invalid_outline_destinations: list[str] = []
    for _, item in outline_entries:
        destination_page = _destination_page(reader, item)
        if destination_page is None:
            invalid_outline_destinations.append(item.title)
        elif not 1 <= destination_page <= len(reader.pages):
            invalid_outline_destinations.append(item.title)

    outline_destination_issues: dict[str, Mapping[str, object]] = {}
    for title in section_titles:
        records = tuple(item for _, item in outline_entries if item.title == title)
        expected_page = section_pages.get(title)
        actual_pages = tuple(_destination_page(reader, item) for item in records)
        if len(records) != 1 or expected_page is None or actual_pages != (expected_page,):
            outline_destination_issues[title] = {
                "expected_title": title,
                "expected_page": expected_page,
                "actual_titles": [item.title for item in records],
                "actual_pages": list(actual_pages),
            }
    for question in bank.questions:
        records = tuple(
            item
            for question_id, item in question_outline_records
            if question_id == question.question_id
        )
        expected_title = f"{question.question_id}. {question.title}"
        expected_page = question_pages.get(question.question_id)
        actual_titles = tuple(item.title for item in records)
        actual_pages = tuple(_destination_page(reader, item) for item in records)
        if (
            len(records) != 1
            or actual_titles != (expected_title,)
            or expected_page is None
            or actual_pages != (expected_page,)
        ):
            outline_destination_issues[question.question_id] = {
                "expected_title": expected_title,
                "expected_page": expected_page,
                "actual_titles": list(actual_titles),
                "actual_pages": list(actual_pages),
            }

    link_records: list[tuple[int, object]] = []
    uri_link_records: list[tuple[int, str]] = []
    for page_number, page in enumerate(reader.pages, start=1):
        for annotation in page.get("/Annots") or []:
            annotation_object = annotation.get_object()
            if annotation_object.get("/Subtype") == "/Link":
                link_records.append((page_number, annotation_object))
                action = annotation_object.get("/A")
                if action and action.get("/URI"):
                    uri_link_records.append((page_number, str(action.get("/URI"))))
    toc_pages = {
        page_number
        for page_number, text in enumerate(page_texts, start=1)
        if re.search(r"(?m)^目录$", text)
    }
    toc_link_count = sum(1 for page_number, _ in link_records if page_number in toc_pages)
    toc_link_records = sorted(
        (
            (page_number, annotation)
            for page_number, annotation in link_records
            if page_number in toc_pages
        ),
        key=lambda record: (
            record[0],
            -float((record[1].get("/Rect") or [0, 0, 0, 0])[3]),
            float((record[1].get("/Rect") or [0, 0, 0, 0])[0]),
        ),
    )
    toc_link_issues: dict[str, Mapping[str, object]] = {}
    for index, title in enumerate(section_titles):
        pair = toc_link_records[index * 2 : index * 2 + 2]
        expected_page = section_pages.get(title)
        actual_pages = tuple(
            _link_destination_page(reader, annotation)
            for _, annotation in pair
        )
        if len(pair) != 2 or expected_page is None or actual_pages != (expected_page, expected_page):
            toc_link_issues[title] = {
                "expected_count": 2,
                "actual_count": len(pair),
                "expected_page": expected_page,
                "actual_pages": list(actual_pages),
            }

    blocks = _question_blocks(extracted_text)
    reference_entry_count = sum(
        len(_exact_label_indices(block, "参考入口"))
        for block in blocks.values()
    )
    expected_reference_entry_count = sum(
        "参考入口" in question.answer_fields
        for question in bank.questions
    )
    structural_mismatches: dict[str, Mapping[str, object]] = {}
    expected_structure = {
        "page_range": "80-140",
        "source_question_count": 80,
        "source_unique_question_count": 80,
        "pdf_question_count": 80,
        "pdf_unique_question_count": 80,
        "reference_entry_count": expected_reference_entry_count,
        "section_count": 12,
        "source_table_count": 4,
        "outline_count": 93,
        "question_outline_count": 80,
        "link_count": 24,
        "toc_link_count": 24,
    }
    actual_structure = {
        "page_range": len(reader.pages),
        "source_question_count": len(expected_question_ids),
        "source_unique_question_count": len(set(expected_question_ids)),
        "pdf_question_count": len(pdf_question_ids),
        "pdf_unique_question_count": len(set(pdf_question_ids)),
        "reference_entry_count": reference_entry_count,
        "section_count": len(section_titles),
        "source_table_count": len(bank.tables),
        "outline_count": len(outline_entries),
        "question_outline_count": len(question_outline_records),
        "link_count": len(link_records),
        "toc_link_count": toc_link_count,
    }
    if not 80 <= len(reader.pages) <= 140:
        structural_mismatches["page_range"] = _mismatch("80-140", len(reader.pages))
    for key in expected_structure.keys() - {"page_range"}:
        if actual_structure[key] != expected_structure[key]:
            structural_mismatches[key] = _mismatch(expected_structure[key], actual_structure[key])
    structural_mismatches.update(
        analyze_question_openings(
            expected_question_ids,
            question_opening_records,
        )
    )
    structural_mismatches.update(
        analyze_section_outline_structure(
            section_titles,
            outline_entries,
        )
    )
    structural_mismatches.update(
        analyze_artifact_section_structure(
            section_titles,
            extract_artifact_section_titles(
                text_lines_by_page,
                fonts,
            ),
        )
    )

    question_label_issues = {
        qid: missing
        for qid, missing in analyze_question_fields(extracted_text, bank.questions).items()
        if missing
    }
    question_record_issues = analyze_interviewer_records(
        extracted_text,
        bank.questions,
    )
    question_order_issues = analyze_question_order(
        extracted_text,
        bank.questions,
    )
    reference_entry_issues = analyze_reference_entries(
        extracted_text,
        bank.questions,
    )
    forbidden_tokens = find_forbidden_tokens(extracted_text)
    leaked_reference_tokens = tuple(
        token
        for token in forbidden_tokens
        if token.lower().startswith("file://") or token == "../"
    )
    if leaked_reference_tokens:
        reference_entry_issues["document"] = tuple(
            f"reference path leakage: {token}"
            for token in leaked_reference_tokens
        )
    if uri_link_records:
        reference_entry_issues["pdf_annotations"] = tuple(
            f"unexpected URI link on page {page}: {uri}"
            for page, uri in uri_link_records
        )
    expected_headers = _expected_page_headers(
        page_texts,
        section_titles,
        section_pages,
        bank.questions,
        question_pages,
    )
    page_furniture_issues = analyze_page_furniture(
        header_texts,
        footer_texts,
        expected_headers,
    )
    divider_contract_issues = analyze_divider_contracts(
        page_texts,
        bank,
        section_pages,
        page_rects,
    )
    font_role_issues = analyze_font_roles(reader, fonts, question_pages)
    question_content_issues = _question_content_issues(
        extracted_text,
        bank.questions,
        question_pages=question_pages,
        page_text_variants=page_text_variants,
    )
    missing_sections = tuple(title for title in section_titles if _normalized(title) not in normalized_extracted)
    missing_non_question_headings = tuple(
        title
        for title in _non_question_headings(source_text)
        if _normalized(title) not in normalized_extracted
    )
    missing_table_cells = tuple(
        cell for cell in _table_cells(bank) if _normalized(cell) not in normalized_extracted
    )
    table_contract_issues = analyze_table_contracts(
        bank.tables,
        source_table_section_titles(source_text),
        section_pages,
        physical_tables_by_page,
        questions=bank.questions,
        question_pages=question_pages,
        printable_form_page=_heading_pages(
            page_texts,
            ("面试记录模板",),
        ).get("面试记录模板"),
        require_complete_layout=True,
    )
    maintenance_rules = tuple(
        item
        for section in bank.maintenance_rules
        for block in section.blocks
        if isinstance(block, ListBlock)
        for item in block.items
    )
    maintenance_title = bank.maintenance_rules[0].title if bank.maintenance_rules else ""
    maintenance_rule_issues = analyze_maintenance_rules(
        page_texts,
        maintenance_rules,
        maintenance_page=section_pages.get(maintenance_title, 0),
    )
    normalized_form_text = _normalized_form_text(extracted_text)
    missing_record_fields = tuple(
        field
        for field in REQUIRED_RECORD_FIELDS
        if _normalized_form_text(field) not in normalized_form_text
    )

    page_text_char_counts = tuple(len(_normalized(text)) for text in page_texts)
    near_blank_pages = tuple(
        page_number
        for page_number, char_count in enumerate(page_text_char_counts, start=1)
        if char_count < 100
    )
    unexpected_near_blank_pages = tuple(
        page_number
        for page_number in near_blank_pages
        if not _expected_low_density_page(page_texts[page_number - 1], page_number)
    )
    receipt_mismatches = _receipt_mismatches(
        receipt_path,
        source_sha256=source_hash,
        pdf_sha256=pdf_hash,
        page_count=len(reader.pages),
        question_ids=expected_question_ids,
        section_titles=section_titles,
        fonts=fonts,
    )
    file_mode_value = pdf.stat().st_mode & 0o777
    file_mode = f"{file_mode_value:04o}"
    file_mode_issue = (
        None
        if file_mode_value == 0o644
        else f"expected release mode 0644, actual {file_mode}"
    )
    expected_tail = source_last_sentence(bank)
    longest_answer_tail_issue = (
        None
        if expected_tail
        and expected_tail in normalize_for_match(extracted_text)
        else "longest answer tail missing from extracted PDF text"
    )

    return VerificationReport(
        source_path=str(source.resolve()),
        pdf_path=str(pdf.resolve()),
        receipt_path=str(receipt_path.resolve()),
        source_sha256=source_hash,
        pdf_sha256=pdf_hash,
        file_size_bytes=pdf.stat().st_size,
        page_count=len(reader.pages),
        source_question_count=len(expected_question_ids),
        pdf_question_count=len(pdf_question_ids),
        reference_entry_count=reference_entry_count,
        section_count=len(section_titles),
        outline_count=len(outline_entries),
        question_outline_count=len(question_outline_records),
        link_count=len(link_records),
        toc_link_count=toc_link_count,
        metadata=metadata,
        metadata_mismatches=metadata_mismatches,
        structural_mismatches=structural_mismatches,
        receipt_mismatches=receipt_mismatches,
        missing_question_ids=missing_question_ids,
        unexpected_question_ids=unexpected_question_ids,
        duplicate_question_ids=duplicate_question_ids,
        missing_sections=missing_sections,
        missing_non_question_headings=missing_non_question_headings,
        missing_outline_sections=missing_outline_sections,
        missing_question_outline_ids=missing_question_outline_ids,
        duplicate_question_outline_ids=duplicate_question_outline_ids,
        invalid_outline_destinations=tuple(invalid_outline_destinations),
        outline_destination_issues=outline_destination_issues,
        toc_link_issues=toc_link_issues,
        question_label_issues=question_label_issues,
        question_record_issues=question_record_issues,
        question_order_issues=question_order_issues,
        reference_entry_issues=reference_entry_issues,
        page_furniture_issues=page_furniture_issues,
        divider_contract_issues=divider_contract_issues,
        font_role_issues=font_role_issues,
        question_content_issues=question_content_issues,
        missing_table_cells=missing_table_cells,
        table_contract_issues=table_contract_issues,
        maintenance_rule_issues=maintenance_rule_issues,
        missing_record_fields=missing_record_fields,
        forbidden_tokens=forbidden_tokens,
        page_size_issues=page_size_issues,
        page_text_char_counts=page_text_char_counts,
        near_blank_pages=near_blank_pages,
        unexpected_near_blank_pages=unexpected_near_blank_pages,
        question_pages=question_pages,
        file_mode=file_mode,
        file_mode_issue=file_mode_issue,
        longest_answer_tail_issue=longest_answer_tail_issue,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--receipt", type=Path, default=DEFAULT_RECEIPT_PATH)
    parser.add_argument("--report", type=Path, default=REPORT_PATH)
    args = parser.parse_args()
    report = verify_pdf(args.source, args.pdf, receipt_path=args.receipt)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(report.to_dict(), ensure_ascii=False, indent=2) + "\n"
    args.report.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
