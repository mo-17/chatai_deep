from __future__ import annotations

from io import BytesIO
from pathlib import Path
from tempfile import TemporaryDirectory
from types import MappingProxyType
import unittest
from unittest.mock import patch

from pypdf import PdfReader
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfgen.canvas import Canvas
from reportlab.platypus import (
    KeepTogether,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
)

from interview_question_bank.components import (
    interview_record_flowable,
    question_flowables,
    table_flowable,
)
import interview_question_bank.components as component_module
from interview_question_bank.parser import CodeBlock, Question, TableBlock
from interview_question_bank.styles import (
    BLUE,
    DARK_NAVY,
    NAVY,
    RISK,
    SCORE,
    SCORE_FILL,
    SKY,
    build_styles,
    register_fonts,
    safe_inline,
)
import interview_question_bank.styles as style_tokens


BODY_WIDTH = A4[0] - 40 * mm


def sample_question(*, long_answer: bool = False) -> Question:
    answer = "用 `idempotency_key` 保证幂等，并记录可审计状态。"
    if long_answer:
        answer = " ".join([answer] * 220) + " LONG-ANSWER-END"
    return Question(
        question_id="C1",
        title="系统边界与目标",
        prompt="如何把 <需求> 转换为可验证的系统边界？",
        preface=("题前材料：请先阅读 `README.md`。",),
        answer_fields=MappingProxyType(
            {
                "考察点": ("边界识别、约束澄清。",),
                "答案要点": (answer,),
                "追问": ("失败路径如何处理？",),
                "风险信号": ("只讲 happy path，不谈回滚。",),
                "评分锚点": ("1 分：空泛；3 分：可执行；5 分：有证据链。",),
            }
        ),
    )


def nested_flowables(flowable):
    yield flowable
    if isinstance(flowable, Table):
        for row in flowable._cellvalues:
            for cell in row:
                if isinstance(cell, (list, tuple)):
                    for child in cell:
                        yield from nested_flowables(child)
                elif not isinstance(cell, str):
                    yield from nested_flowables(cell)
    for attribute in ("_content", "_flowables"):
        for child in getattr(flowable, attribute, ()):
            yield from nested_flowables(child)


def flowable_text(flowable) -> str:
    if isinstance(flowable, (list, tuple)):
        return "\n".join(flowable_text(child) for child in flowable)
    if isinstance(flowable, Paragraph):
        return flowable.getPlainText()
    if isinstance(flowable, Table):
        return "\n".join(
            flowable_text(cell) if not isinstance(cell, str) else cell
            for row in flowable._cellvalues
            for cell in row
        )
    return "\n".join(
        flowable_text(child)
        for child in nested_flowables(flowable)
        if child is not flowable
    )


def wrap_flowable(flowable) -> tuple[float, float]:
    return flowable.wrapOn(Canvas(BytesIO(), pagesize=A4), BODY_WIDTH, A4[1])


def build_component_pdf(flowables) -> bytes:
    target = BytesIO()
    doc = SimpleDocTemplate(
        target,
        pagesize=A4,
        leftMargin=20 * mm,
        rightMargin=20 * mm,
        topMargin=18 * mm,
        bottomMargin=17 * mm,
    )
    doc.build(flowables)
    return target.getvalue()


class BlueprintStyleContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fonts = register_fonts()

    def test_approved_blueprint_tokens(self) -> None:
        self.assertEqual(DARK_NAVY, HexColor("#0D263E"))
        self.assertEqual(NAVY, HexColor("#163A5F"))
        self.assertEqual(BLUE, HexColor("#2F6FED"))
        self.assertEqual(SKY, HexColor("#62ADFF"))
        self.assertEqual(SCORE, HexColor("#1D4ED8"))
        self.assertEqual(SCORE_FILL, HexColor("#EFF6FF"))
        self.assertEqual(build_styles(self.fonts).risk_body.textColor, RISK)

    def test_score_styles_are_blue_not_green(self) -> None:
        styles = build_styles(self.fonts)
        self.assertEqual(styles.scoring_label.textColor, SCORE)
        self.assertEqual(styles.scoring_body.textColor, SCORE)
        self.assertEqual(styles.scoring_fill, SCORE_FILL)
        self.assertIsNone(styles.scoring_body.backColor)

    def test_reading_sizes_are_not_reduced(self) -> None:
        styles = build_styles(self.fonts)
        self.assertEqual(styles.question_heading.fontSize, 15)
        self.assertEqual(styles.question_heading.leading, 20)
        self.assertEqual(styles.prompt.fontSize, 10.2)
        self.assertEqual(styles.prompt.leading, 16)
        self.assertGreaterEqual(styles.field_body.fontSize, 9.2)
        self.assertGreaterEqual(styles.table_body.fontSize, 7.8)


class ComponentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fonts = register_fonts()
        cls.styles = build_styles(cls.fonts)

    def test_font_registration_provides_verified_chinese_fonts(self) -> None:
        self.assertIn(self.fonts.body, pdfmetrics.getRegisteredFontNames())
        self.assertIn(self.fonts.heading, pdfmetrics.getRegisteredFontNames())
        self.assertIn(self.fonts.code, pdfmetrics.getRegisteredFontNames())
        self.assertNotEqual(self.fonts.body, self.fonts.heading)
        self.assertNotEqual(self.fonts.body, self.fonts.code)
        self.assertNotEqual(self.fonts.heading, self.fonts.code)
        self.assertNotIn("Black", getattr(self.fonts, "body_postscript_name", ""))
        self.assertRegex(
            getattr(self.fonts, "heading_postscript_name", ""),
            r"(?:Medium|Bold|Black)",
        )
        self.assertRegex(
            getattr(self.fonts, "code_postscript_name", ""),
            r"(?:Menlo|Mono|Courier)",
        )

    def test_font_registration_uses_inspected_nonzero_cjk_subfonts(self) -> None:
        self.assertEqual(1, getattr(self.fonts, "body_subfont_index", None))
        self.assertEqual(1, getattr(self.fonts, "heading_subfont_index", None))
        self.assertIn("Light", getattr(self.fonts, "body_postscript_name", ""))
        self.assertIn("Medium", getattr(self.fonts, "heading_postscript_name", ""))

    def test_font_registration_fails_closed_without_an_embeddable_font(self) -> None:
        missing = Path("/missing/embedded-chinese-font.ttf")
        with patch.object(
            style_tokens,
            "BODY_FONT_CANDIDATES",
            (("MissingBodyForTest", missing, 0, "missing"),),
            create=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "No embeddable Chinese font"):
                register_fonts()

    def test_safe_inline_escapes_html_and_preserves_code_span(self) -> None:
        rendered = safe_inline("比较 <tag> 与 `idempotency_key`", self.fonts.code)
        self.assertIn("&lt;tag&gt;", rendered)
        self.assertNotIn("<tag>", rendered)
        self.assertIn(f'<font name="{self.fonts.code}"', rendered)
        self.assertIn("idempotency_key", rendered)

    def test_safe_inline_prints_reference_label_and_normalized_repository_path(self) -> None:
        rendered = safe_inline(
            "[`mcp.controller.ts`](../chatgpt_backend/src/mcp/mcp.controller.ts)",
            self.fonts.code,
        )
        plain = Paragraph(rendered, self.styles.field_body).getPlainText()

        self.assertEqual(
            "mcp.controller.ts · chatgpt_backend/src/mcp/mcp.controller.ts",
            plain,
        )
        self.assertNotIn("../", rendered)
        self.assertNotIn("](", rendered)
        self.assertNotIn("href=", rendered)
        self.assertGreaterEqual(rendered.count(f'<font name="{self.fonts.code}"'), 2)

    def test_question_components_cover_required_labels(self) -> None:
        flows = question_flowables(sample_question(), self.styles)
        text = "\n".join(flowable_text(flow) for flow in flows)
        for label in ("问题", "考察点", "答案要点", "追问", "风险信号", "评分锚点"):
            self.assertIn(label, text)
        self.assertIsInstance(flows[0], KeepTogether)
        self.assertIn("C1", flowable_text(flows[0]))
        self.assertIn("如何把", text)

    def test_question_panel_has_structured_evidence_risk_and_score_choices(self) -> None:
        flows = question_flowables(sample_question(), self.styles)
        panels = [
            item
            for flow in flows
            for item in nested_flowables(flow)
            if isinstance(item, Table) and "面试官记录" in flowable_text(item)
        ]

        self.assertEqual(1, len(panels))
        text = flowable_text(panels[0])
        for label in ("证据", "风险", "评分"):
            self.assertIn(label, text)
        for score in range(5):
            self.assertRegex(text, rf"(?:^|\s){score}(?:\s|$)")
        width, height = wrap_flowable(panels[0])
        self.assertLessEqual(width, BODY_WIDTH + 0.01)
        self.assertGreaterEqual(height, 14 * mm)
        self.assertLessEqual(height, 32 * mm)

    def test_optional_fields_follow_the_approved_print_order(self) -> None:
        question = Question(
            question_id="C8",
            title="授权边界",
            prompt="如何证明服务端授权？",
            preface=("先阅读盲面材料。",),
            answer_fields=MappingProxyType(
                {
                    "考察点": ("认证与授权。",),
                    "答案要点": ("服务端验证。",),
                    "项目情景": ("当前 Guard 缺失。",),
                    "追问": ("对象级授权呢？",),
                    "风险信号": ("只隐藏按钮。",),
                    "评分锚点": ("0 到 4 分。",),
                    "参考入口": (
                        "[`auth.controller.ts`](../chatgpt_backend/src/auth/auth.controller.ts)",
                    ),
                }
            ),
        )
        text = "\n".join(flowable_text(flow) for flow in question_flowables(question, self.styles))
        ordered = (
            "题前材料（盲面提供）",
            "问题",
            "项目情景",
            "考察点",
            "答案要点",
            "追问",
            "风险信号",
            "评分锚点",
            "参考入口",
            "面试官记录",
        )

        self.assertTrue(
            all(label in text for label in ordered),
            f"missing ordered labels in: {text}",
        )
        positions = [text.index(label) for label in ordered]
        self.assertEqual(sorted(positions), positions)

    def test_chapter_divider_component_carries_visual_and_content_contract(self) -> None:
        divider_type = getattr(component_module, "ChapterDividerFlowable", None)
        self.assertIsNotNone(divider_type)
        divider = divider_type(
            section_number="03",
            section_title="3. 共享核心题",
            group_name="共享核心题",
            question_range="C1 - C10",
            ability_keywords="架构、数据流、安全、可靠性、验证意识。",
            styles=self.styles,
        )

        self.assertEqual("03", divider.section_number)
        self.assertEqual("3. 共享核心题", divider.section_title)
        self.assertEqual("C1 - C10", divider.question_range)
        self.assertIn("验证意识", divider.ability_keywords)
        width, height = wrap_flowable(divider)
        self.assertLessEqual(width, BODY_WIDTH + 0.01)
        self.assertGreaterEqual(height, 70 * mm)

    def test_risk_and_scoring_panels_use_distinct_container_backgrounds(self) -> None:
        panel_type = getattr(component_module, "FieldPanel", None)
        self.assertIsNotNone(panel_type)
        panels = [
            item
            for flow in question_flowables(sample_question(), self.styles)
            for item in nested_flowables(flow)
            if isinstance(item, panel_type)
        ]
        risk = next(panel for panel in panels if panel.label == "风险信号")
        scoring = next(panel for panel in panels if panel.label == "评分锚点")
        self.assertIsNone(risk.body_style.backColor)
        self.assertIsNone(scoring.body_style.backColor)
        self.assertEqual(self.styles.risk_fill, risk.fill_color)
        self.assertEqual(self.styles.scoring_fill, scoring.fill_color)
        self.assertNotEqual(risk.fill_color, scoring.fill_color)

    def test_blind_material_uses_a_blue_information_container(self) -> None:
        panel_type = getattr(component_module, "FieldPanel", None)
        self.assertIsNotNone(panel_type)
        panels = [
            flow
            for flow in question_flowables(sample_question(), self.styles)
            if isinstance(flow, panel_type)
        ]
        preface = next(
            panel
            for panel in panels
            if panel.label == "题前材料（盲面提供）"
        )

        self.assertIsNone(preface.body_style.backColor)
        self.assertEqual(self.styles.info_fill, preface.fill_color)
        self.assertEqual(self.styles.accent, preface.border_color)

    def test_question_flowables_wrap_within_a4_body_width(self) -> None:
        for flow in question_flowables(sample_question(), self.styles):
            width, _ = wrap_flowable(flow)
            self.assertLessEqual(width, BODY_WIDTH + 0.01)

    def test_long_answer_can_split_across_pages(self) -> None:
        with TemporaryDirectory() as directory:
            target = Path(directory) / "long-answer.pdf"
            doc = SimpleDocTemplate(
                str(target),
                pagesize=A4,
                leftMargin=18 * mm,
                rightMargin=18 * mm,
                topMargin=18 * mm,
                bottomMargin=18 * mm,
            )
            doc.build(question_flowables(sample_question(long_answer=True), self.styles))
            reader = PdfReader(target)
            self.assertGreater(len(reader.pages), 1)
            self.assertIn("LONG-ANSWER-END", "\n".join(page.extract_text() or "" for page in reader.pages))

    def test_long_answer_begins_on_opening_page_when_space_remains(self) -> None:
        with TemporaryDirectory() as directory:
            target = Path(directory) / "opening-page-answer.pdf"
            doc = SimpleDocTemplate(
                str(target),
                pagesize=A4,
                leftMargin=18 * mm,
                rightMargin=18 * mm,
                topMargin=18 * mm,
                bottomMargin=18 * mm,
            )
            doc.build(question_flowables(sample_question(long_answer=True), self.styles))
            opening_page = PdfReader(target).pages[0].extract_text() or ""
            self.assertIn("答案要点", opening_page)
            self.assertIn("用 idempotency_key", opening_page)

    def test_field_label_moves_to_next_page_when_less_than_guard_space_remains(self) -> None:
        with TemporaryDirectory() as directory:
            target = Path(directory) / "field-boundary.pdf"
            doc = SimpleDocTemplate(
                str(target),
                pagesize=A4,
                leftMargin=18 * mm,
                rightMargin=18 * mm,
                topMargin=18 * mm,
                bottomMargin=18 * mm,
            )
            field_flows = question_flowables(sample_question(), self.styles)[1:]
            panel_type = getattr(component_module, "FieldPanel")
            first_panel = next(
                flowable
                for flowable in field_flows
                if isinstance(flowable, panel_type)
            )
            doc.build(
                [
                    Spacer(1, doc.height - first_panel.minimum_start_height + 1),
                    *field_flows,
                ]
            )
            pages = PdfReader(target).pages
            self.assertGreater(len(pages), 1)
            self.assertNotIn("考察点", pages[0].extract_text() or "")
            self.assertIn("考察点", pages[1].extract_text() or "")

    def test_eight_column_weight_table_is_split_into_two_readable_tables(self) -> None:
        table = TableBlock(
            rows=(
                ("维度", "前端", "AI", "后端", "安全", "产品", "测试", "运维"),
                ("工程能力", "25%", "20%", "25%", "15%", "10%", "20%", "20%"),
            )
        )
        rendered = table_flowable(table, self.styles)
        tables = [item for item in nested_flowables(rendered) if isinstance(item, Table)]
        self.assertEqual(2, len(tables))
        self.assertEqual([5, 4], [len(item._cellvalues[0]) for item in tables])
        self.assertTrue(all(item._cellvalues[0][0].getPlainText() == "维度" for item in tables))
        self.assertTrue(all(item.repeatRows == 1 for item in tables))
        width, _ = wrap_flowable(rendered)
        self.assertLessEqual(width, BODY_WIDTH + 0.01)

    def test_normal_table_repeats_its_header(self) -> None:
        rendered = table_flowable(
            TableBlock(rows=(("维度", "说明", "权重"), ("工程能力", "可交付", "40%"))),
            self.styles,
        )
        self.assertIsInstance(rendered, Table)
        self.assertEqual(1, rendered.repeatRows)

    def test_interview_code_block_becomes_a_printable_form(self) -> None:
        code = CodeBlock(
            "text",
            "候选人：____\n面试官：____\n综合建议：[ ] 通过 [ ] 待定 [ ] 不通过\n备注：",
        )
        rendered = interview_record_flowable(code, self.styles)
        self.assertIsInstance(rendered, Table)
        text = flowable_text(rendered)
        for label in ("候选人", "面试官", "综合建议", "通过", "待定", "不通过", "备注"):
            self.assertIn(label, text)
        self.assertIn("________________", text)
        width, _ = wrap_flowable(rendered)
        self.assertLessEqual(width, BODY_WIDTH + 0.01)


class FieldPanelGeometryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fonts = register_fonts()
        cls.styles = build_styles(cls.fonts)

    def _component(self, name: str):
        value = getattr(component_module, name, None)
        self.assertIsNotNone(value, f"{name} must be implemented")
        return value

    def test_label_and_body_share_boundary_without_overlap(self) -> None:
        make_field_panel = self._component("make_field_panel")
        panel = make_field_panel(
            "答案要点",
            ["第一行答案。", "第二行答案。"],
            self.styles,
            BODY_WIDTH,
        )
        panel.wrap(BODY_WIDTH, A4[1])
        self.assertEqual(panel.metrics.boundary_overlap, 0)
        self.assertEqual(panel.metrics.label_bottom, panel.metrics.body_top)

    def test_adjacent_field_gap_is_at_least_four_points(self) -> None:
        field_panel_flowables = self._component("field_panel_flowables")
        flowables = field_panel_flowables(
            "考察点",
            ["系统设计与证据链。"],
            self.styles,
            BODY_WIDTH,
        )
        self.assertIsInstance(flowables[-1], Spacer)
        self.assertGreaterEqual(flowables[-1].height, 4)

    def test_keep_block_includes_label_and_two_body_lines(self) -> None:
        make_field_panel = self._component("make_field_panel")
        panel = make_field_panel(
            "答案要点",
            ["第一行。<br/>第二行。<br/>第三行。"],
            self.styles,
            BODY_WIDTH,
        )
        panel.wrap(BODY_WIDTH, A4[1])
        expected_floor = (
            panel.metrics.label_height
            + 2 * self.styles.field_body.leading
            + panel.body_vertical_padding
        )
        self.assertGreaterEqual(panel.minimum_start_height, expected_floor)

    def test_all_question_fields_use_split_safe_panels(self) -> None:
        panel_type = self._component("FieldPanel")
        flows = question_flowables(sample_question(), self.styles)
        panels = [flow for flow in flows if isinstance(flow, panel_type)]
        labels = [panel.label for panel in panels]
        self.assertEqual(
            [
                "题前材料（盲面提供）",
                "问题",
                "考察点",
                "答案要点",
                "评分锚点",
            ],
            labels,
        )
        pair = next(
            flow
            for flow in flows
            if getattr(flow, "_compact_pair", False)
        )
        self.assertEqual(
            ["追问", "风险信号"],
            [pair.left_panel.label, pair.right_panel.label],
        )

    def test_short_followup_and_risk_have_real_eight_point_gap(self) -> None:
        compact_pair_flowables = self._component("compact_pair_flowables")
        flowables = compact_pair_flowables(
            ("追问", ["请给出验证证据。"]),
            ("风险信号", ["只给结论，不给证据。"]),
            self.styles,
            BODY_WIDTH,
        )
        pair = flowables[1]
        self.assertTrue(getattr(pair, "_compact_pair", False))
        pair.wrap(BODY_WIDTH, A4[1])
        column_width = (BODY_WIDTH - 8) / 2
        self.assertEqual(3, len(pair._colWidths))
        self.assertAlmostEqual(column_width, pair._colWidths[0])
        self.assertAlmostEqual(8, pair._colWidths[1])
        self.assertAlmostEqual(column_width, pair._colWidths[2])

    def test_long_compact_candidate_falls_back_to_full_width_stack(self) -> None:
        compact_pair_flowables = self._component("compact_pair_flowables")
        long_risk = "风险描述。" * 180
        flowables = compact_pair_flowables(
            ("追问", ["请给出验证证据。"]),
            ("风险信号", [long_risk]),
            self.styles,
            BODY_WIDTH,
        )
        self.assertFalse(
            any(getattr(flowable, "_compact_pair", False) for flowable in flowables)
        )

    def test_external_field_has_three_point_gaps_in_both_directions(self) -> None:
        block_type = self._component("ExternalFieldBlock")
        block = block_type(
            "文档性质",
            "内部面试材料，仅用于高级岗位能力评估。",
            self.styles.field_label,
            self.styles.field_body,
            self.styles.soft,
            self.styles.line,
            BODY_WIDTH,
        )
        block.wrap(BODY_WIDTH, A4[1])
        self.assertGreaterEqual(block.metrics.label_to_panel_gap, 3)
        self.assertGreaterEqual(block.metrics.panel_to_next_label_gap, 3)

    def test_long_field_splits_without_losing_end_sentinel(self) -> None:
        field_panel_flowables = self._component("field_panel_flowables")
        long_answer = ("跨页答案内容。" * 900) + " LONG-ANSWER-END"
        pdf_bytes = build_component_pdf(
            field_panel_flowables(
                "答案要点",
                [long_answer],
                self.styles,
                BODY_WIDTH,
            )
        )
        reader = PdfReader(BytesIO(pdf_bytes))
        extracted = "\n".join(page.extract_text() or "" for page in reader.pages)
        self.assertGreater(len(reader.pages), 1)
        self.assertEqual(extracted.count("LONG-ANSWER-END"), 1)


if __name__ == "__main__":
    unittest.main()
