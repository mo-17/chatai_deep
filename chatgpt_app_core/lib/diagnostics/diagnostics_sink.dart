import 'dart:async';

import 'package:chatgpt_app_core/diagnostics/diagnostics_consent_store.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_gate.dart';

abstract interface class DiagnosticsSink {
  FutureOr<void> capture(DiagnosticsEvent event);
}

/// 默认 sink：不缓存、不上传，也不引入任何原生诊断依赖。
final class NoopDiagnosticsSink implements DiagnosticsSink {
  const NoopDiagnosticsSink();

  @override
  void capture(DiagnosticsEvent event) {}
}

typedef DiagnosticsFlagReader = bool Function();

/// 在真实 delegate 的 capture 边界动态执行三重开关。
///
/// build 或 remote reader 缺失时分别按“未配置”和“已熔断”处理；任何读取
/// 异常也直接拒绝，避免显式传入上传 delegate 后绕过用户同意。
final class ConsentGatedDiagnosticsSink implements DiagnosticsSink {
  final DiagnosticsSink delegate;
  final DiagnosticsConsentStore consentStore;
  final DiagnosticsFlagReader? _buildConfigured;
  final DiagnosticsFlagReader? _remoteDisabled;

  ConsentGatedDiagnosticsSink({
    this.delegate = const NoopDiagnosticsSink(),
    this.consentStore = const DiagnosticsConsentStore(),
    DiagnosticsFlagReader? buildConfigured,
    DiagnosticsFlagReader? remoteDisabled,
  })  : _buildConfigured = buildConfigured,
        _remoteDisabled = remoteDisabled;

  @override
  FutureOr<void> capture(DiagnosticsEvent event) {
    try {
      final enabled = DiagnosticsGate.enabled(
        buildConfigured: _buildConfigured?.call() ?? false,
        userConsented: consentStore.read(),
        remoteDisabled: _remoteDisabled?.call() ?? true,
      );
      if (!enabled) return null;
    } catch (_) {
      return null;
    }
    return delegate.capture(event);
  }
}
