import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/legacy_office_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String extract(Uint8List bytes, String extension, {int limit = 100000}) =>
      LegacyOfficeTextExtractor.extractBytes(bytes,
          extension: extension, maxCharacters: limit);

  test('DOC mini streams combine Unicode and compressed pieces in CP order',
      () {
    final doc =
        _doc(['Hello “', '中文与😀', '”\rNext\x07cell\r'], compressed: {0, 2});
    expect(extract(_cfb(doc), 'doc'), 'Hello “中文与😀”\nNext\tcell');
  });

  test('DOC reads only main story and shows cached field result', () {
    const text = '正文\r\x13HYPERLINK "https://example.invalid"\x14链接\x15\r';
    final doc = _doc([text, '不应读取的页眉\r'], bodyCharacters: text.length);
    expect(extract(_cfb(doc), '.DOC'), '正文\n链接');
  });

  test('DOC follows 1Table and regular sectors in CFB v4', () {
    final doc = _doc(['中英 Word 2003\r'], version: 0x10c, tableOne: true);
    doc['WordDocument'] = _pad(doc['WordDocument']!, 4096);
    doc['1Table'] = _pad(doc['1Table']!, 4096);
    expect(extract(_cfb(doc, major: 4), 'doc'), '中英 Word 2003');
  });

  test('DOC rejects missing CLX, old versions, encryption and invalid UTF16',
      () {
    final absent = _doc(['normal\r']);
    ByteData.sublistView(absent['WordDocument']!)
        .setUint32(422, 0, Endian.little);
    expect(() => extract(_cfb(absent), 'doc'), throwsFormatException);
    final old = _doc(['normal\r']);
    ByteData.sublistView(old['WordDocument']!)
        .setUint16(2, 0x65, Endian.little);
    expect(() => extract(_cfb(old), 'doc'), throwsFormatException);
    final encrypted = _doc(['normal\r']);
    ByteData.sublistView(encrypted['WordDocument']!)
        .setUint16(10, 0x100, Endian.little);
    expect(() => extract(_cfb(encrypted), 'doc'), throwsFormatException);
    final invalid = _doc([String.fromCharCode(0xd800)]);
    expect(() => extract(_cfb(invalid), 'doc'), throwsFormatException);
  });

  test('DOC rejects truncated pieces, malformed fields and oversized output',
      () {
    final doc = _doc(['abc\r']);
    doc['WordDocument'] = Uint8List.sublistView(doc['WordDocument']!, 0, 1026);
    expect(() => extract(_cfb(doc), 'doc'), throwsFormatException);
    expect(() => extract(_cfb(_doc(['\x13unfinished'])), 'doc'),
        throwsFormatException);
    expect(() => extract(_cfb(_doc(['text too long\r'])), 'doc', limit: 3),
        throwsFormatException);
  });

  test('XLS multiple sheets, Unicode SST CONTINUE, rich skips and cells', () {
    final bytes = _cfb({'Workbook': _xls()});
    expect(
        extract(bytes, 'xls'),
        '[工作表：销售]\n'
        'A1: 中文ABC\nB1: 12.5\nC1: TRUE\n'
        'A2: 42\nB2: -1.25\nC2: FALSE\n'
        'A3: 7\nB3: 8\n'
        'A4: 6\nB4: 缓存😀\nC4: #DIV/0!\n'
        '\n[工作表：Sheet2]\nA1: Second');
  });

  test('XLS accepts Book stream and preserves column/row coordinates', () {
    final workbook =
        _xls(extraSheetCell: _record(0x203, _numberCell(65535, 255, 3)));
    final text = extract(_cfb({'Book': _pad(workbook, 4096)}), 'xls');
    expect(text, contains('IV65536: 3'));
  });

  test(
      'XLS rejects unsupported BIFF, encrypted, malformed SST and absent cache',
      () {
    final old = _xls();
    ByteData.sublistView(old).setUint16(4, 0x500, Endian.little);
    expect(
        () => extract(_cfb({'Workbook': old}), 'xls'), throwsFormatException);
    final encrypted = _xls(globalsExtra: _record(0x2f, _u16(0)));
    expect(() => extract(_cfb({'Workbook': encrypted}), 'xls'),
        throwsFormatException);
    expect(
        () => extract(_cfb({'Workbook': _xls(badContinuation: true)}), 'xls'),
        throwsFormatException);
    expect(
        () => extract(_cfb({'Workbook': _xls(omitFormulaString: true)}), 'xls'),
        throwsFormatException);
    expect(() => extract(_cfb({'Workbook': _xls(badSstIndex: true)}), 'xls'),
        throwsFormatException);
    final truncated = _xls();
    expect(
        () => extract(
            _cfb({
              'Workbook':
                  Uint8List.sublistView(truncated, 0, truncated.length - 2)
            }),
            'xls'),
        throwsFormatException);
    expect(() => extract(_cfb({'Workbook': _xls()}), 'xls', limit: 10),
        throwsFormatException);
  });

  test(
      'CFB rejects magic, truncated sectors and excessive declared stream size',
      () {
    final bytes = _cfb(_doc(['abc']));
    final magic = Uint8List.fromList(bytes)..[0] = 0;
    expect(() => extract(magic, 'doc'), throwsFormatException);
    expect(
        () => extract(Uint8List.sublistView(bytes, 0, bytes.length - 1), 'doc'),
        throwsFormatException);
    final data = ByteData.sublistView(bytes);
    final directory = (data.getUint32(48, Endian.little) + 1) * 512;
    data.setUint32(directory + 128 + 120, 0xffffffff, Endian.little);
    expect(() => extract(bytes, 'doc'), throwsFormatException);
  });

  test(
      'CFB rejects FAT and MiniFAT cycles, shared sectors and directory cycles',
      () {
    final streams = _doc(['abc']);
    streams['WordDocument'] = _pad(streams['WordDocument']!, 4096);
    final fatCycle = _cfb(streams);
    final d = ByteData.sublistView(fatCycle);
    final directory = (d.getUint32(48, Endian.little) + 1) * 512;
    final wordStart = d.getUint32(directory + 2 * 128 + 116, Endian.little);
    final fat = (d.getUint32(76, Endian.little) + 1) * 512;
    d.setUint32(fat + wordStart * 4, wordStart, Endian.little);
    expect(() => extract(fatCycle, 'doc'), throwsFormatException);
    final miniCycle = _cfb(_doc(['abc']));
    final m = ByteData.sublistView(miniCycle);
    final mini = (m.getUint32(60, Endian.little) + 1) * 512;
    m.setUint32(mini, 0, Endian.little);
    expect(() => extract(miniCycle, 'doc'), throwsFormatException);
    final shared = _cfb(_doc(['abc']));
    final s = ByteData.sublistView(shared);
    final dir = (s.getUint32(48, Endian.little) + 1) * 512;
    s.setUint32(dir + 2 * 128 + 116,
        s.getUint32(dir + 128 + 116, Endian.little), Endian.little);
    expect(() => extract(shared, 'doc'), throwsFormatException);
    final cycle = _cfb(_doc(['abc']));
    final c = ByteData.sublistView(cycle);
    final dir2 = (c.getUint32(48, Endian.little) + 1) * 512;
    c.setUint32(dir2 + 2 * 128 + 68, 2, Endian.little);
    expect(() => extract(cycle, 'doc'), throwsFormatException);
  });

  test(
      'CFB follows DIFAT beyond the 109 header FAT entries and rejects a cycle',
      () {
    final streams = _doc(['DIFAT 正文\r']);
    streams['WordDocument'] = _pad(streams['WordDocument']!, 8 * 1024 * 1024);
    final bytes = _cfb(streams);
    expect(ByteData.sublistView(bytes).getUint32(72, Endian.little),
        greaterThan(0));
    expect(extract(bytes, 'doc'), 'DIFAT 正文');
    final d = ByteData.sublistView(bytes);
    final difId = d.getUint32(68, Endian.little);
    d.setUint32((difId + 1) * 512 + 508, difId, Endian.little);
    expect(() => extract(bytes, 'doc'), throwsFormatException);
  });
}

Uint8List _u16(int value) =>
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();
Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
Uint8List _join(Iterable<List<int>> parts) =>
    Uint8List.fromList(parts.expand((p) => p).toList());
Uint8List _utf16(String text) => _join(text.codeUnits.map(_u16));
Uint8List _pad(Uint8List bytes, int length) =>
    Uint8List(length)..setRange(0, bytes.length, bytes);

Map<String, Uint8List> _doc(List<String> pieces,
    {Set<int> compressed = const {},
    int? bodyCharacters,
    int version = 0xc1,
    bool tableOne = false}) {
  final pairCount = {0xc1: 93, 0xd9: 108, 0x101: 136, 0x10c: 164}[version]!;
  final fibLength = 156 + pairCount * 8 + (version == 0xc1 ? 0 : 4);
  final textOffset = ((fibLength + 511) ~/ 512) * 512;
  final texts = <Uint8List>[];
  final offsets = <int>[];
  final positions = <int>[0];
  var byteOffset = textOffset;
  for (var i = 0; i < pieces.length; i++) {
    final text = pieces[i];
    final bytes = compressed.contains(i)
        ? Uint8List.fromList(text.codeUnits
            .map((unit) => unit == 0x201c
                ? 0x93
                : unit == 0x201d
                    ? 0x94
                    : unit)
            .toList())
        : _utf16(text);
    offsets
        .add(compressed.contains(i) ? 0x40000000 | byteOffset * 2 : byteOffset);
    texts.add(bytes);
    byteOffset += bytes.length;
    positions.add(positions.last + text.length);
  }
  final word = Uint8List(byteOffset);
  final d = ByteData.sublistView(word);
  d.setUint16(0, 0xa5ec, Endian.little);
  d.setUint16(2, 0xc1, Endian.little);
  d.setUint16(10, tableOne ? 0x1200 : 0x1000, Endian.little);
  d.setUint16(32, 14, Endian.little);
  d.setUint16(62, 22, Endian.little);
  d.setUint32(76, bodyCharacters ?? positions.last, Endian.little);
  if (bodyCharacters != null && positions.last > bodyCharacters) {
    // 非主 story 的总计额外包含一个最终段落标记（MS-DOC PlcPcd）。
    d.setUint32(84, positions.last - bodyCharacters - 1, Endian.little);
  }
  d.setUint16(152, pairCount, Endian.little);
  final newHeader = 154 + pairCount * 8;
  d.setUint16(newHeader, version == 0xc1 ? 0 : 2, Endian.little);
  if (version != 0xc1) d.setUint16(newHeader + 2, version, Endian.little);
  var offset = textOffset;
  for (final text in texts) {
    word.setRange(offset, offset + text.length, text);
    offset += text.length;
  }
  final plc = _join([
    ...positions.map(_u32),
    for (final fc in offsets) _join([_u16(0), _u32(fc), _u16(0)]),
  ]);
  final table = _join([
    <int>[2],
    _u32(plc.length),
    plc
  ]);
  d.setUint32(418, 0, Endian.little);
  d.setUint32(422, table.length, Endian.little);
  return {'WordDocument': word, tableOne ? '1Table' : '0Table': table};
}

Uint8List _record(int type, List<int> data) =>
    _join([_u16(type), _u16(data.length), data]);
Uint8List _bof(int type) => _record(
    0x809,
    _join([
      _u16(0x600),
      _u16(type),
      _u16(0x0dbb),
      _u16(1997),
      _u32(0x41),
      _u32(6)
    ]));
Uint8List _cell(int row, int column) =>
    _join([_u16(row), _u16(column), _u16(0)]);
Uint8List _numberCell(int row, int column, double number) => _join([
      _cell(row, column),
      (ByteData(8)..setFloat64(0, number, Endian.little)).buffer.asUint8List()
    ]);
Uint8List _formula(int row, int column, List<int> cached) => _record(
    6,
    _join([
      _cell(row, column),
      cached,
      _u16(0),
      _u32(0),
      _u16(3),
      <int>[0x1e, 1, 0]
    ]));
Uint8List _string(String text) => _join([
      _u16(text.length),
      <int>[1],
      _utf16(text)
    ]);

Uint8List _xls(
    {Uint8List? globalsExtra,
    Uint8List? extraSheetCell,
    bool badContinuation = false,
    bool omitFormulaString = false,
    bool badSstIndex = false}) {
  // 第一字符串在 Unicode 字符边界断开并转为压缩字符；第二字符串的
  // rich runs 跨 CONTINUE，不带额外字符标记；cbExtRst=0 也是合法扩展。
  final sst = _record(
      0xfc,
      _join([
        _u32(2),
        _u32(2),
        _u16(5),
        <int>[1],
        _utf16('中文')
      ]));
  final continuation = _record(
      0x3c,
      _join([
        <int>[badContinuation ? 2 : 0],
        'ABC'.codeUnits,
        _u16(6),
        <int>[0x0c],
        _u16(2),
        _u32(0),
        'Second'.codeUnits,
        _u16(0),
      ]));
  final continuation2 = _record(
      0x3c,
      _join([
        _u16(0),
        _u16(3),
        _u16(0),
      ]));
  final cachedNumber =
      (ByteData(8)..setFloat64(0, 6, Endian.little)).buffer.asUint8List();
  final sheet1 = _join([
    _bof(0x10),
    _record(0x81, _u16(0)),
    _record(0xfd, _join([_cell(0, 0), _u32(badSstIndex ? 5 : 0)])),
    _record(0x203, _numberCell(0, 1, 12.5)),
    _record(
        0x205,
        _join([
          _cell(0, 2),
          <int>[1, 0]
        ])),
    _record(0x27e, _join([_cell(1, 0), _u32((42 << 2) | 2)])),
    _record(0x27e, _join([_cell(1, 1), _u32((-125 << 2) | 3)])),
    _record(
        0x205,
        _join([
          _cell(1, 2),
          <int>[0, 0]
        ])),
    _record(
        0xbd,
        _join([
          _u16(2),
          _u16(0),
          _u16(0),
          _u32((7 << 2) | 2),
          _u16(0),
          _u32((8 << 2) | 2),
          _u16(1)
        ])),
    _formula(3, 0, cachedNumber),
    _formula(3, 1, <int>[0, 0, 0, 0, 0, 0, 0xff, 0xff]),
    if (!omitFormulaString) _record(0x207, _string('缓存😀')),
    _formula(3, 2, <int>[2, 0, 7, 0, 0, 0, 0xff, 0xff]),
    _record(0x0a, []),
  ]);
  final sheet2 = _join([
    _bof(0x10),
    _record(0x81, _u16(0)),
    _record(0xfd, _join([_cell(0, 0), _u32(1)])),
    if (extraSheetCell != null) extraSheetCell,
    _record(0x0a, [])
  ]);
  Uint8List bound(String name, int offset) => _record(
      0x85,
      _join([
        _u32(offset),
        <int>[0, 0, name.length, 1],
        _utf16(name)
      ]));
  Uint8List globals(int first, int second) => _join([
        _bof(5),
        bound('销售', first),
        bound('Sheet2', second),
        if (globalsExtra != null) globalsExtra,
        sst,
        continuation,
        continuation2,
        _record(0x0a, [])
      ]);
  final length = globals(0, 0).length;
  return _join([globals(length, length + sheet1.length), sheet1, sheet2]);
}

/// 生成包含可验证 FAT/DIFAT/MiniFAT 与真实目录树的 CFB 样本。
/// 小流使用 64-byte mini sectors，4096+ 流使用 regular sectors。
Uint8List _cfb(Map<String, Uint8List> streams, {int major = 3}) {
  const free = 0xffffffff;
  const end = 0xfffffffe;
  final sectorSize = major == 3 ? 512 : 4096;
  final entriesPerFat = sectorSize ~/ 4;
  final names = streams.keys.toList()
    ..sort((a, b) => a.length != b.length
        ? a.length.compareTo(b.length)
        : a.toUpperCase().compareTo(b.toUpperCase()));
  final sectors = <Uint8List>[];
  final fat = <int>[];
  List<int> allocate(Uint8List data) {
    final ids = <int>[];
    for (var offset = 0; offset < data.length; offset += sectorSize) {
      final id = sectors.length;
      ids.add(id);
      sectors.add(Uint8List(sectorSize)
        ..setRange(
            0,
            data.length - offset < sectorSize
                ? data.length - offset
                : sectorSize,
            data,
            offset));
      fat.add(end);
      if (ids.length > 1) fat[ids[ids.length - 2]] = id;
    }
    return ids;
  }

  final miniFat = <int>[];
  final miniParts = <Uint8List>[];
  final starts = <String, int>{};
  for (final name in names) {
    final data = streams[name]!;
    if (data.isEmpty) {
      starts[name] = end;
    } else if (data.length < 4096) {
      starts[name] = miniFat.length;
      final first = miniFat.length;
      for (var offset = 0; offset < data.length; offset += 64) {
        final id = miniFat.length;
        miniFat.add(end);
        if (id > first) miniFat[id - 1] = id;
        miniParts.add(Uint8List(64)
          ..setRange(0, data.length - offset < 64 ? data.length - offset : 64,
              data, offset));
      }
    } else {
      starts[name] = allocate(data).first;
    }
  }
  final miniStream = _join(miniParts);
  final rootChain = allocate(miniStream);
  final miniFatBytes = Uint8List(
      ((miniFat.length + entriesPerFat - 1) ~/ entriesPerFat) * sectorSize);
  miniFatBytes.fillRange(0, miniFatBytes.length, 0xff);
  final mfData = ByteData.sublistView(miniFatBytes);
  for (var i = 0; i < miniFat.length; i++) {
    mfData.setUint32(i * 4, miniFat[i], Endian.little);
  }
  final miniFatChain = allocate(miniFatBytes);
  final directory = Uint8List(
      ((names.length + 1 + sectorSize ~/ 128 - 1) ~/ (sectorSize ~/ 128)) *
          sectorSize);
  final d = ByteData.sublistView(directory);
  void entry(int index, String name, int type, int start, int size) {
    final offset = index * 128;
    final encoded = _utf16('$name\u0000');
    directory.setRange(offset, offset + encoded.length, encoded);
    d.setUint16(offset + 64, encoded.length, Endian.little);
    directory[offset + 66] = type;
    directory[offset + 67] = 1;
    d.setUint32(offset + 68, free, Endian.little);
    d.setUint32(offset + 72, free, Endian.little);
    d.setUint32(offset + 76, free, Endian.little);
    d.setUint32(offset + 116, start, Endian.little);
    d.setUint32(offset + 120, size, Endian.little);
  }

  entry(0, 'Root Entry', 5, rootChain.isEmpty ? end : rootChain.first,
      miniStream.length);
  for (var i = 0; i < names.length; i++) {
    entry(i + 1, names[i], 2, starts[names[i]]!, streams[names[i]]!.length);
  }
  var maxDepth = 0;
  final depths = <int, int>{};
  int tree(int first, int last, int depth) {
    if (first >= last) return free;
    final index = (first + last) ~/ 2;
    depths[index + 1] = depth;
    if (depth > maxDepth) maxDepth = depth;
    d.setUint32(
        (index + 1) * 128 + 68, tree(first, index, depth + 1), Endian.little);
    d.setUint32((index + 1) * 128 + 72, tree(index + 1, last, depth + 1),
        Endian.little);
    return index + 1;
  }

  d.setUint32(76, tree(0, names.length, 0), Endian.little);
  for (final pair in depths.entries) {
    if (pair.value == maxDepth && maxDepth > 0) {
      directory[pair.key * 128 + 67] = 0;
    }
  }
  final directoryChain = allocate(directory);
  final baseCount = sectors.length;
  var fatCount = 1;
  var difCount = 0;
  while (true) {
    final nextFat =
        (baseCount + fatCount + difCount + entriesPerFat - 1) ~/ entriesPerFat;
    final nextDif = nextFat <= 109
        ? 0
        : (nextFat - 109 + entriesPerFat - 2) ~/ (entriesPerFat - 1);
    if (nextFat == fatCount && nextDif == difCount) break;
    fatCount = nextFat;
    difCount = nextDif;
  }
  final fatIds = <int>[];
  for (var i = 0; i < fatCount; i++) {
    fatIds.add(sectors.length);
    sectors.add(Uint8List(sectorSize)..fillRange(0, sectorSize, 0xff));
    fat.add(0xfffffffd);
  }
  final difIds = <int>[];
  for (var i = 0; i < difCount; i++) {
    difIds.add(sectors.length);
    sectors.add(Uint8List(sectorSize)..fillRange(0, sectorSize, 0xff));
    fat.add(0xfffffffc);
  }
  for (var i = 0; i < fat.length; i++) {
    ByteData.sublistView(sectors[fatIds[i ~/ entriesPerFat]])
        .setUint32((i % entriesPerFat) * 4, fat[i], Endian.little);
  }
  for (var i = 0; i < difIds.length; i++) {
    final data = ByteData.sublistView(sectors[difIds[i]]);
    for (var j = 0; j < entriesPerFat - 1; j++) {
      final index = 109 + i * (entriesPerFat - 1) + j;
      if (index < fatIds.length) {
        data.setUint32(j * 4, fatIds[index], Endian.little);
      }
    }
    data.setUint32(sectorSize - 4, i + 1 < difIds.length ? difIds[i + 1] : end,
        Endian.little);
  }
  final header = Uint8List(sectorSize);
  header.setRange(0, 8, <int>[0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);
  final h = ByteData.sublistView(header);
  h.setUint16(24, 0x3e, Endian.little);
  h.setUint16(26, major, Endian.little);
  h.setUint16(28, 0xfffe, Endian.little);
  h.setUint16(30, major == 3 ? 9 : 12, Endian.little);
  h.setUint16(32, 6, Endian.little);
  h.setUint32(40, major == 4 ? directoryChain.length : 0, Endian.little);
  h.setUint32(44, fatCount, Endian.little);
  h.setUint32(48, directoryChain.first, Endian.little);
  h.setUint32(56, 4096, Endian.little);
  h.setUint32(
      60, miniFatChain.isEmpty ? end : miniFatChain.first, Endian.little);
  h.setUint32(64, miniFatChain.length, Endian.little);
  h.setUint32(68, difIds.isEmpty ? end : difIds.first, Endian.little);
  h.setUint32(72, difCount, Endian.little);
  for (var i = 0; i < 109; i++) {
    h.setUint32(
        76 + i * 4, i < fatIds.length ? fatIds[i] : free, Endian.little);
  }
  return _join([header, ...sectors]);
}
