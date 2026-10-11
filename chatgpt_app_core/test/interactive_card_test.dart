import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> checklistJson() => {
      'schema': 'chatai.card',
      'version': 1,
      'type': 'checklist',
      'title': '出发前',
      'items': [
        {'id': 'ticket', 'text': '确认车票'},
        {'id': 'bag', 'text': '整理行李'}
      ],
    };
Map<String, dynamic> comparisonJson() => {
      'schema': 'chatai.card',
      'version': 1,
      'type': 'comparison',
      'title': '方案比较',
      'options': [
        {'id': 'a', 'label': '方案 A'},
        {'id': 'b', 'label': '方案 B'}
      ],
      'rows': [
        {
          'id': 'cost',
          'label': '成本',
          'values': <String, dynamic>{'a': '较低', 'b': '较高'}
        }
      ],
    };
String cardFence(Map<String, dynamic> value) =>
    '```chatai-card\n${jsonEncode(value)}\n```\n';

void main() {
  test('混合正文保留顺序和逐字原文，非法候选也占 ordinal', () {
    const invalid = '```chatai-card\n{"bad":true}\n```\n';
    final raw =
        '开头 [1]\n$invalid${cardFence(checklistJson())}中间\n${cardFence(comparisonJson())}结尾';
    final parts = InteractiveCardParser.parse(raw);
    final cards = parts.whereType<CardProjection>().toList();
    expect(cards.map((c) => c.ordinal), [1, 2]);
    expect(cards.first.card, isA<ChecklistCard>());
    expect(cards.last.card, isA<ComparisonCard>());
    expect(
        parts
            .map((p) =>
                p is CardProjection ? p.original : (p as CardPlainText).text)
            .join(),
        raw);
  });
  test('相同卡片 hash 相同而 ordinal key 不同；JSON 字段顺序不影响 hash', () {
    final a = checklistJson();
    final b = Map<String, dynamic>.fromEntries(a.entries.toList().reversed);
    final cards = InteractiveCardParser.parse('${cardFence(a)}${cardFence(b)}')
        .whereType<CardProjection>()
        .toList();
    expect(cards[0].card.schemaHash, cards[1].card.schemaHash);
    expect(cards[0].key, isNot(cards[1].key));
  });
  test('对比 values 以方案顺序规范化', () {
    final a = comparisonJson(), b = comparisonJson();
    (b['rows'] as List).first['values'] = {'b': '较高', 'a': '较低'};
    expect(InteractiveCardParser.tryParseJson(jsonEncode(a))!.schemaHash,
        InteractiveCardParser.tryParseJson(jsonEncode(b))!.schemaHash);
  });
  final invalids = <String, void Function(Map<String, dynamic>)>{
    '未知字段': (j) => j['checked'] = true,
    '缺少字段': (j) => j.remove('title'),
    '未知 schema': (j) => j['schema'] = 'other',
    '未知版本': (j) => j['version'] = 2,
    '非整数版本': (j) => j['version'] = 1.0,
    '未知类型': (j) => j['type'] = 'html',
    '空白标题': (j) => j['title'] = ' \n',
    '超长标题': (j) => j['title'] = '字' * 121,
    '非字符串标题': (j) => j['title'] = 1,
    '空 items': (j) => j['items'] = [],
    '21 items': (j) =>
        j['items'] = List.generate(21, (i) => {'id': 'i$i', 'text': '事项'}),
    '重复 id': (j) => j['items'][1]['id'] = 'ticket',
    '非法 id': (j) => j['items'][0]['id'] = '../path',
    '超长 id': (j) => j['items'][0]['id'] = 'a' * 65,
    '空事项': (j) => j['items'][0]['text'] = '\t',
    '超长事项': (j) => j['items'][0]['text'] = '🙂' * 501,
    'item 未知字段': (j) => j['items'][0]['url'] = 'https://example.com',
  };
  for (final e in invalids.entries) {
    test('拒绝${e.key}且保留原文，后续合法卡继续展示', () {
      final value = checklistJson();
      e.value(value);
      final raw = cardFence(value);
      final parts =
          InteractiveCardParser.parse('$raw${cardFence(comparisonJson())}');
      expect((parts.first as CardPlainText).text, raw);
      expect(parts.whereType<CardProjection>().single.ordinal, 1);
    });
  }
  test('严格拒绝嵌套重复键、转义等价重复键及非 JSON 修补', () {
    final raw = jsonEncode(checklistJson());
    for (final value in [
      raw.replaceFirst('"schema":', '"schema":"chatai.card","schema":'),
      raw.replaceFirst('"id":"ticket"', '"id":"ticket","i\\u0064":"ticket"'),
      raw.replaceFirst('"text":"确认车票"', '"text":"确认车票","text":"重复"'),
      '$raw trailing',
      raw.replaceFirst('"version":1', '"version":01'),
      raw.replaceFirst('"version":1', '"version":NaN'),
      raw.replaceFirst('"title":', '/* comment */"title":'),
    ]) {
      expect(InteractiveCardParser.tryParseJson(value), isNull);
    }
  });
  test('嵌套超过 8 层拒绝；JSON 和正文预算保留原文', () {
    final deep = '${'[' * 9}0${']' * 9}';
    expect(InteractiveCardParser.tryParseJson(deep), isNull);
    final huge =
        '```chatai-card\n${' ' * (32 * 1024 + 1)}${jsonEncode(checklistJson())}\n```';
    expect(
        (InteractiveCardParser.parse(huge).single as CardPlainText).text, huge);
    final raw = '${'字' * (512 * 1024 ~/ 3 + 1)}${cardFence(checklistJson())}';
    expect(
        (InteractiveCardParser.parse(raw).single as CardPlainText).text, raw);
  });
  test('精确 JSON 字节上限和最大项数', () {
    final value = checklistJson()
      ..['items'] = List.generate(20, (i) => {'id': 'i$i', 'text': '字' * 500});
    final raw = jsonEncode(value);
    expect(InteractiveCardParser.tryParseJson(raw), isNotNull);
    final padded = raw + ' ' * (32 * 1024 - utf8.encode(raw).length);
    expect(InteractiveCardParser.tryParseJson(padded), isNotNull);
    expect(InteractiveCardParser.tryParseJson('$padded '), isNull);
  });
  test('对比边界、重复 id、精确 values 键集和未知字段', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (j) => j['options'].removeLast(),
      (j) =>
          j['options'] = List.generate(5, (i) => {'id': 'i$i', 'label': '方案'}),
      (j) => j['options'][1]['id'] = 'a',
      (j) => j['rows'] = [],
      (j) => j['rows'] = List.generate(
          13,
          (i) => {
                'id': 'i$i',
                'label': '行',
                'values': {'a': '一', 'b': '二'}
              }),
      (j) => j['rows'].add(j['rows'].first),
      (j) => j['rows'][0]['values'].remove('b'),
      (j) => j['rows'][0]['values']['c'] = '三',
      (j) => j['rows'][0]['values']['a'] = 1,
      (j) => j['rows'][0]['label'] = 'a' * 121,
      (j) => j['options'][0]['label'] = ' ',
      (j) => j['rows'][0]['values']['a'] = 'a' * 501,
      (j) => j['rows'][0]['extra'] = true,
    ]) {
      final value = comparisonJson();
      mutate(value);
      expect(InteractiveCardParser.tryParseJson(jsonEncode(value)), isNull);
    }
  });
  test('每条正文最多四卡，多余原文不裁剪', () {
    final fence = cardFence(checklistJson());
    final parts = InteractiveCardParser.parse(fence * 5);
    expect(parts.whereType<CardProjection>().length, 4);
    expect((parts.last as CardPlainText).text, fence);
    expect(
        InteractiveCardParser.parse(fence * 3, cardLimit: 1)
            .whereType<CardProjection>()
            .length,
        1);
  });
  test('多个正文块共享 512KiB 扫描预算', () {
    expect(
        InteractiveCardParser.fitsMessageBudget(
            ['a' * (256 * 1024), 'a' * (256 * 1024)]),
        isTrue);
    expect(
        InteractiveCardParser.fitsMessageBudget(
            ['a' * (256 * 1024), 'a' * (256 * 1024), '字']),
        isFalse);
  });
  test('独立围栏、CRLF、普通代码围栏、未闭合保留', () {
    final fence = cardFence(checklistJson());
    expect(
        InteractiveCardParser.parse(fence.replaceAll('\n', '\r\n'))
            .whereType<CardProjection>()
            .length,
        1);
    for (final raw in [
      '前缀$fence',
      '```text\n$fence```\n',
      fence.substring(0, fence.length - 4)
    ]) {
      expect(
          (InteractiveCardParser.parse(raw).single as CardPlainText).text, raw);
    }
  });
  test('每个流式切点均保持原文，收到完整闭合也必须等待 completed', () {
    final raw = '开始\n${cardFence(checklistJson())}结束';
    for (var i = 0; i <= raw.length; i++) {
      final partial = raw.substring(0, i);
      expect(
          (InteractiveCardParser.parse(partial, completed: false).single
                  as CardPlainText)
              .text,
          partial);
    }
  });
  test('坏本地状态逐卡忽略，copyWith 和持久化保留原文/协议', () {
    final raw = '${cardFence(checklistJson())}${cardFence(checklistJson())}';
    final cards =
        InteractiveCardParser.parse(raw).whereType<CardProjection>().toList();
    final block = MainTextBlock(
        id: 'b',
        messageId: 'm',
        createdAt: 1,
        status: MessageBlockStatus.success,
        content: raw,
        protocolMessages: const [
          {'role': 'assistant', 'content': '逐字 原文\n'}
        ]);
    for (final bad in [
      null,
      [],
      true,
      {
        'version': 2,
        'checkedItemIds': ['ticket']
      },
      {
        'version': 1,
        'checkedItemIds': ['ticket', 'ticket']
      },
      {
        'version': 1,
        'checkedItemIds': ['unknown']
      },
      {
        'version': 1,
        'checkedItemIds': [1]
      }
    ]) {
      final encoded = block.toJson()
        ..['localCardStates'] = {
          cards[0].key: bad,
          cards[1].key: {
            'version': 1,
            'checkedItemIds': ['bag']
          },
          '0:badHash': {
            'version': 1,
            'checkedItemIds': ['ticket']
          }
        };
      final decoded = MessageBlock.decodeList(jsonEncode([encoded])).single
          as MainTextBlock;
      expect(decoded.content, raw);
      expect(decoded.protocolMessages, block.protocolMessages);
      expect(decoded.localCardStates.keys, [cards[1].key]);
      expect(
          decoded
              .copyWith(status: MessageBlockStatus.paused)
              .localCardStates[cards[1].key]!
              .checkedItemIds,
          {'bag'});
      expect(
          (MessageBlock.decodeList(MessageBlock.encodeList([decoded])).single
                  as MainTextBlock)
              .content,
          raw);
    }
    final changed = raw.replaceAll('确认车票', '确认机票');
    expect(
        decodeLocalCardStates({
          cards[0].key: {
            'version': 1,
            'checkedItemIds': ['ticket']
          }
        }, changed),
        isEmpty);
    for (final bad in [true, [], 'wrong']) {
      expect(
          MessageBlock.decodeList(
              jsonEncode([block.toJson()..['localCardStates'] = bad])).single,
          isA<MainTextBlock>());
    }
  });
  test('导出包含勾选和正确转义，卡片数据作为纯文本', () {
    final card =
        InteractiveCardParser.tryParseJson(jsonEncode(checklistJson()))!;
    expect(exportInteractiveCard(card, checked: {'ticket'}),
        contains('- [x] 确认车票'));
    expect(exportInteractiveCard(card, checked: {'ticket'}),
        contains('- [ ] 整理行李'));
    final value = comparisonJson();
    value['title'] = 'a*b';
    value['rows'][0]['values']['a'] = 'x|y\nz`w\\v';
    final export = exportInteractiveCard(
        InteractiveCardParser.tryParseJson(jsonEncode(value))!);
    expect(export, contains(r'a\*b'));
    expect(export, contains(r'x\|y / z\`w\\v'));
    final plain = checklistJson()
      ..['items'][0]['text'] =
          '<script>alert(1)</script> https://example.com /etc/passwd';
    expect(
        (InteractiveCardParser.tryParseJson(jsonEncode(plain)) as ChecklistCard)
            .items[0]
            .text,
        plain['items'][0]['text']);
  });
}
