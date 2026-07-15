import 'dart:math';

import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generateUuidV4 生成小写 RFC 4122 v4 UUID', () {
    final first = generateUuidV4(random: Random(42));
    final second = generateUuidV4(random: Random(42));

    expect(first, second);
    expect(
      first,
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      )),
    );
  });
}
