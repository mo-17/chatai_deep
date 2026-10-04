import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AgentBackgroundCapabilities {
  final bool supported;
  final String mode;
  final String? reason;
  const AgentBackgroundCapabilities(
      {required this.supported, this.mode = 'unsupported', this.reason});
}

class AgentBackgroundStartResult {
  final bool active;
  final String mode;
  final String? reason;
  const AgentBackgroundStartResult(
      {required this.active, this.mode = 'unsupported', this.reason});
}

abstract class AgentBackgroundExecution {
  Future<AgentBackgroundCapabilities> capabilities();
  Future<AgentBackgroundStartResult> start({
    required String runId,
    required int cid,
    required String title,
    required Future<void> Function(String reason) onInterrupted,
  });
  bool isActive(String runId);
  Future<void> update({
    required String runId,
    required int completed,
    required int total,
    required String status,
  });
  Future<void> stop({required String runId, bool success = false});
}

/// 一个引擎只持有一个原生执行许可；提交申请不代表已获准后台执行。
class PlatformAgentBackgroundExecution implements AgentBackgroundExecution {
  static final instance = PlatformAgentBackgroundExecution();
  final MethodChannel _channel;
  final String _operatingSystem;
  final Duration requestTimeout;
  String? _runId;
  bool _active = false;
  Future<AgentBackgroundStartResult>? _starting;
  Future<void> Function(String reason)? _onInterrupted;

  PlatformAgentBackgroundExecution({
    MethodChannel? channel,
    String? operatingSystem,
    this.requestTimeout = const Duration(seconds: 40),
  })  : _channel = channel ??
            const MethodChannel('com.example.chatgpt_flutter/agent_background'),
        _operatingSystem = operatingSystem ?? Platform.operatingSystem {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  bool get _mobile =>
      _operatingSystem == 'android' || _operatingSystem == 'ios';
  String get _mode =>
      _operatingSystem == 'android' ? 'androidForeground' : 'iosContinued';

  @override
  Future<AgentBackgroundCapabilities> capabilities() async {
    if (!_mobile) return const AgentBackgroundCapabilities(supported: false);
    try {
      final value = await _channel
          .invokeMapMethod<String, dynamic>('getCapabilities')
          .timeout(const Duration(seconds: 3));
      return AgentBackgroundCapabilities(
          supported: value?['supported'] == true,
          mode: value?['mode'] as String? ?? _mode,
          reason: value?['reason'] as String?);
    } catch (_) {
      return const AgentBackgroundCapabilities(
          supported: false, reason: 'native_unavailable');
    }
  }

  @override
  Future<AgentBackgroundStartResult> start({
    required String runId,
    required int cid,
    required String title,
    required Future<void> Function(String reason) onInterrupted,
  }) {
    if (_runId != null) {
      if (_runId == runId) {
        return _starting ??
            Future.value(
                AgentBackgroundStartResult(active: _active, mode: _mode));
      }
      return Future.value(
          const AgentBackgroundStartResult(active: false, reason: 'busy'));
    }
    if (!_mobile) {
      return Future.value(const AgentBackgroundStartResult(active: false));
    }
    _runId = runId;
    _onInterrupted = onInterrupted;
    final starting = _startNative(runId, cid, title);
    _starting = starting;
    return starting;
  }

  Future<AgentBackgroundStartResult> _startNative(
      String runId, int cid, String title) async {
    try {
      final caps = await capabilities();
      if (_runId != runId) {
        return const AgentBackgroundStartResult(
            active: false, reason: 'cancelled');
      }
      if (!caps.supported) {
        return AgentBackgroundStartResult(
            active: false, mode: caps.mode, reason: caps.reason);
      }
      final request = _channel.invokeMapMethod<String, dynamic>('start', {
        'runId': runId,
        'cid': cid,
        'title': title,
        'completed': 0,
        'total': 0,
      });
      // 超时或取消后迟到的成功回调不能复活任务，且须释放对应的原生许可。
      unawaited(request.then((value) async {
        if (_runId != runId && value?['active'] == true) {
          await _stopNative(runId, false);
        }
      }).catchError((Object _) {}));
      final value = await request.timeout(requestTimeout);
      if (_runId != runId) {
        return const AgentBackgroundStartResult(
            active: false, reason: 'cancelled');
      }
      _active = value?['active'] == true;
      return AgentBackgroundStartResult(
          active: _active,
          mode: value?['mode'] as String? ?? caps.mode,
          reason: value?['reason'] as String?);
    } catch (_) {
      if (_runId == runId) {
        _invalidate();
        await _stopNative(runId, false);
      }
      return const AgentBackgroundStartResult(
          active: false, reason: 'start_failed');
    } finally {
      if (_runId == runId) {
        _starting = null;
        if (!_active) _invalidate();
      }
    }
  }

  @override
  bool isActive(String runId) => _runId == runId && _active;

  @override
  Future<void> update({
    required String runId,
    required int completed,
    required int total,
    required String status,
  }) async {
    if (!isActive(runId)) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'runId': runId,
        'completed': completed,
        'total': total,
        'status': status,
      }).timeout(const Duration(seconds: 2));
    } catch (_) {
      if (_runId != runId) return;
      final callback = _onInterrupted;
      _invalidate();
      try {
        await callback?.call('systemStopped');
      } finally {
        await _stopNative(runId, false);
      }
    }
  }

  @override
  Future<void> stop({required String runId, bool success = false}) async {
    if (_runId != runId) return;
    _invalidate();
    await _stopNative(runId, success);
  }

  void _invalidate() {
    _runId = null;
    _active = false;
    _starting = null;
    _onInterrupted = null;
  }

  Future<void> _stopNative(String runId, bool success) async {
    try {
      await _channel.invokeMethod<void>('stop', {
        'runId': runId,
        'success': success,
      }).timeout(const Duration(seconds: 2));
    } catch (_) {
      // 原生停止是尽力清理；本地许可已同步撤销，后台事件不能再放行。
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onInterrupted' || call.arguments is! Map) return;
    final args = call.arguments as Map;
    if (args['runId'] != _runId || _runId == null) return;
    final runId = _runId!;
    final callback = _onInterrupted;
    _invalidate();
    // 返回前等待页面写入断点，iOS expiration handler 以此 ACK 收尾。
    try {
      await callback?.call(args['reason'] as String? ?? 'systemStopped');
    } finally {
      await _stopNative(runId, false);
    }
  }
}
