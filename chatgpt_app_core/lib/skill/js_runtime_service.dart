import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/skill/js_exec_result.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

/// JS 运行时封装（QuickJS via flutter_js）。给技能里的 `scripts/*.js` 提供一个
/// **纯计算沙箱**：无文件系统、无网络、无进程访问，只能做字符串/数据处理。
///
/// 平台支持由 [isSupported] 守卫：Android/iOS/macOS/Windows/Linux 走原生引擎；
/// 鸿蒙（无原生实现，flutter_js 被 override 成本地 stub）与 Web 返回 false，
/// 这两类平台上 [run] 永不被调用（调用方应先判 isSupported）。
class JsRuntimeService {
  const JsRuntimeService();

  /// 当前平台是否能执行 JS 脚本。
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  /// 执行一段脚本。[input] 会以全局变量 `INPUT`（字符串）注入，脚本可读取；
  /// 约定脚本的输出为「最后一个表达式的字符串值」或脚本自行 `JSON.stringify`。
  /// 不抛异常：引擎错误/不支持都包进 [JsExecResult]。
  Future<JsExecResult> run(String code, {String input = ''}) async {
    if (!isSupported) {
      return const JsExecResult.fail('当前平台不支持执行 JS 脚本');
    }
    JavascriptRuntime? rt;
    try {
      rt = getJavascriptRuntime();
      // 注入输入；脚本里可用全局 INPUT 取到原始文本。
      final wrapped = 'var INPUT = ${jsonEncode(input)};\n$code';
      final r = rt.evaluate(wrapped);
      if (r.isError) {
        return JsExecResult.fail('脚本执行出错：${r.stringResult}');
      }
      return JsExecResult.ok(r.stringResult);
    } catch (e) {
      return JsExecResult.fail('脚本执行异常：$e');
    } finally {
      rt?.dispose();
    }
  }
}
