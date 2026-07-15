import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AISettings localSettings({
    String providerId = 'custom_active',
    String apiKey = 'key',
    String apiHost = 'https://example.com',
    String selectedModelId = 'model-a',
    bool enabled = true,
    String selectedTestStatus = 'unknown',
    List<AiProvider> otherProviders = const [],
  }) {
    final provider = AiProvider(
      id: providerId,
      type: 'openai',
      name: 'Active',
      apiKey: apiKey,
      apiHost: apiHost,
      enabled: enabled,
      selectedModelId: selectedModelId,
      models: selectedModelId.isEmpty
          ? []
          : [
              AiModel(
                id: selectedModelId,
                lastTestStatus: selectedTestStatus,
              ),
            ],
    );
    return AISettings(
      mode: AIMode.local,
      providers: [provider, ...otherProviders],
      activeProviderId: providerId,
      backendModel: 'backend-model',
      streamEnabled: true,
      resetOnLogout: true,
    );
  }

  group('local readiness', () {
    test('空 Key 需要配置', () {
      final state = resolveAIReadiness(
        settings: localSettings(apiKey: '  '),
        isGuest: false,
      );

      expect(state.status, AIReadyStatus.needsSetup);
      expect(state.reasonCode, 'missing_api_key');
    });

    test('自定义 provider 空 host 需要配置', () {
      final state = resolveAIReadiness(
        settings: localSettings(apiHost: '  '),
        isGuest: false,
      );

      expect(state.status, AIReadyStatus.needsSetup);
      expect(state.reasonCode, 'missing_api_host');
    });

    test('系统预设空 host 继续使用预设 fallback', () {
      final state = resolveAIReadiness(
        settings: localSettings(
          providerId: 'deepseek',
          apiHost: '',
        ),
        isGuest: false,
      );

      expect(state.status, AIReadyStatus.configuredUnverified);
      expect(state.reasonCode, 'model_unverified');
    });

    test('空模型或被禁用的当前 provider 需要配置', () {
      final missingModel = resolveAIReadiness(
        settings: localSettings(selectedModelId: ''),
        isGuest: false,
      );
      final disabled = resolveAIReadiness(
        settings: localSettings(enabled: false),
        isGuest: false,
      );

      expect(missingModel.status, AIReadyStatus.needsSetup);
      expect(missingModel.reasonCode, 'missing_model');
      expect(disabled.status, AIReadyStatus.needsSetup);
      expect(disabled.reasonCode, 'provider_disabled');
    });

    test('完整但未测试的配置为 configuredUnverified', () {
      final state = resolveAIReadiness(
        settings: localSettings(),
        isGuest: false,
      );

      expect(state.status, AIReadyStatus.configuredUnverified);
      expect(state.reasonCode, 'model_unverified');
      expect(state.providerId, 'custom_active');
      expect(state.modelId, 'model-a');
    });

    test('当前模型成功为 ready，失败为 temporarilyUnavailable', () {
      final success = resolveAIReadiness(
        settings: localSettings(selectedTestStatus: 'success'),
        isGuest: false,
      );
      final failure = resolveAIReadiness(
        settings: localSettings(selectedTestStatus: 'failure'),
        isGuest: false,
      );

      expect(success.status, AIReadyStatus.ready);
      expect(success.reasonCode, 'model_test_succeeded');
      expect(failure.status, AIReadyStatus.temporarilyUnavailable);
      expect(failure.reasonCode, 'model_test_failed');
    });

    test('只读取当前 provider 的当前有效模型健康状态', () {
      final inactiveSuccess = AiProvider(
        id: 'inactive',
        type: 'openai',
        name: 'Inactive',
        enabled: true,
        apiKey: 'other-key',
        apiHost: 'https://other.example.com',
        selectedModelId: 'other-model',
        models: [
          AiModel(id: 'other-model', lastTestStatus: 'success'),
        ],
      );
      final settings = localSettings(otherProviders: [inactiveSuccess]);
      settings.activeProvider.models.add(
        AiModel(id: 'not-selected', lastTestStatus: 'failure'),
      );

      final state = resolveAIReadiness(settings: settings, isGuest: false);

      expect(state.status, AIReadyStatus.configuredUnverified);
      expect(state.modelId, 'model-a');
    });

    test('guest 的有效 local 配置不要求登录', () {
      final state = resolveAIReadiness(
        settings: localSettings(selectedTestStatus: 'success'),
        isGuest: true,
      );

      expect(state.status, AIReadyStatus.ready);
      expect(state.status, isNot(AIReadyStatus.backendRequiresLogin));
    });
  });

  group('backend readiness', () {
    AISettings backendSettings(String model) => AISettings(
          mode: AIMode.backend,
          providers: [],
          activeProviderId: '',
          backendModel: model,
          streamEnabled: true,
          resetOnLogout: true,
        );

    test('guest backend 始终要求登录', () {
      for (final model in ['backend-model', '  ']) {
        final state = resolveAIReadiness(
          settings: backendSettings(model),
          isGuest: true,
        );

        expect(state.status, AIReadyStatus.backendRequiresLogin);
        expect(state.reasonCode, 'backend_login_required');
      }
    });

    test('已登录 backend 非空模型未验证，空模型需要配置', () {
      final configured = resolveAIReadiness(
        settings: backendSettings(' backend-model '),
        isGuest: false,
      );
      final missing = resolveAIReadiness(
        settings: backendSettings('  '),
        isGuest: false,
      );

      expect(configured.status, AIReadyStatus.configuredUnverified);
      expect(configured.reasonCode, 'model_unverified');
      expect(configured.modelId, 'backend-model');
      expect(missing.status, AIReadyStatus.needsSetup);
      expect(missing.reasonCode, 'missing_model');
    });
  });

  test('AIReadyState 具备值语义', () {
    const first = AIReadyState(
      status: AIReadyStatus.ready,
      reasonCode: 'model_test_succeeded',
      providerId: 'p',
      modelId: 'm',
    );
    const second = AIReadyState(
      status: AIReadyStatus.ready,
      reasonCode: 'model_test_succeeded',
      providerId: 'p',
      modelId: 'm',
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(const AIReadyState.loading().status, AIReadyStatus.loading);
  });
}
