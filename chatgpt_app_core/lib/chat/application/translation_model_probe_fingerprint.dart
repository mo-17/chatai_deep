import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:crypto/crypto.dart';
import 'package:login_sdk/dao/backend_host.dart';

/// 只返回可持久化的 SHA-256 身份；原始 endpoint 与 API Key 都不会离开内存。
abstract final class TranslationModelProbeFingerprint {
  static const protocolVersion = 1;

  static String build({
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    final applied = TranslationModelResolver.apply(settings, profile);
    final isLocal = profile.mode == TranslationExecutionMode.local;
    final providerId = isLocal ? applied.activeProvider.id : 'backend';
    final providerCode =
        isLocal ? applied.activeProvider.providerCode : 'backend';
    final Uri endpointUri;
    final int? explicitPort;
    if (isLocal) {
      final rawEndpoint = applied.activeLocal.baseUrl;
      endpointUri = Uri.parse(rawEndpoint);
      explicitPort = _explicitPortInEndpoint(rawEndpoint);
    } else {
      endpointUri = BackendConfig.buildUri('/uapi/chat/completions/stream');
      explicitPort = _explicitPortInAuthority(BackendConfig.host);
    }
    final normalizedPath = endpointUri.normalizePath().path;
    final normalizedOrigin = Uri(
      scheme: endpointUri.scheme.toLowerCase(),
      host: endpointUri.host.toLowerCase(),
    ).toString();
    final normalizedRequestTarget = Uri(
      path: normalizedPath,
      query: endpointUri.hasQuery ? endpointUri.query : null,
    ).toString();
    // Uri.toString() 会省略显式 :443/:80；配置中显式端口仍属于正式请求身份。
    final effectivePort =
        explicitPort ?? (endpointUri.hasPort ? endpointUri.port : null);
    final effectiveEndpoint = effectivePort != null
        ? '$normalizedOrigin:$effectivePort$normalizedRequestTarget'
        : '$normalizedOrigin$normalizedRequestTarget';
    final canonical = jsonEncode({
      'protocolVersion': protocolVersion,
      'reasoningPolicyVersion': ReasoningControlAdapter.policyVersion,
      'mode': profile.mode.name,
      'providerId': providerId,
      'providerCode': providerCode,
      'modelId': profile.modelId,
      'endpoint': effectiveEndpoint,
      'reasoningPolicy': profile.reasoningPolicy.name,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static int? _explicitPortInEndpoint(String endpoint) {
    final authorityStart = endpoint.indexOf('://');
    if (authorityStart < 0) return null;
    final start = authorityStart + 3;
    var end = endpoint.length;
    for (final separator in ['/', '?', '#']) {
      final candidate = endpoint.indexOf(separator, start);
      if (candidate >= 0 && candidate < end) end = candidate;
    }
    return _explicitPortInAuthority(endpoint.substring(start, end));
  }

  static int? _explicitPortInAuthority(String authority) {
    final withoutUserInfo = authority.substring(authority.lastIndexOf('@') + 1);
    final String rawPort;
    if (withoutUserInfo.startsWith('[')) {
      final closingBracket = withoutUserInfo.indexOf(']');
      if (closingBracket < 0 ||
          closingBracket + 1 >= withoutUserInfo.length ||
          withoutUserInfo[closingBracket + 1] != ':') {
        return null;
      }
      rawPort = withoutUserInfo.substring(closingBracket + 2);
    } else {
      final separator = withoutUserInfo.lastIndexOf(':');
      if (separator < 0 ||
          withoutUserInfo.indexOf(':') != separator ||
          separator + 1 >= withoutUserInfo.length) {
        return null;
      }
      rawPort = withoutUserInfo.substring(separator + 1);
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(rawPort)) return null;
    final port = int.tryParse(rawPort);
    return port != null && port >= 0 && port <= 65535 ? port : null;
  }
}
