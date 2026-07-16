import 'dart:convert';

import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticsSanitizer', () {
    test('只保留白名单字段，且不会泄露异常正文或不安全 stack', () {
      final error = StateError(
        'Bearer token-123 sk-secret account_hash=user-abc '
        'https://api.example.com/v1/chat '
        '/Users/alice/private/story.txt '
        'prompt=不要泄露 MCP args={"path":"/secret"}',
      );
      final stackTrace = StackTrace.fromString('''
#0 unsafe (/Users/alice/private/story.txt:1:1)
#1 request (https://api.example.com/v1/chat:2:3)
#2 safe (package:chatgpt_app_core/example.dart:10:3) prompt=不要泄露
#3 schedule (dart:async/zone.dart:20:4) Bearer token-123
MCP args={"apiKey":"sk-secret","account":"user-abc"}
''');

      final event = const DiagnosticsSanitizer().fromError(
        source: DiagnosticsSource.flutter,
        error: error,
        stackTrace: stackTrace,
        appVersion: '1.0.4+8',
        platform: 'android',
        httpStatusCode: 503,
        durationMs: 1250,
        count: 2,
      );

      final encoded = jsonEncode(event.toJson());
      expect(encoded, isNot(contains('sk-secret')));
      expect(encoded, isNot(contains('Bearer')));
      expect(encoded, isNot(contains('https://')));
      expect(encoded, isNot(contains('/Users/')));
      expect(encoded, isNot(contains('不要泄露')));
      expect(encoded, isNot(contains('user-abc')));
      expect(encoded, isNot(contains('MCP args')));
      expect(event.source, DiagnosticsSource.flutter);
      expect(event.exceptionType, 'StateError');
      expect(
        event.stackFrames,
        everyElement(anyOf(startsWith('package:'), startsWith('dart:'))),
      );
      expect(event.stackFrames, [
        'package:chatgpt_app_core/example.dart:10:3',
        'dart:async/zone.dart:20:4',
      ]);
      expect(
        event.toJson().keys,
        unorderedEquals(const [
          'source',
          'exceptionType',
          'stackFrames',
          'appVersion',
          'platform',
          'httpStatusCode',
          'durationMs',
          'count',
        ]),
      );
    });

    test('stack 最多保留 40 帧且单帧最多 240 字符', () {
      final longSegment = List.filled(300, 'a').join();
      final stackTrace = StackTrace.fromString(
        List.generate(
          60,
          (index) =>
              '#$index fn (package:example/$longSegment.dart:$index:1)',
        ).join('\n'),
      );

      final event = const DiagnosticsSanitizer().fromError(
        source: DiagnosticsSource.zone,
        error: Exception('secret message'),
        stackTrace: stackTrace,
      );

      expect(event.stackFrames, hasLength(40));
      expect(
        event.stackFrames,
        everyElement(hasLength(lessThanOrEqualTo(240))),
      );
      expect(event.stackFrames, everyElement(startsWith('package:')));
    });

    test('非法元数据与无效指标不会进入事件', () {
      final event = const DiagnosticsSanitizer().fromError(
        source: DiagnosticsSource.zone,
        error: Exception('hidden'),
        appVersion: '1.0.4 Bearer secret',
        platform: '/Users/alice',
        httpStatusCode: 999,
        durationMs: -1,
        count: 0,
      );

      expect(
        event.toJson().keys,
        unorderedEquals(const ['source', 'exceptionType', 'stackFrames']),
      );
    });

    test('事件会防御性复制 stack，toJson 每次创建独立白名单 map', () {
      final frames = <String>['package:example/a.dart:1:2'];
      final event = DiagnosticsEvent(
        source: DiagnosticsSource.platform,
        exceptionType: 'ArgumentError',
        stackFrames: frames,
      );
      frames.add('package:example/leak.dart:3:4');

      final first = event.toJson();
      first['source'] = 'tampered';
      (first['stackFrames']! as List<String>).add('package:bad/leak.dart');
      final second = event.toJson();

      expect(event.stackFrames, ['package:example/a.dart:1:2']);
      expect(second['source'], 'platform');
      expect(second['stackFrames'], ['package:example/a.dart:1:2']);
    });

    test('直接构造事件也不能绕过字段值净化', () {
      final event = DiagnosticsEvent(
        source: DiagnosticsSource.platform,
        exceptionType: 'StateError Bearer sk-secret',
        stackFrames: const [
          '/Users/alice/private.dart:1:2',
          'package:example/a.dart:3:4) Bearer sk-secret',
        ],
        appVersion: 'https://secret.example',
        platform: '/Users/alice',
        httpStatusCode: 999,
        durationMs: -1,
        count: 0,
      );

      final encoded = jsonEncode(event.toJson());
      expect(encoded, isNot(contains('Bearer')));
      expect(encoded, isNot(contains('sk-secret')));
      expect(encoded, isNot(contains('/Users/')));
      expect(encoded, isNot(contains('https://')));
      expect(event.exceptionType, 'Object');
      expect(event.stackFrames, ['package:example/a.dart:3:4']);
      expect(
        event.toJson().keys,
        unorderedEquals(const ['source', 'exceptionType', 'stackFrames']),
      );
    });
  });
}
