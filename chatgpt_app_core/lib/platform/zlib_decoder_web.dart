import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive;

class ZLibDecoder {
  const ZLibDecoder({this.raw = false});
  final bool raw;
  ByteConversionSink startChunkedConversion(Sink<List<int>> output) =>
      _InflateSink(output, raw);
  Uint8List convert(List<int> bytes) {
    final result = _ResultSink();
    startChunkedConversion(result)
      ..add(bytes)
      ..close();
    return result.bytes.takeBytes();
  }
}

class _InflateSink extends ByteConversionSink {
  _InflateSink(this.output, this.raw);
  final Sink<List<int>> output;
  final bool raw;
  final compressed = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) => compressed.add(chunk);
  @override
  void close() {
    final bytes = compressed.takeBytes();
    List<int> body = bytes;
    if (!raw) {
      if (bytes.length < 6 ||
          (bytes[0] & 15) != 8 ||
          (bytes[0] >> 4) > 7 ||
          ((bytes[0] * 256 + bytes[1]) % 31) != 0 ||
          (bytes[1] & 32) != 0) {
        throw const FormatException('无效的 zlib 头');
      }
      body = bytes.sublist(2, bytes.length - 4);
    }
    final target = _BoundedOutput(output);
    // 必须把调用方的有界 sink 直接接到 Inflate，不能先生成完整解压结果。
    archive.Inflate.stream(archive.InputMemoryStream(body), output: target);
    target.flush();
    if (!raw) {
      final at = bytes.length - 4;
      final expected = bytes[at] * 16777216 +
          bytes[at + 1] * 65536 +
          bytes[at + 2] * 256 +
          bytes[at + 3];
      if (archive.getAdler32(target.history.getBytes()) != expected) {
        throw const FormatException('zlib 校验失败');
      }
    }
    output.close();
  }
}

class _BoundedOutput extends archive.OutputStream {
  _BoundedOutput(this.output)
      : super(byteOrder: archive.ByteOrder.littleEndian);
  final Sink<List<int>> output;
  final history = archive.OutputMemoryStream();
  final _pending = Uint8List(256);
  int _used = 0;
  @override
  int get length => history.length;
  @override
  void writeByte(int value) {
    history.writeByte(value);
    _pending[_used++] = value;
    if (_used == _pending.length) flush();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final chunk = length == null ? bytes : bytes.sublist(0, length);
    // 最多保留 256 字节未核预算的 LZ77 输出，避免逐字节分配无数小数组。
    for (final value in chunk) {
      writeByte(value);
    }
  }

  @override
  void writeStream(archive.InputStream stream) =>
      writeBytes(stream.toUint8List());
  @override
  Uint8List subset(int start, [int? end]) => history.subset(start, end);
  @override
  void clear() {
    history.clear();
    _used = 0;
  }

  @override
  void flush() {
    if (_used == 0) return;
    output.add(Uint8List.fromList(_pending.sublist(0, _used)));
    _used = 0;
  }
}

class _ResultSink implements Sink<List<int>> {
  final bytes = BytesBuilder();
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void close() {}
}
