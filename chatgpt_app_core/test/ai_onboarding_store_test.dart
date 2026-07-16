import 'dart:async';

import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('onboarding key 使用固定 v1 前缀并保留 accountHash', () {
    expect(
      AIOnboardingStore.keyFor('account-123'),
      'ai_onboarding_v1_account-123',
    );
  });

  test('缺失、非字符串和 allowlist 外的值都按 unseen 读取', () {
    final storage = _MemoryOnboardingStorage();
    storage.values[AIOnboardingStore.keyFor('corrupt-type')] = 1;
    storage.values[AIOnboardingStore.keyFor('corrupt-name')] = 'loading';
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => 'unused',
    );

    expect(store.read('missing'), AIOnboardingStatus.unseen);
    expect(store.read('corrupt-type'), AIOnboardingStatus.unseen);
    expect(store.read('corrupt-name'), AIOnboardingStatus.unseen);
  });

  test('每个 accountHash 使用独立 key 和可见状态', () async {
    var current = 'account-a';
    final storage = _MemoryOnboardingStorage();
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => current,
    );

    await store.save(
      AIOnboardingStatus.dismissed,
      expectedAccountHash: 'account-a',
    );
    current = 'account-b';
    await store.save(
      AIOnboardingStatus.completed,
      expectedAccountHash: 'account-b',
    );

    expect(store.read('account-a'), AIOnboardingStatus.dismissed);
    expect(store.read('account-b'), AIOnboardingStatus.completed);
    expect(
      storage.values[AIOnboardingStore.keyFor('account-a')],
      'dismissed',
    );
    expect(
      storage.values[AIOnboardingStore.keyFor('account-b')],
      'completed',
    );
  });

  test('账号 A 的写入等待期间切到 B 后会拒绝并恢复 A 原值', () async {
    var current = 'account-a';
    final pending = Completer<bool>();
    final storage = _MemoryOnboardingStorage()..pendingWrite = pending;
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => current,
    );

    final saving = store.save(
      AIOnboardingStatus.dismissed,
      expectedAccountHash: 'account-a',
    );
    await Future<void>.delayed(Duration.zero);
    current = 'account-b';
    pending.complete(true);

    await expectLater(saving, throwsStateError);
    expect(store.read('account-a'), AIOnboardingStatus.unseen);
    expect(
      storage.values.containsKey(AIOnboardingStore.keyFor('account-a')),
      isFalse,
    );
  });

  test('写失败时 SharedPreferences 风格的预先 cache 变更不会泄漏到可见状态',
      () async {
    const account = 'account-a';
    final key = AIOnboardingStore.keyFor(account);
    final storage = _MemoryOnboardingStorage()
      ..values[key] = 'dismissed'
      ..nextWriteResult = false;
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => account,
    );
    expect(store.read(account), AIOnboardingStatus.dismissed);

    await expectLater(
      store.save(
        AIOnboardingStatus.completed,
        expectedAccountHash: account,
      ),
      throwsStateError,
    );

    expect(store.read(account), AIOnboardingStatus.dismissed);
    expect(storage.values[key], 'dismissed');
  });

  test('原写入和回滚都返回 false 时保持旧可见状态并报告回滚失败', () async {
    const account = 'rollback-failure';
    final key = AIOnboardingStore.keyFor(account);
    final storage = _MemoryOnboardingStorage()
      ..values[key] = 'dismissed'
      ..writeResults.addAll([false, false]);
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => account,
    );
    expect(store.read(account), AIOnboardingStatus.dismissed);

    await expectLater(
      store.save(
        AIOnboardingStatus.completed,
        expectedAccountHash: account,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('回滚未持久化'),
        ),
      ),
    );

    expect(store.read(account), AIOnboardingStatus.dismissed);
  });

  test('同一账号的连续保存会串行，后一次只在前一次完成后写盘', () async {
    const account = 'account-a';
    final firstWrite = Completer<bool>();
    final secondWrite = Completer<bool>();
    final storage = _MemoryOnboardingStorage()
      ..pendingWrites.addAll([firstWrite, secondWrite]);
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => account,
    );

    final first = store.save(
      AIOnboardingStatus.dismissed,
      expectedAccountHash: account,
    );
    final second = store.save(
      AIOnboardingStatus.completed,
      expectedAccountHash: account,
    );
    await Future<void>.delayed(Duration.zero);
    expect(storage.writeCount, 1);

    firstWrite.complete(true);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(storage.writeCount, 2);

    secondWrite.complete(true);
    await second;
    expect(store.read(account), AIOnboardingStatus.completed);
  });

  test('任一旧用户证据都会持久化 grandfathered；全 false 保持 unseen',
      () async {
    final evidences = [
      const AIOnboardingEvidence(
        hasStoredSettings: true,
        hasConversationHistory: false,
        hasCustomProvider: false,
        hasSuccessfulHealthCheck: false,
      ),
      const AIOnboardingEvidence(
        hasStoredSettings: false,
        hasConversationHistory: true,
        hasCustomProvider: false,
        hasSuccessfulHealthCheck: false,
      ),
      const AIOnboardingEvidence(
        hasStoredSettings: false,
        hasConversationHistory: false,
        hasCustomProvider: true,
        hasSuccessfulHealthCheck: false,
      ),
      const AIOnboardingEvidence(
        hasStoredSettings: false,
        hasConversationHistory: false,
        hasCustomProvider: false,
        hasSuccessfulHealthCheck: true,
      ),
    ];

    for (var i = 0; i < evidences.length; i++) {
      final account = 'legacy-$i';
      final storage = _MemoryOnboardingStorage();
      final store = AIOnboardingStore(
        storage: storage,
        currentAccountHash: () => account,
      );

      expect(
        await store.classify(
          expectedAccountHash: account,
          evidence: evidences[i],
        ),
        AIOnboardingStatus.grandfathered,
      );
      expect(store.read(account), AIOnboardingStatus.grandfathered);
    }

    const fresh = 'fresh';
    final freshStorage = _MemoryOnboardingStorage();
    final freshStore = AIOnboardingStore(
      storage: freshStorage,
      currentAccountHash: () => fresh,
    );
    expect(
      await freshStore.classify(
        expectedAccountHash: fresh,
        evidence: AIOnboardingEvidence.empty,
      ),
      AIOnboardingStatus.unseen,
    );
    expect(freshStorage.writeCount, 0);
  });

  test('dismissed/completed 持久状态优先且 legacy 分类幂等', () async {
    for (final status in [
      AIOnboardingStatus.dismissed,
      AIOnboardingStatus.completed,
    ]) {
      final account = status.name;
      final storage = _MemoryOnboardingStorage()
        ..values[AIOnboardingStore.keyFor(account)] = status.name;
      final store = AIOnboardingStore(
        storage: storage,
        currentAccountHash: () => account,
      );

      expect(
        await store.classify(
          expectedAccountHash: account,
          evidence: const AIOnboardingEvidence(
            hasStoredSettings: true,
            hasConversationHistory: true,
            hasCustomProvider: true,
            hasSuccessfulHealthCheck: true,
          ),
        ),
        status,
      );
      expect(storage.writeCount, 0);
    }

    const account = 'legacy-idempotent';
    final storage = _MemoryOnboardingStorage();
    final store = AIOnboardingStore(
      storage: storage,
      currentAccountHash: () => account,
    );
    const evidence = AIOnboardingEvidence(
      hasStoredSettings: true,
      hasConversationHistory: false,
      hasCustomProvider: false,
      hasSuccessfulHealthCheck: false,
    );
    await store.classify(
      expectedAccountHash: account,
      evidence: evidence,
    );
    await store.classify(
      expectedAccountHash: account,
      evidence: evidence,
    );
    expect(storage.writeCount, 1);
  });
}

final class _MemoryOnboardingStorage implements AIOnboardingKeyValueStore {
  final Map<String, Object?> values = {};
  Completer<bool>? pendingWrite;
  final List<Completer<bool>> pendingWrites = [];
  bool nextWriteResult = true;
  final List<bool> writeResults = [];
  int writeCount = 0;

  @override
  Object? read(String key) => values[key];

  @override
  Future<bool> writeString(String key, String value) async {
    writeCount++;
    // 模拟 SharedPreferences：Future 完成前内存 cache 已经改变。
    values[key] = value;
    if (pendingWrites.isNotEmpty) {
      return pendingWrites.removeAt(0).future;
    }
    final pending = pendingWrite;
    if (pending != null) return pending.future;
    if (writeResults.isNotEmpty) return writeResults.removeAt(0);
    return nextWriteResult;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}
