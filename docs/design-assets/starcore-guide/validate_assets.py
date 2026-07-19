import argparse
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image


SVG_NAMESPACE = "http://www.w3.org/2000/svg"
ALLOWED_ELEMENTS = {"svg", "title", "path", "circle"}
ALLOWED_ATTRIBUTES = {
    "svg": {"viewBox"},
    "title": set(),
    "path": {
        "d",
        "fill",
        "stroke",
        "stroke-width",
        "stroke-linecap",
        "stroke-linejoin",
    },
    "circle": {"cx", "cy", "r", "fill", "stroke", "stroke-width"},
}
PAINT_ATTRIBUTES = {"fill", "stroke"}
HEX_COLOR = re.compile(r"#[0-9A-Fa-f]{6}\Z")


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _namespace(tag: str) -> str | None:
    if not tag.startswith("{"):
        return None
    return tag[1:].split("}", 1)[0]


def _validate_png(path: Path, contract: dict) -> list[str]:
    errors: list[str] = []
    with Image.open(path) as image:
        if image.format != "PNG":
            errors.append(f"{path.name}: expected PNG format, got {image.format}")
        expected = (int(contract["width"]), int(contract["height"]))
        if image.size != expected:
            errors.append(
                f"{path.name}: expected {expected[0]}x{expected[1]}, "
                f"got {image.width}x{image.height}"
            )
        if contract.get("opaque"):
            alpha = image.convert("RGBA").getchannel("A")
            minimum, _ = alpha.getextrema()
            if minimum < 255:
                errors.append(f"{path.name}: must be opaque")
    return errors


def _validate_svg(
    path: Path,
    contract: dict,
    palette: set[str],
) -> list[str]:
    errors: list[str] = []
    root = ET.parse(path).getroot()
    expected = contract["viewBox"]
    actual = root.attrib.get("viewBox")
    if actual != expected:
        errors.append(f"{path.name}: expected viewBox {expected!r}, got {actual!r}")
    colors: set[str] = set()
    for element in root.iter():
        element_name = _local_name(element.tag)
        if element_name == "style":
            errors.append(f"{path.name}: <style> is forbidden")
        elif element_name not in ALLOWED_ELEMENTS:
            errors.append(f"{path.name}: <{element_name}> is not allowlisted")
        if _namespace(element.tag) != SVG_NAMESPACE:
            errors.append(
                f"{path.name}: namespace is not allowlisted on <{element_name}>"
            )

        allowed_attributes = ALLOWED_ATTRIBUTES.get(element_name, set())
        for attr, value in sorted(element.attrib.items()):
            attr_name = _local_name(attr)
            if attr_name == "href":
                errors.append(f"{path.name}: href is forbidden on <{element_name}>")
                continue
            if attr_name == "style":
                errors.append(
                    f"{path.name}: style attribute is forbidden on <{element_name}>"
                )
                continue
            if _namespace(attr) is not None or attr_name not in allowed_attributes:
                errors.append(
                    f"{path.name}: attribute {attr_name!r} is not allowlisted "
                    f"on <{element_name}>"
                )
                continue
            if attr_name in PAINT_ATTRIBUTES:
                paint = value.strip()
                if paint == "none":
                    continue
                if not HEX_COLOR.fullmatch(paint):
                    errors.append(
                        f"{path.name}: {attr_name} value {paint!r} is not "
                        f"allowlisted on <{element_name}>"
                    )
                    continue
                normalized = paint.upper()
                colors.add(normalized)
                if normalized not in palette:
                    errors.append(
                        f"{path.name}: {attr_name} color {normalized} is outside "
                        "the approved palette"
                    )

        if element_name not in {"path", "circle"}:
            continue
        stroke = element.attrib.get("stroke")
        if stroke is None or stroke.strip() == "none":
            continue
        width_text = element.attrib.get("stroke-width")
        if width_text is None:
            errors.append(
                f"{path.name}: visible stroke on <{element_name}> requires "
                "explicit stroke-width"
            )
            continue
        try:
            width = float(width_text)
        except ValueError:
            errors.append(
                f"{path.name}: stroke-width {width_text!r} on <{element_name}> "
                "must be numeric"
            )
            continue
        if not math.isfinite(width):
            errors.append(
                f"{path.name}: stroke-width {width_text!r} on <{element_name}> "
                "must be finite"
            )
            continue
        minimum = contract.get("minStrokeWidth")
        if minimum is not None and width < float(minimum):
            errors.append(
                f"{path.name}: stroke-width {width} on <{element_name}> "
                f"is below {minimum}"
            )

    max_colors = int(contract.get("maxColors", 999))
    if len(colors) > max_colors:
        errors.append(f"{path.name}: uses {len(colors)} colors, max is {max_colors}")
    return errors


def validate(
    root: Path,
    manifest: dict,
    only: set[str] | None = None,
) -> list[str]:
    errors: list[str] = []
    known = {
        filename
        for kind in ("png", "svg")
        for filename in manifest.get(kind, {})
    }
    if only is not None:
        errors.extend(
            f"{filename}: unknown asset in only filter"
            for filename in sorted(only - known)
        )
    palette = {
        color.upper()
        for color in manifest.get("palette", [])
        if isinstance(color, str)
    }
    for kind in ("png", "svg"):
        for filename, contract in sorted(manifest.get(kind, {}).items()):
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
                    else _validate_svg(path, contract, palette)
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
