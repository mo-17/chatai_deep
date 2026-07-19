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

  const TranslationEligibilityIssue({
    required this.level,
    required this.code,
    required this.message,
    this.actionLabel,
  });
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
      return TranslationEligibilityResult([_unavailableIssue(error)]);
    } on FormatException {
      return TranslationEligibilityResult([_configurationChangedIssue()]);
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
      issues.add(_unavailableIssue(error));
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
      issues.add(const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.invalidEndpoint,
        message: '翻译后端地址无效。',
      ));
    }
    if (environment.isGuest) {
      issues.add(const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.guestBackend,
        message: '游客模式不能使用后端翻译。',
      ));
    }
    if (environment.platform == TargetPlatform.android &&
        environment.distribution == AppDistribution.store &&
        !environment.backendUseHttps) {
      issues.add(const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.androidStoreCleartext,
        message: 'Android 商店版不能通过 HTTP 使用后端翻译。',
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
      return const [
        TranslationEligibilityIssue(
          level: TranslationEligibilityLevel.blocked,
          code: TranslationEligibilityCode.invalidEndpoint,
          message: '翻译服务地址无效。',
        ),
      ];
    }
    final endpointUri = uri!;

    final issues = <TranslationEligibilityIssue>[];
    if (environment.platform == TargetPlatform.android &&
        environment.distribution == AppDistribution.store &&
        endpointUri.scheme == 'http') {
      issues.add(const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.androidStoreCleartext,
        message: 'Android 商店版不能通过 HTTP 访问翻译服务。',
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
  ) {
    final code = switch (error.safeCode) {
      'providerMissing' => TranslationEligibilityCode.providerMissing,
      'providerDisabled' => TranslationEligibilityCode.providerDisabled,
      'modelMissing' => TranslationEligibilityCode.modelMissing,
      'apiKeyMissing' => TranslationEligibilityCode.apiKeyMissing,
      _ => TranslationEligibilityCode.configurationChanged,
    };
    return TranslationEligibilityIssue(
      level: TranslationEligibilityLevel.blocked,
      code: code,
      message: error.message,
    );
  }

  TranslationEligibilityIssue _configurationChangedIssue() =>
      const TranslationEligibilityIssue(
        level: TranslationEligibilityLevel.blocked,
        code: TranslationEligibilityCode.configurationChanged,
        message: '翻译模型配置已变化，请重新选择。',
      );

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
