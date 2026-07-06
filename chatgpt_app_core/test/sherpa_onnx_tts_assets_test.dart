import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chatgpt_app_core/chat/application/user_sherpa_onnx_tts_models.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内置 Matcha 中文模型声明首版随 app 打包的必需资源', () {
    const model = BundledSherpaOnnxTtsModel.matchaZhBaker;

    expect(model.id, 'matcha-icefall-zh-baker');
    expect(model.manifestAsset, endsWith('/manifest.json'));
    expect(
      model.assetKeys,
      contains(
          'assets/sherpa_onnx/matcha-icefall-zh-baker/vocos-22khz-univ.onnx'),
    );
    expect(
      model.assetKeys,
      contains(
          'assets/sherpa_onnx/matcha-icefall-zh-baker/matcha-icefall-zh-baker/model-steps-3.onnx'),
    );
    expect(
      model.assetKeys,
      contains(
          'assets/sherpa_onnx/matcha-icefall-zh-baker/matcha-icefall-zh-baker/dict/'),
    );
    expect(
      model.fileAssetKeys,
      contains(
          'assets/sherpa_onnx/matcha-icefall-zh-baker/matcha-icefall-zh-baker/dict/jieba.dict.utf8'),
    );
  });

  test('SherpaOnnxTtsManifest 解析 Matcha 模型包并校验必需资源', () {
    const json = '''
{
  "engine": "sherpa-onnx-matcha",
  "name": "matcha-icefall-zh-baker",
  "locale": "zh-CN",
  "speaker": "female",
  "acousticModel": "matcha-icefall-zh-baker/model-steps-3.onnx",
  "vocoder": "vocos-22khz-univ.onnx",
  "tokens": "matcha-icefall-zh-baker/tokens.txt",
  "lexicon": "matcha-icefall-zh-baker/lexicon.txt",
  "ruleFsts": [
    "matcha-icefall-zh-baker/phone.fst",
    "matcha-icefall-zh-baker/date.fst",
    "matcha-icefall-zh-baker/number.fst"
  ],
  "dictDir": "matcha-icefall-zh-baker/dict",
  "sampleRate": 22050
}
''';

    final manifest = SherpaOnnxTtsManifest.decode(json);

    expect(manifest.isMatcha, isTrue);
    expect(manifest.locale, 'zh-CN');
    expect(manifest.sampleRate, 22050);
    expect(manifest.requiredRelativePaths, contains('vocos-22khz-univ.onnx'));
    expect(
      BundledSherpaOnnxTtsModel.matchaZhBaker.missingRequiredAssets(manifest),
      isEmpty,
    );
  });

  test('UserSherpaOnnxTtsModelStore 可安装、列出并解析用户模型目录', () async {
    final temp = await Directory.systemTemp.createTemp('user_sherpa_tts_');
    addTearDown(() => temp.delete(recursive: true));
    final source = Directory('${temp.path}/source');
    await _writeModelFixture(source);
    final store = UserSherpaOnnxTtsModelStore(
      baseDir: () async => Directory('${temp.path}/app_support'),
    );

    final installed = await store.installFromDirectory(source.path);
    final models = await store.listModels();
    final resolved = await store.resolveInstalled(installed.voiceStyleId);

    expect(installed.id, 'my-voice');
    expect(installed.voiceStyleId, 'custom_sherpa:my-voice');
    expect(models.single.title, 'My Voice');
    expect(resolved.id, 'my-voice');
    expect(resolved.resolve('model.onnx'), endsWith('/my-voice/model.onnx'));
  });

  test('UserSherpaOnnxTtsModelStore 可从 ZIP 安装用户模型目录', () async {
    final temp = await Directory.systemTemp.createTemp('user_sherpa_zip_');
    addTearDown(() => temp.delete(recursive: true));
    final zipPath = '${temp.path}/my_voice.zip';
    final archive = Archive()
      ..addFile(ArchiveFile.string(
          'model-package/my-voice/manifest.json', _fixtureManifest))
      ..addFile(ArchiveFile.string('model-package/my-voice/model.onnx', 'm'))
      ..addFile(ArchiveFile.string('model-package/my-voice/vocoder.onnx', 'v'))
      ..addFile(ArchiveFile.string('model-package/my-voice/tokens.txt', 't'))
      ..addFile(ArchiveFile.string('model-package/my-voice/lexicon.txt', 'l'))
      ..addFile(ArchiveFile.string('model-package/my-voice/phone.fst', 'p'))
      ..addFile(ArchiveFile.string(
          'model-package/my-voice/dict/jieba.dict.utf8', 'd'));
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));
    final store = UserSherpaOnnxTtsModelStore(
      baseDir: () async => Directory('${temp.path}/app_support'),
    );

    final installed = await store.installFromZip(zipPath);
    final resolved = await store.resolveInstalled(installed.voiceStyleId);

    expect(installed.id, 'my-voice');
    expect(resolved.resolve('tokens.txt'), endsWith('/my-voice/tokens.txt'));
  });

  test('UserSherpaOnnxTtsModelStore 缺少必需文件时拒绝导入', () async {
    final temp = await Directory.systemTemp.createTemp('user_sherpa_bad_');
    addTearDown(() => temp.delete(recursive: true));
    final source = Directory('${temp.path}/source');
    await source.create(recursive: true);
    await File('${source.path}/manifest.json').writeAsString(_fixtureManifest);
    final store = UserSherpaOnnxTtsModelStore(
      baseDir: () async => Directory('${temp.path}/app_support'),
    );

    expect(
      () => store.installFromDirectory(source.path),
      throwsA(isA<StateError>()),
    );
  });
}

const _fixtureManifest = '''
{
  "engine": "sherpa-onnx-matcha",
  "name": "My Voice",
  "locale": "zh-CN",
  "speaker": "female",
  "acousticModel": "model.onnx",
  "vocoder": "vocoder.onnx",
  "tokens": "tokens.txt",
  "lexicon": "lexicon.txt",
  "ruleFsts": ["phone.fst"],
  "dictDir": "dict",
  "sampleRate": 22050
}
''';

Future<void> _writeModelFixture(Directory root) async {
  await root.create(recursive: true);
  await File('${root.path}/manifest.json').writeAsString(_fixtureManifest);
  for (final name in [
    'model.onnx',
    'vocoder.onnx',
    'tokens.txt',
    'lexicon.txt',
    'phone.fst',
  ]) {
    await File('${root.path}/$name').writeAsString('fake $name');
  }
  await Directory('${root.path}/dict').create(recursive: true);
  await File('${root.path}/dict/jieba.dict.utf8').writeAsString('fake dict');
}
