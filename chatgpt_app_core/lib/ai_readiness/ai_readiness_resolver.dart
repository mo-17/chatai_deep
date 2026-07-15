import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 仅根据当前设置和登录模式推导 AI 可用状态，不读写任何持久化数据。
AIReadyState resolveAIReadiness({
  required AISettings settings,
  required bool isGuest,
}) {
  if (settings.mode == AIMode.backend) {
    final modelId = settings.backendModel.trim();
    if (isGuest) {
      return AIReadyState(
        status: AIReadyStatus.backendRequiresLogin,
        reasonCode: 'backend_login_required',
        modelId: modelId.isEmpty ? null : modelId,
      );
    }
    if (modelId.isEmpty) {
      return const AIReadyState(
        status: AIReadyStatus.needsSetup,
        reasonCode: 'missing_model',
      );
    }
    // 后端模式当前没有与账号设置绑定的模型健康记录；配置完整时保持可发送前
    // 确认的 configuredUnverified，不能借用本地 provider 的测试结果。
    return AIReadyState(
      status: AIReadyStatus.configuredUnverified,
      reasonCode: 'model_unverified',
      modelId: modelId,
    );
  }

  final provider = settings.activeProvider;
  final providerId = provider.id.trim().isEmpty ? null : provider.id;
  if (!provider.enabled) {
    return AIReadyState(
      status: AIReadyStatus.needsSetup,
      reasonCode: 'provider_disabled',
      providerId: providerId,
    );
  }

  // 必须通过 activeLocal 取值：系统预设的 apiHost 留空时仍应回落到预设地址，
  // 保持旧配置和详情页“留空使用默认地址”的兼容语义。
  final local = settings.activeLocal;
  final modelId = local.model.trim();
  if (local.apiKey.trim().isEmpty) {
    return AIReadyState(
      status: AIReadyStatus.needsSetup,
      reasonCode: 'missing_api_key',
      providerId: providerId,
      modelId: modelId.isEmpty ? null : modelId,
    );
  }
  if (local.baseUrl.trim().isEmpty) {
    return AIReadyState(
      status: AIReadyStatus.needsSetup,
      reasonCode: 'missing_api_host',
      providerId: providerId,
      modelId: modelId.isEmpty ? null : modelId,
    );
  }
  if (modelId.isEmpty) {
    return AIReadyState(
      status: AIReadyStatus.needsSetup,
      reasonCode: 'missing_model',
      providerId: providerId,
    );
  }

  // 只认当前实际生效模型的测试结果。其它 provider 或同 provider 中未选模型
  // 的成功/失败都不能改变本次发送的 readiness。
  String? testStatus;
  for (final model in provider.models) {
    if (model.id.trim() == modelId) {
      testStatus = model.lastTestStatus.trim().toLowerCase();
      break;
    }
  }
  if (testStatus == 'success') {
    return AIReadyState(
      status: AIReadyStatus.ready,
      reasonCode: 'model_test_succeeded',
      providerId: providerId,
      modelId: modelId,
    );
  }
  if (testStatus == 'failure') {
    return AIReadyState(
      status: AIReadyStatus.temporarilyUnavailable,
      reasonCode: 'model_test_failed',
      providerId: providerId,
      modelId: modelId,
    );
  }
  return AIReadyState(
    status: AIReadyStatus.configuredUnverified,
    reasonCode: 'model_unverified',
    providerId: providerId,
    modelId: modelId,
  );
}
