import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('StoryTemplateTransfer', () {
    test('导出后可导入并保留角色完整编辑字段与头像引用', () {
      final template = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(
              name: 'Alice',
              description: '侦探',
              prompt: '保持冷静',
              avatarType: 'image',
              avatarValue: '/avatars/alice.png',
              openingMessage: '晚上好。',
              exampleDialogs: 'Alice: 我会查清真相。',
              memoryBook: '案件 => 雨夜的旧报纸。',
            ),
          ),
        ],
        initialOpening: '房间开场',
        promptConfigJson: '{"version":1,"modules":[]}',
        quickRepliesJson: '{"roomId":0,"groups":[]}',
        regexScriptsJson: '{"version":1,"rules":[]}',
        tavernPresetJson:
            '{"format":"chatai_deep_story_tavern_preset_bundle","formatVersion":1,"presets":{"context":{"story_string":"safe"}}}',
        temperature: 0.65,
        topP: 0.88,
        maxOutputTokens: 2048,
      ).toTemplate(title: '午夜案件', sourceTitle: '来源', translated: true);

      final restored = StoryTemplateTransfer.importJson(
        StoryTemplateTransfer.exportJson(template),
      );
      final payload = StoryRoomTemplatePayload.fromTemplate(restored);
      final assistant = payload.results.single.assistant;

      expect(restored.title, '午夜案件');
      expect(restored.translated, isTrue);
      expect(payload.initialOpening, '房间开场');
      expect(payload.promptConfigJson, '{"version":1,"modules":[]}');
      expect(payload.quickRepliesJson, '{"roomId":0,"groups":[]}');
      expect(payload.regexScriptsJson, '{"version":1,"rules":[]}');
      expect(payload.tavernPresetJson, contains('tavern_preset_bundle'));
      expect(payload.temperature, 0.65);
      expect(payload.topP, 0.88);
      expect(payload.maxOutputTokens, 2048);
      expect(assistant.name, 'Alice');
      expect(assistant.description, '侦探');
      expect(assistant.prompt, '保持冷静');
      expect(assistant.avatarValue, '/avatars/alice.png');
      expect(assistant.openingMessage, '晚上好。');
      expect(assistant.exampleDialogs, contains('查清真相'));
      expect(assistant.memoryBook, contains('旧报纸'));
    });

    test('拒绝错误格式和较新格式版本', () {
      expect(
        () => StoryTemplateTransfer.importJson('{"format":"other"}'),
        throwsFormatException,
      );
      expect(
        () => StoryTemplateTransfer.importJson(jsonEncode({
          'format': StoryTemplateTransfer.format,
          'formatVersion': 2,
          'template': const {},
        })),
        throwsFormatException,
      );
    });

    test('模板 payload 会重新清洗预设并拒绝越界采样值', () {
      final payload = StoryRoomTemplatePayload.fromJson({
        'results': [
          {
            'assistant': AssistantModel(name: 'Alice').toJson(),
          },
        ],
        'tavernPresetJson': jsonEncode({
          'format': 'chatai_deep_story_tavern_preset_bundle',
          'formatVersion': 1,
          'presets': {
            'openai': {
              'prompts': [],
              'prompt_order': [],
              'api_key': 'secret',
            },
          },
        }),
        'temperature': 9,
        'topP': 2,
        'maxOutputTokens': -1,
      });

      expect(payload.tavernPresetJson, isNot(contains('secret')));
      expect(payload.temperature, isNull);
      expect(payload.topP, isNull);
      expect(payload.maxOutputTokens, isNull);
    });

    test('重名模板追加稳定序号', () {
      expect(
        StoryTemplateTransfer.uniqueTitle('酒馆', ['酒馆', '酒馆 (2)']),
        '酒馆 (3)',
      );
    });
  });

  group('StoryTemplateTranslationTaskDao', () {
    late Database db;
    late HiDBManager storage;
    late StoryTemplateTranslationTaskDao taskDao;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      storage = HiDBManager.test(db);
      taskDao = await StoryTemplateTranslationTaskDao.create(storage);
    });

    tearDown(() async {
      await db.close();
    });

    test('重启后运行中的任务恢复为可重试并保留检查点', () async {
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '旧模板',
        sourcePayload: '{}',
        status: StoryTemplateTranslationTaskStatus.running,
        roleIndex: 1,
        roleTotal: 3,
        roleName: 'Bob',
        fieldIndex: 2,
        fieldTotal: 6,
        fieldLabel: '人设',
        log: '翻译中',
      );
      final id = await taskDao.saveTask(task);

      await taskDao.recoverInterruptedTasks();
      final restored = await taskDao.getTask(id);

      expect(restored?.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(restored?.roleIndex, 1);
      expect(restored?.fieldLabel, '人设');
      expect(restored?.detail, contains('角色 1/3'));
      expect(restored?.log, contains('可重试'));
    });

    test('旧任务表会 guarded ALTER 新增租约、字段快照和新检查点列', () async {
      await db.execute('drop table tb_story_template_translation_task');
      await db.execute(
        'create table tb_story_template_translation_task ('
        'id integer primary key autoincrement, '
        'templateId integer, sourceTitle text, sourcePayload text, outputTitle text, '
        'outputTemplateId integer, status text, progress real, stage text, detail text, '
        'log text, error text, roleIndex integer, roleTotal integer, roleName text, '
        'fieldIndex integer, fieldTotal integer, fieldLabel text, fieldProgress real, '
        'partialPayload text, createdAt integer, updatedAt integer)',
      );
      taskDao = await StoryTemplateTranslationTaskDao.create(storage);
      final columns = await db
          .rawQuery('pragma table_info(tb_story_template_translation_task)');
      final names = columns.map((column) => column['name']).toSet();

      expect(
          names,
          containsAll([
            'fieldPayload',
            'leaseOwner',
            'leaseUntil',
            'attempts',
            'nextRunAt',
            'taskKind',
            'requestProfile',
            'chunkPayload',
            'outputRoomId',
            'checkpointVersion',
          ]));
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '兼容旧库',
        sourcePayload: '{}',
        fieldPayload: '{"field":"value"}',
        attempts: 3,
      );
      await taskDao.saveTask(task);
      final saved = await taskDao.getTask(task.id!);
      expect(saved?.fieldPayload, '{"field":"value"}');
      expect(saved?.attempts, 3);
    });

    test('旧表迁移会回填任务类型和检查点版本且保留原字段', () async {
      await db.execute('drop table tb_story_template_translation_task');
      await db.execute(
        'create table tb_story_template_translation_task ('
        'id integer primary key autoincrement, '
        'templateId integer, sourceTitle text, sourcePayload text, outputTitle text, '
        'outputTemplateId integer, status text, progress real, stage text, detail text, '
        'log text, error text, roleIndex integer, roleTotal integer, roleName text, '
        'fieldIndex integer, fieldTotal integer, fieldLabel text, fieldProgress real, '
        'fieldPayload text, partialPayload text, leaseOwner text, leaseUntil integer, '
        'attempts integer default 0, nextRunAt integer, createdAt integer, updatedAt integer)',
      );
      final legacyId = await db.insert('tb_story_template_translation_task', {
        'templateId': 17,
        'sourceTitle': '旧模板',
        'sourcePayload': '{"source":true}',
        'outputTitle': '中文副本',
        'outputTemplateId': 23,
        'status': StoryTemplateTranslationTaskStatus.retryable,
        'progress': 0.4,
        'stage': '旧阶段',
        'detail': '旧详情',
        'log': '旧日志',
        'error': '旧错误',
        'roleIndex': 1,
        'roleTotal': 2,
        'roleName': 'Alice',
        'fieldIndex': 3,
        'fieldTotal': 5,
        'fieldLabel': '人设',
        'fieldProgress': 0.6,
        'fieldPayload': '{"field":"snapshot"}',
        'partialPayload': '{"partial":true}',
        'leaseOwner': 'legacy-runner',
        'leaseUntil': 123456,
        'attempts': 4,
        'nextRunAt': 234567,
        'createdAt': 1000,
        'updatedAt': 2000,
      });

      taskDao = await StoryTemplateTranslationTaskDao.create(storage);

      final migrated = await taskDao.getTask(legacyId);
      expect(migrated?.taskKind, StoryTemplateTranslationTaskKind.templateCopy);
      expect(migrated?.requestProfile, isEmpty);
      expect(migrated?.chunkPayload, isEmpty);
      expect(migrated?.outputRoomId, isNull);
      expect(migrated?.checkpointVersion, 0);
      expect(migrated?.templateId, 17);
      expect(migrated?.sourceTitle, '旧模板');
      expect(migrated?.sourcePayload, '{"source":true}');
      expect(migrated?.outputTemplateId, 23);
      expect(migrated?.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(migrated?.progress, 0.4);
      expect(migrated?.fieldPayload, '{"field":"snapshot"}');
      expect(migrated?.partialPayload, '{"partial":true}');
      expect(migrated?.leaseOwner, 'legacy-runner');
      expect(migrated?.attempts, 4);

      final columns = await db
          .rawQuery('pragma table_info(tb_story_template_translation_task)');
      final types = {
        for (final column in columns)
          column['name'] as String:
              (column['type'] as String? ?? '').toLowerCase(),
      };
      expect(types['taskKind'], 'text');
      expect(types['requestProfile'], 'text');
      expect(types['chunkPayload'], 'text');
      expect(types['outputRoomId'], 'integer');
      expect(types['checkpointVersion'], 'integer');

      final raw = (await db.rawQuery(
        'select taskKind, requestProfile, chunkPayload, outputRoomId, '
        'checkpointVersion, typeof(requestProfile) as requestProfileType, '
        'typeof(chunkPayload) as chunkPayloadType, '
        'typeof(outputRoomId) as outputRoomIdType '
        'from tb_story_template_translation_task where id = ?',
        [legacyId],
      ))
          .single;
      expect(raw['taskKind'], StoryTemplateTranslationTaskKind.templateCopy);
      expect(raw['requestProfile'], isNull);
      expect(raw['chunkPayload'], isNull);
      expect(raw['outputRoomId'], isNull);
      expect(raw['checkpointVersion'], 0);
      expect(raw['requestProfileType'], 'null');
      expect(raw['chunkPayloadType'], 'null');
      expect(raw['outputRoomIdType'], 'null');

      await db.update(
        'tb_story_template_translation_task',
        {'taskKind': '   ', 'checkpointVersion': null},
        where: 'id = ?',
        whereArgs: [legacyId],
      );
      taskDao = await StoryTemplateTranslationTaskDao.create(storage);
      final backfilled = await taskDao.getTask(legacyId);
      final backfilledRaw = (await db.query(
        'tb_story_template_translation_task',
        columns: ['taskKind', 'checkpointVersion'],
        where: 'id = ?',
        whereArgs: [legacyId],
      ))
          .single;
      expect(
        backfilledRaw['taskKind'],
        StoryTemplateTranslationTaskKind.templateCopy,
      );
      expect(backfilledRaw['checkpointVersion'], 0);
      expect(
        backfilled?.taskKind,
        StoryTemplateTranslationTaskKind.templateCopy,
      );
      expect(backfilled?.checkpointVersion, 0);
      expect(backfilled?.fieldPayload, '{"field":"snapshot"}');
      expect(backfilled?.partialPayload, '{"partial":true}');
    });

    test('新任务字段可通过 JSON 和 DAO 完整往返', () async {
      final original = StoryTemplateTranslationTaskModel(
        templateId: 9,
        sourceTitle: '酒馆导入',
        sourcePayload: '{"source":true}',
        outputTitle: '新房间',
        taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
        requestProfile: '{"provider":"openai","model":"gpt-test"}',
        chunkPayload: '{"chunks":[{"id":"role:0:name"}]}',
        outputRoomId: 42,
        checkpointVersion: 3,
        fieldPayload: '{"legacyField":"kept"}',
        partialPayload: '{"legacyPartial":"kept"}',
      );

      final decoded = StoryTemplateTranslationTaskModel.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(
        decoded.taskKind,
        StoryTemplateTranslationTaskKind.tavernRoomImport,
      );
      expect(
        decoded.requestProfile,
        '{"provider":"openai","model":"gpt-test"}',
      );
      expect(decoded.chunkPayload, '{"chunks":[{"id":"role:0:name"}]}');
      expect(decoded.outputRoomId, 42);
      expect(decoded.checkpointVersion, 3);
      expect(decoded.fieldPayload, '{"legacyField":"kept"}');
      expect(decoded.partialPayload, '{"legacyPartial":"kept"}');

      await taskDao.saveTask(decoded);
      final saved = await taskDao.getTask(decoded.id!);
      expect(
        saved?.taskKind,
        StoryTemplateTranslationTaskKind.tavernRoomImport,
      );
      expect(
        saved?.requestProfile,
        '{"provider":"openai","model":"gpt-test"}',
      );
      expect(saved?.chunkPayload, '{"chunks":[{"id":"role:0:name"}]}');
      expect(saved?.outputRoomId, 42);
      expect(saved?.checkpointVersion, 3);
      expect(saved?.fieldPayload, '{"legacyField":"kept"}');
      expect(saved?.partialPayload, '{"legacyPartial":"kept"}');

      final raw = (await db.rawQuery(
        'select typeof(taskKind) as taskKindType, '
        'typeof(requestProfile) as requestProfileType, '
        'typeof(chunkPayload) as chunkPayloadType, '
        'typeof(outputRoomId) as outputRoomIdType, '
        'typeof(checkpointVersion) as checkpointVersionType '
        'from tb_story_template_translation_task where id = ?',
        [decoded.id],
      ))
          .single;
      expect(raw['taskKindType'], 'text');
      expect(raw['requestProfileType'], 'text');
      expect(raw['chunkPayloadType'], 'text');
      expect(raw['outputRoomIdType'], 'integer');
      expect(raw['checkpointVersionType'], 'integer');

      final defaults = StoryTemplateTranslationTaskModel.fromJson({
        'sourceTitle': '默认值',
        'sourcePayload': '{}',
      });
      expect(defaults.taskKind, StoryTemplateTranslationTaskKind.templateCopy);
      expect(defaults.requestProfile, isEmpty);
      expect(defaults.chunkPayload, isEmpty);
      expect(defaults.outputRoomId, isNull);
      expect(defaults.checkpointVersion, 0);
    });

    test('任务状态保留旧语义并表达待配置和带警告完成', () {
      final cases = <(String, String, bool, bool)>[
        (StoryTemplateTranslationTaskStatus.queued, '等待中', false, false),
        (StoryTemplateTranslationTaskStatus.running, '运行中', false, false),
        (StoryTemplateTranslationTaskStatus.retryable, '可重试', true, false),
        (StoryTemplateTranslationTaskStatus.completed, '已完成', false, true),
        (StoryTemplateTranslationTaskStatus.failed, '失败', true, true),
        (StoryTemplateTranslationTaskStatus.cancelled, '已取消', true, true),
        (
          StoryTemplateTranslationTaskStatus.needsConfiguration,
          '需要配置',
          true,
          false,
        ),
        (
          StoryTemplateTranslationTaskStatus.completedWithWarnings,
          '部分翻译完成',
          false,
          true,
        ),
      ];

      for (final (status, label, canRetry, isTerminal) in cases) {
        expect(StoryTemplateTranslationTaskStatus.labelOf(status), label);
        expect(StoryTemplateTranslationTaskStatus.canRetry(status), canRetry);
        expect(
          StoryTemplateTranslationTaskStatus.isTerminal(status),
          isTerminal,
        );
        final task = StoryTemplateTranslationTaskModel(
          sourceTitle: status,
          sourcePayload: '{}',
          status: status,
        );
        expect(task.canRetry, canRetry);
        expect(task.isTerminal, isTerminal);
      }
    });

    test('待配置任务不会自动领取，带警告完成不会被领取或恢复', () async {
      final now = DateTime(2026, 7, 10, 12);
      final needsConfiguration = StoryTemplateTranslationTaskModel(
        sourceTitle: '待配置',
        sourcePayload: '{}',
        status: StoryTemplateTranslationTaskStatus.needsConfiguration,
      );
      final completedWithWarnings = StoryTemplateTranslationTaskModel(
        sourceTitle: '带警告完成',
        sourcePayload: '{}',
        status: StoryTemplateTranslationTaskStatus.completedWithWarnings,
        leaseOwner: 'legacy-runner',
        leaseUntil:
            now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
        attempts: 2,
      );
      await taskDao.saveTask(needsConfiguration);
      await taskDao.saveTask(completedWithWarnings);

      expect(
        await taskDao.claimTask(
          needsConfiguration.id!,
          leaseOwner: 'runner-a',
          leaseDuration: const Duration(minutes: 1),
          now: now,
        ),
        isFalse,
      );
      expect(
        await taskDao.claimTask(
          completedWithWarnings.id!,
          leaseOwner: 'runner-a',
          leaseDuration: const Duration(minutes: 1),
          now: now,
        ),
        isFalse,
      );

      await taskDao.recoverInterruptedTasks(now: now);
      final waiting = await taskDao.getTask(needsConfiguration.id!);
      final completed = await taskDao.getTask(completedWithWarnings.id!);
      expect(waiting?.status,
          StoryTemplateTranslationTaskStatus.needsConfiguration);
      expect(waiting?.attempts, 0);
      expect(waiting?.leaseOwner, isNull);
      expect(completed?.status,
          StoryTemplateTranslationTaskStatus.completedWithWarnings);
      expect(completed?.attempts, 2);
      expect(completed?.leaseOwner, 'legacy-runner');
      expect(completed?.leaseUntil,
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch);
    });

    test('暂停和待配置任务可以显式取消且保留检查点', () async {
      for (final status in [
        StoryTemplateTranslationTaskStatus.failed,
        StoryTemplateTranslationTaskStatus.needsConfiguration,
      ]) {
        final task = StoryTemplateTranslationTaskModel(
          sourceTitle: status,
          sourcePayload: '{}',
          status: status,
          chunkPayload: '{"checkpoint":"kept"}',
          fieldPayload: '{"field":"kept"}',
        );
        await taskDao.saveTask(task);

        expect(await taskDao.cancelTask(task.id!), isTrue);
        final stored = await taskDao.getTask(task.id!);
        expect(stored?.status, StoryTemplateTranslationTaskStatus.cancelled);
        expect(stored?.chunkPayload, task.chunkPayload);
        expect(stored?.fieldPayload, task.fieldPayload);
      }
    });

    test('原子领取只允许一个 owner 成功，丢失租约后不能续租或保存', () async {
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '待领取',
        sourcePayload: '{}',
      );
      await taskDao.saveTask(task);
      final now = DateTime(2026, 7, 10, 12);

      final claimed = await Future.wait([
        taskDao.claimTask(task.id!,
            leaseOwner: 'runner-a',
            leaseDuration: const Duration(minutes: 1),
            now: now),
        taskDao.claimTask(task.id!,
            leaseOwner: 'runner-b',
            leaseDuration: const Duration(minutes: 1),
            now: now),
      ]);
      final saved = await taskDao.getTask(task.id!);

      expect(claimed.where((value) => value), hasLength(1));
      expect(saved?.status, StoryTemplateTranslationTaskStatus.running);
      expect(saved?.attempts, 1);
      final winner = saved!.leaseOwner!;
      final loser = winner == 'runner-a' ? 'runner-b' : 'runner-a';
      expect(
        await taskDao.renewLease(task.id!,
            leaseOwner: loser,
            leaseDuration: const Duration(minutes: 1),
            now: now),
        isFalse,
      );
      saved.stage = '不应保存';
      expect(
        await taskDao.saveClaimedTask(saved,
            leaseOwner: loser,
            leaseDuration: const Duration(minutes: 1),
            now: now),
        isFalse,
      );

      final afterExpiry = now.add(const Duration(minutes: 2));
      expect(
        await taskDao.claimTask(task.id!,
            leaseOwner: loser,
            leaseDuration: const Duration(minutes: 1),
            now: afterExpiry),
        isTrue,
      );
      expect((await taskDao.getTask(task.id!))?.attempts, 2);
    });

    test('unclaimed CAS 同时校验 status 和 updatedAt 且同毫秒也单调递增', () async {
      final task = _translationTask(
        'CAS writers',
        status: StoryTemplateTranslationTaskStatus.retryable,
        chunkPayload: '{"checkpoint":"base"}',
      );
      await taskDao.saveTask(task);
      final persisted = (await taskDao.getTask(task.id!))!;
      final first = StoryTemplateTranslationTaskModel.fromJson(
        persisted.toJson(),
      )
        ..stage = 'first writer'
        ..chunkPayload = '{"checkpoint":"first"}';
      final staleSecond = StoryTemplateTranslationTaskModel.fromJson(
        persisted.toJson(),
      )
        ..stage = 'stale second writer'
        ..chunkPayload = '{"checkpoint":"stale"}';
      final sameNow = DateTime.fromMillisecondsSinceEpoch(persisted.updatedAt);

      expect(
        await taskDao.saveTaskIfUnclaimed(
          first,
          expectedStatus: persisted.status,
          expectedUpdatedAt: persisted.updatedAt,
          now: sameNow,
        ),
        isTrue,
      );
      expect(first.updatedAt, persisted.updatedAt + 1);
      expect(
        await taskDao.saveTaskIfUnclaimed(
          staleSecond,
          expectedStatus: persisted.status,
          expectedUpdatedAt: persisted.updatedAt,
          now: sameNow,
        ),
        isFalse,
      );
      expect(staleSecond.updatedAt, persisted.updatedAt);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.stage, 'first writer');
      expect(stored?.chunkPayload, '{"checkpoint":"first"}');
      expect(stored?.updatedAt, persisted.updatedAt + 1);
    });

    test('pre-claim stale CAS 在另一 owner 领取后不能抹掉有效租约', () async {
      final task = _translationTask(
        'CAS lease',
        status: StoryTemplateTranslationTaskStatus.retryable,
        chunkPayload: '{"checkpoint":"kept"}',
      );
      await taskDao.saveTask(task);
      final stale = (await taskDao.getTask(task.id!))!;
      final attempted = StoryTemplateTranslationTaskModel.fromJson(
        stale.toJson(),
      )
        ..status = StoryTemplateTranslationTaskStatus.queued
        ..stage = 'stale retry'
        ..chunkPayload = '{"checkpoint":"overwritten"}';
      final writerReady = Completer<void>();
      final releaseWriter = Completer<void>();
      final staleWrite = () async {
        writerReady.complete();
        await releaseWriter.future;
        return taskDao.saveTaskIfUnclaimed(
          attempted,
          expectedStatus: stale.status,
          expectedUpdatedAt: stale.updatedAt,
        );
      }();
      await writerReady.future;

      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: 'background-owner',
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final claimed = (await taskDao.getTask(task.id!))!;
      releaseWriter.complete();

      expect(await staleWrite, isFalse);
      expect(attempted.updatedAt, stale.updatedAt);
      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(stored?.leaseOwner, 'background-owner');
      expect(stored?.leaseUntil, claimed.leaseUntil);
      expect(stored?.attempts, 1);
      expect(stored?.chunkPayload, '{"checkpoint":"kept"}');
    });

    test('恢复只处理过期租约，并保留有效运行中的任务', () async {
      final now = DateTime(2026, 7, 10, 12);
      final expired = StoryTemplateTranslationTaskModel(
        sourceTitle: '过期',
        sourcePayload: '{}',
        status: StoryTemplateTranslationTaskStatus.running,
        leaseOwner: 'old-runner',
        leaseUntil:
            now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
      );
      final active = StoryTemplateTranslationTaskModel(
        sourceTitle: '有效',
        sourcePayload: '{}',
        status: StoryTemplateTranslationTaskStatus.running,
        leaseOwner: 'active-runner',
        leaseUntil: now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      );
      await taskDao.saveTask(expired);
      await taskDao.saveTask(active);

      await taskDao.recoverInterruptedTasks(now: now);

      expect((await taskDao.getTask(expired.id!))?.status,
          StoryTemplateTranslationTaskStatus.retryable);
      expect((await taskDao.getTask(expired.id!))?.leaseOwner, isNull);
      expect((await taskDao.getTask(active.id!))?.status,
          StoryTemplateTranslationTaskStatus.running);
      expect((await taskDao.getTask(active.id!))?.leaseOwner, 'active-runner');
    });

    test('迟到的 interrupted recovery 不能覆盖另一 DAO 新领取的租约', () async {
      final now = DateTime.now();
      final expired = _translationTask(
        'Recovery race',
        status: StoryTemplateTranslationTaskStatus.running,
        chunkPayload: '{"checkpoint":"recovery-kept"}',
      )
        ..leaseOwner = 'expired-owner'
        ..leaseUntil =
            now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch
        ..attempts = 2;
      await taskDao.saveTask(expired);
      final staleDao = await StoryTemplateTranslationTaskDao.create(storage);
      final candidatesLoaded = Completer<void>();
      final releaseStaleRecovery = Completer<void>();
      final staleRecovery = staleDao.recoverInterruptedTasks(
        now: now,
        afterCandidatesLoaded: () async {
          candidatesLoaded.complete();
          await releaseStaleRecovery.future;
        },
      );
      await candidatesLoaded.future;

      await taskDao.recoverInterruptedTasks(now: now);
      expect(
        await taskDao.claimTask(
          expired.id!,
          leaseOwner: 'new-owner',
          leaseDuration: const Duration(minutes: 5),
          now: now,
        ),
        isTrue,
      );
      final claimed = (await taskDao.getTask(expired.id!))!;
      releaseStaleRecovery.complete();
      await staleRecovery;

      final stored = await taskDao.getTask(expired.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(stored?.leaseOwner, 'new-owner');
      expect(stored?.leaseUntil, claimed.leaseUntil);
      expect(stored?.attempts, 3);
      expect(stored?.chunkPayload, '{"checkpoint":"recovery-kept"}');
    });

    test('完成事务复用已关联输出，且不会重复插入模板', () async {
      final now = DateTime(2026, 7, 10, 12);
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: '原模板',
        sourcePayload: '{}',
        outputTitle: '中文副本',
      );
      await taskDao.saveTask(task);
      expect(
        await taskDao.claimTask(task.id!,
            leaseOwner: 'runner-a',
            leaseDuration: const Duration(minutes: 1),
            now: now),
        isTrue,
      );
      task
        ..stage = '已生成中文副本'
        ..progress = 1;
      final output = StoryTemplateModel(
        title: '中文副本',
        sourceTitle: '原模板',
        translated: true,
        payload: '{"results":[]}',
      );

      final first = await taskDao.completeWithTemplate(task,
          outputTemplate: output, leaseOwner: 'runner-a', now: now);
      final second = await taskDao.completeWithTemplate(task,
          outputTemplate: output, leaseOwner: 'runner-a', now: now);
      final templates = await storage.db.query('tb_story_template');
      final completed = await taskDao.getTask(task.id!);

      expect(first, isNotNull);
      expect(second, first);
      expect(templates, hasLength(1));
      expect(completed?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(completed?.outputTemplateId, first);
      expect(completed?.leaseOwner, isNull);
      expect(completed?.leaseUntil, isNull);
    });

    test('运行器保存完成任务、角色检查点和中文副本', () async {
      final templateDao = await StoryTemplateDao.create(storage);
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice', prompt: 'Careful.'),
          ),
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Bob', prompt: 'Brave.'),
          ),
        ],
        initialOpening: 'Welcome.',
        promptConfigJson: '{"version":1,"modules":[]}',
        quickRepliesJson: '{"roomId":0,"groups":[]}',
        regexScriptsJson: '{"version":1,"rules":[]}',
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Party',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: 'Party（简中）',
        roleTotal: 2,
      );
      await taskDao.saveTask(task);
      const leaseOwner = 'runner-test';
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: leaseOwner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      var call = 0;

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
        leaseOwner: leaseOwner,
        complete: (_) async {
          call++;
          return jsonEncode({
            'name': call == 1
                ? '爱丽丝'
                : call == 2
                    ? '鲍勃'
                    : '模板开场',
            'description': '中文简介',
            'prompt': '中文人设',
            'openingMessage': call == 3 ? '欢迎。' : '角色开场',
            'exampleDialogs': '示例对话',
            'memoryBook': '世界书',
          });
        },
        isCancelled: () => false,
      ).run();

      final savedTask = await taskDao.getTask(task.id!);
      expect(
        savedTask?.status,
        StoryTemplateTranslationTaskStatus.completed,
        reason: '${savedTask?.error}\n${savedTask?.log}',
      );
      final copy = await templateDao.getTemplate(savedTask!.outputTemplateId!);
      final copyPayload = StoryRoomTemplatePayload.fromTemplate(copy!);

      expect(savedTask.roleIndex, 2);
      expect(savedTask.partialPayload, isNotEmpty);
      expect(savedTask.log, contains('中文副本已保存'));
      expect(copy.title, 'Party（简中）');
      expect(copy.translated, isTrue);
      expect(copyPayload.results.map((item) => item.assistant.name),
          ['爱丽丝', '鲍勃']);
      expect(copyPayload.initialOpening, '欢迎。');
      expect(copyPayload.promptConfigJson, '{"version":1,"modules":[]}');
      expect(copyPayload.quickRepliesJson, '{"roomId":0,"groups":[]}');
      expect(copyPayload.regexScriptsJson, '{"version":1,"rules":[]}');
    });

    test('用户取消与网络返回重叠时取消状态获胜且不写输出模板', () async {
      final templateDao = await StoryTemplateDao.create(storage);
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice', prompt: 'Careful.'),
          ),
        ],
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Cancel overlap',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: '不应生成',
        roleTotal: 1,
      );
      await taskDao.saveTask(task);
      const owner = 'runner-cancel-overlap';
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: owner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      var cancelled = false;

      final running = StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
        leaseOwner: owner,
        complete: (prompt) async {
          if (!requestStarted.isCompleted) requestStarted.complete();
          await releaseResponse.future;
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          final field = payload.keys.single;
          return jsonEncode({field: '迟到的网络结果'});
        },
        isCancelled: () => cancelled,
      ).run();

      await requestStarted.future;
      cancelled = true;
      expect(await taskDao.cancelTask(task.id!), isTrue);
      releaseResponse.complete();
      await running;

      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.cancelled);
      expect(stored?.outputTemplateId, isNull);
      expect(await templateDao.getTemplates(), isEmpty);
    });

    test('运行器从字段检查点恢复时不重复请求已完成字段', () async {
      final templateDao = await StoryTemplateDao.create(storage);
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(
              name: 'Alice',
              prompt:
                  'FIRST-${List.filled(1800, 'x').join()}\n\nSECOND-${List.filled(1800, 'y').join()}',
            ),
          ),
        ],
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Checkpoint',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: 'Checkpoint（简中）',
        roleTotal: 1,
      );
      await taskDao.saveTask(task);
      const firstOwner = 'runner-first';
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: firstOwner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      var promptCalls = 0;
      var cancelled = false;
      String? completedPromptChunk;
      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
        leaseOwner: firstOwner,
        useChunkCheckpoints: true,
        complete: (prompt) async {
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          final field = payload.keys.single;
          if (field == 'prompt') {
            promptCalls += 1;
            if (promptCalls == 1) {
              completedPromptChunk = payload[field] as String;
            } else if (promptCalls == 2) {
              cancelled = true;
            }
          }
          return jsonEncode({field: '翻译:$field'});
        },
        isCancelled: () => cancelled,
      ).run();

      final interrupted = await taskDao.getTask(task.id!);
      expect(
        interrupted?.status,
        StoryTemplateTranslationTaskStatus.cancelled,
        reason: '${interrupted?.error}\n${interrupted?.log}',
      );
      final checkpoint =
          jsonDecode(interrupted!.fieldPayload) as Map<String, dynamic>;
      expect((checkpoint['fields'] as Map).keys, ['name', 'description']);
      expect(interrupted.chunkPayload, isNotEmpty);

      interrupted
        ..status = StoryTemplateTranslationTaskStatus.queued
        ..leaseOwner = null
        ..leaseUntil = null;
      await taskDao.saveTask(interrupted);
      const secondOwner = 'runner-second';
      expect(
        await taskDao.claimTask(
          interrupted.id!,
          leaseOwner: secondOwner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final resumedFields = <String>[];
      final resumedPromptChunks = <String>[];
      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: interrupted,
        leaseOwner: secondOwner,
        useChunkCheckpoints: true,
        complete: (prompt) async {
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          final field = payload.keys.single;
          resumedFields.add(field);
          if (field == 'prompt') {
            resumedPromptChunks.add(payload[field] as String);
          }
          return jsonEncode({field: '翻译:$field'});
        },
        isCancelled: () => false,
      ).run();

      expect(resumedFields, isNot(contains('name')));
      expect(resumedFields, isNot(contains('description')));
      expect(resumedPromptChunks, isNot(contains(completedPromptChunk)));
      expect((await taskDao.getTask(task.id!))?.status,
          StoryTemplateTranslationTaskStatus.completed);
    });

    test('限流会保存当前分块、释放租约并保留 nextRunAt', () async {
      final templateDao = await StoryTemplateDao.create(storage);
      const secretSource = 'SOURCE_TEXT_MUST_NOT_APPEAR_IN_LOG';
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Rate limited',
        sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: secretSource),
          ),
        ]).toJson()),
        outputTitle: 'Rate limited（简中）',
      );
      await taskDao.saveTask(task);
      const owner = 'runner-rate-limit';
      expect(
        await taskDao.claimTask(
          task.id!,
          leaseOwner: owner,
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final before = DateTime.now().millisecondsSinceEpoch;

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
        leaseOwner: owner,
        useChunkCheckpoints: true,
        complete: (_) async => throw const TranslationRequestFailure(
          kind: TranslationFailureKind.rateLimited,
          statusCode: 429,
          retryAfter: Duration(seconds: 30),
          safeCode: 'rate_limited',
        ),
        isCancelled: () => false,
      ).run();

      final stored = await taskDao.getTask(task.id!);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(stored?.leaseOwner, isNull);
      expect(stored?.leaseUntil, isNull);
      expect(stored?.nextRunAt, greaterThan(before));
      expect(stored?.chunkPayload, isNotEmpty);
      expect(stored?.error, 'rate_limited');
      expect(stored?.log, isNot(contains(secretSource)));
    });

    test('协调器启动后串行自动恢复意外中断任务', () async {
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice', prompt: 'Careful.'),
          ),
        ],
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Party',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: 'Party（简中）',
        roleTotal: 1,
        status: StoryTemplateTranslationTaskStatus.running,
      );
      await taskDao.saveTask(task);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');

      final resumed = await coordinator.resumeRecoverable(
        complete: (_) async => jsonEncode({
          'name': '爱丽丝',
          'description': '中文简介',
          'prompt': '谨慎。',
          'openingMessage': '',
          'exampleDialogs': '',
          'memoryBook': '',
        }),
      );

      final restored = await taskDao.getTask(task.id!);
      expect(resumed, 1);
      expect(
        restored?.status,
        StoryTemplateTranslationTaskStatus.completed,
        reason: '${restored?.error}\n${restored?.log}',
      );
      expect(restored?.log, contains('从检查点自动恢复'));
      expect(restored?.outputTemplateId, isNotNull);
    });

    test('保留原文 action 恢复后持久化警告且只创建一个模板', () async {
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      final memoryBook = List.filled(1300, '界').join();
      final payload = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice', memoryBook: memoryBook),
        ),
      ]);
      final checkpoint = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: memoryBook,
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Retained source',
        sourcePayload: jsonEncode(payload.toJson()),
        outputTitle: 'Retained copy',
        roleTotal: 1,
        status: StoryTemplateTranslationTaskStatus.failed,
        requestProfile: jsonEncode(profile.toJson()),
        chunkPayload: jsonEncode({
          'version': TranslationChunkCheckpoint.currentVersion,
          'checkpoints': {'role:0:memoryBook': checkpoint.toJson()},
        }),
      );
      await taskDao.saveTask(task);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');

      await coordinator.completeKeepingOriginalChunks(
        coordinator.tasks.single,
      );
      final service = _EchoTranslationChatService();
      final resumed = await coordinator.resumeRecoverable(
        resolveExecutor: (resolved) => TranslationStreamExecutor(
          service: service,
          profile: resolved,
        ),
      );

      final stored = await taskDao.getTask(task.id!);
      final outputs = await StoryTemplateDao.create(storage)
          .then((dao) => dao.getTemplates());
      final output = StoryRoomTemplatePayload.fromTemplate(outputs.single);
      expect(resumed, 1);
      expect(
        stored?.status,
        StoryTemplateTranslationTaskStatus.completedWithWarnings,
      );
      expect(stored?.stage, '已生成中文副本，部分内容保留原文');
      expect(
        service.payloads.where(
          (request) =>
              request['memoryBook'] is String &&
              (request['memoryBook'] as String).isNotEmpty,
        ),
        isEmpty,
      );
      expect(outputs, hasLength(1));
      expect(output.results.single.assistant.memoryBook, memoryBook);
    });

    test('切换账号会立即中止旧 transport 并隔离相同任务 id', () async {
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbB.close);
      final storageB = HiDBManager.test(dbB);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      StoryTemplateTranslationTaskModel taskFor(String name) =>
          StoryTemplateTranslationTaskModel(
            sourceTitle: '$name source',
            sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
              AssistantRoleCardImportResult(
                assistant: AssistantModel(name: name),
              ),
            ]).toJson()),
            outputTitle: '$name copy',
            roleTotal: 1,
            requestProfile: jsonEncode(profile.toJson()),
          );

      final taskA = taskFor('Alice');
      final taskB = taskFor('Bob');
      await taskDao.saveTask(taskA);
      await taskDaoB.saveTask(taskB);
      expect(taskA.id, taskB.id);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'account-a');
      final heldA = _HeldTranslationChatService();

      final runningA = coordinator.resumeRecoverable(
        resolveExecutor: (resolved) => TranslationStreamExecutor(
          service: heldA,
          profile: resolved,
        ),
      );
      await heldA.requestStarted.future;
      await coordinator.initialize(storageB, accountHash: 'account-b');
      final abortPrompt = await heldA.abortObserved.future.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => false,
      );
      if (!abortPrompt) heldA.respond();
      await runningA;

      expect(abortPrompt, isTrue);
      final storedA = await taskDao.getTask(taskA.id!);
      expect(storedA?.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(storedA?.leaseOwner, isNull);
      expect(storedA?.leaseUntil, isNull);

      final serviceB = _EchoTranslationChatService();
      final resumedB = await coordinator.resumeRecoverable(
        resolveExecutor: (resolved) => TranslationStreamExecutor(
          service: serviceB,
          profile: resolved,
        ),
      );
      final storedB = await taskDaoB.getTask(taskB.id!);
      expect(resumedB, 1);
      expect(storedB?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(storedB?.outputTemplateId, isNotNull);
    });

    test('同账号登出后会绑定新 storage 并恢复任务', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final storageA = HiDBManager.test(dbA);
      final taskDaoA = await StoryTemplateTranslationTaskDao.create(storageA);
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      StoryTemplateTranslationTaskModel taskFor(String name) =>
          StoryTemplateTranslationTaskModel(
            sourceTitle: '$name source',
            sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
              AssistantRoleCardImportResult(
                assistant: AssistantModel(name: name),
              ),
            ]).toJson()),
            outputTitle: '$name copy',
            roleTotal: 1,
            requestProfile: jsonEncode(profile.toJson()),
          );

      final staleTask = taskFor('Alice');
      await taskDaoA.saveTask(staleTask);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');
      await coordinator.cancelActiveRunsForLifecycle();
      await dbA.close();

      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbB.close);
      final storageB = HiDBManager.test(dbB);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final recoverableTask = taskFor('Bob');
      await taskDaoB.saveTask(recoverableTask);
      expect(staleTask.id, recoverableTask.id);

      await coordinator.initialize(storageB, accountHash: 'account-a');
      final resumed = await coordinator.resumeRecoverable(
        resolveExecutor: (resolved) => TranslationStreamExecutor(
          service: _EchoTranslationChatService(),
          profile: resolved,
        ),
      );

      final storedB = await taskDaoB.getTask(recoverableTask.id!);
      expect(resumed, 1);
      expect(coordinator.tasks.single.sourceTitle, 'Bob source');
      expect(storedB?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(storedB?.outputTemplateId, isNotNull);
    });

    test('同账号不同 storage 会绕过旧 fast path', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final storageA = HiDBManager.test(dbA);
      final taskDaoA = await StoryTemplateTranslationTaskDao.create(storageA);
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      StoryTemplateTranslationTaskModel taskFor(String name) =>
          StoryTemplateTranslationTaskModel(
            sourceTitle: '$name source',
            sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
              AssistantRoleCardImportResult(
                assistant: AssistantModel(name: name),
              ),
            ]).toJson()),
            outputTitle: '$name copy',
            roleTotal: 1,
            requestProfile: jsonEncode(profile.toJson()),
          );

      final staleTask = taskFor('Alice');
      await taskDaoA.saveTask(staleTask);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');
      await dbA.close();

      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbB.close);
      final storageB = HiDBManager.test(dbB);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final recoverableTask = taskFor('Bob');
      await taskDaoB.saveTask(recoverableTask);
      expect(staleTask.id, recoverableTask.id);

      await coordinator.initialize(storageB, accountHash: 'account-a');
      final resumed = await coordinator.resumeRecoverable(
        resolveExecutor: (resolved) => TranslationStreamExecutor(
          service: _EchoTranslationChatService(),
          profile: resolved,
        ),
      );

      final storedB = await taskDaoB.getTask(recoverableTask.id!);
      expect(resumed, 1);
      expect(coordinator.tasks.single.sourceTitle, 'Bob source');
      expect(storedB?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(storedB?.outputTemplateId, isNotNull);
    });

    test('切换 binding 时会同步隐藏旧账号任务快照', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final storageA = HiDBManager.test(dbA);
      final storageB = HiDBManager.test(dbB);
      final taskDaoA = await StoryTemplateTranslationTaskDao.create(storageA);
      await taskDaoA.saveTask(_translationTask('Alice'));
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');

      final lockStarted = Completer<void>();
      final releaseLock = Completer<void>();
      final blockingTransaction = dbB.transaction((txn) async {
        await txn.rawQuery('select 1');
        lockStarted.complete();
        await releaseLock.future;
      });
      addTearDown(() async {
        if (!releaseLock.isCompleted) releaseLock.complete();
        await blockingTransaction;
      });
      await lockStarted.future;
      var notifications = 0;
      coordinator.addListener(() => notifications += 1);

      final initializeB =
          coordinator.initialize(storageB, accountHash: 'account-b');
      try {
        expect(coordinator.tasks, isEmpty);
        expect(notifications, 1);
      } finally {
        if (!releaseLock.isCompleted) releaseLock.complete();
        await blockingTransaction;
        await initializeB;
      }
    });

    test('detach 会在首个 await 前同步隐藏任务快照', () async {
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      await taskDao.saveTask(_translationTask('Alice'));
      await coordinator.initialize(
        HiDBManager.test(db),
        accountHash: 'test-reload',
      );
      expect(coordinator.tasks, isNotEmpty);
      var notifications = 0;
      coordinator.addListener(() => notifications += 1);

      final detached = coordinator.detachForLifecycle();
      expect(coordinator.tasks, isEmpty);
      expect(notifications, 1);
      await detached;
    });

    test('切换账号后旧 resume loop 不会继续运行第二个任务', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final storageA = HiDBManager.test(dbA);
      final storageB = HiDBManager.test(dbB);
      final taskDaoA = await StoryTemplateTranslationTaskDao.create(storageA);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final taskA1 = _translationTask(
        'A1',
        modelId: 'held-a1',
        createdAt: 1,
      );
      final taskA2 = _translationTask(
        'A2',
        modelId: 'must-not-run-a2',
        createdAt: 2,
      );
      final taskB1 = _translationTask(
        'B1',
        modelId: 'run-b1',
        createdAt: 1,
      );
      final protectedB2 = _translationTask(
        'B2-protected',
        modelId: 'never-run-b2',
        status: StoryTemplateTranslationTaskStatus.cancelled,
        createdAt: 2,
      );
      await taskDaoA.saveTask(taskA1);
      await taskDaoA.saveTask(taskA2);
      await taskDaoB.saveTask(taskB1);
      await taskDaoB.saveTask(protectedB2);
      expect(taskA1.id, taskB1.id);
      expect(taskA2.id, protectedB2.id);

      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');
      final heldA1 = _HeldTranslationChatService();
      final forbiddenA2 = _EchoTranslationChatService();
      final runningA = coordinator.resumeRecoverable(
        resolveExecutor: (profile) => TranslationStreamExecutor(
          service: profile.modelId == 'held-a1'
              ? heldA1 as ChatService
              : forbiddenA2,
          profile: profile,
        ),
      );
      await heldA1.requestStarted.future;

      final lockStarted = Completer<void>();
      final releaseLock = Completer<void>();
      final blockingTransaction = dbB.transaction((txn) async {
        await txn.rawQuery('select 1');
        lockStarted.complete();
        await releaseLock.future;
      });
      addTearDown(() async {
        if (!releaseLock.isCompleted) releaseLock.complete();
        await blockingTransaction;
      });
      await lockStarted.future;
      final initializeB =
          coordinator.initialize(storageB, accountHash: 'account-b');
      await heldA1.abortObserved.future;
      try {
        await runningA;
      } finally {
        if (!releaseLock.isCompleted) releaseLock.complete();
        await blockingTransaction;
        await initializeB;
      }

      final storedA1 = await taskDaoA.getTask(taskA1.id!);
      final storedA2 = await taskDaoA.getTask(taskA2.id!);
      final storedProtectedB2 = await taskDaoB.getTask(protectedB2.id!);
      expect(await heldA1.abortObserved.future, isTrue);
      expect(storedA1?.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(storedA2?.status, StoryTemplateTranslationTaskStatus.queued);
      expect(storedA2?.attempts, 0);
      expect(forbiddenA2.payloads, isEmpty);
      expect(storedProtectedB2?.sourceTitle, 'B2-protected source');
      expect(
        storedProtectedB2?.status,
        StoryTemplateTranslationTaskStatus.cancelled,
      );

      final resumedB = await coordinator.resumeRecoverable(
        resolveExecutor: (profile) => TranslationStreamExecutor(
          service: _EchoTranslationChatService(),
          profile: profile,
        ),
      );
      expect(resumedB, 1);
      expect(
        (await taskDaoB.getTask(taskB1.id!))?.status,
        StoryTemplateTranslationTaskStatus.completed,
      );
    });

    test('较旧 initialize 完成后不会覆盖更新的 binding', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final dbC = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      addTearDown(dbC.close);
      final storageA = HiDBManager.test(dbA);
      final storageB = HiDBManager.test(dbB);
      final storageC = HiDBManager.test(dbC);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final taskDaoC = await StoryTemplateTranslationTaskDao.create(storageC);
      await taskDaoB.saveTask(_translationTask('B'));
      await taskDaoC.saveTask(_translationTask('C'));
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');

      final lockStarted = Completer<void>();
      final releaseLock = Completer<void>();
      final blockingTransaction = dbB.transaction((txn) async {
        await txn.rawQuery('select 1');
        lockStarted.complete();
        await releaseLock.future;
      });
      await lockStarted.future;
      final olderInitialize =
          coordinator.initialize(storageB, accountHash: 'account-b');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await coordinator.initialize(storageC, accountHash: 'account-c');
      releaseLock.complete();
      await blockingTransaction;
      await olderInitialize;

      expect(coordinator.tasks, hasLength(1));
      expect(coordinator.tasks.single.sourceTitle, 'C source');
    });

    test('旧页面任务引用不能用相同 id 修改新账号', () async {
      final dbA = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final dbB = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final storageA = HiDBManager.test(dbA);
      final storageB = HiDBManager.test(dbB);
      final taskDaoA = await StoryTemplateTranslationTaskDao.create(storageA);
      final taskDaoB = await StoryTemplateTranslationTaskDao.create(storageB);
      final checkpoint = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: List.filled(1300, '界').join(),
      );
      for (var index = 1; index <= 4; index += 1) {
        await taskDaoA.saveTask(_translationTask(
          'A$index',
          status: StoryTemplateTranslationTaskStatus.failed,
          chunkPayload: index == 3
              ? jsonEncode({
                  'version': TranslationChunkCheckpoint.currentVersion,
                  'checkpoints': {'role:0:memoryBook': checkpoint.toJson()},
                })
              : '',
        ));
        await taskDaoB.saveTask(_translationTask(
          'B$index',
          status: StoryTemplateTranslationTaskStatus.failed,
        ));
      }
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storageA, accountHash: 'account-a');
      final staleTasks = coordinator.tasks.toList()
        ..sort((a, b) => a.id!.compareTo(b.id!));
      await coordinator.initialize(storageB, accountHash: 'account-b');
      var retryResolverCalls = 0;

      await coordinator.cancel(staleTasks[0]);
      await coordinator.retry(
        staleTasks[1],
        resolveExecutor: (_) {
          retryResolverCalls += 1;
          throw const TranslationModelUnavailableException('stale');
        },
      );
      await coordinator.completeKeepingOriginalChunks(staleTasks[2]);
      await coordinator.dismiss(staleTasks[3]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final storedB = (await taskDaoB.getTasks())
        ..sort((a, b) => a.id!.compareTo(b.id!));
      expect(storedB, hasLength(4));
      expect(storedB.map((task) => task.sourceTitle), [
        'B1 source',
        'B2 source',
        'B3 source',
        'B4 source',
      ]);
      expect(
        storedB.map((task) => task.status),
        everyElement(StoryTemplateTranslationTaskStatus.failed),
      );
      expect(retryResolverCalls, 0);
    });

    test('claim 替换对象后旧引用不能执行任何任务 mutation', () async {
      final checkpoint = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: List.filled(1300, '界').join(),
      );
      final chunkPayload = jsonEncode({
        'version': TranslationChunkCheckpoint.currentVersion,
        'checkpoints': {'role:0:memoryBook': checkpoint.toJson()},
      });

      for (final action in ['retry', 'retain', 'cancel', 'dismiss']) {
        final actionDb = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final actionStorage = HiDBManager.test(actionDb);
        final actionDao =
            await StoryTemplateTranslationTaskDao.create(actionStorage);
        final persisted = _translationTask(
          action,
          status: StoryTemplateTranslationTaskStatus.retryable,
          chunkPayload: chunkPayload,
        );
        await actionDao.saveTask(persisted);
        final coordinator = StoryTemplateTranslationCoordinator();
        await coordinator.initialize(
          actionStorage,
          accountHash: 'account-$action',
        );
        final stale = coordinator.tasks.single;
        final held = _HeldTranslationChatService();
        final running = coordinator.resumeRecoverable(
          resolveExecutor: (profile) => TranslationStreamExecutor(
            service: held,
            profile: profile,
          ),
        );
        await held.requestStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final current = coordinator.tasks.single;
        expect(identical(stale, current), isFalse, reason: action);
        final before = await actionDao.getTask(persisted.id!);
        expect(before?.status, StoryTemplateTranslationTaskStatus.running,
            reason: action);

        switch (action) {
          case 'retry':
            await coordinator.retry(
              stale,
              resolveExecutor: (profile) => TranslationStreamExecutor(
                service: _EchoTranslationChatService(),
                profile: profile,
              ),
            );
          case 'retain':
            await coordinator.completeKeepingOriginalChunks(stale);
          case 'cancel':
            await coordinator.cancel(stale);
          case 'dismiss':
            stale.status = StoryTemplateTranslationTaskStatus.failed;
            await coordinator.dismiss(stale);
        }

        final after = await actionDao.getTask(persisted.id!);
        expect(after?.status, StoryTemplateTranslationTaskStatus.running,
            reason: action);
        expect(after?.leaseOwner, before?.leaseOwner, reason: action);
        expect(after?.chunkPayload, before?.chunkPayload, reason: action);
        expect(identical(coordinator.tasks.single, current), isTrue,
            reason: action);

        await coordinator.detachForLifecycle();
        await running;
        await actionDb.close();
      }
    });

    test('background claim 后 stale resume 不覆盖租约且不启动第二个 runner', () async {
      final task = _translationTask(
        'Resume race',
        status: StoryTemplateTranslationTaskStatus.retryable,
        chunkPayload: '{"checkpoint":"resume-kept"}',
      );
      await taskDao.saveTask(task);
      final ownerCoordinator = StoryTemplateTranslationCoordinator();
      final staleCoordinator = StoryTemplateTranslationCoordinator();
      await ownerCoordinator.initialize(storage, accountHash: 'test');
      await staleCoordinator.initialize(storage, accountHash: 'test');
      final held = _HeldTranslationChatService();
      final ownerRun = ownerCoordinator.resumeRecoverable(
        resolveExecutor: (profile) => TranslationStreamExecutor(
          service: held,
          profile: profile,
        ),
      );
      await held.requestStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final claimed = (await taskDao.getTask(task.id!))!;
      final forbidden = _EchoTranslationChatService();
      var staleResolverCalls = 0;

      try {
        final resumed = await staleCoordinator.resumeRecoverable(
          resolveExecutor: (profile) {
            staleResolverCalls += 1;
            return TranslationStreamExecutor(
              service: forbidden,
              profile: profile,
            );
          },
        );

        final stored = await taskDao.getTask(task.id!);
        expect(resumed, 0);
        expect(staleResolverCalls, 0);
        expect(forbidden.payloads, isEmpty);
        expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
        expect(stored?.leaseOwner, claimed.leaseOwner);
        expect(stored?.leaseUntil, claimed.leaseUntil);
        expect(stored?.attempts, 1);
        expect(stored?.chunkPayload, claimed.chunkPayload);
        expect(
          staleCoordinator.tasks.single.status,
          StoryTemplateTranslationTaskStatus.running,
        );
        expect(staleCoordinator.tasks.single.leaseOwner, claimed.leaseOwner);
      } finally {
        await ownerCoordinator.detachForLifecycle();
        await ownerRun;
        await staleCoordinator.detachForLifecycle();
      }
    });

    test('background claim 后 stale retry 和 retain 都不能覆盖租约', () async {
      final checkpoint = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: List.filled(1300, '界').join(),
      );
      final checkpointPayload = jsonEncode({
        'version': TranslationChunkCheckpoint.currentVersion,
        'checkpoints': {'role:0:memoryBook': checkpoint.toJson()},
      });

      for (final action in ['retry', 'retain']) {
        final actionDb = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final actionStorage = HiDBManager.test(actionDb);
        final actionDao =
            await StoryTemplateTranslationTaskDao.create(actionStorage);
        final task = _translationTask(
          'CAS $action',
          status: StoryTemplateTranslationTaskStatus.retryable,
          chunkPayload: checkpointPayload,
        );
        await actionDao.saveTask(task);
        final ownerCoordinator = StoryTemplateTranslationCoordinator();
        final staleCoordinator = StoryTemplateTranslationCoordinator();
        await ownerCoordinator.initialize(
          actionStorage,
          accountHash: 'account-$action',
        );
        await staleCoordinator.initialize(
          actionStorage,
          accountHash: 'account-$action',
        );
        final stale = staleCoordinator.tasks.single;
        final held = _HeldTranslationChatService();
        final ownerRun = ownerCoordinator.resumeRecoverable(
          resolveExecutor: (profile) => TranslationStreamExecutor(
            service: held,
            profile: profile,
          ),
        );
        await held.requestStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final claimed = (await actionDao.getTask(task.id!))!;
        var retryResolverCalls = 0;

        try {
          if (action == 'retry') {
            await staleCoordinator.retry(
              stale,
              resolveExecutor: (profile) {
                retryResolverCalls += 1;
                return TranslationStreamExecutor(
                  service: _EchoTranslationChatService(),
                  profile: profile,
                );
              },
            );
          } else {
            await staleCoordinator.completeKeepingOriginalChunks(stale);
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));

          final stored = await actionDao.getTask(task.id!);
          expect(retryResolverCalls, 0, reason: action);
          expect(stored?.status, StoryTemplateTranslationTaskStatus.running,
              reason: action);
          expect(stored?.leaseOwner, claimed.leaseOwner, reason: action);
          expect(stored?.leaseUntil, claimed.leaseUntil, reason: action);
          expect(stored?.attempts, 1, reason: action);
          expect(stored?.chunkPayload, claimed.chunkPayload, reason: action);
          expect(
            staleCoordinator.tasks.single.status,
            StoryTemplateTranslationTaskStatus.running,
            reason: action,
          );
        } finally {
          await ownerCoordinator.detachForLifecycle();
          await ownerRun;
          await staleCoordinator.detachForLifecycle();
          await actionDb.close();
        }
      }
    });

    test('legacy needsConfiguration transition CAS 失败时重载 background lease',
        () async {
      final legacy = _translationTask(
        'Legacy CAS',
        status: StoryTemplateTranslationTaskStatus.retryable,
      )..requestProfile = '';
      await taskDao.saveTask(legacy);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      expect(
        await taskDao.claimTask(
          legacy.id!,
          leaseOwner: 'background-legacy',
          leaseDuration: const Duration(minutes: 5),
        ),
        isTrue,
      );
      final claimed = (await taskDao.getTask(legacy.id!))!;
      var executorCalls = 0;

      final resumed = await coordinator.resumeRecoverable(
        resolveLegacyRequestProfile: () => null,
        resolveExecutor: (profile) {
          executorCalls += 1;
          return TranslationStreamExecutor(
            service: _EchoTranslationChatService(),
            profile: profile,
          );
        },
      );

      final stored = await taskDao.getTask(legacy.id!);
      expect(resumed, 0);
      expect(executorCalls, 0);
      expect(stored?.status, StoryTemplateTranslationTaskStatus.running);
      expect(stored?.leaseOwner, 'background-legacy');
      expect(stored?.leaseUntil, claimed.leaseUntil);
      expect(stored?.attempts, 1);
      expect(
        coordinator.tasks.single.status,
        StoryTemplateTranslationTaskStatus.running,
      );
      expect(coordinator.tasks.single.leaseOwner, 'background-legacy');
    });

    test('未知 executor 初始化异常会安全释放租约且不泄漏 unawaited 错误', () async {
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      final errors = <Object>[];
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      final template = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice'),
        ),
      ]).toTemplate(title: 'Party', sourceTitle: 'party.json');

      await runZonedGuarded<Future<void>>(
        () async {
          await coordinator.start(
            template,
            requestProfile: profile,
            resolveExecutor: (_) => throw StateError('secret setup detail'),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        (error, _) => errors.add(error),
      );

      final stored = (await taskDao.getTasks()).single;
      expect(errors, isEmpty);
      expect(stored.status, StoryTemplateTranslationTaskStatus.retryable);
      expect(stored.leaseOwner, isNull);
      expect(stored.leaseUntil, isNull);
      expect(stored.error, 'translation_executor_failed');
      expect(stored.log, contains('StateError'));
      expect(stored.log, isNot(contains('secret setup detail')));
    });

    test('cancel CAS 输给已完成任务时以内存和数据库权威结果为准', () async {
      final task = _translationTask(
        'Completed tavern',
        status: StoryTemplateTranslationTaskStatus.failed,
      )..taskKind = StoryTemplateTranslationTaskKind.tavernRoomImport;
      await taskDao.saveTask(task);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      final current = coordinator.tasks.single;
      final authoritative = StoryTemplateTranslationTaskModel.fromJson(
        current.toJson(),
      )
        ..status = StoryTemplateTranslationTaskStatus.completed
        ..outputTemplateId = 41
        ..outputRoomId = 51
        ..progress = 1
        ..stage = '已导入酒馆房间';
      await taskDao.saveTask(authoritative);

      await coordinator.cancel(current);

      final stored = await taskDao.getTask(task.id!);
      final visible = coordinator.tasks.single;
      expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(stored?.outputTemplateId, 41);
      expect(stored?.outputRoomId, 51);
      expect(visible.status, StoryTemplateTranslationTaskStatus.completed);
      expect(visible.outputTemplateId, 41);
      expect(visible.outputRoomId, 51);
    });

    test('协调器创建任务时冻结具体模型和任务类型', () async {
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      final profile = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: 'fast-model-a',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );
      TranslationRequestProfile? resolvedProfile;
      final template = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice'),
          ),
        ],
      ).toTemplate(title: 'Party', sourceTitle: 'party.json');

      await coordinator.start(
        template,
        requestProfile: profile,
        resolveExecutor: (resolved) {
          resolvedProfile = resolved;
          throw const TranslationModelUnavailableException('测试暂停');
        },
      );
      await _waitUntil(() =>
          coordinator.tasks.single.status ==
          StoryTemplateTranslationTaskStatus.needsConfiguration);

      final stored = (await taskDao.getTasks()).single;
      expect(stored.taskKind, StoryTemplateTranslationTaskKind.templateCopy);
      expect(stored.checkpointVersion, 1);
      expect(
        TranslationRequestProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(stored.requestProfile) as Map),
        ).modelId,
        'fast-model-a',
      );
      expect(resolvedProfile?.providerId, 'provider-a');
      expect(resolvedProfile?.modelId, 'fast-model-a');
      expect(
          stored.status, StoryTemplateTranslationTaskStatus.needsConfiguration);
      expect(stored.error, 'model_unavailable');
    });

    test('更换模型重试保留分块和字段检查点', () async {
      final oldProfile = TranslationRequestProfile(
        mode: TranslationExecutionMode.backend,
        modelId: 'slow-model',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      final replacement = TranslationRequestProfile(
        mode: TranslationExecutionMode.backend,
        modelId: 'fast-model',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );
      const chunkPayload =
          '{"version":1,"checkpoints":{"role:0:memoryBook":{"version":1}}}';
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Party',
        sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice'),
          ),
        ]).toJson()),
        requestProfile: jsonEncode(oldProfile.toJson()),
        chunkPayload: chunkPayload,
        fieldPayload: '{"scope":"role","roleIndex":0,"fields":{}}',
        status: StoryTemplateTranslationTaskStatus.failed,
      );
      await taskDao.saveTask(task);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');

      await coordinator.retry(
        coordinator.tasks.single,
        replacementProfile: replacement,
        resolveExecutor: (_) {
          throw const TranslationModelUnavailableException('测试暂停');
        },
      );
      await _waitUntil(() =>
          coordinator.tasks.single.status ==
          StoryTemplateTranslationTaskStatus.needsConfiguration);

      final stored = await taskDao.getTask(task.id!);
      expect(stored?.chunkPayload, chunkPayload);
      expect(stored?.fieldPayload, task.fieldPayload);
      expect(
        TranslationRequestProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(stored!.requestProfile) as Map),
        ).modelId,
        'fast-model',
      );
    });

    test('自动恢复跳过未来退避、暂停和待配置任务', () async {
      final future = DateTime.now().add(const Duration(minutes: 5));
      for (final task in [
        StoryTemplateTranslationTaskModel(
          sourceTitle: '未来退避',
          sourcePayload: '{}',
          status: StoryTemplateTranslationTaskStatus.retryable,
          nextRunAt: future.millisecondsSinceEpoch,
        ),
        StoryTemplateTranslationTaskModel(
          sourceTitle: '用户暂停',
          sourcePayload: '{}',
          status: StoryTemplateTranslationTaskStatus.failed,
        ),
        StoryTemplateTranslationTaskModel(
          sourceTitle: '等待配置',
          sourcePayload: '{}',
          status: StoryTemplateTranslationTaskStatus.needsConfiguration,
        ),
      ]) {
        await taskDao.saveTask(task);
      }
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      var calls = 0;

      final resumed = await coordinator.resumeRecoverable(
        complete: (_) async {
          calls += 1;
          return '{}';
        },
      );

      expect(resumed, 0);
      expect(calls, 0);
      expect(
          coordinator.tasks.map((task) => task.status),
          containsAll([
            StoryTemplateTranslationTaskStatus.retryable,
            StoryTemplateTranslationTaskStatus.failed,
            StoryTemplateTranslationTaskStatus.needsConfiguration,
          ]));
    });

    test('失效 legacy fallback 只暂停旧任务且现代快照继续完成', () async {
      final settings = AISettings(
        mode: AIMode.local,
        providers: [
          AiProvider(
            id: 'current-provider',
            type: 'openai',
            name: 'Current',
            apiKey: 'test-key',
            enabled: true,
            selectedModelId: 'current-model',
            models: [AiModel(id: 'current-model')],
          ),
        ],
        activeProviderId: 'current-provider',
        backendModel: 'backend-modern',
        streamEnabled: true,
        resetOnLogout: true,
      );
      final modernProfile = TranslationRequestProfile(
        mode: TranslationExecutionMode.backend,
        modelId: 'backend-modern',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );
      String payloadFor(String name) => jsonEncode(
            StoryRoomTemplatePayload(results: [
              AssistantRoleCardImportResult(
                assistant: AssistantModel(name: name),
              ),
            ]).toJson(),
          );
      final legacy = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Legacy',
        sourcePayload: payloadFor('Legacy role'),
        outputTitle: 'Legacy copy',
        createdAt: 1,
        updatedAt: 1,
      );
      final modern = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Modern',
        sourcePayload: payloadFor('Modern role'),
        outputTitle: 'Modern copy',
        requestProfile: jsonEncode(modernProfile.toJson()),
        createdAt: 2,
        updatedAt: 2,
      );
      await taskDao.saveTask(legacy);
      await taskDao.saveTask(modern);
      final coordinator = StoryTemplateTranslationCoordinator();
      await coordinator.initialize(storage, accountHash: 'test');
      final service = _EchoTranslationChatService();
      var legacyResolutions = 0;
      final executedProfiles = <TranslationRequestProfile>[];

      final resumed = await coordinator.resumeRecoverable(
        resolveLegacyRequestProfile: () {
          legacyResolutions += 1;
          return TranslationModelResolver.legacyFallbackOrNull(
            settings,
            const TranslationModelPreference(
              mode: TranslationModelPreferenceMode.local,
              providerId: 'deleted-provider',
              modelId: 'deleted-model',
              reasoningPolicy: ChatReasoningPolicy.offIfSupported,
            ),
          );
        },
        resolveExecutor: (profile) {
          executedProfiles.add(profile);
          return TranslationStreamExecutor(service: service, profile: profile);
        },
      );

      final storedLegacy = await taskDao.getTask(legacy.id!);
      final storedModern = await taskDao.getTask(modern.id!);
      final outputs = await StoryTemplateDao.create(storage)
          .then((dao) => dao.getTemplates());
      expect(resumed, 1);
      expect(legacyResolutions, 1);
      expect(storedLegacy?.status,
          StoryTemplateTranslationTaskStatus.needsConfiguration);
      expect(storedLegacy?.error, 'legacy_profile_missing');
      expect(
          storedModern?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(executedProfiles, hasLength(1));
      expect(executedProfiles.single.modelId, 'backend-modern');
      expect(outputs, hasLength(1));
    });
  });
}

StoryTemplateTranslationTaskModel _translationTask(
  String name, {
  String modelId = 'model-a',
  String status = StoryTemplateTranslationTaskStatus.queued,
  String chunkPayload = '',
  int? createdAt,
}) =>
    StoryTemplateTranslationTaskModel(
      sourceTitle: '$name source',
      sourcePayload: jsonEncode(StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: name),
        ),
      ]).toJson()),
      outputTitle: '$name copy',
      roleTotal: 1,
      requestProfile: jsonEncode(TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'provider-a',
        modelId: modelId,
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      ).toJson()),
      status: status,
      chunkPayload: chunkPayload,
      createdAt: createdAt,
    );

final class _EchoTranslationChatService
    implements ChatService, OptionsAwareChatService {
  final List<Map<String, dynamic>> payloads = [];

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
      _respond(prompt);

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) =>
      _respond(prompt);

  Stream<StreamEvent> _respond(String prompt) {
    final payload = Map<String, dynamic>.from(
      jsonDecode(prompt.split('\n').last) as Map,
    );
    payloads.add(payload);
    return Stream<StreamEvent>.value(StreamEvent.text(jsonEncode(payload)));
  }
}

final class _HeldTranslationChatService
    implements ChatService, OptionsAwareChatService {
  final Completer<void> requestStarted = Completer<void>();
  final Completer<bool> abortObserved = Completer<bool>();
  late final StreamController<StreamEvent> _controller;
  late final Map<String, dynamic> _payload;

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
    _payload = Map<String, dynamic>.from(
      jsonDecode(prompt.split('\n').last) as Map,
    );
    _controller = StreamController<StreamEvent>(
      onListen: () => requestStarted.complete(),
    );
    options.abortTrigger?.then((_) {
      if (!abortObserved.isCompleted) abortObserved.complete(true);
    });
    return _controller.stream;
  }

  void respond() {
    _controller.add(StreamEvent.text(jsonEncode(_payload)));
    unawaited(_controller.close());
  }
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
