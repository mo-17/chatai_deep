import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
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
  });
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
