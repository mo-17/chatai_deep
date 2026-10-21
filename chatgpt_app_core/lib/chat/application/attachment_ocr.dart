import 'dart:typed_data';
import 'pdf_ocr_result.dart';

/// 发送快照中的实际字节，不能在确认后重新读取用户选择的原路径。
class AttachmentOcrRequest {
  static const maxBytes = 8 * 1024 * 1024;
  final String filename;
  final Uint8List bytes;
  final bool pdf;
  final int totalPages;
  final List<int> pageNumbers;
  AttachmentOcrRequest(
      {required this.filename,
      required Uint8List bytes,
      required this.pdf,
      this.totalPages = 1,
      List<int> pageNumbers = const []})
      : bytes = _freeze(bytes),
        pageNumbers = List.unmodifiable(pageNumbers);

  static Uint8List _freeze(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const AttachmentOcrException('服务器 OCR 单文件最多 8 MiB，附件不能为空；原输入已保留');
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }
}

typedef AttachmentOcrHandler = Future<PdfOcrResult> Function(
    AttachmentOcrRequest request);

/// 只包含面向用户的固定提示，不透传服务端错误、路径或文档内容。
class AttachmentOcrException implements Exception {
  final String message;
  const AttachmentOcrException(this.message);
  @override
  String toString() => message;
}
