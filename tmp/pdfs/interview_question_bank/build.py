"""CLI entry point for the formal Aipu interview question-bank PDF."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Mapping

from interview_question_bank.document import BuildReceipt, build_pdf


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
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    receipt = build_pdf(args.source, args.output)
    payload = write_build_receipt(receipt)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
