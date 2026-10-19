import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'knowledge_assistant.dart';
import 'knowledge_evidence.dart';
import 'knowledge_repository.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';

KnowledgeCompletion knowledgeRuntime(
        {required IKnowledgeRepository repository,
        HiDBManager? usageStorage,
        required AISettingsProvider settings,
        required String account,
        ChatService Function(AISettings)? transportFactory}) =>
    (
        {required prompt,
        required abort,
        required isCurrent,
        required beforeDispatch}) async {
      final selected = settings.settings.clone();
      final ready = resolveAIReadiness(
          settings: selected,
          isGuest: LoginDao.isGuest() || LoginDao.getBoardingPass() == null,
          accountHash: account,
          origin: BackendConfig.buildUri('/uapi').origin);
      if (ready.status == AIReadyStatus.needsSetup ||
          ready.status == AIReadyStatus.backendRequiresLogin) {
        throw const KnowledgeScopeException('请先在 AI 服务设置中配置可用模型；后端模式需要登录');
      }
      final scope = ConversationGenerationScope(
          account: account,
          currentAccount: () => LoginDao.getAccountHash() ?? 'guest');
      final profile = ConversationGenerationProfile(selected, account,
          additionalCurrent: isCurrent);
      final transport = (transportFactory ?? ChatService.from)(selected);
      Future<void> guard() async {
        if (!isCurrent()) throw const KnowledgeScopeException('本次提问已停止');
        await profile.verify(scope);
        await beforeDispatch();
      }

      await profile.prepareSelection(transport, scope, abort);
      await guard();
      final result = await transport.chatWithUsageWithOptions(
          prompt: prompt,
          history: const [
            {'role': 'system', 'content': KnowledgeAnswerVerifier.systemPrompt}
          ],
          options: ChatRequestOptions(
              abortTrigger: abort,
              maxAutoRetries: 0,
              nonStreamingTimeout: const Duration(minutes: 2),
              maxOutputTokensOverride: 2048,
              beforeDispatch: (_) => guard(),
              dispatchIsCurrent: () => isCurrent() && scope.isCurrent));
      await guard();
      final usage = UsageRecordService(await UsageDao.create(
          usageStorage ?? (repository as KnowledgeRepository).storage));
      await scope.stable(() async {
        await guard();
        await usage.recordTurn(
            modelId: profile.modelId,
            providerId: profile.usageProviderId,
            projectId: null,
            cid: null,
            prompt: '${KnowledgeAnswerVerifier.systemPrompt}\n$prompt',
            completion: result.content ?? '',
            promptTokens: result.promptTokens,
            cachedPromptTokens: result.cachedPromptTokens,
            completionTokens: result.completionTokens,
            estimated: result.estimated,
            cost: result.cost,
            costConfig: selected.usageCostConfig,
            createdAt: DateTime.now().millisecondsSinceEpoch);
      });
      return KnowledgeModelResult(profile.modelId, result);
    };
