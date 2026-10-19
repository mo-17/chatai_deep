import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/ai_readiness_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('展示模型把稳定 reason 映射为用户可执行文案', () {
    final missingKey = aiReadinessPresentation(const AIReadyState(
      status: AIReadyStatus.needsSetup,
      reasonCode: 'missing_api_key',
    ));
    expect(missingKey.title, '添加服务商 API Key');
    expect(missingKey.primaryAction, AIReadinessPrimaryAction.configure);
    expect(missingKey.statusLabel, '待配置');

    final ready = aiReadinessPresentation(const AIReadyState(
      status: AIReadyStatus.ready,
      reasonCode: 'model_test_succeeded',
    ));
    expect(ready.statusLabel, '可用');
    expect(ready.primaryAction, AIReadinessPrimaryAction.none);
  });

  testWidgets('配置卡主操作与稍后提醒可触发且窄屏不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var configured = 0;
    var dismissed = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.classic(Colors.blue),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.2),
            ),
            child: AIReadinessCard(
              state: const AIReadyState(
                status: AIReadyStatus.needsSetup,
                reasonCode: 'missing_api_key',
              ),
              onConfigure: () => configured++,
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('classic_ai_readiness_card')),
        findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('ai_readiness_primary_action')),
    );
    await tester.tap(find.byKey(const ValueKey('ai_readiness_dismiss')));
    await tester.pump();

    expect(configured, 1);
    expect(dismissed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('二次元模式使用统一视觉卡面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: const Scaffold(
          body: AIReadinessCard(
            state: AIReadyState(
              status: AIReadyStatus.configuredUnverified,
              reasonCode: 'model_unverified',
            ),
          ),
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey('anime_ai_readiness_card')), findsOneWidget);
    expect(find.text('待验证'), findsOneWidget);
  });
  testWidgets(
      'trial entry is explicit and does not replace service configuration action',
      (tester) async {
    var trial = 0;
    var configured = 0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AIReadinessCard(
      state: const AIReadyState(
          status: AIReadyStatus.needsSetup, reasonCode: 'missing_api_key'),
      onTrial: () => trial++,
      onConfigure: () => configured++,
    )))));
    await tester.tap(find.text('了解官方试用'));
    await tester.tap(find.text('去配置'));
    expect(trial, 1);
    expect(configured, 1);
    expect(tester.takeException(), isNull);
  });
}
