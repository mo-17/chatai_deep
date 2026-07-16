import 'dart:async';

import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String currentAccount;
  late _MemoryOnboardingStorage storage;
  late AIOnboardingStore onboardingStore;

  setUp(() {
    currentAccount = 'account-a';
    storage = _MemoryOnboardingStorage();
    onboardingStore = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => currentAccount,
    );
  });

  AISettings configuredSettings() {
    final settings = AISettings.defaults();
    settings.activeProvider
      ..apiKey = 'ready-key'
      ..enabled = true;
    return settings;
  }

  test('新账号初始化为 unseen，并随设置同步纯计算 readiness', () async {
    final provider = AIReadinessProvider(
      onboardingStore: onboardingStore,
      evidenceReader: ({
        required accountHash,
        required settings,
        storage,
      }) async => AIOnboardingEvidence.empty,
    );
    provider.synchronize(
      settings: AISettings.defaults(),
      accountHash: currentAccount,
      isGuest: false,
    );

    await provider.initialize();

    expect(provider.onboardingStatus, AIOnboardingStatus.unseen);
    expect(provider.state.status, AIReadyStatus.needsSetup);
    expect(provider.showProactiveCard, isTrue);

    provider.synchronize(
      settings: configuredSettings(),
      accountHash: currentAccount,
      isGuest: false,
    );
    expect(provider.state.status, AIReadyStatus.configuredUnverified);
    expect(provider.showProactiveCard, isTrue);

    await provider.dismiss();
    expect(provider.onboardingStatus, AIOnboardingStatus.dismissed);
    expect(provider.showProactiveCard, isFalse);
    expect(storage.values[AIOnboardingStore.keyFor(currentAccount)],
        'dismissed');
  });

  test('旧用户证据静默 grandfather，不展示主动卡片', () async {
    final provider = AIReadinessProvider(
      onboardingStore: onboardingStore,
      evidenceReader: ({
        required accountHash,
        required settings,
        storage,
      }) async => const AIOnboardingEvidence(
        hasStoredSettings: false,
        hasConversationHistory: true,
        hasCustomProvider: false,
        hasSuccessfulHealthCheck: false,
      ),
    );
    provider.synchronize(
      settings: configuredSettings(),
      accountHash: currentAccount,
      isGuest: false,
    );

    await provider.initialize();

    expect(provider.onboardingStatus, AIOnboardingStatus.grandfathered);
    expect(provider.showProactiveCard, isFalse);
  });

  test('账号切换会丢弃旧账号尚未完成的初始化结果', () async {
    final accountAEvidence = Completer<AIOnboardingEvidence>();
    final provider = AIReadinessProvider(
      onboardingStore: onboardingStore,
      evidenceReader: ({
        required accountHash,
        required settings,
        storage,
      }) {
        if (accountHash == 'account-a') return accountAEvidence.future;
        return Future.value(AIOnboardingEvidence.empty);
      },
    );
    provider.synchronize(
      settings: configuredSettings(),
      accountHash: currentAccount,
      isGuest: false,
    );
    final oldInitialization = provider.initialize();

    currentAccount = 'account-b';
    provider.synchronize(
      settings: AISettings.defaults(),
      accountHash: currentAccount,
      isGuest: false,
    );
    accountAEvidence.complete(const AIOnboardingEvidence(
      hasStoredSettings: true,
      hasConversationHistory: true,
      hasCustomProvider: true,
      hasSuccessfulHealthCheck: true,
    ));
    await oldInitialization;

    expect(provider.initialized, isFalse);
    expect(provider.state, const AIReadyState.loading());
    expect(provider.onboardingStatus, AIOnboardingStatus.unseen);

    await provider.initialize();
    expect(provider.initialized, isTrue);
    expect(provider.onboardingStatus, AIOnboardingStatus.unseen);
    expect(provider.state.status, AIReadyStatus.needsSetup);
  });

  test('markCompleted 持久化完成态且重复调用幂等', () async {
    final provider = AIReadinessProvider(
      onboardingStore: onboardingStore,
      evidenceReader: ({
        required accountHash,
        required settings,
        storage,
      }) async => AIOnboardingEvidence.empty,
    );
    provider.synchronize(
      settings: configuredSettings(),
      accountHash: currentAccount,
      isGuest: false,
    );
    await provider.initialize();

    await provider.markCompleted();
    await provider.markCompleted();

    expect(provider.onboardingStatus, AIOnboardingStatus.completed);
    expect(provider.showProactiveCard, isFalse);
    expect(storage.writeCount, 1);
  });
}

final class _MemoryOnboardingStorage implements AIOnboardingKeyValueStore {
  final Map<String, Object?> values = {};
  int writeCount = 0;

  @override
  Object? read(String key) => values[key];

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> writeString(String key, String value) async {
    writeCount++;
    values[key] = value;
    return true;
  }
}
