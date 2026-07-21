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
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, inner - 1, inner - 1), radius=radius, fill=255
    )
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
        directory.extend(
            struct.pack(
                "<BBBBHHII",
                encoded_size,
                encoded_size,
                0,
                0,
                1,
                32,
                len(payload),
                offset,
            )
        )
        body.extend(payload)
        offset += len(payload)
    path.write_bytes(bytes(directory + body))


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
        _save(
            rounded_icon(_master(root), size, inset_ratio=0.08),
            base / f"app_icon_{size}.png",
        )


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
    _save(
        image,
        root
        / "chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png",
    )
    _save(
        image,
        root
        / "chatgpt_flutter_ohos/ohos/entry/src/main/resources/base/media/icon.png",
    )


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
