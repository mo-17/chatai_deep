import contextlib
import io
import json
import shutil
import struct
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

    def test_windows(self):
        self.assertEqual(validate_platform(ROOT, "windows"), [])

    def test_web(self):
        self.assertEqual(validate_platform(ROOT, "web"), [])

    def test_ohos(self):
        self.assertEqual(validate_platform(ROOT, "ohos"), [])

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

    def test_web_rejects_duplicate_manifest_record(self):
        with self._generated_web_root() as root:
            manifest_path = root / "chatgpt_flutter/web/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["icons"].append(manifest["icons"][0].copy())
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertTrue(validate_platform(root, "web"))

    def test_windows_rejects_duplicate_approved_size_directory_entry(self):
        with self._generated_windows_root() as root:
            path = root / "chatgpt_flutter/windows/runner/resources/app_icon.ico"
            entries = self._read_ico_entries(path)
            entries.append(entries[0])
            self._write_ico_entries(path, entries)

            self.assertIn(
                "Windows ICO directory count differs: 5",
                validate_platform(root, "windows"),
            )

    def test_windows_rejects_non_rgba_png_payload(self):
        with self._generated_windows_root() as root:
            path = root / "chatgpt_flutter/windows/runner/resources/app_icon.ico"
            entries = self._read_ico_entries(path)
            index = next(index for index, entry in enumerate(entries) if entry[0] == 16)
            payload = self._palette_png(entries[index][-1])
            entries[index] = (*entries[index][:-1], payload)
            self._write_ico_entries(path, entries)

            self.assertIn(
                "Windows ICO PNG payload must be RGBA at 16px",
                validate_platform(root, "windows"),
            )

    def test_web_rejects_reordered_manifest_records(self):
        with self._generated_web_root() as root:
            manifest_path = root / "chatgpt_flutter/web/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["icons"].reverse()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertIn(
                "Web manifest icon records differ from expected records",
                validate_platform(root, "web"),
            )

    def test_web_rejects_manifest_record_with_altered_type(self):
        with self._generated_web_root() as root:
            manifest_path = root / "chatgpt_flutter/web/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["icons"][0]["type"] = "image/webp"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertIn(
                "Web manifest icon records differ from expected records",
                validate_platform(root, "web"),
            )

    def test_web_rejects_manifest_record_with_missing_type(self):
        with self._generated_web_root() as root:
            manifest_path = root / "chatgpt_flutter/web/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            del manifest["icons"][0]["type"]
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertIn(
                "Web manifest icon records differ from expected records",
                validate_platform(root, "web"),
            )

    def test_web_rejects_non_maskable_record_with_purpose(self):
        with self._generated_web_root() as root:
            manifest_path = root / "chatgpt_flutter/web/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["icons"][0]["purpose"] = "any"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertIn(
                "Web manifest icon records differ from expected records",
                validate_platform(root, "web"),
            )

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

    @contextlib.contextmanager
    def _generated_web_root(self):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            guide = root / "docs/design-assets/starcore-guide"
            guide.mkdir(parents=True)
            shutil.copy2(ROOT / "docs/design-assets/starcore-guide/app-icon-concept.png", guide)
            source = ROOT / "chatgpt_flutter/web"
            target = root / "chatgpt_flutter/web"
            target.mkdir(parents=True)
            shutil.copy2(source / "manifest.json", target)
            shutil.copy2(source / "index.html", target)
            generate_platform(root, "web")
            manifest_path = target / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["background_color"] = "#120D24"
            manifest["theme_color"] = "#6D28D9"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            yield root

    @contextlib.contextmanager
    def _generated_windows_root(self):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            guide = root / "docs/design-assets/starcore-guide"
            guide.mkdir(parents=True)
            shutil.copy2(ROOT / "docs/design-assets/starcore-guide/app-icon-concept.png", guide)
            runner = root / "chatgpt_flutter/windows/runner"
            runner.mkdir(parents=True)
            (runner / "Runner.rc").write_text(
                'IDI_APP_ICON ICON "resources\\\\app_icon.ico"\n',
                encoding="utf-8",
            )
            generate_platform(root, "windows")
            yield root

    @staticmethod
    def _read_ico_entries(path: Path):
        raw = path.read_bytes()
        reserved, kind, count = struct.unpack_from("<HHH", raw)
        if (reserved, kind) != (0, 1):
            raise AssertionError("test fixture must be a Windows ICO")
        entries = []
        for index in range(count):
            offset = 6 + index * 16
            width, height, colors, entry_reserved, planes, bpp, length, start = (
                struct.unpack_from("<BBBBHHII", raw, offset)
            )
            payload = raw[start : start + length]
            if len(payload) != length:
                raise AssertionError("test fixture ICO payload is truncated")
            entries.append(
                (width, height, colors, entry_reserved, planes, bpp, payload)
            )
        return entries

    @staticmethod
    def _write_ico_entries(path: Path, entries):
        offset = 6 + len(entries) * 16
        directory = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
        body = bytearray()
        for width, height, colors, reserved, planes, bpp, payload in entries:
            directory.extend(
                struct.pack(
                    "<BBBBHHII",
                    width,
                    height,
                    colors,
                    reserved,
                    planes,
                    bpp,
                    len(payload),
                    offset,
                )
            )
            body.extend(payload)
            offset += len(payload)
        path.write_bytes(bytes(directory + body))

    def _palette_png(self, rgba_payload: bytes) -> bytes:
        with Image.open(io.BytesIO(rgba_payload)) as source:
            source.load()
            image = source.convert("RGBA")
        pixels = list(image.get_flattened_data())
        colors = list(dict.fromkeys(pixels))
        self.assertLessEqual(len(colors), 256)
        indices = {color: index for index, color in enumerate(colors)}
        palette = Image.new("P", image.size)
        palette.putpalette(
            [component for color in colors for component in color[:3]]
            + [0] * (768 - len(colors) * 3)
        )
        palette.putdata([indices[color] for color in pixels])
        stream = io.BytesIO()
        palette.save(
            stream,
            format="PNG",
            transparency=bytes(color[3] for color in colors),
        )
        with Image.open(io.BytesIO(stream.getvalue())) as rewritten:
            rewritten.load()
            self.assertEqual(rewritten.mode, "P")
            self.assertIsNone(
                ImageChops.difference(rewritten.convert("RGBA"), image).getbbox(
                    alpha_only=False,
                )
            )
        return stream.getvalue()

    @staticmethod
    def _app_icon_base(root: Path, platform: str) -> Path:
        return root / f"chatgpt_flutter/{platform}/Runner/Assets.xcassets/AppIcon.appiconset"


if __name__ == "__main__":
    unittest.main()
