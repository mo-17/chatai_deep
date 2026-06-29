import 'dart:async';

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
          int? updatedBefore,
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
          int? updatedBefore,
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

  testWidgets('搜索异常会展示错误态并收起加载', (tester) async {
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
          int? updatedBefore,
        }) async {
          throw StateError('boom');
        },
        searchFavorites: (_) async => const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'Error');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('conversation_search_error')),
        findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation_search_loading')),
        findsNothing);
  });

  testWidgets('连续搜索时慢响应不会覆盖最后一次结果', (tester) async {
    final blockers = <String, Future<void>>{};
    final completions = <String, void Function()>{};
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
          int? updatedBefore,
        }) async {
          final completer = Completer<void>();
          blockers[query] = completer.future;
          completions[query] = completer.complete;
          await completer.future;
          return [
            ConversationSearchResult(
              conversation: ConversationModel(
                cid: query == 'first' ? 1 : 2,
                icon: '',
                title: query == 'first' ? '旧结果' : '新结果',
              ),
              snippet: query,
            ),
          ];
        },
        searchFavorites: (_) async => const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'first');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'second');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump();

    completions['second']!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);

    completions['first']!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
    expect(blockers.keys, containsAll(['first', 'second']));
  });

  testWidgets('点击会话搜索结果会返回对应 ConversationModel', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('open'),
            onPressed: () async {
              final result = await Navigator.push<ConversationModel>(
                context,
                MaterialPageRoute(
                  builder: (_) => ConversationSearchPage(
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
                      int? updatedBefore,
                    }) async =>
                        [
                      ConversationSearchResult(
                        conversation: ConversationModel(
                          cid: 88,
                          icon: '',
                          title: '可跳转会话',
                        ),
                        snippet: 'jump',
                      ),
                    ],
                    searchFavorites: (_) async => const [],
                  ),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('cid=${result?.cid}')),
                );
              }
            },
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'jump');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('可跳转会话'));
    await tester.pumpAndSettle();

    expect(find.text('cid=88'), findsOneWidget);
  });
}
