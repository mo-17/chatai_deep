import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// TL、TR、BR、BL，归一化坐标。拒绝交叉/退化四边形。
void validateScanCorners(List<List<double>> points) {
  if (points.length != 4 ||
      points.any((p) =>
          p.length != 2 || p.any((n) => !n.isFinite || n < 0 || n > 1))) {
    throw const FormatException('请在图片内选择四个角');
  }
  var area = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
    final cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cross < .0001) throw const FormatException('四角不能交叉或重叠，请按左上、右上、右下、左下调整');
    area += a[0] * b[1] - b[0] * a[1];
  }
  if (area < .02) throw const FormatException('裁剪区域过小，请重新调整四角');
}

img.Image _decode(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('扫描照片最多 8 MiB');
  }
  try {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width < 2 ||
        info.height < 2 ||
        info.width * info.height > 24000000 ||
        info.numFrames != 1) {
      throw const FormatException('请选择 2400 万像素以内的静态图片');
    }
    final image = decoder!.decodeFrame(0);
    if (image == null) throw const FormatException('图片无法解码');
    return img.bakeOrientation(image);
  } on FormatException {
    rethrow;
  } catch (_) {
    // 部分解码器在探测截断文件时会抛出 RangeError，统一为可显示的输入错误。
    throw const FormatException('图片无法解码，请重新选择完整的图片');
  }
}

/// 在 isolate 中执行。输出去除元数据、长边不超过 1600 的 JPEG。
Uint8List prepareScanPreview(Uint8List bytes) {
  var image = _decode(bytes);
  if (math.max(image.width, image.height) > 1600) {
    image = img.copyResize(image,
        width: image.width >= image.height ? 1600 : null,
        height: image.height > image.width ? 1600 : null);
  }
  final clean =
      img.Image(width: image.width, height: image.height, numChannels: 3);
  img.fill(clean, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(clean, image);
  return img.encodeJpg(clean, quality: 85);
}

Uint8List rectifyScan(Map<String, Object> input) {
  final points = (input['corners'] as List)
      .map((p) => (p as List).cast<double>())
      .toList();
  validateScanCorners(points);
  final source = _decode(input['bytes'] as Uint8List);
  final p = points
      .map((p) => [p[0] * (source.width - 1), p[1] * (source.height - 1)])
      .toList();
  double distance(int a, int b) => math
      .sqrt(math.pow(p[a][0] - p[b][0], 2) + math.pow(p[a][1] - p[b][1], 2));
  final width = ((distance(0, 1) + distance(3, 2)) / 2).round().clamp(2, 1600);
  final height = ((distance(0, 3) + distance(1, 2)) / 2).round().clamp(2, 1600);
  final dx1 = p[1][0] - p[2][0],
      dx2 = p[3][0] - p[2][0],
      dx3 = p[0][0] - p[1][0] + p[2][0] - p[3][0];
  final dy1 = p[1][1] - p[2][1],
      dy2 = p[3][1] - p[2][1],
      dy3 = p[0][1] - p[1][1] + p[2][1] - p[3][1];
  final den = dx1 * dy2 - dx2 * dy1;
  if (den.abs() < .0001) throw const FormatException('四角无法校正，请重新调整');
  final g = (dx3 * dy2 - dx2 * dy3) / den, h = (dx1 * dy3 - dx3 * dy1) / den;
  final a = p[1][0] - p[0][0] + g * p[1][0],
      b = p[3][0] - p[0][0] + h * p[3][0];
  final d = p[1][1] - p[0][1] + g * p[1][1],
      e = p[3][1] - p[0][1] + h * p[3][1];
  var output = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    final v = y / (height - 1);
    for (var x = 0; x < width; x++) {
      final u = x / (width - 1), divisor = g * u + h * v + 1;
      if (divisor <= 0 || !divisor.isFinite) {
        throw const FormatException('裁剪区域无法校正');
      }
      final sx = ((a * u + b * v + p[0][0]) / divisor)
          .clamp(0.0, (source.width - 1).toDouble());
      final sy = ((d * u + e * v + p[0][1]) / divisor)
          .clamp(0.0, (source.height - 1).toDouble());
      output.setPixel(
          x,
          y,
          source.getPixelInterpolate(sx, sy,
              interpolation: img.Interpolation.linear));
    }
  }
  for (final quality in [80, 65, 50, 35]) {
    final bytes = img.encodeJpg(output, quality: quality);
    if (bytes.length <= 320 * 1024) return bytes;
  }
  output = img.copyResize(output,
      width: (output.width * .7).round().clamp(2, 1600),
      height: (output.height * .7).round().clamp(2, 1600));
  final bytes = img.encodeJpg(output, quality: 35);
  if (bytes.length > 320 * 1024) throw const FormatException('照片压缩后仍过大，请缩小后重试');
  return bytes;
}

Future<Uint8List> scannedPagesPdf(List<Uint8List> pages) async {
  if (pages.isEmpty ||
      pages.length > 20 ||
      pages.any((p) => p.length > 320 * 1024)) {
    throw const FormatException('扫描文档支持 1～20 页');
  }
  final document = PdfDocument();
  try {
    for (final bytes in pages) {
      final bitmap = PdfBitmap(bytes);
      final section = document.sections!.add();
      section.pageSettings.margins.all = 0;
      // PdfPageSettings 会按方向重排宽高；横图若仍用默认竖向会裁掉右侧内容。
      section.pageSettings.orientation = bitmap.width > bitmap.height
          ? PdfPageOrientation.landscape
          : PdfPageOrientation.portrait;
      section.pageSettings.size =
          Size(bitmap.width.toDouble(), bitmap.height.toDouble());
      section.pages.add().graphics.drawImage(
          bitmap,
          Rect.fromLTWH(
              0, 0, bitmap.width.toDouble(), bitmap.height.toDouble()));
    }
    final bytes = Uint8List.fromList(await document.save());
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('扫描 PDF 超过 8 MiB，请减少页数');
    }
    return bytes;
  } finally {
    document.dispose();
  }
}
