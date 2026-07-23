"""Splittable ReportLab components for the interview handbook."""

from __future__ import annotations

import re

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.platypus import CondPageBreak, Flowable, KeepTogether, Paragraph, Spacer, Table, TableStyle

from interview_question_bank.parser import CodeBlock, Question, TableBlock
from interview_question_bank.styles import StyleSet, safe_inline


BODY_WIDTH = A4[0] - 40 * mm
FIELD_ORDER = ("考察点", "答案要点", "追问", "风险信号", "评分锚点")
PROJECT_CONTEXT_LABEL = "项目情景"
REFERENCE_LABEL = "参考入口"
FIELD_START_HEIGHT = 22 * mm


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


def _field_styles(label: str, styles: StyleSet):
    if label == "风险信号":
        return styles.risk_label, styles.risk_body
    if label == "评分锚点":
        return styles.scoring_label, styles.scoring_body
    return styles.field_label, styles.field_body


def _field_flowables(
    label: str,
    values: tuple[str, ...],
    styles: StyleSet,
) -> list[Flowable]:
    label_style, body_style = _field_styles(label, styles)
    flows: list[Flowable] = [
        CondPageBreak(FIELD_START_HEIGHT),
        Paragraph(safe_inline(label, styles.fonts.code), label_style),
    ]
    if values:
        for value in values:
            prefix = "&#8226; " if len(values) > 1 else ""
            flows.append(
                Paragraph(
                    prefix + safe_inline(value, styles.fonts.code),
                    body_style,
                )
            )
    else:
        flows.append(Paragraph("　", body_style))
    return flows


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
    top: list[Flowable] = [heading]
    if question.preface:
        top.append(
            Paragraph(
                "<b>题前材料（盲面提供）</b><br/>"
                + "<br/>".join(safe_inline(item, styles.fonts.code) for item in question.preface),
                styles.preface,
            )
        )
    top.append(
        Paragraph(
            "<b>问题</b><br/>" + safe_inline(question.prompt, styles.fonts.code),
            styles.prompt,
        )
    )
    flows: list[Flowable] = [KeepTogether(top)]

    project_context = question.answer_fields.get(PROJECT_CONTEXT_LABEL, ())
    if project_context:
        flows.extend(_field_flowables(PROJECT_CONTEXT_LABEL, project_context, styles))

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
    for label in labels:
        values = question.answer_fields.get(label, ())
        flows.extend(_field_flowables(label, values, styles))

    references = question.answer_fields.get(REFERENCE_LABEL, ())
    if references:
        flows.extend(_field_flowables(REFERENCE_LABEL, references, styles))

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
