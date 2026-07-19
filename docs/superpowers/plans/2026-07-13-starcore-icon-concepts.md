# 星核向导图标首轮概念 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一套可评审的星核向导首轮概念资产，包括 1 个启动图标、4 个导航状态图标、2 个助手头像、2 个工具图标和 1 张总览稿。

**Architecture:** 启动图标和助手头像使用内置 `image_gen` 生成赛璐璐栅格插画；导航与工具图标由确定性 SVG 源文件实现，避免小尺寸路径漂移。一个独立的 Python/Pillow 验证器检查文件清单、尺寸、透明度和 SVG 合法性，Node/Playwright 把全部资产渲染为固定 2048×1536 的评审总览稿。

**Tech Stack:** Built-in `image_gen`, SVG 1.1, bundled Python 3 + Pillow 12.2.0, bundled Node.js + Playwright 1.61.1, `xmllint`, `sips`, Git

## Global Constraints

- 执行前必须使用 `superpowers:using-git-worktrees` 创建隔离 worktree；当前主工作区含有与本任务无关的修改。
- 首轮只创建 `docs/design-assets/starcore-guide/` 下的概念资产，不修改 Flutter 代码、`pubspec.yaml` 或任何平台 AppIcon。
- 核心 IP 必须是非人类、无性别的「星核向导」：圆形悬浮主体、顶部四芒星核、双侧几何光翼、深色面罩和发光眼神。
- 造型比例保持约 70% 圆润体块、30% 锐利切角；不得出现头发、服装、人体比例、武器、尖牙、骷髅、血迹或敌意红眼。
- 品牌色固定为 Midnight `#120D24`、Brand Purple `#6D28D9`、Core Violet `#7C3AED`、Energy Magenta `#BE185D`、Energy Highlight `#EC4899`、Digital Cyan `#22D3EE`、Highlight `#F5F3FF`。
- 单个 24px 图标最多同时使用三种颜色，等效主描边不低于 1.75px；默认态与选中态不得只靠颜色区分。
- 图标与头像素材本身不得包含文字、水印、平台徽标、第三方商标或外部网络资源；`contact-sheet.html` 的评审标签不属于图标内容。
- 栅格文件必须为不透明 PNG：启动图标 1024×1024，助手头像 512×512，总览稿 2048×1536。
- SVG 必须使用 `viewBox="0 0 24 24"`，不得含 `<text>` 或外部 `href`。
- `docs/` 被仓库 `.gitignore` 忽略；每次提交必须用 `git add -f` 且只列出本任务的精确路径。

---

## File Map

**Create under `docs/design-assets/starcore-guide/`:**

- `asset_manifest.json` — 首轮文件清单与机器可验证的格式约束。
- `validate_assets.py` — PNG/SVG 合同验证器。
- `test_validate_assets.py` — 验证器单元测试。
- `generation-prompts.md` — 最终使用的三条 image-generation prompt。
- `app-icon-concept.png` — 1024×1024 启动图标母版。
- `nav-chat-default.svg` — 聊天导航默认态。
- `nav-chat-selected.svg` — 聊天导航选中态。
- `nav-create-default.svg` — 创作导航默认态。
- `nav-create-selected.svg` — 创作导航选中态。
- `assistant-explorer.png` — 512×512 探索向导头像。
- `assistant-creator.png` — 512×512 创作搭档头像。
- `tool-web-search.svg` — 联网搜索工具图标。
- `tool-knowledge-search.svg` — 知识检索工具图标。
- `contact-sheet.html` — 总览稿的确定性排版源文件。
- `contact-sheet.png` — 2048×1536 评审总览稿。
- `render_contact_sheet.cjs` — 使用 Playwright 截取总览稿的本地脚本。

No existing runtime files are modified.

---

### Task 1: Asset contract and validator

**Files:**

- Create: `docs/design-assets/starcore-guide/test_validate_assets.py`
- Create: `docs/design-assets/starcore-guide/asset_manifest.json`
- Create: `docs/design-assets/starcore-guide/validate_assets.py`

**Interfaces:**

- Consumes: bundled Python at `/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3` and Pillow 12.2.0.
- Produces: `validate(root: Path, manifest: dict, only: set[str] | None = None) -> list[str]` and CLI `validate_assets.py [--only FILE]...`.

- [ ] **Step 1: Write the failing validator test**

Create `docs/design-assets/starcore-guide/test_validate_assets.py`:

```python
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from validate_assets import validate


class ValidateAssetsTest(unittest.TestCase):
    def test_valid_png_and_svg_contracts_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGB", (32, 32), "#120D24").save(root / "sample.png")
            (root / "sample.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'viewBox="0 0 24 24"><title>Sample</title>'
                '<path d="M4 12h16" stroke="#7C3AED" stroke-width="1.8"/></svg>',
                encoding="utf-8",
            )
            manifest = {
                "png": {
                    "sample.png": {
                        "width": 32,
                        "height": 32,
                        "opaque": True,
                    }
                },
                "svg": {
                    "sample.svg": {
                        "viewBox": "0 0 24 24",
                        "maxColors": 3,
                        "minStrokeWidth": 1.75,
                    }
                },
            }

            self.assertEqual([], validate(root, manifest))

    def test_only_filter_and_contract_errors_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            Image.new("RGBA", (31, 32), (0, 0, 0, 0)).save(root / "bad.png")
            manifest = {
                "png": {
                    "bad.png": {"width": 32, "height": 32, "opaque": True},
                    "ignored.png": {"width": 1, "height": 1, "opaque": True},
                },
                "svg": {},
            }

            errors = validate(root, manifest, only={"bad.png"})

            self.assertTrue(any("expected 32x32" in error for error in errors))
            self.assertTrue(any("must be opaque" in error for error in errors))
            self.assertFalse(any("ignored.png" in error for error in errors))

    def test_svg_rejects_text_external_links_color_overflow_and_thin_strokes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bad.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 24 24">'
                '<text>bad</text><image xlink:href="https://example.com/a.png"/>'
                '<path d="M2 2h20" fill="#111111" stroke="#222222" '
                'stroke-width="1"/><path d="M2 4h20" fill="#333333" '
                'stroke="#444444" stroke-width="2"/></svg>',
                encoding="utf-8",
            )
            manifest = {
                "png": {},
                "svg": {
                    "bad.svg": {
                        "viewBox": "0 0 24 24",
                        "maxColors": 3,
                        "minStrokeWidth": 1.75,
                    }
                },
            }

            errors = validate(root, manifest)

            self.assertTrue(any("<text> is forbidden" in error for error in errors))
            self.assertTrue(any("external href is forbidden" in error for error in errors))
            self.assertTrue(any("uses 4 colors" in error for error in errors))
            self.assertTrue(any("below 1.75" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and confirm the module is missing**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/test_validate_assets.py
```

Expected: FAIL with `ModuleNotFoundError: No module named 'validate_assets'`.

- [ ] **Step 3: Create the manifest**

Create `docs/design-assets/starcore-guide/asset_manifest.json`:

```json
{
  "png": {
    "app-icon-concept.png": { "width": 1024, "height": 1024, "opaque": true },
    "assistant-explorer.png": { "width": 512, "height": 512, "opaque": true },
    "assistant-creator.png": { "width": 512, "height": 512, "opaque": true },
    "contact-sheet.png": { "width": 2048, "height": 1536, "opaque": true }
  },
  "svg": {
    "nav-chat-default.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 },
    "nav-chat-selected.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 },
    "nav-create-default.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 },
    "nav-create-selected.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 },
    "tool-web-search.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 },
    "tool-knowledge-search.svg": { "viewBox": "0 0 24 24", "maxColors": 3, "minStrokeWidth": 1.75 }
  }
}
```

- [ ] **Step 4: Implement the validator**

Create `docs/design-assets/starcore-guide/validate_assets.py`:

```python
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
```

- [ ] **Step 5: Run the unit test and the empty-directory contract check**

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/test_validate_assets.py
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py
```

Expected: unit tests report `Ran 3 tests ... OK`; the full validator exits 1 and lists the ten missing deliverable files.

- [ ] **Step 6: Commit the contract**

```bash
git add -f docs/design-assets/starcore-guide/asset_manifest.json docs/design-assets/starcore-guide/validate_assets.py docs/design-assets/starcore-guide/test_validate_assets.py
git commit -m "test(design): add starcore asset contract"
```

---

### Task 2: Deterministic navigation and tool SVGs

**Files:**

- Create: `docs/design-assets/starcore-guide/nav-chat-default.svg`
- Create: `docs/design-assets/starcore-guide/nav-chat-selected.svg`
- Create: `docs/design-assets/starcore-guide/nav-create-default.svg`
- Create: `docs/design-assets/starcore-guide/nav-create-selected.svg`
- Create: `docs/design-assets/starcore-guide/tool-web-search.svg`
- Create: `docs/design-assets/starcore-guide/tool-knowledge-search.svg`

**Interfaces:**

- Consumes: the palette and 24×24 SVG contract from Task 1.
- Produces: six standalone SVG files with no runtime dependency.

- [ ] **Step 1: Run the vector contract before creating files**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py \
  --only nav-chat-default.svg --only nav-chat-selected.svg \
  --only nav-create-default.svg --only nav-create-selected.svg \
  --only tool-web-search.svg --only tool-knowledge-search.svg
```

Expected: FAIL with six `missing` lines.

- [ ] **Step 2: Create the chat navigation states**

Create `nav-chat-default.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>聊天 默认态</title>
  <path d="M4 5.5h16v10.5H11l-4.5 3.5V16H4z" fill="none" stroke="#6D28D9" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M8 9h8M8 12.5h5" fill="none" stroke="#6D28D9" stroke-width="1.8" stroke-linecap="round"/>
</svg>
```

Create `nav-chat-selected.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>聊天 选中态</title>
  <path d="M4 5.5h16v10.5H11l-4.5 3.5V16H4z" fill="#120D24" stroke="#22D3EE" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M8 9h8M8 12.5h5" fill="none" stroke="#22D3EE" stroke-width="1.8" stroke-linecap="round"/>
  <path d="M18.25 3.4l.65 1.55 1.6.65-1.6.65-.65 1.55-.65-1.55-1.6-.65 1.6-.65z" fill="#EC4899"/>
</svg>
```

- [ ] **Step 3: Create the creation navigation states**

Create `nav-create-default.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>创作 默认态</title>
  <path d="M5 18.5c4.8-.9 8.4-4.7 10.2-10.7L20 5.3l-.8 5.2C16.4 16.2 12 19.4 5 20z" fill="none" stroke="#6D28D9" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M7 17.5l3 2M15.4 8l3 2" fill="none" stroke="#6D28D9" stroke-width="1.8" stroke-linecap="round"/>
</svg>
```

Create `nav-create-selected.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>创作 选中态</title>
  <path d="M5 18.5c4.8-.9 8.4-4.7 10.2-10.7L20 5.3l-.8 5.2C16.4 16.2 12 19.4 5 20z" fill="#120D24" stroke="#22D3EE" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M7 17.5l3 2M15.4 8l3 2" fill="none" stroke="#EC4899" stroke-width="1.8" stroke-linecap="round"/>
  <path d="M6.3 5.1l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z" fill="#22D3EE"/>
</svg>
```

- [ ] **Step 4: Create the tool icons**

Create `tool-web-search.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>联网搜索</title>
  <circle cx="10.2" cy="10.2" r="5.7" fill="none" stroke="#6D28D9" stroke-width="1.8"/>
  <path d="M14.5 14.5L20 20" fill="none" stroke="#BE185D" stroke-width="2" stroke-linecap="round"/>
  <path d="M10.2 5.9l.75 1.8 1.8.75-1.8.75-.75 1.8-.75-1.8-1.8-.75 1.8-.75z" fill="#22D3EE"/>
</svg>
```

Create `tool-knowledge-search.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <title>知识检索</title>
  <path d="M3.5 5h6.2c1.6 0 2.8.8 2.8 2.1V20c0-1.6-1.2-2.5-2.8-2.5H3.5z" fill="#120D24" stroke="#7C3AED" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M20.5 5h-6.2c-1.6 0-2.8.8-2.8 2.1V20c0-1.6 1.2-2.5 2.8-2.5h6.2z" fill="#120D24" stroke="#7C3AED" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M12 7.2l.7 1.7 1.7.7-1.7.7-.7 1.7-.7-1.7-1.7-.7 1.7-.7z" fill="#22D3EE"/>
</svg>
```

- [ ] **Step 5: Validate XML and asset contracts**

```bash
xmllint --noout docs/design-assets/starcore-guide/nav-chat-default.svg docs/design-assets/starcore-guide/nav-chat-selected.svg docs/design-assets/starcore-guide/nav-create-default.svg docs/design-assets/starcore-guide/nav-create-selected.svg docs/design-assets/starcore-guide/tool-web-search.svg docs/design-assets/starcore-guide/tool-knowledge-search.svg
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py \
  --only nav-chat-default.svg --only nav-chat-selected.svg \
  --only nav-create-default.svg --only nav-create-selected.svg \
  --only tool-web-search.svg --only tool-knowledge-search.svg
```

Expected: `xmllint` exits 0 with no output; validator prints `starcore assets: OK`.

- [ ] **Step 6: Commit the vectors**

```bash
git add -f docs/design-assets/starcore-guide/nav-chat-default.svg docs/design-assets/starcore-guide/nav-chat-selected.svg docs/design-assets/starcore-guide/nav-create-default.svg docs/design-assets/starcore-guide/nav-create-selected.svg docs/design-assets/starcore-guide/tool-web-search.svg docs/design-assets/starcore-guide/tool-knowledge-search.svg
git commit -m "feat(design): add starcore vector icon concepts"
```

---

### Task 3: App icon raster master

**Files:**

- Create: `docs/design-assets/starcore-guide/generation-prompts.md`
- Create: `docs/design-assets/starcore-guide/app-icon-concept.png`

**Interfaces:**

- Consumes: approved Starcore Guide design and palette.
- Produces: the canonical raster reference used by both assistant-avatar prompts.

- [ ] **Step 1: Run the app-icon contract before generation**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py --only app-icon-concept.png
```

Expected: FAIL with `app-icon-concept.png: missing`.

- [ ] **Step 2: Record and run the exact app-icon prompt**

Create `generation-prompts.md` with the following `## App icon` prompt, then call the built-in `image_gen` tool once with no reference images:

```text
Use case: logo-brand
Asset type: 1024x1024 mobile app icon concept for an anime-styled AI chat app
Primary request: Create the canonical Starcore Guide, a gender-neutral non-human digital spirit mascot with a cool cyber-anime attitude.
Scene/backdrop: Opaque rounded-square app-icon composition, deep midnight violet backdrop with a restrained violet-to-magenta energy gradient and a very subtle digital halo.
Subject: One floating circular spirit body, a bright four-point star core centered above the head, two symmetric geometric light wings, a dark visor face, and two sharp but calm luminous eyes. No human anatomy.
Style/medium: High-end Japanese cel-shaded mascot illustration, crisp vector-friendly silhouette, clean graphic shadow shapes, polished mobile app icon.
Composition/framing: Centered front view, subject fills about 72% of the square, all star-core and wing tips inside the central 80% safe area, immediately readable at thumbnail size.
Lighting/mood: Cool, confident, reliable, agile; controlled cyan rim light and magenta energy accent.
Color palette: #120D24, #6D28D9, #7C3AED, #BE185D, #EC4899, #22D3EE, #F5F3FF.
Constraints: Opaque background; one mascot only; no text; no letters; no watermark; no platform badge; no transparent corners. Preserve 70% rounded mass and 30% sharp cyber cuts.
Avoid: human face, hair, clothing, limbs, gender cues, animal ears, conventional robot body, weapon, red hostile eyes, skull, glass material, tiny circuitry, photorealism, 3D toy rendering.
```

Pass the result through `generatedImage(result)`. Use the exact local path returned by the tool as the source file; do not assume a temp-directory path.

- [ ] **Step 3: Normalize the generated file into the project**

Use `sips` with the path returned by `image_gen`:

```bash
sips -z 1024 1024 "$SOURCE" --out docs/design-assets/starcore-guide/app-icon-concept.png
```

Expected: `app-icon-concept.png` exists at exactly 1024×1024.

- [ ] **Step 4: Inspect and validate the master**

Open `app-icon-concept.png` with `view_image` at original detail. Reject and regenerate if any of these are true: human or animal reading, missing four-point star, cropped light wings, hostile expression, text/watermark, muddy thumbnail silhouette, transparent pixels.

Then run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py --only app-icon-concept.png
```

Expected: `starcore assets: OK`.

- [ ] **Step 5: Commit the prompt and master**

```bash
git add -f docs/design-assets/starcore-guide/generation-prompts.md docs/design-assets/starcore-guide/app-icon-concept.png
git commit -m "feat(design): add starcore app icon concept"
```

---

### Task 4: Assistant avatar variants

**Files:**

- Modify: `docs/design-assets/starcore-guide/generation-prompts.md`
- Create: `docs/design-assets/starcore-guide/assistant-explorer.png`
- Create: `docs/design-assets/starcore-guide/assistant-creator.png`

**Interfaces:**

- Consumes: `app-icon-concept.png` as the only character-identity reference.
- Produces: two 512×512 opaque avatars sharing the exact same body, star core, visor and light-wing skeleton.

- [ ] **Step 1: Run the avatar contracts before generation**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py --only assistant-explorer.png --only assistant-creator.png
```

Expected: FAIL with two `missing` lines.

- [ ] **Step 2: Inspect the reference and generate Explorer**

Load `app-icon-concept.png` with `view_image`, then append this exact prompt under `## Explorer avatar` in `generation-prompts.md`. Call built-in `image_gen` with `referenced_image_paths` containing only the app-icon path:

```text
Use case: stylized-concept
Asset type: square assistant avatar for circular crop
Input images: Image 1 is the canonical identity reference; preserve its exact Starcore Guide silhouette, four-point star, visor, eye geometry, and twin light wings.
Primary request: Create the Explorer variant of the same gender-neutral Starcore Guide digital spirit.
Scene/backdrop: Opaque circular midnight-violet energy field inside a square canvas, clean edge and no environmental scene.
Subject: The same non-human floating spirit from Image 1, with a slightly focused eye expression and one minimal cyan scanning-ring accessory. Do not change the base body.
Style/medium: Match Image 1's crisp high-end anime cel shading and graphic shadow shapes.
Composition/framing: Centered front view; star core, visor, and wings remain inside the central 70% circular-crop safe area.
Color palette: Preserve Image 1; increase #22D3EE emphasis only for the scanning accessory.
Constraints: Change only expression and one scanning-ring accessory; preserve identity and proportions; opaque image; no text; no watermark.
Avoid: human or animal features, gender cues, new limbs, clothing, weapon, extra mascot, cropped star, detailed background, translucent glass.
```

- [ ] **Step 3: Generate Creator as a separate call**

Append this exact prompt under `## Creator avatar`, then make a second built-in `image_gen` call with the same single reference path:

```text
Use case: stylized-concept
Asset type: square assistant avatar for circular crop
Input images: Image 1 is the canonical identity reference; preserve its exact Starcore Guide silhouette, four-point star, visor, eye geometry, and twin light wings.
Primary request: Create the Creator variant of the same gender-neutral Starcore Guide digital spirit.
Scene/backdrop: Opaque circular midnight-violet energy field inside a square canvas, clean edge and no environmental scene.
Subject: The same non-human floating spirit from Image 1, with a confident creative eye expression and one short magenta pulse-ribbon accessory. Do not change the base body.
Style/medium: Match Image 1's crisp high-end anime cel shading and graphic shadow shapes.
Composition/framing: Centered front view; star core, visor, and wings remain inside the central 70% circular-crop safe area.
Color palette: Preserve Image 1; increase #EC4899 emphasis only for the pulse ribbon.
Constraints: Change only expression and one pulse-ribbon accessory; preserve identity and proportions; opaque image; no text; no watermark.
Avoid: human or animal features, gender cues, new limbs, clothing, weapon, extra mascot, cropped star, detailed background, translucent glass.
```

- [ ] **Step 4: Normalize both outputs**

Use the exact paths returned by the two image calls:

```bash
sips -z 512 512 "$EXPLORER_SOURCE" --out docs/design-assets/starcore-guide/assistant-explorer.png
sips -z 512 512 "$CREATOR_SOURCE" --out docs/design-assets/starcore-guide/assistant-creator.png
```

- [ ] **Step 5: Inspect identity consistency and validate**

Open both avatars and the app-icon master with `view_image`. Compare: body diameter, star shape and placement, visor outline, eye spacing, wing angle, circular-crop safety. Reject any avatar that changes more than expression, energy emphasis and its single allowed accessory.

Run:

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py --only assistant-explorer.png --only assistant-creator.png
```

Expected: `starcore assets: OK`.

- [ ] **Step 6: Commit the avatars**

```bash
git add -f docs/design-assets/starcore-guide/generation-prompts.md docs/design-assets/starcore-guide/assistant-explorer.png docs/design-assets/starcore-guide/assistant-creator.png
git commit -m "feat(design): add starcore assistant avatars"
```

---

### Task 5: Contact sheet and final acceptance gate

**Files:**

- Create: `docs/design-assets/starcore-guide/contact-sheet.html`
- Create: `docs/design-assets/starcore-guide/render_contact_sheet.cjs`
- Create: `docs/design-assets/starcore-guide/contact-sheet.png`

**Interfaces:**

- Consumes: all nine concept asset files from Tasks 2–4.
- Produces: one 2048×1536 opaque review image plus its deterministic local render source.

- [ ] **Step 1: Run the complete contract before the contact sheet exists**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py
```

Expected: FAIL only with `contact-sheet.png: missing`.

- [ ] **Step 2: Create the contact-sheet source**

Create `contact-sheet.html`:

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <style>
    * { box-sizing: border-box; }
    html, body { width: 2048px; height: 1536px; margin: 0; overflow: hidden; }
    body { padding: 76px; background: #fffbfe; color: #1e1b2e; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    h1 { margin: 0; font-size: 58px; letter-spacing: -1.5px; }
    .sub { margin: 12px 0 34px; color: #514a63; font-size: 23px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 26px; }
    section { min-height: 535px; padding: 28px; border: 2px solid #e7dff1; border-radius: 30px; background: #fff; }
    h2 { margin: 0 0 8px; color: #6d28d9; font-size: 31px; }
    .meta { margin-bottom: 22px; color: #786f85; font-size: 18px; }
    .row { display: flex; align-items: center; justify-content: center; gap: 34px; min-height: 385px; }
    .app { width: 355px; height: 355px; border-radius: 82px; box-shadow: 0 22px 52px rgba(109,40,217,.24); }
    .avatar { width: 270px; height: 270px; border-radius: 50%; border: 7px solid #7c3aed; }
    .sample { display: grid; justify-items: center; gap: 11px; color: #514a63; font-size: 18px; }
    .icon-tile { display: grid; place-items: center; width: 142px; height: 142px; border-radius: 34px; background: #f7f3fd; border: 2px solid #e7dff1; }
    .icon-tile.dark { background: #120d24; }
    .icon-tile img { width: 64px; height: 64px; }
    .sizes { display: flex; align-items: end; gap: 24px; }
    .sizes img:nth-child(1) { width: 48px; height: 48px; }
    .sizes img:nth-child(2) { width: 64px; height: 64px; }
    .sizes img:nth-child(3) { width: 96px; height: 96px; }
    .palette { position: absolute; right: 76px; top: 92px; display: flex; gap: 10px; }
    .palette i { width: 30px; height: 30px; border-radius: 50%; border: 2px solid rgba(30,27,46,.12); }
  </style>
</head>
<body>
  <div class="palette"><i style="background:#120d24"></i><i style="background:#6d28d9"></i><i style="background:#7c3aed"></i><i style="background:#be185d"></i><i style="background:#22d3ee"></i><i style="background:#f5f3ff"></i></div>
  <h1>星核向导 · 首轮图标系统</h1>
  <p class="sub">无性别数字精灵 · 赛博酷飒 · 70% 圆润体块 / 30% 锐利切角</p>
  <div class="grid">
    <section><h2>A · App 启动图标</h2><div class="meta">1024×1024 不透明母版</div><div class="row"><img class="app" src="app-icon-concept.png"></div></section>
    <section><h2>B · 导航状态</h2><div class="meta">聊天 / 创作 · 默认与选中</div><div class="row"><div class="sample"><div class="icon-tile"><img src="nav-chat-default.svg"></div><span>聊天 默认</span></div><div class="sample"><div class="icon-tile dark"><img src="nav-chat-selected.svg"></div><span>聊天 选中</span></div><div class="sample"><div class="icon-tile"><img src="nav-create-default.svg"></div><span>创作 默认</span></div><div class="sample"><div class="icon-tile dark"><img src="nav-create-selected.svg"></div><span>创作 选中</span></div></div></section>
    <section><h2>C · 助手头像</h2><div class="meta">相同骨架 · 冰蓝探索 / 玫红创作</div><div class="row"><div class="sample"><img class="avatar" src="assistant-explorer.png"><span>探索向导</span></div><div class="sample"><img class="avatar" src="assistant-creator.png"><span>创作搭档</span></div></div></section>
    <section><h2>D · 工具图标</h2><div class="meta">语义优先 · 星核作为识别锚点</div><div class="row"><div class="sample"><div class="icon-tile dark"><img src="tool-web-search.svg"></div><span>联网搜索</span></div><div class="sample"><div class="icon-tile dark"><img src="tool-knowledge-search.svg"></div><span>知识检索</span></div><div class="sample"><div class="sizes"><img src="tool-web-search.svg"><img src="tool-web-search.svg"><img src="tool-web-search.svg"></div><span>24 / 32 / 48px 对照</span></div></div></section>
  </div>
</body>
</html>
```

- [ ] **Step 3: Create the deterministic renderer**

Create `render_contact_sheet.cjs`:

```javascript
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { chromium } = require("/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright");

(async () => {
  const root = __dirname;
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 2048, height: 1536 }, deviceScaleFactor: 1 });
    await page.goto(pathToFileURL(path.join(root, "contact-sheet.html")).href, { waitUntil: "load" });
    await page.screenshot({ path: path.join(root, "contact-sheet.png"), type: "png" });
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

- [ ] **Step 4: Render and inspect the contact sheet**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node docs/design-assets/starcore-guide/render_contact_sheet.cjs
```

Expected: `contact-sheet.png` is created at 2048×1536. Open it with `view_image` at original detail and verify: no clipping, all labels visible, four groups present, SVGs sharp, both avatars circular-crop safe, and no broken-image placeholder.

- [ ] **Step 5: Run the complete automated acceptance gate**

```bash
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/test_validate_assets.py
/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 docs/design-assets/starcore-guide/validate_assets.py
xmllint --noout docs/design-assets/starcore-guide/*.svg
git diff --check
```

Expected: three tests pass; validator prints `starcore assets: OK`; `xmllint` and `git diff --check` exit 0 with no output.

- [ ] **Step 6: Confirm scope and commit the review artifact**

Run `git status --short` and confirm no existing runtime file is staged. Then commit only the contact-sheet source, renderer and PNG:

```bash
git add -f docs/design-assets/starcore-guide/contact-sheet.html docs/design-assets/starcore-guide/render_contact_sheet.cjs docs/design-assets/starcore-guide/contact-sheet.png
git commit -m "docs(design): add starcore icon review sheet"
```

- [ ] **Step 7: Final handoff check**

Run:

```bash
git log -5 --oneline
git status --short
```

Expected: the five task commits are visible on the isolated branch; unrelated main-worktree changes are absent from the worktree and were never staged. Present `contact-sheet.png` to the user and explicitly state that no App runtime integration has been performed.

---

### Task 6: 2026-07-15 final-review remediation（superseding task）

本任务记录最终全分支审查后的用户批准决议。它在冲突处**明确取代**早期 Task 1 中的 manifest/validator 实现片段与“3 tests”预期，也取代 Task 5 中的 contact-sheet HTML、renderer 片段和最终验收措辞；Task 1/5 原文保留为实施历史，不代表当前合同。书面设计规范优先于早期 exact snippets。

**批准后的边界：**

- App icon 与助手头像至少露出星核、面罩、双翼中的两个；24px 功能 SVG 保持现有 canonical 路径，不增加第二个角色提示。工具图标各带一颗四芒星；导航默认/选中状态对作为品牌单元，选中态带四芒星即可。
- 六个 SVG 的验收矩阵必须是 DPR 1 下真实 24/32/48 CSS px，并覆盖 `#FFFBFE`、`#FCE7F3`、`#120D24`。
- 2048×1536 总览只显示标注原生尺寸的栅格缩略图；HTML 缩略图直链 canonical 1024×1024 / 512×512 PNG，供独立 1:1 检查。
- Renderer 只承诺固定评审机上的确定性；跨机器/CI 字节级 hash 不在首轮范围。仓库提交的 PNG 是 canonical 评审制品。
- 两张头像前景宽度占画布比例最多相差 5 个百分点；实测 4.883 个百分点。身份骨架与中央 70% 裁切安全要求不因此放宽。
- 本修复波不修改三张 canonical 栅格角色资产或六个 canonical SVG，也不修改 App runtime；不执行 `git add` / `git commit`。

**Files:**

- Modify: `docs/design-assets/starcore-guide/asset_manifest.json`
- Modify: `docs/design-assets/starcore-guide/validate_assets.py`
- Modify: `docs/design-assets/starcore-guide/test_validate_assets.py`
- Modify: `docs/design-assets/starcore-guide/contact-sheet.html`
- Modify: `docs/design-assets/starcore-guide/render_contact_sheet.cjs`
- Regenerate: `docs/design-assets/starcore-guide/contact-sheet.png`
- Modify: `docs/superpowers/specs/2026-07-13-starcore-icon-system-design.md`
- Modify: `docs/superpowers/plans/2026-07-13-starcore-icon-concepts.md`
- Create: `.superpowers/sdd/final-fix-report.md`

- [ ] **Step 1: 先写 validator 回归测试并捕获 RED**

  覆盖 renamed JPEG、palette PNG+tRNS、unknown `only`、style element/attribute、任意 href/xlink:href、可见描边缺少显式宽度、非 allowlist element/attribute/paint、off-palette hex 与 `maxColors`。预期最终 suite 共 **12 tests**；在实现前必须看到新增行为因 validator 缺口失败。

- [ ] **Step 2: 最小实现 validator GREEN**

  顶层唯一 `palette` 字段列出批准的七色；PNG 强制 Pillow `format == "PNG"` 并通过 RGBA alpha 检查不透明；SVG 仅允许 `svg/title/path/circle` 及当前六文件所需属性，拒绝 style/href/未知 paint，并逐个校验可见描边的显式有限数值宽度。保留 `validate(...)` 与 CLI 形状。预期：`Ran 12 tests ... OK`，完整 validator 输出 `starcore assets: OK`。

- [ ] **Step 3: 对齐规范并重建真实验收矩阵**

  更新 spec 状态、品牌锚点规则、尺寸/背景/原图直链、本地渲染边界与头像尺度容差。联系表保留 A–D 概览，并明确展示 6×3×3 共 54 个功能 SVG 样本；缩略图标签含原生栅格尺寸且可直接链接原件。

- [ ] **Step 4: 强化 renderer 并生成 canonical PNG**

  Playwright 解析顺序为 `STARCORE_PLAYWRIGHT_MODULE` → local `playwright` → bundled fallback；viewport 固定 2048×1536、DPR 1。截图前等待 `document.fonts.ready` 与每张图片 `decode()`，破图、零 natural size 或 scroll dimensions 超界均非零退出。固定机器连续渲染两次的 SHA-256 必须一致。

- [ ] **Step 5: Fresh final acceptance**

  运行 12-test suite、完整 validator、六 SVG 的 `xmllint --noout`、双次 render/hash、`sips` 尺寸与 alpha、`view_image(detail: original)`、`git diff --check`、未 staged 与无 App runtime 变更的 scope check。完整 RED/GREEN、hash、视觉结论、修改文件和 concerns 写入 `.superpowers/sdd/final-fix-report.md`。
