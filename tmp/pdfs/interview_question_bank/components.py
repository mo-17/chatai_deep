"""Splittable ReportLab components for the interview handbook."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Sequence

from reportlab.lib.colors import Color, HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import CondPageBreak, Flowable, KeepTogether, Paragraph, Spacer, Table, TableStyle

from interview_question_bank.parser import CodeBlock, Question, TableBlock
from interview_question_bank.styles import StyleSet, safe_inline


BODY_WIDTH = A4[0] - 40 * mm
FIELD_ORDER = ("考察点", "答案要点", "追问", "风险信号", "评分锚点")
PROJECT_CONTEXT_LABEL = "项目情景"
REFERENCE_LABEL = "参考入口"
FIELD_PANEL_GAP = 4.0
FIELD_LABEL_HORIZONTAL_PADDING = 7.0
FIELD_LABEL_VERTICAL_PADDING = 4.0
FIELD_BODY_HORIZONTAL_PADDING = 7.0
FIELD_BODY_VERTICAL_PADDING = 6.0
KEEP_BODY_LINES = 2
COMPACT_FIELD_GAP = 8.0
COMPACT_FIELD_MAX_HEIGHT = 42 * mm
EXTERNAL_FIELD_GAP = 3.0


class QuestionHeadingFlowable(Paragraph):
    """Question heading with stable navigation metadata for document templates."""

    def __init__(self, question: Question, styles: StyleSet) -> None:
        super().__init__(
            f"{safe_inline(question.question_id, styles.fonts.code)} · "
            f"{safe_inline(question.title, styles.fonts.code)}",
            styles.question_heading,
        )
        self.question_id = question.question_id
        self.question_title = question.title


class ChapterDividerFlowable(Flowable):
    """Large, extractable blue chapter anchor derived from source metadata."""

    def __init__(
        self,
        *,
        section_number: str,
        section_title: str,
        group_name: str,
        question_range: str,
        ability_keywords: str,
        styles: StyleSet,
        anchor: str | None = None,
        outline_level: int = 1,
        toc_level: int | None = 0,
    ) -> None:
        super().__init__()
        self.section_number = section_number
        self.section_title = section_title
        self.group_name = group_name
        self.question_range = question_range
        self.ability_keywords = ability_keywords
        self.styles = styles
        self.plain_text = section_title
        self.anchor = anchor
        self.outline_level = outline_level
        self.toc_level = toc_level
        self.width = BODY_WIDTH
        self.height = 92 * mm

    def wrap(self, available_width: float, available_height: float) -> tuple[float, float]:
        self.width = min(BODY_WIDTH, available_width)
        return self.width, self.height

    def draw(self) -> None:
        canvas = self.canv
        canvas.saveState()
        canvas.setFillColor(self.styles.primary)
        canvas.rect(0, 0, self.width, self.height, stroke=0, fill=1)
        canvas.setFillColor(self.styles.accent)
        canvas.rect(0, 0, 10 * mm, self.height, stroke=0, fill=1)

        left = 20 * mm
        canvas.setFillColor(HexColor("#DCE8FF"))
        canvas.setFont(self.styles.fonts.body, 8.5)
        canvas.drawString(left, self.height - 14 * mm, self.section_title)

        canvas.setFillColor(HexColor("#FFFFFF"))
        canvas.setFont(self.styles.fonts.heading, 44)
        canvas.drawString(left, self.height - 38 * mm, self.section_number)
        canvas.setFont(self.styles.fonts.heading, 21)
        canvas.drawString(left, self.height - 53 * mm, self.group_name)

        canvas.setFillColor(HexColor("#DCE8FF"))
        range_y = self.height - 65 * mm
        canvas.setFont(self.styles.fonts.body, 10)
        canvas.drawString(left, range_y, "题号")
        range_x = left + canvas.stringWidth("题号", self.styles.fonts.body, 10) + 5
        canvas.setFont(self.styles.fonts.code, 10)
        canvas.drawString(range_x, range_y, self.question_range)
        suffix_x = (
            range_x
            + canvas.stringWidth(
                self.question_range,
                self.styles.fonts.code,
                10,
            )
            + 5
        )
        canvas.setFont(self.styles.fonts.body, 10)
        canvas.drawString(suffix_x, range_y, "| 共 10 道")
        canvas.setFont(self.styles.fonts.body, 8.8)
        canvas.drawString(left, self.height - 75 * mm, "能力关键词")
        canvas.setFont(self.styles.fonts.body, 9.5)
        canvas.drawString(left, self.height - 83 * mm, self.ability_keywords)
        canvas.restoreState()


def _field_palette(
    label: str,
    styles: StyleSet,
) -> tuple[ParagraphStyle, ParagraphStyle, Color, Color]:
    if label == "风险信号":
        return (
            styles.risk_label,
            styles.risk_body,
            styles.danger,
            styles.risk_fill,
        )
    if label == "评分锚点":
        return (
            styles.scoring_label,
            styles.scoring_body,
            styles.score,
            styles.scoring_fill,
        )
    if label in {"问题", "题前材料", "题前材料（盲面提供）"}:
        return (
            styles.field_label,
            styles.prompt,
            styles.accent,
            styles.info_fill,
        )
    return (
        styles.field_label,
        styles.field_body,
        styles.line,
        styles.soft,
    )


@dataclass(frozen=True)
class FieldPanelMetrics:
    label_top: float
    label_bottom: float
    body_top: float
    body_bottom: float

    @property
    def label_height(self) -> float:
        return self.label_bottom - self.label_top

    @property
    def boundary_overlap(self) -> float:
        return max(
            0.0,
            min(self.label_bottom, self.body_bottom)
            - max(self.label_top, self.body_top),
        )


class FieldPanel(Table):
    """Measured label/body container whose body row may split across pages."""

    def __init__(
        self,
        label: str | list,
        body_blocks: Sequence[str] | None = None,
        styles: StyleSet | None = None,
        width: float | None = None,
        **table_kwargs,
    ) -> None:
        if styles is None:
            self.label = ""
            self.body_style = None
            self.border_color = None
            self.fill_color = None
            self.body_vertical_padding = 0.0
            self.metrics = FieldPanelMetrics(0.0, 0.0, 0.0, 0.0)
            self.minimum_start_height = 0.0
            super().__init__(label, **table_kwargs)
            return

        assert isinstance(label, str)
        assert body_blocks is not None
        assert width is not None
        label_style, body_style, border_color, fill_color = _field_palette(
            label,
            styles,
        )
        label_paragraph = Paragraph(
            safe_inline(label, styles.fonts.code),
            label_style,
        )
        blocks = [block for block in body_blocks if block.strip()]
        body_story = [
            Paragraph(
                ("&#8226; " if len(blocks) > 1 else "")
                + safe_inline(
                    block.replace("<br/>", "\n").replace("<br>", "\n"),
                    styles.fonts.code,
                ),
                body_style,
            )
            for block in blocks
        ]
        if not body_story:
            body_story = [Paragraph("—", body_style)]

        self.label = label
        self.body_style = body_style
        self.border_color = border_color
        self.fill_color = fill_color
        self.body_vertical_padding = 2 * FIELD_BODY_VERTICAL_PADDING
        self.metrics = FieldPanelMetrics(0.0, 0.0, 0.0, 0.0)
        self.minimum_start_height = 0.0

        super().__init__(
            [[label_paragraph], [body_story]],
            colWidths=[width],
            splitByRow=1,
            splitInRow=1,
            hAlign="LEFT",
            style=TableStyle(
                [
                    ("BACKGROUND", (0, 0), (0, 0), styles.paper),
                    ("BACKGROUND", (0, 1), (0, 1), fill_color),
                    ("BOX", (0, 0), (-1, -1), 0.65, border_color),
                    ("LINEBELOW", (0, 0), (0, 0), 0.65, border_color),
                    (
                        "LEFTPADDING",
                        (0, 0),
                        (0, 0),
                        FIELD_LABEL_HORIZONTAL_PADDING,
                    ),
                    (
                        "RIGHTPADDING",
                        (0, 0),
                        (0, 0),
                        FIELD_LABEL_HORIZONTAL_PADDING,
                    ),
                    (
                        "TOPPADDING",
                        (0, 0),
                        (0, 0),
                        FIELD_LABEL_VERTICAL_PADDING,
                    ),
                    (
                        "BOTTOMPADDING",
                        (0, 0),
                        (0, 0),
                        FIELD_LABEL_VERTICAL_PADDING,
                    ),
                    (
                        "LEFTPADDING",
                        (0, 1),
                        (0, 1),
                        FIELD_BODY_HORIZONTAL_PADDING,
                    ),
                    (
                        "RIGHTPADDING",
                        (0, 1),
                        (0, 1),
                        FIELD_BODY_HORIZONTAL_PADDING,
                    ),
                    (
                        "TOPPADDING",
                        (0, 1),
                        (0, 1),
                        FIELD_BODY_VERTICAL_PADDING,
                    ),
                    (
                        "BOTTOMPADDING",
                        (0, 1),
                        (0, 1),
                        FIELD_BODY_VERTICAL_PADDING,
                    ),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ]
            ),
        )

    def wrap(self, avail_width: float, avail_height: float) -> tuple[float, float]:
        width, height = super().wrap(avail_width, avail_height)
        if len(self._rowHeights) < 2 or self.body_style is None:
            return width, height
        label_height = float(self._rowHeights[0])
        body_height = float(self._rowHeights[1])
        self.metrics = FieldPanelMetrics(
            label_top=0.0,
            label_bottom=label_height,
            body_top=label_height,
            body_bottom=label_height + body_height,
        )
        body_start = min(
            body_height,
            KEEP_BODY_LINES * self.body_style.leading
            + self.body_vertical_padding,
        )
        self.minimum_start_height = label_height + body_start
        return width, height


def make_field_panel(
    label: str,
    body_blocks: Sequence[str],
    styles: StyleSet,
    width: float,
) -> FieldPanel:
    panel = FieldPanel(label, body_blocks, styles, width)
    panel.wrap(width, A4[1])
    return panel


def field_panel_flowables(
    label: str,
    body_blocks: Sequence[str],
    styles: StyleSet,
    width: float = BODY_WIDTH,
) -> list[Flowable]:
    panel = make_field_panel(label, body_blocks, styles, width)
    return [
        CondPageBreak(panel.minimum_start_height),
        panel,
        Spacer(1, FIELD_PANEL_GAP),
    ]


def compact_pair_flowables(
    left: tuple[str, Sequence[str]],
    right: tuple[str, Sequence[str]],
    styles: StyleSet,
    width: float,
) -> list[Flowable]:
    column_width = (width - COMPACT_FIELD_GAP) / 2
    left_panel = make_field_panel(left[0], left[1], styles, column_width)
    right_panel = make_field_panel(right[0], right[1], styles, column_width)
    left_height = left_panel.wrap(column_width, A4[1])[1]
    right_height = right_panel.wrap(column_width, A4[1])[1]

    if max(left_height, right_height) > COMPACT_FIELD_MAX_HEIGHT:
        return (
            field_panel_flowables(left[0], left[1], styles, width)
            + field_panel_flowables(right[0], right[1], styles, width)
        )

    pair = Table(
        [[left_panel, Spacer(COMPACT_FIELD_GAP, 1), right_panel]],
        colWidths=[column_width, COMPACT_FIELD_GAP, column_width],
        hAlign="LEFT",
        style=TableStyle(
            [
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ]
        ),
    )
    pair._compact_pair = True
    pair.left_panel = left_panel
    pair.right_panel = right_panel
    pair_height = max(left_height, right_height)
    return [
        CondPageBreak(pair_height),
        pair,
        Spacer(1, FIELD_PANEL_GAP),
    ]


@dataclass(frozen=True)
class ExternalFieldMetrics:
    label_to_panel_gap: float
    panel_to_next_label_gap: float


class ExternalFieldBlock(Table):
    """External label plus a measured value panel and bidirectional spacing."""

    def __init__(
        self,
        label: str,
        value: str,
        label_style: ParagraphStyle,
        value_style: ParagraphStyle,
        fill_color: Color,
        border_color: Color,
        width: float,
    ) -> None:
        self.label = label
        self.metrics = ExternalFieldMetrics(0.0, 0.0)
        super().__init__(
            [
                [Paragraph(safe_inline(label, label_style.fontName), label_style)],
                [Spacer(1, EXTERNAL_FIELD_GAP)],
                [Paragraph(safe_inline(value, value_style.fontName), value_style)],
                [Spacer(1, EXTERNAL_FIELD_GAP)],
            ],
            colWidths=[width],
            hAlign="LEFT",
            style=TableStyle(
                [
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                    ("TOPPADDING", (0, 0), (-1, -1), 0),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
                    ("BACKGROUND", (0, 2), (0, 2), fill_color),
                    ("BOX", (0, 2), (0, 2), 0.65, border_color),
                    (
                        "LEFTPADDING",
                        (0, 2),
                        (0, 2),
                        FIELD_BODY_HORIZONTAL_PADDING,
                    ),
                    (
                        "RIGHTPADDING",
                        (0, 2),
                        (0, 2),
                        FIELD_BODY_HORIZONTAL_PADDING,
                    ),
                    (
                        "TOPPADDING",
                        (0, 2),
                        (0, 2),
                        FIELD_BODY_VERTICAL_PADDING,
                    ),
                    (
                        "BOTTOMPADDING",
                        (0, 2),
                        (0, 2),
                        FIELD_BODY_VERTICAL_PADDING,
                    ),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ]
            ),
        )

    def wrap(self, avail_width: float, avail_height: float) -> tuple[float, float]:
        width, height = super().wrap(avail_width, avail_height)
        self.metrics = ExternalFieldMetrics(
            label_to_panel_gap=float(self._rowHeights[1]),
            panel_to_next_label_gap=float(self._rowHeights[3]),
        )
        return width, height


def external_field_flowables(
    label: str,
    value: str,
    label_style: ParagraphStyle,
    value_style: ParagraphStyle,
    fill_color: Color,
    border_color: Color,
    width: float = BODY_WIDTH,
) -> list[Flowable]:
    return [
        ExternalFieldBlock(
            label,
            value,
            label_style,
            value_style,
            fill_color,
            border_color,
            width,
        )
    ]


def interviewer_record_panel(
    styles: StyleSet,
    *,
    available_width: float = BODY_WIDTH,
) -> Table:
    """Compact printable evidence/risk/score record used by every question."""
    title = Paragraph("<b>面试官记录</b>", styles.form_label)
    label = lambda value: Paragraph(value, styles.form_label)
    blank = lambda: Paragraph("　", styles.form_body)
    score_choices = Paragraph(
        "□ 0　　□ 1　　□ 2　　□ 3　　□ 4",
        styles.form_body,
    )
    label_width = 20 * mm
    table = Table(
        [
            [title, ""],
            [label("证据"), blank()],
            [label("风险"), blank()],
            [label("评分"), score_choices],
        ],
        colWidths=[label_width, available_width - label_width],
        rowHeights=[6 * mm, 7 * mm, 7 * mm, 7 * mm],
        hAlign="LEFT",
    )
    table.setStyle(
        TableStyle(
            [
                ("SPAN", (0, 0), (1, 0)),
                ("BOX", (0, 0), (-1, -1), 0.7, styles.primary),
                ("INNERGRID", (0, 1), (-1, -1), 0.35, styles.line),
                ("BACKGROUND", (0, 0), (-1, 0), HexColor("#EEF4FF")),
                ("BACKGROUND", (0, 1), (0, -1), HexColor("#F6F8FA")),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ]
        )
    )
    return table


def question_flowables(question: Question, styles: StyleSet) -> list[Flowable]:
    """Render one question without trapping its long answer fields in a table row."""
    heading = QuestionHeadingFlowable(question, styles)
    flows: list[Flowable] = [KeepTogether([heading])]
    if question.preface:
        flows.extend(
            field_panel_flowables(
                "题前材料（盲面提供）",
                question.preface,
                styles,
            )
        )
    flows.extend(
        field_panel_flowables(
            "问题",
            [question.prompt],
            styles,
        )
    )

    project_context = question.answer_fields.get(PROJECT_CONTEXT_LABEL, ())
    if project_context:
        flows.extend(
            field_panel_flowables(
                PROJECT_CONTEXT_LABEL,
                project_context,
                styles,
            )
        )

    labels = [
        *FIELD_ORDER,
        *(
            label
            for label in question.answer_fields
            if label
            not in (
                *FIELD_ORDER,
                PROJECT_CONTEXT_LABEL,
                REFERENCE_LABEL,
            )
        ),
    ]
    skipped: set[str] = set()
    for label in labels:
        if label in skipped:
            continue
        values = question.answer_fields.get(label, ())
        if label == "追问":
            risk_values = question.answer_fields.get("风险信号", ())
            if values and risk_values:
                flows.extend(
                    compact_pair_flowables(
                        ("追问", values),
                        ("风险信号", risk_values),
                        styles,
                        BODY_WIDTH,
                    )
                )
                skipped.add("风险信号")
                continue
        flows.extend(field_panel_flowables(label, values, styles))

    references = question.answer_fields.get(REFERENCE_LABEL, ())
    if references:
        flows.extend(field_panel_flowables(REFERENCE_LABEL, references, styles))

    flows.extend(
        [
            CondPageBreak(31 * mm),
            interviewer_record_panel(styles),
            Spacer(1, 3 * mm),
        ]
    )
    return flows


def _column_widths(rows: tuple[tuple[str, ...], ...], available_width: float) -> list[float]:
    column_count = max(len(row) for row in rows)
    weights: list[float] = []
    for column in range(column_count):
        longest = max((len(row[column]) if column < len(row) else 0) for row in rows)
        weights.append(min(4.2, max(1.0, longest / 8)))
    total = sum(weights)
    return [available_width * weight / total for weight in weights]


def _styled_table(rows: tuple[tuple[str, ...], ...], styles: StyleSet, width: float) -> Table:
    column_count = max(len(row) for row in rows)
    normalized = tuple(row + ("",) * (column_count - len(row)) for row in rows)
    data = [
        [
            Paragraph(
                safe_inline(cell, styles.fonts.code),
                styles.table_header if row_index == 0 else styles.table_body,
            )
            for cell in row
        ]
        for row_index, row in enumerate(normalized)
    ]
    table = Table(
        data,
        colWidths=_column_widths(normalized, width),
        repeatRows=1,
        hAlign="LEFT",
    )
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), styles.primary),
                ("TEXTCOLOR", (0, 0), (-1, 0), HexColor("#FFFFFF")),
                ("GRID", (0, 0), (-1, -1), 0.45, styles.line),
                ("BACKGROUND", (0, 1), (-1, -1), HexColor("#FFFFFF")),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [HexColor("#FFFFFF"), HexColor("#F6F8FA")]),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    return table


def table_flowable(
    table: TableBlock,
    styles: StyleSet,
    *,
    available_width: float = BODY_WIDTH,
) -> Flowable:
    """Build a repeat-header table; split eight-column role weights into two halves."""
    if not table.rows:
        return Spacer(0, 0)
    column_count = max(len(row) for row in table.rows)
    if column_count != 8:
        return _styled_table(table.rows, styles, available_width)
    left_indices = (0, 1, 2, 3, 4)
    right_indices = (0, 5, 6, 7)
    left = tuple(tuple(row[index] if index < len(row) else "" for index in left_indices) for row in table.rows)
    right = tuple(tuple(row[index] if index < len(row) else "" for index in right_indices) for row in table.rows)
    return KeepTogether(
        [
            _styled_table(left, styles, available_width),
            Spacer(1, 4 * mm),
            _styled_table(right, styles, available_width),
        ]
    )


def _record_row(line: str, styles: StyleSet) -> tuple[Paragraph, Paragraph]:
    label, separator, value = line.partition("：")
    if not separator:
        return Paragraph("", styles.form_label), Paragraph(safe_inline(line, styles.fonts.code), styles.form_body)
    label_text = safe_inline(label + "：", styles.fonts.code)
    stripped = value.strip()
    if not stripped:
        rendered_value = "____________________________________________"
    elif "/" in stripped:
        choices = [part.strip().replace("[ ]", "").strip() for part in stripped.split("/")]
        rendered_value = "　".join(f"&#9633; {safe_inline(choice, styles.fonts.code)}" for choice in choices)
    else:
        rendered_value = safe_inline(stripped, styles.fonts.code)
        if "____" in stripped:
            rendered_value += "________________"
    return Paragraph(label_text, styles.form_label), Paragraph(rendered_value, styles.form_body)


def interview_record_flowable(
    code: CodeBlock,
    styles: StyleSet,
    *,
    available_width: float = BODY_WIDTH,
) -> Table:
    """Turn the source interview-record code block into a paper-friendly form."""
    rows: list[list[Paragraph]] = []
    for raw_line in code.code.splitlines():
        line = raw_line.strip()
        if not line:
            rows.append([Paragraph("　", styles.form_body), Paragraph("", styles.form_body)])
        elif line == "-":
            rows.append(
                [
                    Paragraph("", styles.form_label),
                    Paragraph("____________________________________________", styles.form_body),
                ]
            )
        else:
            rows.append(list(_record_row(line, styles)))
    label_width = min(36 * mm, available_width * 0.3)
    table = Table(
        rows,
        colWidths=[label_width, available_width - label_width],
        hAlign="LEFT",
    )
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.8, styles.primary),
                ("INNERGRID", (0, 0), (-1, -1), 0.35, styles.line),
                ("BACKGROUND", (0, 0), (0, -1), HexColor("#EEF4FF")),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    return table
