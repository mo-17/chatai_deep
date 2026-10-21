import 'js_exec_result.dart';

/// 浏览器不加载 QuickJS/JSC 原生库；保持原有脚本权限边界。
class JsRuntimeService {
  static const defaultTimeout = Duration(seconds: 2);
  static const defaultMaxCodeChars = 128 * 1024;
  static const defaultMaxInputChars = 256 * 1024;
  static const defaultMaxOutputChars = 1024 * 1024;
  static const defaultMemoryLimitBytes = 32 * 1024 * 1024;
  final Duration timeout;
  final int maxCodeChars, maxInputChars, maxOutputChars, memoryLimitBytes;
  const JsRuntimeService({
    this.timeout = defaultTimeout,
    this.maxCodeChars = defaultMaxCodeChars,
    this.maxInputChars = defaultMaxInputChars,
    this.maxOutputChars = defaultMaxOutputChars,
    this.memoryLimitBytes = defaultMemoryLimitBytes,
  });
  static bool get isSupported => false;
  static bool supportsPlatform(
          {required bool isWeb,
          required bool isAndroid,
          required bool isIOS,
          required bool isMacOS,
          required bool isWindows,
          required bool isLinux,
          bool isOhos = false}) =>
      false;
  Future<JsExecResult> run(String code, {String input = ''}) async =>
      const JsExecResult.fail('浏览器不支持原生 JS 技能脚本');
}
