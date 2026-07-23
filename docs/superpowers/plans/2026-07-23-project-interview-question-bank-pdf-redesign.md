# 艾普项目高级岗位面试题库 PDF Blueprint 重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 在不改动 `docs/project-interview-question-bank.md` 内容的前提下，把现有 80 题 PDF 重设计为已批准的“工程蓝图 Blueprint”面试官手册，彻底消除标签文字被背景框遮挡的问题，并通过内容、分页、几何和逐页视觉验收。

**Architecture:** 保留现有 `Markdown -> parser -> components -> ReportLab document -> verify -> atomic publish` 管线。`styles.py` 只定义字体与视觉令牌，`components.py` 提供可测量且可跨页拆分的 Flowable，`document.py` 管理 PageTemplate、题目起始页和续页状态，`verify.py` 独立验证正式 PDF，新增 `visual_review.py` 负责用 Poppler 生成本轮专属逐页渲染和联系表。

**Tech Stack:** Python 3.12、ReportLab 4.4.9、PyMuPDF、pypdf、Pillow、Poppler (`pdftoppm` / `pdfinfo`)、`unittest`。

**Global Constraints:**

- 已批准设计规范是唯一视觉与验收依据：`docs/superpowers/specs/2026-07-23-project-interview-question-bank-pdf-design.md`。
- 不修改源题库、README、Flutter、Backend、Admin 或用户的其他工作树改动。
- 只修改 `tmp/pdfs/interview_question_bank/`、正式 PDF 和必要的 PDF 文档。
- 中文标题使用可嵌入的 STHeiti Medium，中文正文使用可嵌入的 STHeiti Light，技术标签使用 Menlo；中文字形不可用时构建必须失败。
- 每道题的首页必须从新页开始；长题可自然续页；下一题仍从新页开始。
- 标签和正文起始两行必须同页；不得通过缩小全局字号解决分页。
- 最终 PDF 必须先写入临时文件，完成验证后原子替换，权限保持 `0644`。
- 所有本轮视觉证据写入新的 `tmp/pdfs/rendered-blueprint/` 与 `tmp/pdfs/contact-sheets-blueprint/`，不得复用旧 PNG。
- 每个代码任务先写失败测试，再实现，再运行聚焦测试；任务结束后提交一个可回退的检查点。

---

## File map

### Modify

- `tmp/pdfs/interview_question_bank/styles.py`
  - Blueprint 色彩令牌、字体角色和面板样式。
- `tmp/pdfs/interview_question_bank/components.py`
  - 集成标签字段、外置标签字段、短块双列、章节内容层和题目标题。
- `tmp/pdfs/interview_question_bank/document.py`
  - Cover / Chapter / Body PageTemplate、蓝图背景、题目分页和续页页眉。
- `tmp/pdfs/interview_question_bank/build.py`
  - 原子发布和可追溯构建回执。
- `tmp/pdfs/interview_question_bank/verify.py`
  - metadata、内容、题号、最长答案、参考路径、页码、权限和几何验证。
- `tmp/pdfs/interview_question_bank/test_components.py`
  - 字段边界、净距、拆分页和哨兵回归测试。
- `tmp/pdfs/interview_question_bank/test_document.py`
  - PageTemplate、每题新页、续页页眉、章节装饰和页脚安全区测试。
- `tmp/pdfs/interview_question_bank/test_verify.py`
  - 正式验证合同的正反例。

### Create

- `tmp/pdfs/interview_question_bank/visual_review.py`
  - Poppler 144 DPI 渲染、联系表和可疑页筛查。
- `tmp/pdfs/interview_question_bank/test_visual_review.py`
  - 渲染隔离、页数一致性和联系表覆盖测试。

### Generated artifacts

- `output/pdf/aipu-senior-role-interview-question-bank.pdf`
- `tmp/pdfs/build-receipt.json`
- `tmp/pdfs/verification-report.json`
- `tmp/pdfs/render-screening-blueprint.json`
- `tmp/pdfs/rendered-blueprint/page-*.png`
- `tmp/pdfs/contact-sheets-blueprint/contact-*.png`
- `tmp/pdfs/grayscale-blueprint/cover.png`
- `tmp/pdfs/grayscale-blueprint/chapter.png`
- `tmp/pdfs/grayscale-blueprint/dense-body.png`

### Must remain unchanged

- `docs/project-interview-question-bank.md`
- `README.md`
- `login_sdk/test/support/`
- 除上述 PDF 路径之外的全部产品代码和用户文件。

---

## Task 1: Lock the approved visual tokens and font contract

**Files:**

- Modify: `tmp/pdfs/interview_question_bank/styles.py`
- Test: `tmp/pdfs/interview_question_bank/test_components.py`

**Interfaces:**

- `build_styles() -> StyleSet`
- `StyleSet.dark_navy`
- `StyleSet.primary`
- `StyleSet.accent`
- `StyleSet.sky`
- `StyleSet.danger`
- `StyleSet.score`
- `StyleSet.paper`
- `StyleSet.soft`
- `StyleSet.info_fill`
- `StyleSet.line`
- `StyleSet.risk_fill`
- `StyleSet.scoring_fill`

- [ ] **Step 1: Record the current baseline**

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_components \
  interview_question_bank.test_document \
  interview_question_bank.test_verify
```

Expected: existing suite passes before redesign. If it does not, record the exact pre-existing failure and stop this task before editing.

- [ ] **Step 2: Add failing token and typography tests**

Add exact assertions for the approved tokens:

```python
from reportlab.lib.colors import HexColor

from interview_question_bank.styles import (
    BLUE,
    DARK_NAVY,
    NAVY,
    SCORE,
    SCORE_FILL,
    SKY,
    build_styles,
)


class BlueprintStyleContractTest(unittest.TestCase):
    def test_approved_blueprint_tokens(self) -> None:
        self.assertEqual(DARK_NAVY, HexColor("#0D263E"))
        self.assertEqual(NAVY, HexColor("#163A5F"))
        self.assertEqual(BLUE, HexColor("#2F6FED"))
        self.assertEqual(SKY, HexColor("#62ADFF"))
        self.assertEqual(SCORE, HexColor("#1D4ED8"))
        self.assertEqual(SCORE_FILL, HexColor("#EFF6FF"))

    def test_score_styles_are_blue_not_green(self) -> None:
        styles = build_styles()
        self.assertEqual(styles.scoring_label.textColor, SCORE)
        self.assertEqual(styles.scoring_body.textColor, SCORE)
        self.assertEqual(styles.scoring_fill, SCORE_FILL)
        self.assertIsNone(styles.scoring_body.backColor)

    def test_reading_sizes_are_not_reduced(self) -> None:
        styles = build_styles()
        self.assertEqual(styles.question_heading.fontSize, 15)
        self.assertEqual(styles.question_heading.leading, 20)
        self.assertEqual(styles.prompt.fontSize, 10.2)
        self.assertEqual(styles.prompt.leading, 16)
        self.assertGreaterEqual(styles.body.fontSize, 9.2)
        self.assertGreaterEqual(styles.table_body.fontSize, 7.8)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_components.BlueprintStyleContractTest
```

Expected: FAIL because `DARK_NAVY`, `SKY`, `SCORE` and the blue score style do not yet exist.

- [ ] **Step 3: Implement the approved immutable tokens**

Replace the old green score semantics and extend `StyleSet` with these exact values:

```python
DARK_NAVY = HexColor("#0D263E")
NAVY = HexColor("#163A5F")
BLUE = HexColor("#2F6FED")
SKY = HexColor("#62ADFF")
INK = HexColor("#172B3A")
MUTED = HexColor("#536575")
LINE = HexColor("#D6DEE6")
PAPER = HexColor("#FFFFFF")
SOFT = HexColor("#F6F8FA")
RISK = HexColor("#B42318")
RISK_FILL = HexColor("#FEF3F2")
SCORE = HexColor("#1D4ED8")
SCORE_FILL = HexColor("#EFF6FF")
INFO_FILL = HexColor("#EEF4FF")
```

Extend `StyleSet` with `dark_navy`, `sky`, `score`, `paper`, `soft`, `info_fill`, `line`, `risk_fill` and `scoring_fill`. Use `SCORE` for the score paragraph text and expose `SCORE_FILL` as `scoring_fill`; the paragraph itself must have `backColor=None` because Task 2 moves the painted background into the measured parent cell. Keep these approved reading sizes:

```python
question_heading.fontSize = 15
question_heading.leading = 20
prompt.fontSize = 10.2
prompt.leading = 16
body.fontSize = 9.2
body.leading = 15
table_body.fontSize = 7.8
table_body.leading = 11
```

Do not retain `SUCCESS` as an alternate score color. Update all `StyleSet` construction and component references to the `score` field so there is one semantic source.

- [ ] **Step 4: Run focused and complete style regressions**

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_components.BlueprintStyleContractTest \
  interview_question_bank.test_components
```

Expected: PASS. Existing Chinese font embedding tests also remain green.

- [ ] **Step 5: Commit the visual-token checkpoint**

```bash
git add -f \
  tmp/pdfs/interview_question_bank/styles.py \
  tmp/pdfs/interview_question_bank/test_components.py
git commit -m "feat(pdf): lock blueprint visual tokens"
```

---

## Task 2: Replace overlapping paragraphs with split-safe field components

**Files:**

- Modify: `tmp/pdfs/interview_question_bank/components.py`
- Modify: `tmp/pdfs/interview_question_bank/test_components.py`

**Interfaces:**

- `FieldPanelMetrics`
- `FieldPanel`
- `make_field_panel(...) -> FieldPanel`
- `field_panel_flowables(...) -> list[Flowable]`
- `compact_pair_flowables(...) -> list[Flowable]`
- `ExternalFieldBlock`
- `external_field_flowables(...) -> list[Flowable]`

- [ ] **Step 1: Add failing integrated-field geometry tests**

Add tests that construct the real component at `BODY_WIDTH` and inspect its measured rows:

```python
class FieldPanelGeometryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.styles = build_styles()

    def test_label_and_body_share_boundary_without_overlap(self) -> None:
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
        flowables = field_panel_flowables(
            "考察点",
            ["系统设计与证据链。"],
            self.styles,
            BODY_WIDTH,
        )
        self.assertIsInstance(flowables[-1], Spacer)
        self.assertGreaterEqual(flowables[-1].height, 4)

    def test_keep_block_includes_label_and_two_body_lines(self) -> None:
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
```

Add an external-label reverse-gap regression:

```python
def test_external_field_has_three_point_gaps_in_both_directions(self) -> None:
    styles = build_styles()
    block = ExternalFieldBlock(
        "文档性质",
        "内部面试材料，仅用于高级岗位能力评估。",
        styles.field_label,
        styles.field_body,
        styles.soft,
        styles.line,
        BODY_WIDTH,
    )
    block.wrap(BODY_WIDTH, A4[1])
    self.assertGreaterEqual(block.metrics.label_to_panel_gap, 3)
    self.assertGreaterEqual(block.metrics.panel_to_next_label_gap, 3)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_components.FieldPanelGeometryTest
```

Expected: FAIL because these components and metrics do not yet exist.

- [ ] **Step 2: Implement the measured two-row `FieldPanel`**

Use one `Table` as the parent boundary. The label and body are separate rows; the body row may split:

```python
FIELD_PANEL_GAP = 4.0
FIELD_LABEL_HORIZONTAL_PADDING = 7.0
FIELD_LABEL_VERTICAL_PADDING = 4.0
FIELD_BODY_HORIZONTAL_PADDING = 7.0
FIELD_BODY_VERTICAL_PADDING = 6.0
KEEP_BODY_LINES = 2
COMPACT_FIELD_GAP = 8.0
COMPACT_FIELD_MAX_HEIGHT = 42 * mm


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
    def __init__(
        self,
        label: str,
        body_blocks: Sequence[str],
        styles: StyleSet,
        width: float,
    ) -> None:
        label_style, body_style, border_color, fill_color = _field_palette(
            label,
            styles,
        )
        label_paragraph = Paragraph(safe_inline(label), label_style)
        body_story = [
            Paragraph(safe_inline(block), body_style)
            for block in body_blocks
            if block.strip()
        ]
        if not body_story:
            body_story = [Paragraph("—", body_style)]

        self.body_style = body_style
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
```

`_field_palette()` must map all panel types through the same algorithm:

```python
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
    if label in {"问题", "题前材料"}:
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
```

Do not use `ParagraphStyle.backColor` for these field backgrounds; backgrounds and borders belong to the measured `Table` cells.

- [ ] **Step 3: Route every question field through the new panel**

Implement the factory and start-height guard:

```python
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
```

Replace `_field_flowables()` usage for “问题、项目情景、考察点、答案要点、追问、风险信号、评分锚点、参考入口” with `field_panel_flowables()`. Preserve source field order and `safe_inline()` path normalization.

- [ ] **Step 4: Add and implement the short-block pair/stack test**

Add:

```python
def test_short_followup_and_risk_can_share_two_columns(self) -> None:
    flowables = compact_pair_flowables(
        ("追问", ["请给出验证证据。"]),
        ("风险信号", ["只给结论，不给证据。"]),
        build_styles(),
        BODY_WIDTH,
    )
    self.assertEqual(getattr(flowables[1], "_compact_pair", False), True)


def test_long_compact_candidate_falls_back_to_full_width_stack(self) -> None:
    long_risk = "风险描述。" * 180
    flowables = compact_pair_flowables(
        ("追问", ["请给出验证证据。"]),
        ("风险信号", [long_risk]),
        build_styles(),
        BODY_WIDTH,
    )
    self.assertFalse(
        any(getattr(flowable, "_compact_pair", False) for flowable in flowables)
    )
```

Implement:

```python
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
        [[left_panel, right_panel]],
        colWidths=[column_width, column_width],
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
    pair_height = pair.wrap(width, A4[1])[1]
    return [
        CondPageBreak(pair_height),
        pair,
        Spacer(1, FIELD_PANEL_GAP),
    ]
```

Use this only for the exact “追问 + 风险信号” pair and only when both blocks are present.

- [ ] **Step 5: Implement the external-label control-page component**

Use spacer rows so both directions are part of the measured component:

```python
EXTERNAL_FIELD_GAP = 3.0


@dataclass(frozen=True)
class ExternalFieldMetrics:
    label_to_panel_gap: float
    panel_to_next_label_gap: float


class ExternalFieldBlock(Table):
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
        self.metrics = ExternalFieldMetrics(0.0, 0.0)
        super().__init__(
            [
                [Paragraph(safe_inline(label), label_style)],
                [Spacer(1, EXTERNAL_FIELD_GAP)],
                [Paragraph(safe_inline(value), value_style)],
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
```

Route the four document-control fields through this component with `ds["control_label"]`, `ds["control_value"]`, `styles.soft`, `styles.line` and `FRAME_WIDTH`. Keep labels outside the value panel. Remove `backColor` and `borderPadding` from the paragraph styles used inside both field component types; their visible backgrounds, borders and padding must be owned only by the measured table cells.

- [ ] **Step 6: Prove long-answer splitting and exact sentinel preservation**

Add a synthetic PDF test with an answer longer than one page and ending in the exact ASCII token:

```python
def test_long_field_splits_without_losing_end_sentinel(self) -> None:
    long_answer = ("跨页答案内容。" * 900) + " LONG-ANSWER-END"
    pdf_bytes = build_component_pdf(
        field_panel_flowables(
            "答案要点",
            [long_answer],
            build_styles(),
            BODY_WIDTH,
        )
    )
    reader = PdfReader(io.BytesIO(pdf_bytes))
    extracted = "\n".join(page.extract_text() or "" for page in reader.pages)
    self.assertGreater(len(reader.pages), 1)
    self.assertEqual(extracted.count("LONG-ANSWER-END"), 1)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_components.FieldPanelGeometryTest \
  interview_question_bank.test_components
```

Expected: PASS; the long field spans pages and contains `LONG-ANSWER-END` exactly once.

- [ ] **Step 7: Commit the anti-overlap component checkpoint**

```bash
git add -f \
  tmp/pdfs/interview_question_bank/components.py \
  tmp/pdfs/interview_question_bank/test_components.py
git commit -m "fix(pdf): make interview fields split safe"
```

---

## Task 3: Build full-page Blueprint cover and chapter templates

**Files:**

- Modify: `tmp/pdfs/interview_question_bank/components.py`
- Modify: `tmp/pdfs/interview_question_bank/document.py`
- Modify: `tmp/pdfs/interview_question_bank/test_document.py`

**Interfaces:**

- `draw_blueprint_background(canvas, doc) -> None`
- PageTemplate ids: `Cover`, `Chapter`, `Body`
- `ChapterDividerFlowable`
- `QuestionHeadingFlowable`

- [ ] **Step 1: Add failing PageTemplate and chapter-page tests**

Add tests that build a minimal document and inspect both template registration and PDF pages:

```python
class BlueprintPageTemplateTest(unittest.TestCase):
    def test_document_registers_cover_chapter_and_body_templates(self) -> None:
        doc = make_test_doc()
        self.assertEqual(
            [template.id for template in doc.pageTemplates],
            ["Cover", "Body", "Chapter"],
        )

    def test_chapter_page_is_a_dedicated_full_page(self) -> None:
        pdf_bytes = build_minimal_bank_pdf()
        pdf = fitz.open(stream=pdf_bytes, filetype="pdf")
        chapter_pages = [
            page
            for page in pdf
            if "UNIFIED SCORE · 0—4" in page.get_text()
        ]
        self.assertEqual(len(chapter_pages), 1)
        self.assertNotIn("答案要点", chapter_pages[0].get_text())
```

Add a render-color assertion using the top-left pixel and a center pixel outside text:

```python
def test_chapter_background_uses_dark_navy(self) -> None:
    page_image = render_chapter_page_at_72_dpi()
    expected = (13, 38, 62)
    dark_start = int(BLUEPRINT_ACCENT_WIDTH) + 8
    for point in ((dark_start, 8), (page_image.width - 8, 8)):
        actual = page_image.getpixel(point)[:3]
        self.assertLessEqual(max(abs(a - b) for a, b in zip(actual, expected)), 4)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_document.BlueprintPageTemplateTest
```

Expected: FAIL because there is no `Chapter` PageTemplate and the current divider is a 92 mm block on a white page.

- [ ] **Step 2: Implement the reusable full-page blueprint background**

Add this page painter in `document.py`:

```python
BLUEPRINT_GRID_STEP = 12 * mm
BLUEPRINT_GRID_ALPHA = 0.10
BLUEPRINT_ACCENT_WIDTH = 11 * mm


def draw_blueprint_background(canvas: Canvas, doc: BaseDocTemplate) -> None:
    page_width, page_height = A4
    canvas.saveState()
    canvas.setFillColor(DARK_NAVY)
    canvas.rect(0, 0, page_width, page_height, stroke=0, fill=1)
    canvas.setFillColor(BLUE)
    canvas.rect(0, 0, BLUEPRINT_ACCENT_WIDTH, page_height, stroke=0, fill=1)

    canvas.setStrokeColor(SKY)
    canvas.setLineWidth(0.35)
    canvas.setStrokeAlpha(BLUEPRINT_GRID_ALPHA)
    x = BLUEPRINT_ACCENT_WIDTH
    while x <= page_width:
        canvas.line(x, 0, x, page_height)
        x += BLUEPRINT_GRID_STEP
    y = 0.0
    while y <= page_height:
        canvas.line(BLUEPRINT_ACCENT_WIDTH, y, page_width, y)
        y += BLUEPRINT_GRID_STEP
    canvas.setStrokeAlpha(1.0)
    canvas.restoreState()
```

The grid is drawn before flowables and never inside `ChapterDividerFlowable`.

- [ ] **Step 3: Register three explicit PageTemplates**

Keep the approved Body Frame dimensions and add a chapter frame:

```python
body_frame = Frame(
    20 * mm,
    17 * mm,
    A4[0] - 40 * mm,
    A4[1] - 35 * mm,
    id="body-frame",
    leftPadding=0,
    rightPadding=0,
    topPadding=0,
    bottomPadding=0,
)
cover_frame = Frame(
    20 * mm,
    20 * mm,
    A4[0] - 40 * mm,
    A4[1] - 40 * mm,
    id="cover-frame",
    leftPadding=0,
    rightPadding=0,
    topPadding=0,
    bottomPadding=0,
)
chapter_frame = Frame(
    20 * mm,
    20 * mm,
    A4[0] - 40 * mm,
    A4[1] - 40 * mm,
    id="chapter-frame",
    leftPadding=0,
    rightPadding=0,
    topPadding=0,
    bottomPadding=0,
)
self.addPageTemplates(
    [
        PageTemplate(
            id="Cover",
            frames=[cover_frame],
            onPage=draw_blueprint_background,
        ),
        PageTemplate(
            id="Body",
            frames=[body_frame],
            onPageEnd=self._draw_body,
        ),
        PageTemplate(
            id="Chapter",
            frames=[chapter_frame],
            onPage=draw_blueprint_background,
        ),
    ]
)
```

Do not draw normal headers or footers on Cover and Chapter pages.

- [ ] **Step 4: Convert chapter divider into a transparent content layer**

`ChapterDividerFlowable` must draw only:

- two-digit section number in `SKY`, 64–72 pt;
- Chinese title in STHeiti Medium, 24/34 pt;
- English technical marker in Menlo;
- ability keywords;
- question range/count;
- `UNIFIED SCORE · 0—4`;
- decoration below metrics with at least 8 pt safety distance.

Its `draw()` must not paint a page-sized or 92 mm dark rectangle. Store metric and decoration rectangles on the instance so the test can calculate:

```python
@property
def decoration_clearance(self) -> float:
    return self.metrics_bottom - self.decoration_top
```

The focused test must assert `decoration_clearance >= 8`.

- [ ] **Step 5: Switch templates deterministically in the story**

Use this exact transition shape:

```python
# Keep the routes page open until the first chapter switch; remove the
# pre-existing trailing PageBreak immediately after the routes loop.
questions_by_prefix = {
    prefix: [
        question
        for question in bank.questions
        if question.question_id.startswith(prefix)
    ]
    for prefix in QUESTION_PREFIXES
}
ability_keywords = _group_ability_keywords(bank)

for group_index, group in enumerate(bank.question_groups):
    prefix = QUESTION_PREFIXES[group_index]
    questions = questions_by_prefix[prefix]
    story.extend(
        [
            NextPageTemplate("Chapter"),
            PageBreak(),
            UnitMarker("level2_section"),
            UnitMarker("question_group_divider"),
            PageContextMarker(group.title, None),
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
            NextPageTemplate("Body"),
        ]
    )
    for question in questions:
        story.append(PageBreak())
        story.append(UnitMarker("question"))
        story.append(PageContextMarker(group.title, question.question_id))
        story.extend(
            question_flowables(_question_for_document(question), styles)
        )
```

The first question’s `PageBreak` closes the Chapter page and activates the Body template. Later question breaks close the preceding question page. The next group’s `NextPageTemplate("Chapter") + PageBreak()` closes the previous group’s final question and opens the next Chapter page, so no double break or blank Body page is introduced. Do not append a trailing `PageBreak` after the final question.

- [ ] **Step 6: Add cover hierarchy and metrics**

The cover content must include exact extractable strings:

```text
艾普项目高级岗位面试题库
高级岗位内部面试与评分手册
ENGINEERING INTERVIEW HANDBOOK
80 QUESTIONS
7 ROLE ROUTES
0—4 UNIFIED SCORE
A4 INTERVIEWER EDITION
v1.0
2026-07-23
面试官版 / 内部使用 / 禁止外传
```

Use 29/39 pt for the Chinese title. Do not rasterize any cover text.

- [ ] **Step 7: Run the template tests**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_document.BlueprintPageTemplateTest \
  interview_question_bank.test_document
```

Expected: PASS; cover and section pages are full dark blueprint pages, body pages remain white.

- [ ] **Step 8: Commit the page-template checkpoint**

```bash
git add -f \
  tmp/pdfs/interview_question_bank/components.py \
  tmp/pdfs/interview_question_bank/document.py \
  tmp/pdfs/interview_question_bank/test_document.py
git commit -m "feat(pdf): add blueprint cover and chapter pages"
```

---

## Task 4: Enforce deterministic question starts, continuation headers, and safe furniture

**Files:**

- Modify: `tmp/pdfs/interview_question_bank/document.py`
- Modify: `tmp/pdfs/interview_question_bank/test_document.py`

**Interfaces:**

- `InterviewDocTemplate.beforeDocument()`
- `InterviewDocTemplate.afterFlowable(flowable)`
- `InterviewDocTemplate._draw_body(canvas, doc)`
- `PageContextMarker`
- `QuestionHeadingFlowable`

- [ ] **Step 1: Add failing continuation-state tests**

Build a synthetic bank with one long question and one following short question:

```python
class QuestionPaginationContractTest(unittest.TestCase):
    def test_long_question_continuation_header_and_next_question_new_page(self) -> None:
        pdf_bytes = build_long_then_short_question_pdf()
        pdf = fitz.open(stream=pdf_bytes, filetype="pdf")
        pages = [page.get_text() for page in pdf]

        q900_pages = [index for index, text in enumerate(pages) if "Q900" in text]
        q901_pages = [index for index, text in enumerate(pages) if "Q901" in text]

        self.assertGreaterEqual(len(q900_pages), 2)
        self.assertNotIn("Q900 · CONTINUED", pages[q900_pages[0]])
        for page_index in q900_pages[1:]:
            self.assertIn("Q900 · CONTINUED", pages[page_index])
        self.assertGreater(q901_pages[0], q900_pages[-1])
        self.assertNotIn("Q900 · CONTINUED", pages[q901_pages[0]])

    def test_every_question_heading_has_a_distinct_opening_page(self) -> None:
        pdf_bytes = build_three_short_questions_pdf()
        opening_pages = locate_question_heading_pages(
            pdf_bytes,
            ["Q910", "Q911", "Q912"],
        )
        self.assertEqual(len(set(opening_pages.values())), 3)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_document.QuestionPaginationContractTest
```

Expected: FAIL because the current header does not distinguish the opening page from continuation pages.

- [ ] **Step 2: Track the opening page in the document state**

Initialize state before each `multiBuild` pass:

```python
def beforeDocument(self) -> None:
    self.canv.setTitle(TITLE)
    self.canv.setSubject(SUBJECT)
    self.canv.setAuthor(AUTHOR)
    self.canv.setKeywords(KEYWORDS)
    self._current_section = "文档控制"
    self._current_question = None
    self._question_opening_pages: dict[str, int] = {}
```

Update state in `afterFlowable()`:

```python
if isinstance(flowable, PageContextMarker):
    self._current_section = flowable.section_title
    self._current_question = flowable.question_id
    return

if isinstance(flowable, QuestionHeadingFlowable):
    self._current_question = flowable.question_id
    self._question_opening_pages.setdefault(
        flowable.question_id,
        self.page,
    )
```

Keep the existing TOC and bookmark notifications after this state update.

- [ ] **Step 3: Render the exact continuation header**

In `_draw_body()`:

```python
right_header = "艾普项目面试题库"
if self._current_question:
    opening_page = self._question_opening_pages.get(self._current_question)
    if opening_page == self.page:
        right_header = self._current_question
    else:
        right_header = f"{self._current_question} · CONTINUED"
```

The left header remains the current section. Footer strings are exact:

```text
面试官版 / 内部使用
2026-07-23
第 X / Y 页
```

- [ ] **Step 4: Add safe-footer and chapter-decoration geometry tests**

Use PyMuPDF span rectangles on the synthetic long-question PDF:

```python
def test_body_spans_do_not_enter_footer_safe_zone(self) -> None:
    pdf_bytes = build_long_question_pdf()
    pdf = fitz.open(stream=pdf_bytes, filetype="pdf")
    safe_bottom = A4[1] - 17 * mm
    furniture = {
        "面试官版 / 内部使用",
        "2026-07-23",
    }
    for page in pdf:
        for span in body_spans(page):
            if span["text"].strip() in furniture:
                continue
            self.assertLessEqual(span["bbox"][3], safe_bottom + 0.5)


def test_chapter_decoration_has_eight_point_clearance(self) -> None:
    divider = make_test_chapter_divider()
    divider.wrap(BODY_WIDTH, A4[1])
    self.assertGreaterEqual(divider.decoration_clearance, 8)
```

Also keep the component-level 3 pt and 4 pt gap tests from Task 2 in the full suite.

- [ ] **Step 5: Make question start pages explicit**

Keep the Task 3 break-before-question sequence. Factor it into one helper so every question, including the first question after a chapter, has exactly one explicit opening break:

```python
def append_question_pages(
    story: list[Flowable],
    group: Section,
    questions: Sequence[Question],
    styles: StyleSet,
) -> None:
    for question in questions:
        story.append(PageBreak())
        story.append(UnitMarker("question"))
        story.append(PageContextMarker(group.title, question.question_id))
        story.extend(
            question_flowables(_question_for_document(question), styles)
        )


questions_by_prefix = {
    prefix: [
        question
        for question in bank.questions
        if question.question_id.startswith(prefix)
    ]
    for prefix in QUESTION_PREFIXES
}
ability_keywords = _group_ability_keywords(bank)

for group_index, group in enumerate(bank.question_groups):
    prefix = QUESTION_PREFIXES[group_index]
    questions = questions_by_prefix[prefix]
    story.extend(
        [
            NextPageTemplate("Chapter"),
            PageBreak(),
            UnitMarker("level2_section"),
            UnitMarker("question_group_divider"),
            PageContextMarker(group.title, None),
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
            NextPageTemplate("Body"),
        ]
    )
    append_question_pages(story, group, questions, styles)
```

Do not append another break after a question. Chapter-to-first-question and question-to-question transitions are both explicit, while group-to-group transition reuses the next chapter’s single opening break.

- [ ] **Step 6: Run all document regressions**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_document.QuestionPaginationContractTest \
  interview_question_bank.test_document
```

Expected: PASS; every question opens on a distinct page, long questions show `CONTINUED`, and body spans stay outside the footer zone.

- [ ] **Step 7: Commit the pagination checkpoint**

```bash
git add -f \
  tmp/pdfs/interview_question_bank/document.py \
  tmp/pdfs/interview_question_bank/test_document.py
git commit -m "fix(pdf): enforce question continuation contracts"
```

---

## Task 5: Harden the independent verifier and visual evidence pipeline

**Files:**

- Modify: `tmp/pdfs/interview_question_bank/build.py`
- Modify: `tmp/pdfs/interview_question_bank/verify.py`
- Modify: `tmp/pdfs/interview_question_bank/test_verify.py`
- Create: `tmp/pdfs/interview_question_bank/visual_review.py`
- Create: `tmp/pdfs/interview_question_bank/test_visual_review.py`

**Interfaces:**

- `write_build_receipt(...) -> dict[str, object]`
- `verify_pdf(source_path, pdf_path, receipt_path) -> dict[str, object]`
- `normalize_for_match(value: str) -> str`
- `source_last_sentence(question_bank) -> str`
- `render_pages_with_poppler(pdf_path, output_dir, dpi=144) -> list[Path]`
- `build_contact_sheets(page_paths, output_dir, pages_per_sheet=12) -> list[Path]`
- `build_grayscale_samples(pdf_path, page_paths, output_dir) -> dict[str, Path]`
- `screen_rendered_pages(page_paths) -> dict[str, object]`

- [ ] **Step 1: Add failing verification contract tests**

Add positive and negative fixtures for:

```python
EXPECTED_METADATA = {
    "title": "艾普项目高级岗位面试题库",
    "subject": "高级岗位内部面试与评分手册",
    "author": "Aipu Project",
    "keywords": "interview, engineering, internal",
}
FORBIDDEN_EXTRACTED_TOKENS = (
    "<details>",
    "</details>",
    "<summary>",
    "</summary>",
    "file://",
)
```

Required tests:

```python
class VerificationContractTest(unittest.TestCase):
    def test_rejects_wrong_metadata(self) -> None:
        with self.assertRaisesRegex(VerificationError, "metadata"):
            verify_fixture(metadata={"title": "Wrong title"})

    def test_rejects_missing_source_sha(self) -> None:
        with self.assertRaisesRegex(VerificationError, "source_sha256"):
            verify_fixture(receipt={})

    def test_rejects_unormalized_reference_path(self) -> None:
        with self.assertRaisesRegex(VerificationError, "reference"):
            verify_fixture(extra_text="../chatgpt_app_core/lib/app.dart")

    def test_rejects_missing_longest_answer_tail(self) -> None:
        with self.assertRaisesRegex(VerificationError, "longest answer"):
            verify_fixture(remove_longest_answer_tail=True)

    def test_rejects_non_0644_release_mode(self) -> None:
        with self.assertRaisesRegex(VerificationError, "0644"):
            verify_fixture(mode=0o600)

    def test_receipt_exposes_summary_counts(self) -> None:
        receipt = build_fixture_receipt()
        self.assertEqual(receipt["question_count"], 80)
        self.assertEqual(receipt["section_count"], 12)
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_verify.VerificationContractTest
```

Expected: FAIL because the current verifier does not enforce the complete approved contract.

- [ ] **Step 2: Implement deterministic normalization and source-tail checks**

Use whitespace-insensitive matching without changing Chinese punctuation:

```python
def normalize_for_match(value: str) -> str:
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
```

Select the production field with the largest normalized text length from the parsed question bank. Its `last_normalized_sentence()` must appear in the extracted PDF text.

Extend the existing build receipt without removing its detailed lists:

```python
receipt["question_count"] = len(receipt["question_ids"])
receipt["section_count"] = len(receipt["bookmark_titles"])
```

Verify:

- exactly 80 distinct question ids;
- exactly 12 second-level sections;
- expected four tables;
- every expected normalized reference string appears;
- no extracted `../`, `file://`, Markdown details tags or placeholder tokens;
- receipt `source_sha256` equals the live source file SHA-256;
- PDF metadata equals `EXPECTED_METADATA`;
- page size is A4 within 0.5 pt;
- final file mode is exactly `0o644`;
- page count and total-page footer agree;
- no unexpected near-empty page.

Chapter pages and the printable record form are allowed lower character counts only when their required identifying marker is present.

- [ ] **Step 3: Add failing isolated-render tests**

Add tests with a generated two-page PDF:

```python
class VisualReviewPipelineTest(unittest.TestCase):
    def test_poppler_render_count_matches_pdf_pages(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.render_dir,
            dpi=144,
        )
        self.assertEqual(len(pages), 2)
        self.assertTrue(all(path.parent == self.render_dir for path in pages))

    def test_contact_sheets_cover_every_page_once(self) -> None:
        pages = render_pages_with_poppler(
            self.pdf_path,
            self.render_dir,
            dpi=144,
        )
        sheets = build_contact_sheets(pages, self.contact_dir, pages_per_sheet=12)
        manifest = json.loads(
            (self.contact_dir / "manifest.json").read_text(encoding="utf-8")
        )
        covered = [
            page_number
            for sheet in manifest["sheets"]
            for page_number in sheet["pages"]
        ]
        self.assertEqual(covered, [1, 2])
        self.assertEqual(len(sheets), 1)

    def test_grayscale_samples_select_cover_chapter_and_dense_body(self) -> None:
        pages = render_pages_with_poppler(
            self.blueprint_fixture_pdf,
            self.render_dir,
            dpi=144,
        )
        samples = build_grayscale_samples(
            self.blueprint_fixture_pdf,
            pages,
            self.grayscale_dir,
        )
        self.assertEqual(
            set(samples),
            {"cover", "chapter", "dense-body"},
        )
        self.assertTrue(
            all(Image.open(path).mode == "L" for path in samples.values())
        )
```

Run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_visual_review.VisualReviewPipelineTest
```

Expected: FAIL because `visual_review.py` does not yet exist.

- [ ] **Step 4: Implement Poppler rendering and contact-sheet manifests**

`render_pages_with_poppler()` must:

1. require an empty or newly created output directory;
2. invoke `pdftoppm -png -r 144`;
3. sort pages by numeric suffix;
4. compare PNG count to `fitz.open(pdf_path).page_count`;
5. reject unreadable or inconsistent-size images.

Use this exact process shape:

```python
subprocess.run(
    [
        "pdftoppm",
        "-png",
        "-r",
        str(dpi),
        str(pdf_path),
        str(output_dir / "page"),
    ],
    check=True,
    capture_output=True,
    text=True,
)
```

`build_contact_sheets()` must create 3 x 4 sheets, label every thumbnail with its one-based page number, and write:

```json
{
  "pages_per_sheet": 12,
  "sheets": [
    {
      "file": "contact-001-012.png",
      "pages": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    }
  ]
}
```

The last sheet contains only remaining pages. Do not silently drop blank-looking pages.

`build_grayscale_samples()` must select page 1 as `cover`, the first page whose extracted text contains `UNIFIED SCORE · 0—4` as `chapter`, and the non-cover/non-chapter page with the largest normalized extracted character count as `dense-body`. It writes exactly `cover.png`, `chapter.png` and `dense-body.png` in Pillow mode `L`.

- [ ] **Step 5: Implement conservative suspicious-page screening**

`screen_rendered_pages()` writes `tmp/pdfs/render-screening-blueprint.json` with:

- page count;
- image dimensions;
- near-white ratio;
- near-black ratio;
- connected dark-region candidates crossing the footer safe zone;
- pages with unusually low extracted character count;
- pages whose image dimensions differ;
- `suspicious_pages`, sorted and unique.

Screening is advisory and never replaces human contact-sheet inspection. Any suspicious page must be opened individually.

- [ ] **Step 6: Run verifier and visual-pipeline tests**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest \
  interview_question_bank.test_verify \
  interview_question_bank.test_visual_review
```

Expected: PASS.

- [ ] **Step 7: Commit the verification checkpoint**

```bash
git add -f \
  tmp/pdfs/interview_question_bank/build.py \
  tmp/pdfs/interview_question_bank/verify.py \
  tmp/pdfs/interview_question_bank/test_verify.py \
  tmp/pdfs/interview_question_bank/visual_review.py \
  tmp/pdfs/interview_question_bank/test_visual_review.py
git commit -m "test(pdf): harden release and visual verification"
```

---

## Task 6: Build the complete formal PDF and pass all machine gates

**Files:**

- Modify only if a failing test identifies a defect:
  - `tmp/pdfs/interview_question_bank/styles.py`
  - `tmp/pdfs/interview_question_bank/components.py`
  - `tmp/pdfs/interview_question_bank/document.py`
  - `tmp/pdfs/interview_question_bank/build.py`
  - `tmp/pdfs/interview_question_bank/verify.py`
  - corresponding test file
- Generate: `output/pdf/aipu-senior-role-interview-question-bank.pdf`
- Generate: `tmp/pdfs/build-receipt.json`
- Generate: `tmp/pdfs/verification-report.json`

- [ ] **Step 1: Confirm source and unrelated files are untouched**

Run:

```bash
git status --short
git diff -- docs/project-interview-question-bank.md README.md login_sdk/test/support/
shasum -a 256 docs/project-interview-question-bank.md
```

Expected: no task-created diff in the source Markdown or unrelated user files. Record the source SHA-256 for comparison with the build receipt.

- [ ] **Step 2: Run the complete PDF test suite**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest discover \
  -s tmp/pdfs/interview_question_bank \
  -p 'test_*.py' \
  -v
```

Expected: all tests PASS, including `LONG-ANSWER-END`, continuation headers, both-direction gaps and footer safety.

- [ ] **Step 3: Build through the atomic release path**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 \
  -m interview_question_bank.build \
  docs/project-interview-question-bank.md \
  output/pdf/aipu-senior-role-interview-question-bank.pdf
```

Expected:

- a temporary PDF is built first;
- verification completes before replacement;
- the final file exists;
- old valid output remains intact if any stage fails;
- `tmp/pdfs/build-receipt.json` records source SHA-256, output SHA-256, question count, section count and page count.

- [ ] **Step 4: Run the independent verifier**

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 \
  -m interview_question_bank.verify \
  docs/project-interview-question-bank.md \
  output/pdf/aipu-senior-role-interview-question-bank.pdf \
  --receipt tmp/pdfs/build-receipt.json \
  --report tmp/pdfs/verification-report.json
```

Expected: exit code 0 and a report containing:

```text
questions=80
sections=12
metadata=pass
references=pass
longest_answer_tail=pass
continuations=pass
page_geometry=pass
file_mode=0644
```

- [ ] **Step 5: Inspect PDF structure with Poppler**

```bash
pdfinfo output/pdf/aipu-senior-role-interview-question-bank.pdf
pdffonts output/pdf/aipu-senior-role-interview-question-bank.pdf
stat -f '%Lp %z %N' output/pdf/aipu-senior-role-interview-question-bank.pdf
shasum -a 256 output/pdf/aipu-senior-role-interview-question-bank.pdf
```

Expected:

- A4 page size;
- title, subject, author and keywords match the spec;
- STHeiti and Menlo fonts are embedded/subset;
- permission is `644`;
- page count is content-driven and within the verifier’s structural limits.

- [ ] **Step 6: If a machine gate fails, repair through a focused regression**

For each failure:

1. add one failing test that reproduces the exact defect;
2. make the smallest in-scope fix;
3. run the focused test;
4. rerun the full suite;
5. rebuild and rerun the verifier.

Do not weaken a threshold merely to make the existing artifact pass.

- [ ] **Step 7: Commit any build-discovered source fix**

If no source fix was needed, skip this commit. If a fix was needed:

```bash
git add -f \
  tmp/pdfs/interview_question_bank/components.py \
  tmp/pdfs/interview_question_bank/document.py \
  tmp/pdfs/interview_question_bank/build.py \
  tmp/pdfs/interview_question_bank/styles.py \
  tmp/pdfs/interview_question_bank/verify.py \
  tmp/pdfs/interview_question_bank/test_components.py \
  tmp/pdfs/interview_question_bank/test_document.py \
  tmp/pdfs/interview_question_bank/test_verify.py
git commit -m "fix(pdf): resolve full-book pagination regression"
```

Stage only files that actually changed. Do not commit the generated PDF binary or render PNG files.

---

## Task 7: Render and visually approve every page

**Files:**

- Generate: `tmp/pdfs/rendered-blueprint/page-*.png`
- Generate: `tmp/pdfs/contact-sheets-blueprint/contact-*.png`
- Generate: `tmp/pdfs/contact-sheets-blueprint/manifest.json`
- Generate: `tmp/pdfs/grayscale-blueprint/cover.png`
- Generate: `tmp/pdfs/grayscale-blueprint/chapter.png`
- Generate: `tmp/pdfs/grayscale-blueprint/dense-body.png`
- Generate: `tmp/pdfs/render-screening-blueprint.json`

- [ ] **Step 1: Create a fresh, isolated visual-evidence set**

Use directories that do not exist before this run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 \
  -m interview_question_bank.visual_review \
  output/pdf/aipu-senior-role-interview-question-bank.pdf \
  --render-dir tmp/pdfs/rendered-blueprint \
  --contact-dir tmp/pdfs/contact-sheets-blueprint \
  --grayscale-dir tmp/pdfs/grayscale-blueprint \
  --screening-report tmp/pdfs/render-screening-blueprint.json \
  --dpi 144
```

Expected:

- PNG count equals PDF page count;
- manifest covers every page exactly once;
- all pages have identical pixel dimensions;
- screening report lists all suspicious pages explicitly.

If any of the three evidence directories already exists, use the same new suffix such as `-v2` for all three; do not overwrite or reuse an old evidence set.

- [ ] **Step 2: Inspect every contact sheet**

Open every `contact-*.png` with the local image viewer. Check:

- page sequence and chapter transitions;
- repeated unexpected blank pages;
- visible clipping or overflow;
- black squares or missing Chinese glyphs;
- inconsistent page density;
- labels touching or being covered by panels;
- body content crossing the footer line.

Record each suspect page number before opening individual pages.

- [ ] **Step 3: Inspect all mandatory individual pages**

Open the rendered pages corresponding to:

- cover;
- document control;
- usage/scoring page;
- table of contents;
- role routes;
- first chapter page;
- first question;
- a question with blind material;
- the production longest-answer question and every continuation page;
- the widest table;
- comprehensive assessment;
- printable interview record form;
- final maintenance page.

Also open every page listed in `suspicious_pages`.

- [ ] **Step 4: Check dark and light templates in grayscale**

Open `tmp/pdfs/grayscale-blueprint/cover.png`, `chapter.png` and `dense-body.png`. Confirm:

- dark-page grid remains subordinate to text;
- Sky/Blue metrics remain readable;
- risk, score and info panels remain distinguishable through labels and borders;
- no meaning depends on color alone.

- [ ] **Step 5: Repair any visual defect through the regression loop**

For each defect:

1. add a test for its geometry or pagination cause;
2. implement the focused fix;
3. rerun the complete unit suite;
4. rebuild the formal PDF;
5. rerun independent verification;
6. render into another new evidence directory;
7. reinspect every contact sheet and mandatory page.

Do not declare completion from a sample page or a partial render.

---

## Task 8: Final independent review and handoff

**Files:**

- Review all task-modified source and tests.
- Deliver: `output/pdf/aipu-senior-role-interview-question-bank.pdf`

- [ ] **Step 1: Run spec-to-artifact review**

Use `superpowers:requesting-code-review` for an independent review against:

- the approved design spec;
- this implementation plan;
- the final verification report;
- the contact-sheet manifest and suspicious-page report.

The reviewer must explicitly answer:

- Is the original overlap bug eliminated by measured geometry rather than negative spacing?
- Does every question begin on a new page?
- Do continuation headers identify the active question?
- Does the longest answer preserve its final source sentence?
- Are all 80 questions and 12 sections present?
- Are all mandatory visual pages reviewed?
- Were unrelated user files preserved?

- [ ] **Step 2: Resolve every blocking review finding**

Any content loss, overlap, clipping, missing glyph, invalid metadata, unsafe footer, wrong question start or unreviewed suspicious page is release-blocking. Repair it through the same test → build → verify → render cycle.

- [ ] **Step 3: Run final verification immediately before delivery**

Use `superpowers:verification-before-completion`, then run:

```bash
PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 -m unittest discover \
  -s tmp/pdfs/interview_question_bank \
  -p 'test_*.py' \
  -v

PYTHONPATH=tmp/pdfs /Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3.12 \
  -m interview_question_bank.verify \
  docs/project-interview-question-bank.md \
  output/pdf/aipu-senior-role-interview-question-bank.pdf \
  --receipt tmp/pdfs/build-receipt.json \
  --report tmp/pdfs/verification-report.json

pdfinfo output/pdf/aipu-senior-role-interview-question-bank.pdf
stat -f '%Lp %z %N' output/pdf/aipu-senior-role-interview-question-bank.pdf
git diff --check
git status --short
```

Expected: all tests and verifier pass, A4 metadata is correct, mode is `644`, diff is clean of whitespace errors, and unrelated pre-existing changes remain untouched.

- [ ] **Step 4: Deliver an evidence-based handoff**

Report:

- clickable absolute path to the final PDF;
- final page count and file size;
- source and PDF SHA-256;
- `80 / 12 / 4` content counts;
- test and verifier results;
- Poppler render page count and contact-sheet count;
- mandatory-page and suspicious-page visual review result;
- exact list of source files changed;
- confirmation that `docs/project-interview-question-bank.md` and unrelated user changes were not modified.
