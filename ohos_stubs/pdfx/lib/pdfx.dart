/// HarmonyOS 空实现 stub：仅提供 [OcrService] 用到的 pdfx 公开 API 形状，
/// 任何真正渲染的调用都抛 [UnsupportedError]（OHOS 上被 isSupported 守卫，不会触发）。
library pdfx;

import 'dart:typed_data';

const _msg = 'PDF 渲染（pdfx）在 HarmonyOS 上不可用';

/// 渲染输出格式（与上游枚举同名，OcrService 用 [png]）。
enum PdfPageImageFormat { jpeg, png, webp }

/// 渲染产物占位（含 `bytes` 字段）。
class PdfPageImage {
  final Uint8List bytes;

  PdfPageImage(this.bytes);
}

/// PDF 单页占位。
class PdfPage {
  final double width;
  final double height;

  PdfPage({this.width = 0, this.height = 0});

  Future<PdfPageImage?> render({
    required double width,
    required double height,
    PdfPageImageFormat format = PdfPageImageFormat.jpeg,
  }) =>
      throw UnsupportedError(_msg);

  Future<void> close() async {}
}

/// PDF 文档占位。[openFile] / [getPage] 在 OHOS 上不可用。
class PdfDocument {
  final int pagesCount;

  PdfDocument({this.pagesCount = 0});

  static Future<PdfDocument> openFile(String filePath, {String? password}) =>
      throw UnsupportedError(_msg);

  Future<PdfPage> getPage(int pageNumber) => throw UnsupportedError(_msg);

  Future<void> close() async {}
}
