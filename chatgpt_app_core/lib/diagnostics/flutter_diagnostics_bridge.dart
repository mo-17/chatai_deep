import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sanitizer.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sink.dart';
import 'package:flutter/foundation.dart';

typedef PlatformErrorHandler = bool Function(
  Object error,
  StackTrace stackTrace,
);

/// 把 Flutter、PlatformDispatcher 和 Zone 三条错误路径统一为安全事件。
///
/// getter/setter 可注入，既便于测试，也让 handler 所有权判断不依赖全局状态。
final class FlutterDiagnosticsBridge {
  static final Expando<_FlutterHandlerNode> _flutterHandlerNodes =
      Expando<_FlutterHandlerNode>('diagnosticsFlutterHandler');
  static final Expando<_PlatformHandlerNode> _platformHandlerNodes =
      Expando<_PlatformHandlerNode>('diagnosticsPlatformHandler');

  final DiagnosticsSink _sink;
  final DiagnosticsSanitizer _sanitizer;
  final FlutterExceptionHandler? Function() _getFlutterHandler;
  final void Function(FlutterExceptionHandler? handler) _setFlutterHandler;
  final PlatformErrorHandler? Function() _getPlatformHandler;
  final void Function(PlatformErrorHandler? handler) _setPlatformHandler;
  final void Function(FlutterErrorDetails details) _presentFlutterError;
  final Set<Object> _inFlightErrors = HashSet<Object>.identity();

  FlutterExceptionHandler? _previousFlutterHandler;
  FlutterExceptionHandler? _ownedFlutterHandler;
  _FlutterHandlerNode? _ownedFlutterNode;
  PlatformErrorHandler? _previousPlatformHandler;
  PlatformErrorHandler? _ownedPlatformHandler;
  _PlatformHandlerNode? _ownedPlatformNode;
  bool _flutterInstalled = false;
  bool _platformInstalled = false;

  FlutterDiagnosticsBridge({
    DiagnosticsSink sink = const NoopDiagnosticsSink(),
    DiagnosticsSanitizer sanitizer = const DiagnosticsSanitizer(),
    FlutterExceptionHandler? Function()? getFlutterHandler,
    void Function(FlutterExceptionHandler? handler)? setFlutterHandler,
    PlatformErrorHandler? Function()? getPlatformHandler,
    void Function(PlatformErrorHandler? handler)? setPlatformHandler,
    void Function(FlutterErrorDetails details)? presentFlutterError,
  })  : _sink = sink,
        _sanitizer = sanitizer,
        _getFlutterHandler = getFlutterHandler ?? (() => FlutterError.onError),
        _setFlutterHandler =
            setFlutterHandler ?? ((handler) => FlutterError.onError = handler),
        _getPlatformHandler =
            getPlatformHandler ?? (() => ui.PlatformDispatcher.instance.onError),
        _setPlatformHandler = setPlatformHandler ??
            ((handler) => ui.PlatformDispatcher.instance.onError = handler),
        _presentFlutterError = presentFlutterError ?? FlutterError.presentError;

  void installFlutterHandler() {
    if (_flutterInstalled) return;
    _previousFlutterHandler = _getFlutterHandler();
    final previous = _previousFlutterHandler;
    late final _FlutterHandlerNode node;
    late final FlutterExceptionHandler handler;
    handler = (FlutterErrorDetails details) {
      if (node.active) {
        _record(
          source: DiagnosticsSource.flutter,
          error: details.exception,
          stackTrace: details.stack ?? StackTrace.empty,
        );
      }
      if (previous != null) {
        previous(details);
      } else {
        _presentFlutterError(details);
      }
    };
    node = _FlutterHandlerNode(previous);
    _ownedFlutterHandler = handler;
    _ownedFlutterNode = node;
    _flutterHandlerNodes[handler] = node;
    _setFlutterHandler(handler);
    _flutterInstalled = true;
  }

  void installPlatformHandler() {
    if (_platformInstalled) return;
    _previousPlatformHandler = _getPlatformHandler();
    final previous = _previousPlatformHandler;
    late final _PlatformHandlerNode node;
    late final PlatformErrorHandler handler;
    handler = (Object error, StackTrace stackTrace) {
      if (node.active) {
        _record(
          source: DiagnosticsSource.platform,
          error: error,
          stackTrace: stackTrace,
        );
      }
      return previous?.call(error, stackTrace) ?? false;
    };
    node = _PlatformHandlerNode(previous);
    _ownedPlatformHandler = handler;
    _ownedPlatformNode = node;
    _platformHandlerNodes[handler] = node;
    _setPlatformHandler(handler);
    _platformInstalled = true;
  }

  void recordZoneError(Object error, StackTrace stackTrace) {
    _record(
      source: DiagnosticsSource.zone,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void dispose() {
    _ownedFlutterNode?.active = false;
    _ownedPlatformNode?.active = false;
    if (_flutterInstalled &&
        identical(_getFlutterHandler(), _ownedFlutterHandler)) {
      _setFlutterHandler(_nearestActiveFlutterHandler(
        _previousFlutterHandler,
      ));
    }
    if (_platformInstalled &&
        identical(_getPlatformHandler(), _ownedPlatformHandler)) {
      _setPlatformHandler(_nearestActivePlatformHandler(
        _previousPlatformHandler,
      ));
    }
    _previousFlutterHandler = null;
    _ownedFlutterHandler = null;
    _ownedFlutterNode = null;
    _previousPlatformHandler = null;
    _ownedPlatformHandler = null;
    _ownedPlatformNode = null;
    _flutterInstalled = false;
    _platformInstalled = false;
    _inFlightErrors.clear();
  }

  static FlutterExceptionHandler? _nearestActiveFlutterHandler(
    FlutterExceptionHandler? handler,
  ) {
    final seen = HashSet<Object>.identity();
    var candidate = handler;
    while (candidate != null) {
      final current = candidate;
      if (!seen.add(current)) return null;
      final node = _flutterHandlerNodes[current];
      if (node == null || node.active) return current;
      candidate = node.previous;
    }
    return null;
  }

  static PlatformErrorHandler? _nearestActivePlatformHandler(
    PlatformErrorHandler? handler,
  ) {
    final seen = HashSet<Object>.identity();
    var candidate = handler;
    while (candidate != null) {
      final current = candidate;
      if (!seen.add(current)) return null;
      final node = _platformHandlerNodes[current];
      if (node == null || node.active) return current;
      candidate = node.previous;
    }
    return null;
  }

  void _record({
    required DiagnosticsSource source,
    required Object error,
    required StackTrace stackTrace,
  }) {
    if (!_inFlightErrors.add(error)) return;
    scheduleMicrotask(() => _inFlightErrors.remove(error));

    DiagnosticsEvent event;
    try {
      event = _sanitizer.fromError(
        source: source,
        error: error,
        stackTrace: stackTrace,
      );
    } catch (_) {
      return;
    }

    // Future.sync 同时隔离同步 throw 和 Future error；onError 不记录日志，
    // 避免诊断 sink 自身失败再次进入全局错误链。
    final capture = Future<void>.sync(() => _sink.capture(event));
    unawaited(capture.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    ));
  }
}

final class _FlutterHandlerNode {
  final FlutterExceptionHandler? previous;
  bool active = true;

  _FlutterHandlerNode(this.previous);
}

final class _PlatformHandlerNode {
  final PlatformErrorHandler? previous;
  bool active = true;

  _PlatformHandlerNode(this.previous);
}
