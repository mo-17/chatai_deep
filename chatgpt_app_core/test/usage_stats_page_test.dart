import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:chatgpt_app_core/pages/usage_stats_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const snapshot = UsageStatsSnapshot(
    byModel: [
      UsageAggregate(
        key: 'gpt-a',
        promptTokens: 10,
        cachedPromptTokens: 4,
        completionTokens: 20,
        cost: 0.12,
        calls: 2,
        estimated: true,
      ),
    ],
    byProvider: [
      UsageAggregate(
        key: 'openai',
        promptTokens: 10,
        cachedPromptTokens: 4,
        completionTokens: 20,
        cost: 0.12,
        calls: 2,
        estimated: true,
      ),
    ],
    byDate: [
      UsageAggregate(
        key: '2026-06-30',
        promptTokens: 10,
        cachedPromptTokens: 4,
        completionTokens: 20,
        cost: 0.12,
        calls: 2,
        estimated: true,
      ),
    ],
    byProject: [
      UsageAggregate(
        key: '研究项目',
        promptTokens: 10,
        cachedPromptTokens: 4,
        completionTokens: 20,
        cost: 0.12,
        calls: 2,
        estimated: true,
      ),
    ],
    byConversation: [
      UsageAggregate(
        key: '100',
        promptTokens: 10,
        cachedPromptTokens: 4,
        completionTokens: 20,
        cost: 0.12,
        calls: 2,
        estimated: true,
      ),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  test('用量统计汇总可格式化为可复制文本', () {
    final text = UsageStatsExportFormatter.buildText(snapshot);

    expect(text, contains('用量统计'));
    expect(text, contains('总 Token：30'));
    expect(text, contains('数据来源：含估算'));
    expect(text, contains('[按模型]'));
    expect(text, contains('gpt-a：调用 2 次'));
    expect(text, contains('输入 10，缓存输入 4，未缓存输入 6，输出 20'));
    expect(text, contains('[按服务商]'));
    expect(text, contains('openai：调用 2 次'));
    expect(text, contains('[按日期]'));
    expect(text, contains('2026-06-30：调用 2 次'));
    expect(text, contains('[按项目]'));
    expect(text, contains('研究项目：调用 2 次'));
    expect(text, contains('[按会话]'));
    expect(text, contains('100：调用 2 次'));
  });

  testWidgets('用量统计页展示聚合摘要和估算标记', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: UsageStatsPage(
        loader: () async => snapshot,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('用量统计'), findsOneWidget);
    expect(find.text('总 Token'), findsOneWidget);
    expect(find.text('缓存输入'), findsOneWidget);
    expect(find.text('4'), findsAtLeastNWidgets(1));
    expect(find.text('30'), findsAtLeastNWidgets(1));
    expect(find.text('数据来源'), findsOneWidget);
    expect(find.text('含估算'), findsAtLeastNWidgets(1));
    expect(find.text('gpt-a'), findsOneWidget);
    expect(find.textContaining('调用 2 次'), findsOneWidget);

    await tester.tap(find.text('服务商'));
    await tester.pumpAndSettle();
    expect(find.text('openai'), findsOneWidget);

    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    expect(find.text('2026-06-30'), findsOneWidget);

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(find.text('研究项目'), findsOneWidget);
  });

  testWidgets('用量统计页可复制汇总', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: UsageStatsPage(
        loader: () async => snapshot,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('复制汇总'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('总 Token：30'));
    expect(copied.single, contains('缓存输入 4'));
    expect(copied.single, contains('gpt-a：调用 2 次'));
    expect(copied.single, contains('研究项目：调用 2 次'));
    expect(find.text('用量汇总已复制'), findsOneWidget);
  });

  testWidgets('用量统计页空状态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: UsageStatsPage(
        loader: () async => const UsageStatsSnapshot(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('还没有用量记录'), findsOneWidget);
  });

  testWidgets('成本单价弹窗可保存默认单价和模型精确单价', (tester) async {
    final provider = AISettingsProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: provider,
        child: MaterialApp(
          home: UsageStatsPage(
            loader: () async => const UsageStatsSnapshot(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('成本单价'));
    await tester.pumpAndSettle();

    expect(find.text('默认单价（每 1M token）'), findsOneWidget);
    expect(find.text('内置价格'), findsOneWidget);
    expect(find.text('内置'), findsAtLeastNWidgets(1));
    expect(find.text('deepseek/deepseek-v4-pro'), findsAtLeastNWidgets(1));
    expect(find.text('deepseek/deepseek-v4-flash'), findsAtLeastNWidgets(1));
    expect(find.text('09:00-12:00 北京时间'), findsAtLeastNWidgets(1));
    expect(find.text('14:00-18:00 北京时间'), findsAtLeastNWidgets(1));
    expect(find.text('缓存输入 / 1M'), findsNWidgets(2));
    expect(find.text('输入 / 1M'), findsNWidgets(2));
    expect(find.text('输出 / 1M'), findsNWidgets(2));

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '0.005');
    await tester.enterText(fields.at(1), '0.01');
    await tester.enterText(fields.at(2), '0.03');
    await tester.enterText(fields.at(3), 'openai');
    await tester.enterText(fields.at(4), 'gpt-4o');
    await tester.enterText(fields.at(5), '0.01');
    await tester.enterText(fields.at(6), '0.02');
    await tester.enterText(fields.at(7), '0.06');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final config = provider.settings.usageCostConfig;
    expect(config.defaultRate.effectiveCachedInputCostPer1K, 0.005);
    expect(config.defaultRate.inputCostPer1K, 0.01);
    expect(config.defaultRate.outputCostPer1K, 0.03);
    expect(
        config
            .rateFor(providerId: 'openai', modelId: 'gpt-4o')
            .effectiveCachedInputCostPer1K,
        0.01);
    expect(
        config.rateFor(providerId: 'openai', modelId: 'gpt-4o').inputCostPer1K,
        0.02);
    expect(
        config.rateFor(providerId: 'openai', modelId: 'gpt-4o').outputCostPer1K,
        0.06);
    expect(config.rateFor(providerId: 'deepseek', modelId: 'chat'),
        isA<UsageCostRate>());
  });
}
