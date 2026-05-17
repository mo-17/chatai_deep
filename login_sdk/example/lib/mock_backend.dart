import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 进程内 mock backend — 监听 localhost:3000，对所有路径返回 `{code:0, data, extra}` 形态。
/// 让 example 在不启动 chatgpt_backend 的情况下也能跑完整登录流程。
class MockBackend {
  HttpServer? _server;

  Future<int> start({int port = 3000}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    return _server!.port;
  }

  Future<void> stop() async => _server?.close(force: true);

  void _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;

    // ignore: avoid_print
    print('[mock] $method $path');

    // 识别端点 — 用 curl 找出真正的 mock 端口
    if (method == 'GET' && path == '/__mock_id__') {
      _writeJson(req.response, {'mock': true, 'role': 'login_sdk_example_mock'});
      return;
    }

    // 任意 POST → 返回成功的 login result。auth_kit_flutter / LoginDao 都吃这个格式。
    if (method == 'POST') {
      _writeJson(req.response, {
        'code': 0,
        'data': 'mock-token-${DateTime.now().millisecondsSinceEpoch}',
        'extra': {
          'userName': 'demo_user',
          'avatar': null,
          'imoocId': 'mock-imooc-id',
        },
      });
      return;
    }

    // 公共配置接口（auth_kit_flutter 用）
    if (method == 'GET' && path.contains('public-config')) {
      _writeJson(req.response, {
        'huaweiGetAuthCodeEnabled': false,
        'huaweiQuickLoginEnabled': false,
        'huaweiPrimaryFlow': 'getAuthCode',
        'appleSignInEnabled': false,
        'supportedCountryCodes': [
          {'code': '+86', 'iso': 'CN', 'name': '中国大陆'},
          {'code': '+1', 'iso': 'US', 'name': 'United States'},
        ],
      });
      return;
    }

    _writeJson(req.response, {'code': 0, 'data': null});
  }

  void _writeJson(HttpResponse response, Object body) {
    response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    response.close();
  }
}
