import 'dart:convert';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:login_sdk/config/login_sdk_config.dart';

/// 对话框打开时捕获；后续异步工作不能借当前账号重签旧选择。
class TranslationSelectionScope {
  final String accountHash;
  final String Function() currentAccount;
  final AiCatalogIdentity identity;
  final Object _storage;
  final int _restoreTick, _restoreRevision;
  TranslationSelectionScope(
      {required this.accountHash, required this.currentAccount})
      : identity = AiCatalogIdentity.capture(),
        _storage = LoginSdkConfig.instance.storage,
        _restoreTick = BackupService.restoreTick.value,
        _restoreRevision = BackupService.agentExecutionRevision;
  bool get accountCurrent => currentAccount() == accountHash;
  bool get backendCurrent =>
      accountCurrent &&
      identity.authenticated &&
      identity.account == accountHash &&
      identity.current &&
      identical(_storage, LoginSdkConfig.instance.storage) &&
      _restoreTick == BackupService.restoreTick.value &&
      _restoreRevision == BackupService.agentExecutionRevision;
  void verifyBackend() {
    if (!backendCurrent) {
      throw const TranslationModelUnavailableException(
          '账号、登录或后端来源已变化，请重新打开翻译设置',
          safeCode: 'backend_scope_changed');
    }
  }
}

/// 只比较选择来源；不包含凭据，不做 modelId 全局缓存。
String translationSelectionInputKey(
        AISettings settings, TranslationModelPreference preference) =>
    jsonEncode([
      preference.toJson(),
      if (preference.mode == TranslationModelPreferenceMode.followGlobal)
        settings.mode.name,
      if (preference.mode == TranslationModelPreferenceMode.followGlobal &&
          settings.mode == AIMode.backend)
        [
          settings.backendSelection?.toStorageJson(),
          settings.backendSelection == null ? settings.backendModel : null
        ],
    ]);

/// profile 和 transport 一源，仅本次新逻辑翻译使用。不会绑定旧已发送任务。
class TranslationSelectionSession {
  final TranslationSelectionScope scope;
  final String inputKey;
  final TranslationModelPreference sourcePreference;
  final AISettings settings;
  final TranslationRequestProfile profile;
  final TranslationStreamExecutor executor;
  final ChatService _transport;
  TranslationSelectionSession._(
      {required this.scope,
      required this.inputKey,
      required this.sourcePreference,
      required this.settings,
      required this.profile,
      required this.executor,
      required ChatService transport})
      : _transport = transport;
  bool get isCurrent =>
      scope.backendCurrent &&
      ModelCatalog.backendProfileAvailable(profile.modelId,
          account: scope.accountHash,
          providerCode: profile.backendSelection?.providerCode);
  void verify() {
    scope.verifyBackend();
    if (!isCurrent) {
      throw const TranslationModelUnavailableException('所选模型已删除或停用，请重新选择',
          safeCode: 'model_unavailable');
    }
  }

  static Future<TranslationSelectionSession> prepare(
      {required TranslationSelectionScope scope,
      required AISettings settings,
      required TranslationModelPreference preference,
      required TranslationRequestProfile profile,
      required TranslationCancellationToken cancellation}) async {
    scope.verifyBackend();
    final captured = settings.clone();
    final key = translationSelectionInputKey(captured, preference);
    final transport =
        ChatService.from(TranslationModelResolver.apply(captured, profile));
    final executor =
        TranslationStreamExecutor(service: transport, profile: profile);
    final fixed = await executor.prepare(cancellation: cancellation);
    scope.verifyBackend();
    final session = TranslationSelectionSession._(
        scope: scope,
        inputKey: key,
        sourcePreference: preference,
        settings: captured,
        profile: fixed,
        executor: executor,
        transport: transport);
    session.verify();
    return session;
  }

  /// 缓存仅改变已批准的 reasoning suppression；复用同一个实际 transport，零二次解析。
  Future<TranslationSelectionSession> withEvidence(
      TranslationRequestProfile evidenced,
      TranslationCancellationToken cancellation) async {
    verify();
    if (evidenced.backendSelection?.pairKey !=
            profile.backendSelection?.pairKey ||
        evidenced.modelId != profile.modelId ||
        evidenced.reasoningPolicy != profile.reasoningPolicy) {
      throw const TranslationModelUnavailableException('翻译配置已变化，请重新确认',
          safeCode: 'configurationChanged');
    }
    if (evidenced.reasoningControlSuppressed ==
        profile.reasoningControlSuppressed) {
      return this;
    }
    final next =
        TranslationStreamExecutor(service: _transport, profile: evidenced);
    final fixed = await next.prepare(cancellation: cancellation);
    verify();
    return TranslationSelectionSession._(
        scope: scope,
        inputKey: inputKey,
        sourcePreference: sourcePreference,
        settings: settings,
        profile: fixed,
        executor: next,
        transport: _transport);
  }
}
