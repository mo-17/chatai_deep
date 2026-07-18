import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_finalizer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('TavernRoomImportFinalizer', () {
    late Database db;
    late HiDBManager storage;
    late StoryTemplateTranslationTaskDao taskDao;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      storage = HiDBManager.test(db);
      taskDao = await StoryTemplateTranslationTaskDao.create(storage);
      await StoryTemplateDao.create(storage);
      await StoryRoomDao.create(storage);
    });

    tearDown(() async => db.close());

    test('build creates a two-role bundle with complete room configuration',
        () {
      final payload = _twoRolePayload();

      final bundle = TavernRoomImportFinalizer.build(
        payload: payload,
        title: '中文房间',
        sourceTitle: 'source.zip',
        translated: true,
      );

      expect(bundle.hasRetainedOriginal, isFalse);
      expect(bundle.outputTemplate.id, isNull);
      expect(bundle.outputTemplate.title, '中文房间');
      expect(bundle.outputTemplate.sourceTitle, 'source.zip');
      expect(bundle.outputTemplate.translated, isTrue);
      final storedPayload =
          StoryRoomTemplatePayload.fromTemplate(bundle.outputTemplate);
      expect(storedPayload.toJson(), payload.toJson());

      expect(bundle.room.id, isNull);
      expect(bundle.room.title, '中文房间');
      expect(bundle.room.mode, StoryRoomMode.tavern);
      expect(bundle.room.promptConfigJson, payload.promptConfigJson);
      expect(bundle.room.quickRepliesJson, payload.quickRepliesJson);
      expect(bundle.room.regexScriptsJson, payload.regexScriptsJson);
      expect(bundle.room.tavernPresetJson, payload.tavernPresetJson);
      expect(bundle.room.temperature, payload.temperature);
      expect(bundle.room.topP, payload.topP);
      expect(bundle.room.maxOutputTokens, payload.maxOutputTokens);
      expect(bundle.participants.map((item) => item.name), ['Alice', 'Bob']);
      expect(bundle.participants.every((item) => item.roomId == 0), isTrue);
      expect(bundle.messages, hasLength(1));
      expect(bundle.messages.single.roomId, 0);
      expect(bundle.messages.single.speakerRole, 'system');
      expect(bundle.messages.single.content, payload.initialOpening);
    });

    test('coordinator snapshots Tavern import kind, source and model',
        () async {
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.backend,
        modelId: 'fast-backend-model',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );

      await coordinator.startTavernRoomImport(
        _twoRolePayload().results,
        sourceTitle: 'party.zip',
        initialOpening: 'Selected opening',
        requestProfile: profile,
        resolveExecutor: (_) {
          throw const TranslationModelUnavailableException('测试暂停');
        },
      );
      await _waitUntil(() =>
          coordinator.tasks.single.status ==
          StoryTemplateTranslationTaskStatus.needsConfiguration);

      final task = (await taskDao.getTasks()).single;
      expect(task.taskKind, StoryTemplateTranslationTaskKind.tavernRoomImport);
      expect(task.sourceTitle, 'party.zip');
      expect(task.roleTotal, 2);
      final storedPayload = StoryRoomTemplatePayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(task.sourcePayload) as Map),
      );
      expect(storedPayload.results, hasLength(2));
      expect(storedPayload.initialOpening, 'Selected opening');
      expect(
        TranslationRequestProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(task.requestProfile) as Map),
        ).modelId,
        'fast-backend-model',
      );
    });

    test('runner atomically finalizes a translated Tavern room task', () async {
      final payload = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice', prompt: 'Careful.'),
        ),
      ]);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'alice.png',
        sourcePayload: jsonEncode(payload.toJson()),
        outputTitle: 'Alice（简中）',
        taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
      );
      await taskDao.saveTask(task);
      const owner = 'runner-tavern';
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: owner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: await StoryTemplateDao.create(storage),
        task: task,
        leaseOwner: owner,
        complete: (_) async => jsonEncode({
          'name': '爱丽丝',
          'description': '谨慎的侦探',
          'prompt': '保持警觉。',
          'openingMessage': '',
          'exampleDialogs': '',
          'memoryBook': '',
        }),
        isCancelled: () => false,
      ).run();

      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(stored?.outputTemplateId, isNotNull);
      expect(stored?.outputRoomId, isNotNull);
      expect(stored?.stage, '已导入酒馆房间');
      expect(stored?.log, contains('酒馆房间已保存'));
      expect(await db.query('tb_story_template'), hasLength(1));
      expect(await db.query('tb_story_room'), hasLength(1));
      expect(await db.query('tb_story_participant'), hasLength(1));
    });

    test('full-envelope checkpoint is discarded during Tavern task recovery',
        () async {
      const marker = '# [chatai_deep.tavern_raw.v1] LEGACY_SENTINEL';
      final legacy = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: marker,
      );
      final poisoned = TranslationChunkCheckpoint(
        field: legacy.field,
        sourceHash: legacy.sourceHash,
        chunks: [
          for (final state in legacy.chunks)
            TranslationChunkState(
              chunk: state.chunk,
              status: TranslationChunkStatus.completed,
              translatedText: 'CORRUPTED_BASE64_TRANSLATION',
              attempts: 1,
              lastErrorKind: TranslationFailureKind.invalidOutput,
            ),
        ],
      );
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Gail', memoryBook: marker),
        ),
      ]);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'gail.png',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: '盖尔',
        taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
        fieldPayload: jsonEncode({
          'scope': 'role',
          'roleIndex': 0,
          'fields': {
            'name': '盖尔',
            'description': '',
            'prompt': '',
            'openingMessage': '',
            'exampleDialogs': '',
          },
        }),
        checkpointVersion: TranslationChunkCheckpoint.currentVersion,
        chunkPayload: jsonEncode({
          'version': TranslationChunkCheckpoint.currentVersion,
          'checkpoints': {'role:0:memoryBook': poisoned.toJson()},
        }),
      );
      await taskDao.saveTask(task);
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: 'runner-raw-recovery',
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final prompts = <String>[];

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: await StoryTemplateDao.create(storage),
        task: task,
        leaseOwner: 'runner-raw-recovery',
        useChunkCheckpoints: true,
        complete: (prompt) async {
          prompts.add(prompt);
          throw StateError('marker-only recovery must not call the model');
        },
        isCancelled: () => false,
      ).run();

      final stored = await taskDao.getTask(task.id!);
      final templates =
          await (await StoryTemplateDao.create(storage)).getTemplates();
      final output = StoryRoomTemplatePayload.fromTemplate(templates.single);
      expect(prompts, isEmpty);
      expect(output.results.single.assistant.memoryBook, marker);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(stored?.outputRoomId, isNotNull);
      expect(await db.query('tb_story_room'), hasLength(1));
    });

    test(
        'legacy raw memoryBook field checkpoint is retried with only visible body',
        () async {
      const prefix = '# [chatai_deep.tavern_raw.v1] ';
      const base64Sentinel = 'VU5JUVVFX1JBV19CQVNFNjRfU0VOVElORUw=';
      const marker = '$prefix$base64Sentinel';
      const body = 'key => Alice keeps a visible world-book note.';
      const corruptedField = '${prefix}CORRUPTED_RAW_FIELD_SENTINEL';
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(
            name: 'Alice',
            description: 'A careful detective.',
            prompt: 'Stay alert.',
            openingMessage: 'Hello there.',
            exampleDialogs: '<START>\nAlice: Hello',
            memoryBook: '$marker\n$body',
          ),
        ),
      ]);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'alice.png',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: '爱丽丝',
        taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
        fieldPayload: jsonEncode({
          'scope': 'role',
          'roleIndex': 0,
          'fields': {
            'name': '爱丽丝',
            'description': '一位谨慎的侦探。',
            'prompt': '保持警觉。',
            'openingMessage': '你好。',
            'exampleDialogs': '<START>\n爱丽丝：你好',
            'memoryBook': corruptedField,
          },
        }),
      );
      expect(task.chunkPayload, isEmpty);
      expect(task.partialPayload, isEmpty);
      await taskDao.saveTask(task);
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: 'runner-legacy-raw-field',
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final prompts = <String>[];

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: await StoryTemplateDao.create(storage),
        task: task,
        leaseOwner: 'runner-legacy-raw-field',
        useChunkCheckpoints: true,
        complete: (prompt) async {
          prompts.add(prompt);
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          expect(payload.keys, ['memoryBook']);
          expect(payload['memoryBook'], body);
          return jsonEncode({
            'memoryBook': 'key => 爱丽丝保留了一条可见的世界书记录。',
          });
        },
        isCancelled: () => false,
      ).run();

      final stored = await taskDao.getTask(task.id!);
      final templates =
          await (await StoryTemplateDao.create(storage)).getTemplates();
      final output = StoryRoomTemplatePayload.fromTemplate(templates.single);
      final memoryBook = output.results.single.assistant.memoryBook;
      expect(prompts, hasLength(1));
      expect(prompts.single, isNot(contains(prefix)));
      expect(prompts.single, isNot(contains(base64Sentinel)));
      expect(prompts.single, isNot(contains(corruptedField)));
      expect(memoryBook, startsWith('$marker\n'));
      expect(memoryBook, contains('爱丽丝保留了一条可见的世界书记录。'));
      expect(memoryBook, isNot(contains(corruptedField)));
      expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(stored?.fieldPayload, isEmpty);
      expect(stored?.outputRoomId, isNotNull);
      expect(await db.query('tb_story_room'), hasLength(1));
    });

    test('build preserves single and batch empty-opening semantics', () {
      final single = TavernRoomImportFinalizer.build(
        payload: StoryRoomTemplatePayload(
          results: [
            AssistantRoleCardImportResult(
              assistant: AssistantModel(
                name: 'Alice',
                openingMessage: '角色默认开场',
              ),
            ),
          ],
        ),
        title: '单角色',
        sourceTitle: 'single.png',
        translated: true,
      );
      final batch = TavernRoomImportFinalizer.build(
        payload: StoryRoomTemplatePayload(
          results: [
            AssistantRoleCardImportResult(
              assistant: AssistantModel(
                name: 'Alice',
                openingMessage: 'Alice 开场',
              ),
            ),
            AssistantRoleCardImportResult(
              assistant: AssistantModel(
                name: 'Bob',
                openingMessage: 'Bob 开场',
              ),
            ),
          ],
        ),
        title: '双角色',
        sourceTitle: 'batch.zip',
        translated: true,
      );

      expect(single.messages, isEmpty);
      expect(batch.messages, hasLength(1));
      expect(batch.messages.single.content, contains('【Alice】'));
      expect(batch.messages.single.content, contains('Alice 开场'));
      expect(batch.messages.single.content, contains('【Bob】'));
      expect(batch.messages.single.content, contains('Bob 开场'));
    });

    test('build rejects an empty role payload', () {
      expect(
        () => TavernRoomImportFinalizer.build(
          payload: const StoryRoomTemplatePayload(results: []),
          title: '空房间',
          sourceTitle: 'empty.zip',
          translated: true,
        ),
        throwsFormatException,
      );
    });

    test('repeated completion reuses one template and one room graph',
        () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final task = await _claimedTask(
        taskDao,
        payload: _twoRolePayload(),
        leaseOwner: 'runner-a',
        now: now,
      );
      final bundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '中文房间',
        sourceTitle: 'source.zip',
        translated: true,
      );

      final first = await taskDao.completeWithTavernRoom(
        task,
        bundle: bundle,
        leaseOwner: 'runner-a',
        now: now,
      );
      final resumedTask = (await taskDao.getTask(task.id!))!;
      final resumedBundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '中文房间',
        sourceTitle: 'source.zip',
        translated: true,
      );
      final second = await taskDao.completeWithTavernRoom(
        resumedTask,
        bundle: resumedBundle,
        leaseOwner: 'runner-a',
        now: now.add(const Duration(minutes: 10)),
      );

      expect(first, isNotNull);
      expect(second?.outputTemplateId, first?.outputTemplateId);
      expect(second?.outputRoomId, first?.outputRoomId);
      expect(await db.query('tb_story_template'), hasLength(1));
      expect(await db.query('tb_story_room'), hasLength(1));
      expect(await db.query('tb_story_participant'), hasLength(2));
      expect(await db.query('tb_story_message'), hasLength(1));
      expect(bundle.outputTemplate.id, first?.outputTemplateId);
      expect(bundle.room.id, first?.outputRoomId);
      expect(resumedBundle.outputTemplate.id, first?.outputTemplateId);
      expect(resumedBundle.room.id, first?.outputRoomId);
      expect(task.outputTemplateId, first?.outputTemplateId);
      expect(task.outputRoomId, first?.outputRoomId);
      expect(task.status, StoryTemplateTranslationTaskStatus.completed);
      expect(task.leaseOwner, isNull);
      expect(task.leaseUntil, isNull);
      expect(task.nextRunAt, isNull);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.outputTemplateId, first?.outputTemplateId);
      expect(stored?.outputRoomId, first?.outputRoomId);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
    });

    test('wrong owner and expired lease perform zero output writes', () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final wrongOwnerTask = await _claimedTask(
        taskDao,
        payload: _twoRolePayload(),
        leaseOwner: 'runner-a',
        now: now,
      );
      final wrongOwnerBundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '错误 owner',
        sourceTitle: 'wrong-owner.zip',
        translated: true,
      );

      final wrongOwner = await taskDao.completeWithTavernRoom(
        wrongOwnerTask,
        bundle: wrongOwnerBundle,
        leaseOwner: 'runner-b',
        now: now,
      );
      expect(wrongOwner, isNull);

      final expiredTask = await _claimedTask(
        taskDao,
        payload: _twoRolePayload(),
        leaseOwner: 'runner-expired',
        now: now,
      );
      final expiredBundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '过期 lease',
        sourceTitle: 'expired.zip',
        translated: true,
      );
      final expired = await taskDao.completeWithTavernRoom(
        expiredTask,
        bundle: expiredBundle,
        leaseOwner: 'runner-expired',
        now: now.add(const Duration(minutes: 6)),
      );

      expect(expired, isNull);
      expect(await db.query('tb_story_template'), isEmpty);
      expect(await db.query('tb_story_room'), isEmpty);
      expect(await db.query('tb_story_participant'), isEmpty);
      expect(await db.query('tb_story_message'), isEmpty);
      expect(wrongOwnerBundle.outputTemplate.id, isNull);
      expect(wrongOwnerBundle.room.id, isNull);
      expect(expiredBundle.outputTemplate.id, isNull);
      expect(expiredBundle.room.id, isNull);
      final wrongOwnerStored = await taskDao.getTask(wrongOwnerTask.id!);
      final expiredStored = await taskDao.getTask(expiredTask.id!);
      expect(
          wrongOwnerStored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(wrongOwnerStored?.leaseOwner, 'runner-a');
      expect(expiredStored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(expiredStored?.leaseOwner, 'runner-expired');
    });

    test('wrong task kind cannot create Tavern outputs', () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '模板副本任务',
        sourcePayload: '{}',
        taskKind: StoryTemplateTranslationTaskKind.templateCopy,
      );
      await taskDao.saveTask(task);
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: 'runner-a',
          leaseDuration: const Duration(minutes: 5),
          now: now,
        ),
        isTrue,
      );
      final bundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '不应创建',
        sourceTitle: 'wrong-kind.zip',
        translated: true,
      );

      final completion = await taskDao.completeWithTavernRoom(
        task,
        bundle: bundle,
        leaseOwner: 'runner-a',
        now: now,
      );

      expect(completion, isNull);
      expect(await db.query('tb_story_template'), isEmpty);
      expect(await db.query('tb_story_room'), isEmpty);
      expect(await db.query('tb_story_participant'), isEmpty);
      expect(await db.query('tb_story_message'), isEmpty);
      expect(bundle.outputTemplate.id, isNull);
      expect(bundle.room.id, isNull);
    });

    test('Tavern task kind cannot complete through the template-only path',
        () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final task = await _claimedTask(
        taskDao,
        payload: _twoRolePayload(),
        leaseOwner: 'runner-tavern-kind',
        now: now,
      );
      final output = StoryTemplateModel(
        title: '不应创建的模板',
        sourceTitle: 'source.zip',
        translated: true,
        payload: '{"results":[]}',
      );

      final completion = await taskDao.completeWithTemplate(
        task,
        outputTemplate: output,
        leaseOwner: 'runner-tavern-kind',
        now: now,
      );

      expect(completion, isNull);
      expect(await db.query('tb_story_template'), isEmpty);
      expect(output.id, isNull);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(stored?.leaseOwner, 'runner-tavern-kind');
    });

    test('template completion preserves warning status and remains idempotent',
        () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '模板源',
        sourcePayload: '{}',
      );
      await taskDao.saveTask(task);
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: 'runner-template',
          leaseDuration: const Duration(minutes: 5),
          now: now,
        ),
        isTrue,
      );
      task.status = StoryTemplateTranslationTaskStatus.completedWithWarnings;
      final output = StoryTemplateModel(
        title: '部分翻译模板',
        sourceTitle: '模板源',
        translated: true,
        payload: '{"results":[]}',
      );

      final first = await taskDao.completeWithTemplate(
        task,
        outputTemplate: output,
        leaseOwner: 'runner-template',
        now: now,
      );
      final resumed = (await taskDao.getTask(task.id!))!;
      final second = await taskDao.completeWithTemplate(
        resumed,
        outputTemplate: StoryTemplateModel(
          title: '不应重复插入',
          sourceTitle: '模板源',
          translated: true,
          payload: '{"results":[]}',
        ),
        leaseOwner: 'runner-template',
        now: now.add(const Duration(hours: 1)),
      );

      expect(first, isNotNull);
      expect(second, first);
      expect(resumed.status,
          StoryTemplateTranslationTaskStatus.completedWithWarnings);
      expect(await db.query('tb_story_template'), hasLength(1));
    });

    test('template completion rollback leaves database and inputs unchanged',
        () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final seed = StoryTemplateTranslationTaskModel(
        sourceTitle: '事务回滚模板源',
        sourcePayload: '{}',
      );
      await taskDao.saveTask(seed);
      expect(
        await taskDao.claimTask(
          seed.id!,
          leaseOwner: 'runner-template-rollback',
          leaseDuration: const Duration(minutes: 5),
          now: now,
        ),
        isTrue,
      );
      final task = (await taskDao.getTask(seed.id!))!;
      final output = StoryTemplateModel(
        title: '不应保留的输出模板',
        sourceTitle: '事务回滚模板源',
        translated: true,
        payload: '{"results":[]}',
      );
      final taskBefore = Map<String, dynamic>.from(task.toJson());
      final outputBefore = Map<String, dynamic>.from(output.toJson());
      await db.execute('''
        create trigger fail_template_completion
        before update on tb_story_template_translation_task
        when NEW.outputTemplateId is not null
          or NEW.status in (
            '${StoryTemplateTranslationTaskStatus.completed}',
            '${StoryTemplateTranslationTaskStatus.completedWithWarnings}'
          )
        begin
          select raise(abort, 'forced template completion failure');
        end
      ''');

      await expectLater(
        taskDao.completeWithTemplate(
          task,
          outputTemplate: output,
          leaseOwner: 'runner-template-rollback',
          now: now,
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await db.query('tb_story_template'), isEmpty);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.toJson(), taskBefore);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(stored?.leaseOwner, 'runner-template-rollback');
      expect(stored?.leaseUntil, taskBefore['leaseUntil']);
      expect(stored?.updatedAt, taskBefore['updatedAt']);
      expect(task.toJson(), taskBefore);
      expect(output.toJson(), outputBefore);
    });

    for (final failingTable in [
      'tb_story_participant',
      'tb_story_message',
    ]) {
      test('$failingTable insertion failure rolls back every output and object',
          () async {
        final now = DateTime.utc(2026, 7, 17, 12);
        final task = await _claimedTask(
          taskDao,
          payload: _twoRolePayload(),
          leaseOwner: 'runner-a',
          now: now,
        );
        final bundle = TavernRoomImportFinalizer.build(
          payload: _twoRolePayload(),
          title: '必须回滚',
          sourceTitle: 'rollback.zip',
          translated: true,
        );
        final roomBefore = Map<String, dynamic>.from(bundle.room.toJson());
        final participantBefore = [
          for (final item in bundle.participants)
            Map<String, dynamic>.from(item.toJson()),
        ];
        final messageBefore = [
          for (final item in bundle.messages)
            Map<String, dynamic>.from(item.toJson()),
        ];
        await db.execute('''
          create trigger fail_tavern_graph
          before insert on $failingTable
          begin
            select raise(abort, 'forced tavern graph failure');
          end
        ''');

        await expectLater(
          taskDao.completeWithTavernRoom(
            task,
            bundle: bundle,
            leaseOwner: 'runner-a',
            now: now,
          ),
          throwsA(isA<DatabaseException>()),
        );

        expect(await db.query('tb_story_template'), isEmpty);
        expect(await db.query('tb_story_room'), isEmpty);
        expect(await db.query('tb_story_participant'), isEmpty);
        expect(await db.query('tb_story_message'), isEmpty);
        final stored = await taskDao.getTask(task.id!);
        expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
        expect(stored?.leaseOwner, 'runner-a');
        expect(stored?.outputTemplateId, isNull);
        expect(stored?.outputRoomId, isNull);
        expect(bundle.outputTemplate.id, isNull);
        expect(bundle.room.toJson(), roomBefore);
        expect(
          bundle.participants.map((item) => item.toJson()).toList(),
          participantBefore,
        );
        expect(
          bundle.messages.map((item) => item.toJson()).toList(),
          messageBefore,
        );
      });
    }

    test('retained originals complete once with a terminal warning status',
        () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      final task = await _claimedTask(
        taskDao,
        payload: _twoRolePayload(),
        leaseOwner: 'runner-a',
        now: now,
      );
      final bundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '部分翻译房间',
        sourceTitle: 'warnings.zip',
        translated: true,
        hasRetainedOriginal: true,
      );

      final first = await taskDao.completeWithTavernRoom(
        task,
        bundle: bundle,
        leaseOwner: 'runner-a',
        now: now,
      );
      final resumedTask = (await taskDao.getTask(task.id!))!;
      final resumedBundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '部分翻译房间',
        sourceTitle: 'warnings.zip',
        translated: true,
        hasRetainedOriginal: false,
      );
      final second = await taskDao.completeWithTavernRoom(
        resumedTask,
        bundle: resumedBundle,
        leaseOwner: 'runner-a',
        now: now.add(const Duration(hours: 1)),
      );

      expect(first, isNotNull);
      expect(second?.outputTemplateId, first?.outputTemplateId);
      expect(second?.outputRoomId, first?.outputRoomId);
      expect(resumedBundle.outputTemplate.id, first?.outputTemplateId);
      expect(resumedBundle.room.id, first?.outputRoomId);
      expect(resumedTask.status,
          StoryTemplateTranslationTaskStatus.completedWithWarnings);
      expect(task.status,
          StoryTemplateTranslationTaskStatus.completedWithWarnings);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status,
          StoryTemplateTranslationTaskStatus.completedWithWarnings);
      expect(stored?.isTerminal, isTrue);
      expect(stored?.canRetry, isFalse);
      expect(await db.query('tb_story_template'), hasLength(1));
      expect(await db.query('tb_story_room'), hasLength(1));
    });

    test('legacy saveTavernImport applies graph identities after commit',
        () async {
      final dao = await StoryRoomDao.create(storage);
      final bundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '旧入口',
        sourceTitle: 'legacy.zip',
        translated: false,
      );

      final roomId = await dao.saveTavernImport(
        room: bundle.room,
        participants: bundle.participants,
        messages: bundle.messages,
      );

      expect(bundle.room.id, roomId);
      expect(bundle.room.activeMessageKey, bundle.messages.single.nodeKey);
      expect(
        bundle.participants.every(
          (item) => item.id != null && item.roomId == roomId,
        ),
        isTrue,
      );
      expect(bundle.messages.single.id, isNotNull);
      expect(bundle.messages.single.roomId, roomId);
      expect(bundle.messages.single.speakerId, isNull);
    });

    test('legacy saveTavernImport leaves every graph object unchanged on error',
        () async {
      final dao = await StoryRoomDao.create(storage);
      final bundle = TavernRoomImportFinalizer.build(
        payload: _twoRolePayload(),
        title: '旧入口回滚',
        sourceTitle: 'legacy-rollback.zip',
        translated: false,
      );
      final roomBefore = Map<String, dynamic>.from(bundle.room.toJson());
      final participantBefore = [
        for (final item in bundle.participants)
          Map<String, dynamic>.from(item.toJson()),
      ];
      final messageBefore = [
        for (final item in bundle.messages)
          Map<String, dynamic>.from(item.toJson()),
      ];
      await db.execute('''
        create trigger fail_legacy_tavern_message
        before insert on tb_story_message
        begin
          select raise(abort, 'forced legacy Tavern failure');
        end
      ''');

      await expectLater(
        dao.saveTavernImport(
          room: bundle.room,
          participants: bundle.participants,
          messages: bundle.messages,
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await db.query('tb_story_room'), isEmpty);
      expect(await db.query('tb_story_participant'), isEmpty);
      expect(await db.query('tb_story_message'), isEmpty);
      expect(bundle.room.toJson(), roomBefore);
      expect(
        bundle.participants.map((item) => item.toJson()).toList(),
        participantBefore,
      );
      expect(
        bundle.messages.map((item) => item.toJson()).toList(),
        messageBefore,
      );
    });
  });
}

StoryRoomTemplatePayload _twoRolePayload() => StoryRoomTemplatePayload(
      results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(
            name: 'Alice',
            description: 'A careful detective.',
            prompt: 'Stay observant.',
            openingMessage: 'Good evening.',
          ),
          sourceName: 'alice.png',
        ),
        AssistantRoleCardImportResult(
          assistant: AssistantModel(
            name: 'Bob',
            description: 'A brave guide.',
            prompt: 'Protect the party.',
            openingMessage: 'Follow me.',
          ),
          sourceName: 'bob.png',
        ),
      ],
      initialOpening: '房间开场',
      promptConfigJson: '{"version":1,"modules":[]}',
      quickRepliesJson: '{"roomId":0,"groups":[]}',
      regexScriptsJson: '{"version":1,"rules":[]}',
      tavernPresetJson:
          '{"format":"chatai_deep_story_tavern_preset_bundle","formatVersion":1,"presets":{"context":{"story_string":"safe"}}}',
      temperature: 0.7,
      topP: 0.85,
      maxOutputTokens: 2048,
    );

Future<StoryTemplateTranslationTaskModel> _claimedTask(
  StoryTemplateTranslationTaskDao dao, {
  required StoryRoomTemplatePayload payload,
  required String leaseOwner,
  required DateTime now,
}) async {
  final task = StoryTemplateTranslationTaskModel(
    sourceTitle: 'source.zip',
    sourcePayload: jsonEncode(payload.toJson()),
    outputTitle: '中文房间',
    taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
  );
  await dao.saveTask(task);
  final claimed = await dao.claimTask(
    task.id!,
    leaseOwner: leaseOwner,
    leaseDuration: const Duration(minutes: 5),
    now: now,
  );
  expect(claimed, isTrue);
  return task;
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待异步任务状态超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
