"""非敏感合成材料验证真实 OCR、页号、预览大小与坐标；没有依赖时跳过。"""
import base64
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(all(importlib.util.find_spec(name) for name in ("rapidocr", "PIL", "pypdfium2")),
                     "install pinned OCR requirements to run engine acceptance")
class EnginePreviewTest(unittest.TestCase):
    def test_image_and_selected_scanned_pdf_previews(self):
        from PIL import Image, ImageDraw
        from engine import recognize

        class Progress:
            def __init__(self):
                self.events = []

            def send(self, value):
                self.events.append(value)

        with tempfile.TemporaryDirectory() as root:
            first = Image.new("RGB", (900, 600), "white")
            second = Image.new("RGB", (900, 600), "white")
            try:
                ImageDraw.Draw(first).text((50, 100), "ChatAI OCR Review 2026", fill="black", font_size=45)
                ImageDraw.Draw(second).text((50, 100), "SECOND PAGE OCR REVIEW", fill="black", font_size=45)
                image_path = Path(root) / "image.png"
                pdf_path = Path(root) / "scan.pdf"
                first.save(image_path)
                first.save(pdf_path, save_all=True, append_images=[second], resolution=96)
                progress = Progress()
                image = recognize(str(image_path), "image", [], progress, True)
                self.assertIn("ocr", image["pages"][0]["text"].lower())
                pdf = recognize(str(pdf_path), "pdf", [2], progress, True)
                self.assertEqual(pdf["totalPages"], 2)
                self.assertEqual([p["page"] for p in pdf["pages"]], [2])
                self.assertIn("second", pdf["pages"][0]["text"].lower())
                for page in image["pages"] + pdf["pages"]:
                    encoded = base64.b64decode(page["preview"], validate=True)
                    self.assertLessEqual(len(encoded), 24 * 1024)
                    with Image.open(io.BytesIO(encoded)) as preview:
                        self.assertEqual(preview.format, "JPEG")
                        self.assertLessEqual(max(preview.size), 800)
                    for line in page["lines"]:
                        self.assertGreaterEqual(line["confidence"], 0)
                        self.assertLessEqual(line["confidence"], 1)
                        self.assertEqual(len(line["box"]), 4)
                self.assertLess(len(json.dumps(pdf).encode()), 2 * 1024 * 1024)
                self.assertEqual(progress.events[-1], {"totalPages": 2, "completedPages": 1})
            finally:
                first.close()
                second.close()


if __name__ == "__main__":
    unittest.main()
