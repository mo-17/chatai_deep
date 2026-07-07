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
}
