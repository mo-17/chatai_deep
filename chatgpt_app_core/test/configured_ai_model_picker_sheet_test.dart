import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('只展示已配置模型，保留失败状态并按最近使用排序', (tester) async {
    final settings = _settings();
    final before = settings.toJson();
    TranslationModelPreference? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showConfiguredAiModelPickerSheet(
                context,
                settings: settings,
                selected: const TranslationModelPreference(
                  mode: TranslationModelPreferenceMode.followGlobal,
                  reasoningPolicy: ChatReasoningPolicy.offIfSupported,
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('configured_model_follow_global')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('configured_model_backend_backend-fast')),
        findsOneWidget);
    expect(find.text('Fast model'), findsOneWidget);
    expect(find.text('Failed model'), findsOneWidget);
    expect(find.text('测试失败'), findsOneWidget);
    expect(find.text('Disabled model'), findsNothing);
    expect(find.text('Missing key model'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Fast model')).dy,
      lessThan(tester.getTopLeft(find.text('Failed model')).dy),
    );

    await tester.enterText(
      find.byKey(const ValueKey('configured_model_search')),
      'failed',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('configured_model_follow_global')),
        findsOneWidget);
    expect(find.text('Fast model'), findsNothing);
    expect(find.text('Failed model'), findsOneWidget);

    await tester.tap(find.text('Failed model'));
    await tester.pumpAndSettle();
    expect(result?.mode, TranslationModelPreferenceMode.local);
    expect(result?.providerId, 'deepseek');
    expect(result?.modelId, 'failed-model');
    expect(settings.toJson(), before);
  });

  testWidgets('后端行返回当前后端模型且可隐藏跟随全局', (tester) async {
    final settings = _settings();
    TranslationModelPreference? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showConfiguredAiModelPickerSheet(
                context,
                settings: settings,
                selected: const TranslationModelPreference(
                  mode: TranslationModelPreferenceMode.backend,
                  modelId: 'backend-fast',
                  reasoningPolicy: ChatReasoningPolicy.offIfSupported,
                ),
                includeFollowGlobal: false,
                onlyMode: TranslationExecutionMode.backend,
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('跟随全局设置'), findsNothing);
    expect(find.text('backend-fast'), findsOneWidget);
    await tester.tap(find.text('backend-fast'));
    await tester.pumpAndSettle();

    expect(result?.mode, TranslationModelPreferenceMode.backend);
    expect(result?.modelId, 'backend-fast');
  });
}

AISettings _settings() => AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'deepseek',
          type: 'openai',
          name: 'DeepSeek',
          apiKey: 'test-key',
          apiHost: 'https://example.test',
          selectedModelId: 'fast-model',
          enabled: true,
          models: [
            AiModel(id: 'fast-model', name: 'Fast model', lastUsedAt: 200),
            AiModel(
              id: 'failed-model',
              name: 'Failed model',
              lastUsedAt: 100,
              lastTestStatus: 'failure',
              lastTestError: 'timeout',
            ),
          ],
        ),
        AiProvider(
          id: 'disabled',
          type: 'openai',
          name: 'Disabled',
          apiKey: 'key',
          enabled: false,
          models: [AiModel(id: 'disabled-model', name: 'Disabled model')],
        ),
        AiProvider(
          id: 'missing-key',
          type: 'openai',
          name: 'Missing key',
          enabled: true,
          models: [AiModel(id: 'missing-model', name: 'Missing key model')],
        ),
      ],
      activeProviderId: 'deepseek',
      backendModel: 'backend-fast',
      streamEnabled: true,
      resetOnLogout: true,
    );
