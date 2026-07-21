import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:chatgpt_app_core/widget/starcore_tool_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  Future<void> pumpToolIcon(
    WidgetTester tester, {
    required ThemeData theme,
    required String toolName,
    required Key fallbackKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: StarcoreToolIcon(
            toolName: toolName,
            fallback: Icon(Icons.build_outlined, key: fallbackKey),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('anime maps only approved tool ids to their stable SVG keys',
      (tester) async {
    await pumpToolIcon(
      tester,
      theme: AppThemeFactory.anime(),
      toolName: ToolRegistry.webSearchId,
      fallbackKey: const ValueKey('fallback-web'),
    );
    expect(
      find.byKey(const ValueKey('starcore-svg-tool-web-search')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fallback-web')), findsNothing);

    await pumpToolIcon(
      tester,
      theme: AppThemeFactory.anime(),
      toolName: ToolRegistry.knowledgeSearchId,
      fallbackKey: const ValueKey('fallback-knowledge'),
    );
    expect(
      find.byKey(const ValueKey('starcore-svg-tool-knowledge-search')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fallback-knowledge')), findsNothing);
  });

  testWidgets('classic and unknown tools render only their supplied fallback',
      (tester) async {
    await pumpToolIcon(
      tester,
      theme: AppThemeFactory.classic(Colors.blue),
      toolName: ToolRegistry.webSearchId,
      fallbackKey: const ValueKey('fallback-classic'),
    );
    expect(find.byKey(const ValueKey('fallback-classic')), findsOneWidget);
    expect(find.byType(StarcoreSvgIcon), findsNothing);

    await pumpToolIcon(
      tester,
      theme: AppThemeFactory.anime(),
      toolName: ToolRegistry.calculatorId,
      fallbackKey: const ValueKey('fallback-unknown'),
    );
    expect(find.byKey(const ValueKey('fallback-unknown')), findsOneWidget);
    expect(find.byType(StarcoreSvgIcon), findsNothing);
  });

  testWidgets('assistant tool rows keep the leading checkbox and title glyph',
      (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: AISettingsProvider(),
        child: MaterialApp(
          theme: AppThemeFactory.anime(),
          home: AssistantEditPage(
            assistant: AssistantModel(
              id: 1,
              name: '工具助手',
              emoji: '🤖',
              toolIds: const [ToolRegistry.webSearchId],
            ),
            saveAssistant: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();

    final tile = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .firstWhere(
      (candidate) {
        final title = candidate.title! as Row;
        return (title.children.whereType<Flexible>().single.child as Text)
                .data ==
            '联网搜索';
      },
    );
    expect(tile.controlAffinity, ListTileControlAffinity.leading);
    expect(tile.secondary, isNull);

    final title = tile.title! as Row;
    expect(title.children.first, isA<StarcoreToolIcon>());
    expect(title.children[1], isA<SizedBox>());
    expect(title.children[2], isA<Flexible>());
    expect((title.children[2] as Flexible).child, isA<Text>());
  });
}
