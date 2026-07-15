import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_readiness_resolver.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AISettings configuredSettings({String testStatus = 'success'}) {
    final settings = AISettings.defaults();
    final provider = settings.activeProvider
      ..apiKey = 'stable-key'
      ..apiHost = '';
    for (final model in provider.models) {
      model
        ..lastTestStatus = testStatus
        ..lastTestAt = testStatus == 'unknown' ? null : 123
        ..lastTestError = testStatus == 'failure' ? 'failed' : null;
    }
    return settings;
  }

  void expectCleared(AISettings settings, {String? providerId}) {
    final provider = providerId == null
        ? settings.activeProvider
        : settings.providers.firstWhere((item) => item.id == providerId);
    for (final model in provider.models) {
      expect(model.lastTestStatus, 'unknown');
      expect(model.lastTestAt, isNull);
      expect(model.lastTestError, isNull);
    }
  }

  test('配置未变时保留健康检查刚写入的 success', () {
    final previous = configuredSettings(testStatus: 'unknown');
    final next = previous.clone();
    next.activeProvider.models.first
      ..lastTestStatus = 'success'
      ..lastTestAt = 456;

    final reconciled = reconcileAIHealthState(
      previous: previous,
      next: next,
    );

    expect(reconciled.activeProvider.models.first.lastTestStatus, 'success');
    expect(reconciled.activeProvider.models.first.lastTestAt, 456);
    expect(
      resolveAIReadiness(settings: reconciled, isGuest: false).status,
      AIReadyStatus.ready,
    );
  });

  test('非连接配置变化不会清除已有 success', () {
    final previous = configuredSettings();
    final next = previous.clone()
      ..streamEnabled = !previous.streamEnabled
      ..searchMaxResults = previous.searchMaxResults + 1;

    final reconciled = reconcileAIHealthState(
      previous: previous,
      next: next,
    );

    expect(reconciled.activeProvider.models.first.lastTestStatus, 'success');
  });

  test('API key 改变会清除该 provider 全部健康结果', () {
    final previous = configuredSettings();
    final next = previous.clone()..activeProvider.apiKey = 'changed-key';

    final reconciled = reconcileAIHealthState(
      previous: previous,
      next: next,
    );

    expectCleared(reconciled);
    expect(
      resolveAIReadiness(settings: reconciled, isGuest: false).status,
      AIReadyStatus.configuredUnverified,
    );
  });

  test('有效 host 相同保留结果，有效 host 改变清除结果', () {
    final previous = configuredSettings();
    final equivalent = previous.clone()
      ..activeProvider.apiHost = 'https://api.deepseek.com';
    final same = reconcileAIHealthState(
      previous: previous,
      next: equivalent,
    );
    expect(same.activeProvider.models.first.lastTestStatus, 'success');

    final changed = previous.clone()
      ..activeProvider.apiHost = 'https://proxy.example.com/v1';
    final reconciled = reconcileAIHealthState(
      previous: previous,
      next: changed,
    );
    expectCleared(reconciled);
  });

  test('当前模型选择或模型身份集合改变会清除结果', () {
    final previous = configuredSettings();
    final changedSelection = previous.clone();
    changedSelection.activeProvider.selectedModelId =
        changedSelection.activeProvider.models.last.id;
    expectCleared(
      reconcileAIHealthState(
        previous: previous,
        next: changedSelection,
      ),
    );

    final changedIdentity = previous.clone();
    changedIdentity.activeProvider.models.add(
      AiModel(id: 'new-model', lastTestStatus: 'success', lastTestAt: 789),
    );
    expectCleared(
      reconcileAIHealthState(
        previous: previous,
        next: changedIdentity,
      ),
    );
  });

  test('新 provider 不能携带没有本地配置基线的 success', () {
    final previous = configuredSettings();
    final next = previous.clone();
    next.providers.add(
      AiProvider(
        id: 'custom-restored',
        type: 'openai',
        name: 'Restored',
        apiKey: 'restored-key',
        apiHost: 'https://restored.example.com',
        enabled: true,
        selectedModelId: 'restored-model',
        models: [
          AiModel(
            id: 'restored-model',
            lastTestStatus: 'success',
            lastTestAt: 999,
          ),
        ],
      ),
    );

    final reconciled = reconcileAIHealthState(
      previous: previous,
      next: next,
    );

    expectCleared(reconciled, providerId: 'custom-restored');
    expect(
      previous.providers.any((provider) => provider.id == 'custom-restored'),
      isFalse,
    );
  });

  test('测试开始配置快照拒绝 Key host 选择与模型身份变化', () {
    final settings = configuredSettings();
    final provider = settings.activeProvider;
    final expected = AIProviderHealthConfiguration.capture(provider);

    expect(expected.matches(provider.copy()), isTrue);
    expect(
      expected.matches(provider.copy()..apiKey = 'changed-key'),
      isFalse,
    );
    expect(
      expected.matches(
        provider.copy()..apiHost = 'https://changed.example.com',
      ),
      isFalse,
    );
    expect(
      expected.matches(
        provider.copy()..selectedModelId = provider.models.last.id,
      ),
      isFalse,
    );
    expect(
      expected.matches(
        provider.copy()..models.add(AiModel(id: 'new-model')),
      ),
      isFalse,
    );
  });
}
