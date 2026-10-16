import 'package:chatgpt_app_core/chat/application/translation_selection_session.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection_error.dart';
import 'package:chatgpt_app_core/widget/backend_selection_picker.dart';
import 'dart:async';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/widget/configured_ai_model_picker_sheet.dart';
import 'package:flutter/material.dart';

final class TranslationSettingsResult {
  final TranslationModelPreference preference;
  final TranslationRequestProfile profile;
  final TranslationModelProbeIdentity identity;
  final TranslationSettingsEvidenceSignature evidenceSignature;
  final bool warningsAcknowledged;
  final TranslationSelectionSession? preparedSession;

  const TranslationSettingsResult({
    required this.preference,
    required this.profile,
    required this.identity,
    required this.evidenceSignature,
    required this.warningsAcknowledged,
    this.preparedSession,
  });
}

/// 用户确认时看到的 eligibility + probe 证据版本。
///
/// 签名只包含枚举、时间、脱敏错误码和 cache generation；不包含 API Key、
/// endpoint 或 warning 原文，也不提供可被误写进日志的字符串表示。
final class TranslationSettingsEvidenceSignature {
  final List<String> _eligibilityKeys;
  final String _fingerprint;
  final int _accountGeneration;
  final int _providerGeneration;
  final int _runtimeProviderGeneration;
  final String _recordState;
  final int? _checkedAtMillis;
  final int? _firstEventMs;
  final int? _totalMs;
  final String? _safeErrorCode;
  final bool? _reasoningControlSuppressed;

  TranslationSettingsEvidenceSignature._({
    required List<String> eligibilityKeys,
    required String fingerprint,
    required int accountGeneration,
    required int providerGeneration,
    required int runtimeProviderGeneration,
    required String recordState,
    required int? checkedAtMillis,
    required int? firstEventMs,
    required int? totalMs,
    required String? safeErrorCode,
    required bool? reasoningControlSuppressed,
  })  : _eligibilityKeys = List.unmodifiable(eligibilityKeys),
        _fingerprint = fingerprint,
        _accountGeneration = accountGeneration,
        _providerGeneration = providerGeneration,
        _runtimeProviderGeneration = runtimeProviderGeneration,
        _recordState = recordState,
        _checkedAtMillis = checkedAtMillis,
        _firstEventMs = firstEventMs,
        _totalMs = totalMs,
        _safeErrorCode = safeErrorCode,
        _reasoningControlSuppressed = reasoningControlSuppressed;

  bool sameAs(TranslationSettingsEvidenceSignature other) =>
      _sameStrings(_eligibilityKeys, other._eligibilityKeys) &&
      _fingerprint == other._fingerprint &&
      _accountGeneration == other._accountGeneration &&
      _providerGeneration == other._providerGeneration &&
      _runtimeProviderGeneration == other._runtimeProviderGeneration &&
      _recordState == other._recordState &&
      _checkedAtMillis == other._checkedAtMillis &&
      _firstEventMs == other._firstEventMs &&
      _totalMs == other._totalMs &&
      _safeErrorCode == other._safeErrorCode &&
      _reasoningControlSuppressed == other._reasoningControlSuppressed;
}

TranslationSettingsEvidenceSignature buildTranslationSettingsEvidenceSignature({
  required TranslationEligibilityResult eligibility,
  required TranslationModelProbeIdentity identity,
  required TranslationModelProbeRecord? record,
}) =>
    TranslationSettingsEvidenceSignature._(
      eligibilityKeys: [
        for (final issue in eligibility.issues)
          '${issue.level.name}:${issue.code.name}',
      ],
      fingerprint: identity.fingerprint,
      accountGeneration: identity.cacheToken.accountGeneration,
      providerGeneration: identity.cacheToken.providerGeneration,
      runtimeProviderGeneration: identity.cacheToken.runtimeProviderGeneration,
      recordState: record?.status.name ?? 'missing',
      checkedAtMillis: record?.checkedAt.toUtc().millisecondsSinceEpoch,
      firstEventMs: record?.firstEventMs,
      totalMs: record?.totalMs,
      safeErrorCode: record?.safeErrorCode,
      reasoningControlSuppressed: record?.reasoningControlSuppressed,
    );

final class TranslationSettingsSnapshot {
  final AISettings settings;
  final String accountHash;
  final TranslationEligibilityEnvironment eligibilityEnvironment;

  const TranslationSettingsSnapshot({
    required this.settings,
    required this.accountHash,
    required this.eligibilityEnvironment,
  });
}

typedef TranslationSettingsSnapshotReader = TranslationSettingsSnapshot
    Function();

/// 页面在启动 coordinator 前得到的同一份 fresh settings/profile 快照。
final class TranslationSettingsHandoff {
  final TranslationSettingsSnapshot snapshot;
  final TranslationRequestProfile profile;
  final TranslationSelectionSession? preparedSession;

  const TranslationSettingsHandoff({
    required this.snapshot,
    required this.profile,
    this.preparedSession,
  });
}

/// 一次设置对话框返回值及其绑定的 fresh snapshot reader。
final class TranslationSettingsSelection {
  final TranslationSettingsResult result;
  final TranslationSettingsSnapshotReader readSnapshot;

  const TranslationSettingsSelection({
    required this.result,
    required this.readSnapshot,
  });
}

/// production caller 已通过边界复核并成功交给 coordinator 的同一份 handoff。
final class TranslationPreflightAccepted {
  final TranslationSettingsSelection selection;
  final TranslationSettingsHandoff handoff;

  const TranslationPreflightAccepted({
    required this.selection,
    required this.handoff,
  });
}

typedef TranslationSettingsSelector = Future<TranslationSettingsSelection?>
    Function(TranslationModelPreference initialValue);
typedef TranslationPreflightStarter = Future<void> Function(
  TranslationSettingsHandoff handoff,
  TranslationEligibilityResult Function(TranslationRequestProfile profile)
      checkEligibility,
);

/// 设置结果到 coordinator 之间唯一的生产循环：任何 identity/evidence 漂移都
/// 回到选择器；checker 则在 coordinator 写任务前再做最后一次同步复核。
Future<TranslationPreflightAccepted?> runTranslationPreflightStartLoop({
  required TranslationModelPreference initialValue,
  TranslationSettingsSelection? initialSelection,
  required TranslationSettingsSelector select,
  required TranslationModelProbeGateway probeService,
  required TranslationPreflightStarter start,
  FutureOr<void> Function()? onConfigurationChanged,
}) async {
  var nextInitial = initialValue;
  var pendingSelection = initialSelection;
  while (true) {
    final selection = pendingSelection ?? await select(nextInitial);
    pendingSelection = null;
    if (selection == null) return null;
    final result = selection.result;
    final handoff = resolveTranslationSettingsHandoff(
      result: result,
      readSnapshot: selection.readSnapshot,
      probeService: probeService,
    );
    if (handoff == null) {
      await onConfigurationChanged?.call();
      nextInitial = result.preference;
      continue;
    }
    final checkEligibility = buildTranslationSettingsEligibilityCheck(
      readSnapshot: selection.readSnapshot,
      probeService: probeService,
      result: result,
      expectedProfile: handoff.profile,
    );
    if (!checkEligibility(handoff.profile).canStart) {
      await onConfigurationChanged?.call();
      nextInitial = result.preference;
      continue;
    }
    try {
      await start(handoff, checkEligibility);
      return TranslationPreflightAccepted(
        selection: selection,
        handoff: handoff,
      );
    } on TranslationModelUnavailableException catch (error) {
      if (error.safeCode !=
          TranslationEligibilityCode.configurationChanged.name) {
        rethrow;
      }
      await onConfigurationChanged?.call();
      nextInitial = result.preference;
    }
  }
}

/// dialog 返回到页面后重新读取缓存和配置。任何身份变化，或出现尚未确认的
/// warning，都会要求页面重新打开设置，而不是创建任务。
TranslationSettingsHandoff? resolveTranslationSettingsHandoff({
  required TranslationSettingsResult result,
  required TranslationSettingsSnapshotReader readSnapshot,
  required TranslationModelProbeGateway probeService,
}) {
  try {
    final snapshot = readSnapshot();
    final profile = _profileForConfirmedResult(result, snapshot);
    const evaluator = TranslationModelEligibilityEvaluator();
    final eligibility = evaluator.evaluateProfile(
      settings: snapshot.settings,
      profile: profile,
      environment: snapshot.eligibilityEnvironment,
    );
    if (!eligibility.canStart ||
        !probeService.isIdentityCurrent(
          result.identity,
          accountHash: snapshot.accountHash,
          settings: snapshot.settings,
          profile: profile,
        )) {
      return null;
    }
    final record = probeService.lookup(
      accountHash: snapshot.accountHash,
      settings: snapshot.settings,
      profile: profile,
    );
    final evidenceSignature = buildTranslationSettingsEvidenceSignature(
      eligibility: eligibility,
      identity: result.identity,
      record: record,
    );
    if (!result.evidenceSignature.sameAs(evidenceSignature)) return null;
    if (_requiresWarning(eligibility, record) && !result.warningsAcknowledged) {
      return null;
    }
    return TranslationSettingsHandoff(
      snapshot: result.preparedSession == null
          ? snapshot
          : TranslationSettingsSnapshot(
              settings: result.preparedSession!.settings.clone(),
              accountHash: snapshot.accountHash,
              eligibilityEnvironment: snapshot.eligibilityEnvironment),
      preparedSession: result.preparedSession,
      profile: probeService.applyCachedEvidence(
        accountHash: snapshot.accountHash,
        settings: snapshot.settings,
        profile: profile,
      ),
    );
  } catch (_) {
    return null;
  }
}

/// coordinator 会在写入任务前和异步执行前重复调用。闭包只捕获同步 reader，
/// 不捕获 BuildContext；配置或兼容证据变化时，以稳定 blocked 语义中止。
TranslationEligibilityResult Function(TranslationRequestProfile profile)
    buildTranslationSettingsEligibilityCheck({
  required TranslationSettingsSnapshotReader readSnapshot,
  required TranslationModelProbeGateway probeService,
  required TranslationSettingsResult result,
  required TranslationRequestProfile expectedProfile,
}) =>
        (profile) {
          try {
            final snapshot = readSnapshot();
            final currentProfile = _profileForConfirmedResult(result, snapshot);
            const evaluator = TranslationModelEligibilityEvaluator();
            final eligibility = evaluator.evaluateProfile(
              settings: snapshot.settings,
              profile: currentProfile,
              environment: snapshot.eligibilityEnvironment,
            );
            if (!eligibility.canStart) return eligibility;
            if (!probeService.isIdentityCurrent(
              result.identity,
              accountHash: snapshot.accountHash,
              settings: snapshot.settings,
              profile: currentProfile,
            )) {
              return _configurationChangedResult;
            }
            final record = probeService.lookup(
              accountHash: snapshot.accountHash,
              settings: snapshot.settings,
              profile: currentProfile,
            );
            final evidenceSignature = buildTranslationSettingsEvidenceSignature(
              eligibility: eligibility,
              identity: result.identity,
              record: record,
            );
            if (!result.evidenceSignature.sameAs(evidenceSignature)) {
              return _configurationChangedResult;
            }
            final evidenced = probeService.applyCachedEvidence(
              accountHash: snapshot.accountHash,
              settings: snapshot.settings,
              profile: currentProfile,
            );
            if (!_sameProfile(evidenced, expectedProfile) ||
                !_sameProfile(profile, expectedProfile)) {
              return _configurationChangedResult;
            }
            return eligibility;
          } catch (_) {
            return _configurationChangedResult;
          }
        };

TranslationRequestProfile _profileForConfirmedResult(
    TranslationSettingsResult result, TranslationSettingsSnapshot snapshot) {
  final run = result.preparedSession;
  if (run != null) {
    run.verify();
    if (translationSelectionInputKey(snapshot.settings, run.sourcePreference) !=
        run.inputKey) {
      throw const TranslationModelUnavailableException('翻译配置已变化，请重新确认',
          safeCode: 'configurationChanged');
    }
    return run.profile;
  }
  final profile =
      TranslationModelResolver.snapshot(snapshot.settings, result.preference);
  if (profile.mode == TranslationExecutionMode.backend) {
    throw const TranslationModelUnavailableException('请重新确认后端服务商与模型',
        safeCode: 'configurationChanged');
  }
  return profile;
}

const _configurationChangedResult = TranslationEligibilityResult([
  TranslationEligibilityIssue(
    level: TranslationEligibilityLevel.blocked,
    code: TranslationEligibilityCode.configurationChanged,
    message: '翻译配置已变化，请重新确认',
    actionLabel: '返回翻译设置',
  ),
]);

Future<TranslationSettingsResult?> showTranslationSettingsDialog(
  BuildContext context, {
  required TranslationSettingsSnapshotReader readSnapshot,
  required TranslationModelPreference initialValue,
  required int estimatedRunes,
  required TranslationModelProbeGateway probeService,
  Future<void> Function(TranslationEligibilityIssue issue)? onFixIssue,
  String title = '翻译设置',
}) =>
    showDialog<TranslationSettingsResult>(
      context: context,
      builder: (_) => _TranslationSettingsDialog(
        readSnapshot: readSnapshot,
        initialValue: initialValue,
        estimatedRunes: estimatedRunes,
        probeService: probeService,
        onFixIssue: onFixIssue,
        title: title,
      ),
    );

class _TranslationSettingsDialog extends StatefulWidget {
  final TranslationSettingsSnapshotReader readSnapshot;
  final TranslationModelPreference initialValue;
  final int estimatedRunes;
  final TranslationModelProbeGateway probeService;
  final Future<void> Function(TranslationEligibilityIssue issue)? onFixIssue;
  final String title;

  const _TranslationSettingsDialog({
    required this.readSnapshot,
    required this.initialValue,
    required this.estimatedRunes,
    required this.probeService,
    required this.onFixIssue,
    required this.title,
  });

  @override
  State<_TranslationSettingsDialog> createState() =>
      _TranslationSettingsDialogState();
}

class _TranslationSettingsDialogState
    extends State<_TranslationSettingsDialog> {
  late TranslationModelPreference _selected;
  late bool _disableThinking;
  TranslationModelProbeHandle? _activeProbe;
  TranslationModelProbeRecord? _displayRecord;
  TranslationModelProbeIdentity? _displayRecordIdentity;
  String? _notice;
  late final TranslationSelectionScope _selectionScope;
  final _prepareCancellation = TranslationCancellationController();
  TranslationSelectionSession? _preparedSession;
  Future<TranslationSelectionSession>? _preparation;
  String? _preparationKey;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    final first = widget.readSnapshot();
    _selectionScope = TranslationSelectionScope(
        accountHash: first.accountHash,
        currentAccount: () => widget.readSnapshot().accountHash);
    final settings = first.settings;
    _selected =
        widget.initialValue.mode == TranslationModelPreferenceMode.backend ||
                _targetExists(settings, widget.initialValue)
            ? widget.initialValue
            : const TranslationModelPreference(
                mode: TranslationModelPreferenceMode.followGlobal,
                reasoningPolicy: ChatReasoningPolicy.offIfSupported,
              );
    // 每次任务默认优先快速翻译；模型选择会被记住，但是否关闭 Thinking
    // 由本次任务显式确认，不继承旧任务可能采用的 provider default。
    _disableThinking = true;
  }

  @override
  void dispose() {
    _activeProbe?.cancel();
    _activeProbe = null;
    _prepareCancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = _currentView();
    final settings = view.snapshot.settings;
    final decision = _reasoningDecision(settings, _selected);
    final usesBackend = _usesBackend(settings, _selected);
    final supportsThinkingControl = decision.supported;
    final effectiveSwitch = supportsThinkingControl && _disableThinking;
    final running = _activeProbe != null || _preparing;
    final issue = view.eligibility.primaryIssue;
    return AlertDialog(
      key: const ValueKey('translation_settings_dialog'),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.estimatedRunes <= 0
                  ? '预计字符数暂不可用'
                  : '预计翻译 ${_formatRunes(widget.estimatedRunes)} 字',
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('translation_model_button'),
              icon: const Icon(Icons.smart_toy_outlined),
              label: Text(_selectionLabel(settings, _selected,
                  backendPair: view.profile?.backendSelection)),
              onPressed: running ? null : _pickModel,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('translation_disable_thinking'),
              contentPadding: EdgeInsets.zero,
              title: const Text('关闭深度思考（推荐）'),
              subtitle: Text(
                usesBackend
                    ? '后端会在模型支持时关闭 Thinking。'
                    : supportsThinkingControl
                        ? '翻译任务会显式请求快速输出，减少首字等待。'
                        : '该接口不会发送 Thinking 参数',
              ),
              value: effectiveSwitch,
              onChanged: running || !supportsThinkingControl
                  ? null
                  : (value) => setState(() => _disableThinking = value),
            ),
            const SizedBox(height: 8),
            _status(view),
            if (_notice != null) ...[
              const SizedBox(height: 6),
              Text(
                _notice!,
                key: const ValueKey('translation_probe_notice'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (!view.eligibility.canStart &&
                issue != null &&
                issue.actionLabel != null &&
                issue.repairTarget != null &&
                widget.onFixIssue != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('translation_fix_issue'),
                onPressed: running ? null : () => _fixIssue(issue),
                icon: const Icon(Icons.settings_outlined),
                label: Text(issue.actionLabel!),
              ),
            ],
            const SizedBox(height: 8),
            if (running)
              OutlinedButton.icon(
                key: const ValueKey('translation_probe_cancel'),
                onPressed: _cancelProbe,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('取消测试'),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('translation_probe_button'),
                onPressed: view.eligibility.canStart && view.profile != null
                    ? _testModel
                    : null,
                icon: const Icon(Icons.network_check),
                label: Text(view.record == null ? '测试模型' : '重新测试'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('translation_settings_cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('translation_settings_confirm'),
          onPressed: !running && view.eligibility.canStart
              ? _confirmTranslation
              : null,
          child: const Text('开始翻译'),
        ),
      ],
    );
  }

  Widget _status(_SelectionView view) {
    final theme = Theme.of(context);
    final eligibility = view.eligibility;
    final record = view.record;
    late final String badge;
    late final Color color;
    final detail = <String>[];
    if (!eligibility.canStart) {
      badge = '配置不可用';
      color = theme.colorScheme.error;
      if (eligibility.primaryIssue != null) {
        detail.add(eligibility.primaryIssue!.message);
      }
    } else if (eligibility.level == TranslationEligibilityLevel.warning) {
      badge = eligibility.issues.any(
        (issue) => issue.code == TranslationEligibilityCode.mobileLoopback,
      )
          ? '地址警告'
          : '配置警告';
      color = theme.colorScheme.tertiary;
      detail.addAll(eligibility.issues.map((issue) => issue.message));
    } else if (record?.status == TranslationModelProbeStatus.failed) {
      badge = '测试失败';
      color = theme.colorScheme.error;
      detail.add(_safeProbeFailure(record!.safeErrorCode));
    } else if (record?.status == TranslationModelProbeStatus.verified) {
      badge = '已验证';
      color = theme.colorScheme.primary;
      detail.add(_probeTiming(record!));
    } else {
      badge = '未验证';
      color = theme.colorScheme.tertiary;
      detail.add('预检只会在你点击“测试模型”后发起。');
    }
    return Semantics(
      key: const ValueKey('translation_model_status'),
      label: badge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(badge,
              style: theme.textTheme.labelLarge?.copyWith(color: color)),
          for (final line in detail.where((item) => item.isNotEmpty))
            Text(line, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> _pickModel() async {
    final snapshot = widget.readSnapshot();
    final picked = await showConfiguredAiModelPickerSheet(
      context,
      settings: snapshot.settings,
      selected: _selected,
      eligibilityFor: (preference) => _viewFor(preference).eligibility,
      probeFor: (preference) => _viewFor(preference).record,
      includeUnavailable: true,
      backendIdentity: _selectionScope.identity,
    );
    if (!mounted || picked == null) return;
    if (!_selectionScope.accountCurrent ||
        (_usesBackend(snapshot.settings, picked) &&
            !_selectionScope.backendCurrent)) {
      setState(() => _notice = '账号、登录或后端来源已变化，请重新打开翻译设置');
      return;
    }
    setState(() {
      _preparedSession = null;
      _preparation = null;
      _preparationKey = null;
      _selected = picked;
      _disableThinking = true;
      _displayRecord = null;
      _displayRecordIdentity = null;
      _notice = null;
    });
  }

  Future<void> _testModel() async {
    if (!await _prepareCurrentBackend()) return;
    final before = _currentView();
    final beforeIdentity = before.identity;
    if (!before.eligibility.canStart ||
        before.profile == null ||
        beforeIdentity == null) {
      setState(() {});
      return;
    }
    final confirmed = await _showProbeNotice();
    if (!mounted || !confirmed) return;

    final current = _currentView();
    final profile = current.profile;
    if (!current.eligibility.canStart ||
        profile == null ||
        current.identity == null ||
        !widget.probeService.isIdentityCurrent(
          beforeIdentity,
          accountHash: current.snapshot.accountHash,
          settings: current.snapshot.settings,
          profile: profile,
        )) {
      setState(() {
        _displayRecord = null;
        _displayRecordIdentity = null;
        _notice = '翻译配置已变化，请重新确认';
      });
      return;
    }

    final identity = current.identity!;
    final handle = widget.probeService.start(
      accountHash: current.snapshot.accountHash,
      settings: current.snapshot.settings,
      profile: profile,
      isConfigurationCurrent: () {
        final latest = _currentView();
        final latestProfile = latest.profile;
        return latest.eligibility.canStart &&
            latestProfile != null &&
            widget.probeService.isIdentityCurrent(
              identity,
              accountHash: latest.snapshot.accountHash,
              settings: latest.snapshot.settings,
              profile: latestProfile,
            );
      },
    );
    setState(() {
      _activeProbe = handle;
      _notice = '正在测试模型连接…';
    });
    try {
      final result = await handle.result;
      if (!mounted || !identical(_activeProbe, handle)) return;
      final latest = _currentView();
      final latestProfile = latest.profile;
      if (latestProfile == null ||
          !latest.eligibility.canStart ||
          !widget.probeService.isIdentityCurrent(
            identity,
            accountHash: latest.snapshot.accountHash,
            settings: latest.snapshot.settings,
            profile: latestProfile,
          )) {
        setState(() {
          _displayRecord = null;
          _displayRecordIdentity = null;
          _notice = '翻译配置已变化，请重新确认';
        });
        return;
      }
      setState(() {
        _displayRecord = result.record;
        _displayRecordIdentity = identity;
        _notice = result.record.status == TranslationModelProbeStatus.verified
            ? '模型测试完成。'
            : _safeProbeFailure(result.record.safeErrorCode);
      });
    } catch (_) {
      if (mounted && identical(_activeProbe, handle)) {
        setState(() => _notice = '模型测试已取消。');
      }
    } finally {
      if (mounted && identical(_activeProbe, handle)) {
        setState(() => _activeProbe = null);
      }
    }
  }

  void _cancelProbe() {
    final handle = _activeProbe;
    if (handle == null) return;
    _activeProbe = null;
    handle.cancel();
    setState(() => _notice = '模型测试已取消。');
  }

  Future<void> _confirmTranslation() async {
    var forceConfigurationConfirmation = false;
    while (mounted) {
      if (!await _prepareCurrentBackend()) return;
      final before = _currentView();
      final profile = before.profile;
      final identity = before.identity;
      final evidenceSignature = before.evidenceSignature;
      if (!before.eligibility.canStart ||
          profile == null ||
          identity == null ||
          evidenceSignature == null) {
        setState(() {});
        return;
      }
      final reasons = _warningReasons(before);
      if (forceConfigurationConfirmation) {
        reasons.insert(0, '翻译配置已变化，请重新确认');
      }
      // 唯一解析只确认可用性；旧选择仍须由用户看见并明确确认服务商与模型。
      final resolvedBackendPair = _resolvedLegacyPairForConfirmation();
      final acknowledged = reasons.isNotEmpty || resolvedBackendPair != null;
      if (acknowledged) {
        final confirmed = await _showTranslationWarning(reasons,
            resolvedBackendPair: resolvedBackendPair);
        if (!mounted || !confirmed) return;
      }

      final refreshed = _currentView();
      final refreshedProfile = refreshed.profile;
      if (!refreshed.eligibility.canStart ||
          refreshedProfile == null ||
          refreshed.identity == null ||
          refreshed.evidenceSignature == null) {
        setState(() => _notice = '翻译配置已变化，请重新确认');
        return;
      }
      if (!widget.probeService.isIdentityCurrent(
        identity,
        accountHash: refreshed.snapshot.accountHash,
        settings: refreshed.snapshot.settings,
        profile: refreshedProfile,
      )) {
        forceConfigurationConfirmation = true;
        setState(() => _notice = '翻译配置已变化，请重新确认');
        continue;
      }
      if (!evidenceSignature.sameAs(refreshed.evidenceSignature!)) {
        forceConfigurationConfirmation = true;
        setState(() => _notice = '翻译配置已变化，请重新确认');
        continue;
      }
      var evidenced = widget.probeService.applyCachedEvidence(
        accountHash: refreshed.snapshot.accountHash,
        settings: refreshed.snapshot.settings,
        profile: refreshedProfile,
      );
      if (_preparedSession != null) {
        try {
          _preparedSession = await _preparedSession!
              .withEvidence(evidenced, _prepareCancellation);
          _preparedSession!.verify();
          evidenced = _preparedSession!.profile;
          final latest = _currentView();
          if (latest.evidenceSignature == null ||
              !evidenceSignature.sameAs(latest.evidenceSignature!) ||
              translationSelectionInputKey(
                      latest.snapshot.settings, latest.preference) !=
                  _preparedSession!.inputKey) {
            setState(() => _notice = '翻译配置已变化，请重新确认');
            continue;
          }
        } catch (_) {
          if (mounted) setState(() => _notice = '翻译配置已变化，请重新确认');
          return;
        }
      }
      if (!mounted || !_selectionScope.accountCurrent) return;
      var declared = _preferenceWithReasoning(refreshed.snapshot.settings);
      if (declared.mode == TranslationModelPreferenceMode.backend &&
          _preparedSession != null) {
        declared = TranslationModelPreference(
            mode: declared.mode,
            modelId: evidenced.modelId,
            reasoningPolicy: declared.reasoningPolicy,
            backendSelection: evidenced.backendSelection);
      }
      Navigator.pop(
        context,
        TranslationSettingsResult(
          preference: declared,
          preparedSession: _preparedSession,
          profile: evidenced,
          identity: refreshed.identity!,
          evidenceSignature: refreshed.evidenceSignature!,
          warningsAcknowledged: acknowledged,
        ),
      );
      return;
    }
  }

  Future<bool> _showProbeNotice() async =>
      await showDialog<bool>(
        context: context,
        builder: (noticeContext) => AlertDialog(
          title: const Text('测试模型'),
          content: const Text(
            '将发送一次不含用户数据的小请求，用于验证翻译兼容性，可能产生少量 Token。',
          ),
          actions: [
            TextButton(
              key: const ValueKey('translation_probe_notice_cancel'),
              onPressed: () => Navigator.pop(noticeContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('translation_probe_notice_confirm'),
              onPressed: () => Navigator.pop(noticeContext, true),
              child: const Text('确认测试'),
            ),
          ],
        ),
      ) ??
      false;

  BackendSelection? _resolvedLegacyPairForConfirmation() {
    final prepared = _preparedSession;
    if (prepared == null) return null;
    final source = prepared.sourcePreference;
    final legacy = (source.mode == TranslationModelPreferenceMode.backend &&
            source.backendSelection == null) ||
        (source.mode == TranslationModelPreferenceMode.followGlobal &&
            prepared.settings.backendSelection == null);
    return legacy ? prepared.profile.backendSelection : null;
  }

  Future<bool> _showTranslationWarning(List<String> reasons,
          {BackendSelection? resolvedBackendPair}) async =>
      await showDialog<bool>(
        context: context,
        builder: (warningContext) => AlertDialog(
          title: Text(resolvedBackendPair == null ? '继续翻译？' : '确认后端翻译模型'),
          content: Text([
            if (resolvedBackendPair != null)
              '本次翻译将使用：${backendSelectionLabel(resolvedBackendPair)}',
            ...reasons,
          ].join('\n')),
          actions: [
            TextButton(
              key: const ValueKey('translation_warning_back'),
              onPressed: () => Navigator.pop(warningContext, false),
              child: const Text('返回检查'),
            ),
            FilledButton(
              key: const ValueKey('translation_warning_continue'),
              onPressed: () => Navigator.pop(warningContext, true),
              child: const Text('继续翻译'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _fixIssue(TranslationEligibilityIssue issue) async {
    await widget.onFixIssue?.call(issue);
    if (!mounted) return;
    final repaired = widget.readSnapshot();
    setState(() {
      // 用户明确点击“改用本地直连”的修复动作后才切换，读取/失败不会自动回退。
      if (_selectionScope.accountCurrent &&
          issue.repairTarget ==
              TranslationEligibilityRepairTarget.requestModeSettings &&
          _selected.mode == TranslationModelPreferenceMode.backend &&
          repaired.settings.mode == AIMode.local) {
        _selected = TranslationModelPreference(
            mode: TranslationModelPreferenceMode.followGlobal,
            reasoningPolicy: _selected.reasoningPolicy);
        _preparedSession = null;
        _preparation = null;
        _preparationKey = null;
      }
      _displayRecord = null;
      _displayRecordIdentity = null;
      _notice = null;
    });
  }

  _SelectionView _currentView() {
    final snapshot = widget.readSnapshot();
    return _viewFor(
      _preferenceWithReasoning(snapshot.settings),
      snapshot: snapshot,
    );
  }

  _SelectionView _viewFor(
    TranslationModelPreference preference, {
    TranslationSettingsSnapshot? snapshot,
  }) {
    final currentSnapshot = snapshot ?? widget.readSnapshot();
    var normalizedPreference = preference;
    var eligibility = const TranslationEligibilityResult();
    TranslationRequestProfile? profile;
    TranslationModelProbeIdentity? identity;
    TranslationModelProbeRecord? record;
    try {
      normalizedPreference = normalizeTranslationModelPreference(
          currentSnapshot.settings, preference);
      const evaluator = TranslationModelEligibilityEvaluator();
      eligibility = evaluator.evaluatePreference(
          settings: currentSnapshot.settings,
          preference: normalizedPreference,
          environment: currentSnapshot.eligibilityEnvironment);
      if (!eligibility.canStart) {
        return _SelectionView(
            snapshot: currentSnapshot,
            preference: normalizedPreference,
            profile: null,
            identity: null,
            eligibility: eligibility,
            record: null);
      }
      final backend =
          _usesBackend(currentSnapshot.settings, normalizedPreference);
      if (!_selectionScope.accountCurrent ||
          backend && !_selectionScope.backendCurrent) {
        throw const TranslationModelUnavailableException(
            '账号、登录或后端来源已变化，请重新打开翻译设置',
            safeCode: 'backend_scope_changed');
      }
      final prepared = _preparedSession;
      profile = prepared != null &&
              prepared.isCurrent &&
              prepared.inputKey ==
                  translationSelectionInputKey(
                      currentSnapshot.settings, normalizedPreference)
          ? prepared.profile
          : TranslationModelResolver.snapshot(
              currentSnapshot.settings, normalizedPreference);
      eligibility = evaluator.evaluateProfile(
          settings: currentSnapshot.settings,
          profile: profile,
          environment: currentSnapshot.eligibilityEnvironment);
      identity = widget.probeService.identify(
          accountHash: currentSnapshot.accountHash,
          settings: currentSnapshot.settings,
          profile: profile);
      record = widget.probeService.lookup(
          accountHash: currentSnapshot.accountHash,
          settings: currentSnapshot.settings,
          profile: profile);
      final displayIdentity = _displayRecordIdentity;
      if (record == null &&
          displayIdentity != null &&
          widget.probeService.isIdentityCurrent(displayIdentity,
              accountHash: currentSnapshot.accountHash,
              settings: currentSnapshot.settings,
              profile: profile)) {
        record = _displayRecord;
      }
    } catch (_) {
      profile = null;
      identity = null;
      record = null;
      eligibility = const TranslationEligibilityResult([
        TranslationEligibilityIssue(
          level: TranslationEligibilityLevel.blocked,
          code: TranslationEligibilityCode.configurationChanged,
          message: '原翻译选择不可用于当前账号或地址，请重新选择',
          actionLabel: '重新选择模型',
        )
      ]);
    }
    return _SelectionView(
      snapshot: currentSnapshot,
      preference: normalizedPreference,
      profile: profile,
      identity: identity,
      eligibility: eligibility,
      record: record,
    );
  }

  Future<bool> _prepareCurrentBackend() async {
    final before = _currentView();
    final profile = before.profile;
    if (profile == null || !before.eligibility.canStart) return false;
    if (profile.mode != TranslationExecutionMode.backend) {
      return _selectionScope.accountCurrent;
    }
    final key = translationSelectionInputKey(
        before.snapshot.settings, before.preference);
    if (_preparedSession?.inputKey == key && _preparedSession!.isCurrent) {
      return true;
    }
    try {
      setState(() => _preparing = true);
      if (_preparationKey != key) {
        _preparationKey = key;
        _preparation = TranslationSelectionSession.prepare(
            scope: _selectionScope,
            settings: before.snapshot.settings,
            preference: before.preference,
            profile: profile,
            cancellation: _prepareCancellation);
      }
      final prepared = await _preparation!;
      if (!mounted) return false;
      prepared.verify();
      final current = _currentView();
      if (translationSelectionInputKey(
              current.snapshot.settings, current.preference) !=
          key) {
        throw const TranslationModelUnavailableException('翻译配置已变化，请重新确认',
            safeCode: 'configurationChanged');
      }
      setState(() => _preparedSession = prepared);
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _notice = error is TranslationRequestFailure
            ? backendSelectionMessages[error.safeCode] ?? '后端模型确认失败，请重新选择'
            : '翻译配置已变化，请重新选择或重新打开设置');
      }
      return false;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  TranslationModelPreference _preferenceWithReasoning(AISettings settings) {
    if (_selected.isUnavailable) return _selected;
    final decision = _reasoningDecision(settings, _selected);
    return normalizeTranslationModelPreference(
      settings,
      _copyWithReasoning(
        _selected,
        decision.supported && _disableThinking
            ? ChatReasoningPolicy.offIfSupported
            : ChatReasoningPolicy.providerDefault,
      ),
    );
  }

  static List<String> _warningReasons(_SelectionView view) {
    final reasons = <String>[
      ...view.eligibility.issues
          .where((issue) => issue.level == TranslationEligibilityLevel.warning)
          .map((issue) => issue.message),
    ];
    final record = view.record;
    if (record == null) {
      reasons.add('该模型尚未完成预检。');
    } else if (record.status == TranslationModelProbeStatus.failed) {
      reasons.add(_safeProbeFailure(record.safeErrorCode));
    }
    return reasons;
  }

  static TranslationModelPreference _copyWithReasoning(
    TranslationModelPreference value,
    ChatReasoningPolicy reasoningPolicy,
  ) =>
      TranslationModelPreference(
        mode: value.mode,
        providerId: value.providerId,
        modelId: value.modelId,
        backendSelection: value.backendSelection,
        reasoningPolicy: reasoningPolicy,
      );

  static bool _targetExists(
    AISettings settings,
    TranslationModelPreference value,
  ) {
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        return true;
      case TranslationModelPreferenceMode.backend:
        return value.modelId != null &&
            value.modelId == settings.backendModel.trim() &&
            value.modelId!.isNotEmpty;
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return provider != null &&
            provider.models.any((model) => model.id == value.modelId);
    }
  }

  static ReasoningControlDecision _reasoningDecision(
    AISettings settings,
    TranslationModelPreference value,
  ) {
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        if (settings.mode == AIMode.backend) return _backendReasoningDecision;
        final provider = settings.activeProvider;
        return ReasoningControlAdapter.resolve(
          providerId: provider.id,
          providerCode: provider.providerCode,
          modelId: provider.effectiveModelId,
          policy: ChatReasoningPolicy.offIfSupported,
        );
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return ReasoningControlAdapter.resolve(
          providerId: provider?.id,
          providerCode: provider?.providerCode,
          modelId: value.modelId ?? '',
          policy: ChatReasoningPolicy.offIfSupported,
        );
      case TranslationModelPreferenceMode.backend:
        return _backendReasoningDecision;
    }
  }

  static const _backendReasoningDecision = ReasoningControlDecision(
    supported: true,
    requestFields: {},
    explanation: 'backend_semantic_policy',
  );

  static bool _usesBackend(
    AISettings settings,
    TranslationModelPreference value,
  ) =>
      value.mode == TranslationModelPreferenceMode.backend ||
      (value.mode == TranslationModelPreferenceMode.followGlobal &&
          settings.mode == AIMode.backend);

  static AiProvider? _provider(AISettings settings, String? providerId) {
    for (final provider in settings.providers) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  static String _selectionLabel(
      AISettings settings, TranslationModelPreference value,
      {BackendSelection? backendPair}) {
    if (value.isUnavailable) return '原翻译模型偏好无法识别，请重新选择';
    switch (value.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        if (settings.mode == AIMode.backend) {
          return '跟随全局：${backendSelectionLabel(settings.backendSelection ?? backendPair, legacyModelId: settings.backendModel)}';
        }
        return '跟随全局：${settings.effectiveModel}';
      case TranslationModelPreferenceMode.backend:
        return '后端代理：${backendSelectionLabel(value.backendSelection ?? backendPair, legacyModelId: value.modelId)}';
      case TranslationModelPreferenceMode.local:
        final provider = _provider(settings, value.providerId);
        return '${provider?.name ?? value.providerId} / ${value.modelId}';
    }
  }

  static String _formatRunes(int value) {
    final digits = value < 0 ? 0 : value;
    final text = '$digits';
    final buffer = StringBuffer();
    for (var index = 0; index < text.length; index += 1) {
      if (index > 0 && (text.length - index) % 3 == 0) buffer.write(',');
      buffer.write(text[index]);
    }
    return buffer.toString();
  }
}

final class _SelectionView {
  final TranslationSettingsSnapshot snapshot;
  final TranslationModelPreference preference;
  final TranslationRequestProfile? profile;
  final TranslationModelProbeIdentity? identity;
  final TranslationEligibilityResult eligibility;
  final TranslationModelProbeRecord? record;

  const _SelectionView({
    required this.snapshot,
    required this.preference,
    required this.profile,
    required this.identity,
    required this.eligibility,
    required this.record,
  });

  TranslationSettingsEvidenceSignature? get evidenceSignature {
    final currentIdentity = identity;
    if (currentIdentity == null) return null;
    return buildTranslationSettingsEvidenceSignature(
      eligibility: eligibility,
      identity: currentIdentity,
      record: record,
    );
  }
}

bool _requiresWarning(
  TranslationEligibilityResult eligibility,
  TranslationModelProbeRecord? record,
) =>
    eligibility.level == TranslationEligibilityLevel.warning ||
    record == null ||
    record.status == TranslationModelProbeStatus.failed;

bool _sameProfile(
  TranslationRequestProfile first,
  TranslationRequestProfile second,
) =>
    first.mode == second.mode &&
    first.providerId == second.providerId &&
    first.modelId == second.modelId &&
    first.reasoningPolicy == second.reasoningPolicy &&
    first.reasoningControlSuppressed == second.reasoningControlSuppressed;

bool _sameStrings(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

String _probeTiming(TranslationModelProbeRecord record) {
  final checked = record.checkedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final parts = <String>[
    '检查于 ${checked.year}-${two(checked.month)}-${two(checked.day)} '
        '${two(checked.hour)}:${two(checked.minute)}',
    if (record.firstEventMs != null) '首字 ${record.firstEventMs} ms',
    if (record.totalMs != null) '总计 ${record.totalMs} ms',
  ];
  return parts.join(' · ');
}

String _safeProbeFailure(String? code) => switch (code) {
      'auth_failed' => '认证失败，请检查 API Key。',
      'unsupported_api' => '接口不兼容，请检查模型或服务地址。',
      'rate_limited' => '请求过于频繁，请稍后重试。',
      'first_event_timeout' || 'idle_timeout' => '模型响应超时，请稍后重试。',
      'network_unreachable' => '网络连接失败，请检查服务地址。',
      'invalid_output' => '模型返回格式不符合翻译要求。',
      _ => '模型测试失败，请稍后重试。',
    };
