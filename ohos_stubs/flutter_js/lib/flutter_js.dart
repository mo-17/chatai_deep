/// flutter_js 的鸿蒙空实现 stub（同包名、Dart-only）。
/// 只提供 [JsRuntimeService] 用到的符号；方法被调用即抛 [UnsupportedError]。
/// 运行时 JsRuntimeService.isSupported 在 OHOS 返回 false，故这些方法不会被触达。
library flutter_js;

/// 对应真实包的 JsEvalResult（只暴露本项目读取的字段）。
class JsEvalResult {
  final String stringResult;
  final bool isError;

  JsEvalResult(this.stringResult, {this.isError = false});
}

/// 对应真实包的 JavascriptRuntime。
class JavascriptRuntime {
  JsEvalResult evaluate(String code, {String? sourceUrl}) =>
      throw UnsupportedError('flutter_js 在鸿蒙平台不可用');

  void dispose() {}
}

/// 对应真实包的工厂函数。
JavascriptRuntime getJavascriptRuntime({
  bool forceJavascriptCoreOnAndroid = false,
  bool xhr = true,
}) =>
    throw UnsupportedError('flutter_js 在鸿蒙平台不可用');
