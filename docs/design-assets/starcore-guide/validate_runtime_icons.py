from __future__ import annotations

import argparse
import io
import json
import struct
from collections import Counter
from collections.abc import Callable
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

IMAGE_INPUT_ERRORS = (
    OSError,
    SyntaxError,
    TypeError,
    ValueError,
    Image.DecompressionBombError,
)


def _read_text(path: Path, *, label: str, errors: list[str]) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        errors.append(f"unable to read {label}: {path}: {error}")
        return None


def _read_bytes(path: Path, *, label: str, errors: list[str]) -> bytes | None:
    try:
        return path.read_bytes()
    except OSError as error:
        errors.append(f"unable to read {label}: {path}: {error}")
        return None


def _read_json_object(
    path: Path,
    *,
    label: str,
    errors: list[str],
) -> dict[str, object] | None:
    text = _read_text(path, label=label, errors=errors)
    if text is None:
        return None
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        errors.append(f"unable to parse {label}: {path}: {error}")
        return None
    if not isinstance(value, dict):
        errors.append(f"{label} must be a JSON object: {path}")
        return None
    return value


def _render_expected(
    render: Callable[[], Image.Image],
    *,
    label: str,
    source: Path,
    errors: list[str],
) -> Image.Image | None:
    try:
        return render()
    except IMAGE_INPUT_ERRORS as error:
        errors.append(
            f"unable to render {label} from Starcore master {source}: {error}"
        )
        return None


def _same_pixels(
    actual: Path,
    expected: Image.Image,
    *,
    label: str = "image",
    errors: list[str] | None = None,
) -> bool:
    if not actual.is_file():
        if errors is not None:
            errors.append(f"missing {label}: {actual}")
        return False
    try:
        with Image.open(actual) as loaded:
            loaded.load()
            if loaded.size != expected.size or loaded.mode != expected.mode:
                return False
            return ImageChops.difference(loaded, expected).getbbox(
                alpha_only=False,
            ) is None
    except IMAGE_INPUT_ERRORS as error:
        if errors is not None:
            errors.append(f"unable to decode {label}: {actual}: {error}")
        return False


def _check_pixels(
    actual: Path,
    expected: Image.Image,
    *,
    label: str,
    mismatch: str,
    errors: list[str],
) -> None:
    error_count = len(errors)
    if not _same_pixels(actual, expected, label=label, errors=errors):
        if len(errors) == error_count:
            errors.append(mismatch)


def validate_android(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/android/app/src/main/res"
    master = _master(root)
    for density, size in ANDROID_SIZES.items():
        path = base / density / "ic_launcher.png"
        expected = _render_expected(
            lambda size=size: square_icon(master, size),
            label=f"Android {density} launcher",
            source=master,
            errors=errors,
        )
        if expected is None:
            break
        _check_pixels(
            path,
            expected,
            label="Android launcher",
            mismatch=f"android launcher mismatch: {path}",
            errors=errors,
        )
    manifest = root / "chatgpt_flutter/android/app/src/main/AndroidManifest.xml"
    text = _read_text(manifest, label="Android manifest", errors=errors)
    if text is not None:
        if 'android:icon="@mipmap/ic_launcher"' not in text:
            errors.append("AndroidManifest no longer references @mipmap/ic_launcher")
        if "android:roundIcon=" in text:
            errors.append("roundIcon is outside the approved non-adaptive scope")
    return errors


def validate_ios(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    catalog_path = base / "Contents.json"
    contents = _read_json_object(
        catalog_path,
        label="iOS icon catalog",
        errors=errors,
    )
    raw_records = contents.get("images") if contents is not None else None
    if raw_records is not None and not isinstance(raw_records, list):
        errors.append(f"iOS icon catalog images must be a list: {catalog_path}")
    records = raw_records if isinstance(raw_records, list) else []
    declared: dict[str, dict[str, object]] = {}
    for index, item in enumerate(records):
        if not isinstance(item, dict):
            errors.append(
                f"iOS icon catalog record {index} must be an object: {catalog_path}"
            )
            continue
        filename = item.get("filename")
        if not isinstance(filename, str) or not filename:
            errors.append(
                f"iOS icon catalog record {index} has an invalid filename: "
                f"{catalog_path}"
            )
            continue
        declared[filename] = item
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
        try:
            declared_size = item["size"]
            declared_scale = item["scale"]
            if not isinstance(declared_size, str) or not isinstance(
                declared_scale,
                str,
            ):
                raise TypeError("size and scale must be strings")
            points = float(declared_size.split("x", maxsplit=1)[0])
            scale = int(declared_scale.removesuffix("x"))
        except (KeyError, TypeError, ValueError) as error:
            errors.append(
                f"iOS catalog record is malformed for {filename}: {error}"
            )
        else:
            if round(points * scale) != pixels:
                errors.append(f"iOS catalog size mismatch: {filename}")
        if not path.is_file():
            errors.append(f"missing iOS icon: {path}")
            continue
        try:
            with Image.open(path) as actual:
                actual.load()
                if actual.mode != "RGB" or actual.info.get("transparency") is not None:
                    errors.append(f"iOS icon must be RGB without alpha: {path}")
        except IMAGE_INPUT_ERRORS as error:
            errors.append(f"unable to decode iOS icon: {path}: {error}")
            continue
        master = _master(root)
        expected = _render_expected(
            lambda pixels=pixels: square_icon(master, pixels),
            label=f"iOS {filename}",
            source=master,
            errors=errors,
        )
        if expected is None:
            break
        _check_pixels(
            path,
            expected,
            label="iOS icon",
            mismatch=f"iOS icon pixels differ: {path}",
            errors=errors,
        )
    return errors


def validate_macos(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    catalog_path = base / "Contents.json"
    contents = _read_json_object(
        catalog_path,
        label="macOS icon catalog",
        errors=errors,
    )
    raw_records = contents.get("images") if contents is not None else None
    if raw_records is not None and not isinstance(raw_records, list):
        errors.append(f"macOS icon catalog images must be a list: {catalog_path}")
    records = raw_records if isinstance(raw_records, list) else []
    actual_records: Counter[tuple[str, str, str]] = Counter()
    for index, item in enumerate(records):
        if not isinstance(item, dict):
            errors.append(
                f"macOS icon catalog record {index} must be an object: "
                f"{catalog_path}"
            )
            continue
        try:
            filename = item["filename"]
            declared_size = item["size"]
            scale = item["scale"]
            if not all(
                isinstance(value, str)
                for value in (filename, declared_size, scale)
            ):
                raise TypeError("filename, size, and scale must be strings")
        except (KeyError, TypeError) as error:
            errors.append(
                f"macOS icon catalog record {index} is malformed: {error}"
            )
            continue
        actual_records[(filename, declared_size, scale)] += 1
    if actual_records != EXPECTED_MACOS_RECORDS:
        errors.append("macOS Contents.json records differ from expected catalog")
    master = _master(root)
    for size in MAC_SIZES:
        path = base / f"app_icon_{size}.png"
        if not path.is_file():
            errors.append(f"missing macOS icon: {path}")
            continue
        try:
            with Image.open(path) as actual:
                actual.load()
                if actual.mode != "RGBA" or actual.getpixel((0, 0))[3] != 0:
                    errors.append(
                        f"macOS icon lacks transparent rounded canvas: {path}"
                    )
        except IMAGE_INPUT_ERRORS as error:
            errors.append(f"unable to decode macOS icon: {path}: {error}")
            continue
        expected = _render_expected(
            lambda size=size: rounded_icon(master, size, inset_ratio=0.08),
            label=f"macOS {size}px icon",
            source=master,
            errors=errors,
        )
        if expected is None:
            break
        _check_pixels(
            path,
            expected,
            label="macOS icon",
            mismatch=f"macOS icon pixels differ: {path}",
            errors=errors,
        )
    return errors


def validate_windows(root: Path) -> list[str]:
    errors: list[str] = []
    path = root / "chatgpt_flutter/windows/runner/resources/app_icon.ico"
    if not path.is_file():
        return [f"missing Windows ICO: {path}"]
    raw = _read_bytes(path, label="Windows ICO", errors=errors)
    if raw is None:
        return errors
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
            except IMAGE_INPUT_ERRORS as error:
                errors.append(
                    f"Windows ICO PNG payload cannot be decoded at entry {index}: {error}"
                )
        expected_sizes = {(size, size) for size in WINDOWS_ICON_SIZES}
        if set(sizes) != expected_sizes or len(sizes) != len(set(sizes)):
            errors.append(f"Windows ICO frame entries differ: {sizes}")
    rc_path = root / "chatgpt_flutter/windows/runner/Runner.rc"
    rc = _read_text(rc_path, label="Windows Runner.rc", errors=errors)
    if rc is not None:
        if 'resources\\\\app_icon.ico' not in rc:
            errors.append("Runner.rc no longer references resources\\\\app_icon.ico")
    return errors


def validate_web(root: Path) -> list[str]:
    errors: list[str] = []
    base = root / "chatgpt_flutter/web"
    manifest_path = base / "manifest.json"
    manifest = _read_json_object(
        manifest_path,
        label="Web manifest",
        errors=errors,
    )
    if manifest is None:
        manifest = {}
    if manifest.get("icons") != EXPECTED_WEB_ICON_RECORDS:
        errors.append("Web manifest icon records differ from expected records")
    master = _master(root)
    for item in EXPECTED_WEB_ICON_RECORDS:
        relative = item["src"]
        size = int(item["sizes"].split("x", maxsplit=1)[0])
        is_maskable = item.get("purpose") == "maskable"
        rendered = _render_expected(
            lambda size=size, is_maskable=is_maskable: (
                maskable_icon(master, size)
                if is_maskable
                else square_icon(master, size)
            ),
            label=f"Web {relative}",
            source=master,
            errors=errors,
        )
        if rendered is None:
            break
        _check_pixels(
            base / relative,
            rendered,
            label="Web icon",
            mismatch=f"Web icon pixels differ: {relative}",
            errors=errors,
        )
    favicon = _render_expected(
        lambda: rounded_icon(master, 16, inset_ratio=0.03),
        label="Web favicon",
        source=master,
        errors=errors,
    )
    if favicon is not None:
        _check_pixels(
            base / "favicon.png",
            favicon,
            label="Web favicon",
            mismatch="Web favicon pixels differ",
            errors=errors,
        )
    if manifest.get("background_color") != "#120D24":
        errors.append("Web background_color is not #120D24")
    if manifest.get("theme_color") != "#6D28D9":
        errors.append("Web theme_color is not #6D28D9")
    html_path = base / "index.html"
    html = _read_text(html_path, label="Web index", errors=errors)
    if html is not None:
        if "icons/Icon-192.png" not in html or "favicon.png" not in html:
            errors.append("Web HTML icon references changed")
    return errors


def validate_ohos(root: Path) -> list[str]:
    errors: list[str] = []
    app_scope = root / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png"
    entry = root / "chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png"
    master = _master(root)
    expected = _render_expected(
        lambda: rounded_icon(master, 114, inset_ratio=0.04),
        label="HarmonyOS launcher",
        source=master,
        errors=errors,
    )
    if expected is not None:
        for path in (app_scope, entry):
            _check_pixels(
                path,
                expected,
                label="HarmonyOS icon",
                mismatch=f"HarmonyOS icon pixels differ: {path}",
                errors=errors,
            )
    if app_scope.is_file() and entry.is_file():
        app_scope_bytes = _read_bytes(
            app_scope,
            label="HarmonyOS AppScope icon",
            errors=errors,
        )
        entry_bytes = _read_bytes(
            entry,
            label="HarmonyOS entry icon",
            errors=errors,
        )
        if (
            app_scope_bytes is not None
            and entry_bytes is not None
            and app_scope_bytes != entry_bytes
        ):
            errors.append("HarmonyOS AppScope and entry icons differ")
    app_config_path = root / "chatgpt_flutter_ohos/ohos/AppScope/app.json5"
    module_config_path = (
        root / "chatgpt_flutter_ohos/ohos/entry/src/main/module.json5"
    )
    app_json = _read_text(
        app_config_path,
        label="HarmonyOS AppScope config",
        errors=errors,
    )
    module_json = _read_text(
        module_config_path,
        label="HarmonyOS entry config",
        errors=errors,
    )
    if app_json is not None and '"icon": "$media:app_icon"' not in app_json:
        errors.append("AppScope no longer references $media:app_icon")
    if module_json is not None:
        if '"icon": "$media:icon"' not in module_json:
            errors.append("entry no longer references $media:icon")
        if '"startWindowIcon": "$media:icon"' not in module_json:
            errors.append("startWindowIcon no longer references $media:icon")
    return errors


VALIDATORS = {
    "android": validate_android,
    "ios": validate_ios,
    "macos": validate_macos,
    "windows": validate_windows,
    "web": validate_web,
    "ohos": validate_ohos,
}


def validate_platform(root: Path, platform: str) -> list[str]:
    validator = VALIDATORS[platform]
    try:
        return validator(root)
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
        struct.error,
        Image.DecompressionBombError,
    ) as error:
        return [
            f"{platform} validator could not inspect repository input under "
            f"{root}: {type(error).__name__}: {error}"
        ]


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
