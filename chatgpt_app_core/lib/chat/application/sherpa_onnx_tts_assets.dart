import 'dart:convert';
import 'dart:io';

class SherpaOnnxTtsManifest {
  final String engine;
  final String name;
  final String locale;
  final String speaker;
  final String acousticModel;
  final String vocoder;
  final String tokens;
  final String? lexicon;
  final List<String> ruleFsts;
  final String? dictDir;
  final int sampleRate;

  const SherpaOnnxTtsManifest({
    required this.engine,
    required this.name,
    required this.locale,
    required this.speaker,
    required this.acousticModel,
    required this.vocoder,
    required this.tokens,
    this.lexicon,
    this.ruleFsts = const [],
    this.dictDir,
    required this.sampleRate,
  });

  factory SherpaOnnxTtsManifest.fromJson(Map<String, dynamic> json) {
    return SherpaOnnxTtsManifest(
      engine: json['engine'] as String? ?? '',
      name: json['name'] as String? ?? '',
      locale: json['locale'] as String? ?? '',
      speaker: json['speaker'] as String? ?? '',
      acousticModel: json['acousticModel'] as String? ?? '',
      vocoder: json['vocoder'] as String? ?? '',
      tokens: json['tokens'] as String? ?? '',
      lexicon: json['lexicon'] as String?,
      ruleFsts: [
        for (final item in (json['ruleFsts'] as List? ?? const []))
          if (item is String) item,
      ],
      dictDir: json['dictDir'] as String?,
      sampleRate: json['sampleRate'] as int? ?? 0,
    );
  }

  factory SherpaOnnxTtsManifest.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('manifest must be a JSON object');
    }
    return SherpaOnnxTtsManifest.fromJson(decoded);
  }

  bool get isMatcha => engine == 'sherpa-onnx-matcha';

  List<String> get requiredRelativePaths => [
        acousticModel,
        vocoder,
        tokens,
        if (lexicon != null && lexicon!.isNotEmpty) lexicon!,
        ...ruleFsts,
      ];
}

class BundledSherpaOnnxTtsModel {
  final String id;
  final String title;
  final String rootAsset;
  final String manifestAsset;
  final List<String> assetKeys;
  final List<String> fileAssetKeys;

  const BundledSherpaOnnxTtsModel({
    required this.id,
    required this.title,
    required this.rootAsset,
    required this.manifestAsset,
    required this.assetKeys,
    required this.fileAssetKeys,
  });

  static const matchaZhBakerRoot = 'assets/sherpa_onnx/matcha-icefall-zh-baker';

  static const matchaZhBaker = BundledSherpaOnnxTtsModel(
    id: 'matcha-icefall-zh-baker',
    title: '中文女声 Baker',
    rootAsset: matchaZhBakerRoot,
    manifestAsset: '$matchaZhBakerRoot/manifest.json',
    assetKeys: [
      '$matchaZhBakerRoot/manifest.json',
      '$matchaZhBakerRoot/vocos-22khz-univ.onnx',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/model-steps-3.onnx',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/tokens.txt',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/lexicon.txt',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/phone.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/date.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/number.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/',
    ],
    fileAssetKeys: [
      '$matchaZhBakerRoot/manifest.json',
      '$matchaZhBakerRoot/vocos-22khz-univ.onnx',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/model-steps-3.onnx',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/tokens.txt',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/lexicon.txt',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/phone.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/date.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/number.fst',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/README.md',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/generate_user_dict.py',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/hmm_model.utf8',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/idf.utf8',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/jieba.dict.utf8',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/stop_words.utf8',
      '$matchaZhBakerRoot/matcha-icefall-zh-baker/dict/user.dict.utf8',
    ],
  );

  static const all = [matchaZhBaker];

  List<String> missingRequiredAssets(SherpaOnnxTtsManifest manifest) {
    final declared = fileAssetKeys.toSet();
    return [
      for (final relative in manifest.requiredRelativePaths)
        if (!declared.contains('$rootAsset/$relative')) relative,
    ];
  }
}

class InstalledSherpaOnnxTtsModel {
  final String id;
  final BundledSherpaOnnxTtsModel? bundled;
  final Directory rootDir;
  final SherpaOnnxTtsManifest manifest;

  const InstalledSherpaOnnxTtsModel({
    required this.id,
    this.bundled,
    required this.rootDir,
    required this.manifest,
  });

  String resolve(String relativePath) => '${rootDir.path}/$relativePath';
}
