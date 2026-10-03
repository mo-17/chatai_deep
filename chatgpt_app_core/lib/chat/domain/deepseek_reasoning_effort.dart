/// DeepSeek 双模式模型的推理等级；null 由调用方表示跟随服务端默认。
enum DeepSeekReasoningEffort {
  off,
  low,
  high,
  max;

  String get wireValue => name;

  String get label => switch (this) {
        off => '关闭',
        low => '低',
        high => '高',
        max => '最高',
      };

  /// 旧配置、导入配置中的未知值保持服务端默认，不猜测其他服务商的等级。
  static DeepSeekReasoningEffort? parse(Object? value) {
    if (value is! String) return null;
    for (final effort in values) {
      if (effort.wireValue == value) return effort;
    }
    return null;
  }
}
