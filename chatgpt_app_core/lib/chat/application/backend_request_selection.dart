import 'dart:async';
import 'package:flutter/services.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection_error.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 默认兼容存储的同步 getter 会惰性启动偏好插件；纯能力查询不可启动它。
/// 已注入的同步存储不需要平台 binding，App 默认存储须沿原 doInit 顺序。
bool backendIdentityCanBeCaptured() {
  if (!LoginSdkConfig.isInstalled) {
    try {
      ServicesBinding.instance;
    } catch (_) {
      return false;
    }
  }
  final storage = LoginSdkConfig.instance.storage;
  if (storage is! HiCacheTokenStorage) return true;
  try {
    ServicesBinding.instance;
    return true;
  } catch (_) {
    return false;
  }
}

/// 每个逻辑运行独立持有；不做 modelId 全局缓存，不向调用方返回凭据。
class BackendRequestSelection {
  final AISettings _settings;
  late final String _legacyModelId;
  final LegacyBackendSelectionProbe? _probe;
  late final BackendSelectionBindingScope? _scope;
  late final Object? _storage;
  late final String? _token;
  ChatTransportException? _captureFailure;
  Future<BackendSelection>? _preparing;
  BackendSelection? _fixed;
  BackendSelection? get fixedPair => _fixed;
  String get modelId => _settings.backendSelection == null
      ? _legacyModelId
      : _settings.backendSelection!.modelId ?? '';
  BackendRequestSelection(AISettings settings,
      {LegacyBackendSelectionProbe? probe, BackendSelectionBindingScope? scope})
      : _settings = settings.clone(),
        _probe = probe {
    _legacyModelId =
        _settings.backendSelection == null ? _settings.effectiveModel : '';
    Object? storage;
    String? token;
    BackendSelectionBindingScope? capturedScope;
    try {
      if (!backendIdentityCanBeCaptured()) {
        throw StateError('identity not initialized');
      }
      storage = LoginSdkConfig.instance.storage;
      token = LoginDao.getBoardingPass();
      final account = LoginDao.getAccountHash();
      if (account == null || LoginDao.isGuest()) {
        capturedScope = null;
        _captureFailure = const ChatTransportException(
            safeCode: 'authentication_error',
            safeMessage: '请登录后使用后端模型',
            statusCode: 401);
      } else {
        capturedScope = scope ??
            BackendSelectionBindingScope.capture(
                AgentWorkflowScope(accountHash: account));
      }
    } catch (_) {
      capturedScope = null;
      _captureFailure = _failure('backend_scope_changed');
    }
    _storage = storage;
    _token = token;
    _scope = capturedScope;
  }
  void verify() {
    final captureFailure = _captureFailure;
    if (captureFailure != null) throw captureFailure;
    try {
      if (!identical(_storage, LoginSdkConfig.instance.storage)) {
        throw StateError('scope');
      }
      _scope!.verify();
    } catch (_) {
      throw _failure('backend_scope_changed');
    }
    final pair = _fixed;
    if (pair != null &&
        !ModelCatalog.backendProfileAvailable(pair.modelId!,
            account: pair.accountHash!, providerCode: pair.providerCode!)) {
      throw _failure('model_unavailable');
    }
  }

  Uri endpoint(String path) {
    verify();
    return Uri.parse(_scope!.origin).replace(path: path);
  }

  /// 共享解析不被某一个等待者的取消销毁；每个等待者独立检查取消/身份。
  Future<BackendSelection> prepare({Future<void>? abortTrigger}) async {
    var cancelled = false;
    abortTrigger?.then<void>((_) => cancelled = true,
        onError: (Object _, StackTrace __) => cancelled = true);
    await Future<void>.value();
    void check() {
      if (cancelled) {
        throw const ChatTransportException(
            safeCode: 'cancelled', safeMessage: '请求已取消');
      }
      verify();
    }

    check();
    final future = _preparing ??= _resolve();
    final pair = abortTrigger == null
        ? await future
        : await Future.any<BackendSelection>([
            future,
            abortTrigger.then<BackendSelection>(
                (_) => throw const ChatTransportException(
                    safeCode: 'cancelled', safeMessage: '请求已取消'),
                onError: (Object _, StackTrace __) =>
                    throw const ChatTransportException(
                        safeCode: 'cancelled', safeMessage: '请求已取消'))
          ]);
    check();
    return pair;
  }

  Future<BackendSelection> _resolve() async {
    verify();
    try {
      final declared = _settings.backendSelection;
      BackendSelection pair;
      if (declared != null) {
        if (!declared.isPair ||
            !declared.matchesScope(
                accountHash: _scope!.accountHash, origin: _scope!.origin)) {
          throw _failure('invalid_backend_selection');
        }
        pair = declared;
      } else {
        if (modelId.trim().isEmpty) throw _failure('invalid_backend_selection');
        final probe = _probe ??
            BackendSelectionProbeClient(
                    headers: () => {'Authorization': 'Bearer ${_token ?? ''}'})
                .resolve;
        pair = await probe(_scope!, modelId);
        verify();
        _scope!.verifyPair(pair, modelId);
      }
      verify();
      _fixed = pair;
      verify();
      return pair;
    } on BackendSelectionProbeFailure catch (error) {
      final code = switch (error.safeCode) {
        'catalogForbidden' => 'catalog_not_public',
        'model_ambiguous' ||
        'model_unavailable' ||
        'provider_unavailable' =>
          error.safeCode,
        'notAuthenticated' => 'authentication_error',
        _ => 'invalid_backend_selection',
      };
      if (code == 'authentication_error') {
        throw const ChatTransportException(
            safeCode: 'authentication_error',
            safeMessage: '登录已过期，请重新登录',
            statusCode: 401,
            failureStage: ChatFailureStage.response,
            failureKind: ChatFailureKind.httpStatus);
      }
      throw _failure(code);
    } on ChatTransportException {
      rethrow;
    } catch (_) {
      throw _failure('backend_scope_changed');
    }
  }

  static ChatTransportException _failure(String code) => ChatTransportException(
      safeCode: code,
      safeMessage: backendSelectionMessages[code]!,
      failureStage: ChatFailureStage.prepare,
      failureKind: ChatFailureKind.invalidConfiguration,
      unsentReason: ChatUnsentReason.configurationRevoked);
}
