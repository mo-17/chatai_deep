import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
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
  static const maxManifestBytes = 1024 * 1024;
  static const importArchiveLimits = BackupArchiveLimits(
    maxCompressedBytes: 256 * 1024 * 1024,
    maxEntries: 4096,
    maxEntryUncompressedBytes: 256 * 1024 * 1024,
    maxTotalUncompressedBytes: 768 * 1024 * 1024,
  );

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
    await _validateModelDirectoryBudget(source);
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
      await _extractZipBounded(zip, tmp);
      final modelRoot = await _findModelRoot(tmp);
      return await installFromDirectory(modelRoot.path);
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  Future<void> _extractZipBounded(File zip, Directory target) async {
    final type = await FileSystemEntity.type(zip.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const FormatException('TTS 模型 ZIP 不允许使用符号链接');
    }
    if (type != FileSystemEntityType.file) {
      throw const FormatException('TTS 模型 ZIP 不是普通文件');
    }
    final compressedBytes = await zip.length();
    final input = InputFileStream(zip.path);
    try {
      final preflight = preflightBoundedZip(
        input,
        compressedInputBytes: compressedBytes,
        limits: importArchiveLimits,
      );
      final outputBudget = _TtsArchiveOutputBudget(importArchiveLimits);
      for (var index = 0;
          index < preflight.directory.fileHeaders.length;
          index++) {
        final header = preflight.directory.fileHeaders[index];
        final localFile = header.file!;
        final metadata = preflight.entries[index];
        if (localFile.flags != header.generalPurposeBitFlag ||
            localFile.compressedSize != header.compressedSize ||
            localFile.uncompressedSize != header.uncompressedSize) {
          throw const FormatException('TTS 模型 ZIP 本地 header 与中央目录不一致');
        }
        final safeName = _safeZipEntryName(header.filename);
        final targetPath = '${target.path}/$safeName';
        if (metadata.isDirectory) {
          if (header.uncompressedSize != 0) {
            throw const FormatException('TTS 模型 ZIP 目录 entry 大小不合法');
          }
          await Directory(targetPath).create(recursive: true);
          continue;
        }

        await File(targetPath).parent.create(recursive: true);
        final sink = _BoundedTtsFileSink(
          targetPath,
          outputBudget,
          header.filename,
        );
        try {
          localFile.decompress(sink);
        } finally {
          sink.closeSync();
        }
        if (sink.length != header.uncompressedSize) {
          throw FormatException(
              'TTS 模型 ZIP entry 实际解压大小不一致：${header.filename}');
        }
        if (sink.crc32 != header.crc32) {
          throw FormatException('TTS 模型 ZIP entry CRC 校验失败：${header.filename}');
        }
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('TTS 模型 ZIP 解析失败');
    } finally {
      input.closeSync();
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
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('模型目录缺少 manifest.json');
    }
    final bytes = await readFileBytesBounded(
      file,
      maxBytes: maxManifestBytes,
      label: 'TTS manifest.json',
    );
    return SherpaOnnxTtsManifest.decode(utf8.decode(bytes));
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
    for (final relative in manifest.requiredRelativePaths) {
      _validateRelativeModelPath(relative);
    }
    final dictDir = manifest.dictDir;
    if (dictDir != null && dictDir.isNotEmpty) {
      _validateRelativeModelPath(dictDir);
    }
  }

  Future<void> _assertRequiredFiles(
    Directory root,
    SherpaOnnxTtsManifest manifest,
  ) async {
    final missing = <String>[];
    for (final relative in manifest.requiredRelativePaths) {
      final file = File('${root.path}/$relative');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() <= 0) {
        missing.add(relative);
      }
    }
    final dictDir = manifest.dictDir;
    if (dictDir != null && dictDir.isNotEmpty) {
      final dir = Directory('${root.path}/$dictDir');
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        missing.add(dictDir);
      }
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

  Future<void> _validateModelDirectoryBudget(Directory source) async {
    var entries = 0;
    var totalBytes = 0;
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      entries++;
      if (entries > importArchiveLimits.maxEntries) {
        throw const FormatException('TTS 模型目录文件数量过多');
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('TTS 模型目录不允许包含符号链接');
      }
      if (type != FileSystemEntityType.file) continue;
      final bytes = await File(entity.path).length();
      if (bytes > importArchiveLimits.maxEntryUncompressedBytes) {
        throw const FormatException('TTS 模型单文件过大');
      }
      totalBytes += bytes;
      if (totalBytes > importArchiveLimits.maxTotalUncompressedBytes) {
        throw const FormatException('TTS 模型目录总大小过大');
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

  void _validateRelativeModelPath(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value != value.trim() ||
        value.startsWith('/') ||
        value.contains(r'\') ||
        value.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw FormatException('TTS manifest 包含非法路径：$value');
    }
    final segments = value.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException('TTS manifest 包含非法路径：$value');
    }
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

final class _TtsArchiveOutputBudget {
  final BackupArchiveLimits limits;
  int totalBytes = 0;

  _TtsArchiveOutputBudget(this.limits);

  void add(int count, int entryBytes, String name) {
    if (count < 0 || entryBytes > limits.maxEntryUncompressedBytes) {
      throw FormatException('TTS 模型 ZIP 单个 entry 实际解压后过大：$name');
    }
    if (totalBytes + count > limits.maxTotalUncompressedBytes) {
      throw const FormatException('TTS 模型 ZIP 实际解压后总大小过大');
    }
    totalBytes += count;
  }
}

/// 同步解压器的有界文件 sink：不在 Dart heap 中保留完整模型，
/// 并在每个输出 chunk 上核算单文件/总量预算与 CRC。
final class _BoundedTtsFileSink extends OutputStream {
  static const _chunkBytes = 32 * 1024;

  final OutputFileStream _output;
  final _TtsArchiveOutputBudget _budget;
  final String _name;
  int _length = 0;
  int _crc32 = 0;

  _BoundedTtsFileSink(
    String path,
    this._budget,
    this._name,
  )   : _output = OutputFileStream(path, bufferSize: _chunkBytes),
        super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _length;

  int get crc32 => _crc32;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() => throw UnsupportedError('TTS ZIP sink 不支持 clear');

  @override
  void flush() => _output.flush();

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void writeByte(int value) => writeBytes([value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const FormatException('TTS ZIP entry 输出块大小不合法');
    }
    final chunk = count == bytes.length ? bytes : bytes.sublist(0, count);
    final nextLength = _length + count;
    _budget.add(count, nextLength, _name);
    _crc32 = getCrc32(chunk, _crc32);
    _output.writeBytes(chunk);
    _length = nextLength;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final remaining = stream.length;
      if (remaining <= 0) {
        throw const FormatException('TTS ZIP entry 输出流提前结束');
      }
      final count = remaining > _chunkBytes ? _chunkBytes : remaining;
      final chunk = stream.readBytes(count).toUint8List();
      if (chunk.isEmpty) {
        throw const FormatException('TTS ZIP entry 输出流提前结束');
      }
      writeBytes(chunk);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}
