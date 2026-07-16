import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('偏好 key 使用固定 v1 前缀并保留 accountHash', () {
    expect(
      TranslationModelPreferenceStore.keyFor('account-a'),
      'translation_model_preference_v1_account-a',
    );
  });

  test('损坏 JSON 回退 followGlobal 与 offIfSupported', () {
    final storage = _MemoryTranslationPreferenceStorage();
    storage.values[TranslationModelPreferenceStore.keyFor('invalid-json')] =
        '{';
    storage.values[TranslationModelPreferenceStore.keyFor('invalid-mode')] =
        jsonEncode({
      'mode': 'automatic',
      'reasoningPolicy': 'offIfSupported',
    });
    storage.values[TranslationModelPreferenceStore.keyFor('invalid-local')] =
        jsonEncode({
      'mode': 'local',
      'modelId': 'deepseek-chat',
      'reasoningPolicy': 'offIfSupported',
    });
    final store = TranslationModelPreferenceStore(
      storage: storage,
      currentAccountHash: () => 'unused',
    );

    for (final account in [
      'missing',
      'invalid-json',
      'invalid-mode',
      'invalid-local',
    ]) {
      final preference = store.read(account);
      expect(
        preference.mode,
        TranslationModelPreferenceMode.followGlobal,
        reason: account,
      );
      expect(
        preference.reasoningPolicy,
        ChatReasoningPolicy.offIfSupported,
        reason: account,
      );
      expect(preference.providerId, isNull, reason: account);
      expect(preference.modelId, isNull, reason: account);
    }
  });

  test('账号 A 与 B 使用独立 key 和可见偏好', () async {
    var current = 'account-a';
    final storage = _MemoryTranslationPreferenceStorage();
    final store = TranslationModelPreferenceStore(
      storage: storage,
      currentAccountHash: () => current,
    );
    const accountA = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );
    const accountB = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'backend-fast',
      reasoningPolicy: ChatReasoningPolicy.providerDefault,
    );

    await store.save(accountA, expectedAccountHash: 'account-a');
    current = 'account-b';
    await store.save(accountB, expectedAccountHash: 'account-b');

    expect(store.read('account-a').providerId, 'deepseek');
    expect(store.read('account-a').modelId, 'deepseek-chat');
    expect(
      store.read('account-b').mode,
      TranslationModelPreferenceMode.backend,
    );
    expect(store.read('account-b').modelId, 'backend-fast');
    expect(
      storage.values.keys,
      containsAll([
        TranslationModelPreferenceStore.keyFor('account-a'),
        TranslationModelPreferenceStore.keyFor('account-b'),
      ]),
    );
  });

  test('账号 A 写入等待期间切到 B 会拒绝并恢复 A 旧偏好', () async {
    var current = 'account-a';
    final pending = Completer<bool>();
    const previous = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'backend-old',
      reasoningPolicy: ChatReasoningPolicy.providerDefault,
    );
    const next = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.local,
      providerId: 'openai',
      modelId: 'gpt-4.1',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );
    final key = TranslationModelPreferenceStore.keyFor('account-a');
    final previousRaw = jsonEncode(previous.toJson());
    final storage = _MemoryTranslationPreferenceStorage()
      ..values[key] = previousRaw
      ..pendingWrite = pending;
    final store = TranslationModelPreferenceStore(
      storage: storage,
      currentAccountHash: () => current,
    );
    expect(store.read('account-a').modelId, 'backend-old');

    final saving = store.save(next, expectedAccountHash: 'account-a');
    await Future<void>.delayed(Duration.zero);
    current = 'account-b';
    pending.complete(true);

    await expectLater(saving, throwsStateError);
    expect(store.read('account-a').modelId, 'backend-old');
    expect(storage.values[key], previousRaw);
  });

  test('落盘失败保持旧可见偏好并恢复旧 JSON', () async {
    const account = 'account-a';
    const previous = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'backend-old',
      reasoningPolicy: ChatReasoningPolicy.providerDefault,
    );
    const next = TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'backend-new',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );
    final key = TranslationModelPreferenceStore.keyFor(account);
    final previousRaw = jsonEncode(previous.toJson());
    final storage = _MemoryTranslationPreferenceStorage()
      ..values[key] = previousRaw
      ..nextWriteResult = false;
    final store = TranslationModelPreferenceStore(
      storage: storage,
      currentAccountHash: () => account,
    );
    expect(store.read(account).modelId, 'backend-old');

    await expectLater(
      store.save(next, expectedAccountHash: account),
      throwsStateError,
    );

    expect(store.read(account).modelId, 'backend-old');
    expect(storage.values[key], previousRaw);
  });

  test('持久化 JSON 只有非敏感偏好字段', () async {
    const account = 'safe-json';
    final storage = _MemoryTranslationPreferenceStorage();
    final store = TranslationModelPreferenceStore(
      storage: storage,
      currentAccountHash: () => account,
    );

    await store.save(
      const TranslationModelPreference(
        mode: TranslationModelPreferenceMode.local,
        providerId: 'deepseek',
        modelId: 'deepseek-chat',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      ),
      expectedAccountHash: account,
    );

    final raw = storage.values[TranslationModelPreferenceStore.keyFor(account)]!
        as String;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(json.keys.toSet(), {
      'mode',
      'providerId',
      'modelId',
      'reasoningPolicy',
    });
    final lower = raw.toLowerCase();
    expect(lower, isNot(contains('apikey')));
    expect(lower, isNot(contains('apihost')));
    expect(lower, isNot(contains('token')));
    expect(lower, isNot(contains('authorization')));
  });
}

final class _MemoryTranslationPreferenceStorage
    implements TranslationPreferenceKeyValueStore {
  final Map<String, Object?> values = {};
  Completer<bool>? pendingWrite;
  bool nextWriteResult = true;

  @override
  Object? read(String key) => values[key];

  @override
  Future<bool> writeString(String key, String value) async {
    // 模拟 SharedPreferences：Future 完成前内存 cache 已经改变。
    values[key] = value;
    final pending = pendingWrite;
    if (pending != null) return pending.future;
    return nextWriteResult;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}
