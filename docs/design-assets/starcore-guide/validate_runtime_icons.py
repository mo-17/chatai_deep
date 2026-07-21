from __future__ import annotations

import argparse
import io
import json
import struct
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

WINDOWS_ICON_SIZES = (16, 32, 48, 256)

EXPECTED_WEB_ICON_RECORDS = [
    {
        "src": "icons/Icon-192.png",
        "sizes": "192x192",
        "type": "image/png",
    },
    {
        "src": "icons/Icon-512.png",
        "sizes": "512x512",
        "type": "image/png",
    },
    {
        "src": "icons/Icon-maskable-192.png",
        "sizes": "192x192",
        "type": "image/png",
        "purpose": "maskable",
    },
    {
        "src": "icons/Icon-maskable-512.png",
        "sizes": "512x512",
        "type": "image/png",
        "purpose": "maskable",
    },
]


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
    if not path.is_file():
        return [f"missing Windows ICO: {path}"]
    try:
        raw = path.read_bytes()
    except OSError as error:
        return [f"unable to read Windows ICO: {path}: {error}"]
    if len(raw) < 6:
        return [f"Windows ICO header is truncated: {path}"]

    reserved, icon_type, count = struct.unpack_from("<HHH", raw)
    if reserved != 0:
        errors.append(f"Windows ICO reserved header field differs: {reserved}")
    if icon_type != 1:
        errors.append(f"Windows ICO type differs: {icon_type}")
    if count != len(WINDOWS_ICON_SIZES):
        errors.append(f"Windows ICO directory count differs: {count}")

    directory_end = 6 + count * 16
    if len(raw) < directory_end:
        errors.append(
            f"Windows ICO directory is truncated: expected {directory_end} bytes, "
            f"found {len(raw)}"
        )
    else:
        sizes: list[tuple[int, int]] = []
        ranges: list[tuple[int, int]] = []
        for index in range(count):
            offset = 6 + index * 16
            (
                encoded_width,
                encoded_height,
                _colors,
                _entry_reserved,
                planes,
                bpp,
                length,
                payload_offset,
            ) = struct.unpack_from("<BBBBHHII", raw, offset)
            width = encoded_width or 256
            height = encoded_height or 256
            size = (width, height)
            sizes.append(size)
            if planes != 1 or bpp != 32:
                errors.append(
                    f"Windows ICO directory entry {index} must use 1 plane and 32bpp"
                )
            payload_end = payload_offset + length
            if (
                length == 0
                or payload_offset < directory_end
                or payload_offset > len(raw)
                or payload_end > len(raw)
            ):
                errors.append(
                    f"Windows ICO directory entry {index} has an invalid payload "
                    f"offset/length"
                )
                continue
            if any(
                payload_offset < previous_end and start < payload_end
                for start, previous_end in ranges
            ):
                errors.append(
                    f"Windows ICO directory entry {index} overlaps another payload"
                )
                continue
            ranges.append((payload_offset, payload_end))
            payload = raw[payload_offset:payload_end]
            if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
                errors.append(f"Windows ICO payload is not PNG at {width}px")
                continue
            try:
                with Image.open(io.BytesIO(payload)) as actual:
                    actual.load()
                    if actual.mode != "RGBA":
                        errors.append(
                            f"Windows ICO PNG payload must be RGBA at {width}px"
                        )
                        continue
                    if actual.size != size:
                        errors.append(
                            f"Windows ICO PNG dimensions differ at entry {index}: "
                            f"{actual.size} != {size}"
                        )
                        continue
                    expected = rounded_icon(
                        _master(root), width, inset_ratio=0.06
                    )
                    if ImageChops.difference(actual, expected).getbbox(
                        alpha_only=False,
                    ) is not None:
                        errors.append(f"Windows ICO pixels differ at {width}px")
            except (OSError, SyntaxError, ValueError) as error:
                errors.append(
                    f"Windows ICO PNG payload cannot be decoded at entry {index}: {error}"
                )
        expected_sizes = {(size, size) for size in WINDOWS_ICON_SIZES}
        if set(sizes) != expected_sizes or len(sizes) != len(set(sizes)):
            errors.append(f"Windows ICO frame entries differ: {sizes}")
    try:
        rc = (root / "chatgpt_flutter/windows/runner/Runner.rc").read_text(
            encoding="utf-8",
        )
    except OSError as error:
        errors.append(f"unable to read Runner.rc: {error}")
    else:
        if 'resources\\\\app_icon.ico' not in rc:
            errors.append("Runner.rc no longer references resources\\\\app_icon.ico")
    return errors


def validate_web(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/web"
    manifest_path = base / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"unable to read Web manifest: {manifest_path}: {error}"]
    if manifest.get("icons") != EXPECTED_WEB_ICON_RECORDS:
        errors.append("Web manifest icon records differ from expected records")
    for item in EXPECTED_WEB_ICON_RECORDS:
        relative = item["src"]
        size = int(item["sizes"].split("x", maxsplit=1)[0])
        is_maskable = item.get("purpose") == "maskable"
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
