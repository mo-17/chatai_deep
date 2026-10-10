import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
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

  for (final anime in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
          '${anime ? "二次元" : "经典"}/${dark ? "暗色" : "亮色"}：搜索状态、高亮、禁用与可访问性',
          (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final theme = ThemeProvider()
          ..setVisualStyle(
              anime ? AppVisualStyle.anime : AppVisualStyle.classic);
        addTearDown(theme.dispose);
        final themeData = dark
            ? ThemeData(
                colorScheme: ColorScheme.fromSeed(
                    seedColor: theme.getTheme().colorScheme.primary,
                    brightness: Brightness.dark))
            : theme.getTheme();
        var selected = false;
        var ready = true;
        var editable = true;
        var streaming = false;
        var configured = true;
        var callbackAvailable = true;
        var clicks = 0;
        late StateSetter update;
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: MaterialApp(
                theme: themeData,
                home: StatefulBuilder(builder: (context, setState) {
                  update = setState;
                  return Scaffold(
                      body: Align(
                          alignment: Alignment.bottomCenter,
                          child: MessageInputWidget('请输入',
                              enable: ready,
                              editingEnabled: editable,
                              isStreaming: streaming,
                              speechInputEnabled: false,
                              showWebSearch: configured,
                              webSearchEnabled: selected,
                              onToggleWebSearch: callbackAvailable
                                  ? () => setState(() {
                                        selected = !selected;
                                        clicks++;
                                      })
                                  : null)));
                }))));
        final finder = find.byKey(const ValueKey('web_search_toggle'));
        IconButton button() => tester.widget<IconButton>(finder);
        final off = button().style!.backgroundColor!.resolve({});
        expect(button().isSelected, isFalse);
        expect(find.byTooltip('开启联网搜索'), findsOneWidget);
        expect(tester.getSize(finder).shortestSide, greaterThanOrEqualTo(44));
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        expect(clicks, 1);
        expect(button().isSelected, isTrue);
        expect(find.byTooltip('关闭联网搜索'), findsOneWidget);
        expect(tester.getSemantics(finder).flagsCollection.isSelected,
            isTrue);
        final on =
            button().style!.backgroundColor!.resolve({WidgetState.selected})!;
        final foreground =
            button().style!.foregroundColor!.resolve({WidgetState.selected})!;
        expect(on, isNot(off));
        final l1 = on.computeLuminance();
        final l2 = foreground.computeLuminance();
        final contrast =
            ((l1 > l2 ? l1 : l2) + .05) / ((l1 < l2 ? l1 : l2) + .05);
        expect(contrast, greaterThanOrEqualTo(3), reason: '选中图标与背景必须清晰可辨');
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(selected, isFalse);
        expect(clicks, 2);
        expect(button().style!.backgroundColor!.resolve({}), off);
        for (final unavailable in ['未就绪', '编辑锁', '生成中', '无回调']) {
          for (final enabled in [false, true]) {
            update(() {
              selected = enabled;
              ready = unavailable != '未就绪';
              editable = unavailable != '编辑锁';
              streaming = unavailable == '生成中';
              callbackAvailable = unavailable != '无回调';
            });
            await tester.pumpAndSettle();
            expect(button().onPressed, isNull);
            expect(
                button()
                    .style!
                    .backgroundColor!
                    .resolve({WidgetState.disabled}),
                isNot(on));
            await tester.tap(finder);
            await tester.pump();
            expect(clicks, 2);
            expect(selected, enabled, reason: '禁用不丢失当前选择');
          }
        }
        update(() => configured = false);
        await tester.pump();
        expect(finder, findsNothing, reason: '未配置搜索服务时不显示入口');
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
