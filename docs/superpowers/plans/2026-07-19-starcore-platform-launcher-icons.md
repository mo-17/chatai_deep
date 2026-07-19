# Starcore Platform Launcher Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deterministically generate and install the approved 1024×1024 Starcore master as the configured Android, iOS, macOS, Windows, Web PWA, and HarmonyOS application icons.

**Architecture:** A development-only Pillow generator reads the single canonical RGB master and emits platform-specific square, transparent-rounded, maskable, and multi-frame ICO derivatives. A separate validator compares checked-in files with deterministic expected pixels, configuration references, dimensions, and color modes. Generated binaries are committed per platform and never produced during an end-user build.

**Tech Stack:** Python 3, Pillow 12.2.0 from the Codex workspace runtime, JSON/XML/plist platform manifests, Android resources, Apple asset catalogs, Windows ICO/RC, Web PWA manifest, HarmonyOS resource ids.

## Global Constraints

- The only launcher master is `docs/design-assets/starcore-guide/app-icon-concept.png`, SHA-256 `7c0b970374eae122f7f1a090c7a2d185873d3834207056547802d6fa9d1cb6f7`, 1024×1024 RGB.
- Every derivative is generated directly from the 1024px master with `Image.Resampling.LANCZOS`; never resize from another derivative.
- iOS and Android legacy images remain square RGB without pre-baked system masks.
- macOS and Windows use a transparent rounded platform composition; Web maskable images use a dedicated safe-zone composition.
- The approved spec explicitly defers Android adaptive/round icons because no separable transparent foreground master exists. Do not add `roundIcon`, `mipmap-anydpi-v26`, or guessed foreground layers in this plan.
- Preserve every existing platform resource id and configured filename; add only the four missing Android density directories.
- Do not edit `chatgpt_flutter/**/launch_screen.png`, `chatgpt_flutter_ohos/ohos/entry/src/ohosTest/`, any `build/` output, or the non-OHOS scaffold icons inside `chatgpt_flutter_ohos`.
- Do not add Pillow to any Flutter runtime package; `icon_requirements.txt` is development tooling only.
- Windows cannot be built on the current macOS host; report static ICO/RC validation as a runtime-verification gap instead of claiming a Windows build passed.
- Write and observe every platform validator failure before replacing its checked-in resources, then commit each platform slice separately.

---

### Task 1: Add the deterministic launcher generator

**Files:**
- Create: `docs/design-assets/starcore-guide/icon_requirements.txt`
- Create: `docs/design-assets/starcore-guide/generate_runtime_icons.py`
- Create: `docs/design-assets/starcore-guide/test_generate_runtime_icons.py`

**Interfaces:**
- Consumes: the canonical launcher master and a repository root.
- Produces: `generate_platform(repo_root: Path, platform: str)`, six platform generators, and CLI `--platform android|ios|macos|windows|web|ohos|all`.

- [ ] **Step 1: Write failing generator unit tests**

Create `test_generate_runtime_icons.py`:

```python
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
        self.assertEqual(MASTER_SHA256, "7c0b970374eae122f7f1a090c7a2d185873d3834207056547802d6fa9d1cb6f7")
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
            self.assertTrue((root / "chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png").is_file())
            self.assertTrue((root / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/icon-1024.png").is_file())
            self.assertTrue((root / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png").is_file())
            self.assertTrue((root / "chatgpt_flutter/windows/runner/resources/app_icon.ico").is_file())
            self.assertTrue((root / "chatgpt_flutter/web/icons/Icon-maskable-512.png").is_file())
            self.assertTrue((root / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png").is_file())
            with Image.open(root / "chatgpt_flutter/windows/runner/resources/app_icon.ico") as icon:
                self.assertEqual(
                    set(icon.ico.sizes()),
                    {(16, 16), (32, 32), (48, 48), (256, 256)},
                )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and verify RED**

Use the bundled Python that already provides Pillow 12.2.0:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_generate_runtime_icons.py -v
```

Expected: import fails because `generate_runtime_icons.py` does not exist.

- [ ] **Step 3: Pin the development-only image dependency**

Create `icon_requirements.txt`:

```text
Pillow==12.2.0
```

- [ ] **Step 4: Implement the canonical image compositions**

Start `generate_runtime_icons.py` with these contracts:

```python
from __future__ import annotations

import argparse
import hashlib
import io
import struct
from pathlib import Path

from PIL import Image, ImageDraw


MASTER_SHA256 = "7c0b970374eae122f7f1a090c7a2d185873d3834207056547802d6fa9d1cb6f7"
MIDNIGHT = (18, 13, 36)
RESAMPLE = Image.Resampling.LANCZOS


def _assert_master(path: Path) -> Image.Image:
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != MASTER_SHA256:
        raise ValueError(f"unexpected Starcore master hash: {path}")
    image = Image.open(path)
    image.load()
    if image.size != (1024, 1024) or image.mode != "RGB":
        raise ValueError(f"master must be 1024x1024 RGB: {image.size} {image.mode}")
    return image


def square_icon(master: Path, size: int) -> Image.Image:
    return _assert_master(master).resize((size, size), RESAMPLE).convert("RGB")


def rounded_icon(master: Path, size: int, *, inset_ratio: float) -> Image.Image:
    source = _assert_master(master)
    inset = round(size * inset_ratio)
    inner = size - inset * 2
    art = source.resize((inner, inner), RESAMPLE).convert("RGBA")
    mask = Image.new("L", (inner, inner), 0)
    radius = round(inner * 0.22)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner - 1, inner - 1), radius=radius, fill=255)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(art, (inset, inset), mask)
    return canvas


def maskable_icon(master: Path, size: int) -> Image.Image:
    source = _assert_master(master)
    inner = round(size * 0.78)
    art = source.resize((inner, inner), RESAMPLE)
    canvas = Image.new("RGB", (size, size), MIDNIGHT)
    offset = (size - inner) // 2
    canvas.paste(art, (offset, offset))
    return canvas


def _save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False)


def _save_ico(images: list[Image.Image], path: Path) -> None:
    payloads: list[tuple[int, bytes]] = []
    for image in images:
        stream = io.BytesIO()
        image.save(stream, format="PNG", optimize=False)
        payloads.append((image.width, stream.getvalue()))
    path.parent.mkdir(parents=True, exist_ok=True)
    offset = 6 + 16 * len(payloads)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(payloads)))
    body = bytearray()
    for size, payload in payloads:
        encoded_size = 0 if size == 256 else size
        directory.extend(struct.pack(
            "<BBBBHHII",
            encoded_size,
            encoded_size,
            0,
            0,
            1,
            32,
            len(payload),
            offset,
        ))
        body.extend(payload)
        offset += len(payload)
    path.write_bytes(bytes(directory + body))
```

- [ ] **Step 5: Implement exact platform output tables**

Add these constants and generators:

```python
ANDROID_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

IOS_FILES = {
    "icon-20@2x.png": 40,
    "icon-20@3x.png": 60,
    "icon-29@2x.png": 58,
    "icon-29@3x.png": 87,
    "icon-38@2x.png": 76,
    "icon-38@3x.png": 114,
    "icon-40@2x.png": 80,
    "icon-40@3x.png": 120,
    "icon-60@2x.png": 120,
    "icon-60@3x.png": 180,
    "icon-64@2x.png": 128,
    "icon-64@3x.png": 192,
    "icon-68@2x.png": 136,
    "icon-76@2x.png": 152,
    "icon-83.5@2x.png": 167,
    "icon-1024.png": 1024,
}

MAC_SIZES = (16, 32, 64, 128, 256, 512, 1024)


def _master(root: Path) -> Path:
    return root / "docs/design-assets/starcore-guide/app-icon-concept.png"


def generate_android(root: Path) -> None:
    base = root / "chatgpt_flutter/android/app/src/main/res"
    for density, size in ANDROID_SIZES.items():
        _save(square_icon(_master(root), size), base / density / "ic_launcher.png")


def generate_ios(root: Path) -> None:
    base = root / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for filename, size in IOS_FILES.items():
        _save(square_icon(_master(root), size), base / filename)


def generate_macos(root: Path) -> None:
    base = root / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in MAC_SIZES:
        _save(rounded_icon(_master(root), size, inset_ratio=0.08), base / f"app_icon_{size}.png")


def generate_windows(root: Path) -> None:
    path = root / "chatgpt_flutter/windows/runner/resources/app_icon.ico"
    frames = [
        rounded_icon(_master(root), size, inset_ratio=0.06)
        for size in (16, 32, 48, 256)
    ]
    _save_ico(frames, path)


def generate_web(root: Path) -> None:
    base = root / "chatgpt_flutter/web"
    _save(square_icon(_master(root), 192), base / "icons/Icon-192.png")
    _save(square_icon(_master(root), 512), base / "icons/Icon-512.png")
    _save(maskable_icon(_master(root), 192), base / "icons/Icon-maskable-192.png")
    _save(maskable_icon(_master(root), 512), base / "icons/Icon-maskable-512.png")
    _save(rounded_icon(_master(root), 16, inset_ratio=0.03), base / "favicon.png")


def generate_ohos(root: Path) -> None:
    image = rounded_icon(_master(root), 114, inset_ratio=0.04)
    _save(image, root / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png")
    _save(image, root / "chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png")
```

- [ ] **Step 6: Implement the dispatch API and CLI**

Finish the file:

```python
GENERATORS = {
    "android": generate_android,
    "ios": generate_ios,
    "macos": generate_macos,
    "windows": generate_windows,
    "web": generate_web,
    "ohos": generate_ohos,
}


def generate_platform(root: Path, platform: str) -> None:
    if platform == "all":
        for generator in GENERATORS.values():
            generator(root)
        return
    GENERATORS[platform](root)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--platform",
        choices=[*GENERATORS, "all"],
        default="all",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
    )
    args = parser.parse_args()
    generate_platform(args.root.resolve(), args.platform)


if __name__ == "__main__":
    main()
```

- [ ] **Step 7: Run generator unit tests and syntax checks**

Run:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_generate_runtime_icons.py -v
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m py_compile generate_runtime_icons.py
```

Expected: two tests pass and compilation exits 0; repository platform files are still untouched because tests use a temporary root.

- [ ] **Step 8: Commit the generator only**

```bash
git add -f docs/design-assets/starcore-guide/icon_requirements.txt docs/design-assets/starcore-guide/generate_runtime_icons.py docs/design-assets/starcore-guide/test_generate_runtime_icons.py
git commit -m "test(icons): add deterministic launcher generator"
```

---

### Task 2: Add the platform validator and install Android densities

**Files:**
- Create: `docs/design-assets/starcore-guide/validate_runtime_icons.py`
- Create: `docs/design-assets/starcore-guide/test_validate_runtime_icons.py`
- Create: `chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png`
- Create: `chatgpt_flutter/android/app/src/main/res/mipmap-hdpi/ic_launcher.png`
- Create: `chatgpt_flutter/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png`
- Create: `chatgpt_flutter/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png`
- Replace: `chatgpt_flutter/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`
- Verify unchanged: `chatgpt_flutter/android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: `ANDROID_SIZES`, `square_icon`, and the approved no-adaptive decision.
- Produces: `validate_platform(root, platform) -> list[str]` and a complete five-density legacy Android launcher set.

- [ ] **Step 1: Write a failing Android repository-validation test**

Create `test_validate_runtime_icons.py`:

```python
import unittest
from pathlib import Path

from validate_runtime_icons import validate_platform


ROOT = Path(__file__).resolve().parents[3]


class RuntimeIconRepositoryTest(unittest.TestCase):
    def test_android(self):
        self.assertEqual(validate_platform(ROOT, "android"), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Implement pixel-exact Android validation**

Create `validate_runtime_icons.py` with reusable image comparison and the first platform validator:

```python
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops

from generate_runtime_icons import ANDROID_SIZES, GENERATORS, _master, square_icon


def _same_pixels(actual: Path, expected: Image.Image) -> bool:
    if not actual.is_file():
        return False
    with Image.open(actual) as loaded:
        loaded.load()
        if loaded.size != expected.size or loaded.mode != expected.mode:
            return False
        return ImageChops.difference(loaded, expected).getbbox(
            alpha_only=False,
        ) is None


def validate_android(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/android/app/src/main/res"
    for density, size in ANDROID_SIZES.items():
        path = base / density / "ic_launcher.png"
        if not _same_pixels(path, square_icon(_master(root), size)):
            errors.append(f"android launcher mismatch: {path}")
    manifest = root / "chatgpt_flutter/android/app/src/main/AndroidManifest.xml"
    text = manifest.read_text(encoding="utf-8")
    if 'android:icon="@mipmap/ic_launcher"' not in text:
        errors.append("AndroidManifest no longer references @mipmap/ic_launcher")
    if "android:roundIcon=" in text:
        errors.append("roundIcon is outside the approved non-adaptive scope")
    return errors


VALIDATORS = {"android": validate_android}


def validate_platform(root: Path, platform: str) -> list[str]:
    return VALIDATORS[platform](root)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=list(VALIDATORS), required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args()
    errors = validate_platform(args.root.resolve(), args.platform)
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Starcore runtime icons [{args.platform}]: OK")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run Android validation and verify RED**

Run:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_validate_runtime_icons.RuntimeIconRepositoryTest.test_android -v
```

Expected: failure lists the four missing density files and the old xxxhdpi pixel mismatch.

- [ ] **Step 4: Generate only Android and verify GREEN**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/generate_runtime_icons.py --platform android
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v
```

Expected: generator and Android repository tests pass. Confirm `launch_screen.png` and the manifest have no diff.

- [ ] **Step 5: Commit Android separately**

```bash
git add -f docs/design-assets/starcore-guide/validate_runtime_icons.py docs/design-assets/starcore-guide/test_validate_runtime_icons.py
git add chatgpt_flutter/android/app/src/main/res/mipmap-mdpi/ic_launcher.png chatgpt_flutter/android/app/src/main/res/mipmap-hdpi/ic_launcher.png chatgpt_flutter/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png chatgpt_flutter/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png chatgpt_flutter/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
git commit -m "feat(android): install Starcore launcher icons"
```

---

### Task 3: Install iOS and macOS AppIcon sets

**Files:**
- Replace: all 16 PNGs named by `chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Replace: `chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png`
- Modify: `docs/design-assets/starcore-guide/validate_runtime_icons.py`
- Modify: `docs/design-assets/starcore-guide/test_validate_runtime_icons.py`
- Verify unchanged: both Apple `Contents.json` files and both Xcode project files

**Interfaces:**
- Consumes: `IOS_FILES`, `MAC_SIZES`, `square_icon`, and `rounded_icon`.
- Produces: RGB/no-alpha iOS images and transparent rounded macOS images matching their existing asset catalogs.

- [ ] **Step 1: Add failing Apple validation tests**

Add to `RuntimeIconRepositoryTest`:

```python
def test_ios(self):
    self.assertEqual(validate_platform(ROOT, "ios"), [])

def test_macos(self):
    self.assertEqual(validate_platform(ROOT, "macos"), [])
```

- [ ] **Step 2: Implement Apple validators**

Import `json`, `IOS_FILES`, `MAC_SIZES`, and `rounded_icon`, then add:

```python
def validate_ios(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((base / "Contents.json").read_text(encoding="utf-8"))
    declared = {item["filename"]: item for item in contents["images"]}
    if set(declared) != set(IOS_FILES):
        errors.append("iOS Contents.json filenames differ from IOS_FILES")
    for filename, pixels in IOS_FILES.items():
        item = declared.get(filename)
        path = base / filename
        if item is None:
            continue
        points = float(item["size"].split("x")[0])
        scale = int(item["scale"].removesuffix("x"))
        if round(points * scale) != pixels:
            errors.append(f"iOS catalog size mismatch: {filename}")
        if not path.is_file():
            errors.append(f"missing iOS icon: {path}")
            continue
        with Image.open(path) as actual:
            if actual.mode != "RGB":
                errors.append(f"iOS icon must be RGB without alpha: {path}")
        if not _same_pixels(path, square_icon(_master(root), pixels)):
            errors.append(f"iOS icon pixels differ: {path}")
    return errors


def validate_macos(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((base / "Contents.json").read_text(encoding="utf-8"))
    records = contents["images"]
    declared = {item["filename"] for item in records}
    expected_names = {f"app_icon_{size}.png" for size in MAC_SIZES}
    if declared != expected_names:
        errors.append("macOS Contents.json filenames differ from MAC_SIZES")
    for item in records:
        points = float(item["size"].split("x")[0])
        scale = int(item["scale"].removesuffix("x"))
        pixels = round(points * scale)
        if item["filename"] != f"app_icon_{pixels}.png":
            errors.append(
                f"macOS catalog size mismatch: {item['filename']}"
            )
    for size in MAC_SIZES:
        path = base / f"app_icon_{size}.png"
        if not path.is_file():
            errors.append(f"missing macOS icon: {path}")
            continue
        with Image.open(path) as actual:
            actual.load()
            if actual.mode != "RGBA" or actual.getpixel((0, 0))[3] != 0:
                errors.append(f"macOS icon lacks transparent rounded canvas: {path}")
        expected = rounded_icon(_master(root), size, inset_ratio=0.08)
        if not _same_pixels(path, expected):
            errors.append(f"macOS icon pixels differ: {path}")
    return errors


VALIDATORS.update({"ios": validate_ios, "macos": validate_macos})
```

- [ ] **Step 3: Run Apple tests and verify RED**

Run:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_validate_runtime_icons.RuntimeIconRepositoryTest.test_ios test_validate_runtime_icons.RuntimeIconRepositoryTest.test_macos -v
```

Expected: both tests fail because the checked-in Flutter defaults do not match the Starcore-derived pixels.

- [ ] **Step 4: Generate Apple sets and verify GREEN**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/generate_runtime_icons.py --platform ios
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/generate_runtime_icons.py --platform macos
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m json.tool chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m json.tool chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null
```

Expected: all tests pass, both JSON syntax checks exit 0, and neither `Contents.json` has a diff.

- [ ] **Step 5: Commit Apple resources**

```bash
git add -f docs/design-assets/starcore-guide/validate_runtime_icons.py docs/design-assets/starcore-guide/test_validate_runtime_icons.py
git add chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset
git commit -m "feat(apple): install Starcore AppIcon sets"
```

---

### Task 4: Install Windows and Web PWA icons

**Files:**
- Replace: `chatgpt_flutter/windows/runner/resources/app_icon.ico`
- Replace: `chatgpt_flutter/web/favicon.png`
- Replace: `chatgpt_flutter/web/icons/Icon-192.png`
- Replace: `chatgpt_flutter/web/icons/Icon-512.png`
- Replace: `chatgpt_flutter/web/icons/Icon-maskable-192.png`
- Replace: `chatgpt_flutter/web/icons/Icon-maskable-512.png`
- Modify: `chatgpt_flutter/web/manifest.json:5-6`
- Modify: `docs/design-assets/starcore-guide/validate_runtime_icons.py`
- Modify: `docs/design-assets/starcore-guide/test_validate_runtime_icons.py`
- Verify unchanged: `chatgpt_flutter/windows/runner/Runner.rc`, `resource.h`, `win32_window.cpp`, and `chatgpt_flutter/web/index.html`

**Interfaces:**
- Consumes: `rounded_icon`, `square_icon`, `maskable_icon`, Windows RC and Web manifest references.
- Produces: a four-frame ICO and five PWA/favicon images with branded install colors.

- [ ] **Step 1: Add failing Windows and Web tests**

Add `test_windows` and `test_web` methods that call `validate_platform` and expect no errors.

- [ ] **Step 2: Implement the Windows validator**

Add:

```python
def validate_windows(root: Path) -> list[str]:
    errors: list[str] = []
    path = root / "chatgpt_flutter/windows/runner/resources/app_icon.ico"
    expected_sizes = {(16, 16), (32, 32), (48, 48), (256, 256)}
    if not path.is_file():
        return [f"missing Windows ICO: {path}"]
    with Image.open(path) as image:
        sizes = set(image.ico.sizes())
        if sizes != expected_sizes:
            errors.append(f"Windows ICO frame set differs: {sizes}")
        for size in expected_sizes & sizes:
            actual = image.ico.getimage(size).convert("RGBA")
            expected = rounded_icon(_master(root), size[0], inset_ratio=0.06)
            if ImageChops.difference(actual, expected).getbbox(
                alpha_only=False,
            ) is not None:
                errors.append(f"Windows ICO pixels differ at {size[0]}px")
    rc = (root / "chatgpt_flutter/windows/runner/Runner.rc").read_text(
        encoding="utf-8",
    )
    if 'resources\\\\app_icon.ico' not in rc:
        errors.append("Runner.rc no longer references resources\\\\app_icon.ico")
    return errors


VALIDATORS["windows"] = validate_windows
```

- [ ] **Step 3: Implement the Web validator**

Import `maskable_icon`, then add:

```python
def validate_web(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/web"
    manifest = json.loads((base / "manifest.json").read_text(encoding="utf-8"))
    expected = {
        "icons/Icon-192.png": (192, False),
        "icons/Icon-512.png": (512, False),
        "icons/Icon-maskable-192.png": (192, True),
        "icons/Icon-maskable-512.png": (512, True),
    }
    records = {item["src"]: item for item in manifest["icons"]}
    for relative, (size, is_maskable) in expected.items():
        item = records.get(relative)
        if item is None or item.get("sizes") != f"{size}x{size}":
            errors.append(f"Web manifest entry differs: {relative}")
            continue
        if is_maskable != (item.get("purpose") == "maskable"):
            errors.append(f"Web maskable purpose differs: {relative}")
        rendered = maskable_icon(_master(root), size) if is_maskable else square_icon(_master(root), size)
        if not _same_pixels(base / relative, rendered):
            errors.append(f"Web icon pixels differ: {relative}")
    if not _same_pixels(
        base / "favicon.png",
        rounded_icon(_master(root), 16, inset_ratio=0.03),
    ):
        errors.append("Web favicon pixels differ")
    if manifest.get("background_color") != "#120D24":
        errors.append("Web background_color is not #120D24")
    if manifest.get("theme_color") != "#6D28D9":
        errors.append("Web theme_color is not #6D28D9")
    html = (base / "index.html").read_text(encoding="utf-8")
    if "icons/Icon-192.png" not in html or "favicon.png" not in html:
        errors.append("Web HTML icon references changed")
    return errors


VALIDATORS["web"] = validate_web
```

- [ ] **Step 4: Run both tests and verify RED**

Run:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_validate_runtime_icons.RuntimeIconRepositoryTest.test_windows test_validate_runtime_icons.RuntimeIconRepositoryTest.test_web -v
```

Expected: the existing ICO/PWA pixels differ and the manifest still contains Flutter blue.

- [ ] **Step 5: Generate resources and set the approved Web colors**

Run the generator for `windows` and `web`, then change only:

```json
"background_color": "#120D24",
"theme_color": "#6D28D9"
```

in `chatgpt_flutter/web/manifest.json`.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v
file chatgpt_flutter/windows/runner/resources/app_icon.ico
```

Expected: all generator/repository tests pass and `file` identifies a Windows icon resource. Then commit:

```bash
git add -f docs/design-assets/starcore-guide/validate_runtime_icons.py docs/design-assets/starcore-guide/test_validate_runtime_icons.py
git add chatgpt_flutter/windows/runner/resources/app_icon.ico chatgpt_flutter/web/favicon.png chatgpt_flutter/web/icons chatgpt_flutter/web/manifest.json
git commit -m "feat(desktop-web): install Starcore app icons"
```

---

### Task 5: Install the two HarmonyOS production icons

**Files:**
- Replace: `chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png`
- Replace: `chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png`
- Modify: `docs/design-assets/starcore-guide/validate_runtime_icons.py`
- Modify: `docs/design-assets/starcore-guide/test_validate_runtime_icons.py`
- Verify unchanged: `chatgpt_flutter_ohos/ohos/AppScope/app.json5`, `chatgpt_flutter_ohos/ohos/entry/src/main/module.json5`, and `src/ohosTest/resources/base/media/icon.png`

**Interfaces:**
- Consumes: `rounded_icon(master, 114, inset_ratio=0.04)` and current `$media` references.
- Produces: identical 114×114 production icons for AppScope and entry/startWindow.

- [ ] **Step 1: Add a failing HarmonyOS test**

Add:

```python
def test_ohos(self):
    self.assertEqual(validate_platform(ROOT, "ohos"), [])
```

- [ ] **Step 2: Implement HarmonyOS validation**

Add:

```python
def validate_ohos(root: Path) -> list[str]:
    errors: list[str] = []
    app_scope = root / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png"
    entry = root / "chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png"
    expected = rounded_icon(_master(root), 114, inset_ratio=0.04)
    for path in (app_scope, entry):
        if not _same_pixels(path, expected):
            errors.append(f"HarmonyOS icon pixels differ: {path}")
    if app_scope.is_file() and entry.is_file() and app_scope.read_bytes() != entry.read_bytes():
        errors.append("HarmonyOS AppScope and entry icons differ")
    app_json = (
        root / "chatgpt_flutter_ohos/ohos/AppScope/app.json5"
    ).read_text(encoding="utf-8")
    module_json = (
        root / "chatgpt_flutter_ohos/ohos/entry/src/main/module.json5"
    ).read_text(encoding="utf-8")
    if '"icon": "$media:app_icon"' not in app_json:
        errors.append("AppScope no longer references $media:app_icon")
    if '"icon": "$media:icon"' not in module_json:
        errors.append("entry no longer references $media:icon")
    if '"startWindowIcon": "$media:icon"' not in module_json:
        errors.append("startWindowIcon no longer references $media:icon")
    return errors


VALIDATORS["ohos"] = validate_ohos
```

Do not search or validate generated `build/` resources.

- [ ] **Step 3: Run the test and verify RED**

Run:

```bash
cd docs/design-assets/starcore-guide
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest test_validate_runtime_icons.RuntimeIconRepositoryTest.test_ohos -v
```

Expected: current default icon pixels differ from the Starcore result.

- [ ] **Step 4: Generate OHOS, verify protected paths, and commit**

Record the protected test icon hash, generate, and verify it is unchanged:

```bash
shasum -a 256 chatgpt_flutter_ohos/ohos/entry/src/ohosTest/resources/base/media/icon.png
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/generate_runtime_icons.py --platform ohos
shasum -a 256 chatgpt_flutter_ohos/ohos/entry/src/ohosTest/resources/base/media/icon.png
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v
```

Expected: pre/post protected hashes match and all tests pass. Commit only production files:

```bash
git add -f docs/design-assets/starcore-guide/validate_runtime_icons.py docs/design-assets/starcore-guide/test_validate_runtime_icons.py
git add chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png
git commit -m "feat(ohos): install Starcore app icons"
```

---

### Task 6: Verify platform packaging and record completion evidence

**Files:**
- Modify: `docs/superpowers/specs/2026-07-19-starcore-runtime-icon-integration-design.md`
- Verify: generator/validator files from Tasks 1-5; Task 6 adds no generation behavior
- Do not modify: `login_sdk/test/support/`

**Interfaces:**
- Consumes: all generated platform resources and the separate runtime UI plan's status.
- Produces: complete static validation, available platform builds, a documented Windows gap, and final implementation evidence in the design spec.

- [ ] **Step 1: Run the complete generator/validator suites**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform android
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform ios
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform macos
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform windows
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform web
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_runtime_icons.py --platform ohos
```

Expected: all commands print `OK` or pass.

- [ ] **Step 2: Run configuration and repository checks**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m json.tool chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m json.tool chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null
xmllint --noout chatgpt_flutter/android/app/src/main/AndroidManifest.xml
git diff --check
git status --short
```

Expected: configurations are valid and only planned files plus `?? login_sdk/test/support/` appear.

- [ ] **Step 3: Build available primary-shell targets**

Run:

```bash
cd chatgpt_flutter
fvm flutter build apk --debug
fvm flutter build web
fvm flutter build macos --debug
fvm flutter build ios --simulator --no-codesign
```

Expected: every toolchain installed on the current host builds successfully. Record exact toolchain errors for unavailable SDKs; do not weaken static resource tests.

- [ ] **Step 4: Attempt the real HarmonyOS build with the required environment**

Run:

```bash
cd chatgpt_flutter_ohos
eval "$(mise activate zsh --shims)"
flutter build hap
```

Expected: HAP builds when the configured DevEco SDK is available. If the host blocks it, record the exact command/error and retain the passing OHOS resource/config validator as static evidence.

- [ ] **Step 5: Perform visual sampling**

Inspect at native scale: Android 48/192, iOS 40/1024, macOS 16/1024, Web favicon/maskable-512, and OHOS 114. Confirm the star core remains visible, macOS corners are transparent, maskable critical art stays inside the safe zone, and no platform file contains text or a Flutter logo.

- [ ] **Step 6: Append exact verification evidence to the approved spec**

Add a final `## 14. 实施验证记录` section with:

```markdown
- Launcher 资源生成：通过（generator/validator 测试数量与命令）
- Android / Web / macOS / iOS 构建：逐项记录通过或精确阻塞原因
- HarmonyOS HAP：记录通过或精确阻塞原因
- Windows：ICO/RC 静态验证通过；macOS 主机未执行 Windows runner 构建
- Flutter runtime UI：引用另一份计划的最终测试结果；未完成时明确写“待完成”
```

Do not change the document header to “完成” until both this plan and `2026-07-19-starcore-runtime-ui-icons.md` have completed their required verification.

- [ ] **Step 7: Commit verification documentation**

```bash
git add -f docs/superpowers/specs/2026-07-19-starcore-runtime-icon-integration-design.md
git commit -m "docs(icons): record Starcore runtime verification"
```
