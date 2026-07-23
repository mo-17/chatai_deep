"""Isolated Poppler rendering and advisory visual-review evidence."""

from __future__ import annotations

import argparse
import json
from hashlib import sha256
from pathlib import Path
import re
import subprocess
import unicodedata
from typing import Iterable, Mapping, Sequence

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


def _sorted_pages(
    page_paths: Iterable[Path],
    *,
    expected_count: int | None = None,
) -> list[Path]:
    pages = sorted((Path(path) for path in page_paths), key=_page_number)
    numbers = [_page_number(path) for path in pages]
    if len(numbers) != len(set(numbers)):
        raise ValueError("rendered page numbers must be unique")
    count = len(pages) if expected_count is None else expected_count
    if numbers != list(range(1, count + 1)):
        raise ValueError(
            "rendered page numbers must be contiguous from 1 through "
            f"{count}: actual {numbers}"
        )
    return pages


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_identity(manifest: Mapping[str, object]) -> dict[str, object]:
    return {
        key: manifest[key]
        for key in (
            "source_pdf",
            "pdf_sha256",
            "page_count",
            "dpi",
            "dimensions",
            "page_files",
            "page_numbers",
        )
    }


def _validate_render_set(
    page_paths: Sequence[Path],
    *,
    pdf_path: Path | None = None,
) -> tuple[list[Path], dict[str, object]]:
    pages = _sorted_pages(page_paths)
    if not pages:
        raise ValueError("rendered page set must not be empty")
    parent = pages[0].parent
    if any(path.parent != parent for path in pages):
        raise ValueError("rendered pages must share one directory")
    manifest_path = parent / "render-manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"render manifest is required: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"render manifest must be valid JSON: {manifest_path}") from error
    if not isinstance(manifest, dict):
        raise ValueError("render manifest must be a JSON object")

    source_value = manifest.get("source_pdf")
    if not isinstance(source_value, str) or not source_value:
        raise ValueError("render manifest source_pdf must be an absolute canonical path")
    source_pdf = Path(source_value)
    if not source_pdf.is_absolute():
        raise ValueError("render manifest source_pdf must be an absolute canonical path")
    try:
        canonical_source = source_pdf.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"render manifest source PDF is unavailable: {source_pdf}") from error
    if canonical_source != source_pdf:
        raise ValueError("render manifest source_pdf must be an absolute canonical path")
    if pdf_path is not None and Path(pdf_path).resolve(strict=True) != canonical_source:
        raise ValueError("render manifest source PDF does not match the requested PDF")

    expected_sha = manifest.get("pdf_sha256")
    actual_sha = _file_sha256(canonical_source)
    if expected_sha != actual_sha:
        raise ValueError(
            f"render manifest PDF SHA256 mismatch: {expected_sha!r} != {actual_sha!r}"
        )
    try:
        actual_pdf_page_count = len(PdfReader(canonical_source).pages)
    except Exception as error:
        raise ValueError(f"render manifest source PDF is unreadable: {canonical_source}") from error
    page_count = manifest.get("page_count")
    if (
        not isinstance(page_count, int)
        or isinstance(page_count, bool)
        or page_count <= 0
        or page_count != actual_pdf_page_count
    ):
        raise ValueError(
            "render manifest page_count does not match the source PDF: "
            f"{page_count!r} != {actual_pdf_page_count}"
        )
    pages = _sorted_pages(pages, expected_count=page_count)
    directory_pages = _sorted_pages(
        parent.glob("page-*.png"),
        expected_count=page_count,
    )
    if [path.name for path in directory_pages] != [path.name for path in pages]:
        raise ValueError("passed rendered pages do not match the render directory")
    page_numbers = [_page_number(path) for path in pages]
    page_files = [path.name for path in pages]
    if manifest.get("page_numbers") != page_numbers:
        raise ValueError("render manifest page_numbers do not match passed PNGs")
    if manifest.get("page_files") != page_files:
        raise ValueError("render manifest page_files do not match passed PNGs")
    dpi = manifest.get("dpi")
    if not isinstance(dpi, int) or isinstance(dpi, bool) or dpi <= 0:
        raise ValueError("render manifest dpi must be a positive integer")
    dimensions_value = manifest.get("dimensions")
    if (
        not isinstance(dimensions_value, list)
        or len(dimensions_value) != 2
        or any(
            not isinstance(value, int)
            or isinstance(value, bool)
            or value <= 0
            for value in dimensions_value
        )
    ):
        raise ValueError("render manifest dimensions must contain two positive integers")
    expected_dimensions = tuple(dimensions_value)
    for path in pages:
        try:
            with Image.open(path) as image:
                image.load()
                actual_dimensions = image.size
        except Exception as error:
            raise ValueError(f"unreadable rendered page: {path}") from error
        if actual_dimensions != expected_dimensions:
            raise ValueError(
                "rendered page dimensions do not match render manifest: "
                f"{path.name} {actual_dimensions} != {expected_dimensions}"
            )
    return pages, manifest


def _prepare_empty_directory(path: Path) -> Path:
    path = Path(path)
    _require_empty_or_missing_directory(path)
    if not path.exists():
        path.mkdir(parents=True)
    return path


def _require_empty_or_missing_directory(path: Path) -> None:
    path = Path(path)
    if not path.exists():
        return
    if not path.is_dir():
        raise ValueError(f"output path is not a directory: {path}")
    if any(path.iterdir()):
        raise ValueError(f"output directory must be empty: {path}")


def _paths_overlap(left: Path, right: Path) -> bool:
    return (
        left == right
        or left in right.parents
        or right in left.parents
    )


def _preflight_cli_evidence_paths(
    render_dir: Path,
    contact_dir: Path,
    grayscale_dir: Path,
    screening_report: Path,
) -> tuple[Path, Path, Path, Path]:
    raw_directories = tuple(
        Path(path)
        for path in (render_dir, contact_dir, grayscale_dir)
    )
    directories = tuple(
        path.resolve(strict=False)
        for path in raw_directories
    )
    report_path = Path(screening_report)
    canonical_report = report_path.resolve(strict=False)
    for index, left in enumerate(directories):
        for right in directories[index + 1:]:
            if _paths_overlap(left, right):
                raise ValueError(
                    "evidence directories must be disjoint: "
                    f"{left} and {right}"
                )
    if any(
        _paths_overlap(canonical_report, directory)
        for directory in directories
    ):
        raise ValueError(
            "screening report must be outside evidence directories: "
            f"{canonical_report}"
        )
    for raw_path, canonical_path in zip(raw_directories, directories):
        if (
            raw_path.exists()
            or raw_path.is_symlink()
            or canonical_path.exists()
        ):
            raise ValueError(
                "evidence directory must not already exist: "
                f"{canonical_path}"
            )
    if (
        report_path.exists()
        or report_path.is_symlink()
        or canonical_report.exists()
    ):
        raise ValueError(
            f"screening report must not already exist: {canonical_report}"
        )
    return (*directories, canonical_report)


def _normalized_text(value: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value))


def render_pages_with_poppler(
    pdf_path: Path,
    output_dir: Path,
    dpi: int = 144,
) -> list[Path]:
    """Render one readable, consistently sized PNG per PDF page."""
    pdf_path = Path(pdf_path).resolve(strict=True)
    output_dir = _prepare_empty_directory(Path(output_dir))
    if dpi <= 0:
        raise ValueError("dpi must be positive")
    expected_page_count = len(PdfReader(pdf_path).pages)
    try:
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
    except FileNotFoundError as error:
        raise RuntimeError("Poppler pdftoppm executable is unavailable") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or str(error)).strip()
        raise RuntimeError(f"Poppler rendering failed: {detail}") from error
    pages = _sorted_pages(
        output_dir.glob("page-*.png"),
        expected_count=expected_page_count,
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
        "schema_version": 1,
        "source_pdf": str(pdf_path.resolve()),
        "pdf_sha256": _file_sha256(pdf_path),
        "dpi": dpi,
        "page_count": expected_page_count,
        "page_files": [path.name for path in pages],
        "page_numbers": [_page_number(path) for path in pages],
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
    pages, render_manifest = _validate_render_set(page_paths)
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
        "render_identity": _manifest_identity(render_manifest),
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
    pages, render_manifest = _validate_render_set(
        page_paths,
        pdf_path=Path(pdf_path),
    )
    source_pdf = Path(str(render_manifest["source_pdf"]))
    with pdfplumber.open(source_pdf) as opened:
        texts = tuple(page.extract_text() or "" for page in opened.pages)
    chapter_indices = tuple(
        index
        for index, text in enumerate(texts)
        if _normalized_text("UNIFIED SCORE · 0—4") in _normalized_text(text)
    )
    if not chapter_indices:
        raise ValueError("chapter marker UNIFIED SCORE · 0—4 was not found")
    chapter_index = chapter_indices[0]
    candidates = [
        index
        for index in range(len(pages))
        if index != 0 and index not in chapter_indices
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
    manifest = {
        "render_identity": _manifest_identity(render_manifest),
        "selections": {
            name: index + 1
            for name, index in selections.items()
        },
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
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
    report_path = Path(report_path)
    if report_path.exists() or report_path.is_symlink():
        raise ValueError(
            f"screening report must not already exist: {report_path}"
        )
    pages, render_manifest = _validate_render_set(page_paths)
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

    source_pdf = Path(str(render_manifest["source_pdf"]))
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
        "render_identity": _manifest_identity(render_manifest),
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
    report_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with report_path.open("x", encoding="utf-8") as handle:
            handle.write(
                json.dumps(report, ensure_ascii=False, indent=2) + "\n"
            )
    except FileExistsError as error:
        raise ValueError(
            f"screening report must not already exist: {report_path}"
        ) from error
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--render-dir", required=True, type=Path)
    parser.add_argument("--contact-dir", required=True, type=Path)
    parser.add_argument("--grayscale-dir", required=True, type=Path)
    parser.add_argument("--screening-report", required=True, type=Path)
    parser.add_argument("--dpi", default=144, type=int)
    args = parser.parse_args(argv)

    (
        render_dir,
        contact_dir,
        grayscale_dir,
        screening_report,
    ) = _preflight_cli_evidence_paths(
        args.render_dir,
        args.contact_dir,
        args.grayscale_dir,
        args.screening_report,
    )

    pages = render_pages_with_poppler(
        args.pdf,
        render_dir,
        dpi=args.dpi,
    )
    contact_sheets = build_contact_sheets(
        pages,
        contact_dir,
        pages_per_sheet=12,
    )
    grayscale_samples = build_grayscale_samples(
        args.pdf,
        pages,
        grayscale_dir,
    )
    screening = screen_rendered_pages(
        pages,
        report_path=screening_report,
    )
    identity = screening["render_identity"]
    summary = {
        "source_pdf": identity["source_pdf"],
        "pdf_sha256": identity["pdf_sha256"],
        "page_count": identity["page_count"],
        "rendered_pages": len(pages),
        "contact_sheets": len(contact_sheets),
        "grayscale_samples": sorted(grayscale_samples),
        "screening_report": str(screening_report),
        "suspicious_pages": screening["suspicious_pages"],
        "render_identity": identity,
    }
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
