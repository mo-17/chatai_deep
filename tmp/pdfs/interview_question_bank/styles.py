"""Typography and color tokens for the interview handbook PDF."""

from __future__ import annotations

from dataclasses import dataclass
from html import escape
from pathlib import Path
import posixpath
import re

from reportlab.lib.colors import Color, HexColor
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont


HIRAGINO_PATH = Path("/System/Library/Fonts/Hiragino Sans GB.ttc")
SONGTI_PATH = Path("/System/Library/Fonts/Supplemental/Songti.ttc")
ARIAL_UNICODE_PATH = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
STHEITI_LIGHT_PATH = Path("/System/Library/Fonts/STHeiti Light.ttc")
STHEITI_MEDIUM_PATH = Path("/System/Library/Fonts/STHeiti Medium.ttc")
MENLO_PATH = Path("/System/Library/Fonts/Menlo.ttc")

BODY_FONT_CANDIDATES = (
    ("AipuBodyHeitiLight", STHEITI_LIGHT_PATH, 1, "Heiti SC Light"),
    ("AipuBodySongtiLight", SONGTI_PATH, 3, "Songti SC Light"),
    ("AipuBodyArialUnicode", ARIAL_UNICODE_PATH, 0, "Arial Unicode MS"),
)
HEADING_FONT_CANDIDATES = (
    ("AipuHeadingHeitiMedium", STHEITI_MEDIUM_PATH, 1, "Heiti SC Medium"),
    ("AipuHeadingSongtiBold", SONGTI_PATH, 1, "Songti SC Bold"),
)
CODE_FONT_CANDIDATES = (
    ("AipuCodeMenlo", MENLO_PATH, 0, "Menlo Regular"),
)

DARK_NAVY = HexColor("#0D263E")
NAVY = HexColor("#163A5F")
BLUE = HexColor("#2F6FED")
SKY = HexColor("#62ADFF")
INK = HexColor("#172B3A")
MUTED = HexColor("#536575")
LINE = HexColor("#D6DEE6")
PAPER = HexColor("#FFFFFF")
SOFT = HexColor("#F6F8FA")
INFO_FILL = HexColor("#EEF4FF")
RISK = HexColor("#B42318")
RISK_FILL = HexColor("#FEF3F2")
SCORE = HexColor("#1D4ED8")
SCORE_FILL = HexColor("#EFF6FF")


@dataclass(frozen=True)
class FontSet:
    body: str
    heading: str
    code: str
    body_source: str
    heading_source: str
    code_source: str
    body_postscript_name: str
    heading_postscript_name: str
    code_postscript_name: str
    body_subfont_index: int
    heading_subfont_index: int
    code_subfont_index: int
    code_embedded: bool

    @property
    def source(self) -> str:
        """Compatibility label retained for existing build receipts."""
        return self.body_source


@dataclass(frozen=True)
class StyleSet:
    fonts: FontSet
    question_heading: ParagraphStyle
    prompt: ParagraphStyle
    preface: ParagraphStyle
    field_label: ParagraphStyle
    field_body: ParagraphStyle
    risk_label: ParagraphStyle
    risk_body: ParagraphStyle
    scoring_label: ParagraphStyle
    scoring_body: ParagraphStyle
    notes: ParagraphStyle
    table_header: ParagraphStyle
    table_body: ParagraphStyle
    form_label: ParagraphStyle
    form_body: ParagraphStyle
    primary: Color
    accent: Color
    danger: Color
    dark_navy: Color
    sky: Color
    score: Color
    paper: Color
    soft: Color
    info_fill: Color
    line: Color
    risk_fill: Color
    scoring_fill: Color


def _font_postscript_name(name: str) -> str:
    raw = pdfmetrics.getFont(name).face.name
    return raw.decode("latin-1") if isinstance(raw, bytes) else str(raw)


def _register_role(
    candidates: tuple[tuple[str, Path, int, str], ...],
    *,
    require_cjk: bool,
    require_monospace: bool = False,
) -> tuple[str, str, str, int] | None:
    for name, path, subfont_index, source in candidates:
        try:
            if not path.is_file():
                continue
            if name not in pdfmetrics.getRegisteredFontNames():
                font = TTFont(name, str(path), subfontIndex=subfont_index)
                if require_cjk and any(
                    codepoint not in font.face.charToGlyph
                    for codepoint in (ord("中"), ord("面"), ord("试"))
                ):
                    continue
                pdfmetrics.registerFont(font)
            if require_monospace:
                narrow = pdfmetrics.stringWidth("iiii", name, 10)
                wide = pdfmetrics.stringWidth("WWWW", name, 10)
                if abs(narrow - wide) > 0.01:
                    continue
            return name, source, _font_postscript_name(name), subfont_index
        except Exception:
            continue
    return None


def register_fonts() -> FontSet:
    """Register inspected, embeddable and semantically distinct font roles."""
    body = _register_role(BODY_FONT_CANDIDATES, require_cjk=True)
    if body is None:
        raise RuntimeError("No embeddable Chinese font could be registered for body text")
    heading = _register_role(HEADING_FONT_CANDIDATES, require_cjk=True)
    if heading is None:
        raise RuntimeError("No distinct embeddable Chinese heading font could be registered")
    if body[2] == heading[2]:
        raise RuntimeError("Body and heading fonts must resolve to distinct embedded faces")

    code = _register_role(
        CODE_FONT_CANDIDATES,
        require_cjk=False,
        require_monospace=True,
    )
    code_embedded = code is not None
    if code is None:
        code = ("Courier", "PDF Courier fallback", "Courier", -1)

    return FontSet(
        body=body[0],
        heading=heading[0],
        code=code[0],
        body_source=body[1],
        heading_source=heading[1],
        code_source=code[1],
        body_postscript_name=body[2],
        heading_postscript_name=heading[2],
        code_postscript_name=code[2],
        body_subfont_index=body[3],
        heading_subfont_index=heading[3],
        code_subfont_index=code[3],
        code_embedded=code_embedded,
    )


MARKDOWN_LINK_RE = re.compile(r"\[([^]]+)\]\(([^)]+)\)")
INLINE_TOKEN_RE = re.compile(r"(\[[^]]+\]\([^)]+\)|`[^`]+`)")


def normalize_repository_target(
    target: str,
    *,
    source_directory: str = "docs",
) -> str:
    """Resolve a Markdown target to a readable repository-relative path."""
    target = target.strip()
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", target):
        return target
    path, marker, fragment = target.partition("#")
    if path.startswith("/"):
        normalized = posixpath.normpath(path.lstrip("/"))
    else:
        normalized = posixpath.normpath(posixpath.join(source_directory, path))
    while normalized.startswith("../"):
        normalized = normalized[3:]
    if normalized == ".":
        normalized = ""
    return normalized + (marker + fragment if marker else "")


def printable_inline_text(text: str) -> str:
    """Convert inline Markdown to the exact plain text intended for extraction."""
    def replace_link(match: re.Match[str]) -> str:
        label = match.group(1).replace("`", "")
        target = normalize_repository_target(match.group(2))
        return f"{label} · {target}"

    return MARKDOWN_LINK_RE.sub(replace_link, text).replace("`", "")


def _render_code(value: str, code_font: str) -> str:
    return f'<font name="{code_font}" color="#163A5F">{escape(value)}</font>'


def _render_label(label: str, code_font: str) -> str:
    parts = re.split(r"(`[^`]+`)", label)
    return "".join(
        _render_code(part[1:-1], code_font)
        if part.startswith("`") and part.endswith("`")
        else escape(part)
        for part in parts
    )


def safe_inline(text: str, code_font: str) -> str:
    """Escape Markdown and print repository links without creating local URLs."""
    rendered: list[str] = []
    for part in INLINE_TOKEN_RE.split(text):
        link = MARKDOWN_LINK_RE.fullmatch(part)
        if link:
            rendered.append(_render_label(link.group(1), code_font))
            rendered.append(" · ")
            rendered.append(
                _render_code(
                    normalize_repository_target(link.group(2)),
                    code_font,
                )
            )
        elif part.startswith("`") and part.endswith("`"):
            rendered.append(_render_code(part[1:-1], code_font))
        else:
            rendered.append(escape(part))
    return "".join(rendered).replace("\n", "<br/>")


def build_styles(fonts: FontSet) -> StyleSet:
    """Build the immutable visual vocabulary shared by all PDF components."""
    base = dict(fontName=fonts.body, textColor=INK, leading=15, fontSize=9.2)
    def style(name: str, **overrides) -> ParagraphStyle:
        return ParagraphStyle(name, **(base | overrides))

    question_heading = style(
        "QuestionHeading",
        fontName=fonts.heading,
        fontSize=15,
        leading=20,
        textColor=NAVY,
        spaceBefore=7,
        spaceAfter=6,
        keepWithNext=True,
    )
    prompt = style(
        "PromptPanel",
        fontSize=10.2,
        leading=16,
        textColor=NAVY,
        backColor=INFO_FILL,
        borderColor=BLUE,
        borderWidth=0.8,
        borderPadding=(7, 8, 7, 8),
        spaceAfter=7,
    )
    preface = style(
        "Preface",
        fontSize=8.5,
        leading=13,
        textColor=MUTED,
        backColor=INFO_FILL,
        borderColor=BLUE,
        borderWidth=0.6,
        borderPadding=(5, 7, 5, 7),
        spaceAfter=5,
    )
    field_label = style(
        "FieldLabel",
        fontSize=9.4,
        leading=13,
        textColor=NAVY,
        spaceBefore=5,
        spaceAfter=2,
        keepWithNext=False,
    )
    field_body = style(
        "FieldBody",
        backColor=SOFT,
        borderColor=LINE,
        borderWidth=0.45,
        borderPadding=(6, 7, 6, 7),
        spaceAfter=4,
    )
    risk_label = ParagraphStyle(
        "RiskLabel",
        parent=field_label,
        textColor=RISK,
    )
    risk_body = ParagraphStyle(
        "RiskBody",
        parent=field_body,
        textColor=RISK,
        backColor=RISK_FILL,
        borderColor=RISK,
    )
    scoring_label = ParagraphStyle(
        "ScoringLabel",
        parent=field_label,
        textColor=SCORE,
    )
    scoring_body = ParagraphStyle(
        "ScoringBody",
        parent=field_body,
        textColor=SCORE,
        backColor=None,
        borderColor=SCORE,
    )
    notes = style(
        "InterviewerNotes",
        fontSize=8.8,
        leading=16,
        textColor=MUTED,
        borderColor=LINE,
        borderWidth=0.6,
        borderPadding=(6, 7, 7, 7),
        spaceBefore=6,
        spaceAfter=10,
    )
    table_header = style(
        "TableHeader",
        fontSize=8.2,
        leading=11,
        textColor=PAPER,
        alignment=TA_CENTER,
    )
    table_body = style(
        "TableBody",
        fontSize=7.8,
        leading=11,
        alignment=TA_LEFT,
    )
    form_label = style(
        "FormLabel",
        fontSize=9,
        leading=14,
        textColor=NAVY,
    )
    form_body = style(
        "FormBody",
        fontSize=9,
        leading=14,
    )
    return StyleSet(
        fonts=fonts,
        question_heading=question_heading,
        prompt=prompt,
        preface=preface,
        field_label=field_label,
        field_body=field_body,
        risk_label=risk_label,
        risk_body=risk_body,
        scoring_label=scoring_label,
        scoring_body=scoring_body,
        notes=notes,
        table_header=table_header,
        table_body=table_body,
        form_label=form_label,
        form_body=form_body,
        primary=NAVY,
        accent=BLUE,
        danger=RISK,
        dark_navy=DARK_NAVY,
        sky=SKY,
        score=SCORE,
        paper=PAPER,
        soft=SOFT,
        info_fill=INFO_FILL,
        line=LINE,
        risk_fill=RISK_FILL,
        scoring_fill=SCORE_FILL,
    )
