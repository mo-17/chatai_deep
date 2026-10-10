import 'dart:convert';
import 'dart:io' as io show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../backup/backup_archive_limits.dart';
import 'legacy_office_text_extractor.dart';

/// Office 提取结果。警告描述文本转换的边界，不代替格式/资源错误。
final class OfficeTextExtraction {
  final String text;
  final List<String> warnings;

  OfficeTextExtraction({required this.text, List<String> warnings = const []})
      : warnings = List.unmodifiable(warnings);
}

/// 纯内存 Office 文本提取；不执行公式、宏、外部关系或磁盘解压。
final class OfficeTextExtractor {
  static const Set<String> supportedExtensions = {'doc', 'docx', 'xls', 'xlsx'};
  static const int _maxCharacters = 16 * 1024 * 1024;
  static const _archiveLimits = BackupArchiveLimits(
    maxCompressedBytes: 32 * 1024 * 1024,
    maxEntries: 4096,
    maxEntryUncompressedBytes: 32 * 1024 * 1024,
    maxTotalUncompressedBytes: 64 * 1024 * 1024,
  );

  static bool isOfficeFile(String filename) =>
      supportedExtensions.contains(_extension(filename));

  static String mimeFor(String filename) => switch (_extension(filename)) {
        'doc' => 'application/msword',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'xls' => 'application/vnd.ms-excel',
        'xlsx' =>
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        _ => 'application/octet-stream',
      };

  static OfficeTextExtraction extractBytes(
    Uint8List bytes, {
    required String filename,
    int maxCharacters = _maxCharacters,
  }) {
    final extension = _extension(filename);
    if (!supportedExtensions.contains(extension)) {
      throw const FormatException('不支持的 Office 文件扩展名');
    }
    if (maxCharacters <= 0) {
      throw const FormatException('Office 文本字符上限必须大于 0');
    }
    final limit =
        maxCharacters < _maxCharacters ? maxCharacters : _maxCharacters;
    if (bytes.length > _archiveLimits.maxCompressedBytes) {
      throw const FormatException('Office 文件超过 32 MiB 解析上限');
    }
    if (extension == 'doc' || extension == 'xls') {
      return OfficeTextExtraction(
        text: LegacyOfficeTextExtractor.extractBytes(bytes,
            extension: extension, maxCharacters: limit),
        warnings: extension == 'xls'
            ? const [
                '旧版 Excel 按原始单元格值提取；日期、货币等显示格式未重建，公式仅显示已有缓存结果且不执行。',
              ]
            : const [],
      );
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0xd0 &&
        bytes[1] == 0xcf &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xe0) {
      throw const FormatException('Office 文件已加密或格式与扩展名不符，无法提取');
    }
    try {
      _validateZipEnvelope(bytes);
      final archive = _decodeZip(bytes);
      final package = _OfficePackage(archive);
      final warnings = <String>{};
      final text = extension == 'docx'
          ? _extractWord(package, limit, warnings)
          : _extractWorkbook(package, limit, warnings);
      return OfficeTextExtraction(text: text, warnings: warnings.toList());
    } on FormatException catch (error) {
      // 共享 ZIP 工具的错误包含“备份”；附件入口使用具体的 Office 名称。
      throw FormatException(error.message.replaceAll('备份', 'Office'));
    } catch (_) {
      throw const FormatException('Office 文档损坏或包含不支持的结构，无法提取');
    }
  }

  static String _extension(String filename) {
    final basename = filename.split(RegExp(r'[/\\]')).last;
    final dot = basename.lastIndexOf('.');
    return dot < 0 ? '' : basename.substring(dot + 1).toLowerCase();
  }

  static Archive _decodeZip(Uint8List bytes) {
    final preflight = preflightBoundedZip(InputMemoryStream(bytes),
        compressedInputBytes: bytes.length, limits: _archiveLimits);
    final archive = Archive();
    for (final header in preflight.directory.fileHeaders) {
      if (header.filename.endsWith('/')) continue;
      final raw = header.file!.getStream(decompress: false);
      final output = _OfficeZipOutput(header.uncompressedSize);
      if (header.compressionMethod == 8) {
        // archive 4.0.9 的 VM decodeStream 会先累计所有输出块。直接 sink
        // 每块先核对预算，避免伪造 uncompressedSize 后先分配整个 ZIP bomb。
        final decoder =
            io.ZLibDecoder(raw: true).startChunkedConversion(output);
        while (!raw.isEOS) {
          final count = raw.length < 1024 ? raw.length : 1024;
          decoder.add(raw.readBytes(count).toUint8List());
        }
        decoder.close();
      } else {
        output.add(raw.toUint8List());
      }
      if (output.length != header.uncompressedSize ||
          getCrc32(output.bytes) != header.crc32) {
        throw FormatException('Office ZIP 实际解压大小或 CRC 不一致：${header.filename}');
      }
      archive.addFile(ArchiveFile.bytes(header.filename, output.bytes));
    }
    return archive;
  }

  /// archive 在读取中央目录时会创建所有 header；先用原始字段限制数量和范围。
  static void _validateZipEnvelope(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const FormatException('Office ZIP 不完整');
    }
    final data = ByteData.sublistView(bytes);
    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);
    var end = -1;
    final earliest = bytes.length > 65557 ? bytes.length - 65557 : 0;
    for (var i = bytes.length - 22; i >= earliest; i--) {
      if (u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.length) {
        end = i;
        break;
      }
    }
    if (end < 0) throw const FormatException('Office ZIP 缺少完整中央目录');
    final count = u16(end + 10);
    final size = u32(end + 12);
    final offset = u32(end + 16);
    if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
      throw const FormatException('Office 不支持 ZIP64 文件');
    }
    if (count == 0 || count > _archiveLimits.maxEntries) {
      throw const FormatException('Office ZIP entry 数量超过 4096 或为空');
    }
    if (u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != count ||
        offset + size > end) {
      throw const FormatException('Office ZIP 分卷或中央目录范围不合法');
    }
    var cursor = offset;
    var totalSize = 0;
    for (var i = 0; i < count; i++) {
      if (cursor + 46 > offset + size || u32(cursor) != 0x02014b50) {
        throw const FormatException('Office ZIP 中央目录损坏');
      }
      final flags = u16(cursor + 8);
      final method = u16(cursor + 10);
      final compressed = u32(cursor + 20);
      final uncompressed = u32(cursor + 24);
      final local = u32(cursor + 42);
      final nameLength = u16(cursor + 28);
      final next =
          cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32);
      if (next > offset + size || local + 30 > offset) {
        throw const FormatException('Office ZIP entry 范围不合法');
      }
      if ((flags & 0x41) != 0) {
        throw const FormatException('不支持加密的 Office ZIP');
      }
      if (method != 0 && method != 8) {
        throw const FormatException('Office ZIP 包含不支持的压缩算法');
      }
      totalSize += uncompressed;
      if (uncompressed > _archiveLimits.maxEntryUncompressedBytes ||
          totalSize > _archiveLimits.maxTotalUncompressedBytes) {
        throw const FormatException('Office ZIP 解压大小超过资源上限');
      }
      if (u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method ||
          local + 30 + u16(local + 26) + u16(local + 28) + compressed >
              offset) {
        throw const FormatException('Office ZIP 本地 entry 与中央目录不一致');
      }
      if ((flags & 8) == 0 &&
          (u32(local + 14) != u32(cursor + 16) ||
              u32(local + 18) != compressed ||
              u32(local + 22) != uncompressed)) {
        throw const FormatException('Office ZIP 本地大小或 CRC 与中央目录不一致');
      }
      cursor = next;
    }
    if (cursor != offset + size) {
      throw const FormatException('Office ZIP 中央目录 entry 数量不一致');
    }
  }

  static String _extractWord(
      _OfficePackage package, int limit, Set<String> warnings) {
    final mainPath = package.mainPart('docx');
    final document = package.xml(mainPath);
    if (!_is(document.rootElement, 'document', _wordNamespaces)) {
      throw const FormatException('DOCX 主文档根节点不合法');
    }
    final body = _child(document.rootElement, 'body', _wordNamespaces);
    if (body == null) throw const FormatException('DOCX 缺少正文');
    final relationships = package.relationships(mainPath, optional: true);
    final headers = <String>{};
    final footers = <String>{};
    for (final element in body.descendants.whereType<XmlElement>()) {
      final isHeader = _is(element, 'headerReference', _wordNamespaces);
      final isFooter = _is(element, 'footerReference', _wordNamespaces);
      if (!isHeader && !isFooter) continue;
      final id = _relationshipId(element);
      final relation = relationships[id];
      final kind = isHeader ? 'header' : 'footer';
      if (relation == null || !relation.isType(kind)) {
        throw FormatException('DOCX $kind 关系缺失或不合法');
      }
      final path = relation.internalPath(mainPath);
      (isHeader ? headers : footers).add(path);
    }
    final output = _BoundedText(limit);
    for (final path in headers) {
      final root = package.xml(path).rootElement;
      if (!_is(root, 'hdr', _wordNamespaces)) {
        throw const FormatException('DOCX 页眉根节点不合法');
      }
      output.write('[页眉]\n');
      _writeWordBlocks(root, output, warnings);
      output.write('\n');
    }
    _writeWordBlocks(body, output, warnings);
    for (final path in footers) {
      final root = package.xml(path).rootElement;
      if (!_is(root, 'ftr', _wordNamespaces)) {
        throw const FormatException('DOCX 页脚根节点不合法');
      }
      output.write('\n[页脚]\n');
      _writeWordBlocks(root, output, warnings);
    }
    return output.toString();
  }

  static void _writeWordBlocks(
      XmlElement parent, _BoundedText output, Set<String> warnings) {
    var first = true;
    void writeBlock(XmlElement element) {
      if (_is(element, 'p', _wordNamespaces)) {
        if (!first) output.write('\n');
        first = false;
        _writeWordInline(element, output, warnings);
      } else if (_is(element, 'tbl', _wordNamespaces)) {
        if (!first) output.write('\n');
        first = false;
        var firstRow = true;
        for (final row in _wordWrappedChildren(element, 'tr')) {
          if (!firstRow) output.write('\n');
          firstRow = false;
          var firstCell = true;
          for (final cell in _wordWrappedChildren(row, 'tc')) {
            if (!firstCell) output.write('\t');
            firstCell = false;
            _writeWordBlocks(cell, output, warnings);
          }
        }
      } else if (!_skipWordElement(element)) {
        for (final child in _contentChildren(element)) {
          writeBlock(child);
        }
      }
    }

    for (final element in _contentChildren(parent)) {
      writeBlock(element);
    }
  }

  static Iterable<XmlElement> _wordWrappedChildren(
      XmlElement parent, String name) sync* {
    for (final child in _contentChildren(parent)) {
      if (_is(child, name, _wordNamespaces)) {
        yield child;
      } else if (!_skipWordElement(child)) {
        yield* _wordWrappedChildren(child, name);
      }
    }
  }

  static void _writeWordInline(
      XmlElement element, _BoundedText output, Set<String> warnings) {
    if (_skipWordElement(element)) return;
    if (_is(element, 't', _wordNamespaces)) {
      output.write(element.innerText);
      return;
    }
    if (_is(element, 'tab', _wordNamespaces)) {
      output.write('\t');
      return;
    }
    if (_is(element, 'br', _wordNamespaces) ||
        _is(element, 'cr', _wordNamespaces)) {
      output.write('\n');
      return;
    }
    if (_is(element, 'noBreakHyphen', _wordNamespaces)) {
      output.write('\u2011');
      return;
    }
    if (_is(element, 'softHyphen', _wordNamespaces)) {
      output.write('\u00ad');
      return;
    }
    if (_is(element, 'drawing', _wordNamespaces) ||
        _is(element, 'pict', _wordNamespaces)) {
      warnings.add('DOCX 图片和图形未转换；仅提取其中可读取的正文文本。');
    }
    for (final child in _contentChildren(element)) {
      _writeWordInline(child, output, warnings);
    }
  }

  static bool _skipWordElement(XmlElement element) =>
      _wordNamespaces.contains(element.namespaceUri) &&
      (element.localName.endsWith('Pr') ||
          const {'del', 'delText', 'instrText', 'sectPr'}
              .contains(element.localName));

  /// AlternateContent 同时带新版和回退表示；只读取一个分支避免重复文本。
  static Iterable<XmlElement> _contentChildren(XmlElement element) {
    if (element.localName == 'AlternateContent' &&
        element.namespaceUri == _markupCompatibility) {
      final branches = element.childElements;
      final choices = branches.where((child) => child.localName == 'Choice');
      final selected = choices.isNotEmpty
          ? choices.first
          : branches
              .where((child) => child.localName == 'Fallback')
              .firstOrNull;
      return selected?.childElements ?? const <XmlElement>[];
    }
    return element.childElements;
  }

  static String _extractWorkbook(
      _OfficePackage package, int limit, Set<String> warnings) {
    final workbookPath = package.mainPart('xlsx');
    final root = package.xml(workbookPath).rootElement;
    if (!_is(root, 'workbook', _sheetNamespaces)) {
      throw const FormatException('XLSX 工作簿根节点不合法');
    }
    final relationships = package.relationships(workbookPath);
    final sharedRelations = relationships.values
        .where((relation) => relation.isType('sharedStrings'));
    if (sharedRelations.length > 1) {
      throw const FormatException('XLSX 存在多个共享字符串表');
    }
    final sharedStrings = <String>[];
    if (sharedRelations.isNotEmpty) {
      final path = sharedRelations.first.internalPath(workbookPath);
      final sharedRoot = package.xml(path).rootElement;
      if (!_is(sharedRoot, 'sst', _sheetNamespaces)) {
        throw const FormatException('XLSX 共享字符串根节点不合法');
      }
      for (final item in sharedRoot.childElements) {
        if (_is(item, 'si', _sheetNamespaces)) {
          sharedStrings.add(_spreadsheetString(item, limit));
        }
      }
    }
    final sheets = _child(root, 'sheets', _sheetNamespaces);
    if (sheets == null) throw const FormatException('XLSX 缺少工作表列表');
    final output = _BoundedText(limit);
    final names = <String>{};
    var first = true;
    for (final sheet in sheets.childElements) {
      if (!_is(sheet, 'sheet', _sheetNamespaces)) continue;
      final name = sheet.getAttribute('name');
      final id = _relationshipId(sheet);
      final relation = relationships[id];
      if (name == null ||
          name.isEmpty ||
          !names.add(name) ||
          relation == null) {
        throw const FormatException('XLSX 工作表名称或关系不合法');
      }
      if (!first) output.write('\n\n');
      first = false;
      output.write('[工作表：$name]\n');
      if (relation.isType('chartsheet')) {
        output.write('[图表工作表，无可提取单元格]');
        warnings.add('XLSX 图表工作表未转换为文本。');
        continue;
      }
      if (!relation.isType('worksheet')) {
        throw const FormatException('XLSX 工作表关系类型不受支持');
      }
      final path = relation.internalPath(workbookPath);
      _writeWorksheet(
          package.xml(path), sharedStrings, output, warnings, limit);
    }
    if (first) throw const FormatException('XLSX 没有工作表');
    return output.toString();
  }

  static void _writeWorksheet(XmlDocument document, List<String> sharedStrings,
      _BoundedText output, Set<String> warnings, int limit) {
    final root = document.rootElement;
    if (!_is(root, 'worksheet', _sheetNamespaces)) {
      throw const FormatException('XLSX 工作表根节点不合法');
    }
    final sheetData = _child(root, 'sheetData', _sheetNamespaces);
    if (sheetData == null) throw const FormatException('XLSX 缺少单元格数据容器');
    final rows = <int, Map<int, String>>{};
    var previousRow = 0;
    var maxColumn = 0;
    for (final row in sheetData.childElements) {
      if (!_is(row, 'row', _sheetNamespaces)) continue;
      final firstCellReference = row.childElements
          .where((cell) => _is(cell, 'c', _sheetNamespaces))
          .firstOrNull
          ?.getAttribute('r');
      final inferredRow = firstCellReference == null
          ? null
          : RegExp(r'^[A-Z]{1,3}([1-9][0-9]*)$')
              .firstMatch(firstCellReference)
              ?.group(1);
      final rowIndex = row.getAttribute('r') == null && inferredRow == null
          ? previousRow + 1
          : _positiveInt(row.getAttribute('r') ?? inferredRow, 'XLSX 行号');
      if (rowIndex <= previousRow || rowIndex > 1048576) {
        throw const FormatException('XLSX 行号越界、重复或顺序不合法');
      }
      previousRow = rowIndex;
      final cells = <int, String>{};
      var previousColumn = 0;
      for (final cell in row.childElements) {
        if (!_is(cell, 'c', _sheetNamespaces)) continue;
        final reference = cell.getAttribute('r');
        var column = previousColumn + 1;
        if (reference != null) {
          final match =
              RegExp(r'^([A-Z]{1,3})([1-9][0-9]*)$').firstMatch(reference);
          if (match == null || int.tryParse(match.group(2)!) != rowIndex) {
            throw const FormatException('XLSX 单元格地址与行号不一致');
          }
          column = 0;
          for (final code in match.group(1)!.codeUnits) {
            column = column * 26 + code - 64;
          }
        }
        if (column <= previousColumn || column > 16384) {
          throw const FormatException('XLSX 列号越界、重复或顺序不合法');
        }
        previousColumn = column;
        if (column > maxColumn) maxColumn = column;
        cells[column] = _cellValue(cell, sharedStrings, warnings, limit);
      }
      rows[rowIndex] = cells;
    }
    // 稀疏表也必须保留行列位置；先校验展开后的空格预算，拒绝巨大空矩形。
    final separators = previousRow * (maxColumn > 0 ? maxColumn - 1 : 0) +
        (previousRow > 0 ? previousRow - 1 : 0);
    if (separators > limit - output.length) {
      throw const FormatException('XLSX 空行/空列展开超过文本资源上限');
    }
    for (var row = 1; row <= previousRow; row++) {
      if (row != 1) output.write('\n');
      final cells = rows[row];
      for (var column = 1; column <= maxColumn; column++) {
        if (column != 1) output.write('\t');
        final value = cells?[column];
        if (value != null) output.write(_tsvValue(value));
      }
    }
  }

  static String _cellValue(
      XmlElement cell, List<String> strings, Set<String> warnings, int limit) {
    final formula = _child(cell, 'f', _sheetNamespaces);
    final valueElement = _child(cell, 'v', _sheetNamespaces);
    if (formula != null) {
      warnings.add('Excel 公式未执行；显示已有缓存结果，缓存可能与最新数据不一致。');
      if (valueElement == null || valueElement.innerText.isEmpty) {
        warnings.add('部分 Excel 公式无缓存结果，已在对应单元格明确标记。');
        return '[公式未计算：无缓存结果]';
      }
    }
    final type = cell.getAttribute('t') ?? 'n';
    final value = valueElement?.innerText ?? '';
    if (type == 'n' && cell.getAttribute('s') != null) {
      warnings.add('Excel 按原始单元格值提取，日期、货币等显示格式未重建。');
    }
    switch (type) {
      case 'inlineStr':
        final inline = _child(cell, 'is', _sheetNamespaces);
        if (inline == null) {
          throw const FormatException('XLSX inline 字符串内容缺失');
        }
        return _spreadsheetString(inline, limit);
      case 's':
        final index = int.tryParse(value);
        if (index == null || index < 0 || index >= strings.length) {
          throw const FormatException('XLSX 共享字符串索引不合法或内容缺失');
        }
        return strings[index];
      case 'b':
        if (value == '1') return 'TRUE';
        if (value == '0') return 'FALSE';
        if (value.isEmpty && formula == null) return '';
        throw const FormatException('XLSX 布尔单元格值不合法');
      case 'n':
        if (value.isNotEmpty &&
            (!RegExp(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[Ee][+-]?[0-9]+)?$')
                    .hasMatch(value) ||
                !(double.tryParse(value)?.isFinite ?? false))) {
          throw const FormatException('XLSX 数值单元格值不合法');
        }
        return value;
      case 'str':
      case 'e':
      case 'd':
        return _decodeSpreadsheetEscapes(value);
      default:
        throw FormatException('XLSX 不支持的单元格类型：$type');
    }
  }

  static String _spreadsheetString(XmlElement parent, int limit) {
    final output = _BoundedText(limit);
    void visit(XmlElement element) {
      if (_is(element, 'rPh', _sheetNamespaces)) return;
      if (_is(element, 't', _sheetNamespaces)) {
        output.write(_decodeSpreadsheetEscapes(element.innerText));
      } else {
        for (final child in element.childElements) {
          visit(child);
        }
      }
    }

    visit(parent);
    return output.toString();
  }

  static String _decodeSpreadsheetEscapes(String value) =>
      value.replaceAllMapped(
          RegExp(r'_x([0-9a-fA-F]{4})_'),
          (match) =>
              String.fromCharCode(int.parse(match.group(1)!, radix: 16)));

  static String _tsvValue(String value) => value.contains(RegExp('[\t\r\n"]'))
      ? '"${value.replaceAll('"', '""')}"'
      : value;
}

const _wordNamespaces = {
  'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
  'http://purl.oclc.org/ooxml/wordprocessingml/main',
};
const _sheetNamespaces = {
  'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
  'http://purl.oclc.org/ooxml/spreadsheetml/main',
};
const _relationshipNamespaces = {
  'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
  'http://purl.oclc.org/ooxml/officeDocument/relationships',
};
const _packageRelationships =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _contentTypes =
    'http://schemas.openxmlformats.org/package/2006/content-types';
const _markupCompatibility =
    'http://schemas.openxmlformats.org/markup-compatibility/2006';

bool _is(XmlElement element, String localName, Set<String> namespaces) =>
    element.localName == localName && namespaces.contains(element.namespaceUri);

XmlElement? _child(XmlElement parent, String name, Set<String> namespaces) =>
    parent.childElements
        .where((element) => _is(element, name, namespaces))
        .firstOrNull;

String? _relationshipId(XmlElement element) {
  for (final namespace in _relationshipNamespaces) {
    final id = element.getAttribute('id', namespace: namespace);
    if (id != null) return id;
  }
  return null;
}

int _positiveInt(String? value, String label) {
  if (value == null || !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
    throw FormatException('$label 不合法');
  }
  final number = int.tryParse(value);
  if (number == null) throw FormatException('$label 超过资源上限');
  return number;
}

final class _BoundedText {
  final int limit;
  final StringBuffer _buffer = StringBuffer();
  int length = 0;

  _BoundedText(this.limit);

  void write(String text) {
    if (text.length > limit - length) {
      throw FormatException('Office 提取文本超过 $limit 字符资源上限');
    }
    length += text.length;
    _buffer.write(text);
  }

  @override
  String toString() => _buffer.toString();
}

final class _OfficeZipOutput implements Sink<List<int>> {
  final Uint8List bytes;
  int length = 0;

  _OfficeZipOutput(int expectedBytes) : bytes = Uint8List(expectedBytes);

  @override
  void add(List<int> chunk) {
    if (chunk.length > bytes.length - length) {
      throw const FormatException('Office ZIP 实际解压大小超过声明值或资源上限');
    }
    bytes.setRange(length, length + chunk.length, chunk);
    length += chunk.length;
  }

  @override
  void close() {}
}

final class _OfficeRelationship {
  final String type;
  final String target;
  final bool external;

  _OfficeRelationship(this.type, this.target, this.external);

  bool isType(String suffix) =>
      _relationshipNamespaces.any((namespace) => type == '$namespace/$suffix');

  String internalPath(String sourcePart) {
    if (external) throw const FormatException('Office 必需内容引用了外部关系，无法提取');
    if (target.contains('\\')) {
      throw const FormatException('Office 关系路径不合法');
    }
    final uri = Uri.tryParse(target);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Office 关系目标不是合法的包内路径');
    }
    final segments = <String>[];
    if (!target.startsWith('/') && sourcePart.contains('/')) {
      segments.addAll(sourcePart.split('/')..removeLast());
    }
    for (final encoded in uri.path.split('/')) {
      if (encoded.isEmpty || encoded == '.') continue;
      final segment = Uri.decodeComponent(encoded);
      if (segment == '..') {
        if (segments.isEmpty) throw const FormatException('Office 关系路径越过包根目录');
        segments.removeLast();
      } else {
        if (segment == '.' || segment.contains(RegExp(r'[/\\\x00]'))) {
          throw const FormatException('Office 关系路径不合法');
        }
        segments.add(segment);
      }
    }
    if (segments.isEmpty) throw const FormatException('Office 关系目标路径为空');
    return segments.join('/');
  }
}

bool _isXmlCharacter(int code) =>
    code == 9 ||
    code == 10 ||
    code == 13 ||
    (code >= 0x20 && code <= 0xd7ff) ||
    (code >= 0xe000 && code <= 0xfffd) ||
    (code >= 0x10000 && code <= 0x10ffff);

final class _StrictOfficeXmlEntities extends XmlDefaultEntityMapping {
  const _StrictOfficeXmlEntities() : super.xml();

  @override
  String decode(String input) {
    var start = input.indexOf('&');
    while (start >= 0) {
      final end = input.indexOf(';', start + 1);
      if (end < 0) throw const FormatException('Office XML 实体引用不完整');
      final decoded = decodeEntity(input.substring(start + 1, end));
      if (decoded == null ||
          decoded.runes.any((code) => !_isXmlCharacter(code))) {
        throw const FormatException('Office XML 包含未知实体或非法字符引用');
      }
      start = input.indexOf('&', end + 1);
    }
    return super.decode(input);
  }
}

final class _OfficePackage {
  final Map<String, ArchiveFile> files;
  int _xmlNodes = 0;

  _OfficePackage(Archive archive)
      : files = {
          for (final file in archive.files)
            if (file.isFile) file.name: file
        };

  XmlDocument xml(String path) {
    final file = files[path];
    if (file == null) throw FormatException('Office 缺少必需内容：$path');
    final text = _decodeXml(file.content);
    if (text.length > 16 * 1024 * 1024) {
      throw const FormatException('Office XML 超过 16 Mi 字符资源上限');
    }
    if (text.runes.any((code) => !_isXmlCharacter(code))) {
      throw const FormatException('Office XML 包含不合法的控制字符');
    }
    // DTD 在解析前拒绝；XML 库无网络入口，此处也不注册任何自定义实体。
    if (RegExp(r'<!\s*(?:DOCTYPE|ENTITY)\b', caseSensitive: false)
        .hasMatch(text)) {
      throw const FormatException('Office XML 不允许 DTD 或自定义实体');
    }
    var depth = 0;
    try {
      const entityMapping = _StrictOfficeXmlEntities();
      for (final event in parseEvents(text,
          entityMapping: entityMapping,
          validateNesting: true,
          validateDocument: true)) {
        if (++_xmlNodes > 250000) {
          throw const FormatException('Office XML 节点数量超过资源上限');
        }
        if (event is XmlDoctypeEvent) {
          throw const FormatException('Office XML 不允许 DTD');
        }
        if (event is XmlTextEvent) {
          // XML 库延迟解码文本；即使此节点不参与提取，也必须拒绝未知实体。
          event.value;
        }
        if (event is XmlStartElementEvent && !event.isSelfClosing) {
          if (++depth > 128) {
            throw const FormatException('Office XML 嵌套深度超过资源上限');
          }
        } else if (event is XmlEndElementEvent) {
          depth--;
        }
      }
      return XmlDocument.parse(text, entityMapping: entityMapping);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException('Office XML 内容损坏：$path');
    }
  }

  String mainPart(String extension) {
    final rootRelations = relationships('');
    final mainRelations = rootRelations.values
        .where((relation) => relation.isType('officeDocument'));
    if (mainRelations.length != 1) {
      throw const FormatException('Office 缺少唯一主文档关系');
    }
    final path = mainRelations.single.internalPath('');
    final types = xml('[Content_Types].xml').rootElement;
    if (types.localName != 'Types' || types.namespaceUri != _contentTypes) {
      throw const FormatException('Office 内容类型清单不合法');
    }
    final expected = extension == 'docx'
        ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'
        : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml';
    final declarations = types.childElements.where((element) =>
        element.localName == 'Override' &&
        element.namespaceUri == _contentTypes &&
        element.getAttribute('PartName') == '/$path');
    if (declarations.length != 1 ||
        declarations.single.getAttribute('ContentType') != expected) {
      throw const FormatException('Office 主文档内容类型与扩展名不符');
    }
    return path;
  }

  Map<String, _OfficeRelationship> relationships(String part,
      {bool optional = false}) {
    final slash = part.lastIndexOf('/');
    final path = part.isEmpty
        ? '_rels/.rels'
        : '${slash < 0 ? '' : part.substring(0, slash + 1)}_rels/${part.substring(slash + 1)}.rels';
    if (optional && !files.containsKey(path)) return {};
    final root = xml(path).rootElement;
    if (root.localName != 'Relationships' ||
        root.namespaceUri != _packageRelationships) {
      throw FormatException('Office 关系清单根节点不合法：$path');
    }
    final result = <String, _OfficeRelationship>{};
    for (final element in root.childElements) {
      if (element.localName != 'Relationship' ||
          element.namespaceUri != _packageRelationships) {
        continue;
      }
      final id = element.getAttribute('Id');
      final type = element.getAttribute('Type');
      final target = element.getAttribute('Target');
      final mode = element.getAttribute('TargetMode');
      if (id == null ||
          id.isEmpty ||
          type == null ||
          target == null ||
          target.isEmpty ||
          result.containsKey(id) ||
          (mode != null && mode != 'Internal' && mode != 'External')) {
        throw FormatException('Office 关系清单内容不合法：$path');
      }
      result[id] = _OfficeRelationship(type, target, mode == 'External');
    }
    return result;
  }

  static String _decodeXml(Uint8List bytes) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff) ||
            (bytes[0] == 0 && bytes[1] == 0x3c) ||
            (bytes[0] == 0x3c && bytes[1] == 0))) {
      final hasBom = bytes[0] == 0xff || bytes[0] == 0xfe;
      final little = bytes[0] == 0xff || bytes[0] == 0x3c;
      final start = hasBom ? 2 : 0;
      if ((bytes.length - start).isOdd) {
        throw const FormatException('Office UTF-16 XML 不完整');
      }
      final data = ByteData.sublistView(bytes);
      final units = <int>[];
      for (var i = start; i < bytes.length; i += 2) {
        final unit = data.getUint16(i, little ? Endian.little : Endian.big);
        if (unit >= 0xd800 && unit <= 0xdbff) {
          if (i + 3 >= bytes.length) {
            throw const FormatException('Office UTF-16 字符不完整');
          }
          final next =
              data.getUint16(i + 2, little ? Endian.little : Endian.big);
          if (next < 0xdc00 || next > 0xdfff) {
            throw const FormatException('Office UTF-16 字符不合法');
          }
          units.add(unit);
          units.add(next);
          i += 2;
        } else {
          if (unit >= 0xdc00 && unit <= 0xdfff) {
            throw const FormatException('Office UTF-16 字符不合法');
          }
          units.add(unit);
        }
      }
      return String.fromCharCodes(units);
    }
    return utf8.decode(bytes);
  }
}
