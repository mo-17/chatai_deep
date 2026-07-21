import contextlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageChops

from generate_runtime_icons import generate_platform
from validate_runtime_icons import validate_platform


ROOT = Path(__file__).resolve().parents[3]


class RuntimeIconRepositoryTest(unittest.TestCase):
    def test_android(self):
        self.assertEqual(validate_platform(ROOT, "android"), [])

    def test_ios(self):
        self.assertEqual(validate_platform(ROOT, "ios"), [])

    def test_macos(self):
        self.assertEqual(validate_platform(ROOT, "macos"), [])

    def test_ios_rejects_rgb_png_with_trns_transparency(self):
        with self._generated_platform_root("ios") as root:
            path = self._app_icon_base(root, "ios") / "icon-20@2x.png"
            with Image.open(path) as source:
                original = source.convert("RGB").copy()
            original.save(path, format="PNG", transparency=original.getpixel((0, 0)))
            with Image.open(path) as rewritten:
                self.assertEqual(rewritten.mode, "RGB")
                self.assertIn("transparency", rewritten.info)
                self.assertIsNone(
                    ImageChops.difference(rewritten.convert("RGB"), original).getbbox()
                )

            self.assertTrue(validate_platform(root, "ios"))

    def test_ios_rejects_duplicate_catalog_record(self):
        with self._generated_platform_root("ios") as root:
            contents_path = self._app_icon_base(root, "ios") / "Contents.json"
            contents = json.loads(contents_path.read_text(encoding="utf-8"))
            contents["images"].append(contents["images"][0].copy())
            contents_path.write_text(json.dumps(contents), encoding="utf-8")

            self.assertTrue(validate_platform(root, "ios"))

    def test_macos_rejects_missing_shared_filename_representation(self):
        with self._generated_platform_root("macos") as root:
            contents_path = self._app_icon_base(root, "macos") / "Contents.json"
            contents = json.loads(contents_path.read_text(encoding="utf-8"))
            contents["images"] = [
                item
                for item in contents["images"]
                if not (
                    item["filename"] == "app_icon_512.png"
                    and item["size"] == "512x512"
                    and item["scale"] == "1x"
                )
            ]
            contents_path.write_text(json.dumps(contents), encoding="utf-8")

            self.assertTrue(validate_platform(root, "macos"))

    @contextlib.contextmanager
    def _generated_platform_root(self, platform: str):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            guide = root / "docs/design-assets/starcore-guide"
            guide.mkdir(parents=True)
            shutil.copy2(ROOT / "docs/design-assets/starcore-guide/app-icon-concept.png", guide)
            source = self._app_icon_base(ROOT, platform)
            target = self._app_icon_base(root, platform)
            target.mkdir(parents=True)
            shutil.copy2(source / "Contents.json", target)
            generate_platform(root, platform)
            yield root

    @staticmethod
    def _app_icon_base(root: Path, platform: str) -> Path:
        return root / f"chatgpt_flutter/{platform}/Runner/Assets.xcassets/AppIcon.appiconset"


if __name__ == "__main__":
    unittest.main()
