import 'dart:convert';

import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('条目 JSON 往返保留稳定 key、开关和排序字段', () {
    final item = StoryQuickReplyModel(
      key: '  greet  ',
      label: '问候',
      content: '你好，{{user}}。',
      enabled: false,
      sendImmediately: true,
      sortOrder: 4,
    );

    final restored = StoryQuickReplyModel.fromJson(item.toJson());
    expect(restored.key, 'greet');
    expect(restored.label, '问候');
    expect(restored.content, '你好，{{user}}。');
    expect(restored.enabled, isFalse);
    expect(restored.sendImmediately, isTrue);
    expect(restored.sortOrder, 4);
    expect(StoryQuickReplyModel(label: '稳定标签').key, '稳定标签');
  });

  test('变量替换只处理四个已知变量，未知变量原样保留', () {
    final item = StoryQuickReplyModel(
      key: 'scene',
      label: '场景',
      content: '{{char}} 对 {{user}} 说：{{input}}（地点：{{room}}，{{unknown}}）',
    );

    expect(
      item.resolveContent(
        char: '艾琳',
        user: '小林',
        room: '图书馆',
        input: '请坐',
      ),
      '艾琳 对 小林 说：请坐（地点：图书馆，{{unknown}}）',
    );
    expect(
      StoryQuickReplyModel.replaceVariables(
        '{{char}}',
        char: '{{user}}',
        user: '不会二次替换',
      ),
      '{{user}}',
    );
  });

  test('集合按组和条目排序，并可过滤禁用项', () {
    final collection = StoryQuickReplyCollectionModel(
      roomId: 7,
      groups: [
        StoryQuickReplyGroupModel(
          roomId: 7,
          key: 'scene',
          label: '场景',
          sortOrder: 2,
          items: [
            StoryQuickReplyModel(key: 'b', label: 'B', sortOrder: 2),
            StoryQuickReplyModel(
              key: 'a',
              label: 'A',
              sortOrder: 1,
              enabled: false,
            ),
          ],
        ),
        StoryQuickReplyGroupModel(
          roomId: 7,
          key: 'common',
          label: '常用',
          sortOrder: 1,
          items: [StoryQuickReplyModel(key: 'hello', label: '你好')],
        ),
        StoryQuickReplyGroupModel(
          roomId: 7,
          key: 'hidden',
          label: '隐藏',
          enabled: false,
          sortOrder: 0,
        ),
      ],
    );

    expect(collection.sortedGroups().map((group) => group.key),
        ['hidden', 'common', 'scene']);
    expect(collection.sortedGroups(enabledOnly: true).map((group) => group.key),
        ['common', 'scene']);
    expect(
        collection
            .itemsForGroup('scene', enabledOnly: true)
            .map((item) => item.key),
        ['b']);
    expect(collection.filterItems().map((item) => item.key), ['hello', 'b']);
  });

  test('非法 JSON 安全回落，嵌套条目和总条目数受上限保护', () {
    expect(
        StoryQuickReplyCollectionModel.tryParse('{bad json}').groups, isEmpty);
    expect(StoryQuickReplyCollectionModel.tryParse(42).groups, isEmpty);

    final groups = [
      for (var groupIndex = 0;
          groupIndex < StoryQuickReplyLimits.maxGroups + 5;
          groupIndex++)
        {
          'key': 'group-$groupIndex',
          'label': '分组 $groupIndex',
          'items': [
            for (var itemIndex = 0;
                itemIndex < StoryQuickReplyLimits.maxItemsPerGroup + 5;
                itemIndex++)
              {
                'key': 'item-$groupIndex-$itemIndex',
                'label': '条目',
                'content': '内容',
              },
          ],
        },
    ];
    final restored = StoryQuickReplyCollectionModel.tryParse(
      jsonEncode({'roomId': 9, 'groups': groups}),
    );

    expect(restored.roomId, 9);
    expect(restored.groups.length, StoryQuickReplyLimits.maxGroups);
    expect(
      restored.groups
          .fold<int>(0, (total, group) => total + group.items.length),
      StoryQuickReplyLimits.maxItems,
    );
    expect(restored.groups.first.roomId, 9);
  });

  test('Tavern Quick Replies 只导入声明式文本并跳过命令脚本', () {
    final collection = StoryQuickReplyCollectionModel.fromTavernExtensions({
      'quick_replies': {
        'sets': [
          {
            'name': '场景动作',
            'items': [
              {
                'id': 'look',
                'label': '观察',
                'message': '{{user}} 环顾 {{room}}。',
                'autoExecute': true,
              },
              {'name': '脚本', 'command': '/setvar key=value'},
            ],
          },
        ],
      },
    }, roomId: 7);

    expect(collection.groups, hasLength(1));
    expect(collection.groups.single.label, '场景动作');
    expect(collection.groups.single.items, hasLength(1));
    expect(collection.groups.single.items.single.key, 'look');
    expect(collection.groups.single.items.single.sendImmediately, isTrue);
  });

  test('外部快捷回复限制文本长度并跳过重复分组和条目 key', () {
    final collection = StoryQuickReplyCollectionModel.tryParse({
      'groups': [
        {
          'key': 'same',
          'label': 'a' * 200,
          'items': [
            {'key': 'item', 'content': 'x' * 5000},
            {'key': 'item', 'content': '重复'},
          ],
        },
        {'key': 'same', 'items': []},
      ],
    });

    expect(collection.groups, hasLength(1));
    expect(collection.groups.single.label.length,
        StoryQuickReplyLimits.maxLabelLength);
    expect(collection.groups.single.items, hasLength(1));
    expect(collection.groups.single.items.single.content.length,
        StoryQuickReplyLimits.maxContentLength);
  });
}
