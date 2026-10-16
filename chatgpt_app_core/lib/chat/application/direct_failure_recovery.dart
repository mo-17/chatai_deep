import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 弹窗只决定一次新请求，不探测候选、不写全局或旧任务。
class DirectFailureRecovery {
  final AISettings original;
  final ConversationGenerationScope scope;
  final AISettings Function() currentSettings;
  final bool Function() sourceCurrent;
  final ModelCapabilities requiredInput;
  final bool mayHaveBeenProcessed;
  final String safeReason;
  final bool allowOriginalRetry;
  late final String _configuration;
  bool _settled = false;
  bool Function()? windowCurrent;

  DirectFailureRecovery(
      {required AISettings original,
      required this.scope,
      required this.currentSettings,
      required this.sourceCurrent,
      required this.requiredInput,
      required this.mayHaveBeenProcessed,
      required String failureCode,
      this.allowOriginalRetry = true})
      : original = original.clone(),
        safeReason = _reason(failureCode) {
    // 固定打开时配置，而不是在第一次点击时接受新的配置。
    _configuration = _signature(currentSettings());
  }

  String get originalLabel =>
      '${original.activeProvider.name}（${original.activeProviderId}） · ${original.effectiveModel}';
  bool get current =>
      scope.isCurrent &&
      sourceCurrent() &&
      (windowCurrent?.call() ?? true) &&
      _signature(currentSettings()) == _configuration;
  static String _signature(AISettings s) => jsonEncode(s.toJson());
  static String key(String provider, String model) =>
      jsonEncode([provider, model]);

  List<DirectRecoveryChoice> get choices {
    if (!current) return const [];
    final result = <DirectRecoveryChoice>[];
    final seen = <String>{};
    final s = currentSettings();
    for (final p in s.providers) {
      if (!p.enabled || p.apiKey.trim().isEmpty) continue;
      for (final m in p.models) {
        if (m.id.trim().isEmpty) continue;
        final selected = original.clone()
          ..mode = AIMode.local
          ..providers = s.providers.map((p) => p.copy()).toList()
          ..activeProviderId = p.id;
        selected.providers.singleWhere((x) => x.id == p.id).selectedModelId =
            m.id;
        var caps = ChatService.capabilitiesFor(selected);
        final endpoint = Uri.tryParse(selected.activeLocal.baseUrl);
        if (endpoint == null ||
            !{'http', 'https'}.contains(endpoint.scheme) ||
            endpoint.host.isEmpty) {
          continue;
        }
        if (endpoint.scheme == 'https' &&
            endpoint.host == 'api.deepseek.com' &&
            caps.image) {
          caps = caps.copyWith(pdf: true);
        }
        if (!_supports(caps) || !selected.localSelectionValid) continue;
        final id = key(p.id, m.id);
        if (seen.add(id)) {
          result.add(DirectRecoveryChoice(id, '${p.name} · ${m.id}', selected));
        }
      }
    }
    return List.unmodifiable(result);
  }

  bool _supports(ModelCapabilities c) =>
      (!requiredInput.image || c.image) &&
      (!requiredInput.pdf || c.pdf) &&
      (!requiredInput.tool || c.tool);
  DirectRecoveryChoice? get originalChoice {
    if (!allowOriginalRetry) return null;
    for (final c in choices) {
      if (c.settings.activeProviderId == original.activeProvider.id &&
          c.settings.effectiveModel == original.effectiveModel &&
          c.settings.activeLocal.apiKey == original.activeLocal.apiKey &&
          c.settings.activeLocal.baseUrl == original.activeLocal.baseUrl) {
        return c;
      }
    }
    return null;
  }

  DirectRetryPermit? confirm(String id) {
    if (_settled || !current) return null;
    final available = choices.where((c) => c.id == id).toList();
    if (available.length != 1) return null;
    _settled = true;
    return DirectRetryPermit._(available.single.settings, scope, () => current);
  }

  void cancel() => _settled = true;
  static String _reason(String code) => switch (code) {
        'api_key_missing' || 'authentication_error' => '原配置的鉴权失败，请检查配置',
        'direct_configuration_unavailable' ||
        'conversation_configuration_revoked_unsent' =>
          '原服务商或模型已失效',
        'timeout' ||
        'connect_timeout' ||
        'firstEventTimeout' ||
        'idleTimeout' ||
        'totalTimeout' =>
          '请求等待超时',
        'network_error' => '网络请求未正常完成',
        'rate_limited' => '请求受到限流',
        'unsupported_reasoning_control' => '原配置不支持本次推理参数',
        _ => '请求未正常完成，请核对原配置后选择操作',
      };
}

class DirectRecoveryChoice {
  final String id, label;
  final AISettings _settings;
  AISettings get settings => _settings.clone();
  DirectRecoveryChoice(this.id, this.label, AISettings settings)
      : _settings = settings.clone();
}

/// 一次确认只能被一个新运行领取；最后准备/上传/POST前仍复验原声明。
class DirectRetryPermit {
  final AISettings _settings;
  final bool Function() _current;
  final ConversationGenerationScope _scope;
  bool _claimed = false;
  DirectRetryPermit._(AISettings s, this._scope, this._current)
      : _settings = s.clone();
  bool get current => _current();
  AISettings? claim() {
    if (_claimed || !current) return null;
    _claimed = true;
    return _settings.clone();
  }

  Future<T> stable<T>(Future<T> Function() action) => _scope.stable(() async {
        verify();
        final result = await action();
        verify();
        return result;
      });

  void verify() {
    if (!_claimed || !current) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '原请求或弹窗环境已变化，本次请求未发送',
          failureKind: ChatFailureKind.cancelled);
    }
  }
}
