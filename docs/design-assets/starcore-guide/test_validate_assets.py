import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from validate_assets import validate


class ValidateAssetsTest(unittest.TestCase):
    def test_valid_png_and_svg_contracts_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGB", (32, 32), "#120D24").save(root / "sample.png")
            (root / "sample.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'viewBox="0 0 24 24"><title>Sample</title>'
                '<path d="M4 12h16" stroke="#7C3AED" stroke-width="1.8"/></svg>',
                encoding="utf-8",
            )
            manifest = {
                "png": {
                    "sample.png": {
                        "width": 32,
                        "height": 32,
                        "opaque": True,
                    }
                },
                "svg": {
                    "sample.svg": {
                        "viewBox": "0 0 24 24",
                        "maxColors": 3,
                        "minStrokeWidth": 1.75,
                    }
                },
            }

            self.assertEqual([], validate(root, manifest))

    def test_only_filter_and_contract_errors_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGBA", (31, 32), (0, 0, 0, 0)).save(root / "bad.png")
            manifest = {
                "png": {
                    "bad.png": {"width": 32, "height": 32, "opaque": True},
                    "ignored.png": {"width": 1, "height": 1, "opaque": True},
                },
                "svg": {},
            }

            errors = validate(root, manifest, only={"bad.png"})

            self.assertTrue(any("expected 32x32" in error for error in errors))
            self.assertTrue(any("must be opaque" in error for error in errors))
            self.assertFalse(any("ignored.png" in error for error in errors))

    def test_svg_rejects_text_external_links_color_overflow_and_thin_strokes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bad.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 24 24">'
                '<text>bad</text><image xlink:href="https://example.com/a.png"/>'
                '<path d="M2 2h20" fill="#111111" stroke="#222222" '
                'stroke-width="1"/><path d="M2 4h20" fill="#333333" '
                'stroke="#444444" stroke-width="2"/></svg>',
                encoding="utf-8",
            )
            manifest = {
                "png": {},
                "svg": {
                    "bad.svg": {
                        "viewBox": "0 0 24 24",
                        "maxColors": 3,
                        "minStrokeWidth": 1.75,
                    }
                },
            }

            errors = validate(root, manifest)

            self.assertTrue(any("<text> is forbidden" in error for error in errors))
            self.assertTrue(any("external href is forbidden" in error for error in errors))
            self.assertTrue(any("uses 4 colors" in error for error in errors))
            self.assertTrue(any("below 1.75" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
