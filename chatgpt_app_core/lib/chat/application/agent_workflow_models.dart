import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';

class WorkflowModelChoice {
  final WorkflowModelProfile profile;
  final String label;
  const WorkflowModelChoice(this.profile, this.label);
  String get key => '${profile.mode}:${profile.providerId}:${profile.modelId}';
}

/// 配置引用不采用 activeProvider 的兜底，不自动改换 provider/model。
class AgentWorkflowModels {
  final AgentWorkflowScope scope;
  final Future<AISettings> Function() _settings;
  final ChatService Function(AISettings) _create;
  final AISettings? Function()? _visibleSettings;
  final _rates = <String, UsageCostRate>{};
  double? estimateCost(WorkflowModelProfile profile, int input, int output) {
    final rate =
        _rates['${profile.mode}:${profile.providerId}:${profile.modelId}'];
    return rate == null || rate.isZero
        ? null
        : rate.costFor(promptTokens: input, completionTokens: output);
  }

  AgentWorkflowModels(this.scope,
      {Future<AISettings> Function()? settings,
      ChatService Function(AISettings)? createService,
      AISettings? Function()? visibleSettings})
      : _settings =
            settings ?? (() => AISettingsDao.loadForAsync(scope.accountHash)),
        _create = createService ?? ChatService.from,
        _visibleSettings = visibleSettings ??
            (() => AISettingsProvider.instance?.accountHash == scope.accountHash
                ? AISettingsProvider.instance!.settings
                : null);

  static List<WorkflowModelChoice> choices(AISettings settings) => [
        for (final provider in settings.providers)
          if (provider.enabled)
            for (final model in provider.models)
              if (model.id.trim().isNotEmpty)
                WorkflowModelChoice(
                    WorkflowModelProfile('local', provider.id, model.id),
                    '${provider.name} · ${model.name}'),
        for (final model in ModelCatalog.backendAll())
          WorkflowModelChoice(
              WorkflowModelProfile('backend', 'backend', model.id),
              '后端代理 · ${model.displayLabel ?? model.id}'),
      ];

  static AISettings forProfile(
      AISettings current, WorkflowModelProfile profile) {
    WorkflowModelProfile.fromJson(profile.toJson());
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
    final AISettings current;
    try {
      current = await _settings();
    } on AISecretsUnavailableException {
      throw const WorkflowConfigurationMissing();
    }
    scope.verify();
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
