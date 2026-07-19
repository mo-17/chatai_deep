import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('普通聊天请求选项使用稳定默认值', () {
    const options = ChatRequestOptions();

    expect(options.profile, ChatRequestProfile.standard);
    expect(options.reasoningPolicy, ChatReasoningPolicy.providerDefault);
    expect(options.abortTrigger, isNull);
    expect(options.connectTimeout, const Duration(seconds: 20));
    expect(options.minOutputTokens, isNull);
    expect(options.suppressReasoningControl, isFalse);
  });

  test('followGlobal 只解析一次且 apply 不修改全局设置', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');
    final profile = TranslationModelResolver.snapshot(
      settings,
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.followGlobal,
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    );

    expect(profile.mode, TranslationExecutionMode.local);
    expect(profile.providerId, 'deepseek');
    expect(profile.modelId, 'deepseek-chat');
    expect(profile.reasoningPolicy, ChatReasoningPolicy.offIfSupported);
    expect(profile.reasoningControlSuppressed, isFalse);

    settings.activeProviderId = 'openai';
    final applied = TranslationModelResolver.apply(settings, profile);

    expect(applied.mode, AIMode.local);
    expect(applied.activeProviderId, 'deepseek');
    expect(applied.effectiveModel, 'deepseek-chat');
    expect(identical(applied, settings), isFalse);
    expect(settings.activeProviderId, 'openai');
  });

  test('followGlobal 在后端模式快照精确后端模型', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek')
      ..mode = AIMode.backend
      ..backendModel = 'backend-fast';

    final profile = TranslationModelResolver.snapshot(
      settings,
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.followGlobal,
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
      ),
    );

    expect(profile.mode, TranslationExecutionMode.backend);
    expect(profile.providerId, isNull);
    expect(profile.modelId, 'backend-fast');

    settings.backendModel = 'backend-latest';
    final applied = TranslationModelResolver.apply(settings, profile);
    expect(applied.mode, AIMode.backend);
    expect(applied.backendModel, 'backend-fast');
    expect(settings.backendModel, 'backend-latest');
  });

  test('local 偏好快照精确 provider id 与模型', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');

    final profile = TranslationModelResolver.snapshot(
      settings,
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.local,
        providerId: 'openai',
        modelId: 'gpt-4.1',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    );

    expect(profile.mode, TranslationExecutionMode.local);
    expect(profile.providerId, 'openai');
    expect(profile.modelId, 'gpt-4.1');
  });

  test('backend 偏好快照精确后端模型', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');

    final profile = TranslationModelResolver.snapshot(
      settings,
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.backend,
        modelId: 'backend-translate',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
      ),
    );

    expect(profile.mode, TranslationExecutionMode.backend);
    expect(profile.providerId, isNull);
    expect(profile.modelId, 'backend-translate');
  });

  test('apply 严格拒绝已删除的 provider 而不回退', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek')
      ..providers.removeWhere((provider) => provider.id == 'deepseek');

    expect(
      () => TranslationModelResolver.apply(settings, _deepSeekProfile()),
      throwsA(isA<TranslationModelUnavailableException>()),
    );
    expect(settings.activeProviderId, 'deepseek');
  });

  test('resolver unavailable exception carries stable safe codes', () {
    const defaultError = TranslationModelUnavailableException('legacy message');
    expect(defaultError.safeCode, 'model_unavailable');
    expect(
      defaultError.toString(),
      'TranslationModelUnavailableException: legacy message',
    );

    final cases = <({
      String name,
      void Function(AISettings settings) mutate,
      String code
    })>[
      (
        name: 'deleted provider',
        mutate: (settings) => settings.providers.clear(),
        code: 'providerMissing',
      ),
      (
        name: 'disabled provider',
        mutate: (settings) => settings.providers
            .singleWhere((p) => p.id == 'deepseek')
            .enabled = false,
        code: 'providerDisabled',
      ),
      (
        name: 'empty key',
        mutate: (settings) => settings.providers
            .singleWhere((p) => p.id == 'deepseek')
            .apiKey = '',
        code: 'apiKeyMissing',
      ),
      (
        name: 'removed model',
        mutate: (settings) => settings.providers
            .singleWhere((p) => p.id == 'deepseek')
            .models
            .clear(),
        code: 'modelMissing',
      ),
    ];

    for (final testCase in cases) {
      final settings = _settingsWithProviders(activeProviderId: 'deepseek');
      testCase.mutate(settings);
      expect(
        () => TranslationModelResolver.apply(settings, _deepSeekProfile()),
        throwsA(
          isA<TranslationModelUnavailableException>()
              .having((error) => error.safeCode, 'safeCode', testCase.code),
        ),
        reason: testCase.name,
      );
    }
  });

  test('apply 严格拒绝已停用的 provider 而不回退', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');
    settings.providers.singleWhere((p) => p.id == 'deepseek').enabled = false;

    expect(
      () => TranslationModelResolver.apply(settings, _deepSeekProfile()),
      throwsA(isA<TranslationModelUnavailableException>()),
    );
  });

  test('apply 严格拒绝 API Key 缺失的 provider 而不回退', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');
    settings.providers.singleWhere((p) => p.id == 'deepseek').apiKey = '  ';

    expect(
      () => TranslationModelResolver.apply(settings, _deepSeekProfile()),
      throwsA(isA<TranslationModelUnavailableException>()),
    );
  });

  test('apply 严格拒绝已移除的模型而不回退', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');
    settings.providers.singleWhere((p) => p.id == 'deepseek').models.clear();

    expect(
      () => TranslationModelResolver.apply(settings, _deepSeekProfile()),
      throwsA(isA<TranslationModelUnavailableException>()),
    );
  });

  test('snapshot 严格拒绝失效 local 偏好而不借用 activeProvider fallback', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');

    expect(
      () => TranslationModelResolver.snapshot(
        settings,
        const TranslationModelPreference(
          mode: TranslationModelPreferenceMode.local,
          providerId: 'deleted-provider',
          modelId: 'gpt-4.1',
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
      ),
      throwsA(isA<TranslationModelUnavailableException>()),
    );
  });

  test('restore-only legacy fallback 对失效偏好返回 null', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');

    final fallback = TranslationModelResolver.legacyFallbackOrNull(
      settings,
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.local,
        providerId: 'deleted-provider',
        modelId: 'deleted-model',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    );

    expect(fallback, isNull);
  });

  test('snapshot 拒绝直接构造但违反模式字段合同的偏好', () {
    final settings = _settingsWithProviders(activeProviderId: 'deepseek');
    final invalidPreferences = [
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.local,
        providerId: 'deepseek',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.followGlobal,
        modelId: 'deepseek-chat',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.backend,
        providerId: 'deepseek',
        modelId: 'backend-fast',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
    ];

    for (final preference in invalidPreferences) {
      expect(
        () => TranslationModelResolver.snapshot(settings, preference),
        throwsFormatException,
        reason: preference.mode.name,
      );
    }
  });

  test('请求快照 JSON 使用精确枚举名且不包含凭据', () {
    final profile = _deepSeekProfile().suppressReasoningControl();

    final json = profile.toJson();

    expect(json, {
      'version': 1,
      'mode': 'local',
      'providerId': 'deepseek',
      'modelId': 'deepseek-chat',
      'reasoningPolicy': 'offIfSupported',
      'reasoningControlSuppressed': true,
    });
    final raw = json.toString().toLowerCase();
    expect(raw, isNot(contains('apikey')));
    expect(raw, isNot(contains('apihost')));
    expect(raw, isNot(contains('token')));
    expect(raw, isNot(contains('authorization')));

    final restored = TranslationRequestProfile.fromJson(json);
    expect(restored.mode, TranslationExecutionMode.local);
    expect(restored.providerId, 'deepseek');
    expect(restored.modelId, 'deepseek-chat');
    expect(restored.reasoningPolicy, ChatReasoningPolicy.offIfSupported);
    expect(restored.reasoningControlSuppressed, isTrue);
  });

  test('请求快照拒绝空模型和缺失 local provider', () {
    expect(
      () => TranslationRequestProfile.fromJson({
        'version': 1,
        'mode': 'backend',
        'providerId': null,
        'modelId': '   ',
        'reasoningPolicy': 'providerDefault',
        'reasoningControlSuppressed': false,
      }),
      throwsFormatException,
    );
    expect(
      () => TranslationRequestProfile.fromJson({
        'version': 1,
        'mode': 'local',
        'providerId': null,
        'modelId': 'deepseek-chat',
        'reasoningPolicy': 'providerDefault',
        'reasoningControlSuppressed': false,
      }),
      throwsFormatException,
    );
  });
}

TranslationRequestProfile _deepSeekProfile() => TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      reasoningControlSuppressed: false,
    );

AISettings _settingsWithProviders({required String activeProviderId}) {
  return AISettings(
    mode: AIMode.local,
    providers: [
      AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek',
        apiKey: 'test-key',
        apiHost: 'https://api.deepseek.com',
        models: [AiModel(id: 'deepseek-chat')],
        selectedModelId: 'deepseek-chat',
        enabled: true,
      ),
      AiProvider(
        id: 'openai',
        type: 'openai',
        name: 'OpenAI',
        apiKey: 'test-key',
        apiHost: 'https://api.openai.com',
        models: [AiModel(id: 'gpt-4.1')],
        selectedModelId: 'gpt-4.1',
        enabled: true,
      ),
    ],
    activeProviderId: activeProviderId,
    backendModel: 'backend-fast',
    streamEnabled: true,
    resetOnLogout: true,
  );
}
