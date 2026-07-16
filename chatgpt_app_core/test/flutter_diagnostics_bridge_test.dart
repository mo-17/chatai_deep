import 'dart:async';

import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sink.dart';
import 'package:chatgpt_app_core/diagnostics/flutter_diagnostics_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FlutterDiagnosticsBridge', () {
    test('Flutter handler 会记录事件并且只调用一次旧 handler', () {
      final sink = _CollectingSink();
      var previousCalls = 0;
      void previous(FlutterErrorDetails details) => previousCalls += 1;
      FlutterExceptionHandler? current = previous;
      var presented = 0;
      final bridge = FlutterDiagnosticsBridge(
        sink: sink,
        getFlutterHandler: () => current,
        setFlutterHandler: (handler) => current = handler,
        presentFlutterError: (_) => presented += 1,
        getPlatformHandler: () => null,
        setPlatformHandler: (_) {},
      );

      bridge.installFlutterHandler();
      final error = StateError('private body');
      current!(FlutterErrorDetails(
        exception: error,
        stack: StackTrace.fromString(
          '#0 fn (package:example/a.dart:1:2)',
        ),
      ));

      expect(previousCalls, 1);
      expect(presented, 0);
      expect(sink.events, hasLength(1));
      expect(sink.events.single.source, DiagnosticsSource.flutter);
      expect(sink.events.single.exceptionType, 'StateError');
    });

    test('没有旧 Flutter handler 时保留 presentError 行为', () {
      FlutterExceptionHandler? current;
      var presented = 0;
      final bridge = FlutterDiagnosticsBridge(
        sink: const NoopDiagnosticsSink(),
        getFlutterHandler: () => current,
        setFlutterHandler: (handler) => current = handler,
        presentFlutterError: (_) => presented += 1,
        getPlatformHandler: () => null,
        setPlatformHandler: (_) {},
      );

      bridge.installFlutterHandler();
      current!(FlutterErrorDetails(exception: Exception('hidden')));

      expect(presented, 1);
    });

    test('Platform handler 原样返回旧 handler 的 bool', () {
      final sink = _CollectingSink();
      var previousCalls = 0;
      var previousResult = true;
      bool previous(Object error, StackTrace stackTrace) {
        previousCalls += 1;
        return previousResult;
      }

      PlatformErrorHandler? current = previous;
      final bridge = FlutterDiagnosticsBridge(
        sink: sink,
        getFlutterHandler: () => null,
        setFlutterHandler: (_) {},
        getPlatformHandler: () => current,
        setPlatformHandler: (handler) => current = handler,
      );

      bridge.installPlatformHandler();
      final handled = current!(Exception('hidden'), StackTrace.empty);

      expect(handled, isTrue);
      expect(previousCalls, 1);
      expect(sink.events.single.source, DiagnosticsSource.platform);

      previousResult = false;
      expect(current!(StateError('hidden'), StackTrace.empty), isFalse);
      expect(previousCalls, 2);
      expect(sink.events, hasLength(2));
    });

    test('Platform 没有旧 handler 时返回 false', () {
      PlatformErrorHandler? current;
      final bridge = FlutterDiagnosticsBridge(
        getFlutterHandler: () => null,
        setFlutterHandler: (_) {},
        getPlatformHandler: () => current,
        setPlatformHandler: (handler) => current = handler,
      );

      bridge.installPlatformHandler();

      expect(current!(Exception('hidden'), StackTrace.empty), isFalse);
    });

    test('嵌套 bridge 乱序释放不会复活已释放 handler', () {
      final firstSink = _CollectingSink();
      final secondSink = _CollectingSink();
      final FlutterExceptionHandler previousFlutter = (_) {};
      final PlatformErrorHandler previousPlatform = (_, __) => true;
      FlutterExceptionHandler? currentFlutter = previousFlutter;
      PlatformErrorHandler? currentPlatform = previousPlatform;

      FlutterDiagnosticsBridge makeBridge(DiagnosticsSink sink) =>
          FlutterDiagnosticsBridge(
            sink: sink,
            getFlutterHandler: () => currentFlutter,
            setFlutterHandler: (handler) => currentFlutter = handler,
            getPlatformHandler: () => currentPlatform,
            setPlatformHandler: (handler) => currentPlatform = handler,
          );

      final first = makeBridge(firstSink)
        ..installFlutterHandler()
        ..installPlatformHandler();
      final second = makeBridge(secondSink)
        ..installFlutterHandler()
        ..installPlatformHandler();

      first.dispose();
      currentFlutter!(FlutterErrorDetails(exception: Exception('flutter')));
      expect(
        currentPlatform!(StateError('platform'), StackTrace.empty),
        isTrue,
      );

      expect(firstSink.events, isEmpty);
      expect(secondSink.events, hasLength(2));

      second.dispose();
      expect(currentFlutter, same(previousFlutter));
      expect(currentPlatform, same(previousPlatform));
    });

    test('dispose 只恢复仍由当前 bridge 持有的 handler', () {
      void previousFlutter(FlutterErrorDetails details) {}
      bool previousPlatform(Object error, StackTrace stackTrace) => true;
      FlutterExceptionHandler? currentFlutter = previousFlutter;
      PlatformErrorHandler? currentPlatform = previousPlatform;
      final bridge = FlutterDiagnosticsBridge(
        sink: const NoopDiagnosticsSink(),
        getFlutterHandler: () => currentFlutter,
        setFlutterHandler: (handler) => currentFlutter = handler,
        getPlatformHandler: () => currentPlatform,
        setPlatformHandler: (handler) => currentPlatform = handler,
      );

      bridge
        ..installFlutterHandler()
        ..installPlatformHandler();
      bridge.dispose();

      expect(currentFlutter, same(previousFlutter));
      expect(currentPlatform, same(previousPlatform));

      final anotherBridge = FlutterDiagnosticsBridge(
        sink: const NoopDiagnosticsSink(),
        getFlutterHandler: () => currentFlutter,
        setFlutterHandler: (handler) => currentFlutter = handler,
        getPlatformHandler: () => currentPlatform,
        setPlatformHandler: (handler) => currentPlatform = handler,
      );
      anotherBridge
        ..installFlutterHandler()
        ..installPlatformHandler();
      void externalFlutter(FlutterErrorDetails details) {}
      bool externalPlatform(Object error, StackTrace stackTrace) => false;
      currentFlutter = externalFlutter;
      currentPlatform = externalPlatform;

      anotherBridge.dispose();

      expect(currentFlutter, same(externalFlutter));
      expect(currentPlatform, same(externalPlatform));
    });

    test('同步与异步 sink 失败都不会逃逸', () async {
      FlutterExceptionHandler? syncHandler;
      final syncBridge = FlutterDiagnosticsBridge(
        sink: _ThrowingSink(),
        getFlutterHandler: () => syncHandler,
        setFlutterHandler: (handler) => syncHandler = handler,
        presentFlutterError: (_) {},
        getPlatformHandler: () => null,
        setPlatformHandler: (_) {},
      )..installFlutterHandler();

      expect(
        () => syncHandler!(FlutterErrorDetails(exception: Exception('hidden'))),
        returnsNormally,
      );

      final asyncBridge = FlutterDiagnosticsBridge(
        sink: _AsyncThrowingSink(),
        getFlutterHandler: () => null,
        setFlutterHandler: (_) {},
        getPlatformHandler: () => null,
        setPlatformHandler: (_) {},
      );
      expect(
        () => asyncBridge.recordZoneError(Exception('hidden'), StackTrace.empty),
        returnsNormally,
      );
      await Future<void>.delayed(Duration.zero);
    });

    test('同一异常对象在一个微任务窗口内只记录一次', () async {
      final sink = _CollectingSink();
      FlutterExceptionHandler? current;
      final bridge = FlutterDiagnosticsBridge(
        sink: sink,
        getFlutterHandler: () => current,
        setFlutterHandler: (handler) => current = handler,
        presentFlutterError: (_) {},
        getPlatformHandler: () => null,
        setPlatformHandler: (_) {},
      )..installFlutterHandler();
      final error = StateError('hidden');
      final stack = StackTrace.fromString(
        '#0 fn (package:example/a.dart:1:2)',
      );

      current!(FlutterErrorDetails(exception: error, stack: stack));
      bridge.recordZoneError(error, stack);
      expect(sink.events, hasLength(1));

      await Future<void>.delayed(Duration.zero);
      bridge.recordZoneError(error, stack);
      expect(sink.events, hasLength(2));
      expect(sink.events.last.source, DiagnosticsSource.zone);
    });
  });
}

class _CollectingSink implements DiagnosticsSink {
  final List<DiagnosticsEvent> events = [];

  @override
  void capture(DiagnosticsEvent event) => events.add(event);
}

class _ThrowingSink implements DiagnosticsSink {
  @override
  void capture(DiagnosticsEvent event) {
    throw StateError('sink failed');
  }
}

class _AsyncThrowingSink implements DiagnosticsSink {
  @override
  Future<void> capture(DiagnosticsEvent event) =>
      Future<void>.error(StateError('sink failed'));
}
