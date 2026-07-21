from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops

from generate_runtime_icons import (
    ANDROID_SIZES,
    GENERATORS,
    IOS_FILES,
    MAC_SIZES,
    _master,
    rounded_icon,
    square_icon,
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


VALIDATORS = {
    "android": validate_android,
    "ios": validate_ios,
    "macos": validate_macos,
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
