import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/pages/backup_restore_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory resources;
  setUp(() async {
    resources = await Directory.systemTemp.createTemp(
      'backup-translation-lifecycle-',
    );
    BackupService.debugGeneratedImageDirectoryResolver = () async => resources;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => resources;
  });
  tearDown(() async {
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    if (await resources.exists()) await resources.delete(recursive: true);
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
        await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        ),
      );

  StoryTemplateTranslationTaskModel task(
    String name, {
    String status = StoryTemplateTranslationTaskStatus.queued,
  }) =>
      StoryTemplateTranslationTaskModel(
        sourceTitle: name,
        sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: name),
          ),
        ]).toJson()),
        outputTitle: '$name（简中）',
        status: status,
        requestProfile: jsonEncode(TranslationRequestProfile(
          mode: TranslationExecutionMode.local,
          providerId: 'provider-a',
          modelId: 'model-a',
          reasoningPolicy: ChatReasoningPolicy.providerDefault,
          reasoningControlSuppressed: false,
        ).toJson()),
      );

  test('覆盖恢复先停止旧 runner，完成后协调器只展示恢复任务', () async {
    final target = await newDb();
    final targetDao = await StoryTemplateTranslationTaskDao.create(target);
    final activeTask = task('恢复前运行任务');
    await targetDao.saveTask(activeTask);
    final coordinator = StoryTemplateTranslationCoordinator();
    await coordinator.initialize(target, accountHash: 'acc1');
    final held = _HeldTranslationChatService();
    final running = coordinator.resumeRecoverable(
      checkEligibility: _allowTranslationProfile,
      resolveExecutor: (profile) => TranslationStreamExecutor(
        service: held,
        profile: profile,
      ),
    );
    await held.requestStarted.future;

    final source = await newDb();
    final sourceDao = await StoryTemplateTranslationTaskDao.create(source);
    await sourceDao.saveTask(task(
      '备份中的恢复任务',
      status: StoryTemplateTranslationTaskStatus.failed,
    ));
    final archive = await BackupService(source).exportArchive(
      settings: AISettings.defaults(),
      accountHash: 'acc1',
    );
    await source.db.close();

    final restoring = runBackupImportWithTranslationTaskRebind(
      coordinator: coordinator,
      storage: target,
      accountHash: 'acc1',
      importAction: () => BackupService(target).importArchive(
        archive,
        accountHash: 'acc1',
      ),
    );
    expect(coordinator.tasks, isEmpty);
    final result = await restoring;
    await running;

    expect(result.storyTemplateTranslationTasks, 1);
    expect(await held.abortObserved.future, isTrue);
    expect(coordinator.tasks, hasLength(1));
    expect(coordinator.tasks.single.sourceTitle, '备份中的恢复任务');
    expect(
      coordinator.tasks.single.status,
      StoryTemplateTranslationTaskStatus.failed,
    );
    final rows = await target.db.query('tb_story_template_translation_task');
    expect(rows, hasLength(1));
    expect(rows.single['sourceTitle'], '备份中的恢复任务');
    await coordinator.detachForLifecycle();
    await target.db.close();
  });

  test('导入失败后也会重新绑定原账号任务快照', () async {
    final storage = await newDb();
    final dao = await StoryTemplateTranslationTaskDao.create(storage);
    await dao.saveTask(task(
      '原账号任务',
      status: StoryTemplateTranslationTaskStatus.failed,
    ));
    final coordinator = StoryTemplateTranslationCoordinator();
    await coordinator.initialize(storage, accountHash: 'acc1');

    await expectLater(
      runBackupImportWithTranslationTaskRebind<void>(
        coordinator: coordinator,
        storage: storage,
        accountHash: 'acc1',
        importAction: () async => throw StateError('restore failed'),
      ),
      throwsStateError,
    );

    expect(coordinator.tasks, hasLength(1));
    expect(coordinator.tasks.single.sourceTitle, '原账号任务');
    await coordinator.detachForLifecycle();
    await storage.db.close();
  });

  test('导入期间账号失配时保持 detached，交给新账号登录钩子重绑', () async {
    final storage = await newDb();
    final dao = await StoryTemplateTranslationTaskDao.create(storage);
    await dao.saveTask(task(
      '旧账号任务',
      status: StoryTemplateTranslationTaskStatus.failed,
    ));
    final coordinator = StoryTemplateTranslationCoordinator();
    await coordinator.initialize(storage, accountHash: 'old-account');

    await runBackupImportWithTranslationTaskRebind<void>(
      coordinator: coordinator,
      storage: storage,
      accountHash: 'old-account',
      importAction: () async {},
      shouldRebind: () => false,
    );

    expect(coordinator.tasks, isEmpty);
    await coordinator.detachForLifecycle();
    await storage.db.close();
  });
}

TranslationEligibilityResult _allowTranslationProfile(
  TranslationRequestProfile _,
) =>
    const TranslationEligibilityResult([]);

final class _HeldTranslationChatService
    implements ChatService, OptionsAwareChatService {
  final Completer<void> requestStarted = Completer<void>();
  final Completer<bool> abortObserved = Completer<bool>();
  late final StreamController<StreamEvent> _controller;

  @override
  ModelCapabilities get capabilities => const ModelCapabilities.none();

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) =>
      throw UnsupportedError('translation must use typed stream events');

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      throw UnsupportedError('translation must use typed stream events');

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      throw UnsupportedError('translation must use typed stream events');

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) =>
      throw UnsupportedError('translation must pass request options');

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) {
    _controller = StreamController<StreamEvent>(
      onListen: () => requestStarted.complete(),
    );
    options.abortTrigger?.then((_) {
      if (!abortObserved.isCompleted) abortObserved.complete(true);
    });
    return _controller.stream;
  }
}
