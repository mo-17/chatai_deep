import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_send_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AIReadyState state(AIReadyStatus status, {String reason = 'test'}) =>
      AIReadyState(status: status, reasonCode: reason);

  test('ready 与配置完整但未验证允许发送', () {
    for (final status in [
      AIReadyStatus.ready,
      AIReadyStatus.configuredUnverified,
    ]) {
      final decision = resolveAISendGuard(
        state: state(status),
        onboardingStatus: AIOnboardingStatus.unseen,
      );
      expect(decision.allowed, isTrue, reason: '$status');
      expect(decision.action, AISendGuardAction.none);
    }
  });

  test('grandfathered 旧账号不新增强制发送阻断', () {
    for (final status in AIReadyStatus.values) {
      final decision = resolveAISendGuard(
        state: state(status),
        onboardingStatus: AIOnboardingStatus.grandfathered,
      );
      expect(decision.allowed, isTrue, reason: '$status');
      expect(decision.reasonCode, 'legacy_account_passthrough');
    }
  });

  test('缺配置 fail-closed 并引导配置', () {
    final decision = resolveAISendGuard(
      state: state(
        AIReadyStatus.needsSetup,
        reason: 'missing_api_key',
      ),
      onboardingStatus: AIOnboardingStatus.unseen,
    );

    expect(decision.allowed, isFalse);
    expect(decision.reasonCode, 'missing_api_key');
    expect(decision.action, AISendGuardAction.configure);
  });

  test('已知连接失败、初始化中、游客后端分别给出稳定修复动作', () {
    final cases = <AIReadyStatus, AISendGuardAction>{
      AIReadyStatus.temporarilyUnavailable: AISendGuardAction.verify,
      AIReadyStatus.loading: AISendGuardAction.retry,
      AIReadyStatus.backendRequiresLogin: AISendGuardAction.login,
    };

    for (final entry in cases.entries) {
      final decision = resolveAISendGuard(
        state: state(entry.key),
        onboardingStatus: AIOnboardingStatus.dismissed,
      );
      expect(decision.allowed, isFalse, reason: '${entry.key}');
      expect(decision.action, entry.value, reason: '${entry.key}');
    }
  });
}
