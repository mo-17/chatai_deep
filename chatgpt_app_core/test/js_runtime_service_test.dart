import 'dart:io';

import 'package:chatgpt_app_core/skill/js_runtime_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('仅 heap/time 可同时受限的 QuickJS 平台启用脚本执行', () {
    expect(
      JsRuntimeService.supportsPlatform(
        isWeb: false,
        isAndroid: true,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
      ),
      isTrue,
    );
    expect(
      JsRuntimeService.supportsPlatform(
        isWeb: false,
        isAndroid: false,
        isIOS: true,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
      ),
      isFalse,
      reason: 'iOS/macOS JSC 无 heap cap，必须 fail closed',
    );
    expect(
      JsRuntimeService.supportsPlatform(
        isWeb: false,
        isAndroid: false,
        isIOS: false,
        isMacOS: true,
        isWindows: false,
        isLinux: false,
      ),
      isFalse,
      reason: 'macOS JSC 无 heap cap，必须 fail closed',
    );
    expect(
      JsRuntimeService.supportsPlatform(
        isWeb: false,
        isAndroid: false,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: true,
      ),
      isFalse,
      reason: 'Linux 随包 bridge 缺少原生内存和超时保障，必须 fail closed',
    );
    expect(
      JsRuntimeService.supportsPlatform(
        isWeb: true,
        isAndroid: true,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
      ),
      isFalse,
    );
  });

  test('Linux 不加载不兼容 bridge，也不尝试执行脚本', () async {
    const service = JsRuntimeService();
    final result = await service.run('while (true) {}');
    expect(result.ok, isFalse);
    expect(result.error, '当前平台不支持执行 JS 脚本');
  }, skip: !Platform.isLinux);

  test('合法脚本在隔离运行时中读取 INPUT，且不暴露 fetch', () async {
    const service = JsRuntimeService(timeout: Duration(seconds: 2));

    final result = await service.run(
      "typeof fetch + ':' + INPUT.toUpperCase()",
      input: 'hello',
    );

    expect(result.ok, isTrue, reason: result.error);
    expect(result.output, 'undefined:HELLO');
  }, skip: !JsRuntimeService.isSupported);

  test('无限循环脚本受原生 watchdog 与 killable isolate 总预算约束', () async {
    const service = JsRuntimeService(timeout: Duration(milliseconds: 300));
    final clock = Stopwatch()..start();

    final result = await service.run('while (true) {}');
    clock.stop();

    expect(result.ok, isFalse);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  }, skip: !JsRuntimeService.isSupported);

  test('代码、输入与输出预算在跨 isolate 复制前后 fail closed', () async {
    const service = JsRuntimeService(
      maxCodeChars: 16,
      maxInputChars: 4,
      maxOutputChars: 8,
    );

    final code = await service.run('12345678901234567');
    final input = await service.run('INPUT', input: '12345');
    final output = await service.run("'123456789'");

    expect(code.ok, isFalse);
    expect(code.error, contains('脚本过大'));
    expect(input.ok, isFalse);
    expect(input.error, contains('输入过大'));
    expect(output.ok, isFalse);
    expect(output.error, contains('输出过大'));
  }, skip: !JsRuntimeService.isSupported);
}
