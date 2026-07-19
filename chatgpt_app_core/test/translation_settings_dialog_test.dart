import 'dart:async';

import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/translation_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('打开、切换、搜索和确认未验证模型都不会隐式发起预检', (tester) async {
    final settings = _settings();
    var accountHash = 'account-a';
    final gateway = _FakeProbeGateway();
    final initialProfile = TranslationModelResolver.snapshot(
      settings,
      _localPreference(),
    );
    final initialFingerprint = gateway.fingerprint(
      accountHash,
      settings,
      initialProfile,
    );
    gateway.records[initialFingerprint] = _record(
      initialFingerprint,
      status: TranslationModelProbeStatus.verified,
    );
    TranslationSettingsResult? result;

    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          readSnapshot: () => _snapshot(settings, accountHash: accountHash),
          initialValue: _localPreference(),
          estimatedRunes: 33322,
          probeService: gateway,
        );
      },
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('预计翻译 33,322 字'), findsOneWidget);
    expect(gateway.startCalls, 0);
    expect(find.text('已验证'), findsOneWidget);
    gateway.records.clear();
    await tester.tap(
      find.byKey(const ValueKey('translation_disable_thinking')),
    );
    await tester.pump();
    expect(find.text('未验证'), findsOneWidget);
    expect(gateway.startCalls, 0);

    await tester.tap(find.byKey(const ValueKey('translation_model_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随全局设置'));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);

    await tester.tap(find.byKey(const ValueKey('translation_model_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('backend-fast'));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);

    await tester.tap(find.byKey(const ValueKey('translation_model_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('configured_model_search')),
      'custom',
    );
    await tester.pump();
    expect(gateway.startCalls, 0);
    await tester.tap(find.text('Custom fast'));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.text('该模型尚未完成预检。'), findsOneWidget);
    expect(gateway.startCalls, 0);
    await tester.tap(
      find.byKey(const ValueKey('translation_warning_continue')),
    );
    await tester.pumpAndSettle();

    expect(gateway.startCalls, 0);
    expect(result?.preference.providerId, 'custom');
    expect(result?.profile.modelId, 'custom-fast');
    expect(result?.warningsAcknowledged, isTrue);
    expect(settings.activeProviderId, 'deepseek');
    accountHash = 'account-b';
  });

  testWidgets('缓存验证证据会进入返回 profile 且无需再次确认', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();
    final profile =
        TranslationModelResolver.snapshot(settings, _localPreference());
    gateway.records[gateway.fingerprint('account-a', settings, profile)] =
        _record(
      gateway.fingerprint('account-a', settings, profile),
      status: TranslationModelProbeStatus.verified,
      reasoningControlSuppressed: true,
    );
    TranslationSettingsResult? result;

    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          readSnapshot: () => _snapshot(settings),
          initialValue: _localPreference(),
          estimatedRunes: 100,
          probeService: gateway,
        );
      },
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('已验证'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.warningsAcknowledged, isFalse);
    expect(result!.profile.reasoningControlSuppressed, isTrue);
    expect(gateway.startCalls, 0);
  });

  testWidgets('测试按钮先提示 Token；取消零请求，确认单请求且可取消', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('可能产生少量 Token'), findsOneWidget);
    expect(gateway.startCalls, 0);
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_cancel')));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);

    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
    await tester.pump();
    expect(gateway.startCalls, 1);
    expect(
        find.byKey(const ValueKey('translation_probe_cancel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('translation_probe_cancel')));
    await tester.pumpAndSettle();
    expect(gateway.cancelCalls, 1);
  });

  testWidgets('显式预检成功显示时间，失败只显示脱敏本地化动作', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();
    gateway.autoRecord = (fingerprint) => _record(
          fingerprint,
          status: TranslationModelProbeStatus.verified,
          firstEventMs: 42,
          totalMs: 88,
        );

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _confirmProbe(tester);
    expect(find.textContaining('首字 42 ms'), findsOneWidget);
    expect(find.textContaining('总计 88 ms'), findsOneWidget);

    gateway.autoRecord = (fingerprint) => _record(
          fingerprint,
          status: TranslationModelProbeStatus.failed,
          safeErrorCode: 'rate_limited',
        );
    await _confirmProbe(tester);
    expect(find.text('请求过于频繁，请稍后重试。'), findsWidgets);
    expect(find.textContaining('rate_limited'), findsNothing);
    expect(find.text('重新测试'), findsOneWidget);
  });

  testWidgets('关闭设置会取消本对话框仍在运行的预检', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
    await tester.pump();
    expect(gateway.startCalls, 1);

    await tester.tap(find.byKey(const ValueKey('translation_settings_cancel')));
    await tester.pumpAndSettle();
    expect(gateway.cancelCalls, 1);
  });

  testWidgets('Token 提示期间 Key 或可用性变化会阻止请求', (tester) async {
    var settings = _settings();
    final gateway = _FakeProbeGateway();

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    settings = settings.clone();
    settings.providers.first.apiKey = 'changed-key';
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);
    expect(find.text('翻译配置已变化，请重新确认'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    settings = settings.clone();
    settings.providers.first.enabled = false;
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
    await tester.pumpAndSettle();
    expect(gateway.startCalls, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('translation_settings_confirm')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('请求运行期间配置变化会丢弃旧结果', (tester) async {
    var settings = _settings();
    final gateway = _FakeProbeGateway();

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
    await tester.pump();
    final started = gateway.lastHandle!;
    settings = settings.clone();
    settings.providers.first.apiHost = 'https://changed.example/v1';
    started.complete(_record(
      started.fingerprint,
      status: TranslationModelProbeStatus.verified,
    ));
    await tester.pumpAndSettle();

    expect(find.text('已验证'), findsNothing);
    expect(find.text('翻译配置已变化，请重新确认'), findsOneWidget);
    expect(gateway.lastGuard?.call(), isFalse);
  });

  testWidgets('仅内存展示的成功结果在 Key 变化后也会立即失效', (tester) async {
    var settings = _settings();
    final gateway = _FakeProbeGateway()
      ..storeAutoRecord = false
      ..autoRecord = (fingerprint) => _record(
            fingerprint,
            status: TranslationModelProbeStatus.verified,
          );

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _confirmProbe(tester);
    expect(find.text('已验证'), findsOneWidget);

    settings = settings.clone();
    settings.providers.first.apiKey = 'rotated-key';
    await tester.tap(
      find.byKey(const ValueKey('translation_disable_thinking')),
    );
    await tester.pump();

    expect(find.text('已验证'), findsNothing);
    expect(find.text('未验证'), findsOneWidget);
    expect(gateway.startCalls, 1);
  });

  testWidgets('账号在警告确认期间变化时必须为新 identity 再确认一次', (tester) async {
    final settings = _settings();
    var accountHash = 'account-a';
    final gateway = _FakeProbeGateway();
    TranslationSettingsResult? result;

    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          readSnapshot: () => _snapshot(settings, accountHash: accountHash),
          initialValue: _localPreference(),
          estimatedRunes: 100,
          probeService: gateway,
        );
      },
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();
    accountHash = 'account-b';
    await tester.tap(
      find.byKey(const ValueKey('translation_warning_continue')),
    );
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('翻译配置已变化，请重新确认'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('translation_warning_continue')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('translation_warning_continue')),
    );
    await tester.pumpAndSettle();
    expect(result?.identity.accountHash, 'account-b');
  });

  testWidgets('blocked 模型不能测试或开始，并可触发精确修复动作', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();
    TranslationEligibilityIssue? fixed;

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(settings),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
        onFixIssue: (issue) async => fixed = issue,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translation_model_button')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('configured_ai_model_picker')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disabled model'));
    await tester.pumpAndSettle();

    expect(find.text('配置不可用'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('translation_probe_button')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('translation_settings_confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('translation_fix_issue')));
    await tester.pump();
    expect(fixed?.code, TranslationEligibilityCode.providerDisabled);
    expect(gateway.startCalls, 0);
  });

  testWidgets('本地地址 warning 即使已有 verified 也必须确认', (tester) async {
    final settings = _settings(apiHost: 'http://127.0.0.1:11434/v1');
    final gateway = _FakeProbeGateway();
    final profile =
        TranslationModelResolver.snapshot(settings, _localPreference());
    final fingerprint = gateway.fingerprint('account-a', settings, profile);
    gateway.records[fingerprint] = _record(
      fingerprint,
      status: TranslationModelProbeStatus.verified,
    );

    await tester.pumpWidget(_host(
      onOpen: (context) => showTranslationSettingsDialog(
        context,
        readSnapshot: () => _snapshot(
          settings,
          platform: TargetPlatform.iOS,
        ),
        initialValue: _localPreference(),
        estimatedRunes: 100,
        probeService: gateway,
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('地址警告'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('translation_settings_confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本机地址'), findsWidgets);
    expect(
      find.byKey(const ValueKey('translation_warning_continue')),
      findsOneWidget,
    );
  });

  testWidgets('未知字符数仍显示不可用且取消返回 null', (tester) async {
    final settings = _settings();
    final gateway = _FakeProbeGateway();
    TranslationSettingsResult? result;
    await tester.pumpWidget(_host(
      onOpen: (context) async {
        result = await showTranslationSettingsDialog(
          context,
          readSnapshot: () => _snapshot(settings),
          initialValue: _localPreference(),
          estimatedRunes: 0,
          probeService: gateway,
        );
      },
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('预计字符数暂不可用'), findsOneWidget);
    expect(find.text('预计翻译 0 字'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('translation_settings_cancel')));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}

Future<void> _confirmProbe(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('translation_probe_button')));
  await tester.pumpAndSettle();
  await tester
      .tap(find.byKey(const ValueKey('translation_probe_notice_confirm')));
  await tester.pumpAndSettle();
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

TranslationSettingsSnapshot _snapshot(
  AISettings settings, {
  String accountHash = 'account-a',
  TargetPlatform platform = TargetPlatform.macOS,
}) =>
    TranslationSettingsSnapshot(
      settings: settings.clone(),
      accountHash: accountHash,
      eligibilityEnvironment: TranslationEligibilityEnvironment(
        isGuest: false,
        platform: platform,
        distribution: AppDistribution.development,
        backendHost: 'backend.example',
        backendUseHttps: true,
      ),
    );

TranslationModelPreference _localPreference() =>
    const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-v4-flash',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    );

AISettings _settings({String apiHost = 'https://example.test/v1'}) =>
    AISettings(
      mode: AIMode.local,
      providers: [
        AiProvider(
          id: 'deepseek',
          type: 'openai',
          name: 'DeepSeek',
          apiKey: 'key',
          apiHost: apiHost,
          enabled: true,
          selectedModelId: 'deepseek-v4-flash',
          models: [AiModel(id: 'deepseek-v4-flash')],
        ),
        AiProvider(
          id: 'custom',
          type: 'openai',
          name: 'Custom',
          apiKey: 'key',
          apiHost: 'https://custom.example/v1',
          enabled: true,
          selectedModelId: 'custom-fast',
          models: [AiModel(id: 'custom-fast', name: 'Custom fast')],
        ),
        AiProvider(
          id: 'disabled',
          type: 'openai',
          name: 'Disabled',
          apiKey: 'key',
          apiHost: 'https://disabled.example/v1',
          enabled: false,
          selectedModelId: 'disabled-model',
          models: [AiModel(id: 'disabled-model', name: 'Disabled model')],
        ),
      ],
      activeProviderId: 'deepseek',
      backendModel: 'backend-fast',
      streamEnabled: true,
      resetOnLogout: true,
    );

TranslationModelProbeRecord _record(
  String fingerprint, {
  required TranslationModelProbeStatus status,
  int? firstEventMs,
  int? totalMs,
  String? safeErrorCode,
  bool reasoningControlSuppressed = false,
}) =>
    TranslationModelProbeRecord(
      fingerprint: fingerprint,
      status: status,
      checkedAt: DateTime.utc(2026, 7, 20, 8, 30),
      firstEventMs: firstEventMs,
      totalMs: totalMs,
      safeErrorCode: safeErrorCode,
      reasoningControlSuppressed: reasoningControlSuppressed,
    );

final class _FakeProbeGateway implements TranslationModelProbeGateway {
  final Map<String, TranslationModelProbeRecord> records = {};
  TranslationModelProbeRecord Function(String fingerprint)? autoRecord;
  bool storeAutoRecord = true;
  int generation = 0;
  int startCalls = 0;
  int cancelCalls = 0;
  bool Function()? lastGuard;
  _FakeProbeHandle? lastHandle;

  String fingerprint(
    String accountHash,
    AISettings settings,
    TranslationRequestProfile profile,
  ) {
    String localHealth = '';
    if (profile.mode == TranslationExecutionMode.local) {
      final provider = settings.providers.firstWhere(
        (item) => item.id == profile.providerId,
      );
      localHealth = [
        provider.enabled,
        provider.apiKey,
        provider.apiHost,
        provider.models.map((model) => model.id).join(','),
      ].join('|');
    }
    return [
      accountHash,
      profile.mode.name,
      profile.providerId,
      profile.modelId,
      profile.reasoningPolicy.name,
      localHealth,
    ].join('|');
  }

  @override
  TranslationModelProbeIdentity identify({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) =>
      TranslationModelProbeIdentity(
        accountHash: accountHash,
        fingerprint: fingerprint(accountHash, settings, profile),
        cacheToken: TranslationModelProbeCacheToken(
          accountGeneration: generation,
          providerGeneration: generation,
        ),
      );

  @override
  bool isIdentityCurrent(
    TranslationModelProbeIdentity identity, {
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    final current = identify(
      accountHash: accountHash,
      settings: settings,
      profile: profile,
    );
    return identity.accountHash == current.accountHash &&
        identity.fingerprint == current.fingerprint &&
        identity.cacheToken.sameAs(current.cacheToken);
  }

  @override
  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) =>
      records[fingerprint(accountHash, settings, profile)];

  @override
  TranslationModelProbeHandle start({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
    required bool Function() isConfigurationCurrent,
  }) {
    startCalls += 1;
    lastGuard = isConfigurationCurrent;
    final key = fingerprint(accountHash, settings, profile);
    final handle = _FakeProbeHandle(
      key,
      onCancel: () => cancelCalls += 1,
    );
    lastHandle = handle;
    final factory = autoRecord;
    if (factory != null) {
      final record = factory(key);
      if (storeAutoRecord) records[key] = record;
      scheduleMicrotask(() => handle.complete(record));
    }
    return handle;
  }

  @override
  TranslationRequestProfile applyCachedEvidence({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) =>
      lookup(
                accountHash: accountHash,
                settings: settings,
                profile: profile,
              )?.reasoningControlSuppressed ==
              true
          ? profile.suppressReasoningControl()
          : profile;
}

final class _FakeProbeHandle implements TranslationModelProbeHandle {
  final String fingerprint;
  final VoidCallback onCancel;
  final Completer<TranslationModelProbeResult> _completer = Completer();

  _FakeProbeHandle(this.fingerprint, {required this.onCancel});

  @override
  Future<TranslationModelProbeResult> get result => _completer.future;

  @override
  void cancel() {
    onCancel();
    if (!_completer.isCompleted) {
      _completer.completeError(StateError('cancelled'));
    }
  }

  void complete(TranslationModelProbeRecord record) {
    if (_completer.isCompleted) return;
    _completer.complete(TranslationModelProbeResult(record: record));
  }
}
