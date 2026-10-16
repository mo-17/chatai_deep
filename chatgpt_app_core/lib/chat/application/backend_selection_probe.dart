import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';

/// 一次绑定始终属于原账号、凭据、登录代次、后端和恢复代次。
/// GET 不持账号许可；许可只包后续短 SQLite 事务。
class BackendSelectionBindingScope {
  final AgentWorkflowScope lifecycle;
  final String origin;
  final bool Function() _identityCurrent;
  BackendSelectionBindingScope._(
      this.lifecycle, this.origin, this._identityCurrent);
  factory BackendSelectionBindingScope.capture(AgentWorkflowScope lifecycle) {
    final identity = AiCatalogIdentity.capture();
    lifecycle.verify();
    if (!identity.authenticated || identity.account != lifecycle.accountHash) {
      throw const WorkflowStale('后端模型绑定需要原登录账号');
    }
    final origin = BackendSelection.canonicalOrigin(Uri(
            scheme: identity.endpoint.scheme,
            host: identity.endpoint.host,
            port: identity.endpoint.port)
        .toString());
    if (origin == null) throw const WorkflowStale('后端来源无效');
    return BackendSelectionBindingScope._(
        lifecycle, origin, () => identity.current);
  }
  @visibleForTesting
  factory BackendSelectionBindingScope.test(AgentWorkflowScope lifecycle,
      {required String origin,
      required String Function() currentOrigin,
      bool Function()? identityCurrent}) {
    final normalized = BackendSelection.canonicalOrigin(origin);
    if (normalized == null) throw const FormatException('后端来源无效');
    return BackendSelectionBindingScope._(
        lifecycle,
        normalized,
        () =>
            BackendSelection.canonicalOrigin(currentOrigin()) == normalized &&
            (identityCurrent?.call() ?? true));
  }
  String get accountHash => lifecycle.accountHash;
  void verify() {
    lifecycle.verify();
    if (!_identityCurrent()) throw const WorkflowStale('登录凭据或后端来源已变化');
  }

  void verifyPair(BackendSelection selection, String modelId) {
    verify();
    if (!selection.matchesScope(accountHash: accountHash, origin: origin) ||
        selection.modelId != modelId) {
      throw const WorkflowStale('解析的模型选择不属于原请求');
    }
  }

  Future<T> stable<T>(Future<T> Function() action) =>
      lifecycle.stable(() async {
        verify();
        final result = await action();
        verify();
        return result;
      });
}

class BackendSelectionProbeFailure implements Exception {
  final String safeCode;
  const BackendSelectionProbeFailure(this.safeCode);
  @override
  String toString() => '后端模型选择无法确认，请检查配置或重试 ($safeCode)';
}

typedef LegacyBackendSelectionProbe = Future<BackendSelection> Function(
    BackendSelectionBindingScope scope, String modelId);

/// JWT + catalogPublic 的只读 R1 解析；不读缓存、不列候选、不重试、不发模型。
class BackendSelectionProbeClient {
  final http.Client? client;
  final Map<String, String> Function() headers;
  final Duration timeout;
  BackendSelectionProbeClient(
      {this.client,
      Map<String, String> Function()? headers,
      this.timeout = const Duration(seconds: 8)})
      : headers = headers ?? hiHeaders;
  Future<BackendSelection> resolve(
      BackendSelectionBindingScope scope, String modelId) async {
    scope.verify();
    if (modelId.trim().isEmpty) {
      throw const BackendSelectionProbeFailure('invalidSelection');
    }
    final own = client == null;
    final transport = client ?? http.Client();
    try {
      final endpoint = Uri.parse(scope.origin).replace(
          path: '/uapi/ai/model-selection',
          queryParameters: {'modelId': modelId});
      final requestHeaders = headers();
      scope.verify();
      final request = http.Request('GET', endpoint)
        ..headers.addAll(requestHeaders)
        ..followRedirects = false;
      final response = await (() async {
        final streamed = await transport.send(request);
        return http.Response.fromStream(streamed);
      })()
          .timeout(timeout);
      scope.verify();
      if (response.statusCode == 401) {
        throw const BackendSelectionProbeFailure('notAuthenticated');
      }
      if (response.statusCode == 403) {
        throw const BackendSelectionProbeFailure('catalogForbidden');
      }
      if (response.statusCode != 200) {
        var code =
            response.statusCode == 409 ? 'model_unavailable' : 'requestFailed';
        try {
          final body = jsonDecode(response.body);
          if (response.statusCode == 409 &&
              body is Map &&
              const {
                'model_ambiguous',
                'model_unavailable',
                'provider_unavailable'
              }.contains(body['safeCode'])) {
            code = body['safeCode'] as String;
          }
        } catch (_) {/* 仅固定白名单，不回显响应。 */}
        throw BackendSelectionProbeFailure(code);
      }
      final body = jsonDecode(response.body);
      final data = body is Map && body['code'] == 0 ? body['data'] : null;
      if (data is! Map ||
          data.length != 2 ||
          data['providerCode'] is! String ||
          data['modelId'] != modelId) {
        throw const BackendSelectionProbeFailure('invalidResponse');
      }
      final pair = BackendSelection.pair(
          providerCode: data['providerCode'] as String,
          modelId: modelId,
          accountHash: scope.accountHash,
          origin: scope.origin);
      scope.verifyPair(pair, modelId);
      return pair;
    } on TimeoutException {
      throw const BackendSelectionProbeFailure('timeout');
    } on BackendSelectionProbeFailure {
      rethrow;
    } on WorkflowStale {
      rethrow;
    } catch (_) {
      throw const BackendSelectionProbeFailure('invalidResponse');
    } finally {
      if (own) transport.close();
    }
  }
}
