import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';

enum TranslationEligibilityLevel { allowed, warning, blocked }

enum TranslationEligibilityCode {
  providerMissing,
  providerDisabled,
  modelMissing,
  apiKeyMissing,
  invalidEndpoint,
  guestBackend,
  mobileLoopback,
  androidStoreCleartext,
  configurationChanged,
}

enum TranslationEligibilityRepairTarget {
  login,
  providerSettings,
  requestModeSettings,
}

final class TranslationEligibilityEnvironment {
  final bool isGuest;
  final TargetPlatform platform;
  final AppDistribution distribution;
  final String backendHost;
  final bool backendUseHttps;

  const TranslationEligibilityEnvironment({
    required this.isGuest,
    required this.platform,
    required this.distribution,
    required this.backendHost,
    required this.backendUseHttps,
  });

  factory TranslationEligibilityEnvironment.current() =>
      TranslationEligibilityEnvironment(
        isGuest: LoginDao.isGuest(),
        platform: defaultTargetPlatform,
        distribution: DistributionConfig.current,
        backendHost: BackendConfig.host,
        backendUseHttps: BackendConfig.useHttps,
      );
}

final class TranslationEligibilityIssue {
  final TranslationEligibilityLevel level;
  final TranslationEligibilityCode code;
  final String message;
  final String? actionLabel;
  final TranslationEligibilityRepairTarget? repairTarget;

  const TranslationEligibilityIssue({
    required this.level,
    required this.code,
    required this.message,
    this.actionLabel,
    this.repairTarget,
  });
}

Future<void> runTranslationEligibilityIssueRepair({
  required TranslationEligibilityIssue issue,
  required Future<void> Function() goToLogin,
  required Future<void> Function() openProviderSettings,
  required Future<void> Function() openRequestModeSettings,
}) async {
  switch (issue.repairTarget) {
    case TranslationEligibilityRepairTarget.login:
      await goToLogin();
      return;
    case TranslationEligibilityRepairTarget.providerSettings:
      await openProviderSettings();
      return;
    case TranslationEligibilityRepairTarget.requestModeSettings:
      await openRequestModeSettings();
      return;
    case null:
      return;
  }
}

final class TranslationEligibilityResult {
  final List<TranslationEligibilityIssue> issues;

  const TranslationEligibilityResult([this.issues = const []]);

  TranslationEligibilityLevel get level => _highest(issues);

  bool get canStart => level != TranslationEligibilityLevel.blocked;

  TranslationEligibilityIssue? get primaryIssue {
    final highest = level;
    for (final issue in issues) {
      if (issue.level == highest) return issue;
    }
    return null;
  }
}

TranslationEligibilityLevel _highest(
  Iterable<TranslationEligibilityIssue> issues,
) {
  if (issues
      .any((issue) => issue.level == TranslationEligibilityLevel.blocked)) {
    return TranslationEligibilityLevel.blocked;
  }
  if (issues
      .any((issue) => issue.level == TranslationEligibilityLevel.warning)) {
    return TranslationEligibilityLevel.warning;
  }
  return TranslationEligibilityLevel.allowed;
}

final class TranslationModelEligibilityEvaluator {
  const TranslationModelEligibilityEvaluator();

  TranslationEligibilityResult evaluatePreference({
    required AISettings settings,
    required TranslationModelPreference preference,
    required TranslationEligibilityEnvironment environment,
  }) {
    try {
      final profile = TranslationModelResolver.snapshot(settings, preference);
      return evaluateProfile(
        settings: settings,
        profile: profile,
        environment: environment,
      );
    } on TranslationModelUnavailableException catch (error) {
      return TranslationEligibilityResult([
        _unavailableIssue(error, _preferenceMode(settings, preference)),
      ]);
    } on FormatException {
      return TranslationEligibilityResult([
        _configurationChangedIssue(_preferenceMode(settings, preference)),
      ]);
    }
  }

  TranslationEligibilityResult evaluateProfile({
    required AISettings settings,
    required TranslationRequestProfile profile,
    required TranslationEligibilityEnvironment environment,
  }) {
    final issues = <TranslationEligibilityIssue>[
      ..._environmentIssues(profile, environment),
    ];

    try {
      final applied = TranslationModelResolver.apply(settings, profile);
      if (profile.mode == TranslationExecutionMode.local) {
        issues.addAll(_localEndpointIssues(
          applied.activeLocal.baseUrl,
          environment,
        ));
      }
    } on TranslationModelUnavailableException catch (error) {
      issues.add(_unavailableIssue(error, profile.mode));
      if (profile.mode == TranslationExecutionMode.local) {
        final provider = _providerFor(settings, profile.providerId);
        if (provider != null) {
          issues.addAll(_localEndpointIssues(
            AiProvider.buildChatCompletionsUrl(provider.apiHost),
            environment,
          ));
        }
      }
    }

    return TranslationEligibilityResult(issues);
  }

  List<TranslationEligibilityIssue> _environmentIssues(
    TranslationRequestProfile profile,
    TranslationEligibilityEnvironment environment,
  ) {
    if (profile.mode != TranslationExecutionMode.backend) return const [];

    final issues = <TranslationEligibilityIssue>[];
    final backendUri = Uri.tryParse(
      '${environment.backendUseHttps ? 'https' : 'http'}://${environment.backendHost.trim()}',
    );
    if (!_isValidEndpoint(backendUri) ||
        backendUri!.path.isNotEmpty ||
        backendUri.query.isNotEmpty ||
        backendUri.fragment.isNotEmpty) {
      issues.add(_blockedIssue(
        code: TranslationEligibilityCode.invalidEndpoint,
        message: '翻译后端地址无效。',
        mode: TranslationExecutionMode.backend,
      ));
    }
    if (environment.isGuest) {
      issues.add(_blockedIssue(
        code: TranslationEligibilityCode.guestBackend,
        message: '游客模式不能使用后端翻译。',
        mode: TranslationExecutionMode.backend,
      ));
    }
    if (environment.platform == TargetPlatform.android &&
        environment.distribution == AppDistribution.store &&
        !environment.backendUseHttps) {
      issues.add(_blockedIssue(
        code: TranslationEligibilityCode.androidStoreCleartext,
        message: 'Android 商店版不能通过 HTTP 使用后端翻译。',
        mode: TranslationExecutionMode.backend,
      ));
    }
    return issues;
  }

  List<TranslationEligibilityIssue> _localEndpointIssues(
    String endpoint,
    TranslationEligibilityEnvironment environment,
  ) {
    final uri = Uri.tryParse(endpoint.trim());
    if (!_isValidEndpoint(uri)) {
      return [
        _blockedIssue(
          code: TranslationEligibilityCode.invalidEndpoint,
          message: '翻译服务地址无效。',
          mode: TranslationExecutionMode.local,
        ),
      ];
    }
    final endpointUri = uri!;

    final issues = <TranslationEligibilityIssue>[];
    if (environment.platform == TargetPlatform.android &&
        environment.distribution == AppDistribution.store &&
        endpointUri.scheme == 'http') {
      issues.add(_blockedIssue(
        code: TranslationEligibilityCode.androidStoreCleartext,
        message: 'Android 商店版不能通过 HTTP 访问翻译服务。',
        mode: TranslationExecutionMode.local,
      ));
    }
    if (_isMobile(environment.platform) && _isLoopback(endpointUri.host)) {
      issues.add(const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.warning,
        code: TranslationEligibilityCode.mobileLoopback,
        message: '移动设备上的本机地址通常无法访问翻译服务。',
      ));
    }
    return issues;
  }

  TranslationEligibilityIssue _unavailableIssue(
    TranslationModelUnavailableException error,
    TranslationExecutionMode mode,
  ) {
    final code = switch (error.safeCode) {
      'providerMissing' => TranslationEligibilityCode.providerMissing,
      'providerDisabled' => TranslationEligibilityCode.providerDisabled,
      'modelMissing' => TranslationEligibilityCode.modelMissing,
      'apiKeyMissing' => TranslationEligibilityCode.apiKeyMissing,
      _ => TranslationEligibilityCode.configurationChanged,
    };
    return _blockedIssue(
      code: code,
      message: error.message,
      mode: mode,
    );
  }

  TranslationEligibilityIssue _configurationChangedIssue(
    TranslationExecutionMode mode,
  ) =>
      _blockedIssue(
        code: TranslationEligibilityCode.configurationChanged,
        message: '翻译模型配置已变化，请重新选择。',
        mode: mode,
      );

  TranslationExecutionMode _preferenceMode(
    AISettings settings,
    TranslationModelPreference preference,
  ) =>
      switch (preference.mode) {
        TranslationModelPreferenceMode.backend =>
          TranslationExecutionMode.backend,
        TranslationModelPreferenceMode.local => TranslationExecutionMode.local,
        TranslationModelPreferenceMode.followGlobal =>
          settings.mode == AIMode.backend
              ? TranslationExecutionMode.backend
              : TranslationExecutionMode.local,
      };

  TranslationEligibilityIssue _blockedIssue({
    required TranslationEligibilityCode code,
    required String message,
    required TranslationExecutionMode mode,
  }) {
    final repair = _repairFor(code, mode);
    return TranslationEligibilityIssue(
      level: TranslationEligibilityLevel.blocked,
      code: code,
      message: message,
      actionLabel: repair.label,
      repairTarget: repair.target,
    );
  }

  ({String label, TranslationEligibilityRepairTarget target}) _repairFor(
    TranslationEligibilityCode code,
    TranslationExecutionMode mode,
  ) {
    if (code == TranslationEligibilityCode.guestBackend) {
      return (
        label: '去登录',
        target: TranslationEligibilityRepairTarget.login,
      );
    }
    if (mode == TranslationExecutionMode.local) {
      return (
        label: '配置服务商',
        target: TranslationEligibilityRepairTarget.providerSettings,
      );
    }
    return (
      label: code == TranslationEligibilityCode.modelMissing
          ? '配置后端模型'
          : code == TranslationEligibilityCode.configurationChanged
              ? '检查请求方式'
              : '改用本地直连',
      target: TranslationEligibilityRepairTarget.requestModeSettings,
    );
  }

  AiProvider? _providerFor(AISettings settings, String? providerId) {
    for (final provider in settings.providers) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  bool _isMobile(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  bool _isLoopback(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  bool _isValidEndpoint(Uri? uri) =>
      uri != null &&
      uri.hasScheme &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.scheme == 'http' || uri.scheme == 'https');
}
