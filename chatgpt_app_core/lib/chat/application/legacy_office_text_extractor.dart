import 'dart:math' as math;
import 'dart:typed_data';

/// 纯 Dart 旧 Office 文本读取：Word 97–2003 主正文、Excel BIFF8 单元格。
///
/// 容器遵循 MS-CFB，DOC 的 FIB/CLX/Pcd 遵循 MS-DOC，XLS 的
/// BoundSheet8/SST/Continue/FormulaValue 遵循 MS-XLS。只读取已保存的数据，
/// 不解释宏、公式、外部链接或嵌入对象；不支持的版本、加密及损坏会明确失败。
/// 文本中的数字为原始缓存值，Excel 的日期/货币等显示格式不在本提取器范围内。
class LegacyOfficeTextExtractor {
  static const int _maxFileBytes = 64 * 1024 * 1024;

  static String extractBytes(
    Uint8List bytes, {
    required String extension,
    required int maxCharacters,
  }) {
    final ext = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (ext != 'doc' && ext != 'xls') {
      throw const FormatException('旧 Office 提取器仅支持 DOC 或 XLS');
    }
    if (maxCharacters <= 0) {
      throw const FormatException('旧 Office 文本上限必须大于零');
    }
    if (bytes.length > _maxFileBytes) {
      throw const FormatException('旧 Office 文件超过 64 MiB 解析上限');
    }
    final cfb = _CompoundFile(bytes);
    if (cfb.hasRootStream('EncryptionInfo') ||
        cfb.hasRootStream('EncryptedPackage')) {
      throw const FormatException('不支持加密的 Office 文件');
    }
    return ext == 'doc'
        ? _WordText.read(cfb, maxCharacters)
        : _WorkbookText.read(cfb, maxCharacters);
  }
}

Never _bad(String message) => throw FormatException(message);

class _Bytes {
  final Uint8List bytes;
  late final ByteData data = ByteData.sublistView(bytes);
  final String context;

  _Bytes(this.bytes, this.context);

  void need(int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) {
      _bad('$context 数据损坏或截断');
    }
  }

  int u8(int offset) {
    need(offset, 1);
    return bytes[offset];
  }

  int u16(int offset) {
    need(offset, 2);
    return data.getUint16(offset, Endian.little);
  }

  int u32(int offset) {
    need(offset, 4);
    return data.getUint32(offset, Endian.little);
  }

  double f64(int offset) {
    need(offset, 8);
    final value = data.getFloat64(offset, Endian.little);
    if (!value.isFinite) _bad('$context 含无效数值');
    return value;
  }

  Uint8List slice(int offset, int length) {
    need(offset, length);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

String _unicode(List<int> units, String context) {
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        _bad('$context 含无效 UTF-16 文本');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _bad('$context 含无效 UTF-16 文本');
    }
  }
  return String.fromCharCodes(units);
}

String _utf16(_Bytes data, int offset, int characters, String context) {
  data.need(offset, characters * 2);
  return _unicode(
    List<int>.generate(characters, (i) => data.u16(offset + i * 2)),
    context,
  );
}

class _TextLimit {
  final int limit;
  final StringBuffer _buffer = StringBuffer();
  int _length = 0;

  _TextLimit(this.limit);

  void add(String text) {
    if (text.length > limit - _length) {
      _bad('旧 Office 文本超过 $limit 字符上限');
    }
    _length += text.length;
    _buffer.write(text);
  }

  @override
  String toString() => _buffer.toString();
}

class _DirectoryEntry {
  final String name;
  final int type;
  final int left;
  final int right;
  final int child;
  final int start;
  final int size;
  List<int> chain = const [];

  _DirectoryEntry(this.name, this.type, this.left, this.right, this.child,
      this.start, this.size);
}

/// FAT 与 MiniFAT 独立跟踪占用，防止循环、跨流共享和超长链。
class _CompoundFile {
  static const int _free = 0xffffffff;
  static const int _end = 0xfffffffe;
  static const int _fatSector = 0xfffffffd;
  static const int _difSector = 0xfffffffc;
  final _Bytes _file;
  late final int _sectorSize;
  late final int _sectorCount;
  final List<int> _fat = [];
  final List<int> _miniFat = [];
  final Set<int> _claimed = {};
  final Set<int> _miniClaimed = {};
  final Map<String, _DirectoryEntry> _rootStreams = {};
  Uint8List _miniStream = Uint8List(0);

  _CompoundFile(Uint8List bytes) : _file = _Bytes(bytes, 'CFB') {
    _file.need(0, 512);
    const signature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) _bad('文件不是有效的 DOC/XLS CFB 容器');
    }
    final major = _file.u16(26);
    if (major != 3 && major != 4) _bad('不支持的 CFB 版本：$major');
    if (_file.u16(28) != 0xfffe ||
        _file.u16(30) != (major == 3 ? 9 : 12) ||
        _file.u16(32) != 6 ||
        _file.u32(56) != 4096 ||
        (major == 3 && _file.u32(40) != 0)) {
      _bad('CFB 头部或扇区配置无效');
    }
    for (var i = 8; i < 24; i++) {
      if (bytes[i] != 0) _bad('CFB 保留头部无效');
    }
    for (var i = 34; i < 40; i++) {
      if (bytes[i] != 0) _bad('CFB 保留头部无效');
    }
    _sectorSize = 1 << _file.u16(30);
    if (bytes.length % _sectorSize != 0 || bytes.length < _sectorSize * 2) {
      _bad('CFB 扇区数据截断');
    }
    if (major == 4) {
      for (var i = 512; i < _sectorSize; i++) {
        if (bytes[i] != 0) _bad('CFB v4 头部填充无效');
      }
    }
    _sectorCount = bytes.length ~/ _sectorSize - 1;
    final fatCount = _file.u32(44);
    final difCount = _file.u32(72);
    if (fatCount < 1 || fatCount > _sectorCount || difCount > _sectorCount) {
      _bad('CFB FAT/DIFAT 数量无效');
    }
    final fatIds = <int>[];
    void addFat(int id) {
      if (id == _free) return;
      _claim(id, 'FAT');
      fatIds.add(id);
      if (fatIds.length > fatCount) _bad('CFB FAT 数量不匹配');
    }

    for (var i = 0; i < 109; i++) {
      addFat(_file.u32(76 + 4 * i));
    }
    final difIds = <int>[];
    var dif = _file.u32(68);
    for (var i = 0; i < difCount; i++) {
      _claim(dif, 'DIFAT');
      difIds.add(dif);
      final sector = _sector(dif);
      for (var j = 0; j < _sectorSize ~/ 4 - 1; j++) {
        addFat(sector.u32(j * 4));
      }
      dif = sector.u32(_sectorSize - 4);
    }
    if (dif != _end || fatIds.length != fatCount) {
      _bad('CFB DIFAT 链或 FAT 数量无效');
    }
    for (final id in fatIds) {
      final sector = _sector(id);
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        final next = sector.u32(i * 4);
        // 不按攻击者声明的 FAT 容量分配；实际文件之外的项必须为空。
        if (_fat.length < _sectorCount) {
          _fat.add(next);
        } else if (next != _free) {
          _bad('CFB FAT 指向文件之外');
        }
      }
    }
    if (_fat.length < _sectorCount) _bad('CFB FAT 未覆盖文件扇区');
    for (var i = 0; i < _fat.length; i++) {
      final next = _fat[i];
      if (i >= _sectorCount) {
        if (next != _free) _bad('CFB FAT 指向文件之外');
      } else if (next < _difSector && next >= _sectorCount) {
        _bad('CFB FAT 扇区编号无效');
      }
    }
    for (final id in fatIds) {
      if (_fat[id] != _fatSector) _bad('CFB FAT 扇区标记无效');
    }
    for (final id in difIds) {
      if (_fat[id] != _difSector) _bad('CFB DIFAT 扇区标记无效');
    }
    final directoryChain = _chain(_file.u32(48), null, '目录');
    if (directoryChain.length * _sectorSize > 16384 * 128) {
      _bad('CFB 目录超过 16384 个对象解析上限');
    }
    if (directoryChain.isEmpty ||
        (major == 4 && directoryChain.length != _file.u32(40))) {
      _bad('CFB 目录链无效');
    }
    final directory = _Bytes(_join(directoryChain), 'CFB 目录');
    final entries = <_DirectoryEntry>[];
    for (var offset = 0; offset < directory.bytes.length; offset += 128) {
      final type = directory.u8(offset + 66);
      if (type == 0) {
        entries.add(_DirectoryEntry('', 0, _free, _free, _free, _end, 0));
        continue;
      }
      if (type != 1 && type != 2 && type != 5) _bad('CFB 目录对象类型无效');
      final nameBytes = directory.u16(offset + 64);
      if (nameBytes < 2 ||
          nameBytes > 64 ||
          nameBytes.isOdd ||
          directory.u16(offset + nameBytes - 2) != 0) {
        _bad('CFB 目录名称无效');
      }
      final name = _utf16(directory, offset, nameBytes ~/ 2 - 1, 'CFB 目录');
      if (name.isEmpty || name.contains('\u0000')) _bad('CFB 目录名称无效');
      final highSize = directory.u32(offset + 124);
      if (highSize != 0) _bad('CFB 流超过解析大小上限');
      final size = directory.u32(offset + 120);
      if (size > _file.bytes.length) _bad('CFB 流大小超过文件长度');
      entries.add(_DirectoryEntry(
          name,
          type,
          directory.u32(offset + 68),
          directory.u32(offset + 72),
          directory.u32(offset + 76),
          directory.u32(offset + 116),
          size));
    }
    if (entries.first.type != 5 ||
        entries.first.left != _free ||
        entries.first.right != _free) {
      _bad('CFB 根目录无效');
    }
    final root = entries.first;
    final visited = <int>{0};
    final pending = <(int, int)>[(root.child, 0)];
    final names = <int, Set<String>>{};
    while (pending.isNotEmpty) {
      final (id, parent) = pending.removeLast();
      if (id == _free) continue;
      if (id <= 0 || id >= entries.length || !visited.add(id)) {
        _bad('CFB 目录含循环或无效对象引用');
      }
      final entry = entries[id];
      if (entry.type == 0 || entry.type == 5) _bad('CFB 目录引用无效对象');
      final key = entry.name.toLowerCase();
      if (!(names[parent] ??= {}).add(key)) _bad('CFB 目录名称重复');
      pending.add((entry.left, parent));
      pending.add((entry.right, parent));
      if (entry.type == 1) {
        pending.add((entry.child, id));
      } else {
        if (entry.child != _free) _bad('CFB 流对象含子目录');
        if (parent == 0) _rootStreams[key] = entry;
      }
    }
    for (var i = 1; i < entries.length; i++) {
      if (entries[i].type != 0 && !visited.contains(i)) {
        _bad('CFB 存在未连接的目录对象');
      }
    }
    root.chain = _chain(
        root.start, (root.size + _sectorSize - 1) ~/ _sectorSize, 'MiniStream');
    _miniStream = _join(root.chain, root.size);
    if (root.size % 64 != 0) _bad('CFB MiniStream 长度无效');
    final miniCount = _file.u32(64);
    if (miniCount > _sectorCount) _bad('CFB MiniFAT 数量无效');
    final miniChain = _chain(_file.u32(60), miniCount, 'MiniFAT');
    for (final id in miniChain) {
      final sector = _sector(id);
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        final next = sector.u32(i * 4);
        if (_miniFat.length < root.size ~/ 64) {
          _miniFat.add(next);
        } else if (next != _free) {
          _bad('CFB MiniFAT 指向 MiniStream 之外');
        }
      }
    }
    for (final entry in entries.skip(1)) {
      if (entry.type != 2) continue;
      entry.chain = entry.size < 4096
          ? _miniChain(entry.start, (entry.size + 63) ~/ 64)
          : _chain(entry.start, (entry.size + _sectorSize - 1) ~/ _sectorSize,
              '流 ${entry.name}');
    }
  }

  void _claim(int id, String context) {
    if (id < 0 || id >= _sectorCount) _bad('CFB $context 扇区越界或链截断');
    if (!_claimed.add(id)) _bad('CFB $context 含循环或重复占用扇区');
  }

  _Bytes _sector(int id) {
    if (id < 0 || id >= _sectorCount) _bad('CFB 扇区越界');
    return _Bytes(_file.slice((id + 1) * _sectorSize, _sectorSize), 'CFB 扇区');
  }

  List<int> _chain(int start, int? count, String context) {
    final result = <int>[];
    var id = start;
    while (id != _end) {
      _claim(id, context);
      result.add(id);
      if ((count != null && result.length > count) ||
          result.length > _sectorCount) {
        _bad('CFB $context 链长度无效');
      }
      id = _fat[id];
    }
    if (count != null && result.length != count) _bad('CFB $context 链截断');
    return result;
  }

  List<int> _miniChain(int start, int count) {
    final result = <int>[];
    var id = start;
    while (id != _end) {
      if (id < 0 ||
          id >= _miniFat.length ||
          (id + 1) * 64 > _miniStream.length) {
        _bad('CFB MiniFAT 扇区越界或链截断');
      }
      if (!_miniClaimed.add(id)) _bad('CFB MiniFAT 含循环或重复占用扇区');
      result.add(id);
      if (result.length > count) _bad('CFB MiniFAT 链长度无效');
      id = _miniFat[id];
    }
    if (result.length != count) _bad('CFB MiniFAT 链截断');
    return result;
  }

  Uint8List _join(List<int> chain, [int? size]) {
    final result = Uint8List(size ?? chain.length * _sectorSize);
    for (var i = 0; i < chain.length; i++) {
      final offset = i * _sectorSize;
      final length = math.min(_sectorSize, result.length - offset);
      result.setRange(
          offset, offset + length, _file.bytes, (chain[i] + 1) * _sectorSize);
    }
    return result;
  }

  bool hasRootStream(String name) =>
      _rootStreams.containsKey(name.toLowerCase());

  Uint8List stream(String name) {
    final entry = _rootStreams[name.toLowerCase()];
    if (entry == null) _bad('CFB 缺少必需的 $name 流');
    if (entry.size >= 4096) return _join(entry.chain, entry.size);
    final result = Uint8List(entry.size);
    for (var i = 0; i < entry.chain.length; i++) {
      final offset = i * 64;
      final length = math.min(64, result.length - offset);
      result.setRange(
          offset, offset + length, _miniStream, entry.chain[i] * 64);
    }
    return result;
  }
}

class _WordText {
  static const _compressedMap = <int, int>{
    0x82: 0x201a,
    0x83: 0x192,
    0x84: 0x201e,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x2c6,
    0x89: 0x2030,
    0x8a: 0x160,
    0x8b: 0x2039,
    0x8c: 0x152,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201c,
    0x94: 0x201d,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x2dc,
    0x99: 0x2122,
    0x9a: 0x161,
    0x9b: 0x203a,
    0x9c: 0x153,
    0x9f: 0x178,
  };

  static String read(_CompoundFile cfb, int maxCharacters) {
    final word = _Bytes(cfb.stream('WordDocument'), 'DOC WordDocument');
    word.need(0, 34);
    if (word.u16(0) != 0xa5ec) _bad('DOC WordDocument 标识无效');
    final flags = word.u16(10);
    if ((flags & 0x100) != 0) _bad('不支持加密或混淆的 DOC 文件');
    var version = word.u16(2);
    final csw = word.u16(32);
    if (csw != 14) _bad('不支持的 DOC FIB 结构');
    final lwHeader = 34 + csw * 2;
    final cslw = word.u16(lwHeader);
    if (cslw != 22) _bad('不支持的 DOC FIB 长字结构');
    final lw = lwHeader + 2;
    final bodyLength = word.u32(lw + 12);
    if (bodyLength > 4 * 1024 * 1024) _bad('DOC 正文超过解析上限');
    final pairsHeader = lw + cslw * 4;
    final pairCount = word.u16(pairsHeader);
    if (pairCount < 93 || pairCount > 183) _bad('不支持的 DOC FIB 偏移表');
    final pairs = pairsHeader + 2;
    word.need(pairs, pairCount * 8 + 2);
    final newHeader = pairs + pairCount * 8;
    final newWords = word.u16(newHeader);
    if (newWords > 0) {
      word.need(newHeader + 2, newWords * 2);
      version = word.u16(newHeader + 2);
    }
    if (!const [0xc1, 0xd9, 0x101, 0x10c].contains(version)) {
      _bad('仅支持 Word 97–2003 DOC，文件版本为 0x${version.toRadixString(16)}');
    }
    final expectedPairs = {0xc1: 93, 0xd9: 108, 0x101: 136, 0x10c: 164};
    if (pairCount != expectedPairs[version]) _bad('DOC 版本与 FIB 偏移表不匹配');
    if (newWords != (version == 0xc1 ? 0 : 2)) {
      _bad('DOC 版本与 FIB 扩展不匹配');
    }
    final fibEnd = newHeader + 2 + newWords * 2;
    var totalCharacters = bodyLength;
    var otherStory = false;
    for (final field in [4, 5, 7, 8, 9, 10]) {
      final length = word.u32(lw + field * 4);
      if (length != 0) otherStory = true;
      totalCharacters += length;
    }
    if (otherStory) totalCharacters++;
    if (totalCharacters > 16 * 1024 * 1024) _bad('DOC 总字符数超过解析上限');
    final tableName = (flags & 0x200) != 0 ? '1Table' : '0Table';
    final table = _Bytes(cfb.stream(tableName), 'DOC $tableName');
    final clxOffset = word.u32(pairs + 33 * 8);
    final clxLength = word.u32(pairs + 33 * 8 + 4);
    if (clxLength == 0) _bad('DOC 缺少正文 piece table');
    final clx = _Bytes(table.slice(clxOffset, clxLength), 'DOC CLX');
    var cursor = 0;
    while (cursor < clxLength && clx.u8(cursor) == 1) {
      final length = clx.u16(cursor + 1);
      clx.need(cursor + 3, length);
      cursor += length + 3;
    }
    if (cursor >= clxLength || clx.u8(cursor) != 2) _bad('DOC piece table 无效');
    final plcLength = clx.u32(cursor + 1);
    if (plcLength < 4 ||
        (plcLength - 4) % 12 != 0 ||
        cursor + 5 + plcLength != clxLength) {
      _bad('DOC piece table 长度无效');
    }
    final plc = _Bytes(clx.slice(cursor + 5, plcLength), 'DOC piece table');
    final count = (plcLength - 4) ~/ 12;
    if (count > 300000 || plc.u32(0) != 0) _bad('DOC piece table 字符索引无效');
    final units = <int>[];
    for (var i = 0; i < count; i++) {
      final start = plc.u32(i * 4);
      final end = plc.u32((i + 1) * 4);
      if (end <= start || end > 16 * 1024 * 1024) _bad('DOC piece 字符范围无效');
      final encoded = plc.u32((count + 1) * 4 + i * 8 + 2);
      if ((encoded & 0x80000000) != 0) _bad('DOC piece 文件偏移无效');
      final compressed = (encoded & 0x40000000) != 0;
      final fc = encoded & 0x3fffffff;
      if (compressed && fc.isOdd) _bad('DOC 压缩 piece 偏移无效');
      final offset = compressed ? fc ~/ 2 : fc;
      if (offset < fibEnd) _bad('DOC piece 文本指向 FIB 元数据');
      word.need(offset, (end - start) * (compressed ? 1 : 2));
      final take = math.max(0, math.min(end, bodyLength) - start);
      for (var j = 0; j < take; j++) {
        final unit =
            compressed ? word.u8(offset + j) : word.u16(offset + j * 2);
        units.add(compressed ? (_compressedMap[unit] ?? unit) : unit);
      }
    }
    if (plc.u32(count * 4) != totalCharacters || units.length != bodyLength) {
      _bad('DOC piece table 未覆盖正文');
    }
    _unicode(units, 'DOC 正文');
    final output = _TextLimit(maxCharacters);
    final fields = <bool>[];
    var hiddenFields = 0;
    for (final unit in units) {
      if (unit == 0x13) {
        if (fields.length >= 64) _bad('DOC 字段嵌套超过解析上限');
        fields.add(false);
        hiddenFields++;
      } else if (unit == 0x14) {
        if (fields.isEmpty || fields.last) _bad('DOC 字段分隔符无效');
        fields[fields.length - 1] = true;
        hiddenFields--;
      } else if (unit == 0x15) {
        if (fields.isEmpty) _bad('DOC 字段结束符无效');
        if (!fields.removeLast()) hiddenFields--;
      } else if (hiddenFields == 0) {
        if (unit == 0x0d || unit == 0x0b || unit == 0x0c) {
          output.add('\n');
        } else if (unit == 0x07) {
          output.add('\t');
        } else if (unit == 0x1e) {
          output.add('\u2011');
        } else if (unit == 9 || unit >= 0x20) {
          output.add(String.fromCharCode(unit));
        }
      }
    }
    if (fields.isNotEmpty) _bad('DOC 字段数据截断');
    return output.toString().trim();
  }
}

class _BiffRecord {
  final int offset;
  final int type;
  final _Bytes data;

  _BiffRecord(this.offset, this.type, this.data);
}

/// SST/STRING 的字符续记录会有新的宽字符标记；格式/拼音数据续记录没有标记。
class _BiffStrings {
  final List<_Bytes> parts;
  int part = 0;
  int offset = 0;
  int characters = 0;

  _BiffStrings(this.parts);

  void _advance() {
    if (++part >= parts.length) _bad('XLS 字符串续记录截断');
    offset = 0;
  }

  void _fixed(int length) {
    if (offset == parts[part].bytes.length) _advance();
    parts[part].need(offset, length);
  }

  int u8() {
    _fixed(1);
    return parts[part].u8(offset++);
  }

  int u16() {
    _fixed(2);
    final result = parts[part].u16(offset);
    offset += 2;
    return result;
  }

  int u32() {
    _fixed(4);
    final result = parts[part].u32(offset);
    offset += 4;
    return result;
  }

  void skip(int count) {
    while (count > 0) {
      if (offset == parts[part].bytes.length) _advance();
      final take = math.min(count, parts[part].bytes.length - offset);
      offset += take;
      count -= take;
    }
  }

  String string({bool rich = true}) {
    _fixed(3);
    final count = u16();
    final flags = u8();
    if ((flags & (rich ? 0xf2 : 0xfe)) != 0 || count > 32767) {
      _bad('XLS 字符串标记或字符数无效');
    }
    // 长度/flags/cRun/cbExtRst 是不可跨记录的固定头部。
    parts[part]
        .need(offset, ((flags & 8) != 0 ? 2 : 0) + ((flags & 4) != 0 ? 4 : 0));
    final runs = (flags & 8) != 0 ? u16() : 0;
    final extension = (flags & 4) != 0 ? u32() : 0;
    if (extension > 16 * 1024 * 1024) _bad('XLS 字符串附加数据超过解析上限');
    characters += count;
    if (characters > 4 * 1024 * 1024) _bad('XLS 共享字符串超过解析上限');
    var wide = (flags & 1) != 0;
    final units = <int>[];
    for (var i = 0; i < count; i++) {
      if (offset == parts[part].bytes.length) {
        _advance();
        final continuationFlags = u8();
        if (continuationFlags > 1) _bad('XLS CONTINUE 字符标记无效');
        wide = continuationFlags == 1;
      }
      parts[part].need(offset, wide ? 2 : 1);
      units.add(wide ? parts[part].u16(offset) : parts[part].u8(offset));
      offset += wide ? 2 : 1;
    }
    skip(runs * 4 + extension);
    return _unicode(units, 'XLS');
  }

  bool get atEnd =>
      part == parts.length - 1 && offset == parts.last.bytes.length;
}

class _Sheet {
  final int offset;
  final int type;
  final String name;
  _Sheet(this.offset, this.type, this.name);
}

class _WorkbookText {
  static String read(_CompoundFile cfb, int maxCharacters) {
    final name = cfb.hasRootStream('Workbook') ? 'Workbook' : 'Book';
    final workbook = _Bytes(cfb.stream(name), 'XLS Workbook');
    final records = <_BiffRecord>[];
    final indices = <int, int>{};
    var cursor = 0;
    while (cursor < workbook.bytes.length) {
      // 正常 BIFF 流末尾可能带零填充，但它不属于任何子流。
      if (workbook.u8(cursor) == 0 &&
          workbook.bytes.length - cursor >= 4 &&
          workbook.u32(cursor) == 0) {
        for (var i = cursor; i < workbook.bytes.length; i++) {
          if (workbook.bytes[i] != 0) _bad('XLS BIFF 尾部数据无效');
        }
        break;
      }
      final type = workbook.u16(cursor);
      final length = workbook.u16(cursor + 2);
      if (length > 8224) _bad('XLS BIFF 记录超过 8224 字节');
      indices[cursor] = records.length;
      records.add(_BiffRecord(
          cursor,
          type,
          _Bytes(workbook.slice(cursor + 4, length),
              'XLS BIFF 0x${type.toRadixString(16)}')));
      if (records.length > 300000) _bad('XLS BIFF 记录超过解析上限');
      if (type == 0x2f) _bad('不支持加密或混淆的 XLS 文件');
      cursor += length + 4;
    }
    if (records.isEmpty) _bad('XLS Workbook 为空');
    _bof(records.first, 5);
    final sheets = <_Sheet>[];
    var strings = <String>[];
    var hadSst = false;
    var globalsEnd = -1;
    for (var i = 1; i < records.length; i++) {
      final record = records[i];
      if (record.type == 0x0a) {
        if (record.data.bytes.isNotEmpty) _bad('XLS EOF 长度无效');
        globalsEnd = i;
        break;
      }
      if (record.type == 0x809) _bad('XLS globals 子流未结束');
      if (record.type == 0x85) {
        final data = record.data;
        data.need(0, 8);
        final count = data.u8(6);
        final flags = data.u8(7);
        if (count == 0 || count > 31 || flags > 1 || (data.u8(4) & 3) == 3) {
          _bad('XLS 工作表名称或状态无效');
        }
        final text = flags == 1
            ? _utf16(data, 8, count, 'XLS 工作表名')
            : String.fromCharCodes(data.slice(8, count));
        if (data.bytes.length != 8 + count * (flags + 1) ||
            RegExp(r'[\x00\x03:\\*?/\[\]]').hasMatch(text) ||
            text.startsWith("'") ||
            text.endsWith("'")) {
          _bad('XLS 工作表名称无效');
        }
        if (sheets.any((s) =>
            s.name.toLowerCase() == text.toLowerCase() ||
            s.offset == data.u32(0))) {
          _bad('XLS 工作表名称或偏移重复');
        }
        final type = data.u8(5);
        if (!const [0, 1, 2, 6].contains(type)) _bad('XLS 工作表类型无效');
        sheets.add(_Sheet(data.u32(0), type, text));
        if (sheets.length > 4096) _bad('XLS 工作表数超过解析上限');
      } else if (record.type == 0xfc) {
        if (hadSst) _bad('XLS 共享字符串表重复');
        hadSst = true;
        final parts = <_Bytes>[record.data];
        while (i + 1 < records.length && records[i + 1].type == 0x3c) {
          parts.add(records[++i].data);
        }
        final reader = _BiffStrings(parts);
        final total = reader.u32();
        final unique = reader.u32();
        if (total > 0x7fffffff || unique > total || unique > 200000) {
          _bad('XLS 共享字符串数量无效或超过解析上限');
        }
        strings = List<String>.generate(unique, (_) => reader.string());
        if (!reader.atEnd) _bad('XLS 共享字符串表尾部无效');
      }
    }
    if (globalsEnd < 0 || sheets.isEmpty) _bad('XLS 缺少工作表或 globals EOF');
    final output = _TextLimit(maxCharacters);
    final substreams = <int>{};
    var cellCount = 0;
    var sheetNumber = 0;
    for (final sheet in sheets) {
      final start = indices[sheet.offset];
      if (start == null || start <= globalsEnd) _bad('XLS 工作表偏移无效');
      final bof = records[start];
      _bof(
          bof,
          sheet.type == 2
              ? 0x20
              : sheet.type == 1
                  ? 0x40
                  : sheet.type == 6
                      ? 6
                      : 0x10);
      output.add('${sheetNumber++ == 0 ? '' : '\n'}[工作表：${sheet.name}]\n');
      final cells = <int, String>{};
      int? pendingString;
      var depth = 1;
      var ended = false;
      void cell(_Bytes data, String value, {int? column}) {
        final row = data.u16(0);
        final col = column ?? data.u16(2);
        if (col > 255) _bad('XLS 单元格列越界');
        final key = row * 256 + col;
        if (cells.containsKey(key)) _bad('XLS 单元格记录重复');
        cells[key] = value;
        if (++cellCount > 200000) _bad('XLS 单元格数超过解析上限');
      }

      for (var i = start; i < records.length; i++) {
        if (!substreams.add(i)) _bad('XLS 工作表子流重叠');
        final record = records[i];
        if (i == start) continue;
        if (record.type == 0x809) {
          if (++depth > 32) _bad('XLS 嵌套子流超过解析上限');
          continue;
        }
        if (record.type == 0x0a) {
          if (record.data.bytes.isNotEmpty) _bad('XLS EOF 长度无效');
          if (--depth == 0) {
            ended = true;
            break;
          }
          continue;
        }
        if (depth != 1 || sheet.type != 0) continue;
        if (pendingString != null &&
            record.type != 0x207 &&
            !const [0x4bc, 0x221, 0x236, 0x37].contains(record.type)) {
          _bad('XLS 公式缓存字符串缺失');
        }
        final data = record.data;
        switch (record.type) {
          case 0xfd: // LabelSst
            if (data.bytes.length != 10) _bad('XLS LabelSst 长度无效');
            final index = data.u32(6);
            if (index >= strings.length) _bad('XLS 共享字符串索引越界');
            cell(data, strings[index]);
          case 0x203: // Number
            if (data.bytes.length != 14) _bad('XLS Number 长度无效');
            cell(data, _number(data.f64(6)));
          case 0x27e: // RK
            if (data.bytes.length != 10) _bad('XLS RK 长度无效');
            cell(data, _rk(data.u32(6)));
          case 0xbd: // MulRK
            if (data.bytes.length < 12 || (data.bytes.length - 6) % 6 != 0) {
              _bad('XLS MulRK 长度无效');
            }
            final first = data.u16(2);
            final last = data.u16(data.bytes.length - 2);
            final count = (data.bytes.length - 6) ~/ 6;
            if (last > 255 || last - first + 1 != count) {
              _bad('XLS MulRK 列范围无效');
            }
            for (var j = 0; j < count; j++) {
              cell(data, _rk(data.u32(6 + j * 6)), column: first + j);
            }
          case 0x205: // BoolErr
            if (data.bytes.length != 8 || data.u8(7) > 1) {
              _bad('XLS BoolErr 无效');
            }
            cell(data,
                data.u8(7) == 1 ? _error(data.u8(6)) : _boolean(data.u8(6)));
          case 0x204: // BIFF8 Label（旧式字符串记录）
            data.need(0, 9);
            final parts = <_Bytes>[
              _Bytes(data.slice(6, data.bytes.length - 6), 'XLS Label')
            ];
            while (i + 1 < records.length && records[i + 1].type == 0x3c) {
              if (!substreams.add(i + 1)) _bad('XLS 字符串子流重叠');
              parts.add(records[++i].data);
            }
            final reader = _BiffStrings(parts);
            cell(data, reader.string(rich: false));
            if (!reader.atEnd) _bad('XLS Label 尾部无效');
          case 6: // Formula；永远不执行表达式。
            data.need(0, 22);
            final tokenLength = data.u16(20);
            if (data.bytes.length < 22 + tokenLength) _bad('XLS 公式记录截断');
            if (data.u16(12) != 0xffff) {
              cell(data, _number(data.f64(6)));
            } else {
              switch (data.u8(6)) {
                case 0:
                  cell(data, '');
                  pendingString = data.u16(0) * 256 + data.u16(2);
                case 1:
                  cell(data, _boolean(data.u8(8)));
                case 2:
                  cell(data, _error(data.u8(8)));
                case 3:
                  cell(data, '');
                default:
                  _bad('XLS 公式缓存类型无效');
              }
            }
          case 0x207: // String：紧跟公式的缓存字符串。
            if (pendingString == null) _bad('XLS 缓存字符串没有对应公式');
            final parts = <_Bytes>[data];
            while (i + 1 < records.length && records[i + 1].type == 0x3c) {
              if (!substreams.add(i + 1)) _bad('XLS 字符串子流重叠');
              parts.add(records[++i].data);
            }
            final reader = _BiffStrings(parts);
            cells[pendingString] = reader.string(rich: false);
            pendingString = null;
            if (!reader.atEnd) _bad('XLS 缓存字符串尾部无效');
        }
      }
      if (!ended || pendingString != null) _bad('XLS 工作表或公式缓存截断');
      final ordered = cells.keys.toList()..sort();
      for (final key in ordered) {
        output.add('${_column(key % 256)}${key ~/ 256 + 1}: ${cells[key]}\n');
      }
      if (sheet.type != 0) output.add('（此类型工作表不含可提取的单元格正文）\n');
    }
    for (var i = globalsEnd + 1; i < records.length; i++) {
      if (!substreams.contains(i)) _bad('XLS 存在未关联的工作表记录');
    }
    return output.toString().trim();
  }

  static void _bof(_BiffRecord record, int type) {
    if (record.type != 0x809 ||
        record.data.bytes.length != 16 ||
        record.data.u16(0) != 0x600) {
      _bad('仅支持 Excel BIFF8 XLS 文件');
    }
    if (record.data.u16(2) != type) _bad('XLS BOF 工作簿/工作表类型无效');
  }

  static String _number(double value) => value == value.truncateToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  static String _rk(int encoded) {
    double value;
    if ((encoded & 2) != 0) {
      final signed = encoded >= 0x80000000 ? encoded - 0x100000000 : encoded;
      value = (signed >> 2).toDouble();
    } else {
      final data = ByteData(8)
        ..setUint32(4, encoded & 0xfffffffc, Endian.little);
      value = data.getFloat64(0, Endian.little);
      if (!value.isFinite) _bad('XLS RK 数值无效');
    }
    return _number((encoded & 1) != 0 ? value / 100 : value);
  }

  static String _boolean(int value) {
    if (value > 1) _bad('XLS 布尔值无效');
    return value == 1 ? 'TRUE' : 'FALSE';
  }

  static String _error(int value) {
    final result = const {
      0: '#NULL!',
      7: '#DIV/0!',
      15: '#VALUE!',
      23: '#REF!',
      29: '#NAME?',
      36: '#NUM!',
      42: '#N/A',
      43: '#GETTING_DATA'
    }[value];
    if (result == null) _bad('XLS 错误缓存值无效');
    return result;
  }

  static String _column(int value) {
    var col = value + 1;
    var result = '';
    while (col > 0) {
      result = String.fromCharCode(65 + (col - 1) % 26) + result;
      col = (col - 1) ~/ 26;
    }
    return result;
  }
}
