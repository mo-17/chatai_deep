import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('不翻译时直接返回原始角色卡结果', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Alice'),
    );
    final results = [result];

    final prepared = await TavernRoomImportPreparer.prepare(
      results,
      translateToSimplifiedChinese: false,
      complete: (_) async => throw StateError('不应调用翻译'),
    );

    expect(prepared, same(results));
    expect(prepared.single, same(result));
  });

  test('翻译酒馆房间角色卡并同步 Tavern 备选开场', () async {
    final source = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Alice',
        description: 'A detective.',
        prompt: 'Stay careful.',
        openingMessage: 'Good evening.',
        exampleDialogs: '''
[备选开场白]
She stands by the door.
''',
      ),
      avatarPngBytes: [1, 2, 3],
      sourceName: 'alice.png',
      tavernMeta: const AssistantRoleCardTavernMeta(
        creator: 'card maker',
        alternateGreetings: ['She stands by the door.'],
      ),
    );
    final progresses = <TavernRoomImportProgress>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [source],
      translateToSimplifiedChinese: true,
      onProgress: progresses.add,
      complete: (prompt) async {
        expect(prompt, contains('"name":"Alice"'));
        return jsonEncode({
          'name': '爱丽丝',
          'description': '一位侦探。',
          'prompt': '保持谨慎。',
          'openingMessage': '晚上好。',
          'exampleDialogs': '[备选开场白]\n她站在门边。',
          'memoryBook': '',
        });
      },
    );

    expect(prepared.single.assistant.name, '爱丽丝');
    expect(prepared.single.avatarPngBytes, [1, 2, 3]);
    expect(prepared.single.sourceName, 'alice.png');
    expect(prepared.single.tavernMeta?.creator, 'card maker');
    expect(prepared.single.tavernMeta?.alternateGreetings, ['她站在门边。']);
    expect(progresses.map((item) => item.stage), [
      '准备翻译角色',
      '提交整卡翻译',
      '解析整卡翻译',
      '已翻译',
    ]);
    expect(progresses[1].fieldLabel, '整卡');
    expect(progresses[1].fieldCurrent, 1);
    expect(progresses[1].fieldTotal, 1);
    expect(progresses.last.name, '爱丽丝');
  });

  test('翻译后世界书角色数减少时回退原 memoryBook', () async {
    final memoryBook = [
      'Alice => Name: Alice',
      'Type: character',
      'Personality: careful.',
      '',
      'Bob => Name: Bob',
      'Type: character',
      'Personality: brave.',
    ].join('\n');
    final source = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Party',
        description: 'Many characters.',
        prompt: 'Stay in scene.',
        memoryBook: memoryBook,
      ),
    );
    final progresses = <TavernRoomImportProgress>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [source],
      translateToSimplifiedChinese: true,
      onProgress: progresses.add,
      complete: (prompt) async {
        return jsonEncode({
          'name': '队伍',
          'description': '许多角色。',
          'prompt': '保持场景。',
          'openingMessage': '',
          'exampleDialogs': '',
          'memoryBook': [
            'Alice => Name: Alice',
            'Type: character',
            'Personality: careful.',
          ].join('\n'),
        });
      },
    );

    expect(prepared.single.assistant.name, '队伍');
    expect(prepared.single.assistant.memoryBook, memoryBook);
    expect(
      progresses.map((item) => item.stage),
      contains('世界书角色数减少，已回退原文'),
    );
    final rollback = progresses.firstWhere(
      (item) => item.stage == '世界书角色数减少，已回退原文',
    );
    expect(rollback.detail, '2 -> 1');
    expect(rollback.fieldLabel, '世界书');
  });
}
