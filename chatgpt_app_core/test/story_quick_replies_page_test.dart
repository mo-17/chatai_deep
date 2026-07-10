import 'dart:convert';

import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_quick_replies_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('快捷回复页可新增分组、条目并保存到房间', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = StoryRoomModel(id: 7, title: '雨夜');
    StoryRoomModel? savedRoom;

    await tester.pumpWidget(
      MaterialApp(
        home: StoryQuickRepliesPage(
          room: room,
          onSave: (value) async => savedRoom = value,
        ),
      ),
    );

    expect(find.text('还没有快捷回复分组'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('story_quick_replies_add_group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('story_quick_reply_group_key')),
      'common',
    );
    await tester.enterText(
      find.byKey(const ValueKey('story_quick_reply_group_label')),
      '常用',
    );
    await tester
        .tap(find.byKey(const ValueKey('story_quick_reply_dialog_save')));
    await tester.pumpAndSettle();

    expect(find.text('常用'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('story_quick_replies_add_item_common')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('story_quick_reply_item_key')),
      'greet',
    );
    await tester.enterText(
      find.byKey(const ValueKey('story_quick_reply_item_label')),
      '问候',
    );
    await tester.enterText(
      find.byKey(const ValueKey('story_quick_reply_item_content')),
      '你好，{{user}}。',
    );
    await tester
        .tap(find.byKey(const ValueKey('story_quick_reply_dialog_save')));
    await tester.pumpAndSettle();

    expect(find.text('问候'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story_quick_replies_save')));
    await tester.pumpAndSettle();

    expect(savedRoom, same(room));
    final restored =
        StoryQuickReplyCollectionModel.tryParse(room.quickRepliesJson);
    expect(restored.roomId, 7);
    expect(restored.groups.single.key, 'common');
    expect(restored.groups.single.items.single.content, '你好，{{user}}。');
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷回复页可切换启用和立即发送并移动条目', (tester) async {
    final room = StoryRoomModel(
      id: 3,
      title: '房间',
    )..quickRepliesJson = jsonEncode({
        'roomId': 3,
        'groups': [
          {
            'key': 'common',
            'label': '常用',
            'items': [
              {
                'key': 'first',
                'label': '第一条',
                'content': '1',
                'sortOrder': 0,
              },
              {
                'key': 'second',
                'label': '第二条',
                'content': '2',
                'sortOrder': 1,
              },
            ],
          },
        ],
      });

    await tester.pumpWidget(
      MaterialApp(
        home: StoryQuickRepliesPage(room: room, onSave: (_) async {}),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('story_quick_replies_item_enabled_first')),
    );
    await tester.tap(
      find.byKey(const ValueKey('story_quick_replies_item_immediate_first')),
    );
    await tester.tap(
      find.byKey(const ValueKey('story_quick_replies_item_down_first')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('story_quick_replies_save')));
    await tester.pumpAndSettle();
    final saved =
        StoryQuickReplyCollectionModel.tryParse(room.quickRepliesJson);
    expect(saved.groups.single.items.first.key, 'second');
    final first =
        saved.groups.single.items.singleWhere((item) => item.key == 'first');
    expect(first.enabled, isFalse);
    expect(first.sendImmediately, isTrue);
  });
}
