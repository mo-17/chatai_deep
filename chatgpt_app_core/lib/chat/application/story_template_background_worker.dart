import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter/widgets.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';

/// 在系统后台 isolate 中恢复当前账号的酒馆模板翻译。
///
/// 只接收账号标识，不跨 isolate 传递 API Key、ChatService 或数据库对象。执行时
/// 重新初始化持久化层并校验登录账号，防止登出后旧任务访问另一个账号的数据。
Future<bool> runStoryTemplateTranslationBackgroundWork({
  required String accountHash,
  SecureKeyValueStore? secureStore,
}) async {
  final expectedAccount = accountHash.trim();
  if (expectedAccount.isEmpty) return true;

  WidgetsFlutterBinding.ensureInitialized();
  await LoginConfig.instance().init(
    homePage: const SizedBox.shrink(),
    tokenStorage: secureStore == null
        ? null
        : MigratingTokenStorage(
            secureStore: secureStore,
            readOnly: true,
          ),
  );
  AISettingsDao.configureSecretStore(secureStore);

  final currentAccount = LoginDao.getAccountHash();
  if (LoginDao.getBoardingPass() == null || currentAccount != expectedAccount) {
    return true;
  }

  final storage = await HiDBManager.instance(dbName: expectedAccount);
  final coordinator = StoryTemplateTranslationCoordinator.instance;
  await coordinator.initialize(storage, accountHash: expectedAccount);
  final settings = await AISettingsDao.loadForBackground(expectedAccount);
  await coordinator.resumeRecoverable(
    resolveLegacyRequestProfile: () =>
        TranslationModelResolver.legacyFallbackOrNull(
      settings,
      TranslationModelPreferenceStore().read(expectedAccount),
    ),
    resolveExecutor: (profile) => TranslationStreamExecutor(
      service: ChatService.from(
        TranslationModelResolver.apply(settings, profile),
      ),
      profile: profile,
    ),
  );

  // false 让 Android WorkManager 按退避策略重试，iOS 壳层会重新预约。
  // 活跃前台租约也继续保留一次系统唤醒，避免后台任务过早执行后，App 随即
  // 被杀导致没有后续恢复机会。明确失败/取消属于终态，不会无限请求。
  final now = DateTime.now().millisecondsSinceEpoch;
  return !coordinator.tasks.any(
    (task) =>
        task.status == StoryTemplateTranslationTaskStatus.queued ||
        task.status == StoryTemplateTranslationTaskStatus.running ||
        (task.status == StoryTemplateTranslationTaskStatus.retryable &&
            (task.nextRunAt == null || task.nextRunAt! <= now)),
  );
}
