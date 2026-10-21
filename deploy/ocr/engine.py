"""单任务子进程：不接受 URL，只处理已限量的本地输入。"""
import os
import base64
import io

for _name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ[_name] = "1"

MAX_PAGES = 20
MAX_PIXELS = 24_000_000
MAX_EDGE = 1600
MAX_TEXT = 200_000
MAX_LINES = 4000


def recognize(path, kind, selected, send, include_preview=False):
    import cv2
    import numpy as np
    from PIL import Image, ImageOps
    from rapidocr import RapidOCR

    cv2.setNumThreads(1)
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    # 模型随固定版本 wheel 安装；部署时预热，运行期不下载模型。
    engine = RapidOCR(params={"Global.log_level": "error",
                              "EngineConfig.onnxruntime.intra_op_num_threads": 1,
                              "EngineConfig.onnxruntime.inter_op_num_threads": 1})
    used_text = used_lines = 0

    def page_result(image, number):
        nonlocal used_text, used_lines
        if image.width * image.height > MAX_PIXELS:
            raise ValueError("pixels_limit")
        image.thumbnail((MAX_EDGE, MAX_EDGE))
        image = image.convert("RGB")
        result = engine(cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR))
        lines = []
        if result.txts is not None:
            for text, score, box in zip(result.txts, result.scores, result.boxes):
                used_text += len(text)
                used_lines += 1
                if used_text > MAX_TEXT or used_lines > MAX_LINES:
                    raise ValueError("result_limit")
                lines.append({"text": text, "confidence": round(float(score), 4),
                              "box": [[round(float(x), 2), round(float(y), 2)] for x, y in box]})
        page = {"page": number, "width": image.width, "height": image.height,
                "text": "\n".join(line["text"] for line in lines), "lines": lines}
        if include_preview:
            # 校对页图有独立上限；不改变 OCR 使用的图像或坐标比例。
            preview = image.copy()
            try:
                preview.thumbnail((800, 800))
                for edge, quality in ((800, 60), (600, 45), (400, 35), (240, 25)):
                    preview.thumbnail((edge, edge))
                    output = io.BytesIO()
                    preview.save(output, format="JPEG", quality=quality)
                    encoded = output.getvalue()
                    if len(encoded) <= 24 * 1024:
                        page["preview"] = base64.b64encode(encoded).decode("ascii")
                        break
            finally:
                preview.close()
        return page

    if kind == "pdf":
        import pypdfium2 as pdfium
        with pdfium.PdfDocument(path) as pdf:
            total = len(pdf)
            if not 1 <= total <= MAX_PAGES:
                raise ValueError("pages_limit")
            numbers = selected or list(range(1, total + 1))
            if any(n > total for n in numbers):
                raise ValueError("invalid_pages")
            pages = []
            send.send({"totalPages": total, "completedPages": 0})
            for number in numbers:
                page = pdf[number - 1]
                try:
                    width, height = page.get_size()
                    if min(width, height) <= 0 or max(width, height) > 20000:
                        raise ValueError("pixels_limit")
                    bitmap = page.render(scale=min(2, MAX_EDGE / max(width, height)))
                    try:
                        image = bitmap.to_pil()
                        pages.append(page_result(image, number))
                        image.close()
                    finally:
                        bitmap.close()
                finally:
                    page.close()
                send.send({"totalPages": total, "completedPages": len(pages)})
    else:
        total = 1
        with Image.open(path) as source:
            if source.format not in {"PNG", "JPEG", "WEBP", "BMP"}:
                raise ValueError("unsupported_image")
            if source.width * source.height > MAX_PIXELS:
                raise ValueError("pixels_limit")
            image = ImageOps.exif_transpose(source)
            pages = [page_result(image, 1)]
            image.close()
    return {"totalPages": total, "pages": pages}


def run(path, kind, pages, send, include_preview=False):
    try:
        result = recognize(path, kind, pages, send, include_preview)
        send.send({"result": result})
    except Exception as error:
        # 不把文档内容、解析器异常或路径写到日志/响应。
        code = str(error) if isinstance(error, ValueError) else "recognition_failed"
        allowed = {"pages_limit", "pixels_limit", "invalid_pages", "result_limit", "unsupported_image"}
        send.send({"error": code if code in allowed else "recognition_failed"})
    finally:
        send.close()
