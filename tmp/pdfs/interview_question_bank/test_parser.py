from __future__ import annotations

import hashlib
from pathlib import Path
import unittest

from interview_question_bank.parser import parse_question_bank


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "project-interview-question-bank.md"


def expected_question_ids() -> list[str]:
    prefixes = ("C", "FE", "AI", "BE", "SEC", "PM", "QA", "OPS")
    return [f"{prefix}{number}" for prefix in prefixes for number in range(1, 11)]


class QuestionBankParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_full_document_shape(self) -> None:
        bank = parse_question_bank(self.source)
        self.assertEqual(12, len(bank.level2_sections))
        self.assertEqual(80, len(bank.questions))
        self.assertEqual(expected_question_ids(), [q.question_id for q in bank.questions])
        self.assertEqual(4, len(bank.tables))
        self.assertEqual(1, len(bank.code_blocks))

    def test_every_question_has_required_fields(self) -> None:
        bank = parse_question_bank(self.source)
        for question in bank.questions:
            self.assertTrue(question.prompt)
            for label in ("考察点", "答案要点", "追问", "风险信号", "评分锚点"):
                self.assertIn(label, question.answer_fields)
        self.assertNotIn("<details>", bank.searchable_text)
        self.assertNotIn("<summary>", bank.searchable_text)

    def test_summary_text_is_searchable_without_html_tags(self) -> None:
        bank = parse_question_bank(self.source)
        self.assertIn("参考答案、追问与评分", bank.searchable_text)
        self.assertNotIn("<summary>", bank.searchable_text)

    def test_question_identifiers_have_a_stable_digest(self) -> None:
        bank = parse_question_bank(self.source)
        digest = hashlib.sha256("\n".join(q.question_id for q in bank.questions).encode()).hexdigest()
        self.assertEqual(
            "edad9b93c6e6df009e3caa52a78f85254881ba8cade5c07f0838abe36dbb4ac8",
            digest,
        )


if __name__ == "__main__":
    unittest.main()
