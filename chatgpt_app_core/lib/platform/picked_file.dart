import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/platform/app_io.dart';

const browserPickedFileMaxBytes = 32 * 1024 * 1024;

/// 先核元数据，再逐块核实际字节；不要先把任意大小的 Blob 读进内存。
Future<Uint8List> readBrowserPickedBytes(
    int declaredSize, Stream<List<int>> stream,
    {int maxBytes = browserPickedFileMaxBytes}) async {
  if (declaredSize < 0 || declaredSize > maxBytes) {
    throw const FormatException('网页端单个文件超过大小限制');
  }
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (output.length + chunk.length > maxBytes ||
        output.length + chunk.length > declaredSize) {
      throw const FormatException('选中文件实际大小超过限制');
    }
    output.add(chunk);
  }
  if (output.length != declaredSize) throw const FormatException('选中文件内容不完整');
  return output.takeBytes();
}

Future<String> storeBrowserPickedBytes(String name, Uint8List bytes,
    {String? accountHash, int maxBytes = browserPickedFileMaxBytes}) async {
  if (bytes.length > maxBytes) throw const FormatException('网页端单个文件超过大小限制');
  var basename =
      name.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f]'), '_');
  if (basename.isEmpty || basename == '.' || basename == '..') {
    basename = 'attachment';
  }
  if (basename.length > 240) {
    basename = basename.substring(basename.length - 240);
  }
  final account = sha256.convert(
      utf8.encode(accountHash ?? LoginDao.getAccountHash() ?? 'guest'));
  final digest = sha256.convert(bytes);
  final root = appDirectory('/tmp/browser_imports/$account/$digest');
  await root.create(recursive: true);
  final file = appFile('${root.path}/$basename');
  if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<String> materializePickedImage(XFile file) async {
  if (!kIsWeb) return file.path;
  final account = LoginDao.getAccountHash() ?? 'guest';
  const maxBytes = 20 * 1024 * 1024;
  if (await file.length() > maxBytes) {
    throw const FormatException('图片超过 20 MiB');
  }
  return storeBrowserPickedBytes(file.name, await file.readAsBytes(),
      accountHash: account, maxBytes: maxBytes);
}
