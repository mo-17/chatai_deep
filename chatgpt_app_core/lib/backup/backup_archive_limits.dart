import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';

/// 备份 ZIP 的资源上限。
///
/// 这些限制在任何 entry 内容解压前根据 ZIP 元数据检查。测试可传入更小的
/// [BackupArchiveLimits]，无需构造数百 MiB 的归档。
final class BackupArchiveLimits {
  static const int _mib = 1024 * 1024;

  static const standard = BackupArchiveLimits(
    maxCompressedBytes: 256 * _mib,
    maxEntries: 10000,
    maxEntryUncompressedBytes: 128 * _mib,
    maxTotalUncompressedBytes: 512 * _mib,
  );

  final int maxCompressedBytes;
  final int maxEntries;
  final int maxEntryUncompressedBytes;
  final int maxTotalUncompressedBytes;

  const BackupArchiveLimits({
    required this.maxCompressedBytes,
    required this.maxEntries,
    required this.maxEntryUncompressedBytes,
    required this.maxTotalUncompressedBytes,
  })  : assert(maxCompressedBytes >= 0),
        assert(maxEntries >= 0),
        assert(maxEntryUncompressedBytes >= 0),
        assert(maxTotalUncompressedBytes >= 0);
}

/// 从 ZipDecoder callback 捕获的单个原始 header 元数据。
///
/// callback 会为重复 header 分别触发，因此不要从最终 `Archive.files`
/// 重建此列表，否则同名 entry 会在 archive 层被折叠而绕过重复名检查。
final class BackupArchiveEntryName {
  final String name;
  final bool isDirectory;

  const BackupArchiveEntryName({
    required this.name,
    required this.isDirectory,
  });

  /// ZIP 的普通目录名以 `/` 结尾；路径校验按目录自身的规范路径执行。
  /// 只剥掉一个 `/`，因此 `dir//` 等异常路径仍会被拒绝。
  String get nameForValidation => isDirectory && name.endsWith('/')
      ? name.substring(0, name.length - 1)
      : name;
}

final class BackupArchiveEntryInfo {
  final String name;
  final bool isDirectory;
  final bool isSymbolicLink;
  final bool isEncrypted;
  final bool hasRawContent;
  final int uncompressedBytes;
  final int compressedBytes;

  const BackupArchiveEntryInfo({
    required this.name,
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.isEncrypted,
    required this.hasRawContent,
    required this.uncompressedBytes,
    required this.compressedBytes,
  });
}

/// 尚未解压的 ZIP 中央目录与逐 entry 安全元数据。
///
/// [directory] 内的压缩 slice 仍引用调用方传入的 [InputStream]；文件流调用方
/// 必须在消费完所有 entry 后再关闭它。
final class BackupArchivePreflight {
  final ZipDirectory directory;
  final List<BackupArchiveEntryInfo> entries;

  const BackupArchivePreflight({
    required this.directory,
    required this.entries,
  });
}

/// ZIP entry 实际解压输出的共享预算。
///
/// header 只用于快速 preflight；真正解压时每次写入都通过此预算，同时限制
/// 单 entry 与整个 archive，避免伪造 `uncompressedSize` 绕过上限。
final class BackupArchiveOutputBudget {
  final BackupArchiveLimits limits;
  int _totalBytes = 0;

  BackupArchiveOutputBudget({
    this.limits = BackupArchiveLimits.standard,
  });

  int get totalBytes => _totalBytes;

  BackupArchiveOutputSink newEntry(String name) =>
      BackupArchiveOutputSink._(this, name);

  void _add(int bytes, int entryBytes, String name) {
    if (bytes < 0) {
      throw const FormatException('备份 entry 实际解压大小不合法');
    }
    if (entryBytes > limits.maxEntryUncompressedBytes) {
      throw FormatException('单个备份 entry 实际解压后过大：$name');
    }
    if (_totalBytes + bytes > limits.maxTotalUncompressedBytes) {
      throw const FormatException('备份实际解压后总大小过大');
    }
    _totalBytes += bytes;
  }

  void _remove(int bytes) {
    _totalBytes -= bytes;
  }
}

/// archive 4.x `ZipFile.decompress(OutputStream)` 使用的有界内存 sink。
final class BackupArchiveOutputSink extends OutputStream {
  static const int _streamChunkBytes = 32 * 1024;

  final BackupArchiveOutputBudget _budget;
  final String _name;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  BackupArchiveOutputSink._(this._budget, this._name)
      : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _bytes.length;

  @override
  void clear() {
    _budget._remove(length);
    _bytes.clear();
  }

  @override
  void flush() {}

  @override
  void writeByte(int value) {
    final nextLength = length + 1;
    _budget._add(1, nextLength, _name);
    _bytes.addByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const FormatException('备份 entry 实际输出块大小不合法');
    }
    final nextLength = this.length + count;
    _budget._add(count, nextLength, _name);
    _bytes.add(count == bytes.length ? bytes : bytes.sublist(0, count));
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final remaining = stream.length;
      if (remaining <= 0) {
        throw const FormatException('备份 entry 实际输出流状态不合法');
      }
      final chunkLength =
          remaining > _streamChunkBytes ? _streamChunkBytes : remaining;
      final chunk = stream.readBytes(chunkLength).toUint8List();
      if (chunk.isEmpty) {
        throw const FormatException('备份 entry 实际输出流提前结束');
      }
      writeBytes(chunk);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final bytes = getBytes();
    final normalizedStart = start < 0 ? bytes.length + start : start;
    final normalizedEnd = end == null
        ? bytes.length
        : end < 0
            ? bytes.length + end
            : end;
    return Uint8List.fromList(
      bytes.sublist(normalizedStart, normalizedEnd),
    );
  }

  @override
  Uint8List getBytes() => _bytes.toBytes();

  /// 把当前 entry 所有权移交给调用方并释放本 sink 的预算/缓冲。
  ///
  /// 适用于逐 entry 落盘的导入器；archive 总大小仍由解压前的中央目录汇总
  /// 校验约束，且调用方必须核对实际长度与 CRC。
  Uint8List takeBytes() {
    final bytes = _bytes.takeBytes();
    _budget._remove(bytes.length);
    return bytes;
  }
}

/// 只读取 ZIP 中央目录与本地 header，不解压 entry 内容。
BackupArchivePreflight preflightBoundedZip(
  InputStream input, {
  required int compressedInputBytes,
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
}) {
  validateBackupCompressedSize(compressedInputBytes, limits: limits);
  final directory = ZipDirectory()..read(input);
  validateBackupEntryCount(directory.totalCentralDirectoryEntries,
      limits: limits);
  validateBackupEntryCount(directory.fileHeaders.length, limits: limits);
  if (directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.totalCentralDirectoryEntriesOnThisDisk !=
          directory.totalCentralDirectoryEntries ||
      directory.totalCentralDirectoryEntries != directory.fileHeaders.length) {
    throw const FormatException('备份不支持分卷或截断的 ZIP 中央目录');
  }

  final names = <BackupArchiveEntryName>[];
  final entries = <BackupArchiveEntryInfo>[];
  for (final header in directory.fileHeaders) {
    final localFile = header.file;
    if (localFile == null || localFile.filename != header.filename) {
      throw const FormatException('备份 ZIP 本地 header 与中央目录不一致');
    }
    final isDirectory =
        header.filename.endsWith('/') || header.filename.endsWith('\\');
    final entryMode = header.externalFileAttributes >> 16;
    final isEncrypted = (header.generalPurposeBitFlag & 0x1) != 0 ||
        (localFile.flags & 0x1) != 0;
    // `ZipFile.length` 会复制整个压缩 entry；预检只读 raw stream
    // 的已夹紧 length，保持 InputFileStream 的流式边界。
    final rawContentBytes =
        isEncrypted ? -1 : localFile.getStream(decompress: false).length;
    names.add(BackupArchiveEntryName(
      name: header.filename,
      isDirectory: isDirectory,
    ));
    entries.add(BackupArchiveEntryInfo(
      name: header.filename,
      isDirectory: isDirectory,
      isSymbolicLink:
          (header.versionMadeBy >> 8) == 3 && (entryMode & 0xf000) == 0xa000,
      isEncrypted: isEncrypted,
      hasRawContent: rawContentBytes == header.compressedSize,
      uncompressedBytes: header.uncompressedSize,
      compressedBytes: header.compressedSize,
    ));
  }
  validateBackupArchiveEntries(
    entries,
    rawEntryNames: names,
    compressedInputBytes: compressedInputBytes,
    limits: limits,
  );
  return BackupArchivePreflight(
    directory: directory,
    entries: List.unmodifiable(entries),
  );
}

/// 在实际输出预算下解压 ZIP。角色卡、技能等导入器共享这条边界，避免直接
/// 调用 `ZipDecoder.decodeBytes` 在检查 entry 数量/大小前分配攻击者声明的内容。
Archive decodeBoundedZipArchive(
  List<int> zipBytes, {
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
  String invalidArchiveMessage = '不是有效的备份文件（zip 解析失败）',
}) {
  try {
    final preflight = preflightBoundedZip(
      InputMemoryStream(zipBytes),
      compressedInputBytes: zipBytes.length,
      limits: limits,
    );
    final outputBudget = BackupArchiveOutputBudget(limits: limits);
    final archive = Archive();
    for (var index = 0;
        index < preflight.directory.fileHeaders.length;
        index++) {
      final header = preflight.directory.fileHeaders[index];
      final localFile = header.file!;
      final metadata = preflight.entries[index];
      if (localFile.flags != header.generalPurposeBitFlag ||
          localFile.compressedSize != header.compressedSize ||
          localFile.uncompressedSize != header.uncompressedSize) {
        throw const FormatException('备份 ZIP 本地 header 与中央目录大小不一致');
      }
      if (metadata.isDirectory) {
        if (header.uncompressedSize != 0) {
          throw const FormatException('备份目录 entry 大小不合法');
        }
        archive.addFile(
          ArchiveFile.directory(header.filename)
            ..mode = header.externalFileAttributes >> 16,
        );
        continue;
      }

      final sink = outputBudget.newEntry(header.filename);
      localFile.decompress(sink);
      final bytes = sink.getBytes();
      if (bytes.length != header.uncompressedSize) {
        throw FormatException('备份 entry 实际解压大小与 header 不一致：${header.filename}');
      }
      if (getCrc32(bytes) != header.crc32) {
        throw FormatException('备份 entry CRC 校验失败：${header.filename}');
      }
      archive.addFile(
        ArchiveFile.bytes(header.filename, bytes)
          ..mode = header.externalFileAttributes >> 16
          ..crc32 = header.crc32
          ..lastModTime =
              header.lastModifiedFileDate << 16 | header.lastModifiedFileTime,
      );
    }
    return archive;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw FormatException(invalidArchiveMessage);
  }
}

/// 在把压缩数据交给 ZipDecoder 前调用，避免超大输入先占用解析资源。
void validateBackupCompressedSize(
  int compressedBytes, {
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
}) {
  if (compressedBytes < 0) {
    throw const FormatException('备份 ZIP 压缩大小不合法');
  }
  if (compressedBytes > limits.maxCompressedBytes) {
    throw const FormatException('备份文件过大（压缩后不能超过 256 MiB）');
  }
}

/// callback 每读到一个原始 ZIP header 时调用，避免数量失控后继续收集。
void validateBackupEntryCount(
  int entryCount, {
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
}) {
  if (entryCount < 0 || entryCount > limits.maxEntries) {
    throw const FormatException('备份 entry 数量过多（最多 10000 个）');
  }
}

/// 校验从原始 ZIP header 收集的名称，保留重复项以阻止 archive 去重绕过。
void validateBackupArchiveEntryNames(
  Iterable<BackupArchiveEntryName> rawEntryNames, {
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
}) {
  final names = List<BackupArchiveEntryName>.of(rawEntryNames);
  validateBackupEntryCount(names.length, limits: limits);
  validateBackupEntryNames(names.map((entry) => entry.nameForValidation));
}

/// 根据 ZIP 中央目录中尚未解压的 entry 元数据执行 ZIP bomb 与路径防护。
void validateBackupArchiveEntries(
  Iterable<BackupArchiveEntryInfo> decodedEntries, {
  required Iterable<BackupArchiveEntryName> rawEntryNames,
  required int compressedInputBytes,
  BackupArchiveLimits limits = BackupArchiveLimits.standard,
}) {
  validateBackupCompressedSize(compressedInputBytes, limits: limits);

  // 名称来自每个原始 ZIP header，而非已去重的 Archive.files。
  final names = List<BackupArchiveEntryName>.of(rawEntryNames);
  validateBackupArchiveEntryNames(names, limits: limits);

  final entries = List<BackupArchiveEntryInfo>.of(decodedEntries);
  if (entries.length != names.length) {
    throw const FormatException('备份 entry 元数据数量不合法');
  }
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].name != names[i].name ||
        entries[i].isDirectory != names[i].isDirectory) {
      throw const FormatException('备份 entry 名称与大小元数据不一致');
    }
  }

  var totalUncompressedBytes = 0;
  var totalCompressedBytes = 0;
  for (final entry in entries) {
    if (entry.isSymbolicLink) {
      throw const FormatException('备份不允许包含符号链接');
    }
    if (entry.isEncrypted) {
      throw const FormatException('备份不允许包含加密 ZIP entry');
    }
    if (entry.uncompressedBytes < 0 || entry.compressedBytes < 0) {
      throw const FormatException('备份 entry 大小元数据不合法');
    }
    if (entry.compressedBytes > compressedInputBytes) {
      throw const FormatException('备份 entry 压缩大小元数据不合法');
    }
    if (!entry.isDirectory &&
        !entry.hasRawContent &&
        (entry.uncompressedBytes != 0 || entry.compressedBytes != 0)) {
      throw const FormatException('备份 entry 缺少压缩内容');
    }
    if (entry.uncompressedBytes > limits.maxEntryUncompressedBytes) {
      throw const FormatException('单个备份 entry 解压后过大（最多 128 MiB）');
    }

    totalUncompressedBytes += entry.uncompressedBytes;
    if (totalUncompressedBytes > limits.maxTotalUncompressedBytes) {
      throw const FormatException('备份解压后总大小过大（最多 512 MiB）');
    }

    totalCompressedBytes += entry.compressedBytes;
    if (totalCompressedBytes > compressedInputBytes) {
      throw const FormatException('备份 entry 压缩大小总和不合法');
    }
  }
}
