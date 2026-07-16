import 'dart:async';

import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_consent_store.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_gate.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_sink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticsGate', () {
    bool gate({
      required bool buildConfigured,
      required bool userConsented,
      required bool remoteDisabled,
    }) =>
        DiagnosticsGate.enabled(
          buildConfigured: buildConfigured,
          userConsented: userConsented,
          remoteDisabled: remoteDisabled,
        );

    test('只有构建已配置、用户同意且远端未熔断时启用', () {
      expect(
        gate(
          buildConfigured: true,
          userConsented: true,
          remoteDisabled: false,
        ),
        isTrue,
      );
      expect(
        gate(
          buildConfigured: false,
          userConsented: true,
          remoteDisabled: false,
        ),
        isFalse,
      );
      expect(
        gate(
          buildConfigured: true,
          userConsented: false,
          remoteDisabled: false,
        ),
        isFalse,
      );
      expect(
        gate(
          buildConfigured: true,
          userConsented: true,
          remoteDisabled: true,
        ),
        isFalse,
      );
    });
  });

  group('DiagnosticsConsentStore', () {
    test('使用设备全局固定 key，缺失或损坏值都读取为 false', () {
      final adapter = _MemoryAdapter();
      final store = _store(adapter);

      expect(DiagnosticsConsentStore.key, 'diagnostics_consent_v1');
      expect(store.read(), isFalse);

      adapter.values[DiagnosticsConsentStore.key] = 'true';
      expect(store.read(), isFalse);

      adapter.values[DiagnosticsConsentStore.key] = 1;
      expect(store.read(), isFalse);

      adapter.values[DiagnosticsConsentStore.key] = true;
      expect(store.read(), isTrue);
    });

    test('读取存储异常时 fail-closed', () {
      final store = DiagnosticsConsentStore(
        storage: _MemoryAdapter(throwOnRead: true),
        session: DiagnosticsConsentSessionState(),
      );

      expect(store.read(), isFalse);
    });

    test('write 等待持久化成功后才可读到新值', () async {
      final adapter = _MemoryAdapter();
      final store = _store(adapter);

      await store.write(true);

      expect(store.read(), isTrue);
      expect(adapter.writeKeys, [DiagnosticsConsentStore.key]);
    });

    test('启用写盘未完成时，即使底层 cache 已变 true 也继续 deny', () async {
      final adapter = _PendingAdapter();
      final store = DiagnosticsConsentStore(
        storage: adapter,
        session: DiagnosticsConsentSessionState(),
      );

      final pendingWrite = store.write(true);
      await Future<void>.delayed(Duration.zero);

      expect(adapter.value, isTrue);
      expect(store.read(), isFalse);

      adapter.result.complete(true);
      await pendingWrite;
      expect(store.read(), isTrue);
    });

    test('底层返回失败时 write 抛错且不会乐观改变值', () async {
      final adapter = _MemoryAdapter(
        writeSucceeds: false,
        mutateCacheBeforeResult: true,
      );
      final store = _store(adapter);

      await expectLater(store.write(true), throwsStateError);

      expect(store.read(), isFalse);
      expect(adapter.values[DiagnosticsConsentStore.key], isFalse);
    });

    test('撤回同意失败且回滚也失败时，本次会话仍立即 deny', () async {
      final adapter = _MemoryAdapter(
        writeSucceeds: false,
        mutateCacheBeforeResult: true,
      )..values[DiagnosticsConsentStore.key] = true;
      final store = _store(adapter);

      await expectLater(store.write(false), throwsStateError);

      // 第一次写把 cache 改为 false，失败后的 restore 又先改回 true 后失败。
      // 会话 deny 必须优先于这个仍为 true 的底层 cache。
      expect(adapter.writeKeys, hasLength(2));
      expect(adapter.values[DiagnosticsConsentStore.key], isTrue);
      expect(store.read(), isFalse);
    });

    test('底层写异常会原样暴露且不会乐观改变值', () async {
      final failure = StateError('disk full');
      final adapter = _MemoryAdapter(writeError: failure);
      final store = _store(adapter);

      await expectLater(store.write(true), throwsA(same(failure)));

      expect(store.read(), isFalse);
    });

    test('失败后的会话 deny 只有成功持久化 true 才能解除', () async {
      final session = DiagnosticsConsentSessionState();
      final failedAdapter = _MemoryAdapter(
        writeSucceeds: false,
        mutateCacheBeforeResult: true,
      );
      final failedStore = DiagnosticsConsentStore(
        storage: failedAdapter,
        session: session,
      );
      await expectLater(failedStore.write(true), throwsStateError);

      final recoveredAdapter = _MemoryAdapter();
      final recoveredStore = DiagnosticsConsentStore(
        storage: recoveredAdapter,
        session: session,
      );
      expect(recoveredStore.read(), isFalse);

      await recoveredStore.write(true);

      expect(recoveredStore.read(), isTrue);
    });

    test('默认 store 实例共享进程级 deny', () async {
      final failedAdapter = _MemoryAdapter(
        writeSucceeds: false,
        mutateCacheBeforeResult: true,
      )..values[DiagnosticsConsentStore.key] = true;
      final firstStore = DiagnosticsConsentStore(storage: failedAdapter);
      await expectLater(firstStore.write(false), throwsStateError);

      final recoveredAdapter = _MemoryAdapter()
        ..values[DiagnosticsConsentStore.key] = true;
      final secondStore = DiagnosticsConsentStore(storage: recoveredAdapter);
      expect(secondStore.read(), isFalse);

      // 成功、持久化的显式同意可以解除本次进程 deny，并清理测试状态。
      await secondStore.write(true);
      expect(secondStore.read(), isTrue);
    });
  });

  group('ConsentGatedDiagnosticsSink', () {
    test('truth table 只有三项同时允许时才调用真实 delegate', () {
      final delegate = _CollectingSink();
      const cases = <({
        bool buildConfigured,
        bool userConsented,
        bool remoteDisabled,
      })>[
        (
          buildConfigured: true,
          userConsented: true,
          remoteDisabled: false,
        ),
        (
          buildConfigured: false,
          userConsented: true,
          remoteDisabled: false,
        ),
        (
          buildConfigured: true,
          userConsented: false,
          remoteDisabled: false,
        ),
        (
          buildConfigured: true,
          userConsented: true,
          remoteDisabled: true,
        ),
      ];

      for (final entry in cases) {
        final adapter = _MemoryAdapter()
          ..values[DiagnosticsConsentStore.key] = entry.userConsented;
        final sink = ConsentGatedDiagnosticsSink(
          delegate: delegate,
          consentStore: _store(adapter),
          buildConfigured: () => entry.buildConfigured,
          remoteDisabled: () => entry.remoteDisabled,
        );

        sink.capture(_event());
      }

      expect(delegate.events, hasLength(1));
    });

    test('即使显式传真实 delegate，缺失 gate 配置仍默认拒绝', () {
      final delegate = _CollectingSink();
      final adapter = _MemoryAdapter()
        ..values[DiagnosticsConsentStore.key] = true;
      final sink = ConsentGatedDiagnosticsSink(
        delegate: delegate,
        consentStore: _store(adapter),
      );

      sink.capture(_event());

      expect(delegate.events, isEmpty);
    });

    test('build 与 remote 开关也会在每次 capture 时重新读取', () {
      final delegate = _CollectingSink();
      final adapter = _MemoryAdapter()
        ..values[DiagnosticsConsentStore.key] = true;
      var buildConfigured = false;
      var remoteDisabled = false;
      final sink = ConsentGatedDiagnosticsSink(
        delegate: delegate,
        consentStore: _store(adapter),
        buildConfigured: () => buildConfigured,
        remoteDisabled: () => remoteDisabled,
      );

      sink.capture(_event());
      expect(delegate.events, isEmpty);

      buildConfigured = true;
      sink.capture(_event());
      expect(delegate.events, hasLength(1));

      remoteDisabled = true;
      sink.capture(_event());
      expect(delegate.events, hasLength(1));
    });

    test('每次 capture 动态读取 consent，撤回落盘失败也立即停止', () async {
      final delegate = _CollectingSink();
      final adapter = _MemoryAdapter(
        writeSucceeds: false,
        mutateCacheBeforeResult: true,
      )..values[DiagnosticsConsentStore.key] = true;
      final store = _store(adapter);
      final sink = ConsentGatedDiagnosticsSink(
        delegate: delegate,
        consentStore: store,
        buildConfigured: () => true,
        remoteDisabled: () => false,
      );

      sink.capture(_event());
      expect(delegate.events, hasLength(1));

      await expectLater(store.write(false), throwsStateError);
      expect(adapter.values[DiagnosticsConsentStore.key], isTrue);

      sink.capture(_event());
      expect(delegate.events, hasLength(1));
    });

    test('任一动态 gate reader 抛错时 fail-closed', () {
      final delegate = _CollectingSink();
      final adapter = _MemoryAdapter()
        ..values[DiagnosticsConsentStore.key] = true;
      final sink = ConsentGatedDiagnosticsSink(
        delegate: delegate,
        consentStore: _store(adapter),
        buildConfigured: () => throw StateError('config unavailable'),
        remoteDisabled: () => false,
      );

      expect(() => sink.capture(_event()), returnsNormally);
      expect(delegate.events, isEmpty);
    });
  });
}

DiagnosticsConsentStore _store(_MemoryAdapter adapter) =>
    DiagnosticsConsentStore(
      storage: adapter,
      session: DiagnosticsConsentSessionState(),
    );

DiagnosticsEvent _event() => DiagnosticsEvent(
      source: DiagnosticsSource.zone,
      exceptionType: 'StateError',
      stackFrames: const ['package:chatgpt_app_core/a.dart:1:2'],
    );

class _MemoryAdapter implements DiagnosticsConsentKeyValueStore {
  final Map<String, Object?> values = {};
  final List<String> writeKeys = [];
  final bool throwOnRead;
  final bool writeSucceeds;
  final bool mutateCacheBeforeResult;
  final Object? writeError;

  _MemoryAdapter({
    this.throwOnRead = false,
    this.writeSucceeds = true,
    this.mutateCacheBeforeResult = false,
    this.writeError,
  });

  @override
  Object? read(String key) {
    if (throwOnRead) throw StateError('read failed');
    return values[key];
  }

  @override
  Future<bool> writeBool(String key, bool value) async {
    writeKeys.add(key);
    if (mutateCacheBeforeResult) values[key] = value;
    if (writeError case final Object error) throw error;
    if (!writeSucceeds) return false;
    values[key] = value;
    return true;
  }
}

class _CollectingSink implements DiagnosticsSink {
  final List<DiagnosticsEvent> events = [];

  @override
  void capture(DiagnosticsEvent event) => events.add(event);
}

class _PendingAdapter implements DiagnosticsConsentKeyValueStore {
  final Completer<bool> result = Completer<bool>();
  Object? value;

  @override
  Object? read(String key) => value;

  @override
  Future<bool> writeBool(String key, bool value) {
    this.value = value;
    return result.future;
  }
}
