from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from PIL import Image, ImageChops

from generate_runtime_icons import (
    ANDROID_SIZES,
    GENERATORS,
    IOS_FILES,
    MAC_SIZES,
    _master,
    maskable_icon,
    rounded_icon,
    square_icon,
)


EXPECTED_MACOS_RECORDS = Counter(
    [
        ("app_icon_16.png", "16x16", "1x"),
        ("app_icon_32.png", "16x16", "2x"),
        ("app_icon_32.png", "32x32", "1x"),
        ("app_icon_64.png", "32x32", "2x"),
        ("app_icon_128.png", "128x128", "1x"),
        ("app_icon_256.png", "128x128", "2x"),
        ("app_icon_256.png", "256x256", "1x"),
        ("app_icon_512.png", "256x256", "2x"),
        ("app_icon_512.png", "512x512", "1x"),
        ("app_icon_1024.png", "512x512", "2x"),
    ]
)


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


def validate_ios(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((base / "Contents.json").read_text(encoding="utf-8"))
    records = contents["images"]
    declared = {item["filename"]: item for item in records}
    if len(records) != len(IOS_FILES):
        errors.append("iOS Contents.json record count differs from IOS_FILES")
    if len(declared) != len(records):
        errors.append("iOS Contents.json has duplicate filenames")
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
            if actual.mode != "RGB" or actual.info.get("transparency") is not None:
                errors.append(f"iOS icon must be RGB without alpha: {path}")
        if not _same_pixels(path, square_icon(_master(root), pixels)):
            errors.append(f"iOS icon pixels differ: {path}")
    return errors


def validate_macos(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((base / "Contents.json").read_text(encoding="utf-8"))
    records = contents["images"]
    actual_records = Counter(
        (item["filename"], item["size"], item["scale"]) for item in records
    )
    if actual_records != EXPECTED_MACOS_RECORDS:
        errors.append("macOS Contents.json records differ from expected catalog")
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
    manifest_records = manifest["icons"]
    sources = [item.get("src") for item in manifest_records]
    if len(manifest_records) != len(expected):
        errors.append("Web manifest record count differs from expected icons")
    if len(set(sources)) != len(sources):
        errors.append("Web manifest has duplicate icon records")
    if set(sources) != set(expected):
        errors.append("Web manifest icon records differ from expected icons")
    records = {item["src"]: item for item in manifest_records}
    for relative, (size, is_maskable) in expected.items():
        item = records.get(relative)
        if item is None or item.get("sizes") != f"{size}x{size}":
            errors.append(f"Web manifest entry differs: {relative}")
            continue
        if is_maskable != (item.get("purpose") == "maskable"):
            errors.append(f"Web maskable purpose differs: {relative}")
        rendered = (
            maskable_icon(_master(root), size)
            if is_maskable
            else square_icon(_master(root), size)
        )
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


VALIDATORS = {
    "android": validate_android,
    "ios": validate_ios,
    "macos": validate_macos,
    "windows": validate_windows,
    "web": validate_web,
}


def validate_platform(root: Path, platform: str) -> list[str]:
    return VALIDATORS[platform](root)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=list(VALIDATORS), required=True)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
    )
    args = parser.parse_args()
    errors = validate_platform(args.root.resolve(), args.platform)
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Starcore runtime icons [{args.platform}]: OK")


if __name__ == "__main__":
    main()
