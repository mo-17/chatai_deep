import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('parseCitationTextSegments', () {
    test('有效索引映射到 webResults 对应 URL', () {
      final segments = parseCitationTextSegments(
        content: '这是正文[1]和[2]。',
        webResults: const [
          WebSearchResult(url: 'https://source1.com'),
          WebSearchResult(url: 'https://source2.com'),
        ],
      );

      expect(segments, hasLength(5));
      expect(segments[0].text, '这是正文');
      expect(segments[0].citationIndex, isNull);
      expect(segments[0].url, isNull);
      expect(segments[1].text, '[1]');
      expect(segments[1].citationIndex, 1);
      expect(segments[1].url, 'https://source1.com');
      expect(segments[2].text, '和');
      expect(segments[3].text, '[2]');
      expect(segments[3].citationIndex, 2);
      expect(segments[3].url, 'https://source2.com');
      expect(segments[4].text, '。');
      expect(segments[4].citationIndex, isNull);
      expect(segments[4].url, isNull);
    });

    test('越界或空 URL 不可点击，保留普通文本', () {
      final segments = parseCitationTextSegments(
        content: '[1][3][2]',
        webResults: const [
          WebSearchResult(url: ''),
          WebSearchResult(url: 'https://ok.com'),
        ],
      );

      expect(segments, hasLength(3));
      expect(segments[0].citationIndex, 1);
      expect(segments[0].url, isNull);
      expect(segments[1].citationIndex, 3);
      expect(segments[1].url, isNull);
      expect(segments[2].citationIndex, 2);
      expect(segments[2].url, 'https://ok.com');
      expect(segments[2].text, '[2]');
    });

    test('无 [n] 标记时返回单一普通片段', () {
      const content = '没有任何引用标记';
      final segments = parseCitationTextSegments(
        content: content,
        webResults: const [WebSearchResult(url: 'https://only.com')],
      );

      expect(segments, hasLength(1));
      expect(segments.single.text, content);
      expect(segments.single.citationIndex, isNull);
      expect(segments.single.url, isNull);
    });
  });

  group('图片块 UI 回归', () {
    testWidgets('anime 正文引用具备 link 语义和 44dp 命中区', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_citation_anime';
      store.seedMessage(
        messageKey,
        const [
          MainTextBlock(
            id: 'b_text_citation',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: '参考[1]。',
          ),
          CitationBlock(
            id: 'b_citation',
            messageId: messageKey,
            createdAt: 2,
            status: MessageBlockStatus.success,
            webResults: [
              WebSearchResult(
                title: '来源',
                url: 'https://example.com',
                content: '摘要',
              ),
            ],
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeFactory.anime(),
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      final link = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.link == true &&
            widget.properties.label == '打开来源 [1]',
      );
      expect(link, findsOneWidget);
      expect(tester.getSize(link), const Size(44, 44));
      final semantics = tester.widget<Semantics>(link);
      expect(semantics.properties.onTap, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具块排除子语义时保留展开动作', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_tool_semantics';
      store.seedMessage(
        messageKey,
        const [
          ToolBlock(
            id: 'b_tool',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            toolId: 'web_search',
            toolName: '联网搜索',
            arguments: {'query': '测试'},
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeFactory.anime(),
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      final tool = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == '联网搜索',
      );
      expect(tool, findsOneWidget);
      expect(tester.widget<Semantics>(tool).properties.onTap, isNotNull);
      expect(tester.getSize(tool).height, greaterThanOrEqualTo(44));
    });

    testWidgets('字数和底部操作合并为消息 footer', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_footer_1';
      store.seedMessage(
        messageKey,
        const [
          MainTextBlock(
            id: 'b_text_1',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: '你好a',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(
                messageKey: messageKey,
                showCharCount: true,
                footerTrailing: Text('朗读'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('3 字'), findsOneWidget);
      expect(find.text('朗读'), findsOneWidget);
      expect(find.textContaining('字数：'), findsNothing);
    });

    testWidgets('图片块带有效来源时显示保存按钮', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_image_1';
      store.seedMessage(
        messageKey,
        const [
          ImageBlock(
            id: 'b_img_1',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            url:
                'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO8f9+4AAAAASUVORK5CYII=',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('保存图片'), findsOneWidget);
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('无可保存来源时图片块不显示保存按钮', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_image_2';
      store.seedMessage(
        messageKey,
        const [
          ImageBlock(
            id: 'b_img_2',
            messageId: messageKey,
            createdAt: 2,
            status: MessageBlockStatus.success,
            url: 'ftp://example.com/a.png',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('角色上下文块 UI 回归', () {
    testWidgets('角色上下文快照默认折叠，点击后展示完整文本', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_role_context_1';
      store.seedMessage(
        messageKey,
        const [
          RoleContextBlock(
            id: 'b_role_context_1',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: '[当前命中的角色记忆]\n- 钟声代表潮汐',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('本轮完整上下文'), findsOneWidget);
      expect(find.textContaining('钟声代表潮汐'), findsNothing);

      await tester.tap(find.text('本轮完整上下文'));
      await tester.pumpAndSettle();

      expect(find.textContaining('钟声代表潮汐'), findsOneWidget);
      expect(find.byTooltip('复制本轮上下文'), findsOneWidget);
    });

    testWidgets('未完成回复状态默认折叠，点击后展示承接文本', (tester) async {
      final store = ChatBlockStore();
      const messageKey = 'msg_role_continuation_1';
      store.seedMessage(
        messageKey,
        const [
          RoleContinuationBlock(
            id: 'b_role_continuation_1',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: '上一轮尚未正式开口，角色紧张地攥住笔记本。',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider.value(
              value: store,
              child: const BlockMessageContent(messageKey: messageKey),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('已保留角色状态 · 下轮将承接'), findsOneWidget);
      expect(find.textContaining('攥住笔记本'), findsNothing);

      await tester.tap(find.text('已保留角色状态 · 下轮将承接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('攥住笔记本'), findsOneWidget);
    });

    testWidgets('anime 角色上下文操作至少 44dp 且大字体不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = ChatBlockStore();
      const messageKey = 'msg_role_context_anime';
      store.seedMessage(
        messageKey,
        const [
          RoleContextBlock(
            id: 'b_role_context_anime',
            messageId: messageKey,
            createdAt: 1,
            status: MessageBlockStatus.success,
            content: '[当前命中的角色记忆]\n- 钟声代表潮汐',
          ),
        ],
      );
      store.commitSeed();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeFactory.anime(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 480),
              textScaler: TextScaler.linear(1.6),
            ),
            child: Scaffold(
              body: ChangeNotifierProvider.value(
                value: store,
                child: const BlockMessageContent(messageKey: messageKey),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final copy = find.byTooltip('复制本轮上下文');
      expect(tester.getSize(copy).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(copy).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });
  });
}
