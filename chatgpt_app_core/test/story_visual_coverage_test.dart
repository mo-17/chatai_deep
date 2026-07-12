import 'dart:convert';

import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_quick_replies_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget helperHarness(ThemeData theme) {
    return MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextField(
                key: const ValueKey('story_test_field'),
                decoration: InputDecoration(
                  border: storyInputBorder(context),
                ),
              ),
              const StoryAdaptiveSurface(
                animeKey: ValueKey('anime_story_test_surface'),
                child: Text('surface child'),
              ),
              const StoryMessageBubble(
                isUser: true,
                child: Text('user bubble'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('story helper 在 classic 保持旧结构，anime 启用语义外观', (tester) async {
    await tester
        .pumpWidget(helperHarness(AppThemeFactory.classic(Colors.blue)));

    final classicField = tester
        .widget<TextField>(find.byKey(const ValueKey('story_test_field')));
    final classicBorder = classicField.decoration?.border as OutlineInputBorder;
    expect(classicBorder.borderRadius.topLeft.x, 4);
    expect(
        find.byKey(const ValueKey('anime_story_test_surface')), findsNothing);
    expect(find.byType(Card), findsOneWidget);

    await tester.pumpWidget(helperHarness(AppThemeFactory.anime()));
    await tester.pumpAndSettle();

    final animeField = tester
        .widget<TextField>(find.byKey(const ValueKey('story_test_field')));
    final animeBorder = animeField.decoration?.border as OutlineInputBorder;
    expect(animeBorder.borderRadius.topLeft.x, 18);
    expect(
      find.byKey(const ValueKey('anime_story_test_surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime_story_user_bubble')),
      findsOneWidget,
    );
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('anime 快捷回复在 320px 大字体下可换行且操作至少 44dp', (tester) async {
    tester.view.physicalSize = const Size(320, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = StoryRoomModel(id: 9, title: '月夜')
      ..quickRepliesJson = jsonEncode({
        'roomId': 9,
        'groups': [
          {
            'key': 'common',
            'label': '常用回应',
            'items': [
              {
                'key': 'greet',
                'label': '向角色问好',
                'content': '晚上好，{{char}}。',
              },
            ],
          },
        ],
      });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 667),
            textScaler: TextScaler.linear(1.6),
          ),
          child: StoryQuickRepliesPage(room: room, onSave: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final groupUp = tester.widget<IconButton>(
      find.byKey(const ValueKey('story_quick_replies_group_up_common')),
    );
    final itemEdit = tester.widget<IconButton>(
      find.byKey(const ValueKey('story_quick_replies_item_edit_greet')),
    );
    expect(groupUp.constraints?.minWidth, greaterThanOrEqualTo(44));
    expect(groupUp.constraints?.minHeight, greaterThanOrEqualTo(44));
    expect(itemEdit.constraints?.minWidth, greaterThanOrEqualTo(44));
    expect(itemEdit.constraints?.minHeight, greaterThanOrEqualTo(44));
    final groupUpSize = tester.getSize(
      find.byKey(const ValueKey('story_quick_replies_group_up_common')),
    );
    expect(groupUpSize.width, greaterThanOrEqualTo(44));
    expect(groupUpSize.height, greaterThanOrEqualTo(44));
    final itemEditSize = tester.getSize(
      find.byKey(const ValueKey('story_quick_replies_item_edit_greet')),
    );
    expect(itemEditSize.width, greaterThanOrEqualTo(44));
    expect(itemEditSize.height, greaterThanOrEqualTo(44));
    final immediate = find.byKey(
      const ValueKey('story_quick_replies_item_immediate_greet'),
    );
    final itemMenu = find.byKey(
      const ValueKey('story_quick_replies_item_menu_greet'),
    );
    expect(
      tester.getTopLeft(itemMenu).dy,
      greaterThan(tester.getTopLeft(immediate).dy),
    );
    expect(kStoryMinTouchTarget, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('anime story 空态在横屏 2x 字体下可滚动且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 240),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: StoryAdaptiveEmptyState(
              classicChild: Text('经典空态'),
              icon: Icons.auto_stories_outlined,
              title: '等待下一段故事开始',
              subtitle: '这是用于验证横屏和超大字体的较长说明文字。',
              action: FilledButton(
                onPressed: null,
                child: Text('开始创作'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('anime_story_empty_state')),
      findsOneWidget,
    );
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
