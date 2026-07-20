import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const evaluator = TranslationModelEligibilityEvaluator();

  test('guest backend is blocked before transport creation', () {
    final result = evaluator.evaluatePreference(
      settings: _backendSettings(),
      preference: _backendPreference(),
      environment: _environment(
        isGuest: true,
        platform: TargetPlatform.iOS,
        backendHost: 'localhost:3000',
      ),
    );

    expect(result.canStart, isFalse);
    expect(result.primaryIssue?.code, TranslationEligibilityCode.guestBackend);
  });

  test('guest local configuration remains eligible', () {
    final result = evaluator.evaluatePreference(
      settings: _localSettings(),
      preference: _localPreference(),
      environment: _environment(isGuest: true),
    );

    expect(result.level, TranslationEligibilityLevel.allowed);
    expect(result.canStart, isTrue);
  });

  test('local resolver failures expose stable blocked codes', () {
    final cases = <({
      String name,
      AISettings settings,
      TranslationModelPreference preference,
      TranslationEligibilityCode code
    })>[
      (
        name: 'missing provider id',
        settings: _localSettings()..activeProviderId = '',
        preference: const TranslationModelPreference(
          mode: TranslationModelPreferenceMode.followGlobal,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
        code: TranslationEligibilityCode.providerMissing,
      ),
      (
        name: 'deleted provider',
        settings: _localSettings()..providers.clear(),
        preference: _localPreference(),
        code: TranslationEligibilityCode.providerMissing,
      ),
      (
        name: 'disabled provider',
        settings: _localSettings()..providers.single.enabled = false,
        preference: _localPreference(),
        code: TranslationEligibilityCode.providerDisabled,
      ),
      (
        name: 'empty api key',
        settings: _localSettings()..providers.single.apiKey = '  ',
        preference: _localPreference(),
        code: TranslationEligibilityCode.apiKeyMissing,
      ),
      (
        name: 'empty model',
        settings: _backendSettings()..backendModel = ' ',
        preference: const TranslationModelPreference(
          mode: TranslationModelPreferenceMode.followGlobal,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        ),
        code: TranslationEligibilityCode.modelMissing,
      ),
      (
        name: 'removed model',
        settings: _localSettings()..providers.single.models.clear(),
        preference: _localPreference(),
        code: TranslationEligibilityCode.modelMissing,
      ),
    ];

    for (final testCase in cases) {
      final result = evaluator.evaluatePreference(
        settings: testCase.settings,
        preference: testCase.preference,
        environment: _environment(),
      );

      expect(result.level, TranslationEligibilityLevel.blocked,
          reason: testCase.name);
      expect(result.primaryIssue?.code, testCase.code, reason: testCase.name);
    }
  });

  test('invalid local endpoints are blocked', () {
    final empty = evaluator.evaluatePreference(
      settings: _customLocalSettings(endpoint: ''),
      preference: _customLocalPreference(),
      environment: _environment(),
    );
    expect(empty.level, TranslationEligibilityLevel.blocked);
    expect(
        empty.primaryIssue?.code, TranslationEligibilityCode.invalidEndpoint);

    const invalidEndpoints = [
      'api.example.com',
      'ftp://api.example.com',
      'https:///v1/chat/completions',
      'https://user:password@api.example.com',
    ];

    for (final endpoint in invalidEndpoints) {
      final result = evaluator.evaluatePreference(
        settings: _localSettings(endpoint: endpoint),
        preference: _localPreference(),
        environment: _environment(),
      );

      expect(result.level, TranslationEligibilityLevel.blocked,
          reason: endpoint);
      expect(
          result.primaryIssue?.code, TranslationEligibilityCode.invalidEndpoint,
          reason: endpoint);
    }
  });

  test(
      'mobile local loopback is a warning while desktop and emulator hosts work',
      () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        final result = evaluator.evaluatePreference(
          settings: _localSettings(endpoint: 'https://$host/v1'),
          preference: _localPreference(),
          environment: _environment(platform: platform),
        );

        expect(result.level, TranslationEligibilityLevel.warning,
            reason: '$platform / $host');
        expect(result.canStart, isTrue);
        expect(result.primaryIssue?.code,
            TranslationEligibilityCode.mobileLoopback);
      }
    }

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      final result = evaluator.evaluatePreference(
        settings: _localSettings(endpoint: 'https://localhost/v1'),
        preference: _localPreference(),
        environment: _environment(platform: platform),
      );
      expect(result.level, TranslationEligibilityLevel.allowed,
          reason: platform.name);
    }

    final emulator = evaluator.evaluatePreference(
      settings: _localSettings(endpoint: 'https://10.0.2.2/v1'),
      preference: _localPreference(),
      environment: _environment(platform: TargetPlatform.android),
    );
    expect(emulator.level, TranslationEligibilityLevel.allowed);
  });

  test('backend HTTP is blocked only for Android store builds', () {
    final cases = <({
      AppDistribution distribution,
      bool useHttps,
      TranslationEligibilityLevel level,
      TranslationEligibilityCode? code
    })>[
      (
        distribution: AppDistribution.store,
        useHttps: false,
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.androidStoreCleartext,
      ),
      (
        distribution: AppDistribution.direct,
        useHttps: false,
        level: TranslationEligibilityLevel.allowed,
        code: null,
      ),
      (
        distribution: AppDistribution.development,
        useHttps: false,
        level: TranslationEligibilityLevel.allowed,
        code: null,
      ),
      (
        distribution: AppDistribution.store,
        useHttps: true,
        level: TranslationEligibilityLevel.allowed,
        code: null,
      ),
    ];

    for (final testCase in cases) {
      final result = evaluator.evaluatePreference(
        settings: _backendSettings(),
        preference: _backendPreference(),
        environment: _environment(
          platform: TargetPlatform.android,
          distribution: testCase.distribution,
          backendUseHttps: testCase.useHttps,
        ),
      );

      expect(result.level, testCase.level,
          reason: '${testCase.distribution} / ${testCase.useHttps}');
      expect(result.primaryIssue?.code, testCase.code);
    }
  });

  test('invalid backend hosts are blocked before transport creation', () {
    const invalidHosts = [
      '',
      '/relative-backend',
      'ftp://api.example.com',
      'https:///missing-host',
      'user:password@api.example.com',
    ];

    for (final host in invalidHosts) {
      final result = evaluator.evaluatePreference(
        settings: _backendSettings(),
        preference: _backendPreference(),
        environment: _environment(backendHost: host),
      );

      expect(result.level, TranslationEligibilityLevel.blocked, reason: host);
      expect(
          result.primaryIssue?.code, TranslationEligibilityCode.invalidEndpoint,
          reason: host);
    }
  });

  test('local HTTP is blocked only for Android store builds', () {
    final cases = <({
      AppDistribution distribution,
      String endpoint,
      TranslationEligibilityLevel level,
      TranslationEligibilityCode? code,
    })>[
      (
        distribution: AppDistribution.store,
        endpoint: 'http://api.example.com',
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.androidStoreCleartext,
      ),
      (
        distribution: AppDistribution.development,
        endpoint: 'http://api.example.com',
        level: TranslationEligibilityLevel.allowed,
        code: null,
      ),
      (
        distribution: AppDistribution.store,
        endpoint: 'https://api.example.com',
        level: TranslationEligibilityLevel.allowed,
        code: null,
      ),
    ];

    for (final testCase in cases) {
      final result = evaluator.evaluatePreference(
        settings: _localSettings(endpoint: testCase.endpoint),
        preference: _localPreference(),
        environment: _environment(distribution: testCase.distribution),
      );

      expect(result.level, testCase.level, reason: testCase.endpoint);
      expect(result.primaryIssue?.code, testCase.code);
    }
  });

  test('blocked issues take priority over loopback warnings', () {
    final result = evaluator.evaluateProfile(
      settings: _localSettings(endpoint: 'https://localhost/v1')
        ..providers.single.apiKey = '',
      profile: _localProfile(),
      environment: _environment(platform: TargetPlatform.android),
    );

    expect(result.level, TranslationEligibilityLevel.blocked);
    expect(result.canStart, isFalse);
    expect(result.primaryIssue?.code, TranslationEligibilityCode.apiKeyMissing);
  });

  test('blocked issues expose exact executable repair labels by code and mode',
      () {
    void expectLabel(
      TranslationEligibilityResult result,
      String label,
      TranslationEligibilityRepairTarget target,
    ) {
      expect(result.canStart, isFalse);
      expect(result.primaryIssue?.actionLabel, label);
      expect(result.primaryIssue?.repairTarget, target);
    }

    expectLabel(
      evaluator.evaluatePreference(
        settings: _backendSettings(),
        preference: _backendPreference(),
        environment: _environment(isGuest: true),
      ),
      '去登录',
      TranslationEligibilityRepairTarget.login,
    );
    for (final settings in [
      _localSettings()..providers.single.enabled = false,
      _localSettings()..providers.single.apiKey = '',
      _localSettings()..providers.single.models.clear(),
      _localSettings(endpoint: 'not-a-url'),
    ]) {
      expectLabel(
        evaluator.evaluatePreference(
          settings: settings,
          preference: _localPreference(),
          environment: _environment(),
        ),
        '配置服务商',
        TranslationEligibilityRepairTarget.providerSettings,
      );
    }
    expectLabel(
      evaluator.evaluatePreference(
        settings: _backendSettings(),
        preference: _backendPreference(),
        environment: _environment(backendHost: ''),
      ),
      '改用本地直连',
      TranslationEligibilityRepairTarget.requestModeSettings,
    );
    expectLabel(
      evaluator.evaluatePreference(
        settings: _backendSettings(),
        preference: _backendPreference(),
        environment: _environment(
          platform: TargetPlatform.android,
          distribution: AppDistribution.store,
          backendUseHttps: false,
        ),
      ),
      '改用本地直连',
      TranslationEligibilityRepairTarget.requestModeSettings,
    );
    expectLabel(
      evaluator.evaluatePreference(
        settings: _localSettings(endpoint: 'http://api.example.com'),
        preference: _localPreference(),
        environment: _environment(
          platform: TargetPlatform.android,
          distribution: AppDistribution.store,
        ),
      ),
      '配置服务商',
      TranslationEligibilityRepairTarget.providerSettings,
    );
  });
}

TranslationEligibilityEnvironment _environment({
  bool isGuest = false,
  TargetPlatform platform = TargetPlatform.android,
  AppDistribution distribution = AppDistribution.development,
  String backendHost = 'api.example.com',
  bool backendUseHttps = true,
}) =>
    TranslationEligibilityEnvironment(
      isGuest: isGuest,
      platform: platform,
      distribution: distribution,
      backendHost: backendHost,
      backendUseHttps: backendUseHttps,
    );

TranslationModelPreference _localPreference() =>
    const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );

TranslationModelPreference _backendPreference() =>
    const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );

TranslationRequestProfile _localProfile() => TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      reasoningControlSuppressed: false,
    );

AISettings _localSettings({String endpoint = 'https://api.deepseek.com'}) =>
    AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'deepseek',
          type: 'openai',
          name: 'DeepSeek',
          apiKey: 'test-key',
          apiHost: endpoint,
          models: [AiModel(id: 'deepseek-chat')],
          selectedModelId: 'deepseek-chat',
          enabled: true,
        ),
      ],
      activeProviderId: 'deepseek',
      backendModel: 'deepseek-chat',
      streamEnabled: true,
      resetOnLogout: true,
    );

AISettings _backendSettings() => _localSettings()..mode = AIMode.backend;

TranslationModelPreference _customLocalPreference() =>
    const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.local,
      providerId: 'custom',
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );

AISettings _customLocalSettings({required String endpoint}) => AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'custom',
          type: 'openai',
          name: 'Custom',
          apiKey: 'test-key',
          apiHost: endpoint,
          models: [AiModel(id: 'deepseek-chat')],
          selectedModelId: 'deepseek-chat',
          enabled: true,
        ),
      ],
      activeProviderId: 'custom',
      backendModel: 'deepseek-chat',
      streamEnabled: true,
      resetOnLogout: true,
    );
