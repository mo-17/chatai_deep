import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:chatgpt_app_core/skill/js_exec_result.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

/// JS 运行时封装（QuickJS via flutter_js）。给技能里的 `scripts/*.js` 提供一个
/// **纯计算沙箱**：无文件系统、无网络、无进程访问，只能做字符串/数据处理。
///
/// 仅启用 flutter_js 的 QuickJS 平台（Android/Windows/Linux），因为它同时提供
/// 原生 timeout 与 heap memoryLimit。Apple 的 JavaScriptCore 没有可用 heap cap，
/// 即使外层 isolate 可超时也无法保证 OOM containment，因此暂时 fail closed。
class JsRuntimeService {
  static const defaultTimeout = Duration(seconds: 2);
  static const defaultMaxCodeChars = 128 * 1024;
  static const defaultMaxInputChars = 256 * 1024;
  static const defaultMaxOutputChars = 1024 * 1024;
  static const defaultMemoryLimitBytes = 32 * 1024 * 1024;

  final Duration timeout;
  final int maxCodeChars;
  final int maxInputChars;
  final int maxOutputChars;
  final int memoryLimitBytes;

  const JsRuntimeService({
    this.timeout = defaultTimeout,
    this.maxCodeChars = defaultMaxCodeChars,
    this.maxInputChars = defaultMaxInputChars,
    this.maxOutputChars = defaultMaxOutputChars,
    this.memoryLimitBytes = defaultMemoryLimitBytes,
  })  : assert(maxCodeChars >= 0),
        assert(maxInputChars >= 0),
        assert(maxOutputChars >= 0),
        assert(memoryLimitBytes > 0);

  /// 当前平台是否能执行 JS 脚本。
  static bool get isSupported {
    return supportsPlatform(
      isWeb: kIsWeb,
      isAndroid: !kIsWeb && Platform.isAndroid,
      isIOS: !kIsWeb && Platform.isIOS,
      isMacOS: !kIsWeb && Platform.isMacOS,
      isWindows: !kIsWeb && Platform.isWindows,
      isLinux: !kIsWeb && Platform.isLinux,
    );
  }

  static bool supportsPlatform({
    required bool isWeb,
    required bool isAndroid,
    required bool isIOS,
    required bool isMacOS,
    required bool isWindows,
    required bool isLinux,
  }) =>
      !isWeb && !isIOS && !isMacOS && (isAndroid || isWindows || isLinux);

  /// 执行一段脚本。[input] 会以全局变量 `INPUT`（字符串）注入，脚本可读取；
  /// 约定脚本的输出为「最后一个表达式的字符串值」或脚本自行 `JSON.stringify`。
  /// 不抛异常：引擎错误/不支持都包进 [JsExecResult]。
  Future<JsExecResult> run(String code, {String input = ''}) async {
    if (!isSupported) {
      return const JsExecResult.fail('当前平台不支持执行 JS 脚本');
    }
    if (code.length > maxCodeChars) {
      return const JsExecResult.fail('脚本过大，已拒绝执行');
    }
    if (input.length > maxInputChars) {
      return const JsExecResult.fail('脚本输入过大，已拒绝执行');
    }
    if (timeout <= Duration.zero) {
      return const JsExecResult.fail('脚本执行时间预算不合法');
    }

    final resultPort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_JsIsolateRequest>(
        _executeJsInIsolate,
        _JsIsolateRequest(
          sendPort: resultPort.sendPort,
          code: code,
          input: input,
          timeoutMicros: timeout.inMicroseconds,
          maxOutputChars: maxOutputChars,
          memoryLimitBytes: memoryLimitBytes,
        ),
        onError: resultPort.sendPort,
        onExit: resultPort.sendPort,
        errorsAreFatal: true,
      );
      final raw = await resultPort.first.timeout(timeout);
      if (raw is Map && raw['ok'] == true && raw['output'] is String) {
        return JsExecResult.ok(raw['output'] as String);
      }
      if (raw is Map && raw['error'] is String) {
        return JsExecResult.fail(raw['error'] as String);
      }
      return const JsExecResult.fail('脚本执行异常：运行时提前退出');
    } on TimeoutException {
      return const JsExecResult.fail('脚本执行超时，已终止');
    } catch (e) {
      return JsExecResult.fail('脚本执行异常：$e');
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      resultPort.close();
    }
  }
}

class _JsIsolateRequest {
  final SendPort sendPort;
  final String code;
  final String input;
  final int timeoutMicros;
  final int maxOutputChars;
  final int memoryLimitBytes;

  const _JsIsolateRequest({
    required this.sendPort,
    required this.code,
    required this.input,
    required this.timeoutMicros,
    required this.maxOutputChars,
    required this.memoryLimitBytes,
  });
}

void _executeJsInIsolate(_JsIsolateRequest request) {
  JavascriptRuntime? runtime;
  try {
    runtime = _createBudgetedRuntime(request);
    // 注入输入；脚本里可用全局 INPUT 取到原始文本。
    final wrapped =
        'var INPUT = ${jsonEncode(request.input)};\n${request.code}';
    final result = runtime.evaluate(wrapped);
    if (result.isError) {
      request.sendPort.send({
        'ok': false,
        'error': '脚本执行出错：${_boundedError(result.stringResult)}',
      });
      return;
    }
    final output = result.stringResult;
    if (output.length > request.maxOutputChars) {
      request.sendPort.send({
        'ok': false,
        'error': '脚本输出过大，已拒绝返回',
      });
      return;
    }
    request.sendPort.send({'ok': true, 'output': output});
  } catch (error) {
    request.sendPort.send({
      'ok': false,
      'error': '脚本执行异常：${_boundedError('$error')}',
    });
  } finally {
    runtime?.dispose();
  }
}

JavascriptRuntime _createBudgetedRuntime(_JsIsolateRequest request) {
  // QuickJS 自身再施加堆与时间预算；外层 isolate timeout 是独立兜底。
  return QuickJsRuntime2(
    timeout:
        (request.timeoutMicros / Duration.microsecondsPerMillisecond).ceil(),
    memoryLimit: request.memoryLimitBytes,
  );
}

String _boundedError(String value) =>
    value.length <= 4096 ? value : '${value.substring(0, 4096)}…';
