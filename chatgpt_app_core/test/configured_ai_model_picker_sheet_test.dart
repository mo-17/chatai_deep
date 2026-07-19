import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('未传预检 readers 时保持已配置列表和旧健康状态', (tester) async {
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

  testWidgets('预检列表展示全部模型并按 blocked warning failed verified unverified 排序状态',
      (tester) async {
    final settings = _preflightSettings();
    var readerCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showConfiguredAiModelPickerSheet(
              context,
              settings: settings,
              selected: const TranslationModelPreference(
                mode: TranslationModelPreferenceMode.followGlobal,
                reasoningPolicy: ChatReasoningPolicy.offIfSupported,
              ),
              includeUnavailable: true,
              eligibilityFor: (preference) {
                readerCalls += 1;
                if (preference.providerId == 'disabled' ||
                    preference.providerId == 'missing-key') {
                  return _eligibility(
                    TranslationEligibilityLevel.blocked,
                    TranslationEligibilityCode.providerDisabled,
                  );
                }
                if (preference.modelId == 'warning-model') {
                  return _eligibility(
                    TranslationEligibilityLevel.warning,
                    TranslationEligibilityCode.mobileLoopback,
                  );
                }
                return const TranslationEligibilityResult();
              },
              probeFor: (preference) {
                readerCalls += 1;
                return switch (preference.modelId) {
                  'verified-model' => _probe(
                      TranslationModelProbeStatus.verified,
                      preference.modelId!,
                    ),
                  'failed-model' || 'warning-model' => _probe(
                      TranslationModelProbeStatus.failed,
                      preference.modelId!,
                    ),
                  _ => null,
                };
              },
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(_primaryBadge(tester, 'ready', 'verified-model'), '已验证');
    expect(_primaryBadge(tester, 'ready', 'failed-model'), '测试失败');
    expect(_primaryBadge(tester, 'ready', 'warning-model'), '地址警告');
    final callsAfterBuild = readerCalls;
    await tester.enterText(
      find.byKey(const ValueKey('configured_model_search')),
      'unverified',
    );
    await tester.pump();
    expect(readerCalls, greaterThan(callsAfterBuild));
    expect(find.text('Unverified model'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('configured_model_search')),
      '',
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('configured_ai_model_picker')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(_primaryBadge(tester, 'ready', 'unverified-model'), '未验证');
    await tester.drag(
      find.byKey(const ValueKey('configured_ai_model_picker')),
      const Offset(0, -280),
    );
    await tester.pumpAndSettle();
    expect(_primaryBadge(tester, 'disabled', 'disabled-model'), '配置不可用');
    await tester.drag(
      find.byKey(const ValueKey('configured_ai_model_picker')),
      const Offset(0, -280),
    );
    await tester.pumpAndSettle();
    expect(_primaryBadge(tester, 'missing-key', 'missing-model'), '配置不可用');
    expect(readerCalls, greaterThan(0));
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

  testWidgets('不支持 reasoning-control 的候选用正式 providerDefault profile 查 badge',
      (tester) async {
    final settings = AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'custom',
          type: 'openai',
          name: 'Custom',
          apiKey: 'key',
          apiHost: 'https://custom.example/v1',
          enabled: true,
          selectedModelId: 'verified-model',
          models: [
            AiModel(id: 'verified-model', name: 'Verified unsupported'),
            AiModel(id: 'failed-model', name: 'Failed unsupported'),
            AiModel(id: 'warning-model', name: 'Warning verified'),
          ],
        ),
      ],
      activeProviderId: 'custom',
      backendModel: 'backend-fast',
      streamEnabled: true,
      resetOnLogout: true,
    );
    TranslationModelPreference? result;
    final observedPolicies = <ChatReasoningPolicy>[];
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
                includeUnavailable: true,
                eligibilityFor: (preference) {
                  if (preference.providerId == 'custom') {
                    observedPolicies.add(preference.reasoningPolicy);
                  }
                  if (preference.modelId == 'warning-model') {
                    return _eligibility(
                      TranslationEligibilityLevel.warning,
                      TranslationEligibilityCode.mobileLoopback,
                    );
                  }
                  return const TranslationEligibilityResult();
                },
                probeFor: (preference) {
                  if (preference.providerId == 'custom') {
                    observedPolicies.add(preference.reasoningPolicy);
                  }
                  if (preference.reasoningPolicy !=
                      ChatReasoningPolicy.providerDefault) {
                    return null;
                  }
                  return switch (preference.modelId) {
                    'verified-model' || 'warning-model' => _probe(
                        TranslationModelProbeStatus.verified,
                        preference.modelId!,
                      ),
                    'failed-model' => _probe(
                        TranslationModelProbeStatus.failed,
                        preference.modelId!,
                      ),
                    _ => null,
                  };
                },
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(_primaryBadge(tester, 'custom', 'verified-model'), '已验证');
    expect(_primaryBadge(tester, 'custom', 'failed-model'), '测试失败');
    expect(_primaryBadge(tester, 'custom', 'warning-model'), '地址警告');
    expect(observedPolicies, isNotEmpty);
    expect(
      observedPolicies,
      everyElement(ChatReasoningPolicy.providerDefault),
    );

    await tester.tap(find.text('Verified unsupported'));
    await tester.pumpAndSettle();
    expect(result?.reasoningPolicy, ChatReasoningPolicy.providerDefault);
  });
}

String _primaryBadge(
  WidgetTester tester,
  String providerId,
  String modelId,
) =>
    tester
        .widget<Text>(find.descendant(
          of: find.byKey(ValueKey(
            'translation_preflight_badge_${providerId}_$modelId',
          )),
          matching: find.byType(Text),
        ))
        .data!;

TranslationEligibilityResult _eligibility(
  TranslationEligibilityLevel level,
  TranslationEligibilityCode code,
) =>
    TranslationEligibilityResult([
      TranslationEligibilityIssue(
        level: level,
        code: code,
        message: code.name,
      ),
    ]);

TranslationModelProbeRecord _probe(
  TranslationModelProbeStatus status,
  String suffix,
) =>
    TranslationModelProbeRecord(
      fingerprint: suffix.padRight(64, 'a').substring(0, 64),
      status: status,
      checkedAt: DateTime.utc(2026, 7, 20),
      safeErrorCode:
          status == TranslationModelProbeStatus.failed ? 'unknown' : null,
      reasoningControlSuppressed: false,
    );

AISettings _preflightSettings() => AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'ready',
          type: 'openai',
          name: 'Ready',
          apiKey: 'key',
          enabled: true,
          models: [
            AiModel(id: 'verified-model', name: 'Verified model'),
            AiModel(id: 'failed-model', name: 'Failed probe model'),
            AiModel(id: 'warning-model', name: 'Warning model'),
            AiModel(id: 'unverified-model', name: 'Unverified model'),
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
      activeProviderId: 'ready',
      backendModel: 'backend-fast',
      streamEnabled: true,
      resetOnLogout: true,
    );

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
