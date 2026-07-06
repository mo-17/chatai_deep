import 'dart:async';

import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('对话列表支持下拉刷新入口', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ConversationListPage(skipInitialLoad: true),
    ));

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.text('还没有会话，点右上角新建'), findsOneWidget);
  });

  testWidgets('对话列表全局搜索入口打开全部会话搜索页', (tester) async {
    int? openedProjectId = -1;
    var openedUncategorized = true;
    var openedScopeLabel = '';
    ConversationListDao? openedDao;

    await tester.pumpWidget(MaterialApp(
      home: ConversationListPage(
        skipInitialLoad: true,
        searchPageBuilder: (
          context,
          dao,
          projectId,
          uncategorized,
          scopeLabel,
        ) {
          openedDao = dao;
          openedProjectId = projectId;
          openedUncategorized = uncategorized;
          openedScopeLabel = scopeLabel;
          return Scaffold(
            appBar: AppBar(title: const Text('测试搜索页')),
            body: Text('范围：$scopeLabel'),
          );
        },
      ),
    ));

    await tester
        .tap(find.byKey(const ValueKey('conversation_list_global_search')));
    await tester.pumpAndSettle();

    expect(openedDao, isNull);
    expect(openedProjectId, isNull);
    expect(openedUncategorized, isFalse);
    expect(openedScopeLabel, '全部会话');
    expect(find.text('范围：全部会话'), findsOneWidget);
  });

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
            sourceLabel: '历史消息',
            targetMessageCreatedAt: 12345,
            messageSnippets: [
              'Alpha 的 UI 自动化回归',
              '第二处 Alpha 命中',
              '第三处 Alpha 命中',
            ],
          ),
        ],
        searchFavorites: (query) async => [
          FavoriteSearchResult(
            favorite: FavoriteModel(
              ownerName: 'AI',
              content: 'Alpha 会话内收藏',
              createdAt: 998,
            ),
            cid: 42,
            conversationTitle: 'Alpha 原会话',
          ),
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
    final richTexts =
        tester.widgetList<RichText>(find.byType(RichText)).toList();
    expect(
      richTexts.any((widget) =>
          widget.text.toPlainText().contains('历史消息 · Alpha 的 UI 自动化回归')),
      isTrue,
    );
    expect(
      richTexts.any((widget) =>
          widget.text.toPlainText().contains('来自「Alpha 原会话」 · Alpha 会话内收藏')),
      isTrue,
    );
    expect(find.text('展开 2 处命中'), findsOneWidget);
    expect(find.textContaining('第二处 Alpha 命中'), findsNothing);
    await tester.tap(find.text('展开 2 处命中'));
    await tester.pump(const Duration(milliseconds: 300));
    final expandedRichTexts =
        tester.widgetList<RichText>(find.byType(RichText)).toList();
    expect(
      expandedRichTexts
          .any((widget) => widget.text.toPlainText().contains('第二处 Alpha 命中')),
      isTrue,
    );
    expect(
      expandedRichTexts
          .any((widget) => widget.text.toPlainText().contains('第三处 Alpha 命中')),
      isTrue,
    );
    expect(find.text('收起命中片段'), findsOneWidget);
    expect(find.byTooltip('定位到命中消息'), findsOneWidget);
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

  testWidgets('搜索页按命中来源分组展示会话结果', (tester) async {
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
              cid: 11,
              icon: '',
              title: 'Alpha 标题会话',
            ),
            snippet: 'Alpha 标题会话',
            sourceLabel: '标题',
          ),
          ConversationSearchResult(
            conversation: ConversationModel(
              cid: 12,
              icon: '',
              title: '最近消息会话',
            ),
            snippet: 'Alpha 最近消息',
            sourceLabel: '最近消息',
          ),
          ConversationSearchResult(
            conversation: ConversationModel(
              cid: 13,
              icon: '',
              title: '历史消息会话',
            ),
            snippet: 'Alpha 历史消息',
            sourceLabel: '历史消息',
            targetMessageCreatedAt: 13,
          ),
        ],
        searchFavorites: (_) async => const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'Alpha');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('conversation_search_sort_summary')),
        findsOneWidget);
    expect(find.textContaining('按标题、最近消息、历史消息相关性分组'), findsOneWidget);
    expect(find.text('标题命中（1）'), findsOneWidget);
    expect(find.text('最近消息命中（1）'), findsOneWidget);
    expect(find.text('历史消息命中（1）'), findsOneWidget);
    expect(find.text('Alpha 标题会话'), findsOneWidget);
    expect(find.text('最近消息会话'), findsOneWidget);
    expect(find.text('历史消息会话'), findsOneWidget);
  });

  testWidgets('项目内搜索可切换到全部会话并重新搜索', (tester) async {
    final scopes = <({int? projectId, bool uncategorized})>[];
    await tester.pumpWidget(MaterialApp(
      home: ConversationSearchPage(
        dao: null,
        projectId: 7,
        uncategorized: false,
        scopeLabel: '项目 A',
        searchConversations: (
          query, {
          int? projectId,
          bool uncategorized = false,
          int? assistantId,
          String? modelId,
          int? updatedAfter,
          int? updatedBefore,
        }) async {
          scopes.add((projectId: projectId, uncategorized: uncategorized));
          return [
            ConversationSearchResult(
              conversation: ConversationModel(
                cid: projectId == null ? 9 : 7,
                icon: '',
                title: projectId == null ? '全局结果' : '项目结果',
              ),
              snippet: query,
            ),
          ];
        },
        searchFavorites: (_) async => const [],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('conversation_search_scope_local')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('conversation_search_scope_all')),
        findsOneWidget);
    expect(find.text('项目 A'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('conversation_search_input')), 'Alpha');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('项目结果'), findsOneWidget);
    expect(scopes.single.projectId, 7);
    expect(scopes.single.uncategorized, isFalse);

    await tester
        .tap(find.byKey(const ValueKey('conversation_search_scope_all')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('全局结果'), findsOneWidget);
    expect(scopes.last.projectId, isNull);
    expect(scopes.last.uncategorized, isFalse);
  });

  testWidgets('未分类搜索切换全部会话时会取消未分类过滤', (tester) async {
    final scopes = <({int? projectId, bool uncategorized})>[];
    await tester.pumpWidget(MaterialApp(
      home: ConversationSearchPage(
        dao: null,
        projectId: null,
        uncategorized: true,
        scopeLabel: '未分类',
        searchConversations: (
          query, {
          int? projectId,
          bool uncategorized = false,
          int? assistantId,
          String? modelId,
          int? updatedAfter,
          int? updatedBefore,
        }) async {
          scopes.add((projectId: projectId, uncategorized: uncategorized));
          return [
            ConversationSearchResult(
              conversation: ConversationModel(
                cid: uncategorized ? 1 : 2,
                icon: '',
                title: uncategorized ? '未分类结果' : '全部结果',
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
        find.byKey(const ValueKey('conversation_search_input')), 'Beta');
    await tester.tap(find.byKey(const ValueKey('conversation_search_submit')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未分类结果'), findsOneWidget);
    expect(scopes.single.uncategorized, isTrue);

    await tester
        .tap(find.byKey(const ValueKey('conversation_search_scope_all')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('全部结果'), findsOneWidget);
    expect(scopes.last.projectId, isNull);
    expect(scopes.last.uncategorized, isFalse);
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

  testWidgets('点击会话搜索结果会返回会话和命中消息锚点', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('open'),
            onPressed: () async {
              final result = await Navigator.push<ConversationSearchSelection>(
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
                        sourceLabel: '历史消息',
                        targetMessageCreatedAt: 456,
                        messageHits: const [
                          ConversationSearchHit(
                            snippet: '第一处 jump 命中',
                            createdAt: 456,
                          ),
                          ConversationSearchHit(
                            snippet: '第二处 jump 命中',
                            createdAt: 789,
                          ),
                        ],
                      ),
                    ],
                    searchFavorites: (_) async => const [],
                  ),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'cid=${result?.conversation.cid},target=${result?.targetMessageCreatedAt}',
                    ),
                  ),
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
    await tester.tap(find.text('展开 1 处命中'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .tap(find.byKey(const ValueKey('conversation_search_hit_88_789')));
    await tester.pumpAndSettle();

    expect(find.text('cid=88,target=789'), findsOneWidget);
  });
}
