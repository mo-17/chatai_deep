import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 参数固定为发送时副本；只切全局当前模型不会改变或撤销原运行。
class ConversationGenerationProfile {
  final AISettings _settings;
  AISettings get settings => _settings.clone();
  final String account;
  final bool Function()? additionalCurrent;
  final String? _loginToken = _token();
  final String _accountOrigin = BackendConfig.buildUri('/uapi').origin;
  static String? _token() {
    try {
      return LoginDao.getBoardingPass();
    } catch (_) {
      return null;
    }
  }

  bool get originalLoginCurrent =>
      _token() == _loginToken &&
      BackendConfig.buildUri('/uapi').origin == _accountOrigin;
  final String _localProviderId;
  final String _originalModelId;
  BackendSelection? _preparedPair;
  String get providerId => _settings.mode == AIMode.local
      ? _localProviderId
      : _preparedPair?.providerCode ?? 'backend';
  String get usageProviderId =>
      _settings.mode == AIMode.local || _preparedPair == null
          ? providerId
          : backendUsageProviderId(_preparedPair!);
  String get modelId => _preparedPair?.modelId ?? _originalModelId;
  BackendSelection? get backendSelection => _preparedPair;
  final String _key, _endpoint;
  final Future<AISettings> Function() loadSettings;
  final AISettings? Function() visibleSettings;
  ConversationGenerationProfile(
    AISettings selected,
    this.account, {
    this.additionalCurrent,
    Future<AISettings> Function()? loadSettings,
    AISettings? Function()? visibleSettings,
  })  : _settings = selected.clone(),
        _localProviderId = selected.mode == AIMode.local
            ? (selected.activeProviderId.isEmpty
                ? selected.activeProvider.id
                : selected.activeProviderId)
            : 'backend',
        _originalModelId = selected.effectiveModel,
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

  /// 首次搜索/工具/模型派发前调用；结果仅绑定此运行，不保存或改写全局。
  Future<void> prepareSelection(ChatService transport,
      ConversationGenerationScope scope, Future<void> abortTrigger) async {
    scope.verify();
    if (_settings.mode != AIMode.backend) return;
    if (transport is! BackendSelectionPreparingChatService) throw _revoked();
    final pair = await scope.wait(
        (transport as BackendSelectionPreparingChatService)
            .prepareBackendSelection(abortTrigger: abortTrigger),
        abortTrigger);
    scope.verify();
    (transport as BackendSelectionPreparingChatService)
        .verifyPreparedBackendSelection(pair);
    if (!pair.matchesScope(
            accountHash: account, origin: Uri.parse(_endpoint).origin) ||
        (_preparedPair != null && _preparedPair!.pairKey != pair.pairKey)) {
      throw _revoked();
    }
    _preparedPair = pair;
    _settings.backendSelection = pair;
  }

  bool matches(AISettings current) {
    if (!originalLoginCurrent || additionalCurrent?.call() == false) {
      return false;
    }
    if (_settings.mode == AIMode.backend) {
      return BackendConfig.buildUri('/uapi/chat/completions').toString() ==
              _endpoint &&
          (_settings.backendSelection == null ||
              _settings.backendSelection!.matchesScope(
                  accountHash: account, origin: Uri.parse(_endpoint).origin)) &&
          ModelCatalog.backendProfileAvailable(modelId,
              account: account,
              providerCode: _settings.backendSelection?.providerCode);
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
