import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';

enum AIReadinessPrimaryAction { none, retry, configure, verify, login }

@immutable
final class AIReadinessPresentation {
  final String title;
  final String message;
  final String statusLabel;
  final AppStatusKind statusKind;
  final IconData icon;
  final AIReadinessPrimaryAction primaryAction;
  final String primaryLabel;

  const AIReadinessPresentation({
    required this.title,
    required this.message,
    required this.statusLabel,
    required this.statusKind,
    required this.icon,
    required this.primaryAction,
    required this.primaryLabel,
  });
}

AIReadinessPresentation aiReadinessPresentation(AIReadyState state) {
  return switch (state.status) {
    AIReadyStatus.loading => const AIReadinessPresentation(
        title: '正在确认 AI 服务',
        message: '正在读取当前账号的配置与历史状态，请稍候。',
        statusLabel: '检查中',
        statusKind: AppStatusKind.neutral,
        icon: Icons.hourglass_top_rounded,
        primaryAction: AIReadinessPrimaryAction.retry,
        primaryLabel: '重新检查',
      ),
    AIReadyStatus.needsSetup => AIReadinessPresentation(
        title: _needsSetupTitle(state.reasonCode),
        message: _needsSetupMessage(state.reasonCode),
        statusLabel: '待配置',
        statusKind: AppStatusKind.warning,
        icon: Icons.tune_rounded,
        primaryAction: AIReadinessPrimaryAction.configure,
        primaryLabel: '去配置',
      ),
    AIReadyStatus.configuredUnverified => const AIReadinessPresentation(
        title: 'AI 服务已配置',
        message: '可以直接开始对话；也可以先做一次连接检查，确认当前模型可用。',
        statusLabel: '待验证',
        statusKind: AppStatusKind.info,
        icon: Icons.network_check_rounded,
        primaryAction: AIReadinessPrimaryAction.verify,
        primaryLabel: '检查连接',
      ),
    AIReadyStatus.ready => const AIReadinessPresentation(
        title: 'AI 服务可用',
        message: '当前服务商与模型已通过连接检查。',
        statusLabel: '可用',
        statusKind: AppStatusKind.success,
        icon: Icons.check_circle_outline_rounded,
        primaryAction: AIReadinessPrimaryAction.none,
        primaryLabel: '',
      ),
    AIReadyStatus.temporarilyUnavailable => const AIReadinessPresentation(
        title: '当前模型连接异常',
        message: '上次检查未通过。请重新检查，或调整服务商、API 地址与模型。',
        statusLabel: '连接异常',
        statusKind: AppStatusKind.error,
        icon: Icons.cloud_off_outlined,
        primaryAction: AIReadinessPrimaryAction.verify,
        primaryLabel: '重新检查',
      ),
    AIReadyStatus.backendRequiresLogin => const AIReadinessPresentation(
        title: '后端代理需要登录',
        message: '游客模式可以使用本地直连；登录后才能使用账号的后端代理。',
        statusLabel: '需登录',
        statusKind: AppStatusKind.warning,
        icon: Icons.login_rounded,
        primaryAction: AIReadinessPrimaryAction.login,
        primaryLabel: '去登录',
      ),
  };
}

String _needsSetupTitle(String reasonCode) => switch (reasonCode) {
      'provider_disabled' => '启用一个 AI 服务商',
      'missing_api_key' => '添加服务商 API Key',
      'missing_api_host' => '补充 API 地址',
      'missing_model' => '选择一个可用模型',
      'invalid_backend_selection' || 'backend_scope_changed' => '重新选择后端服务商与模型',
      'model_unavailable' => '原后端模型已删除或停用',
      _ => '完成 AI 服务配置',
    };

String _needsSetupMessage(String reasonCode) => switch (reasonCode) {
      'provider_disabled' => '当前服务商未启用，选择并启用一家服务商后即可开始对话。',
      'missing_api_key' => '你的 Key 只保存在当前账号的安全存储中，不会写入普通配置。',
      'missing_api_host' => '请填写兼容 OpenAI 的 API 地址，系统预设也可以恢复默认地址。',
      'missing_model' => '为当前服务商选择或添加一个模型 ID。',
      'invalid_backend_selection' => '原后端选择无法识别，请明确选择服务商与模型。',
      'backend_scope_changed' => '原选择属于其它账号或后端地址，请在当前环境明确重新选择。',
      'model_unavailable' => '原服务商或模型已删除、停用，请重新选择；不会自动改用其它模型。',
      _ => '配置服务商、API Key 与模型后即可开始对话。',
    };

/// 会话列表顶部的非打断式 AI 配置卡。是否展示由外层的
/// `AIReadinessProvider.showProactiveCard` 决定。
class AIReadinessCard extends StatelessWidget {
  final AIReadyState state;
  final VoidCallback? onRetry;
  final VoidCallback? onConfigure;
  final VoidCallback? onVerify;
  final VoidCallback? onLogin;
  final VoidCallback? onDismiss;

  const AIReadinessCard({
    super.key,
    required this.state,
    this.onRetry,
    this.onConfigure,
    this.onVerify,
    this.onLogin,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final presentation = aiReadinessPresentation(state);
    final primaryCallback = _primaryCallback(presentation);
    final secondaryCallback = _secondaryCallback(presentation);
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(presentation.icon,
                  size: 28, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(presentation.title,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      presentation.message,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  key: const ValueKey('ai_readiness_dismiss'),
                  tooltip: '稍后提醒',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              AppStatusBadge(
                label: presentation.statusLabel,
                kind: presentation.statusKind,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (secondaryCallback != null)
                      TextButton(
                        onPressed: secondaryCallback,
                        child: const Text('服务设置'),
                      ),
                    if (primaryCallback != null)
                      FilledButton(
                        key: const ValueKey('ai_readiness_primary_action'),
                        onPressed: primaryCallback,
                        child: Text(presentation.primaryLabel),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (AppVisualTheme.of(context).isAnime) {
      return AppVisualSurface(
        animeKey: const ValueKey('anime_ai_readiness_card'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: EdgeInsets.zero,
        child: content,
      );
    }
    return Card(
      key: const ValueKey('classic_ai_readiness_card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: content,
    );
  }

  VoidCallback? _primaryCallback(AIReadinessPresentation presentation) =>
      switch (presentation.primaryAction) {
        AIReadinessPrimaryAction.none => null,
        AIReadinessPrimaryAction.retry => onRetry,
        AIReadinessPrimaryAction.configure => onConfigure,
        AIReadinessPrimaryAction.verify => onVerify ?? onConfigure,
        AIReadinessPrimaryAction.login => onLogin,
      };

  VoidCallback? _secondaryCallback(AIReadinessPresentation presentation) {
    if (onConfigure == null ||
        presentation.primaryAction == AIReadinessPrimaryAction.configure ||
        presentation.primaryAction == AIReadinessPrimaryAction.none) {
      return null;
    }
    return onConfigure;
  }
}

class AIReadinessStatusBadge extends StatelessWidget {
  final AIReadyState state;

  const AIReadinessStatusBadge({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final presentation = aiReadinessPresentation(state);
    return AppStatusBadge(
      label: presentation.statusLabel,
      kind: presentation.statusKind,
    );
  }
}
