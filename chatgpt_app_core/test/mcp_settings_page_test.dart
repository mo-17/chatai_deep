import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/pages/mcp_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归：MCP 设置页「添加 / 编辑直连 server」对话框的 TextEditingController
/// 必须由对话框自身 State 持有并在卸载时释放。早先把控制器在 `await showDialog`
/// 返回后同步 dispose，而保存又会触发 AISettingsProvider 重建——对话框退出动画
/// 期间子树重建引用到已 dispose 的控制器，抛
/// `A TextEditingController was used after being disposed`（并连锁 `_dependents`
/// 断言红屏）。本测试驱动完整的 添加→填写→保存→退出动画 流程，断言无异常。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    // HiCache 单例（含 prefs）跨测试保留，显式清空以隔离每个用例。
    await HiCache.getInstance().prefs?.clear();
  });

  Future<void> pumpPage(
      WidgetTester tester, AISettingsProvider provider) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: provider,
        child: const MaterialApp(home: McpSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('添加直连 server：保存关闭对话框不崩溃，且 server 已落库', (tester) async {
    final provider = AISettingsProvider();
    await pumpPage(tester, provider);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('添加 MCP server'), findsOneWidget);

    // 顺序：名称(0) / 端点 URL(1) / 请求头(2)
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '本地测试');
    await tester.enterText(fields.at(1), 'https://example.com/mcp');

    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle(); // 跑完对话框退出动画——竞态就在这些帧里

    expect(tester.takeException(), isNull);
    expect(provider.settings.mcpServers, hasLength(1));
    expect(provider.settings.mcpServers.first.url, 'https://example.com/mcp');
    expect(provider.settings.mcpServers.first.name, '本地测试');
    expect(provider.settings.mcpServers.first.permission,
        McpToolPermission.confirmWrite);
  });

  testWidgets('添加直连 server：可保存只读工具权限', (tester) async {
    final provider = AISettingsProvider();
    await pumpPage(tester, provider);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '只读服务');
    await tester.enterText(fields.at(1), 'https://readonly.example/mcp');

    await tester.tap(find.byType(DropdownButtonFormField<McpToolPermission>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅资源/提示词只读').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(provider.settings.mcpServers, hasLength(1));
    expect(provider.settings.mcpServers.first.permission,
        McpToolPermission.readOnly);
  });

  testWidgets('从商店选 Context7：URL 预填后保存即落库', (tester) async {
    final provider = AISettingsProvider();
    await pumpPage(tester, provider);

    await tester.tap(find.text('商店'));
    await tester.pumpAndSettle();
    expect(find.text('MCP 工具商店'), findsOneWidget);

    await tester.tap(find.text('Context7'));
    await tester.pumpAndSettle(); // 返回设置页 + 打开预填的添加对话框

    expect(find.text('https://mcp.context7.com/mcp'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(provider.settings.mcpServers, hasLength(1));
    expect(provider.settings.mcpServers.first.id, 'context7');
    expect(
        provider.settings.mcpServers.first.url, 'https://mcp.context7.com/mcp');
  });

  testWidgets('取消对话框：不新增 server，也不崩溃', (tester) async {
    final provider = AISettingsProvider();
    await pumpPage(tester, provider);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).at(1), 'https://discard.example/mcp');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(provider.settings.mcpServers, isEmpty);
  });
}
