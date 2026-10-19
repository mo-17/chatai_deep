import 'dart:isolate';
import 'package:flutter_js/flutter_js.dart';
import 'package:test/test.dart';

void main() {
  test('真实 FFI 引擎处理中文、emoji、NUL 与 INPUT，且不提供宿主能力', () {
    final runtime = QuickJsRuntime2();
    final result = runtime.evaluate(
      "var INPUT='中文😀';INPUT+'\\u0000'+[typeof fetch,typeof require,typeof std,typeof os,typeof process,typeof sendMessage].join(',')",
    );
    expect(result.isError, false, reason: result.stringResult);
    expect(
      result.stringResult,
      '中文😀\u0000undefined,undefined,undefined,undefined,undefined,undefined',
    );
    runtime.dispose();
    expect(() => runtime.evaluate('1'), throwsStateError);
  });
  test('不同调用之间不保存全局变量', () {
    final runtime = QuickJsRuntime2();
    expect(runtime.evaluate('globalThis.secret = 3').stringResult, '3');
    expect(runtime.evaluate('typeof secret').stringResult, 'undefined');
    runtime.dispose();
  });
  test('原生中断覆盖无限循环和结果 toString 中的无限循环', () {
    final runtime = QuickJsRuntime2(timeout: 30);
    for (final source in ['while(true){}', '({toString(){while(true){}}})']) {
      final clock = Stopwatch()..start();
      final result = runtime.evaluate(source);
      expect(result.isError, true);
      expect(result.stringResult, contains('timed out'));
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    }
    runtime.dispose();
  });
  test('堆、栈与输出超限返回失败，之后的新调用仍可用', () {
    final runtime = QuickJsRuntime2(memoryLimit: 2 * 1024 * 1024);
    final exhausted = runtime.evaluate(
      "const a=[];while(true)a.push(new Array(10000).fill('memory'))",
    );
    expect(exhausted.isError, true);
    expect(exhausted.stringResult, contains('memory'));
    expect(runtime.evaluate('function f(){return f()}f()').isError, true);
    final standard = QuickJsRuntime2();
    expect(standard.evaluate("'a'.repeat(4*1024*1024+1)").isError, true);
    expect(runtime.evaluate('1+1').stringResult, '2');
    standard.dispose();
    runtime.dispose();
  });
  test('动态 import 不能读取宿主模块', () {
    final runtime = QuickJsRuntime2();
    expect(runtime.evaluate("typeof import.meta").isError, true);
    expect(
      runtime
          .evaluate("typeof readFile + ':' + typeof loadScript")
          .stringResult,
      'undefined:undefined',
    );
    runtime.dispose();
  });
  test('真实引擎可在独立 Dart isolate 中运行', () async {
    expect(
      await Isolate.run(() {
        final runtime = QuickJsRuntime2();
        try {
          return runtime
              .evaluate('JSON.stringify([1,2,3].map(x=>x*x))')
              .stringResult;
        } finally {
          runtime.dispose();
        }
      }),
      '[1,4,9]',
    );
  });
  test('非法原生预算不会被当成成功', () {
    for (final runtime in [
      QuickJsRuntime2(timeout: 0),
      QuickJsRuntime2(memoryLimit: 128 * 1024 * 1024),
    ]) {
      expect(runtime.evaluate('1').isError, true);
      runtime.dispose();
    }
  });
}
