import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:path_provider/path_provider.dart';

class UserSherpaOnnxTtsModel {
  final String id;
  final String title;
  final Directory rootDir;
  final SherpaOnnxTtsManifest manifest;

  const UserSherpaOnnxTtsModel({
    required this.id,
    required this.title,
    required this.rootDir,
    required this.manifest,
  });

  String get voiceStyleId => UserSherpaOnnxTtsModelStore.voiceStyleId(id);
}

class UserSherpaOnnxTtsModelStore {
  UserSherpaOnnxTtsModelStore({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  static const voiceStylePrefix = 'custom_sherpa:';

  final Future<Directory> Function() _baseDir;

  static bool isUserVoiceStyle(String? voiceStyle) =>
      voiceStyle?.startsWith(voiceStylePrefix) ?? false;

  static String voiceStyleId(String id) => '$voiceStylePrefix$id';

  static String? idFromVoiceStyle(String? voiceStyle) {
    if (!isUserVoiceStyle(voiceStyle)) return null;
    final id = voiceStyle!.substring(voiceStylePrefix.length).trim();
    return id.isEmpty ? null : id;
  }

  Future<List<UserSherpaOnnxTtsModel>> listModels() async {
    final root = await _modelsRoot();
    if (!await root.exists()) return const [];
    final models = <UserSherpaOnnxTtsModel>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        models.add(await _readModel(entity));
      } catch (_) {
        // 跳过不完整目录，避免一个坏模型影响整个偏好页。
      }
    }
    models.sort((a, b) => a.title.compareTo(b.title));
    return models;
  }

  Future<UserSherpaOnnxTtsModel> installFromDirectory(String sourcePath) async {
    final source = Directory(sourcePath);
    if (!await source.exists()) {
      throw StateError('模型目录不存在');
    }
    final manifest = await _readManifest(source);
    _validateManifest(manifest);
    await _assertRequiredFiles(source, manifest);

    final id = _sanitizeId(
      manifest.name.isEmpty ? _basename(source.path) : manifest.name,
    );
    final target = await _uniqueTarget(id);
    await target.create(recursive: true);
    try {
      await _copyDirectory(source, target);
      return _readModel(target);
    } catch (_) {
      if (await target.exists()) await target.delete(recursive: true);
      rethrow;
    }
  }

  Future<UserSherpaOnnxTtsModel> installFromZip(String zipPath) async {
    final zip = File(zipPath);
    if (!await zip.exists()) {
      throw StateError('模型 ZIP 不存在');
    }
    final base = await _baseDir();
    final tmp = Directory(
      '${base.path}/tts_models/tmp_import_${DateTime.now().millisecondsSinceEpoch}',
    );
    await tmp.create(recursive: true);
    try {
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final entry in archive) {
        final safeName = _safeZipEntryName(entry.name);
        final targetPath = '${tmp.path}/$safeName';
        if (entry.isFile) {
          await File(targetPath).parent.create(recursive: true);
          await File(targetPath).writeAsBytes(entry.content as List<int>);
        } else {
          await Directory(targetPath).create(recursive: true);
        }
      }
      final modelRoot = await _findModelRoot(tmp);
      return await installFromDirectory(modelRoot.path);
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  Future<InstalledSherpaOnnxTtsModel> resolveInstalled(
    String voiceStyle,
  ) async {
    final id = idFromVoiceStyle(voiceStyle);
    if (id == null) throw StateError('不是用户 sherpa-onnx 模型');
    final root = Directory('${(await _modelsRoot()).path}/$id');
    final model = await _readModel(root);
    return InstalledSherpaOnnxTtsModel(
      id: model.id,
      rootDir: model.rootDir,
      manifest: model.manifest,
    );
  }

  Future<Directory> _modelsRoot() async {
    final base = await _baseDir();
    final root = Directory('${base.path}/tts_models/user_sherpa');
    await root.create(recursive: true);
    return root;
  }

  Future<UserSherpaOnnxTtsModel> _readModel(Directory root) async {
    final manifest = await _readManifest(root);
    _validateManifest(manifest);
    await _assertRequiredFiles(root, manifest);
    return UserSherpaOnnxTtsModel(
      id: root.uri.pathSegments.where((e) => e.isNotEmpty).last,
      title: manifest.name.isEmpty ? _basename(root.path) : manifest.name,
      rootDir: root,
      manifest: manifest,
    );
  }

  Future<SherpaOnnxTtsManifest> _readManifest(Directory root) async {
    final file = File('${root.path}/manifest.json');
    if (!await file.exists()) {
      throw StateError('模型目录缺少 manifest.json');
    }
    return SherpaOnnxTtsManifest.decode(await file.readAsString());
  }

  void _validateManifest(SherpaOnnxTtsManifest manifest) {
    if (!manifest.isMatcha) {
      throw StateError('当前仅支持 sherpa-onnx Matcha TTS 模型');
    }
    if (manifest.acousticModel.isEmpty ||
        manifest.vocoder.isEmpty ||
        manifest.tokens.isEmpty ||
        manifest.sampleRate <= 0) {
      throw StateError(
          'manifest.json 缺少 acousticModel/vocoder/tokens/sampleRate');
    }
  }

  Future<void> _assertRequiredFiles(
    Directory root,
    SherpaOnnxTtsManifest manifest,
  ) async {
    final missing = <String>[];
    for (final relative in manifest.requiredRelativePaths) {
      final file = File('${root.path}/$relative');
      if (!await file.exists() || await file.length() <= 0) {
        missing.add(relative);
      }
    }
    final dictDir = manifest.dictDir;
    if (dictDir != null && dictDir.isNotEmpty) {
      final dir = Directory('${root.path}/$dictDir');
      if (!await dir.exists()) missing.add(dictDir);
    }
    if (missing.isNotEmpty) {
      throw StateError('模型文件不完整：${missing.join(', ')}');
    }
  }

  Future<Directory> _uniqueTarget(String id) async {
    final root = await _modelsRoot();
    var candidate = Directory('${root.path}/$id');
    if (!await candidate.exists()) return candidate;
    candidate = Directory(
        '${root.path}/${id}_${DateTime.now().millisecondsSinceEpoch}');
    return candidate;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(source.path.length + 1);
      final targetPath = '${target.path}/$relative';
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }

  Future<Directory> _findModelRoot(Directory root) async {
    final selfManifest = File('${root.path}/manifest.json');
    if (await selfManifest.exists()) return root;
    final candidates = <Directory>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory &&
          await File('${entity.path}/manifest.json').exists()) {
        candidates.add(entity);
      }
    }
    if (candidates.length == 1) return candidates.single;
    if (candidates.isEmpty) throw StateError('ZIP 中未找到 manifest.json');
    throw StateError('ZIP 中包含多个模型目录，请一次只导入一个模型');
  }

  String _safeZipEntryName(String name) {
    final normalized = name.replaceAll('\\', '/');
    if (normalized.startsWith('/') || normalized.contains('\u0000')) {
      throw StateError('ZIP 包含非法路径：$name');
    }
    final parts = [
      for (final part in normalized.split('/'))
        if (part.isNotEmpty) part,
    ];
    if (parts.any((part) => part == '..')) {
      throw StateError('ZIP 包含非法路径：$name');
    }
    if (parts.isEmpty) throw StateError('ZIP 包含空路径');
    return parts.join(Platform.pathSeparator);
  }

  String _sanitizeId(String raw) {
    final id = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    return id.isEmpty ? 'user-model' : id;
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', Platform.pathSeparator);
    final parts = normalized
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'user-model' : parts.last;
  }
}
