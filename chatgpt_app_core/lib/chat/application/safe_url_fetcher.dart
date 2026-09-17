import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/util/public_network_address_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

typedef HostResolver = Future<List<InternetAddress>> Function(String host);
typedef PinnedSocketStarter = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port,
);

/// `fetch_url` 的统一网络边界。
///
/// 每一跳都先解析并校验全部地址，再把实际连接固定到已校验的地址；响应按流计数，
/// 防止重定向绕过、DNS rebinding 以及压缩后超大正文进入模型上下文。
class SafeUrlFetcher {
  static const int maxRedirects = 3;
  static const int maxBodyBytes = 256 * 1024;
  static const Duration timeout = Duration(seconds: 15);

  final HostResolver _resolver;
  final http.Client? _testClient;
  final PinnedSocketStarter _socketStarter;
  final SecurityContext? _securityContext;

  SafeUrlFetcher({
    HostResolver? resolver,
    http.Client? testClient,
    PinnedSocketStarter? socketStarter,
    SecurityContext? securityContext,
  })  : _resolver = resolver ?? InternetAddress.lookup,
        _testClient = testClient,
        _socketStarter = socketStarter ?? Socket.startConnect,
        _securityContext = securityContext;

  Future<String> fetch(Uri initialUri) async {
    final deadline = DateTime.now().add(timeout);
    var uri = initialUri.replace(fragment: '');
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final destination = await _validateAndResolve(uri, deadline);
      final ownsClient = _testClient == null;
      final client = _testClient ?? _pinnedClient(destination);
      try {
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['accept'] =
              'text/html,application/xhtml+xml,text/plain,application/json;q=0.8';
        final response =
            await client.send(request).timeout(_remaining(deadline));

        if (_isRedirect(response.statusCode)) {
          if (redirects == maxRedirects) {
            throw const SafeUrlFetchException('重定向次数过多');
          }
          final location = response.headers['location'];
          if (location == null || location.trim().isEmpty) {
            throw const SafeUrlFetchException('重定向缺少目标地址');
          }
          uri = uri.resolve(location.trim()).replace(fragment: '');
          continue;
        }

        if (response.statusCode != HttpStatus.ok) {
          throw SafeUrlFetchException('HTTP ${response.statusCode}');
        }
        _validateContentType(response.headers['content-type']);
        final declaredLength = response.contentLength;
        if (declaredLength != null && declaredLength > maxBodyBytes) {
          throw const SafeUrlFetchException('响应正文超过安全上限');
        }

        final bytes = BytesBuilder(copy: false);
        final chunks = StreamIterator<List<int>>(response.stream);
        var total = 0;
        try {
          while (true) {
            final remaining = _remaining(deadline);
            if (!await chunks.moveNext().timeout(remaining)) break;
            final chunk = chunks.current;
            total += chunk.length;
            if (total > maxBodyBytes) {
              throw const SafeUrlFetchException('响应正文超过安全上限');
            }
            bytes.add(chunk);
          }
        } finally {
          await chunks.cancel();
        }
        return utf8.decode(bytes.takeBytes(), allowMalformed: true);
      } finally {
        if (ownsClient) client.close();
      }
    }
    throw const SafeUrlFetchException('重定向次数过多');
  }

  Future<_ResolvedDestination> _validateAndResolve(
    Uri uri,
    DateTime deadline,
  ) async {
    if (!(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const SafeUrlFetchException('url 不是可抓取的公开 http/https 地址');
    }

    final port = uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
    if ((uri.isScheme('https') && port != 443) ||
        (uri.isScheme('http') && port != 80)) {
      throw const SafeUrlFetchException('仅允许标准 HTTP/HTTPS 端口');
    }

    final host = PublicNetworkAddressPolicy.normalizeHostname(uri.host);
    if (PublicNetworkAddressPolicy.isLocalHostname(host)) {
      throw const SafeUrlFetchException('拒绝访问本机或私有网络地址');
    }

    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null
        ? await _resolver(host).timeout(_remaining(deadline))
        : [literal];
    if (addresses.isEmpty ||
        addresses.any((a) => !PublicNetworkAddressPolicy.isPublicAddress(a))) {
      throw const SafeUrlFetchException('拒绝访问本机或私有网络地址');
    }
    return _ResolvedDestination(addresses.first, host);
  }

  http.Client _pinnedClient(_ResolvedDestination destination) {
    final io = HttpClient()
      ..autoUncompress = true
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    io.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null) {
        throw const SafeUrlFetchException('fetch_url 不允许代理转发');
      }
      final port = uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
      final rawTask = await _socketStarter(destination.address, port);
      Socket? connectedSocket;
      Socket? upgradedSocket;
      var cancelled = false;
      final socket = rawTask.socket.then<Socket>((value) async {
        connectedSocket = value;
        if (cancelled) {
          value.destroy();
          throw const SocketException('连接已取消');
        }
        if (!uri.isScheme('https')) return value;

        // connectionFactory 会绕过 HttpClient 自带的 TLS 建连，因此必须在
        // 已固定的 IP socket 上显式升级，并仍用原始 hostname 做 SNI/证书校验。
        final secure = await SecureSocket.secure(
          value,
          host: destination.tlsHostname,
          context: _securityContext,
          supportedProtocols: const ['http/1.1'],
        );
        upgradedSocket = secure;
        if (cancelled) {
          secure.destroy();
          throw const SocketException('连接已取消');
        }
        return secure;
      });
      return ConnectionTask.fromSocket<Socket>(socket, () {
        cancelled = true;
        rawTask.cancel();
        connectedSocket?.destroy();
        upgradedSocket?.destroy();
      });
    };
    return IOClient(io);
  }

  static Duration _remaining(DateTime deadline) {
    final value = deadline.difference(DateTime.now());
    if (value <= Duration.zero) throw TimeoutException('fetch_url');
    return value;
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static void _validateContentType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    final mime = raw.split(';').first.trim().toLowerCase();
    if (mime.startsWith('text/') ||
        mime == 'application/xhtml+xml' ||
        mime == 'application/xml' ||
        mime == 'application/json') {
      return;
    }
    throw const SafeUrlFetchException('响应类型不允许作为网页正文读取');
  }
}

final class _ResolvedDestination {
  final InternetAddress address;
  final String tlsHostname;

  const _ResolvedDestination(this.address, this.tlsHostname);
}

class SafeUrlFetchException implements Exception {
  final String message;
  const SafeUrlFetchException(this.message);

  @override
  String toString() => message;
}
