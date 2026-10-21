import 'package:chatgpt_app_core/platform/picked_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('浏览器选中文件检查声明和实际字节，保留二进制内容', () async {
    expect(
        await readBrowserPickedBytes(
            4,
            Stream.fromIterable([
              [0, 255],
              [1, 2]
            ])),
        [0, 255, 1, 2]);
    await expectLater(
        readBrowserPickedBytes(5, Stream.value([1, 2])), throwsFormatException);
    await expectLater(
        readBrowserPickedBytes(1, Stream.value([1, 2])), throwsFormatException);
  });
  test('超预算元数据不会订阅文件流，实际超限即停止消费', () async {
    var chunks = 0;
    Stream<List<int>> input() async* {
      chunks++;
      yield [1, 2, 3];
      chunks++;
      yield [4, 5, 6];
      chunks++;
      yield [7];
    }

    await expectLater(
        readBrowserPickedBytes(5, input(), maxBytes: 4), throwsFormatException);
    expect(chunks, 0);
    await expectLater(
        readBrowserPickedBytes(4, input(), maxBytes: 4), throwsFormatException);
    expect(chunks, 2);
  });
}
