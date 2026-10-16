import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/backend_request_selection.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';

class WorkflowModelChoice {
  final WorkflowModelProfile profile;
  final String label;
  const WorkflowModelChoice(this.profile, this.label);
  String get key => profile.selectionKey;
}

/// 配置引用不采用 activeProvider 的兜底，不自动改换 provider/model。
class AgentWorkflowModels {
  final AgentWorkflowScope scope;
  final Future<AISettings> Function() _settings;
  final ChatService Function(AISettings) _create;
  final AISettings? Function()? _visibleSettings;
  final void Function()? _additionalVerify;
  final _rates = <String, UsageCostRate>{};
  final _preparedBackend = <String, Future<_PreparedWorkflowBackendChat>>{};
  final _readyBackend = <String, _PreparedWorkflowBackendChat>{};
  BackendSelectionBindingScope? _backendBindingScope;
  BackendRequestSelection? _backendRunGuard;
  BackendRequestSelection? _backendControlGuard;
  Object? _backendCaptureFailure;
  bool _backendUsed = false;
  static String _rateKey(WorkflowModelProfile p) => p.backendSelection == null
      ? '${p.mode}:${p.providerId}:${p.modelId}'
      : jsonEncode(p.toJson());
  double? estimateCost(WorkflowModelProfile profile, int input, int output) {
    final rate = _rates[_rateKey(profile)];
    return rate == null || rate.isZero
        ? null
        : rate.costFor(promptTokens: input, completionTokens: output);
  }

  AgentWorkflowModels(this.scope,
      {Future<AISettings> Function()? settings,
      ChatService Function(AISettings)? createService,
      AISettings? Function()? visibleSettings,
      void Function()? additionalVerify})
      : _additionalVerify = additionalVerify,
        _settings =
            settings ?? (() => AISettingsDao.loadForAsync(scope.accountHash)),
        _create = createService ?? ChatService.from,
        _visibleSettings = visibleSettings ??
            (() => AISettingsProvider.instance?.accountHash == scope.accountHash
                ? AISettingsProvider.instance!.settings
                : null);

  static List<WorkflowModelChoice> choices(AISettings settings,
      {AiCatalogIdentity? backendIdentity}) {
    final local = <WorkflowModelChoice>[
      for (final provider in settings.providers)
        if (provider.enabled)
          for (final model in provider.models)
            if (model.id.trim().isNotEmpty)
              WorkflowModelChoice(
                  WorkflowModelProfile('local', provider.id, model.id),
                  '${provider.name} · ${model.name}'),
    ];
    // 只有原身份的有归属清单用于声明 pair；不把硬编码/无归属旧缓存盖成当前选择。
    if (backendIdentity == null ||
        !backendIdentity.authenticated ||
        !backendIdentity.current) {
      return local;
    }
    final snapshot = ModelCatalog.displaySnapshot;
    if (!snapshot.hasSnapshot) {
      return local;
    }
    final counts = <String, int>{};
    for (final model in snapshot.options) {
      if (model.providerCode?.trim().isNotEmpty != true ||
          model.id.trim().isEmpty) {
        continue;
      }
      counts.update(model.pairKey, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      ...local,
      for (final model in snapshot.options)
        if (counts[model.pairKey] == 1)
          WorkflowModelChoice(
              WorkflowModelProfile.backend(BackendSelection.pair(
                  providerCode: model.providerCode!,
                  modelId: model.id,
                  accountHash: backendIdentity.account!,
                  origin: backendIdentity.endpoint.origin)),
              '后端代理 · ${model.backendLabel}'),
    ];
  }

  static AISettings forProfile(
      AISettings current, WorkflowModelProfile profile) {
    WorkflowModelProfile.fromJson(profile.toJson());
    // R2 只保存现代引用；旧 model-only transport 不能丢掉 provider 后发送。
    if (profile.backendSelection != null) {
      throw const WorkflowConfigurationMissing();
    }
    final settings = current.clone();
    if (profile.mode == 'backend') {
      if (profile.providerId != 'backend' ||
          !ModelCatalog.backendAll().any((m) => m.id == profile.modelId)) {
        throw const WorkflowConfigurationMissing();
      }
      settings.mode = AIMode.backend;
      settings.backendModel = profile.modelId;
    } else {
      final providers =
          settings.providers.where((p) => p.id == profile.providerId).toList();
      if (providers.length != 1 ||
          !providers.single.enabled ||
          providers.single.apiKey.trim().isEmpty ||
          !providers.single.models.any((m) => m.id == profile.modelId)) {
        throw const WorkflowConfigurationMissing();
      }
      settings.mode = AIMode.local;
      settings.activeProviderId = profile.providerId;
      settings.setActiveModel(profile.modelId);
    }
    settings.maxOutputTokens = WorkflowBudget.outputTokens;
    settings.webSearchEnabled = false;
    return settings;
  }

  // 摘要仅在当前请求内存中比较；不写日志/SQLite/备份，不保存凭据指纹。
  static String _signature(AISettings value) => workflowHash(jsonEncode({
        'mode': value.mode.name,
        'model': value.effectiveModel,
        if (value.mode == AIMode.local)
          'provider': value.activeProvider.toJson(),
        'temperature': value.temperature,
        'topP': value.topP,
        'reasoning': value.deepSeekReasoningEffort?.name,
      }));
  Future<AISettings> _load(WorkflowModelProfile p) async {
    scope.verify();
    _additionalVerify?.call();
    final AISettings current;
    try {
      current = await _settings();
    } on AISecretsUnavailableException {
      throw const WorkflowConfigurationMissing();
    }
    scope.verify();
    _additionalVerify?.call();
    final selected = forProfile(current, p);
    final visible = _visibleSettings?.call();
    if (visible != null &&
        _signature(forProfile(visible, p)) != _signature(selected)) {
      throw const WorkflowConfigurationMissing();
    }
    return selected;
  }

  Future<bool> available(WorkflowModelProfile p) async {
    try {
      await _load(p);
      return true;
    } on WorkflowConfigurationMissing {
      return false;
    }
  }

  Future<ChatService> service(WorkflowModelProfile p) async {
    final value = await _load(p);
    return _CurrentWorkflowChat(this, p, ChatService.capabilitiesFor(value));
  }

  /// 准备接点不解除普通 service/available 或 DAO 的现代执行阻断。
  /// 只接收已固定现代声明，旧任务须由完整父任务的 CAS 绑定路径处理。
  Future<ChatService> prepareBackend(WorkflowModelProfile profile,
      {Future<void>? abortTrigger}) async {
    scope.verify();
    _backendUsed = true;
    captureBackendScope();
    WorkflowModelProfile.fromJson(profile.toJson());
    final pair = profile.backendSelection;
    if (profile.mode != 'backend' || pair == null) {
      throw const WorkflowConfigurationMissing();
    }
    final key = jsonEncode(profile.toJson());
    final shared = _preparedBackend.putIfAbsent(key, () async {
      try {
        return await _prepareBackendOnce(profile);
      } on ChatTransportException {
        rethrow;
      } on WorkflowStale {
        rethrow;
      } catch (_) {
        throw const WorkflowConfigurationMissing();
      }
    });
    var cancelled = false;
    abortTrigger?.then<void>((_) => cancelled = true,
        onError: (Object _, StackTrace __) => cancelled = true);
    final prepared = abortTrigger == null
        ? await shared
        : await Future.any<_PreparedWorkflowBackendChat>([
            shared,
            abortTrigger.then<_PreparedWorkflowBackendChat>(
                (_) => throw const WorkflowStale('模型准备已取消'),
                onError: (Object _, StackTrace __) =>
                    throw const WorkflowStale('模型准备已取消'))
          ]);
    if (cancelled) throw const WorkflowStale('模型准备已取消');
    prepared.verify();
    _readyBackend[key] = prepared;
    return prepared;
  }

  /// 不知道节点模式时也先捕获；缺后端登录不改变本地任务的既有许可。
  void captureExecutionContext() {
    try {
      captureBackendScope();
    } catch (error) {
      _backendCaptureFailure ??= error;
    }
  }

  void verifyIdentityForControl() {
    if (!scope.identityCurrent) throw const WorkflowStale();
    if (_backendUsed) {
      if (_backendCaptureFailure != null) throw _backendCaptureFailure!;
      _backendControlGuard!.verify();
    }
  }

  void verifyOriginalScope() {
    scope.verify();
    _additionalVerify?.call();
    verifyIdentityForControl();
    if (_backendUsed) _backendRunGuard!.verify();
  }

  bool get originalScopeCurrent {
    try {
      verifyOriginalScope();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get originalIdentityCurrent {
    try {
      verifyIdentityForControl();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 整父任务在领取前准备完；legacy 没有可信原来源，不能按当前身份补签。
  Future<void> prepareWorkflow(List<WorkflowStep> steps,
      {Future<void>? abortTrigger}) async {
    scope.verify();
    if (steps.length != 3 ||
        !steps.map((s) => s.role).toSet().containsAll(WorkflowRole.values)) {
      throw const WorkflowConfigurationMissing();
    }
    for (final step in steps) {
      final p = step.profile;
      if (p.mode == 'backend') {
        if (p.backendSelection == null) {
          throw const WorkflowConfigurationMissing();
        }
        await prepareBackend(p, abortTrigger: abortTrigger);
      } else if (!await available(p)) {
        throw const WorkflowConfigurationMissing();
      }
      verifyOriginalScope();
    }
  }

  void verifyRunProfile(WorkflowModelProfile profile) {
    verifyOriginalScope();
    if (profile.mode != 'backend') return;
    if (profile.backendSelection == null) {
      throw const WorkflowConfigurationMissing();
    }
    final prepared = _readyBackend[jsonEncode(profile.toJson())];
    if (prepared == null) throw const WorkflowConfigurationMissing();
    prepared.verify();
  }

  Future<bool> availableForRun(WorkflowModelProfile profile) async {
    if (profile.mode != 'backend') return available(profile);
    try {
      verifyRunProfile(profile);
      return true;
    } on ChatTransportException {
      return false;
    } on WorkflowConfigurationMissing {
      return false;
    }
  }

  Future<ChatService> serviceForRun(WorkflowModelProfile profile) async {
    if (profile.mode != 'backend') return service(profile);
    verifyRunProfile(profile);
    return _readyBackend[jsonEncode(profile.toJson())]!;
  }

  /// 父运行可在任何初始化等待前调用；多个 pair 共享原身份而不共享模型许可。
  void captureBackendScope() {
    scope.verify();
    if (_backendCaptureFailure != null) throw _backendCaptureFailure!;
    if (_backendRunGuard == null) {
      final binding = BackendSelectionBindingScope.capture(scope);
      final seed = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = null
        ..backendModel = 'workflow-scope';
      _backendBindingScope = binding;
      _backendRunGuard = BackendRequestSelection(seed, scope: binding);
      // 停止操作只核最初身份；运行取消后不能重捕获新凭据替旧任务签名。
      _backendControlGuard = BackendRequestSelection(seed,
          scope: BackendSelectionBindingScope.capture(scope.fork()));
    }
    _backendRunGuard!.verify();
  }

  Future<_PreparedWorkflowBackendChat> _prepareBackendOnce(
      WorkflowModelProfile p) async {
    scope.verify();
    captureBackendScope();
    final seed = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = p.backendSelection
      ..backendModel = p.modelId;
    // 在任何设置等待前捕获原 token/storage/origin；后续不能借新身份构造 client。
    final guard = BackendRequestSelection(seed, scope: _backendBindingScope);
    final pair = await guard.prepare();
    guard.verify();
    final AISettings value;
    try {
      value = await _settings();
    } on AISecretsUnavailableException {
      throw const WorkflowConfigurationMissing();
    }
    scope.verify();
    _backendRunGuard!.verify();
    guard.verify();
    final fixed = value.clone()
      ..mode = AIMode.backend
      ..backendSelection = pair
      ..backendModel = pair.modelId!
      ..maxOutputTokens = WorkflowBudget.outputTokens
      ..webSearchEnabled = false;
    final client = _create(fixed);
    if (client is! BackendSelectionPreparingChatService ||
        client is! AttemptAwareChatService ||
        client is! OptionsAwareNonStreamingChatService ||
        client is! OptionsAwareChatService) {
      throw const WorkflowConfigurationMissing();
    }
    final selected = await (client as BackendSelectionPreparingChatService)
        .prepareBackendSelection();
    scope.verify();
    guard.verify();
    if (jsonEncode(selected.toSafeJson()) != jsonEncode(pair.toSafeJson())) {
      throw const WorkflowConfigurationMissing();
    }
    (client as BackendSelectionPreparingChatService)
        .verifyPreparedBackendSelection(pair);
    _rates[_rateKey(p)] = fixed.usageCostConfig.rateFor(
        providerId: backendUsageProviderId(pair),
        modelId: pair.modelId!,
        at: DateTime.now());
    return _PreparedWorkflowBackendChat(scope, guard, client, pair);
  }
}

/// 每个 pair 只有一个实际 transport；多个节点可共享准备，消息/context 仍由节点隔离。
class _PreparedWorkflowBackendChat
    implements
        ChatService,
        BackendSelectionPreparingChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  final AgentWorkflowScope scope;
  final BackendRequestSelection guard;
  final ChatService client;
  final BackendSelection pair;
  _PreparedWorkflowBackendChat(this.scope, this.guard, this.client, this.pair);
  void verify() {
    scope.verify();
    guard.verify();
    (client as BackendSelectionPreparingChatService)
        .verifyPreparedBackendSelection(pair);
  }

  @override
  ModelCapabilities get capabilities {
    verify();
    return client.capabilities;
  }

  @override
  Future<BackendSelection> prepareBackendSelection(
      {Future<void>? abortTrigger}) async {
    verify();
    final selected = await (client as BackendSelectionPreparingChatService)
        .prepareBackendSelection(abortTrigger: abortTrigger);
    verify();
    if (jsonEncode(selected.toSafeJson()) != jsonEncode(pair.toSafeJson())) {
      throw const WorkflowConfigurationMissing();
    }
    return pair;
  }

  @override
  void verifyPreparedBackendSelection(BackendSelection selected) {
    verify();
    if (jsonEncode(selected.toSafeJson()) != jsonEncode(pair.toSafeJson())) {
      throw const WorkflowConfigurationMissing();
    }
  }

  ChatRequestOptions options(ChatRequestOptions original) => ChatRequestOptions(
      profile: original.profile,
      reasoningPolicy: original.reasoningPolicy,
      deepSeekReasoningEffort: original.deepSeekReasoningEffort,
      abortTrigger: original.abortTrigger,
      connectTimeout: original.connectTimeout,
      nonStreamingTimeout: original.nonStreamingTimeout,
      minOutputTokens: original.minOutputTokens,
      suppressReasoningControl: original.suppressReasoningControl,
      maxOutputTokensOverride: original.maxOutputTokensOverride,
      onProgress: original.onProgress,
      maxAutoRetries: original.maxAutoRetries,
      retryBaseDelay: original.retryBaseDelay,
      maxRetryDelay: original.maxRetryDelay,
      onRetry: original.onRetry,
      messagesForAttempt: original.messagesForAttempt,
      dispatchIsCurrent: () {
        try {
          verify();
          return original.dispatchIsCurrent?.call() ?? true;
        } catch (_) {
          return false;
        }
      },
      beforeDispatch: (messages) async {
        verify();
        await original.beforeDispatch?.call(messages);
        verify();
      });
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    verify();
    final result = await client.chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: this.options(options));
    verify();
    return result;
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    verify();
    await for (final event in client.chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: this.options(options))) {
      verify();
      yield event;
    }
    verify();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 每个请求才读安全存储；最末发送前后校验同一配置，密钥变动时拒绝旧client。
class _CurrentWorkflowChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  final AgentWorkflowModels models;
  final WorkflowModelProfile profile;
  @override
  final ModelCapabilities capabilities;
  _CurrentWorkflowChat(this.models, this.profile, this.capabilities);
  Future<(ChatService, ChatRequestOptions)> _attempt(
      ChatRequestOptions options) async {
    final settings = await models._load(profile);
    models._rates['${profile.mode}:${profile.providerId}:${profile.modelId}'] =
        settings.usageCostConfig.rateFor(
            providerId: profile.providerId,
            modelId: profile.modelId,
            at: DateTime.now());
    final signature = AgentWorkflowModels._signature(settings);
    final service = models._create(settings);
    if (service is! AttemptAwareChatService) {
      throw const WorkflowConfigurationMissing();
    }
    Future<void> sameConfig() async {
      if (AgentWorkflowModels._signature(await models._load(profile)) !=
          signature) {
        throw const WorkflowConfigurationMissing();
      }
    }

    final guarded = ChatRequestOptions(
        profile: options.profile,
        reasoningPolicy: options.reasoningPolicy,
        deepSeekReasoningEffort: options.deepSeekReasoningEffort,
        abortTrigger: options.abortTrigger,
        connectTimeout: options.connectTimeout,
        minOutputTokens: options.minOutputTokens,
        suppressReasoningControl: options.suppressReasoningControl,
        maxOutputTokensOverride: options.maxOutputTokensOverride,
        onProgress: options.onProgress,
        maxAutoRetries: options.maxAutoRetries,
        retryBaseDelay: options.retryBaseDelay,
        maxRetryDelay: options.maxRetryDelay,
        onRetry: options.onRetry,
        messagesForAttempt: options.messagesForAttempt,
        dispatchIsCurrent: () =>
            models.scope.isCurrent &&
            (options.dispatchIsCurrent?.call() ?? true),
        beforeDispatch: (messages) async {
          await sameConfig();
          await options.beforeDispatch?.call(messages);
          try {
            await sameConfig();
          } on WorkflowConfigurationMissing {
            throw const ChatTransportException(
                safeCode: 'workflow_configuration_revoked_unsent',
                safeMessage: '配置已撤销，本次请求明确未发送',
                failureStage: ChatFailureStage.prepare,
                failureKind: ChatFailureKind.invalidConfiguration,
                unsentReason: ChatUnsentReason.configurationRevoked);
          }
        });
    return (service, guarded);
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    final (service, guarded) = await _attempt(options);
    if (service is! OptionsAwareNonStreamingChatService) {
      throw const WorkflowConfigurationMissing();
    }
    return service.chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: guarded);
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    final (service, guarded) = await _attempt(options);
    if (service is! OptionsAwareChatService) {
      throw const WorkflowConfigurationMissing();
    }
    yield* service.chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: guarded);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
