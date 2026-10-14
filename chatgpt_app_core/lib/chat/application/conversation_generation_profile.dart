import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:login_sdk/dao/backend_host.dart';

/// 参数固定为发送时副本；只切全局当前模型不会改变或撤销原运行。
class ConversationGenerationProfile {
  final AISettings _settings;
  AISettings get settings => _settings.clone();
  final String providerId, modelId, account;
  final String _key, _endpoint;
  final Future<AISettings> Function() loadSettings;
  final AISettings? Function() visibleSettings;
  ConversationGenerationProfile(
    AISettings selected,
    this.account, {
    Future<AISettings> Function()? loadSettings,
    AISettings? Function()? visibleSettings,
  })  : _settings = selected.clone(),
        providerId = selected.mode == AIMode.local
            ? selected.activeProviderId
            : 'backend',
        modelId = selected.effectiveModel,
        _key =
            selected.mode == AIMode.local ? selected.activeProvider.apiKey : '',
        _endpoint = selected.mode == AIMode.local
            ? selected.activeProvider.chatCompletionsUrl
            : BackendConfig.buildUri('/uapi/chat/completions').toString(),
        loadSettings =
            loadSettings ?? (() => AISettingsDao.loadForAsync(account)),
        visibleSettings = visibleSettings ??
            (() => AISettingsProvider.instance?.accountHash == account
                ? AISettingsProvider.instance!.settings
                : null);

  bool matches(AISettings current) {
    if (_settings.mode == AIMode.backend) {
      return BackendConfig.buildUri('/uapi/chat/completions').toString() ==
              _endpoint &&
          ModelCatalog.backendProfileAvailable(modelId, account: account);
    }
    final providers =
        current.providers.where((p) => p.id == providerId).toList();
    return providers.length == 1 &&
        providers.single.enabled &&
        _key.trim().isNotEmpty &&
        providers.single.apiKey == _key &&
        providers.single.chatCompletionsUrl == _endpoint &&
        providers.single.models.any((m) => m.id == modelId);
  }

  bool get visiblyCurrent {
    if (_settings.mode == AIMode.backend) return matches(_settings);
    final visible = visibleSettings();
    return visible == null || matches(visible);
  }

  Future<void> verify(ConversationGenerationScope scope) async {
    scope.verify();
    final AISettings current;
    try {
      current = await loadSettings();
    } on AISecretsUnavailableException {
      throw _revoked();
    }
    scope.verify();
    if (!matches(current) || !visiblyCurrent) {
      throw _revoked();
    }
  }

  static ChatTransportException _revoked() => const ChatTransportException(
      safeCode: 'conversation_configuration_revoked_unsent',
      safeMessage: '原服务商、模型或凭据已撤销，本次请求未发送',
      failureStage: ChatFailureStage.prepare,
      failureKind: ChatFailureKind.invalidConfiguration,
      unsentReason: ChatUnsentReason.configurationRevoked);
}
