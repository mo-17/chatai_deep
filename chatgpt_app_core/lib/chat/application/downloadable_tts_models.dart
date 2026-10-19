import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:hi_download/hi_download.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class DownloadableTtsModel {
  final String id, title, url, sha256;
  final int bytes;
  const DownloadableTtsModel(
      {required this.id,
      required this.title,
      required this.url,
      required this.sha256,
      required this.bytes});
  factory DownloadableTtsModel.fromJson(Map<String, dynamic> value) {
    final uri = Uri.tryParse('${value['url']}');
    final size = value['bytes'];
    if (value['id'] != BundledSherpaOnnxTtsModel.matchaZhBaker.id ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch('${value['sha256']}') ||
        size is! int ||
        size <= 0 ||
        size > 256 * 1024 * 1024) {
      throw const FormatException('模型目录无效');
    }
    return DownloadableTtsModel(
        id: value['id'],
        title: '${value['title']}',
        url: uri.toString(),
        sha256: value['sha256'],
        bytes: size);
  }
}

/// 下载只由模型管理页明确触发，朗读不会隐式消耗百兆流量。
class DownloadableTtsModelStore {
  final Future<Directory> Function() baseDir;
  DownloadableTtsModelStore({Future<Directory> Function()? baseDir})
      : baseDir = baseDir ?? getApplicationSupportDirectory;

  Future<List<DownloadableTtsModel>> catalog(
      {http.Client? client, Uri? endpoint}) async {
    final resolved = client ?? http.Client();
    try {
      final response = await resolved
          .get(endpoint ??
              Uri.parse('https://kushui.shop/downloads/models/catalog.json'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.length > 64 * 1024) {
        throw const FormatException('模型目录暂不可用');
      }
      final data = jsonDecode(response.body);
      if (data is! Map || data['models'] is! List) {
        throw const FormatException('模型目录无效');
      }
      return (data['models'] as List)
          .map((e) =>
              DownloadableTtsModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } finally {
      if (client == null) resolved.close();
    }
  }

  Future<InstalledSherpaOnnxTtsModel?> resolve(String id) async {
    if (id != BundledSherpaOnnxTtsModel.matchaZhBaker.id) return null;
    try {
      final pointer = jsonDecode(
          await File('${(await baseDir()).path}/tts_models/official-model.json')
              .readAsString()) as Map;
      final style = pointer['voiceStyle'];
      if (style is! String ||
          !style.startsWith(UserSherpaOnnxTtsModelStore.voiceStylePrefix)) {
        return null;
      }
      return await UserSherpaOnnxTtsModelStore(baseDir: baseDir)
          .resolveInstalled(style);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> install(DownloadableTtsModel model,
      {required DownLoadListener listener,
      DownloadCancellationToken? token,
      http.Client? client}) async {
    final base = await baseDir();
    final path = await HiDownLoad().download(
        downLoadUrl: model.url,
        fileName: '${model.id}-${model.sha256.substring(0, 12)}.zip',
        expectedSha256: model.sha256,
        directoryProvider: () async =>
            Directory('${base.path}/tts_models/downloads'),
        cancellationToken: token,
        client: client,
        maxBytes: model.bytes,
        listener: listener);
    final basePath = base.path;
    final installed = await Isolate.run(() =>
        UserSherpaOnnxTtsModelStore(baseDir: () async => Directory(basePath))
            .installFromZip(path));
    final pointer = File('${base.path}/tts_models/official-model.json');
    final pending = File('${pointer.path}.new');
    await pending.writeAsString(
        jsonEncode(
            {'voiceStyle': installed.voiceStyleId, 'sha256': model.sha256}),
        flush: true);
    await pending.rename(pointer.path);
    await File(path).delete();
  }
}
