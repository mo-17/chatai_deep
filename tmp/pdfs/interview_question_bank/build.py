"""CLI entry point for the formal Aipu interview question-bank PDF."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from interview_question_bank.document import build_pdf


ROOT = Path(__file__).resolve().parents[3]
RECEIPT_PATH = ROOT / "tmp" / "pdfs" / "build-receipt.json"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    receipt = build_pdf(args.source, args.output)
    RECEIPT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT_PATH.write_text(
        json.dumps(receipt.to_dict(), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(receipt.to_dict(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
