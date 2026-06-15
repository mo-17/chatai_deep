import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// OCR 服务的纯逻辑验收（原生识别需真机，这里只测平台守卫与判定）。
void main() {
  group('OcrService.pdfNeedsOcr', () {
    test('空 / 过短 -> 需要 OCR', () {
      expect(OcrService.pdfNeedsOcr(null), isTrue);
      expect(OcrService.pdfNeedsOcr(''), isTrue);
      expect(OcrService.pdfNeedsOcr('   '), isTrue);
      expect(OcrService.pdfNeedsOcr('短'), isTrue);
    });

    test('抽取器占位提示 -> 需要 OCR', () {
      expect(OcrService.pdfNeedsOcr('[PDF 未抽取到文本（可能是扫描件）]'), isTrue);
      expect(OcrService.pdfNeedsOcr('[PDF 无可读页面]'), isTrue);
      expect(OcrService.pdfNeedsOcr('[PDF 解析失败: xxx]'), isTrue);
    });

    test('有足够正文 -> 不需要 OCR', () {
      expect(
          OcrService.pdfNeedsOcr('这是一段从 PDF 文本层正常抽取出来的内容，足够长。'),
          isFalse);
    });
  });

  test('imageExtensions 覆盖常见图片类型', () {
    expect(OcrService.imageExtensions, containsAll(['png', 'jpg', 'jpeg']));
  });
}
