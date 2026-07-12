import argparse
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _validate_png(path: Path, contract: dict) -> list[str]:
    errors: list[str] = []
    with Image.open(path) as image:
        expected = (int(contract["width"]), int(contract["height"]))
        if image.size != expected:
            errors.append(
                f"{path.name}: expected {expected[0]}x{expected[1]}, "
                f"got {image.width}x{image.height}"
            )
        if contract.get("opaque"):
            if "A" in image.getbands():
                alpha = image.getchannel("A")
                minimum, _ = alpha.getextrema()
                if minimum < 255:
                    errors.append(f"{path.name}: must be opaque")
    return errors


def _validate_svg(path: Path, contract: dict) -> list[str]:
    errors: list[str] = []
    root = ET.parse(path).getroot()
    expected = contract["viewBox"]
    actual = root.attrib.get("viewBox")
    if actual != expected:
        errors.append(f"{path.name}: expected viewBox {expected!r}, got {actual!r}")
    colors: set[str] = set()
    stroke_widths: list[float] = []
    for element in root.iter():
        if _local_name(element.tag) == "text":
            errors.append(f"{path.name}: <text> is forbidden")
        for attr, value in element.attrib.items():
            name = _local_name(attr)
            if name in {"fill", "stroke"}:
                normalized = value.strip().upper()
                if normalized.startswith("#"):
                    colors.add(normalized)
            if name == "stroke-width":
                stroke_widths.append(float(value))
            if name == "href" and value.startswith(("http:", "https:", "//")):
                errors.append(f"{path.name}: external href is forbidden")
    max_colors = int(contract.get("maxColors", 999))
    if len(colors) > max_colors:
        errors.append(f"{path.name}: uses {len(colors)} colors, max is {max_colors}")
    minimum = contract.get("minStrokeWidth")
    if minimum is not None:
        if not stroke_widths:
            errors.append(f"{path.name}: no stroke-width found")
        elif min(stroke_widths) < float(minimum):
            errors.append(
                f"{path.name}: stroke-width {min(stroke_widths)} is below {minimum}"
            )
    return errors


def validate(
    root: Path,
    manifest: dict,
    only: set[str] | None = None,
) -> list[str]:
    errors: list[str] = []
    for kind in ("png", "svg"):
        for filename, contract in manifest.get(kind, {}).items():
            if only is not None and filename not in only:
                continue
            path = root / filename
            if not path.is_file():
                errors.append(f"{filename}: missing")
                continue
            try:
                errors.extend(
                    _validate_png(path, contract)
                    if kind == "png"
                    else _validate_svg(path, contract)
                )
            except Exception as error:
                errors.append(f"{filename}: unreadable: {error}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", action="append", default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "asset_manifest.json").read_text(encoding="utf-8"))
    errors = validate(root, manifest, only=set(args.only) or None)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("starcore assets: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
