import unittest
from pathlib import Path

from validate_runtime_icons import validate_platform


ROOT = Path(__file__).resolve().parents[3]


class RuntimeIconRepositoryTest(unittest.TestCase):
    def test_android(self):
        self.assertEqual(validate_platform(ROOT, "android"), [])

    def test_ios(self):
        self.assertEqual(validate_platform(ROOT, "ios"), [])

    def test_macos(self):
        self.assertEqual(validate_platform(ROOT, "macos"), [])


if __name__ == "__main__":
    unittest.main()
