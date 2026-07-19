import tempfile
import unittest
from pathlib import Path

from PIL import Image

from validate_assets import validate


APPROVED_PALETTE = [
    "#120D24",
    "#6D28D9",
    "#7C3AED",
    "#BE185D",
    "#EC4899",
    "#22D3EE",
    "#F5F3FF",
]


def _manifest(
    *,
    png: dict | None = None,
    svg: dict | None = None,
) -> dict:
    return {
        "palette": APPROVED_PALETTE,
        "png": png or {},
        "svg": svg or {},
    }


def _svg_contract(*, max_colors: int = 3) -> dict:
    return {
        "viewBox": "0 0 24 24",
        "maxColors": max_colors,
        "minStrokeWidth": 1.75,
    }


class ValidateAssetsTest(unittest.TestCase):
    def test_valid_png_and_svg_contracts_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGB", (32, 32), "#120D24").save(root / "sample.png")
            (root / "sample.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'viewBox="0 0 24 24"><title>Sample</title>'
                '<circle cx="12" cy="12" r="5" fill="none" '
                'stroke="#22D3EE" stroke-width="1.8"/>'
                '<path d="M4 12h16" fill="none" stroke="#7C3AED" '
                'stroke-width="1.8" stroke-linecap="round"/></svg>',
                encoding="utf-8",
            )
            manifest = _manifest(
                png={
                    "sample.png": {
                        "width": 32,
                        "height": 32,
                        "opaque": True,
                    }
                },
                svg={"sample.svg": _svg_contract()},
            )

            self.assertEqual([], validate(root, manifest))

    def test_only_filter_and_contract_errors_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGBA", (31, 32), (0, 0, 0, 0)).save(root / "bad.png")
            manifest = _manifest(
                png={
                    "bad.png": {"width": 32, "height": 32, "opaque": True},
                    "ignored.png": {"width": 1, "height": 1, "opaque": True},
                }
            )

            errors = validate(root, manifest, only={"bad.png"})

            self.assertTrue(any("expected 32x32" in error for error in errors))
            self.assertTrue(any("must be opaque" in error for error in errors))
            self.assertFalse(any("ignored.png" in error for error in errors))

    def test_unknown_only_filename_is_rejected(self) -> None:
        manifest = _manifest(
            png={"known.png": {"width": 1, "height": 1, "opaque": True}}
        )

        errors = validate(Path("unused"), manifest, only={"unknown.png"})

        self.assertEqual(["unknown.png: unknown asset in only filter"], errors)

    def test_png_requires_png_container_format(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGB", (8, 8), "#120D24").save(
                root / "renamed.png", format="JPEG"
            )
            manifest = _manifest(
                png={
                    "renamed.png": {"width": 8, "height": 8, "opaque": True}
                }
            )

            errors = validate(root, manifest)

            self.assertIn("renamed.png: expected PNG format, got JPEG", errors)

    def test_palette_png_transparency_is_rejected_for_opaque_contract(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = Image.new("P", (8, 8), 0)
            image.putpalette([18, 13, 36] + [0, 0, 0] * 255)
            image.info["transparency"] = 0
            image.save(root / "palette.png", format="PNG")
            manifest = _manifest(
                png={
                    "palette.png": {"width": 8, "height": 8, "opaque": True}
                }
            )

            errors = validate(root, manifest)

            self.assertIn("palette.png: must be opaque", errors)

    def test_svg_rejects_style_element_and_attribute(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "styled.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<style>path { stroke: #7C3AED; }</style>'
                '<path d="M2 2h20" style="stroke:#7C3AED;stroke-width:2"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"styled.svg": _svg_contract()}),
            )

            self.assertIn("styled.svg: <style> is forbidden", errors)
            self.assertIn("styled.svg: style attribute is forbidden on <path>", errors)

    def test_svg_rejects_any_href_or_xlink_href(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "linked.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 24 24">'
                '<path d="M2 2h20" href="#local" fill="none" '
                'stroke="#7C3AED" stroke-width="1.8"/>'
                '<circle cx="12" cy="12" r="4" xlink:href="file:///tmp/a.svg" '
                'fill="none" stroke="#22D3EE" stroke-width="1.8"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"linked.svg": _svg_contract()}),
            )

            self.assertEqual(2, sum("href is forbidden" in error for error in errors))

    def test_svg_rejects_visible_stroke_without_explicit_width(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "implicit.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<path d="M2 2h20" fill="none" stroke="#7C3AED" '
                'stroke-width="1.8"/>'
                '<path d="M2 4h20" fill="none" stroke="#22D3EE"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"implicit.svg": _svg_contract()}),
            )

            self.assertIn(
                "implicit.svg: visible stroke on <path> requires explicit stroke-width",
                errors,
            )

    def test_svg_rejects_non_allowlisted_elements_and_attributes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "unsafe.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<rect x="2" y="2" width="20" height="20" fill="#120D24"/>'
                '<path d="M2 2h20" fill="none" stroke="#7C3AED" '
                'stroke-width="1.8" transform="translate(1 1)"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"unsafe.svg": _svg_contract()}),
            )

            self.assertIn("unsafe.svg: <rect> is not allowlisted", errors)
            self.assertIn(
                "unsafe.svg: attribute 'transform' is not allowlisted on <path>",
                errors,
            )

    def test_svg_rejects_non_allowlisted_paint_values(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "paint.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<path d="M2 2h20" fill="currentColor" stroke="none"/>'
                '<circle cx="12" cy="12" r="4" fill="none" '
                'stroke="url(#paint)" stroke-width="1.8"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"paint.svg": _svg_contract()}),
            )

            self.assertIn(
                "paint.svg: fill value 'currentColor' is not allowlisted on <path>",
                errors,
            )
            self.assertIn(
                "paint.svg: stroke value 'url(#paint)' is not allowlisted on <circle>",
                errors,
            )

    def test_svg_rejects_hex_colors_outside_approved_palette(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "off-palette.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<path d="M2 2h20" fill="#010203" stroke="none"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(svg={"off-palette.svg": _svg_contract()}),
            )

            self.assertIn(
                "off-palette.svg: fill color #010203 is outside the approved palette",
                errors,
            )

    def test_svg_enforces_per_file_max_colors_with_approved_palette(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "color-overflow.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<path d="M2 2h20" fill="#120D24" stroke="#7C3AED" '
                'stroke-width="1.8"/>'
                '<circle cx="12" cy="12" r="4" fill="#22D3EE" '
                'stroke="#EC4899" stroke-width="1.8"/>'
                "</svg>",
                encoding="utf-8",
            )

            errors = validate(
                root,
                _manifest(
                    svg={"color-overflow.svg": _svg_contract(max_colors=3)}
                ),
            )

            self.assertIn("color-overflow.svg: uses 4 colors, max is 3", errors)


if __name__ == "__main__":
    unittest.main()
