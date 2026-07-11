import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
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

    test('旧任务表会 guarded ALTER 新增租约和字段快照列', () async {
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

    test('运行器从字段检查点恢复时不重复请求已完成字段', () async {
      final templateDao = await StoryTemplateDao.create(storage);
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(
              name: 'Alice',
              prompt: List.filled(3200, 'x').join(),
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
      var calls = 0;
      var cancelled = false;
      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
        leaseOwner: firstOwner,
        complete: (prompt) async {
          calls++;
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          final field = payload.keys.single;
          if (calls == 2) cancelled = true;
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
      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: interrupted,
        leaseOwner: secondOwner,
        complete: (prompt) async {
          final payload =
              jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
          final field = payload.keys.single;
          resumedFields.add(field);
          return jsonEncode({field: '翻译:$field'});
        },
        isCancelled: () => false,
      ).run();

      expect(resumedFields, isNot(contains('name')));
      expect(resumedFields, isNot(contains('description')));
      expect((await taskDao.getTask(task.id!))?.status,
          StoryTemplateTranslationTaskStatus.completed);
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
  });
}
