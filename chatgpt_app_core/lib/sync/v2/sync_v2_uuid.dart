import 'dart:math';

import 'package:chatgpt_app_core/util/uuid_v4.dart';

typedef SyncV2UuidGenerator = String Function();

/// Sync v2 使用的稳定身份必须是 RFC 4122 UUID v4。
class SyncV2Uuid {
  SyncV2Uuid._();

  static final RegExp _pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static String generate({Random? random}) => generateUuidV4(random: random);

  static bool isValid(Object? value) =>
      value is String && _pattern.hasMatch(value);

  static String require(Object? value, String field) {
    if (!isValid(value)) {
      throw FormatException('$field 必须是 UUID v4');
    }
    return value as String;
  }
}
