import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 合并备份与当前账号的敏感 AI 设置。
///
/// [incomingIncludesSecrets] 来自 manifest.includeApiKeys。显式为 true 时，
/// 备份是完整凭据快照，空值也会覆盖本地值。缺失或为 false 时按旧格式
/// 兼容规则处理：非空备份值覆盖，空值代表“未携带”并保留本地凭据。
AISettings mergeImportedSettingsSecrets(
  AISettings incoming,
  AISettings local, {
  bool incomingIncludesSecrets = false,
}) {
  // “信任”是当前设备上的执行授权，不是可迁移的数据。备份只能继续沿用
  // 本地已经授予、且 id + endpoint 唯一匹配的 MCP 信任；新增/改址/歧义
  // server 一律按不信任导入。后端 MCP 的信任同样只保留当前设备状态。
  stripImportedMcpAuthorizations(incoming);
  incoming
    ..mcpBackendEnabled = local.mcpBackendEnabled
    ..mcpBackendTrusted = local.mcpBackendTrusted;
  incoming.mcpServers = incoming.mcpServers.map((server) {
    final matches = local.mcpServers
        .where(
          (entry) =>
              entry.id == server.id &&
              _hasSameEndpointIdentity(entry.url, server.url),
        )
        .toList();
    final localGrant = matches.length == 1 ? matches.single : null;
    return server.copyWith(
      enabled: localGrant?.enabled ?? false,
      trusted: localGrant?.trusted ?? false,
      permission: localGrant?.permission ?? McpToolPermission.readOnly,
      enabledProjectIds: localGrant?.enabledProjectIds ?? const [],
    );
  }).toList();

  // manifest 显式声明“包含 API Key”时，备份的凭据状态是完整快照：
  // 空值也有意义，表示用户导出时该凭据未配置，应清除本地旧值。
  if (incomingIncludesSecrets) return incoming;

  for (final provider in incoming.providers) {
    if (provider.apiKey.isNotEmpty) continue;
    final matches = local.providers
        .where(
          (entry) =>
              entry.id == provider.id &&
              entry.type == provider.type &&
              _hasSameEndpointIdentity(entry.apiHost, provider.apiHost),
        )
        .toList();
    // 重复 id/endpoint 也是歧义配置，不能任取一个候选搬运凭据。
    if (matches.length == 1 && matches.single.apiKey.isNotEmpty) {
      provider.apiKey = matches.single.apiKey;
    }
  }
  if (incoming.tavilyApiKey.isEmpty) {
    incoming.tavilyApiKey = local.tavilyApiKey;
  }
  if (incoming.exaApiKey.isEmpty) incoming.exaApiKey = local.exaApiKey;
  if (incoming.bochaApiKey.isEmpty) incoming.bochaApiKey = local.bochaApiKey;
  if (incoming.zhipuApiKey.isEmpty) incoming.zhipuApiKey = local.zhipuApiKey;

  incoming.mcpServers = incoming.mcpServers.map((server) {
    if (server.headers.isNotEmpty) return server;
    final matches = local.mcpServers
        .where(
          (entry) =>
              entry.id == server.id &&
              _hasSameEndpointIdentity(entry.url, server.url),
        )
        .toList();
    if (matches.length != 1 || matches.single.headers.isEmpty) return server;
    return server.copyWith(headers: matches.single.headers);
  }).toList();
  return incoming;
}

/// 把 settings.json 中的 MCP 运行授权视为不可迁移数据。
///
/// BackupService 在返回 [AISettings] 给任何调用方前先调用此边界；UI
/// 随后只能通过 [mergeImportedSettingsSecrets] 恢复当前设备已授予的状态。
AISettings stripImportedMcpAuthorizations(AISettings incoming) {
  incoming
    ..mcpBackendEnabled = false
    ..mcpBackendTrusted = false
    ..mcpServers = incoming.mcpServers
        .map(
          (server) => server.copyWith(
            enabled: false,
            trusted: false,
            permission: McpToolPermission.readOnly,
            enabledProjectIds: const [],
          ),
        )
        .toList();
  return incoming;
}

bool _hasSameEndpointIdentity(String left, String right) {
  final leftIdentity = _endpointIdentity(left);
  if (leftIdentity == null) return false;
  return leftIdentity == _endpointIdentity(right);
}

typedef _EndpointIdentity = ({
  String scheme,
  bool hasUserInfo,
  String userInfo,
  bool bracketedHost,
  String host,
  int port,
  String path,
  bool hasQuery,
  String query,
  bool hasFragment,
  String fragment,
});

_EndpointIdentity? _endpointIdentity(String raw) {
  if (raw.isEmpty ||
      raw != raw.trim() ||
      RegExp(r'\s').hasMatch(raw) ||
      raw.contains('\\')) {
    return null;
  }
  try {
    final match = _absoluteHttpEndpoint.firstMatch(raw);
    if (match == null) return null;
    final scheme = match.group(1)!.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;

    final authority = match.group(2)!;
    final path = match.group(3)!;
    final hasQuery = match.group(4) != null;
    final query = match.group(5) ?? '';
    final hasFragment = match.group(6) != null;
    final fragment = match.group(7) ?? '';
    if (authority.isEmpty ||
        !_hasOnlyValidPercentEscapes(authority) ||
        !_hasOnlyValidPercentEscapes(path) ||
        !_hasOnlyValidPercentEscapes(query) ||
        !_hasOnlyValidPercentEscapes(fragment)) {
      return null;
    }

    final atSigns = '@'.allMatches(authority).length;
    if (atSigns > 1) return null;
    final hasUserInfo = atSigns == 1;
    final at = authority.indexOf('@');
    final userInfo = hasUserInfo ? authority.substring(0, at) : '';
    final hostAndPort = hasUserInfo ? authority.substring(at + 1) : authority;
    // 空 user-info 会被 Dart Uri 抹掉，不能与“未携带 user-info”视为同一。
    if ((hasUserInfo && userInfo.isEmpty) || hostAndPort.isEmpty) return null;

    final parsedAuthority = _parseRawAuthority(hostAndPort);
    if (parsedAuthority == null) return null;
    final defaultPort = scheme == 'https' ? 443 : 80;
    final port = parsedAuthority.port ?? defaultPort;

    // Uri 只辅助拒绝无法作为绝对 HTTP(S) URL 的输入；identity 始终使用
    // 上面的 raw 捕获组，避免 dot-segment、反斜杠与 percent escape 被额外归一化。
    final uri = Uri.tryParse(raw);
    final normalizedHost = _asciiLowercase(parsedAuthority.host);
    final normalizedAuthority = StringBuffer()
      ..write(hasUserInfo ? '$userInfo@' : '')
      ..write(parsedAuthority.bracketed ? '[$normalizedHost]' : normalizedHost)
      ..write(port == defaultPort ? '' : ':$port');
    final allowedNormalizedUri = StringBuffer()
      ..write('$scheme://$normalizedAuthority')
      ..write(path)
      ..write(hasQuery ? '?$query' : '')
      ..write(hasFragment ? '#$fragment' : '');
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.scheme.toLowerCase() != scheme ||
        uri.toString() != allowedNormalizedUri.toString()) {
      return null;
    }

    return (
      scheme: scheme,
      hasUserInfo: hasUserInfo,
      userInfo: userInfo,
      bracketedHost: parsedAuthority.bracketed,
      host: normalizedHost,
      port: port,
      path: _withoutTrailingPathSlashes(path),
      hasQuery: hasQuery,
      query: query,
      hasFragment: hasFragment,
      fragment: fragment,
    );
  } catch (_) {
    return null;
  }
}

final RegExp _absoluteHttpEndpoint = RegExp(
  r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(\?([^#]*))?(#(.*))?$',
);

({String host, int? port, bool bracketed})? _parseRawAuthority(
  String hostAndPort,
) {
  String host;
  int? port;
  final bracketed = hostAndPort.startsWith('[');
  if (bracketed) {
    final closingBracket = hostAndPort.indexOf(']');
    if (closingBracket <= 1 ||
        hostAndPort.indexOf('[', 1) >= 0 ||
        hostAndPort.indexOf(']', closingBracket + 1) >= 0) {
      return null;
    }
    host = hostAndPort.substring(1, closingBracket);
    final suffix = hostAndPort.substring(closingBracket + 1);
    if (suffix.isNotEmpty) {
      if (!suffix.startsWith(':')) return null;
      port = _parsePort(suffix.substring(1));
      if (port == null) return null;
    }
  } else {
    if (hostAndPort.contains('[') || hostAndPort.contains(']')) return null;
    final firstColon = hostAndPort.indexOf(':');
    final lastColon = hostAndPort.lastIndexOf(':');
    if (firstColon != lastColon) return null;
    if (lastColon >= 0) {
      host = hostAndPort.substring(0, lastColon);
      port = _parsePort(hostAndPort.substring(lastColon + 1));
      if (port == null) return null;
    } else {
      host = hostAndPort;
    }
  }
  if (host.isEmpty || host.contains('%')) return null;
  return (host: host, port: port, bracketed: bracketed);
}

int? _parsePort(String raw) {
  if (raw.isEmpty || !RegExp(r'^\d+$').hasMatch(raw)) return null;
  final port = int.tryParse(raw);
  return port != null && port >= 1 && port <= 65535 ? port : null;
}

bool _hasOnlyValidPercentEscapes(String raw) {
  for (var index = 0; index < raw.length; index += 1) {
    if (raw.codeUnitAt(index) != 0x25) continue;
    if (index + 2 >= raw.length ||
        !_isHexDigit(raw.codeUnitAt(index + 1)) ||
        !_isHexDigit(raw.codeUnitAt(index + 2))) {
      return false;
    }
    index += 2;
  }
  return true;
}

bool _isHexDigit(int value) =>
    (value >= 0x30 && value <= 0x39) ||
    (value >= 0x41 && value <= 0x46) ||
    (value >= 0x61 && value <= 0x66);

String _asciiLowercase(String raw) => String.fromCharCodes(
      raw.codeUnits.map(
        (value) => value >= 0x41 && value <= 0x5a ? value + 0x20 : value,
      ),
    );

String _withoutTrailingPathSlashes(String path) {
  if (path.isEmpty) return '/';
  var end = path.length;
  while (end > 1 && path.codeUnitAt(end - 1) == 0x2f) {
    end -= 1;
  }
  return path.substring(0, end);
}
