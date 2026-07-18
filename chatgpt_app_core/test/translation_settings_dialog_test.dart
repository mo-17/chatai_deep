import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/translation_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('记住的模型作为初值，显示字数且 Thinking 默认关闭', (tester) async {
    final settings = _settings();
    TranslationModelPreference? result;
    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          settings: settings,
          initialValue: const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.local,
            providerId: 'deepseek',
            modelId: 'deepseek-v4-flash',
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          ),
          estimatedRunes: 33322,
        );
      },
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('预计翻译 33,322 字'), findsOneWidget);
    expect(find.text('DeepSeek / deepseek-v4-flash'), findsOneWidget);
    final thinking = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('translation_disable_thinking')),
    );
    expect(thinking.value, isTrue);
    expect(thinking.onChanged, isNotNull);

    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();
    expect(result?.mode, TranslationModelPreferenceMode.local);
    expect(result?.providerId, 'deepseek');
    expect(result?.modelId, 'deepseek-v4-flash');
    expect(result?.reasoningPolicy, ChatReasoningPolicy.offIfSupported);
  });

  testWidgets('失效的记忆选择回退全局，不支持接口禁用 Thinking，取消返回 null', (tester) async {
    final settings = _settings(activeProviderId: 'custom');
    TranslationModelPreference? result;
    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          settings: settings,
          initialValue: const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.local,
            providerId: 'deleted-provider',
            modelId: 'deleted-model',
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          ),
          estimatedRunes: 12,
        );
      },
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('跟随全局：custom-fast'), findsOneWidget);
    expect(find.text('该接口不会发送 Thinking 参数'), findsOneWidget);
    final thinking = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('translation_disable_thinking')),
    );
    expect(thinking.value, isFalse);
    expect(thinking.onChanged, isNull);

    await tester.tap(
      find.byKey(const ValueKey('translation_settings_cancel')),
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('从共享选择器换模型后确认只返回偏好', (tester) async {
    final settings = _settings();
    TranslationModelPreference? result;
    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          settings: settings,
          initialValue: const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.followGlobal,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          ),
          estimatedRunes: 100,
        );
      },
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translation_model_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom fast'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();

    expect(result?.mode, TranslationModelPreferenceMode.local);
    expect(result?.providerId, 'custom');
    expect(result?.modelId, 'custom-fast');
    expect(settings.activeProviderId, 'deepseek');
  });

  for (final testCase in [
    (
      name: '显式后端模型',
      preference: const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.backend,
        modelId: 'backend-fast',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    ),
    (
      name: '跟随后端全局模型',
      preference: const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.followGlobal,
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    ),
  ]) {
    testWidgets('${testCase.name}允许语义关闭 Thinking', (tester) async {
      final settings = _settings()..mode = AIMode.backend;
      TranslationModelPreference? result;
      await tester.pumpWidget(_host(
        onOpen: (context) async {
          result = await showTranslationSettingsDialog(
            context,
            settings: settings,
            initialValue: testCase.preference,
            estimatedRunes: 100,
          );
        },
      ));

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('后端会在模型支持时关闭 Thinking。'), findsOneWidget);
      final thinking = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('translation_disable_thinking')),
      );
      expect(thinking.value, isTrue);
      expect(thinking.onChanged, isNotNull);

      await tester.tap(
        find.byKey(const ValueKey('translation_settings_confirm')),
      );
      await tester.pumpAndSettle();
      expect(result?.mode, testCase.preference.mode);
      expect(result?.reasoningPolicy, ChatReasoningPolicy.offIfSupported);
    });
  }
}

Widget _host({required Future<void> Function(BuildContext context) onOpen}) =>
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => onOpen(context),
            child: const Text('打开'),
          ),
        ),
      ),
    );

AISettings _settings({String activeProviderId = 'deepseek'}) => AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'deepseek',
          type: 'openai',
          name: 'DeepSeek',
          apiKey: 'key',
          enabled: true,
          selectedModelId: 'deepseek-v4-flash',
          models: [AiModel(id: 'deepseek-v4-flash')],
        ),
        AiProvider(
          id: 'custom',
          type: 'openai',
          name: 'Custom',
          apiKey: 'key',
          enabled: true,
          selectedModelId: 'custom-fast',
          models: [AiModel(id: 'custom-fast', name: 'Custom fast')],
        ),
      ],
      activeProviderId: activeProviderId,
      backendModel: 'backend-fast',
      streamEnabled: true,
      resetOnLogout: true,
    );
