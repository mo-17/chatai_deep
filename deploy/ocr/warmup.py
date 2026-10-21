"""安装验收：实际加载模型并识别，不依赖外网测试图片。"""
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from engine import recognize


class Sink:
    def send(self, _):
        pass


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        image = Image.new("RGB", (900, 400), "white")
        draw = ImageDraw.Draw(image)
        draw.text((40, 80), "SERVER OCR TEST 2026", fill="black", font=ImageFont.load_default(size=42))
        png = Path(directory) / "test.png"
        pdf = Path(directory) / "test.pdf"
        image.save(png)
        image.save(pdf, "PDF", resolution=150)
        for path, kind in [(png, "image"), (pdf, "pdf")]:
            result = recognize(str(path), kind, [], Sink())
            text = result["pages"][0]["text"]
            if "OCR" not in text or "2026" not in text:
                raise SystemExit("OCR model smoke failed")
            print(kind + ": actual model recognition passed")
