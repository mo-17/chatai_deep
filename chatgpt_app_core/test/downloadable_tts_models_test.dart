import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:chatgpt_app_core/chat/application/downloadable_tts_models.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('requires HTTPS, bounded size and full SHA before downloading', () {
    final descriptor = {
      'id': 'matcha-icefall-zh-baker',
      'title': 'Baker',
      'url': 'https://example.com/model.zip',
      'sha256': 'a' * 64,
      'bytes': 100
    };
    expect(DownloadableTtsModel.fromJson(descriptor).bytes, 100);
    for (final change in [
      {'url': 'http://example.com/a'},
      {'sha256': 'abc'},
      {'bytes': 1024 * 1024 * 257},
      {'id': '../other'}
    ]) {
      expect(() => DownloadableTtsModel.fromJson({...descriptor, ...change}),
          throwsFormatException);
    }
  });
  test(
      'explicit download validates SHA, installs safely and legacy voice resolves without network',
      () async {
    final dir = await Directory.systemTemp.createTemp('download_tts_');
    addTearDown(() => dir.delete(recursive: true));
    final archive = Archive()
      ..addFile(ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'engine': 'sherpa-onnx-matcha',
            'name': 'Baker',
            'locale': 'zh-CN',
            'speaker': 'female',
            'acousticModel': 'model.onnx',
            'vocoder': 'vocoder.onnx',
            'tokens': 'tokens.txt',
            'sampleRate': 22050
          })))
      ..addFile(ArchiveFile.string('model.onnx', 'synthetic model'))
      ..addFile(ArchiveFile.string('vocoder.onnx', 'synthetic vocoder'))
      ..addFile(ArchiveFile.string('tokens.txt', 'synthetic tokens'));
    final zip = ZipEncoder().encode(archive);
    final descriptor = DownloadableTtsModel(
        id: 'matcha-icefall-zh-baker',
        title: 'Baker',
        url: 'https://example.com/model.zip',
        sha256: sha256.convert(zip).toString(),
        bytes: zip.length);
    final store = DownloadableTtsModelStore(baseDir: () async => dir);
    expect(await store.resolve(descriptor.id), isNull);
    await store.install(descriptor,
        listener: (_, __, ___) {},
        client: MockClient((_) async => http.Response.bytes(zip, 200)));
    final resolved = await store.resolve(descriptor.id);
    expect(resolved?.manifest.name, 'Baker');
    expect(await File(resolved!.resolve('model.onnx')).readAsString(),
        'synthetic model');
    final legacy =
        await BundledSherpaOnnxAssetInstaller(baseDir: () async => dir)
            .ensureInstalled(BundledSherpaOnnxTtsModel.matchaZhBaker);
    expect(legacy.rootDir.path, resolved.rootDir.path);
    expect(await Directory('${dir.path}/tts_models/downloads').list().toList(),
        isEmpty);
  });
}
