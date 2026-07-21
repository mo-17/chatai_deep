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
