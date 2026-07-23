"""CLI entry point for the formal Aipu interview question-bank PDF."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
from tempfile import NamedTemporaryFile
from typing import Mapping

from interview_question_bank.document import BuildReceipt, build_pdf
from interview_question_bank.verify import verify_pdf


ROOT = Path(__file__).resolve().parents[3]
RECEIPT_PATH = ROOT / "tmp" / "pdfs" / "build-receipt.json"


def write_build_receipt(
    receipt: BuildReceipt | Mapping[str, object],
    destination: Path = RECEIPT_PATH,
) -> dict[str, object]:
    """Write the detailed receipt plus stable release-summary counts."""
    payload = (
        receipt.to_dict()
        if isinstance(receipt, BuildReceipt)
        else dict(receipt)
    )
    question_ids = payload.get("question_ids")
    bookmark_titles = payload.get("bookmark_titles")
    if not isinstance(question_ids, list):
        raise ValueError("receipt question_ids must be a list")
    if not isinstance(bookmark_titles, list):
        raise ValueError("receipt bookmark_titles must be a list")
    payload["question_count"] = len(question_ids)
    payload["section_count"] = len(bookmark_titles)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(destination, 0o644)
    return payload


def _temporary_release_path(destination: Path, suffix: str) -> Path:
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(
        prefix=f".{destination.name}.",
        suffix=suffix,
        dir=destination.parent,
        delete=False,
    ) as handle:
        return Path(handle.name)


def _backup_existing(destination: Path) -> Path | None:
    if not destination.exists():
        return None
    backup = _temporary_release_path(destination, ".backup")
    try:
        shutil.copy2(destination, backup)
        return backup
    except Exception:
        backup.unlink(missing_ok=True)
        raise


def _restore_release_file(
    destination: Path,
    backup: Path | None,
) -> None:
    if backup is None:
        destination.unlink(missing_ok=True)
        return
    os.replace(backup, destination)


def _publish_release_pair(
    candidate_pdf: Path,
    candidate_receipt: Path,
    output: Path,
    receipt_path: Path,
) -> None:
    pdf_backup: Path | None = None
    receipt_backup: Path | None = None
    receipt_published = False
    pdf_published = False
    preserve_pdf_backup = False
    preserve_receipt_backup = False
    try:
        pdf_backup = _backup_existing(output)
        receipt_backup = _backup_existing(receipt_path)
        os.replace(candidate_receipt, receipt_path)
        receipt_published = True
        os.replace(candidate_pdf, output)
        pdf_published = True
    except Exception as publish_error:
        rollback_errors: list[str] = []
        if pdf_published:
            try:
                _restore_release_file(output, pdf_backup)
                pdf_backup = None
            except Exception as error:
                preserve_pdf_backup = pdf_backup is not None
                rollback_errors.append(
                    f"PDF rollback failed: {error}; recovery backup: "
                    f"{pdf_backup or 'unavailable'}"
                )
        if receipt_published:
            try:
                _restore_release_file(receipt_path, receipt_backup)
                receipt_backup = None
            except Exception as error:
                preserve_receipt_backup = receipt_backup is not None
                rollback_errors.append(
                    f"receipt rollback failed: {error}; recovery backup: "
                    f"{receipt_backup or 'unavailable'}"
                )
        if rollback_errors:
            raise RuntimeError(
                "release publish failed and rollback was incomplete: "
                + "; ".join(rollback_errors)
            ) from publish_error
        raise
    finally:
        if pdf_backup is not None and not preserve_pdf_backup:
            pdf_backup.unlink(missing_ok=True)
        if receipt_backup is not None and not preserve_receipt_backup:
            receipt_backup.unlink(missing_ok=True)


def build_and_publish(
    source: Path,
    output: Path,
    *,
    receipt_path: Path = RECEIPT_PATH,
) -> dict[str, object]:
    """Build, verify and publish the PDF/receipt pair with rollback."""
    source = Path(source)
    output = Path(output)
    receipt_path = Path(receipt_path)
    candidate_pdf: Path | None = None
    candidate_receipt: Path | None = None
    try:
        candidate_pdf = _temporary_release_path(
            output,
            ".candidate.pdf",
        )
        candidate_receipt = _temporary_release_path(
            receipt_path,
            ".candidate.json",
        )
        receipt = build_pdf(source, candidate_pdf)
        os.chmod(candidate_pdf, 0o644)
        payload = write_build_receipt(receipt, candidate_receipt)
        verify_pdf(
            source,
            candidate_pdf,
            receipt_path=candidate_receipt,
        ).require_passed()
        _publish_release_pair(
            candidate_pdf,
            candidate_receipt,
            output,
            receipt_path,
        )
        return payload
    finally:
        if candidate_pdf is not None:
            candidate_pdf.unlink(missing_ok=True)
        if candidate_receipt is not None:
            candidate_receipt.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    payload = build_and_publish(args.source, args.output)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
