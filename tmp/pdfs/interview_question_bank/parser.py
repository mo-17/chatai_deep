"""Semantic, rendering-free parser for the interview question-bank Markdown."""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping, TypeAlias
import re


QUESTION_RE = re.compile(r"^(C|FE|AI|BE|SEC|PM|QA|OPS)(\d+)\.\s+(.+)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
ANSWER_FIELD_RE = re.compile(r"^\*\*([^*]+)：\*\*\s*(.*)$")
LIST_RE = re.compile(r"^(?:[-*+]\s+|\d+\.\s+)(.+)$")


@dataclass(frozen=True)
class InlineText:
    text: str
    kind: str = "paragraph"


@dataclass(frozen=True)
class ListBlock:
    items: tuple[str, ...]
    ordered: bool


@dataclass(frozen=True)
class TableBlock:
    rows: tuple[tuple[str, ...], ...]


@dataclass(frozen=True)
class CodeBlock:
    language: str
    code: str


Block: TypeAlias = InlineText | ListBlock | TableBlock | CodeBlock


@dataclass(frozen=True)
class Section:
    level: int
    title: str
    blocks: tuple[Block, ...]


@dataclass(frozen=True)
class Question:
    question_id: str
    title: str
    prompt: str
    preface: tuple[str, ...]
    answer_fields: Mapping[str, tuple[str, ...]]


@dataclass(frozen=True)
class QuestionBank:
    metadata: tuple[Block, ...]
    intro_sections: tuple[Section, ...]
    question_groups: tuple[Section, ...]
    assessment_sections: tuple[Section, ...]
    maintenance_rules: tuple[Section, ...]
    level2_sections: tuple[Section, ...]
    questions: tuple[Question, ...]
    tables: tuple[TableBlock, ...]
    code_blocks: tuple[CodeBlock, ...]
    searchable_text: str


def _flush_paragraph(buffer: list[str], blocks: list[Block]) -> None:
    if buffer:
        blocks.append(InlineText("\n".join(buffer)))
        buffer.clear()


def _table_row(line: str) -> tuple[str, ...]:
    return tuple(cell.strip() for cell in line.strip().strip("|").split("|"))


def _is_table_separator(line: str) -> bool:
    cells = _table_row(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


def parse_blocks(lines: list[str]) -> tuple[Block, ...]:
    """Recognize document blocks without interpreting inline Markdown."""
    blocks: list[Block] = []
    paragraph: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if stripped == "<details>":
            _flush_paragraph(paragraph, blocks)
            index += 1
            continue
        if stripped == "</details>":
            _flush_paragraph(paragraph, blocks)
            index += 1
            continue
        if stripped.startswith("<summary>") and stripped.endswith("</summary>"):
            _flush_paragraph(paragraph, blocks)
            summary = stripped.removeprefix("<summary>").removesuffix("</summary>").strip()
            if summary:
                blocks.append(InlineText(summary, kind="summary"))
            index += 1
            continue
        if stripped.startswith("```"):
            _flush_paragraph(paragraph, blocks)
            language = stripped[3:].strip()
            index += 1
            code: list[str] = []
            while index < len(lines) and not lines[index].strip().startswith("```"):
                code.append(lines[index])
                index += 1
            if index < len(lines):
                index += 1
            blocks.append(CodeBlock(language, "\n".join(code)))
            continue
        if not stripped or stripped == "---":
            _flush_paragraph(paragraph, blocks)
            index += 1
            continue
        if stripped.startswith("|") and "|" in stripped[1:]:
            _flush_paragraph(paragraph, blocks)
            rows: list[tuple[str, ...]] = [_table_row(stripped)]
            index += 1
            if index < len(lines) and _is_table_separator(lines[index].strip()):
                index += 1
            while index < len(lines) and lines[index].strip().startswith("|"):
                rows.append(_table_row(lines[index]))
                index += 1
            blocks.append(TableBlock(tuple(rows)))
            continue
        list_match = LIST_RE.match(stripped)
        if list_match:
            _flush_paragraph(paragraph, blocks)
            ordered = bool(re.match(r"^\d+\.\s+", stripped))
            items = [list_match.group(1)]
            index += 1
            while index < len(lines):
                next_match = LIST_RE.match(lines[index].strip())
                if not next_match:
                    break
                items.append(next_match.group(1))
                index += 1
            blocks.append(ListBlock(tuple(items), ordered))
            continue
        paragraph.append(line)
        index += 1
    _flush_paragraph(paragraph, blocks)
    return tuple(blocks)


def build_sections(markdown: str) -> tuple[tuple[Block, ...], tuple[Section, ...]]:
    metadata_lines: list[str] = []
    section_parts: list[tuple[int, str, list[str]]] = []
    current: tuple[int, str, list[str]] | None = None
    for line in markdown.splitlines():
        heading = HEADING_RE.match(line)
        if heading:
            if current is None:
                current = (len(heading.group(1)), heading.group(2), [])
            else:
                section_parts.append(current)
                current = (len(heading.group(1)), heading.group(2), [])
        elif current is None:
            metadata_lines.append(line)
        else:
            current[2].append(line)
    if current is not None:
        section_parts.append(current)
    metadata = parse_blocks(metadata_lines)
    sections = tuple(Section(level, title, parse_blocks(lines)) for level, title, lines in section_parts)
    return metadata, sections


def _inline_text(block: Block) -> tuple[str, ...]:
    if isinstance(block, InlineText):
        return tuple(line.strip() for line in block.text.splitlines() if line.strip())
    if isinstance(block, ListBlock):
        return block.items
    return ()


def build_questions(sections: tuple[Section, ...]) -> tuple[Question, ...]:
    questions: list[Question] = []
    for section in sections:
        heading = QUESTION_RE.match(section.title)
        if not heading:
            continue
        question_id = f"{heading.group(1)}{heading.group(2)}"
        preface: list[str] = []
        fields: dict[str, list[str]] = {}
        active_label: str | None = None
        prompt = ""
        for block in section.blocks:
            for text in _inline_text(block):
                if text.startswith("**问题：**"):
                    prompt = text.removeprefix("**问题：**").strip()
                    active_label = None
                    continue
                field = ANSWER_FIELD_RE.match(text)
                if field:
                    active_label = field.group(1)
                    fields.setdefault(active_label, []).append(field.group(2))
                elif active_label is not None:
                    fields[active_label].append(text)
                else:
                    preface.append(text)
        frozen_fields = MappingProxyType({key: tuple(value) for key, value in fields.items()})
        questions.append(Question(question_id, heading.group(3), prompt, tuple(preface), frozen_fields))
    return tuple(questions)


def _searchable_text(blocks: tuple[Block, ...]) -> str:
    values: list[str] = []
    for block in blocks:
        if isinstance(block, InlineText):
            values.append(block.text)
        elif isinstance(block, ListBlock):
            values.extend(block.items)
        elif isinstance(block, TableBlock):
            values.extend(cell for row in block.rows for cell in row)
        elif isinstance(block, CodeBlock):
            values.append(block.code)
    return "\n".join(values)


def parse_question_bank(markdown: str) -> QuestionBank:
    """Parse the complete source document into immutable semantic records."""
    metadata, sections = build_sections(markdown)
    level2_sections = tuple(section for section in sections if section.level == 2)
    questions = build_questions(sections)
    all_blocks = metadata + tuple(block for section in sections for block in section.blocks)
    tables = tuple(block for block in all_blocks if isinstance(block, TableBlock))
    code_blocks = tuple(block for block in all_blocks if isinstance(block, CodeBlock))
    return QuestionBank(
        metadata=metadata,
        intro_sections=level2_sections[:2],
        question_groups=level2_sections[2:10],
        assessment_sections=level2_sections[10:11],
        maintenance_rules=level2_sections[11:],
        level2_sections=level2_sections,
        questions=questions,
        tables=tables,
        code_blocks=code_blocks,
        searchable_text=_searchable_text(all_blocks),
    )
