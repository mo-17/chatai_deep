import shutil
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from generate_runtime_icons import (
    MASTER_SHA256,
    generate_platform,
    rounded_icon,
    square_icon,
)


HERE = Path(__file__).resolve().parent
MASTER = HERE / "app-icon-concept.png"


class RuntimeIconGeneratorTest(unittest.TestCase):
    def test_master_contract_and_basic_compositions(self):
        source = square_icon(MASTER, 48)
        rounded = rounded_icon(MASTER, 64, inset_ratio=0.08)
        self.assertEqual(
            MASTER_SHA256,
            "7c0b970374eae122f7f1a090c7a2d185873d3834207056547802d6fa9d1cb6f7",
        )
        self.assertEqual(source.size, (48, 48))
        self.assertEqual(source.mode, "RGB")
        self.assertEqual(rounded.size, (64, 64))
        self.assertEqual(rounded.mode, "RGBA")
        self.assertEqual(rounded.getpixel((0, 0))[3], 0)

    def test_all_platforms_generate_into_an_isolated_root(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            master = root / "docs/design-assets/starcore-guide/app-icon-concept.png"
            master.parent.mkdir(parents=True)
            shutil.copy2(MASTER, master)
            for platform in ("android", "ios", "macos", "windows", "web", "ohos"):
                generate_platform(root, platform)
            self.assertTrue(
                (
                    root
                    / "chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
                ).is_file()
            )
            self.assertTrue(
                (
                    root
                    / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
                ).is_file()
            )
            self.assertTrue(
                (
                    root
                    / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
                ).is_file()
            )
            self.assertTrue(
                (root / "chatgpt_flutter/windows/runner/resources/app_icon.ico").is_file()
            )
            self.assertTrue(
                (root / "chatgpt_flutter/web/icons/Icon-maskable-512.png").is_file()
            )
            self.assertTrue(
                (
                    root
                    / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png"
                ).is_file()
            )
            with Image.open(root / "chatgpt_flutter/windows/runner/resources/app_icon.ico") as icon:
                self.assertEqual(
                    set(icon.ico.sizes()),
                    {(16, 16), (32, 32), (48, 48), (256, 256)},
                )

    def test_unknown_platform_is_rejected_by_dispatch(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(KeyError):
                generate_platform(Path(raw), "linux")


if __name__ == "__main__":
    unittest.main()
