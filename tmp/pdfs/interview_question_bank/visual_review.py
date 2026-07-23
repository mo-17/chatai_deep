"""Isolated Poppler rendering and advisory visual-review evidence."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import unicodedata
from typing import Iterable, Sequence

import pdfplumber
from PIL import Image, ImageDraw
from pypdf import PdfReader


ROOT = Path(__file__).resolve().parents[3]
SCREENING_REPORT_PATH = ROOT / "tmp" / "pdfs" / "render-screening-blueprint.json"
PAGE_SUFFIX_RE = re.compile(r"-(\d+)\.png$")


def _page_number(path: Path) -> int:
    match = PAGE_SUFFIX_RE.search(path.name)
    if not match:
        raise ValueError(f"rendered page lacks numeric suffix: {path.name}")
    return int(match.group(1))


def _sorted_pages(page_paths: Iterable[Path]) -> list[Path]:
    pages = sorted((Path(path) for path in page_paths), key=_page_number)
    numbers = [_page_number(path) for path in pages]
    if len(numbers) != len(set(numbers)):
        raise ValueError("rendered page numbers must be unique")
    return pages


def _prepare_empty_directory(path: Path) -> Path:
    path = Path(path)
    if path.exists():
        if not path.is_dir():
            raise ValueError(f"output path is not a directory: {path}")
        if any(path.iterdir()):
            raise ValueError(f"output directory must be empty: {path}")
    else:
        path.mkdir(parents=True)
    return path


def _normalized_text(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value))


def render_pages_with_poppler(
    pdf_path: Path,
    output_dir: Path,
    dpi: int = 144,
) -> list[Path]:
    """Render one readable, consistently sized PNG per PDF page."""
    pdf_path = Path(pdf_path)
    output_dir = _prepare_empty_directory(Path(output_dir))
    if dpi <= 0:
        raise ValueError("dpi must be positive")
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
    pages = _sorted_pages(output_dir.glob("page-*.png"))
    expected_page_count = len(PdfReader(pdf_path).pages)
    if len(pages) != expected_page_count:
        raise ValueError(
            "Poppler PNG count does not match PDF page count: "
            f"{len(pages)} != {expected_page_count}"
        )
    expected_size: tuple[int, int] | None = None
    for path in pages:
        try:
            with Image.open(path) as image:
                image.load()
                size = image.size
        except Exception as error:
            raise ValueError(f"unreadable rendered page: {path}") from error
        if expected_size is None:
            expected_size = size
        elif size != expected_size:
            raise ValueError(
                f"inconsistent rendered page size: {path.name} {size} != {expected_size}"
            )
    manifest = {
        "source_pdf": str(pdf_path.resolve()),
        "dpi": dpi,
        "page_count": expected_page_count,
        "pages": [path.name for path in pages],
        "dimensions": list(expected_size or (0, 0)),
    }
    (output_dir / "render-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return pages


def build_contact_sheets(
    page_paths: Sequence[Path],
    output_dir: Path,
    pages_per_sheet: int = 12,
) -> list[Path]:
    """Build fixed 3 x 4 labeled sheets and an exhaustive page manifest."""
    if pages_per_sheet != 12:
        raise ValueError("contact sheets are fixed at 12 pages (3 x 4)")
    pages = _sorted_pages(page_paths)
    if not pages:
        raise ValueError("contact sheets require at least one rendered page")
    output_dir = _prepare_empty_directory(Path(output_dir))
    columns, rows = 3, 4
    cell_width, cell_height = 360, 480
    label_height = 28
    sheets: list[Path] = []
    manifest_sheets: list[dict[str, object]] = []
    for offset in range(0, len(pages), pages_per_sheet):
        batch = pages[offset : offset + pages_per_sheet]
        numbers = [_page_number(path) for path in batch]
        sheet = Image.new(
            "RGB",
            (columns * cell_width, rows * cell_height),
            "white",
        )
        draw = ImageDraw.Draw(sheet)
        for index, (path, page_number) in enumerate(zip(batch, numbers)):
            column = index % columns
            row = index // columns
            x0 = column * cell_width
            y0 = row * cell_height
            with Image.open(path) as source:
                thumbnail = source.convert("RGB")
                thumbnail.thumbnail(
                    (cell_width - 16, cell_height - label_height - 16),
                    Image.Resampling.LANCZOS,
                )
            x = x0 + (cell_width - thumbnail.width) // 2
            y = y0 + label_height + (
                cell_height - label_height - thumbnail.height
            ) // 2
            sheet.paste(thumbnail, (x, y))
            draw.text((x0 + 8, y0 + 7), f"Page {page_number}", fill="black")
            draw.rectangle(
                (x0, y0, x0 + cell_width - 1, y0 + cell_height - 1),
                outline="#B8C2CC",
                width=1,
            )
        filename = f"contact-{numbers[0]:03d}-{numbers[-1]:03d}.png"
        destination = output_dir / filename
        sheet.save(destination)
        sheets.append(destination)
        manifest_sheets.append({"file": filename, "pages": numbers})
    manifest = {
        "pages_per_sheet": pages_per_sheet,
        "sheets": manifest_sheets,
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    covered = [
        page_number
        for record in manifest_sheets
        for page_number in record["pages"]
    ]
    expected = [_page_number(path) for path in pages]
    if covered != expected:
        raise ValueError("contact-sheet manifest did not cover every page exactly once")
    return sheets


def build_grayscale_samples(
    pdf_path: Path,
    page_paths: Sequence[Path],
    output_dir: Path,
) -> dict[str, Path]:
    """Write exact cover, first chapter, and densest Body grayscale samples."""
    pages = _sorted_pages(page_paths)
    with pdfplumber.open(pdf_path) as opened:
        texts = tuple(page.extract_text() or "" for page in opened.pages)
    if len(pages) != len(texts):
        raise ValueError("rendered page count does not match PDF for grayscale samples")
    chapter_index = next(
        (
            index
            for index, text in enumerate(texts)
            if _normalized_text("UNIFIED SCORE · 0—4") in _normalized_text(text)
        ),
        None,
    )
    if chapter_index is None:
        raise ValueError("chapter marker UNIFIED SCORE · 0—4 was not found")
    candidates = [
        index
        for index in range(len(pages))
        if index not in {0, chapter_index}
    ]
    if not candidates:
        raise ValueError("dense Body sample requires a non-cover, non-chapter page")
    dense_index = max(candidates, key=lambda index: len(_normalized_text(texts[index])))
    output_dir = _prepare_empty_directory(Path(output_dir))
    selections = {
        "cover": 0,
        "chapter": chapter_index,
        "dense-body": dense_index,
    }
    results: dict[str, Path] = {}
    for name, index in selections.items():
        destination = output_dir / f"{name}.png"
        with Image.open(pages[index]) as source:
            source.convert("L").save(destination)
        results[name] = destination
    return results


def _footer_crossing(image: Image.Image) -> bool:
    grayscale = image.convert("L")
    width, height = grayscale.size
    safe_y = int(round(height * (1 - 17 / 297)))
    margin = max(5, int(round(height * 0.01)))
    top = max(0, safe_y - margin)
    bottom = min(height, safe_y + margin + 1)
    pixels = grayscale.load()
    dark = {
        (x, y)
        for y in range(top, bottom)
        for x in range(width)
        if pixels[x, y] < 80
    }
    while dark:
        start = dark.pop()
        stack = [start]
        min_y = max_y = start[1]
        size = 1
        while stack:
            x, y = stack.pop()
            for neighbor in (
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1),
                (x - 1, y - 1),
                (x + 1, y - 1),
                (x - 1, y + 1),
                (x + 1, y + 1),
            ):
                if neighbor in dark:
                    dark.remove(neighbor)
                    stack.append(neighbor)
                    min_y = min(min_y, neighbor[1])
                    max_y = max(max_y, neighbor[1])
                    size += 1
        if size >= 4 and min_y < safe_y <= max_y:
            return True
    return False


def screen_rendered_pages(
    page_paths: Sequence[Path],
    *,
    report_path: Path = SCREENING_REPORT_PATH,
) -> dict[str, object]:
    """Write conservative advisory metrics; human review remains mandatory."""
    pages = _sorted_pages(page_paths)
    if not pages:
        raise ValueError("screening requires at least one rendered page")
    dimensions: list[dict[str, int]] = []
    near_white_ratio: list[dict[str, float | int]] = []
    near_black_ratio: list[dict[str, float | int]] = []
    footer_crossing_candidates: list[int] = []
    baseline_size: tuple[int, int] | None = None
    dimension_mismatch_pages: list[int] = []
    for path in pages:
        page_number = _page_number(path)
        with Image.open(path) as source:
            image = source.convert("RGB")
            width, height = image.size
            grayscale = image.convert("L")
            histogram = grayscale.histogram()
            pixel_count = width * height
            white = sum(histogram[245:])
            black = sum(histogram[:11])
            crosses_footer = _footer_crossing(image)
        size = (width, height)
        if baseline_size is None:
            baseline_size = size
        elif size != baseline_size:
            dimension_mismatch_pages.append(page_number)
        dimensions.append({"page": page_number, "width": width, "height": height})
        near_white_ratio.append(
            {"page": page_number, "ratio": round(white / pixel_count, 8)}
        )
        near_black_ratio.append(
            {"page": page_number, "ratio": round(black / pixel_count, 8)}
        )
        if crosses_footer:
            footer_crossing_candidates.append(page_number)

    low_text_pages: list[int] = []
    render_manifest = pages[0].parent / "render-manifest.json"
    if render_manifest.is_file():
        manifest = json.loads(render_manifest.read_text(encoding="utf-8"))
        source_pdf = Path(str(manifest.get("source_pdf", "")))
        if source_pdf.is_file():
            with pdfplumber.open(source_pdf) as opened:
                text_counts = [
                    len(_normalized_text(page.extract_text() or ""))
                    for page in opened.pages
                ]
            low_text_pages = [
                page_number
                for page_number, count in enumerate(text_counts, start=1)
                if count < 100
            ]

    suspicious_pages = sorted(
        set(
            footer_crossing_candidates
            + low_text_pages
            + dimension_mismatch_pages
        )
    )
    report: dict[str, object] = {
        "page_count": len(pages),
        "dimensions": dimensions,
        "near_white_ratio": near_white_ratio,
        "near_black_ratio": near_black_ratio,
        "footer_crossing_candidates": sorted(set(footer_crossing_candidates)),
        "low_text_pages": sorted(set(low_text_pages)),
        "dimension_mismatch_pages": sorted(set(dimension_mismatch_pages)),
        "suspicious_pages": suspicious_pages,
        "note": (
            "Advisory screening only; does not replace human contact-sheet "
            "inspection."
        ),
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report
