import contextlib
import io
import json
import shutil
import struct
import subprocess
import sys
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

    def test_android_reports_corrupt_launcher_without_traceback(self):
        with self._generated_android_root() as root:
            path = (
                root
                / "chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
            )
            path.write_bytes(b"not a PNG")

            errors = validate_platform(root, "android")

            self.assertTrue(
                any(
                    "unable to decode Android launcher" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_cli_returns_nonzero_without_traceback_for_corrupt_input(self):
        with self._generated_android_root() as root:
            path = (
                root
                / "chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
            )
            path.write_bytes(b"not a PNG")

            result = self._run_validator_cli(root, "android")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unable to decode Android launcher", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_ios_cli_rejects_infinite_catalog_size_without_traceback(self):
        with self._generated_platform_root("ios") as root:
            path = self._app_icon_base(root, "ios") / "Contents.json"
            contents = json.loads(path.read_text(encoding="utf-8"))
            contents["images"][0]["size"] = "Infinity"
            path.write_text(json.dumps(contents), encoding="utf-8")

            result = self._run_validator_cli(root, "ios")
            output = result.stdout + result.stderr

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("iOS catalog record is malformed", result.stderr)
            self.assertIn("size and scale must be finite", result.stderr)
            self.assertIn(str(path), result.stderr)
            self.assertNotIn("Traceback", output)

    def test_web_cli_rejects_deep_manifest_without_traceback(self):
        with self._generated_web_root() as root:
            path = root / "chatgpt_flutter/web/manifest.json"
            path.write_text("[" * 10_000 + "0" + "]" * 10_000, encoding="utf-8")

            result = self._run_validator_cli(root, "web")
            output = result.stdout + result.stderr

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("unable to parse Web manifest", result.stderr)
            self.assertIn(str(path), result.stderr)
            self.assertNotIn("Traceback", output)

    def test_android_reports_missing_manifest_without_traceback(self):
        with self._generated_android_root() as root:
            path = root / "chatgpt_flutter/android/app/src/main/AndroidManifest.xml"
            path.unlink()

            errors = validate_platform(root, "android")

            self.assertTrue(
                any(
                    "unable to read Android manifest" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_ios_reports_malformed_catalog_json_without_traceback(self):
        with self._generated_platform_root("ios") as root:
            path = self._app_icon_base(root, "ios") / "Contents.json"
            path.write_text("{not-json", encoding="utf-8")

            errors = validate_platform(root, "ios")

            self.assertTrue(
                any(
                    "unable to parse iOS icon catalog" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_ios_reports_malformed_catalog_schema_without_traceback(self):
        with self._generated_platform_root("ios") as root:
            path = self._app_icon_base(root, "ios") / "Contents.json"
            path.write_text(json.dumps({"images": {"filename": "bad.png"}}))

            errors = validate_platform(root, "ios")

            self.assertTrue(
                any(
                    "iOS icon catalog images must be a list" in error
                    for error in errors
                ),
                errors,
            )

    def test_ios_reports_invalid_size_conversion_without_traceback(self):
        with self._generated_platform_root("ios") as root:
            path = self._app_icon_base(root, "ios") / "Contents.json"
            contents = json.loads(path.read_text(encoding="utf-8"))
            contents["images"][0]["size"] = "not-a-size"
            path.write_text(json.dumps(contents), encoding="utf-8")

            errors = validate_platform(root, "ios")

            self.assertTrue(
                any(
                    "iOS catalog record is malformed" in error
                    and "icon-20@2x.png" in error
                    for error in errors
                ),
                errors,
            )

    def test_macos_reports_missing_catalog_without_traceback(self):
        with self._generated_platform_root("macos") as root:
            path = self._app_icon_base(root, "macos") / "Contents.json"
            path.unlink()

            errors = validate_platform(root, "macos")

            self.assertTrue(
                any(
                    "unable to read macOS icon catalog" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_macos_reports_malformed_catalog_record_without_traceback(self):
        with self._generated_platform_root("macos") as root:
            path = self._app_icon_base(root, "macos") / "Contents.json"
            path.write_text(json.dumps({"images": [{"filename": "bad.png"}]}))

            errors = validate_platform(root, "macos")

            self.assertTrue(
                any(
                    "macOS icon catalog record 0 is malformed" in error
                    for error in errors
                ),
                errors,
            )

    def test_web_reports_missing_index_without_traceback(self):
        with self._generated_web_root() as root:
            path = root / "chatgpt_flutter/web/index.html"
            path.unlink()

            errors = validate_platform(root, "web")

            self.assertTrue(
                any(
                    "unable to read Web index" in error and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_web_reports_malformed_manifest_schema_without_traceback(self):
        with self._generated_web_root() as root:
            path = root / "chatgpt_flutter/web/manifest.json"
            path.write_text(json.dumps([{"icons": []}]), encoding="utf-8")

            errors = validate_platform(root, "web")

            self.assertTrue(
                any("Web manifest must be a JSON object" in error for error in errors),
                errors,
            )

    def test_ohos_reports_missing_app_config_without_traceback(self):
        with self._generated_ohos_root() as root:
            path = root / "chatgpt_flutter_ohos/ohos/AppScope/app.json5"
            path.unlink()

            errors = validate_platform(root, "ohos")

            self.assertTrue(
                any(
                    "unable to read HarmonyOS AppScope config" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_ohos_reports_malformed_module_text_without_traceback(self):
        with self._generated_ohos_root() as root:
            path = (
                root
                / "chatgpt_flutter_ohos/ohos/entry/src/main/module.json5"
            )
            path.write_bytes(b"\xff\xfe\xfa")

            errors = validate_platform(root, "ohos")

            self.assertTrue(
                any(
                    "unable to read HarmonyOS entry config" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

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

    def test_windows_reports_malformed_runner_rc_without_traceback(self):
        with self._generated_windows_root() as root:
            path = root / "chatgpt_flutter/windows/runner/Runner.rc"
            path.write_bytes(b"\xff\xfe\xfa")

            errors = validate_platform(root, "windows")

            self.assertTrue(
                any(
                    "unable to read Windows Runner.rc" in error
                    and str(path) in error
                    for error in errors
                ),
                errors,
            )

    def test_windows_reports_corrupt_master_once_with_correct_attribution(self):
        with self._generated_windows_root() as root:
            master = self._master_path(root)
            master.write_bytes(b"not a PNG")

            errors = validate_platform(root, "windows")

            master_errors = [error for error in errors if "Starcore master" in error]
            self.assertEqual(len(master_errors), 1, errors)
            self.assertIn(str(master), master_errors[0])
            self.assertFalse(
                any("PNG payload cannot be decoded" in error for error in errors),
                errors,
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

    def test_web_reports_corrupt_master_once(self):
        with self._generated_web_root() as root:
            master = self._master_path(root)
            master.write_bytes(b"not a PNG")

            errors = validate_platform(root, "web")

            master_errors = [error for error in errors if "Starcore master" in error]
            self.assertEqual(len(master_errors), 1, errors)
            self.assertIn(str(master), master_errors[0])

    @contextlib.contextmanager
    def _generated_android_root(self):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            self._copy_master(root)
            manifest = root / "chatgpt_flutter/android/app/src/main/AndroidManifest.xml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '<application android:icon="@mipmap/ic_launcher" />',
                encoding="utf-8",
            )
            generate_platform(root, "android")
            yield root

    @contextlib.contextmanager
    def _generated_platform_root(self, platform: str):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            self._copy_master(root)
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
            self._copy_master(root)
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
    def _generated_ohos_root(self):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            self._copy_master(root)
            app_config = root / "chatgpt_flutter_ohos/ohos/AppScope/app.json5"
            app_config.parent.mkdir(parents=True)
            app_config.write_text('{"icon": "$media:app_icon"}', encoding="utf-8")
            module_config = (
                root
                / "chatgpt_flutter_ohos/ohos/entry/src/main/module.json5"
            )
            module_config.parent.mkdir(parents=True)
            module_config.write_text(
                '{"icon": "$media:icon", "startWindowIcon": "$media:icon"}',
                encoding="utf-8",
            )
            generate_platform(root, "ohos")
            yield root

    @contextlib.contextmanager
    def _generated_windows_root(self):
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            self._copy_master(root)
            runner = root / "chatgpt_flutter/windows/runner"
            runner.mkdir(parents=True)
            (runner / "Runner.rc").write_text(
                'IDI_APP_ICON ICON "resources\\\\app_icon.ico"\n',
                encoding="utf-8",
            )
            generate_platform(root, "windows")
            yield root

    @staticmethod
    def _copy_master(root: Path) -> None:
        guide = root / "docs/design-assets/starcore-guide"
        guide.mkdir(parents=True)
        shutil.copy2(
            ROOT / "docs/design-assets/starcore-guide/app-icon-concept.png",
            guide,
        )

    @staticmethod
    def _master_path(root: Path) -> Path:
        return root / "docs/design-assets/starcore-guide/app-icon-concept.png"

    @staticmethod
    def _run_validator_cli(root: Path, platform: str):
        return subprocess.run(
            [
                sys.executable,
                str(
                    ROOT
                    / "docs/design-assets/starcore-guide/validate_runtime_icons.py"
                ),
                "--platform",
                platform,
                "--root",
                str(root),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

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
