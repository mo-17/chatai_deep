"""Complete ReportLab document assembly for the Aipu interview handbook."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from hashlib import sha256
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile, TemporaryDirectory
from types import MappingProxyType
from typing import Iterable, Sequence

from pypdf import PdfReader
from reportlab.lib.colors import HexColor
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    KeepTogether,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
)
from reportlab.platypus.tableofcontents import TableOfContents

from interview_question_bank.components import (
    ChapterDividerFlowable,
    QuestionHeadingFlowable,
    interview_record_flowable,
    question_flowables,
    table_flowable,
)
from interview_question_bank.parser import (
    Block,
    CodeBlock,
    InlineText,
    ListBlock,
    Question,
    QuestionBank,
    Section,
    TableBlock,
    build_sections,
    parse_question_bank,
)
from interview_question_bank.styles import StyleSet, build_styles, register_fonts, safe_inline


TITLE = "艾普项目高级岗位面试题库"
SUBJECT = "高级岗位内部面试与评分手册"
AUTHOR = "Aipu Project"
KEYWORDS = "interview, engineering, internal"
DOCUMENT_SHORT_TITLE = "艾普项目面试题库"
FOOTER_LEFT = "面试官版 / 内部使用"
FOOTER_CENTER = "内容快照 2026-07-23"
QUESTION_PREFIXES = ("C", "FE", "AI", "BE", "SEC", "PM", "QA", "OPS")
FRAME_WIDTH = A4[0] - 40 * mm


@dataclass(frozen=True)
class BuildReceipt:
    source_sha256: str
    sha256: str
    page_count: int
    question_ids: list[str]
    bookmark_titles: list[str]
    font_names: list[str]
    font_roles: dict[str, dict[str, object]]
    generated_at: str

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class StoryMetrics:
    cover_count: int
    control_page_count: int
    toc_count: int
    role_routes_count: int
    question_group_divider_count: int
    question_count: int
    assessment_count: int
    printable_record_count: int
    maintenance_count: int
    level2_section_count: int


class UnitMarker(Flowable):
    """Zero-height semantic marker used by document structure tests."""

    def __init__(self, kind: str) -> None:
        super().__init__()
        self.kind = kind
        self.width = 0
        self.height = 0

    def wrap(self, available_width: float, available_height: float) -> tuple[float, float]:
        return 0, 0

    def draw(self) -> None:
        return None


class PageContextMarker(Flowable):
    """Zero-height marker consumed before end-of-page furniture is rendered."""

    def __init__(self, section_title: str, question_id: str | None = None) -> None:
        super().__init__()
        self.section_title = section_title
        self.question_id = question_id
        self.width = 0
        self.height = 0

    def wrap(self, available_width: float, available_height: float) -> tuple[float, float]:
        return 0, 0

    def draw(self) -> None:
        return None


class HeadingFlowable(Paragraph):
    """Visible heading carrying stable anchor, outline and TOC semantics."""

    def __init__(
        self,
        text: str,
        style: ParagraphStyle,
        *,
        anchor: str,
        outline_level: int,
        toc_level: int | None,
    ) -> None:
        super().__init__(safe_inline(text, style.fontName), style)
        self.plain_text = text
        self.anchor = anchor
        self.outline_level = outline_level
        self.toc_level = toc_level


def _slug(text: str) -> str:
    digest = sha256(text.encode("utf-8")).hexdigest()[:12]
    return "section-" + digest


class InterviewDocTemplate(BaseDocTemplate):
    """A4 handbook template with a furniture-free cover and body furniture."""

    def __init__(
        self,
        filename: str,
        styles: StyleSet,
        *,
        total_pages: int | None = None,
    ) -> None:
        self.styles = styles
        self.total_pages = total_pages
        self._current_section = "文档控制"
        self._current_question: str | None = None
        width, height = A4
        left = right = 20 * mm
        top = 18 * mm
        bottom = 17 * mm
        super().__init__(
            filename,
            pagesize=A4,
            leftMargin=left,
            rightMargin=right,
            topMargin=top,
            bottomMargin=bottom,
            title=TITLE,
            author=AUTHOR,
            subject=SUBJECT,
        )
        frame = Frame(
            left,
            bottom,
            width - left - right,
            height - top - bottom,
            leftPadding=0,
            rightPadding=0,
            id="body-frame",
        )
        self.addPageTemplates(
            [
                PageTemplate(id="Cover", frames=[frame], onPage=self._draw_cover),
                PageTemplate(
                    id="Body",
                    frames=[frame],
                    onPageEnd=self._draw_body,
                ),
            ]
        )

    def beforeDocument(self) -> None:
        self.canv.setTitle(TITLE)
        self.canv.setSubject(SUBJECT)
        self.canv.setAuthor(AUTHOR)
        self.canv.setKeywords(KEYWORDS)

    def _draw_cover(self, canvas, doc) -> None:
        canvas.saveState()
        canvas.setFillColor(self.styles.primary)
        canvas.rect(0, 0, A4[0], A4[1], stroke=0, fill=1)
        canvas.setFillColor(HexColor("#2F6FED"))
        canvas.rect(0, 0, 11 * mm, A4[1], stroke=0, fill=1)
        canvas.restoreState()

    def _draw_body(self, canvas, doc) -> None:
        """Draw dynamic furniture after page content has established context."""
        canvas.saveState()
        canvas.setStrokeColor(self.styles.line)
        canvas.setLineWidth(0.45)
        canvas.line(20 * mm, A4[1] - 13.5 * mm, A4[0] - 20 * mm, A4[1] - 13.5 * mm)
        canvas.line(20 * mm, 12 * mm, A4[0] - 20 * mm, 12 * mm)
        canvas.setFont(self.styles.fonts.body, 7.3)
        canvas.setFillColor(HexColor("#536575"))
        canvas.drawString(
            20 * mm,
            A4[1] - 10.5 * mm,
            self._current_section,
        )
        header_right = self._current_question or DOCUMENT_SHORT_TITLE
        canvas.setFont(
            self.styles.fonts.code if self._current_question else self.styles.fonts.body,
            7.3,
        )
        canvas.drawRightString(
            A4[0] - 20 * mm,
            A4[1] - 10.5 * mm,
            header_right,
        )
        canvas.setFont(self.styles.fonts.body, 7.1)
        canvas.setFillColor(HexColor("#536575"))
        canvas.drawString(20 * mm, 7.7 * mm, FOOTER_LEFT)
        canvas.drawCentredString(A4[0] / 2, 7.7 * mm, FOOTER_CENTER)
        total = self.total_pages if self.total_pages is not None else "?"
        canvas.drawRightString(
            A4[0] - 20 * mm,
            7.7 * mm,
            f"第 {doc.page} / {total} 页",
        )
        canvas.restoreState()

    def afterFlowable(self, flowable: Flowable) -> None:
        if isinstance(flowable, PageContextMarker):
            self._current_section = flowable.section_title
            self._current_question = flowable.question_id
            return
        if isinstance(flowable, ChapterDividerFlowable):
            if flowable.anchor is None:
                return
            self.canv.bookmarkPage(flowable.anchor)
            self.canv.addOutlineEntry(
                flowable.plain_text,
                flowable.anchor,
                flowable.outline_level,
                False,
            )
            if flowable.toc_level is not None:
                self.notify(
                    "TOCEntry",
                    (
                        flowable.toc_level,
                        flowable.plain_text,
                        self.page,
                        flowable.anchor,
                    ),
                )
            return
        if isinstance(flowable, HeadingFlowable):
            self.canv.bookmarkPage(flowable.anchor)
            self.canv.addOutlineEntry(
                flowable.plain_text,
                flowable.anchor,
                flowable.outline_level,
                False,
            )
            if flowable.toc_level is not None:
                self.notify(
                    "TOCEntry",
                    (flowable.toc_level, flowable.plain_text, self.page, flowable.anchor),
                )
            return
        if isinstance(flowable, QuestionHeadingFlowable):
            question_id = flowable.question_id
            question_title = flowable.question_title
            self._current_question = question_id
            anchor = f"question-{question_id.lower()}"
            self.canv.bookmarkPage(anchor)
            self.canv.addOutlineEntry(f"{question_id}. {question_title}", anchor, 2, False)


def _document_styles(styles: StyleSet) -> dict[str, ParagraphStyle]:
    body = ParagraphStyle(
        "DocumentBody",
        fontName=styles.fonts.body,
        fontSize=9.2,
        leading=15,
        textColor=HexColor("#172B3A"),
        spaceAfter=6,
    )
    return {
        "cover_title": ParagraphStyle(
            "CoverTitle",
            parent=body,
            fontName=styles.fonts.heading,
            fontSize=29,
            leading=39,
            textColor=HexColor("#FFFFFF"),
            alignment=TA_LEFT,
            spaceAfter=10,
        ),
        "cover_subtitle": ParagraphStyle(
            "CoverSubtitle",
            parent=body,
            fontSize=12.5,
            leading=20,
            textColor=HexColor("#DCE8FF"),
            spaceAfter=8,
        ),
        "cover_meta": ParagraphStyle(
            "CoverMeta",
            parent=body,
            fontSize=9,
            leading=16,
            textColor=HexColor("#DCE8FF"),
        ),
        "section": ParagraphStyle(
            "SectionHeading",
            parent=body,
            fontName=styles.fonts.heading,
            fontSize=20,
            leading=27,
            textColor=styles.primary,
            spaceAfter=10,
            keepWithNext=True,
        ),
        "subsection": ParagraphStyle(
            "SubsectionHeading",
            parent=body,
            fontName=styles.fonts.heading,
            fontSize=13.2,
            leading=19,
            textColor=styles.primary,
            spaceBefore=8,
            spaceAfter=5,
            keepWithNext=True,
        ),
        "body": body,
        "bullet": ParagraphStyle(
            "DocumentBullet",
            parent=body,
            leftIndent=12,
            firstLineIndent=-8,
            bulletIndent=0,
            spaceAfter=4,
        ),
        "control_label": ParagraphStyle(
            "ControlLabel",
            parent=body,
            textColor=styles.primary,
            fontSize=8.2,
            leading=12,
            # Paragraph border padding is painted outside the wrapped height.
            # Reserve the value panel's 7 pt top padding plus a visible gap.
            spaceAfter=8,
        ),
        "control_value": ParagraphStyle(
            "ControlValue",
            parent=body,
            fontSize=10.5,
            leading=16,
            backColor=HexColor("#F6F8FA"),
            borderColor=styles.line,
            borderWidth=0.5,
            borderPadding=7,
            spaceAfter=7,
        ),
        "divider_title": ParagraphStyle(
            "DividerTitle",
            parent=body,
            fontName=styles.fonts.heading,
            fontSize=24,
            leading=34,
            textColor=styles.primary,
            alignment=TA_CENTER,
            spaceAfter=12,
        ),
        "divider_meta": ParagraphStyle(
            "DividerMeta",
            parent=body,
            fontSize=10,
            leading=17,
            textColor=HexColor("#536575"),
            alignment=TA_CENTER,
        ),
        "toc_title": ParagraphStyle(
            "TocTitle",
            parent=body,
            fontName=styles.fonts.heading,
            fontSize=20,
            leading=27,
            textColor=styles.primary,
            spaceAfter=12,
        ),
        "toc_level": ParagraphStyle(
            "TocLevel",
            parent=body,
            fontSize=10,
            leading=18,
            leftIndent=0,
            firstLineIndent=0,
            textColor=styles.primary,
        ),
        "small_right": ParagraphStyle(
            "SmallRight",
            parent=body,
            fontSize=8,
            textColor=HexColor("#536575"),
            alignment=TA_RIGHT,
        ),
    }


def _source_inline(text: str, styles: StyleSet) -> str:
    text = text.replace("<br/>", "\n").replace("<br>", "\n")
    rendered = safe_inline(text, styles.fonts.code)
    rendered = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", rendered)
    return rendered


def _block_flowables(
    block: Block,
    styles: StyleSet,
    doc_styles: dict[str, ParagraphStyle],
) -> list[Flowable]:
    if isinstance(block, InlineText):
        return [Paragraph(_source_inline(block.text, styles), doc_styles["body"])]
    if isinstance(block, ListBlock):
        flows: list[Flowable] = []
        for index, item in enumerate(block.items, start=1):
            bullet = f"{index}." if block.ordered else "•"
            flows.append(Paragraph(_source_inline(item, styles), doc_styles["bullet"], bulletText=bullet))
        return flows
    if isinstance(block, TableBlock):
        return [
            table_flowable(block, styles, available_width=FRAME_WIDTH),
            Spacer(1, 4 * mm),
        ]
    if isinstance(block, CodeBlock):
        return [
            interview_record_flowable(block, styles, available_width=FRAME_WIDTH)
        ]
    return []


def _section_children(sections: Sequence[Section] | None) -> dict[str, tuple[Section, ...]]:
    if not sections:
        return {}
    result: dict[str, list[Section]] = {}
    active: str | None = None
    for section in sections:
        if section.level == 2:
            active = section.title
            result.setdefault(active, [])
        elif active is not None and section.level == 3:
            result[active].append(section)
    return {key: tuple(value) for key, value in result.items()}


def _section_heading(title: str, doc_styles: dict[str, ParagraphStyle]) -> HeadingFlowable:
    return HeadingFlowable(
        title,
        doc_styles["section"],
        anchor=_slug(title),
        outline_level=1,
        toc_level=0,
    )


def _append_source_sections(
    story: list[Flowable],
    sections: Iterable[Section],
    styles: StyleSet,
    doc_styles: dict[str, ParagraphStyle],
) -> None:
    for section in sections:
        story.append(Paragraph(_source_inline(section.title, styles), doc_styles["subsection"]))
        for block in section.blocks:
            story.extend(_block_flowables(block, styles, doc_styles))


def _fallback_usage(bank: QuestionBank) -> tuple[Section, ...]:
    blocks: list[Block] = []
    if bank.tables:
        blocks.extend(bank.tables[:2])
    return (
        Section(3, "题目编号与统一评分", tuple(blocks)),
        Section(
            3,
            "面试执行原则",
            (
                InlineText("评分对象是候选人拿到约束后能否推导出可靠方案，而不是能否复述文档答案。"),
            ),
        ),
    )


def _question_for_document(question: Question) -> Question:
    """Move parser-only summary markers out and blind-mode material before the prompt."""
    preface = [item for item in question.preface if item != "参考答案、追问与评分"]
    fields = dict(question.answer_fields)
    for label in tuple(fields):
        if label.startswith("题前材料"):
            preface.extend(fields.pop(label))
    return Question(
        question_id=question.question_id,
        title=question.title,
        prompt=question.prompt,
        preface=tuple(preface),
        answer_fields=MappingProxyType(fields),
    )


def _group_ability_keywords(bank: QuestionBank) -> dict[str, str]:
    """Derive divider keywords from the source prefix/role/capability table."""
    if not bank.tables:
        raise RuntimeError("Question-group ability table is missing")
    mapping = {
        row[0].replace("`", "").strip(): row[2].strip()
        for row in bank.tables[0].rows[1:]
        if len(row) >= 3
    }
    missing = tuple(prefix for prefix in QUESTION_PREFIXES if prefix not in mapping)
    if missing:
        raise RuntimeError(f"Question-group ability keywords missing for: {missing}")
    return mapping


def build_story(
    bank: QuestionBank,
    styles: StyleSet,
    *,
    sections: Sequence[Section] | None = None,
) -> list[Flowable]:
    """Build the complete story in source order; ``multiBuild`` fills the TOC."""
    ds = _document_styles(styles)
    children = _section_children(sections)
    story: list[Flowable] = []

    story.extend(
        [
            UnitMarker("cover"),
            Spacer(1, 48 * mm),
            HeadingFlowable(
                TITLE,
                ds["cover_title"],
                anchor="document-title",
                outline_level=0,
                toc_level=None,
            ),
            Paragraph(SUBJECT, ds["cover_subtitle"]),
            Spacer(1, 18 * mm),
            Paragraph("内部资料 | INTERNAL USE ONLY", ds["cover_meta"]),
            Paragraph("内容快照：2026-07-23", ds["cover_meta"]),
            Paragraph("版本：1.0 | 责任团队：Aipu Project", ds["cover_meta"]),
            NextPageTemplate("Body"),
            PageBreak(),
            UnitMarker("control_page"),
            PageContextMarker("文档控制"),
            Paragraph("文档控制", ds["section"]),
            Paragraph("文档性质", ds["control_label"]),
            Paragraph("内部面试材料，仅用于高级岗位能力评估。", ds["control_value"]),
            Paragraph("适用范围", ds["control_label"]),
            Paragraph("高级前端、AI 全栈、高级后端平台、应用安全与 AI 安全、产品经理兼前端、测试、运维。", ds["control_value"]),
            Paragraph("使用要求", ds["control_label"]),
            Paragraph("面试前选定预读或盲面模式；结论必须记录证据、风险、验证与回滚。", ds["control_value"]),
            Paragraph("保密要求", ds["control_label"]),
            Paragraph("不得向候选人或外部系统泄露参考答案、风险信号与评分锚点。", ds["control_value"]),
            PageBreak(),
        ]
    )

    usage = bank.level2_sections[0]
    story.extend(
        [
            UnitMarker("level2_section"),
            PageContextMarker(usage.title),
            _section_heading(usage.title, ds),
        ]
    )
    _append_source_sections(story, children.get(usage.title, _fallback_usage(bank)), styles, ds)
    story.append(PageBreak())

    story.extend(
        [
            UnitMarker("toc"),
            PageContextMarker("目录"),
            Paragraph("目录", ds["toc_title"]),
        ]
    )
    toc = TableOfContents()
    toc.levelStyles = [ds["toc_level"]]
    toc.dotsMinLevel = 0
    story.extend([toc, Paragraph("点击条目可跳转到相应章节。", ds["small_right"]), PageBreak()])

    routes = bank.level2_sections[1]
    story.extend(
        [
            UnitMarker("level2_section"),
            UnitMarker("role_routes"),
            PageContextMarker(routes.title),
            _section_heading(routes.title, ds),
        ]
    )
    for block in routes.blocks:
        story.extend(_block_flowables(block, styles, ds))
    story.append(PageBreak())

    questions_by_prefix = {
        prefix: [question for question in bank.questions if question.question_id.startswith(prefix)]
        for prefix in QUESTION_PREFIXES
    }
    ability_keywords = _group_ability_keywords(bank)
    for group_index, group in enumerate(bank.question_groups):
        prefix = QUESTION_PREFIXES[group_index]
        questions = questions_by_prefix[prefix]
        if group_index:
            story.append(PageBreak())
        story.extend(
            [
                UnitMarker("level2_section"),
                UnitMarker("question_group_divider"),
                PageContextMarker(group.title),
                ChapterDividerFlowable(
                    section_number=group.title.partition(".")[0].zfill(2),
                    section_title=group.title,
                    group_name=group.title.partition(".")[2].strip(),
                    question_range=(
                        f"{questions[0].question_id} - "
                        f"{questions[-1].question_id}"
                    ),
                    ability_keywords=ability_keywords[prefix],
                    styles=styles,
                    anchor=_slug(group.title),
                ),
                PageBreak(),
            ]
        )
        for question_index, question in enumerate(questions):
            if question_index:
                story.append(PageBreak())
            story.append(UnitMarker("question"))
            story.append(PageContextMarker(group.title, question.question_id))
            flows = question_flowables(_question_for_document(question), styles)
            story.extend(flows)

    assessment = bank.level2_sections[10]
    story.extend(
        [
            PageBreak(),
            UnitMarker("level2_section"),
            UnitMarker("assessment"),
            PageContextMarker(assessment.title),
            _section_heading(assessment.title, ds),
        ]
    )
    assessment_children = children.get(assessment.title, ())
    if assessment_children:
        for child in assessment_children:
            if child.title == "面试记录模板":
                story.extend(
                    [
                        PageBreak(),
                        UnitMarker("printable_record"),
                        PageContextMarker(assessment.title),
                    ]
                )
            story.append(Paragraph(_source_inline(child.title, styles), ds["subsection"]))
            for block in child.blocks:
                story.extend(_block_flowables(block, styles, ds))
    else:
        if bank.tables:
            story.extend(
                [
                    Paragraph("岗位能力权重建议", ds["subsection"]),
                    table_flowable(
                        bank.tables[-1], styles, available_width=FRAME_WIDTH
                    ),
                ]
            )
        if bank.code_blocks:
            story.extend(
                [
                    PageBreak(),
                    UnitMarker("printable_record"),
                    Paragraph("面试记录模板", ds["subsection"]),
                    interview_record_flowable(
                        bank.code_blocks[0], styles, available_width=FRAME_WIDTH
                    ),
                ]
            )

    maintenance = bank.level2_sections[11]
    story.extend(
        [
            PageBreak(),
            UnitMarker("level2_section"),
            UnitMarker("maintenance"),
            PageContextMarker(maintenance.title),
            _section_heading(maintenance.title, ds),
        ]
    )
    for block in maintenance.blocks:
        story.extend(_block_flowables(block, styles, ds))
    return story


def story_metrics(story: Sequence[Flowable]) -> StoryMetrics:
    counts: dict[str, int] = {}
    for flowable in story:
        if isinstance(flowable, UnitMarker):
            counts[flowable.kind] = counts.get(flowable.kind, 0) + 1
    return StoryMetrics(
        cover_count=counts.get("cover", 0),
        control_page_count=counts.get("control_page", 0),
        toc_count=counts.get("toc", 0),
        role_routes_count=counts.get("role_routes", 0),
        question_group_divider_count=counts.get("question_group_divider", 0),
        question_count=counts.get("question", 0),
        assessment_count=counts.get("assessment", 0),
        printable_record_count=counts.get("printable_record", 0),
        maintenance_count=counts.get("maintenance", 0),
        level2_section_count=counts.get("level2_section", 0),
    )


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _render_pdf(
    output: Path,
    bank: QuestionBank,
    sections: Sequence[Section],
    styles: StyleSet,
    *,
    total_pages: int | None,
) -> int:
    doc = InterviewDocTemplate(str(output), styles, total_pages=total_pages)
    doc.multiBuild(build_story(bank, styles, sections=sections))
    return len(PdfReader(output).pages)


def build_pdf(source: Path, output: Path) -> BuildReceipt:
    """Build and atomically publish the formal interview-handbook PDF."""
    source = Path(source)
    output = Path(output)
    source_text = source.read_text(encoding="utf-8")
    bank = parse_question_bank(source_text)
    _, sections = build_sections(source_text)
    fonts = register_fonts()
    styles = build_styles(fonts)
    output.parent.mkdir(parents=True, exist_ok=True)
    preview_root = Path(__file__).resolve().parents[1]
    with TemporaryDirectory(prefix="interview-question-bank-", dir=preview_root) as directory:
        preview = Path(directory) / "preview.pdf"
        expected_page_count = _render_pdf(
            preview,
            bank,
            sections,
            styles,
            total_pages=None,
        )
    with NamedTemporaryFile(
        prefix=f".{output.name}.",
        suffix=".tmp.pdf",
        dir=output.parent,
        delete=False,
    ) as handle:
        formal_temporary = Path(handle.name)
    try:
        page_count = _render_pdf(
            formal_temporary,
            bank,
            sections,
            styles,
            total_pages=expected_page_count,
        )
        if page_count != expected_page_count:
            raise RuntimeError(
                "Page count changed between preview and final build: "
                f"{expected_page_count} -> {page_count}"
            )
        if not 80 <= page_count <= 140:
            raise RuntimeError(
                f"Unexpected page count: {page_count}; expected 80-140"
            )
        receipt = BuildReceipt(
            source_sha256=sha256(source_text.encode("utf-8")).hexdigest(),
            sha256=_file_sha256(formal_temporary),
            page_count=page_count,
            question_ids=[question.question_id for question in bank.questions],
            bookmark_titles=[section.title for section in bank.level2_sections],
            font_names=[fonts.body, fonts.heading, fonts.code],
            font_roles={
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
            },
            generated_at=datetime.now(timezone.utc).isoformat(),
        )
        os.chmod(formal_temporary, 0o644)
        os.replace(formal_temporary, output)
        return receipt
    finally:
        formal_temporary.unlink(missing_ok=True)
