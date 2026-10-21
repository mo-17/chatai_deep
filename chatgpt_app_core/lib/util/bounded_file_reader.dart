import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';

/// 先检查文件长度，再以流式累计做第二次上限校验，避免 `readAsBytes` 在预算
/// 判断前一次性分配不受信任的本地文件。第二道检查也覆盖检查后文件增长的竞态。
Future<Uint8List> readFileBytesBounded(
  File file, {
  required int maxBytes,
  String label = '导入文件',
}) async {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', '不能小于 0');
  }
  if (!await file.exists()) {
    throw FormatException('$label不存在');
  }
  final declaredLength = await file.length();
  if (declaredLength > maxBytes) {
    throw FormatException(_tooLargeMessage(label, maxBytes));
  }

  final bytes = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in file.openRead()) {
    total += chunk.length;
    if (total > maxBytes) {
      throw FormatException(_tooLargeMessage(label, maxBytes));
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

String _tooLargeMessage(String label, int maxBytes) {
  final mib = maxBytes / (1024 * 1024);
  final display =
      mib == mib.roundToDouble() ? '${mib.toInt()} MiB' : '$maxBytes bytes';
  return '$label过大（最多 $display）';
}
