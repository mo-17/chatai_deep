import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('搜索页展示会话与收藏结果，收藏可复制', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ConversationSearchPage(
        dao: null,
        projectId: null,
        uncategorized: false,
        scopeLabel: '全部会话',
        searchConversations: (
          query, {
          int? projectId,
          bool uncategorized = false,
          int? assistantId,
          String? modelId,
          int? updatedAfter,
        }) async =>
            [
          ConversationSearchResult(
            conversation: ConversationModel(
              cid: 1,
              icon: '',
              title: 'Alpha 项目',
            ),
            snippet: 'Alpha 的 UI 自动化回归',
          ),
        ],
        searchFavorites: (query) async => [
          FavoriteSearchResult(
            favorite: FavoriteModel(
              ownerName: 'AI',
              content: 'Alpha 收藏片段',
              createdAt: 999,
            ),
          ),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('Alpha 项目'), findsOneWidget);
    expect(find.byType(RichText), findsWidgets);

    await tester.tap(find.byTooltip('复制'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索页清空关键词后恢复空态并清理结果', (tester) async {
    var searchCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: ConversationSearchPage(
        dao: null,
        projectId: 7,
        uncategorized: false,
        scopeLabel: '当前项目',
        searchConversations: (
          query, {
          int? projectId,
          bool uncategorized = false,
          int? assistantId,
          String? modelId,
          int? updatedAfter,
        }) async {
          searchCount += 1;
          expect(projectId, 7);
          return [
            ConversationSearchResult(
              conversation: ConversationModel(
                cid: 2,
                icon: '',
                title: 'Beta 项目',
              ),
              snippet: 'Beta 结果',
            ),
          ];
        },
        searchFavorites: (_) async => const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'Beta');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Beta 项目'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(searchCount, 1);
    expect(find.text('输入关键词搜索'), findsOneWidget);
    expect(find.text('Beta 项目'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
