from __future__ import annotations

from io import BytesIO
import inspect
import json
from pathlib import Path
import posixpath
from tempfile import TemporaryDirectory
import re
import stat
from types import MappingProxyType
import unittest
from unittest.mock import patch
import unicodedata

import pdfplumber
import pypdfium2 as pdfium
from pypdf import PdfReader
from reportlab.pdfbase import pdfmetrics
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen.canvas import Canvas
from reportlab.platypus import NextPageTemplate, PageBreak, Table

from interview_question_bank.components import (
    ChapterDividerFlowable,
    interview_record_flowable,
    question_flowables,
    table_flowable,
)
import interview_question_bank.components as component_module
from interview_question_bank.document import (
    TITLE,
    HeadingFlowable,
    InterviewDocTemplate,
    PageContextMarker,
    _document_styles,
    append_question_pages,
    build_pdf,
    build_story,
    story_metrics,
)
import interview_question_bank.document as document_module
from interview_question_bank.parser import Question, Section, parse_question_bank
from interview_question_bank.styles import build_styles, register_fonts
from interview_question_bank.verify import analyze_font_roles


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "project-interview-question-bank.md"
SECTION_TITLES = (
    "1. 使用方式",
    "2. 七个岗位的抽题路线",
    "3. 共享核心题",
    "4. 高级前端工程师题组",
    "5. AI 全栈工程师题组",
    "6. 高级后端平台工程师题组",
    "7. 应用安全与 AI 安全工程师题组",
    "8. 产品经理兼前端开发题组",
    "9. 测试工程师题组",
    "10. 运维工程师题组",
    "11. 面试官综合评估表",
    "12. 题库维护规则",
)
FRAME_WIDTH = A4[0] - 40 * mm
REFERENCE_LINK_RE = re.compile(r"\[([^]]+)\]\(([^)]+)\)")


def outline_titles(reader: PdfReader) -> list[str]:
    titles: list[str] = []

    def visit(items) -> None:
        for item in items:
            if isinstance(item, list):
                visit(item)
            elif getattr(item, "title", None):
                titles.append(item.title)

    visit(reader.outline)
    return titles


def outline_entries(reader: PdfReader) -> list[tuple[int, object]]:
    entries: list[tuple[int, object]] = []

    def visit(items, depth: int = 0) -> None:
        for item in items:
            if isinstance(item, list):
                visit(item, depth + 1)
            elif getattr(item, "title", None):
                entries.append((depth, item))

    visit(reader.outline)
    return entries


def nested_tables(flowable):
    if isinstance(flowable, Table):
        yield flowable
    for attribute in ("_content", "_flowables"):
        for child in getattr(flowable, attribute, ()):
            yield from nested_tables(child)


def normalized(text: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", text).replace("\x7f", ""))


def printable_reference_text(text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        label = match.group(1).replace(chr(96), "")
        target = posixpath.normpath(posixpath.join("docs", match.group(2)))
        while target.startswith("../"):
            target = target[3:]
        return f"{label} · {target}"

    return REFERENCE_LINK_RE.sub(replace, text).replace(chr(96), "")


def question_blocks(extracted_text: str) -> dict[str, str]:
    pattern = re.compile(r"(?m)^((?:C|FE|AI|BE|SEC|PM|QA|OPS)\d+)\s*·\s+")
    matches = list(pattern.finditer(extracted_text))
    return {
        match.group(1): extracted_text[
            match.start() : matches[index + 1].start() if index + 1 < len(matches) else len(extracted_text)
        ]
        for index, match in enumerate(matches)
    }


def region_text(page, *, header: bool) -> str:
    height = 16 * mm
    if header:
        box = (0, 0, float(page.width), height)
    else:
        box = (0, float(page.height) - height, float(page.width), float(page.height))
    return page.crop(box).extract_text() or ""


def synthetic_question(
    question_id: str,
    *,
    answer_repetitions: int = 1,
) -> Question:
    answer = " ".join(["分页合同必须稳定、可抽取且不越过页脚安全区。"] * answer_repetitions)
    if answer_repetitions > 1:
        answer += " LONG-ANSWER-END"
    return Question(
        question_id=question_id,
        title=f"{question_id} synthetic pagination contract",
        prompt="请解释逐题起页、续页页眉与安全页脚合同。",
        preface=(),
        answer_fields=MappingProxyType(
            {
                "考察点": ("分页状态与页面模板。",),
                "答案要点": (answer,),
                "追问": ("切换到下一题时如何避免状态泄漏？",),
                "风险信号": ("依赖隐式分页或复用上一题状态。",),
                "评分锚点": ("0 分无合同；4 分有可重复的真实 PDF 验证。",),
            }
        ),
    )


def synthetic_question_story(
    questions: list[Question],
    styles,
):
    document_styles = _document_styles(styles)
    group = Section(2, "90. 分页合同", ())
    story = [
        HeadingFlowable(
            TITLE,
            document_styles["cover_title"],
            anchor="synthetic-title",
            outline_level=0,
            toc_level=None,
        ),
        NextPageTemplate("Chapter"),
        PageBreak(),
        PageContextMarker(group.title, None),
        ChapterDividerFlowable(
            section_number="90",
            section_title=group.title,
            group_name="分页合同",
            question_range="S1 - S2",
            ability_keywords="逐题起页、续页状态、安全页脚",
            styles=styles,
            anchor="synthetic-pagination-contract",
        ),
        NextPageTemplate("Body"),
    ]
    append_question_pages(story, group, questions, styles)
    return story


def build_synthetic_question_pdf(
    questions: list[Question],
    styles,
) -> bytes:
    preview = BytesIO()
    InterviewDocTemplate(preview, styles).multiBuild(
        synthetic_question_story(questions, styles)
    )
    total_pages = len(PdfReader(BytesIO(preview.getvalue())).pages)

    final = BytesIO()
    InterviewDocTemplate(
        final,
        styles,
        total_pages=total_pages,
    ).multiBuild(synthetic_question_story(questions, styles))
    return final.getvalue()


def locate_question_heading_pages(
    pdf_bytes: bytes,
    question_ids: list[str],
) -> dict[str, int]:
    reader = PdfReader(BytesIO(pdf_bytes))
    pages = [page.extract_text() or "" for page in reader.pages]
    return {
        question_id: next(
            page_index
            for page_index, text in enumerate(pages)
            if re.search(rf"(?m)^{re.escape(question_id)}\s*·\s+", text)
        )
        for question_id in question_ids
    }


def footer_safe_zone_geometry_issues(
    page,
    *,
    total_pages: int,
    tolerance: float = 0.5,
) -> dict[str, list[dict]]:
    """Return extractable or painted non-furniture objects below the Body frame."""
    safe_zone_top = A4[1] - 17 * mm
    footer_band_top = A4[1] - 10 * mm
    expected_footer = normalized(
        "面试官版 / 内部使用"
        "2026-07-23"
        f"第 {page.page_number} / {total_pages} 页"
    )
    words = page.extract_words()
    footer_words = [
        word
        for word in words
        if float(word["top"]) >= footer_band_top - tolerance
    ]
    if normalized(" ".join(word["text"] for word in footer_words)) != expected_footer:
        footer_words = []

    def inside_footer_word(item: dict) -> bool:
        return any(
            float(item["x0"]) >= float(word["x0"]) - tolerance
            and float(item["x1"]) <= float(word["x1"]) + tolerance
            and float(item["top"]) >= float(word["top"]) - tolerance
            and float(item["bottom"]) <= float(word["bottom"]) + tolerance
            for word in footer_words
        )

    unsafe_chars = [
        char
        for char in page.chars
        if char["text"].strip()
        and float(char["bottom"]) > safe_zone_top + tolerance
        and not inside_footer_word(char)
    ]
    unsafe_words = [
        word
        for word in words
        if float(word["bottom"]) > safe_zone_top + tolerance
        and word not in footer_words
    ]
    unsafe_rects = [
        rect
        for rect in page.rects
        if (rect.get("fill") or rect.get("stroke"))
        and float(rect["bottom"]) > safe_zone_top + tolerance
    ]

    footer_rule_top = A4[1] - 12 * mm

    def is_footer_rule(line: dict) -> bool:
        return (
            abs(float(line["x0"]) - 20 * mm) <= tolerance
            and abs(float(line["x1"]) - (A4[0] - 20 * mm)) <= tolerance
            and abs(float(line["top"]) - footer_rule_top) <= tolerance
            and abs(float(line["bottom"]) - footer_rule_top) <= tolerance
            and abs(float(line.get("linewidth") or 0) - 0.45) <= tolerance
        )

    unsafe_lines = [
        line
        for line in page.lines
        if float(line["bottom"]) > safe_zone_top + tolerance
        and not is_footer_rule(line)
    ]
    return {
        "chars": unsafe_chars,
        "words": unsafe_words,
        "rects": unsafe_rects,
        "lines": unsafe_lines,
    }


def build_unsafe_footer_geometry_pdf() -> bytes:
    buffer = BytesIO()
    canvas = Canvas(buffer, pagesize=A4)
    safe_height = 17 * mm
    canvas.setFont("Helvetica", 12)
    canvas.drawString(24 * mm, safe_height, "BODY-CROSSES-SAFE-LINE")
    canvas.setFillColorRGB(0.85, 0.88, 0.92)
    canvas.setStrokeColorRGB(0.1, 0.2, 0.3)
    canvas.rect(70 * mm, 14 * mm, 42 * mm, 6 * mm, stroke=1, fill=1)
    canvas.line(120 * mm, 20 * mm, 160 * mm, 14 * mm)
    canvas.showPage()
    canvas.save()
    return buffer.getvalue()


class _RecordingCanvas:
    def __init__(self) -> None:
        self.rectangles: list[tuple[float, float, float, float]] = []

    def rect(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        *,
        stroke: int,
        fill: int,
    ) -> None:
        self.rectangles.append((x, y, width, height))

    @staticmethod
    def stringWidth(text: str, font_name: str, font_size: float) -> float:
        return pdfmetrics.stringWidth(text, font_name, font_size)

    def __getattr__(self, name: str):
        return lambda *args, **kwargs: None


class BlueprintPageTemplateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_text = SOURCE.read_text(encoding="utf-8")
        cls.bank = parse_question_bank(cls.source_text)
        cls.fonts = register_fonts()
        cls.styles = build_styles(cls.fonts)
        cls.story = build_story(cls.bank, cls.styles)
        cls._directory = TemporaryDirectory()
        cls.pdf_path = Path(cls._directory.name) / "blueprint-pages.pdf"
        build_pdf(SOURCE, cls.pdf_path)
        cls.reader = PdfReader(cls.pdf_path)
        cls.page_texts = [page.extract_text() or "" for page in cls.reader.pages]
        cls.chapter_page_indexes = [
            index
            for index, text in enumerate(cls.page_texts)
            if "UNIFIED SCORE · 0—4" in text
        ]

    @classmethod
    def tearDownClass(cls) -> None:
        cls._directory.cleanup()

    @classmethod
    def render_page_at_72_dpi(cls, page_index: int):
        pdf = pdfium.PdfDocument(str(cls.pdf_path))
        page = pdf[page_index]
        try:
            return page.render(scale=1).to_pil()
        finally:
            page.close()
            pdf.close()

    def test_document_registers_cover_body_and_chapter_templates(self) -> None:
        with TemporaryDirectory() as directory:
            doc = InterviewDocTemplate(
                str(Path(directory) / "templates.pdf"),
                self.styles,
            )
        self.assertEqual(
            ["Cover", "Body", "Chapter"],
            [template.id for template in doc.pageTemplates],
        )

    def test_story_switches_chapter_and_body_templates_without_double_breaks(self) -> None:
        dividers = [
            index
            for index, flowable in enumerate(self.story)
            if isinstance(flowable, ChapterDividerFlowable)
        ]
        self.assertEqual(8, len(dividers))
        for index in dividers:
            with self.subTest(section=self.story[index].section_title):
                self.assertIsInstance(self.story[index - 5], NextPageTemplate)
                self.assertEqual(
                    ("nextPageTemplate", "Chapter"),
                    self.story[index - 5].action,
                )
                self.assertIsInstance(self.story[index - 4], PageBreak)
                self.assertIsInstance(self.story[index + 1], NextPageTemplate)
                self.assertEqual(
                    ("nextPageTemplate", "Body"),
                    self.story[index + 1].action,
                )
                self.assertIsInstance(self.story[index + 2], PageBreak)
        self.assertFalse(
            any(
                isinstance(left, PageBreak) and isinstance(right, PageBreak)
                for left, right in zip(self.story, self.story[1:])
            )
        )
        question_markers = [
            index
            for index, flowable in enumerate(self.story)
            if getattr(flowable, "kind", None) == "question"
        ]
        self.assertEqual(80, len(question_markers))
        for index in question_markers:
            self.assertIsInstance(self.story[index - 1], PageBreak)
            self.assertFalse(
                index >= 2 and isinstance(self.story[index - 2], PageBreak)
            )

    def test_chapter_pages_are_dedicated_full_pages_without_body_furniture(self) -> None:
        self.assertEqual(8, len(self.chapter_page_indexes))
        for page_index in self.chapter_page_indexes:
            text = self.page_texts[page_index]
            with self.subTest(page=page_index + 1):
                self.assertIn("CAPABILITY BLUEPRINT", text)
                self.assertIn("10 QUESTIONS", text)
                self.assertNotIn("答案要点", text)
                self.assertNotIn("面试官版 / 内部使用", text)
                self.assertNotRegex(text, r"第 \d+ / \d+ 页")
                self.assertLess(page_index + 1, len(self.page_texts))
                self.assertRegex(
                    self.page_texts[page_index + 1],
                    r"(?m)^(?:C|FE|AI|BE|SEC|PM|QA|OPS)1\s*·\s+",
                )

    def test_cover_and_chapter_pages_use_blueprint_colors_while_body_stays_white(self) -> None:
        self.assertEqual(8, len(self.chapter_page_indexes))
        accent_expected = (47, 111, 237)
        navy_expected = (13, 38, 62)
        accent_width = int(
            getattr(document_module, "BLUEPRINT_ACCENT_WIDTH", 11 * mm)
        )
        for page_index in [0, *self.chapter_page_indexes]:
            image = self.render_page_at_72_dpi(page_index)
            with self.subTest(page=page_index + 1, layer="accent"):
                actual = image.getpixel((8, 8))[:3]
                self.assertLessEqual(
                    max(abs(a - b) for a, b in zip(actual, accent_expected)),
                    4,
                )
            for point in (
                (accent_width + 8, 8),
                (image.width - 8, 8),
            ):
                with self.subTest(page=page_index + 1, point=point):
                    actual = image.getpixel(point)[:3]
                    self.assertLessEqual(
                        max(abs(a - b) for a, b in zip(actual, navy_expected)),
                        4,
                    )

        body_index = next(
            index
            for index, text in enumerate(self.page_texts)
            if "文档控制" in text
        )
        body_image = self.render_page_at_72_dpi(body_index)
        for point in ((8, 8), (body_image.width - 8, 8)):
            with self.subTest(body_page=body_index + 1, point=point):
                actual = body_image.getpixel(point)[:3]
                self.assertLessEqual(
                    max(abs(channel - 255) for channel in actual),
                    2,
                )

    def test_chapter_content_layer_exposes_safe_geometry_and_no_large_fill(self) -> None:
        divider = ChapterDividerFlowable(
            section_number="03",
            section_title="3. 共享核心题",
            group_name="共享核心题",
            question_range="C1 - C10",
            ability_keywords="系统边界、跨模块理解、工程取舍",
            styles=self.styles,
        )
        divider.wrap(FRAME_WIDTH, A4[1])
        recording_canvas = _RecordingCanvas()
        divider.canv = recording_canvas
        divider.draw()

        self.assertIsNotNone(getattr(divider, "metrics_rect", None))
        self.assertIsNotNone(getattr(divider, "decoration_rect", None))
        self.assertGreaterEqual(divider.decoration_clearance, 8)
        self.assertFalse(
            any(height >= 90 * mm for _, _, _, height in recording_canvas.rectangles)
        )

    def test_cover_text_is_extractable_and_uses_approved_title_size(self) -> None:
        cover_text = self.page_texts[0]
        for required in (
            "艾普项目高级岗位面试题库",
            "高级岗位内部面试与评分手册",
            "ENGINEERING INTERVIEW HANDBOOK",
            "80 QUESTIONS",
            "7 ROLE ROUTES",
            "0—4 UNIFIED SCORE",
            "A4 INTERVIEWER EDITION",
            "v1.0",
            "2026-07-23",
            "面试官版 / 内部使用 / 禁止外传",
        ):
            with self.subTest(required=required):
                self.assertIn(required, cover_text)
        self.assertNotIn("第 1 /", cover_text)
        cover_style = _document_styles(self.styles)["cover_title"]
        self.assertEqual(29, cover_style.fontSize)
        self.assertEqual(39, cover_style.leading)


class QuestionPaginationContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.styles = build_styles(register_fonts())

    def test_long_question_continuation_header_and_next_question_new_page(self) -> None:
        pdf_bytes = build_synthetic_question_pdf(
            [
                synthetic_question("Q900", answer_repetitions=900),
                synthetic_question("Q901"),
            ],
            self.styles,
        )
        reader = PdfReader(BytesIO(pdf_bytes))
        pages = [page.extract_text() or "" for page in reader.pages]
        q900_pages = [index for index, text in enumerate(pages) if "Q900" in text]
        q901_pages = [index for index, text in enumerate(pages) if "Q901" in text]

        self.assertGreaterEqual(len(q900_pages), 2)
        self.assertNotIn("Q900 · CONTINUED", pages[q900_pages[0]])
        for page_index in q900_pages[1:]:
            self.assertIn("Q900 · CONTINUED", pages[page_index])
        self.assertGreater(q901_pages[0], q900_pages[-1])
        self.assertNotIn("Q900 · CONTINUED", pages[q901_pages[0]])
        self.assertIn("LONG-ANSWER-END", "\n".join(pages))

    def test_before_document_resets_all_pagination_state(self) -> None:
        with TemporaryDirectory() as directory:
            doc = InterviewDocTemplate(
                str(Path(directory) / "state-reset.pdf"),
                self.styles,
            )
        doc.canv = _RecordingCanvas()
        doc._current_section = "stale section"
        doc._current_question = "Q999"
        doc._question_opening_pages = {"Q999": 99}

        doc.beforeDocument()

        self.assertEqual("文档控制", doc._current_section)
        self.assertIsNone(doc._current_question)
        self.assertEqual({}, doc._question_opening_pages)

    def test_every_question_heading_has_a_distinct_opening_page(self) -> None:
        question_ids = ["Q910", "Q911", "Q912"]
        pdf_bytes = build_synthetic_question_pdf(
            [synthetic_question(question_id) for question_id in question_ids],
            self.styles,
        )
        opening_pages = locate_question_heading_pages(pdf_bytes, question_ids)
        self.assertEqual(len(set(opening_pages.values())), 3)

        reader = PdfReader(BytesIO(pdf_bytes))
        pages = [page.extract_text() or "" for page in reader.pages]
        for question_id, opening_page in opening_pages.items():
            with self.subTest(question=question_id):
                self.assertIn(question_id, pages[opening_page])
                self.assertGreater(len(normalized(pages[opening_page])), len(question_id))
        self.assertFalse(
            any(not normalized(text) for text in pages),
            "synthetic pagination introduced an empty page",
        )

    def test_body_spans_do_not_enter_footer_safe_zone(self) -> None:
        pdf_bytes = build_synthetic_question_pdf(
            [synthetic_question("Q920", answer_repetitions=900)],
            self.styles,
        )
        safe_zone_top = A4[1] - 17 * mm
        with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
            total_pages = len(pdf.pages)
            body_pages = [
                page
                for page in pdf.pages
                if "CAPABILITY BLUEPRINT" not in (page.extract_text() or "")
                and (page.page_number != 1)
            ]
            for page in body_pages:
                geometry_issues = footer_safe_zone_geometry_issues(
                    page,
                    total_pages=total_pages,
                )
                footer_text = page.crop(
                    (0, safe_zone_top, float(page.width), float(page.height))
                ).extract_text() or ""
                expected_footer = (
                    "面试官版 / 内部使用"
                    "2026-07-23"
                    f"第 {page.page_number} / {total_pages} 页"
                )
                with self.subTest(page=page.page_number):
                    self.assertEqual(
                        {"chars": [], "words": [], "rects": [], "lines": []},
                        geometry_issues,
                    )
                    self.assertEqual(
                        normalized(expected_footer),
                        normalized(footer_text),
                    )

    def test_geometry_audit_rejects_crossing_character_panel_and_line(self) -> None:
        pdf_bytes = build_unsafe_footer_geometry_pdf()
        safe_zone_top = A4[1] - 17 * mm
        with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
            issues = footer_safe_zone_geometry_issues(
                pdf.pages[0],
                total_pages=1,
            )

        self.assertTrue(issues["chars"], "crossing character was not detected")
        self.assertTrue(issues["words"], "crossing word was not detected")
        self.assertTrue(issues["rects"], "crossing panel was not detected")
        self.assertTrue(issues["lines"], "crossing border line was not detected")
        self.assertTrue(
            any(
                float(char["top"]) < safe_zone_top < float(char["bottom"])
                for char in issues["chars"]
            ),
            "the negative fixture must include an explicitly crossing character",
        )


class DocumentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_text = SOURCE.read_text(encoding="utf-8")
        cls.bank = parse_question_bank(cls.source_text)
        cls.fonts = register_fonts()
        cls.styles = build_styles(cls.fonts)
        cls._formal_directory = TemporaryDirectory()
        cls.formal_pdf = Path(cls._formal_directory.name) / "final-contract.pdf"
        cls.formal_receipt = build_pdf(SOURCE, cls.formal_pdf)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._formal_directory.cleanup()

    def test_story_contains_all_required_units(self) -> None:
        story = build_story(self.bank, self.styles)
        metrics = story_metrics(story)
        self.assertEqual(1, metrics.cover_count)
        self.assertEqual(1, metrics.control_page_count)
        self.assertEqual(1, metrics.toc_count)
        self.assertEqual(1, metrics.role_routes_count)
        self.assertEqual(8, metrics.question_group_divider_count)
        self.assertEqual(80, metrics.question_count)
        self.assertEqual(1, metrics.assessment_count)
        self.assertEqual(1, metrics.printable_record_count)
        self.assertEqual(1, metrics.maintenance_count)
        self.assertEqual(12, metrics.level2_section_count)

    def test_built_pdf_has_metadata_links_and_all_section_bookmarks(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "question-bank.pdf"
            receipt = build_pdf(SOURCE, output)
            reader = PdfReader(output)
            self.assertGreaterEqual(len(reader.pages), 80)
            self.assertLessEqual(len(reader.pages), 140)
            self.assertEqual(len(reader.pages), receipt.page_count)
            self.assertEqual(80, len(receipt.question_ids))
            self.assertEqual(list(SECTION_TITLES), receipt.bookmark_titles)
            titles = outline_titles(reader)
            for title in SECTION_TITLES:
                self.assertIn(title, titles)
            entries_by_title = {item.title: item for _, item in outline_entries(reader)}
            for title in SECTION_TITLES[2:10]:
                destination = entries_by_title[title]
                divider_text = reader.pages[reader.get_destination_page_number(destination)].extract_text() or ""
                self.assertNotIn("面试官记录", divider_text)
            self.assertEqual("艾普项目高级岗位面试题库", reader.metadata.title)
            self.assertEqual("Aipu Project", reader.metadata.author)
            self.assertEqual("高级岗位内部面试与评分手册", reader.metadata.subject)
            self.assertEqual("interview, engineering, internal", reader.metadata.get("/Keywords"))
            link_count = sum(
                1
                for page in reader.pages
                for annotation in (page.get("/Annots") or [])
                if annotation.get_object().get("/Subtype") == "/Link"
            )
            self.assertGreaterEqual(link_count, 12)
            page_texts = [page.extract_text() or "" for page in reader.pages]
            self.assertNotIn("&#8226;", "\n".join(page_texts))
            record_page = next(text for text in page_texts if "候选人：" in text)
            self.assertIn("面试记录模板", record_page)
            ai2_page = next(text for text in page_texts if "AI2 ·" in text)
            self.assertNotIn("题前材料 参考答案、追问与评分", ai2_page)
            self.assertLess(ai2_page.index("当前循环从"), ai2_page.index("问题"))

    def test_pdf_contains_exactly_80_question_outline_destinations(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "question-bookmarks.pdf"
            receipt = build_pdf(SOURCE, output)
            reader = PdfReader(output)
            question_records: list[tuple[int, object, str | None]] = []
            current_section: str | None = None
            for depth, item in outline_entries(reader):
                if depth == 1 and item.title in SECTION_TITLES:
                    current_section = item.title
                if re.match(r"^(?:C|FE|AI|BE|SEC|PM|QA|OPS)\d+\. ", item.title):
                    question_records.append((depth, item, current_section))
            question_entries = [item for _, item, _ in question_records]
            self.assertEqual(80, len(question_entries))
            self.assertEqual({2}, {depth for depth, _, _ in question_records})
            self.assertEqual(
                receipt.question_ids,
                [item.title.partition(".")[0] for item in question_entries],
            )
            expected_parents = [
                title
                for title in SECTION_TITLES[2:10]
                for _ in range(10)
            ]
            self.assertEqual(
                expected_parents,
                [parent for _, _, parent in question_records],
            )
            self.assertTrue(
                all(reader.get_destination_page_number(item) >= 0 for item in question_entries)
            )

    def test_built_pdf_tables_stay_inside_20mm_to_190mm_bounds(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "table-geometry.pdf"
            build_pdf(SOURCE, output)
            with pdfplumber.open(output) as pdf:
                assessment_page = next(
                    page
                    for page in pdf.pages
                    if "11. 面试官综合评估表" in (page.extract_text() or "")
                    and "岗位能力权重建议" in (page.extract_text() or "")
                )
                record_page = next(
                    page
                    for page in pdf.pages
                    if "面试记录模板" in (page.extract_text() or "")
                    and "候选人" in (page.extract_text() or "")
                )
                assessment_tables = assessment_page.find_tables()
                record_tables = record_page.find_tables()
                self.assertEqual(2, len(assessment_tables))
                self.assertEqual(1, len(record_tables))
                tolerance = 0.5
                for table in [*assessment_tables, *record_tables]:
                    x0, _, x1, _ = table.bbox
                    self.assertGreaterEqual(x0, 20 * mm - tolerance)
                    self.assertLessEqual(x1, 190 * mm + tolerance)

    def test_control_page_labels_do_not_overlap_value_panels(self) -> None:
        with pdfplumber.open(self.formal_pdf) as pdf:
            page = pdf.pages[1]
            labels = {
                word["text"]: word
                for word in page.extract_words()
                if word["text"] in {"文档性质", "适用范围", "使用要求", "保密要求"}
            }
            panels = sorted(
                (
                    rect
                    for rect in page.rects
                    if float(rect["width"]) >= 160 * mm
                    and 20 <= float(rect["height"]) <= 50
                ),
                key=lambda rect: float(rect["top"]),
            )

        self.assertEqual(
            {"文档性质", "适用范围", "使用要求", "保密要求"},
            set(labels),
        )
        self.assertEqual(4, len(panels))
        for label, panel in zip(
            ("文档性质", "适用范围", "使用要求", "保密要求"),
            panels,
        ):
            with self.subTest(label=label):
                self.assertGreaterEqual(
                    float(panel["top"]),
                    float(labels[label]["bottom"]) + 3,
                )
        for panel, next_label in zip(
            panels[:3],
            ("适用范围", "使用要求", "保密要求"),
        ):
            with self.subTest(next_label=next_label):
                self.assertGreaterEqual(
                    float(labels[next_label]["top"]),
                    float(panel["bottom"]) + 3,
                )

    def test_control_page_routes_all_fields_through_external_blocks(self) -> None:
        block_type = getattr(component_module, "ExternalFieldBlock", None)
        self.assertIsNotNone(block_type)
        blocks = [
            flowable
            for flowable in build_story(self.bank, self.styles)
            if isinstance(flowable, block_type)
        ]
        self.assertEqual(
            ["文档性质", "适用范围", "使用要求", "保密要求"],
            [block.label for block in blocks],
        )

    def test_task3_assessment_tables_and_record_fit_170mm_frame(self) -> None:
        self.assertIn("available_width", inspect.signature(table_flowable).parameters)
        self.assertIn("available_width", inspect.signature(interview_record_flowable).parameters)
        assessment = table_flowable(
            self.bank.tables[-1], self.styles, available_width=FRAME_WIDTH
        )
        assessment_tables = list(nested_tables(assessment))
        self.assertEqual(2, len(assessment_tables))
        for table in assessment_tables:
            table.wrapOn(Canvas(BytesIO(), pagesize=A4), FRAME_WIDTH, A4[1])
            self.assertLessEqual(sum(table._colWidths), FRAME_WIDTH + 0.01)

        record = interview_record_flowable(
            self.bank.code_blocks[0], self.styles, available_width=FRAME_WIDTH
        )
        record.wrapOn(Canvas(BytesIO(), pagesize=A4), FRAME_WIDTH, A4[1])
        self.assertLessEqual(sum(record._colWidths), FRAME_WIDTH + 0.01)

    def test_body_footers_show_current_and_total_page_count(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "total-page-footers.pdf"
            receipt = build_pdf(SOURCE, output)
            reader = PdfReader(output)
            for page_number, page in enumerate(reader.pages[1:], start=2):
                text = page.extract_text() or ""
                if "UNIFIED SCORE · 0—4" in text:
                    self.assertNotIn("面试官版 / 内部使用", text)
                    self.assertNotRegex(text, r"第 \d+ / \d+ 页")
                    continue
                self.assertIn(f"第 {page_number} / {receipt.page_count} 页", text)

    def test_all_questions_have_structured_record_panels_inside_body_bounds(self) -> None:
        with pdfplumber.open(self.formal_pdf) as pdf:
            extracted_text = "\n".join(page.extract_text() or "" for page in pdf.pages)
            blocks = question_blocks(extracted_text)
            record_tables = []
            for page in pdf.pages:
                for table in page.find_tables():
                    rows = table.extract()
                    table_text = "\n".join(
                        cell or "" for row in rows for cell in row
                    )
                    if "面试官记录" in table_text:
                        record_tables.append(table)

        self.assertEqual(80, len(record_tables))
        self.assertEqual(
            [question.question_id for question in self.bank.questions],
            list(blocks),
        )
        for question in self.bank.questions:
            with self.subTest(question=question.question_id):
                block = blocks[question.question_id]
                self.assertEqual(1, block.count("面试官记录"))
                self.assertRegex(block, r"(?m)^证据\s*$")
                self.assertRegex(block, r"(?m)^风险\s*$")
                self.assertRegex(block, r"(?m)^评分\s+.*0.*1.*2.*3.*4")
        tolerance = 0.5
        for table in record_tables:
            x0, _, x1, _ = table.bbox
            self.assertGreaterEqual(x0, 20 * mm - tolerance)
            self.assertLessEqual(x1, 190 * mm + tolerance)

    def test_reference_entries_are_printable_and_optional_fields_are_ordered(self) -> None:
        reader = PdfReader(self.formal_pdf)
        extracted_text = "\n".join(page.extract_text() or "" for page in reader.pages)
        blocks = question_blocks(extracted_text)
        reference_questions = [
            question for question in self.bank.questions if "参考入口" in question.answer_fields
        ]

        self.assertEqual(33, len(reference_questions))
        self.assertEqual(33, sum(blocks[q.question_id].count("参考入口") for q in reference_questions))
        self.assertNotIn("../", extracted_text)
        self.assertNotIn("](", extracted_text)
        for question in reference_questions:
            for value in question.answer_fields["参考入口"]:
                self.assertIn(
                    normalized(printable_reference_text(value)),
                    normalized(blocks[question.question_id]),
                )

        c8 = normalized(blocks["C8"])
        c8_order = (
            "问题",
            "项目情景",
            "考察点",
            "答案要点",
            "追问",
            "风险信号",
            "评分锚点",
            "面试官记录",
        )
        c8_positions = [c8.index(label) for label in c8_order]
        self.assertEqual(sorted(c8_positions), c8_positions)

        ai2 = normalized(blocks["AI2"])
        self.assertLess(
            ai2.index(normalized("题前材料（盲面提供）")),
            ai2.index("问题"),
        )
        self.assertLess(ai2.index("参考入口"), ai2.index("面试官记录"))

    def test_dynamic_furniture_covers_control_questions_continuation_and_back_matter(self) -> None:
        with pdfplumber.open(self.formal_pdf) as pdf:
            page_texts = [page.extract_text() or "" for page in pdf.pages]
            headers = [region_text(page, header=True) for page in pdf.pages]
            footers = [region_text(page, header=False) for page in pdf.pages]

        total = len(page_texts)

        def assert_furniture(page_number: int, left: str, right: str) -> None:
            header = normalized(headers[page_number - 1])
            footer = normalized(footers[page_number - 1])
            self.assertIn(normalized(left), header)
            self.assertIn(normalized(right), header)
            self.assertIn(normalized("面试官版 / 内部使用"), footer)
            self.assertIn(normalized("2026-07-23"), footer)
            self.assertIn(normalized(f"第 {page_number} / {total} 页"), footer)

        self.assertNotIn(normalized("面试官版 / 内部使用"), normalized(footers[0]))
        assert_furniture(2, "文档控制", "艾普项目面试题库")

        starts: list[tuple[str, int]] = []
        for page_number, text in enumerate(page_texts, start=1):
            for match in re.finditer(
                r"(?m)^((?:C|FE|AI|BE|SEC|PM|QA|OPS)\d+)\s*·\s+",
                text,
            ):
                starts.append((match.group(1), page_number))
        start_map = dict(starts)
        assert_furniture(start_map["C1"], "3. 共享核心题", "C1")

        base_question = self.bank.questions[0]
        long_fields = dict(base_question.answer_fields)
        long_fields["答案要点"] = (
            " ".join([long_fields["答案要点"][0]] * 180) + " LONG-END",
        )
        long_question = Question(
            question_id=base_question.question_id,
            title=base_question.title,
            prompt=base_question.prompt,
            preface=(),
            answer_fields=MappingProxyType(long_fields),
        )
        document_styles = _document_styles(self.styles)

        def long_story():
            return [
                HeadingFlowable(
                    TITLE,
                    document_styles["cover_title"],
                    anchor="synthetic-title",
                    outline_level=0,
                    toc_level=None,
                ),
                NextPageTemplate("Body"),
                PageBreak(),
                HeadingFlowable(
                    "3. 共享核心题",
                    document_styles["section"],
                    anchor="synthetic-group",
                    outline_level=1,
                    toc_level=None,
                ),
                PageContextMarker("3. 共享核心题", "C1"),
                *question_flowables(long_question, self.styles),
            ]

        preview = Path(self._formal_directory.name) / "long-preview.pdf"
        InterviewDocTemplate(str(preview), self.styles).multiBuild(long_story())
        long_total = len(PdfReader(preview).pages)
        long_pdf = Path(self._formal_directory.name) / "long-final.pdf"
        InterviewDocTemplate(
            str(long_pdf),
            self.styles,
            total_pages=long_total,
        ).multiBuild(long_story())
        with pdfplumber.open(long_pdf) as pdf:
            long_texts = [page.extract_text() or "" for page in pdf.pages]
            long_headers = [region_text(page, header=True) for page in pdf.pages]
            long_footers = [region_text(page, header=False) for page in pdf.pages]
        opening_page = next(
            index
            for index, text in enumerate(long_texts, start=1)
            if "C1 ·" in text
        )
        continuation_page = opening_page + 1
        self.assertLessEqual(continuation_page, long_total)
        self.assertNotRegex(
            long_texts[continuation_page - 1],
            r"(?m)^C1\s*·\s+",
        )
        self.assertIn(
            normalized("3. 共享核心题"),
            normalized(long_headers[continuation_page - 1]),
        )
        self.assertIn("C1", normalized(long_headers[continuation_page - 1]))
        self.assertIn(
            normalized(f"第 {continuation_page} / {long_total} 页"),
            normalized(long_footers[continuation_page - 1]),
        )

        assessment_page = next(
            index
            for index, text in enumerate(page_texts, start=1)
            if "岗位能力权重建议" in text
        )
        record_page = next(
            index
            for index, text in enumerate(page_texts, start=1)
            if "面试记录模板" in text and "候选人：" in text
        )
        maintenance_page = max(
            index
            for index, text in enumerate(page_texts, start=1)
            if any(
                normalized(line) == normalized("12. 题库维护规则")
                for line in text.splitlines()
            )
        )
        assert_furniture(
            assessment_page,
            SECTION_TITLES[10],
            "艾普项目面试题库",
        )
        assert_furniture(record_page, SECTION_TITLES[10], "艾普项目面试题库")
        assert_furniture(
            maintenance_page,
            SECTION_TITLES[11],
            "艾普项目面试题库",
        )

    def test_all_eight_dividers_show_number_range_keywords_and_strong_color_block(self) -> None:
        capabilities = {
            row[0].replace(chr(96), ""): row[2]
            for row in self.bank.tables[0].rows[1:]
        }
        prefixes = ("C", "FE", "AI", "BE", "SEC", "PM", "QA", "OPS")
        with pdfplumber.open(self.formal_pdf) as pdf:
            pages = list(pdf.pages)
            for group, prefix in zip(self.bank.question_groups, prefixes):
                page = next(
                    page
                    for page in pages
                    if "UNIFIED SCORE · 0—4" in (page.extract_text() or "")
                    and any(
                        normalized(line)
                        == normalized(group.title.partition(".")[2].strip())
                        for line in (page.extract_text() or "").splitlines()
                    )
                )
                text = normalized(page.extract_text() or "")
                chapter_number = group.title.partition(".")[0].zfill(2)
                self.assertIn(chapter_number, text)
                self.assertIn(
                    normalized(group.title.partition(".")[2].strip()),
                    text,
                )
                self.assertIn(normalized(f"{prefix}1 - {prefix}10"), text)
                self.assertIn(normalized(capabilities[prefix]), text)
                strong_blocks = [
                    rect
                    for rect in page.rects
                    if float(rect["width"]) >= 50 * mm
                    and float(rect["height"]) >= 30 * mm
                    and tuple(
                        round(float(value), 3)
                        for value in (rect.get("non_stroking_color") or ())
                    )
                    in {
                        (0.051, 0.149, 0.243),
                        (0.086, 0.227, 0.373),
                        (0.184, 0.435, 0.929),
                    }
                ]
                self.assertTrue(
                    strong_blocks,
                    f"divider {group.title} lacks strong blue block",
                )

    def test_actual_pdf_resources_contain_distinct_embedded_font_roles(self) -> None:
        reader = PdfReader(self.formal_pdf)
        expected = {
            "body": getattr(self.fonts, "body_postscript_name", ""),
            "heading": getattr(self.fonts, "heading_postscript_name", ""),
            "code": getattr(self.fonts, "code_postscript_name", ""),
        }
        self.assertTrue(all(expected.values()))
        self.assertEqual(3, len(set(expected.values())))
        self.assertEqual(
            {},
            analyze_font_roles(reader, self.fonts, {"C1": 8}),
        )

    def test_failed_formal_render_preserves_previous_valid_output(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "formal.pdf"
            previous = b"previous-valid-formal-pdf"
            output.write_bytes(previous)
            final_paths: list[Path] = []

            def failing_render(path, bank, sections, styles, *, total_pages):
                path = Path(path)
                path.write_bytes(b"partial-render")
                if total_pages is None:
                    return 90
                final_paths.append(path)
                raise RuntimeError("forced final render failure")

            with patch.object(
                document_module,
                "_render_pdf",
                side_effect=failing_render,
            ):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "forced final render failure",
                ):
                    build_pdf(SOURCE, output)

            self.assertEqual(previous, output.read_bytes())
            self.assertEqual(1, len(final_paths))
            self.assertEqual(output.parent, final_paths[0].parent)
            self.assertNotEqual(output, final_paths[0])

    def test_atomic_formal_publication_uses_world_readable_mode(self) -> None:
        with TemporaryDirectory() as directory:
            output = Path(directory) / "formal.pdf"

            def successful_render(path, bank, sections, styles, *, total_pages):
                Path(path).write_bytes(b"complete-formal-pdf")
                return 90

            with patch.object(
                document_module,
                "_render_pdf",
                side_effect=successful_render,
            ):
                build_pdf(SOURCE, output)

            self.assertEqual(0o644, stat.S_IMODE(output.stat().st_mode))


if __name__ == "__main__":
    unittest.main()
