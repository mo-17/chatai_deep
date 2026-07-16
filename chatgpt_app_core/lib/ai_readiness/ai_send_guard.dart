import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';

enum AISendGuardAction { none, retry, configure, verify, login }

/// 发送前的纯决策结果。UI 只负责展示并执行 [action]，不得自行放宽规则。
final class AISendGuardDecision {
  final bool allowed;
  final String reasonCode;
  final AISendGuardAction action;

  const AISendGuardDecision._({
    required this.allowed,
    required this.reasonCode,
    required this.action,
  });

  const AISendGuardDecision.allow(String reasonCode)
      : this._(
          allowed: true,
          reasonCode: reasonCode,
          action: AISendGuardAction.none,
        );

  const AISendGuardDecision.block(
    String reasonCode,
    AISendGuardAction action,
  ) : this._(
          allowed: false,
          reasonCode: reasonCode,
          action: action,
        );
}

/// 主聊天发送的 fail-closed 策略。
///
/// - 已验证可用、或配置完整但尚未验证：允许首轮请求；
/// - grandfathered 旧账号：保留升级前行为，不新增强制阻断；
/// - 缺配置、已知连接失败、游客选择后端或尚未完成账号初始化：阻断并给出
///   明确修复动作。
AISendGuardDecision resolveAISendGuard({
  required AIReadyState state,
  required AIOnboardingStatus onboardingStatus,
}) {
  if (onboardingStatus == AIOnboardingStatus.grandfathered) {
    return const AISendGuardDecision.allow('legacy_account_passthrough');
  }

  return switch (state.status) {
    AIReadyStatus.ready =>
      const AISendGuardDecision.allow('readiness_ready'),
    AIReadyStatus.configuredUnverified =>
      const AISendGuardDecision.allow('configured_first_send'),
    AIReadyStatus.loading => const AISendGuardDecision.block(
        'readiness_loading',
        AISendGuardAction.retry,
      ),
    AIReadyStatus.needsSetup => AISendGuardDecision.block(
        state.reasonCode,
        AISendGuardAction.configure,
      ),
    AIReadyStatus.temporarilyUnavailable => AISendGuardDecision.block(
        state.reasonCode,
        AISendGuardAction.verify,
      ),
    AIReadyStatus.backendRequiresLogin => const AISendGuardDecision.block(
        'backend_login_required',
        AISendGuardAction.login,
      ),
  };
}
