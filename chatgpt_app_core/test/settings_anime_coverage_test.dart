import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/pages/ai_provider_detail_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/cloud_sync_page.dart';
import 'package:chatgpt_app_core/pages/mcp_market_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_progress_dialog.dart';
import 'package:chatgpt_app_core/widget/ai_provider/api_key_field.dart';
import 'package:chatgpt_app_core/widget/ai_provider/capability_chip.dart';
import 'package:chatgpt_app_core/widget/ai_provider/section_card.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  testWidgets('共享设置组件仅在 anime 模式采用二次元形状', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Future<void> pump(ThemeData theme) {
      return tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                const SectionCard(children: [Text('分组')]),
                ApiKeyField(controller: controller),
                const CapabilityChip(
                  label: '视觉',
                  icon: Icons.image_outlined,
                ),
              ],
            ),
          ),
        ),
      );
    }

    await pump(AppThemeFactory.anime());
    await tester.pumpAndSettle();
    final surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(AppVisualSurface).first,
            matching: find.byType(Material),
          )
          .first,
    );
    final surfaceShape = surface.shape! as RoundedRectangleBorder;
    expect(
      (surfaceShape.borderRadius as BorderRadius).topLeft.x,
      20,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).decoration?.border,
        isNull);
    final animeChip = tester.widget<Container>(
      find.descendant(
        of: find.byType(CapabilityChip),
        matching: find.byType(Container),
      ),
    );
    expect(animeChip.decoration, isA<ShapeDecoration>());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pump(AppThemeFactory.classic(Colors.blue));
    final card = tester.widget<Card>(find.byType(Card).first);
    final shape = card.shape! as RoundedRectangleBorder;
    expect((shape.borderRadius as BorderRadius).topLeft.x, 12);
    final classicBorder = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!
        .border! as OutlineInputBorder;
    expect(classicBorder.borderRadius.topLeft.x, 8);
    final classicChip = tester.widget<Container>(
      find.descendant(
        of: find.byType(CapabilityChip),
        matching: find.byType(Container),
      ),
    );
    expect(classicChip.decoration, isA<BoxDecoration>());
  });

  testWidgets('anime 服务商详情的文字操作满足最小触控高度', (tester) async {
    final store = AISettingsProvider();
    final provider = store.settings.providers.firstWhere(
      (item) => item.id != store.settings.activeProviderId,
      orElse: () {
        final item = AiProvider(
          id: 'custom_touch_test',
          type: 'openai',
          name: '测试服务商',
          apiHost: 'https://example.com/v1',
          enabled: true,
        );
        store.settings.providers.add(item);
        return item;
      },
    )..enabled = true;

    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
          theme: AppThemeFactory.anime(),
          home: AiProviderDetailPage(providerId: provider.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final currentButton = find.widgetWithText(TextButton, '设为当前服务商');
    expect(currentButton, findsOneWidget);
    expect(tester.getSize(currentButton).height, greaterThanOrEqualTo(44));

    final apiKeyLink = find.ancestor(
      of: find.text('去申请 API Key'),
      matching: find.byType(InkWell),
    );
    expect(apiKeyLink, findsOneWidget);
    expect(tester.getSize(apiKeyLink).height, greaterThanOrEqualTo(44));
  });

  testWidgets('anime 云同步使用状态卡且主操作满足触控高度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: CloudSyncPage(lastSyncAtLoader: () async => 0),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cloud_sync_status_surface')),
        findsOneWidget);
    final button = find.ancestor(
      of: find.text('立即同步'),
      matching: find.byWidgetPredicate((widget) => widget is ElevatedButton),
    );
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
  });

  testWidgets('anime MCP 商店在窄屏大字体下使用可换行状态标签', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 760),
            textScaler: TextScaler.linear(1.35),
          ),
          child: McpMarketPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppStatusBadge), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anime 更新弹窗沿用主题并保持可关闭', (tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return Scaffold(
              body: FilledButton(
                onPressed: () {
                  HiDialog.showDownloadDialog(
                    context,
                    title: '有新版本啦',
                    content: '新增二次元设置页覆盖。',
                    confirmText: '立即更新',
                    cancelText: '取消',
                  );
                },
                child: const Text('打开更新弹窗'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开更新弹窗'));
    await tester.pumpAndSettle();
    final alert = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(alert.titleTextStyle, isNull);
    expect(alert.contentTextStyle, isNull);
    final cancel = find.widgetWithText(TextButton, '取消');
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(44));
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    final progress = HiProgressDialog();
    expect(progress.show(hostContext, cancellable: false), isTrue);
    await tester.pumpAndSettle();
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    final shape = dialog.shape! as RoundedRectangleBorder;
    expect((shape.borderRadius as BorderRadius).topLeft.x, 24);
    expect(progress.close(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('anime AI 设置在窄屏纵向排列搜索参数且沿用主题输入框', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final store = AISettingsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
          theme: AppThemeFactory.anime(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 900),
              textScaler: TextScaler.linear(1.2),
            ),
            child: AISettingsPage(),
          ),
        ),
      ),
    );
    await tester.pump();

    Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
        );
    final countField = field('结果个数');
    final limitField = field('内容长度限制');
    await tester.scrollUntilVisible(
      countField,
      320,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(countField, findsOneWidget);
    expect(limitField, findsOneWidget);
    expect(
      tester.getTopLeft(limitField).dy,
      greaterThan(tester.getBottomLeft(countField).dy),
    );
    expect(tester.widget<TextField>(countField).decoration?.border, isNull);
    expect(tester.takeException(), isNull);
  });
}
