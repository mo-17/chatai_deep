import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_transfer.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
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
      ).toTemplate(title: '午夜案件', sourceTitle: '来源', translated: true);

      final restored = StoryTemplateTransfer.importJson(
        StoryTemplateTransfer.exportJson(template),
      );
      final payload = StoryRoomTemplatePayload.fromTemplate(restored);
      final assistant = payload.results.single.assistant;

      expect(restored.title, '午夜案件');
      expect(restored.translated, isTrue);
      expect(payload.initialOpening, '房间开场');
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
      );
      final task = StoryTemplateTranslationTaskModel(
        sourceTitle: 'Party',
        sourcePayload: jsonEncode(source.toJson()),
        outputTitle: 'Party（简中）',
        roleTotal: 2,
      );
      await taskDao.saveTask(task);
      var call = 0;

      await StoryTemplateTranslationTaskRunner(
        taskDao: taskDao,
        templateDao: templateDao,
        task: task,
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
      final copy = await templateDao.getTemplate(savedTask!.outputTemplateId!);
      final copyPayload = StoryRoomTemplatePayload.fromTemplate(copy!);

      expect(savedTask.status, StoryTemplateTranslationTaskStatus.completed);
      expect(savedTask.roleIndex, 2);
      expect(savedTask.partialPayload, isNotEmpty);
      expect(savedTask.log, contains('中文副本已保存'));
      expect(copy.title, 'Party（简中）');
      expect(copy.translated, isTrue);
      expect(copyPayload.results.map((item) => item.assistant.name),
          ['爱丽丝', '鲍勃']);
      expect(copyPayload.initialOpening, '欢迎。');
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
      expect(restored?.status, StoryTemplateTranslationTaskStatus.completed);
      expect(restored?.log, contains('从检查点自动恢复'));
      expect(restored?.outputTemplateId, isNotNull);
    });
  });
}
