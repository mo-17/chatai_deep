import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/dao/ai_provider_api.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProvider _provider({
  String host = 'https://api.deepseek.com',
  String key = 'synthetic-test-key',
  String id = 'deepseek',
}) =>
    AiProvider(
      id: id,
      type: 'openai',
      name: 'Test provider',
      apiHost: host,
      apiKey: key,
    );

Map<String, Object?> _file({String id = 'file-api-latest'}) => {
      'id': id,
      'object': 'file',
      'filename': '测试图片.png',
      'purpose': 'user_data',
      'bytes': 4096,
      'created_at': 1700000000,
      'expires_at': 1700003600,
    };

Map<String, Object?> _page({
  List<Object?>? files,
  bool hasMore = false,
}) {
  final rows = files ?? [_file()];
  return {
    'object': 'list',
    'data': rows,
    'first_id': rows.isEmpty ? null : (rows.first as Map)['id'],
    'last_id': rows.isEmpty ? null : (rows.last as Map)['id'],
    'has_more': hasMore,
  };
}

http.Response _json(Object data, {int status = 200}) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json'});

Matcher _apiError([String? text]) => isA<AiProviderApiException>().having(
      (error) => error.message,
      'safe message',
      text == null ? isNot(contains('synthetic-test-key')) : contains(text),
    );

void main() {
  test('仅官方 HTTPS root、v1 和 beta 配置开放文件管理，空地址使用预设', () {
    for (final path in [
      '',
      '/v1',
      '/chat/completions',
      '/v1/chat/completions',
      '/beta/chat/completions',
      '/beta#',
    ]) {
      final provider = _provider(host: 'https://api.deepseek.com$path');
      expect(AiProviderApi.supportsDeepSeekFiles(provider), isTrue);
      expect(AiProviderApi.endpointFor(provider, 'files').toString(),
          'https://api.deepseek.com/files');
      expect(
          AiProviderApi.endpointFor(provider, 'files/file-api-test').toString(),
          'https://api.deepseek.com/files/file-api-test');
    }
    expect(AiProviderApi.supportsDeepSeekFiles(_provider(host: '')), isTrue);
    expect(
        AiProviderApi.supportsDeepSeekFiles(
            _provider(host: 'https://api.deepseek.com:443/v1')),
        isTrue);
  });

  test('代理、非 HTTPS、端口和未知前缀不接收文件管理请求', () async {
    var requests = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      requests++;
      return _json(_page());
    }));
    for (final host in [
      'https://api.openai.com',
      'https://proxy.example/v1',
      'http://api.deepseek.com/v1',
      'https://api.deepseek.com:8443/v1',
      'https://api.deepseek.com.evil.example/v1',
      'https://api.deepseek.com/custom/v1',
      'https://api.deepseek.com/beta',
      'https://api.deepseek.com/v1/chat/completions?secret=synthetic-test-key',
      'https://user:password@api.deepseek.com/v1',
    ]) {
      final provider = _provider(host: host);
      expect(AiProviderApi.supportsDeepSeekFiles(provider), isFalse);
      await expectLater(api.listDeepSeekFiles(provider), throwsA(_apiError()));
      await expectLater(api.getDeepSeekFile(provider, 'file-api-latest'),
          throwsA(_apiError()));
      await expectLater(api.deleteDeepSeekFile(provider, 'file-api-latest'),
          throwsA(_apiError()));
    }
    expect(requests, 0);
  });

  test('不允许 ID 逃逸文件路径或把其他资源当成文件接口', () async {
    var requests = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      requests++;
      return _json(_file());
    }));
    for (final id in [
      '',
      'file-api-',
      'file-other-test',
      ' file-api-test',
      'file-api-test/../user/balance',
      'file-api-test?key=synthetic-test-key',
      'file-api-test%2Fother',
      'file-api-test#fragment',
      'file-api-测试',
      'file-api-${'a' * 257}',
    ]) {
      expect(() => AiProviderApi.endpointFor(_provider(), 'files/$id'),
          throwsA(_apiError('ID')));
      await expectLater(
          api.getDeepSeekFile(_provider(), id), throwsA(_apiError('ID')));
      await expectLater(
          api.deleteDeepSeekFile(_provider(), id), throwsA(_apiError('ID')));
      await expectLater(api.listDeepSeekFiles(_provider(), after: id),
          throwsA(_apiError('ID')));
    }
    expect(() => AiProviderApi.endpointFor(_provider(), 'responses'),
        throwsA(_apiError()));
    expect(requests, 0);
  });

  test('列表按最新顺序和 user_data 请求，带鉴权、取消能力并禁用重定向', () async {
    final client = _CallbackClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.host, 'api.deepseek.com');
      expect(request.url.path, '/files');
      expect(request.url.queryParameters,
          {'limit': '25', 'order': 'desc', 'purpose': 'user_data'});
      expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
      expect(request.headers['Accept'], 'application/json');
      expect(request.followRedirects, isFalse);
      expect(request, isA<http.AbortableRequest>());
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(_page()))), 200);
    });
    final page =
        await AiProviderApi(client: client).listDeepSeekFiles(_provider());
    final file = page.files.single;
    expect(file.id, 'file-api-latest');
    expect(file.filename, '测试图片.png');
    expect(file.bytes, 4096);
    expect(file.createdAt, 1700000000);
    expect(file.expiresAt, 1700003600);
    expect(file.purpose, 'user_data');
    expect(page.lastId, 'file-api-latest');
    expect(page.hasMore, isFalse);
    expect(() => page.files.clear(), throwsUnsupportedError);
    expect(client.closed, isFalse);
  });

  test('下一页保留 last_id 游标及指定 limit', () async {
    final api = AiProviderApi(client: MockClient((request) async {
      expect(request.url.queryParameters, {
        'limit': '10',
        'order': 'desc',
        'purpose': 'user_data',
        'after': 'file-api-latest',
      });
      return _json(_page(files: [_file(id: 'file-api-older')], hasMore: true));
    }));
    final page = await api.listDeepSeekFiles(_provider(),
        after: 'file-api-latest', limit: 10);
    expect(page.files.single.id, 'file-api-older');
    expect(page.lastId, 'file-api-older');
    expect(page.hasMore, isTrue);
  });

  test('列表和详情在 await 之前固定当前账号 Key 和地址', () async {
    for (final detail in [false, true]) {
      final provider = _provider();
      final api = AiProviderApi(client: MockClient((request) async {
        expect(request.url.host, 'api.deepseek.com');
        expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
        provider.apiKey = 'other-key';
        provider.apiHost = 'https://changed.example/v1';
        return _json(detail ? _file() : _page());
      }));
      final fetching = detail
          ? api.getDeepSeekFile(provider, 'file-api-latest')
          : api.listDeepSeekFiles(provider);
      provider.apiKey = 'changed-after-call';
      await fetching;
    }
  });

  test('空文件页接受 null、空串或缺省游标，且不能声称还有下一页', () async {
    for (final cursors in [
      <String, Object?>{},
      {'first_id': null, 'last_id': null},
      {'first_id': '', 'last_id': ''},
    ]) {
      final api = AiProviderApi(
          client: MockClient((request) async => _json({
                'object': 'list',
                'data': [],
                'has_more': false,
                ...cursors,
              })));
      final page = await api.listDeepSeekFiles(_provider());
      expect(page.files, isEmpty);
      expect(page.lastId, isNull);
      expect(page.hasMore, isFalse);
    }
  });

  test('列表拒绝错误结构、超量、重复 ID 和不前进的分页信息', () async {
    final badPages = [
      {..._page(), 'object': 'file'},
      {..._page(), 'data': null},
      {..._page(), 'has_more': 1},
      {
        ..._page(),
        'data': [1]
      },
      _page(files: List.generate(1001, (i) => _file(id: 'file-api-$i'))),
      _page(files: [_file(), _file()]),
      {..._page(hasMore: true), 'last_id': null},
      {..._page(), 'last_id': 'file-api-wrong'},
      {..._page(), 'first_id': 'file-api-wrong'},
      {..._page(), 'last_id': 'file-api-/other'},
      _page(files: [], hasMore: true),
      {..._page(files: []), 'last_id': 'file-api-latest'},
      _page(hasMore: true),
    ];
    for (final data in badPages) {
      final api =
          AiProviderApi(client: MockClient((request) async => _json(data)));
      await expectLater(
          api.listDeepSeekFiles(_provider(), after: 'file-api-latest'),
          throwsA(_apiError()));
    }
  });

  test('分页数量和空 Key 在发请求前校验', () async {
    var requests = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      requests++;
      return _json(_page());
    }));
    for (final limit in [-1, 0, 1001]) {
      await expectLater(api.listDeepSeekFiles(_provider(), limit: limit),
          throwsA(_apiError('数量')));
    }
    await expectLater(api.listDeepSeekFiles(_provider(key: '  ')),
        throwsA(_apiError('API Key')));
    await expectLater(
        api.getDeepSeekFile(_provider(key: ''), 'file-api-latest'),
        throwsA(_apiError('API Key')));
    await expectLater(
        api.deleteDeepSeekFile(_provider(key: ''), 'file-api-latest'),
        throwsA(_apiError('API Key')));
    expect(requests, 0);
  });

  test('详情以 GET 查询指定文件，无过期时间也可正常显示', () async {
    final api = AiProviderApi(client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(),
          'https://api.deepseek.com/files/file-api-test_1');
      final row = _file(id: 'file-api-test_1')..remove('expires_at');
      return _json(row);
    }));
    final file = await api.getDeepSeekFile(_provider(), 'file-api-test_1');
    expect(file.id, 'file-api-test_1');
    expect(file.expiresAt, isNull);
  });

  test('文件详情拒绝其他文件 ID、错误类型和无效元数据', () async {
    for (final change in [
      {'id': 'file-api-other'},
      {'id': 'file-api-unsafe/id'},
      {'object': 'other'},
      {'filename': null},
      {'filename': '   '},
      {'purpose': 'assistants'},
      {'bytes': -1},
      {'bytes': 1.0},
      {'created_at': '1700000000'},
      {'created_at': -1},
      {'created_at': 8640000000001},
      {'expires_at': 1.5},
    ]) {
      final api = AiProviderApi(
          client:
              MockClient((request) async => _json({..._file(), ...change})));
      await expectLater(api.getDeepSeekFile(_provider(), 'file-api-latest'),
          throwsA(_apiError()));
    }
  });

  test('删除仅发送当前文件 DELETE，以服务端精确确认成功', () async {
    final client = _CallbackClient((request) async {
      expect(request.method, 'DELETE');
      expect(request.url.toString(),
          'https://api.deepseek.com/files/file-api-latest');
      expect(request.followRedirects, isFalse);
      expect(request, isA<http.AbortableRequest>());
      expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'id': 'file-api-latest',
            'object': 'file',
            'deleted': true,
          }))),
          200);
    });
    await AiProviderApi(client: client)
        .deleteDeepSeekFile(_provider(), 'file-api-latest');
    expect(client.closed, isFalse);
  });

  test('DELETE 的 200 响应仍必须核对 ID、object 和 deleted=true', () async {
    for (final data in [
      {'id': 'file-api-other', 'object': 'file', 'deleted': true},
      {'id': 'file-api-latest', 'object': 'other', 'deleted': true},
      {'id': 'file-api-latest', 'object': 'file', 'deleted': false},
      {'id': 'file-api-latest', 'object': 'file', 'deleted': 'true'},
      {'id': 'file-api-latest', 'object': 'file'},
    ]) {
      final api =
          AiProviderApi(client: MockClient((request) async => _json(data)));
      await expectLater(api.deleteDeepSeekFile(_provider(), 'file-api-latest'),
          throwsA(_apiError('未确认')));
    }
  });

  test('三个接口均隐藏错误正文、底层网络异常和 API Key', () async {
    for (final method in ['list', 'get', 'delete']) {
      for (final status in [302, 401, 403, 404, 429, 500]) {
        final api = AiProviderApi(
            client: MockClient((request) async =>
                http.Response('echo synthetic-test-key private-body', status)));
        final call = _call(api, method);
        await expectLater(
            call,
            throwsA(isA<AiProviderApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                    (e) => e.toString(),
                    'redacted body',
                    isNot(anyOf(contains('synthetic-test-key'),
                        contains('private-body'))))));
      }
      final api = AiProviderApi(client: MockClient((request) async {
        throw http.ClientException('synthetic-test-key private-body');
      }));
      await expectLater(_call(api, method), throwsA(_apiError()));
    }
  });

  test('DELETE 不能用无效 JSON 或空响应悄悄报告删除成功', () async {
    for (final body in ['', 'not-json synthetic-test-key', '[]']) {
      final api = AiProviderApi(
          client: MockClient((request) async => http.Response(body, 200)));
      await expectLater(api.deleteDeepSeekFile(_provider(), 'file-api-latest'),
          throwsA(_apiError('格式')));
    }
  });

  test('三个接口均在已取消时禁止发送请求', () async {
    var requests = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      requests++;
      return _json(_page());
    }));
    for (final method in ['list', 'get', 'delete']) {
      await expectLater(_call(api, method, abort: Future<void>.value()),
          throwsA(_apiError('取消')));
    }
    expect(requests, 0);
  });

  test('超时取消 DELETE，不关闭调用方注入的 Client', () async {
    Future<void>? aborted;
    final client = _CallbackClient((request) {
      aborted = (request as http.Abortable).abortTrigger;
      return Completer<http.StreamedResponse>().future;
    });
    final api = AiProviderApi(
        client: client, timeout: const Duration(milliseconds: 10));
    await expectLater(api.deleteDeepSeekFile(_provider(), 'file-api-latest'),
        throwsA(_apiError('超时')));
    await expectLater(aborted, completes);
    expect(client.closed, isFalse);
  });

  test('列表读取中取消释放流订阅', () async {
    final cancel = Completer<void>();
    final received = Completer<void>();
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onListen: () => received.complete(),
      onCancel: () => cancelled = true,
    );
    final api = AiProviderApi(
        client: _CallbackClient(
            (request) async => http.StreamedResponse(stream.stream, 200)));
    final expectation = expectLater(
        api.listDeepSeekFiles(_provider(), abortTrigger: cancel.future),
        throwsA(_apiError('取消')));
    await received.future;
    cancel.complete();
    await expectation;
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('过大的文件详情响应及时停止读取', () async {
    var cancelled = false;
    final stream =
        StreamController<List<int>>(onCancel: () => cancelled = true);
    final api = AiProviderApi(client: _CallbackClient((request) async {
      scheduleMicrotask(() => stream.add(List.filled(1024 * 1024 + 1, 32)));
      return http.StreamedResponse(stream.stream, 200);
    }));
    await expectLater(api.getDeepSeekFile(_provider(), 'file-api-latest'),
        throwsA(_apiError('过大')));
    expect(cancelled, isTrue);
    await stream.close();
  });
}

Future<Object?> _call(AiProviderApi api, String method,
    {Future<void>? abort}) async {
  switch (method) {
    case 'list':
      return api.listDeepSeekFiles(_provider(), abortTrigger: abort);
    case 'get':
      return api.getDeepSeekFile(_provider(), 'file-api-latest',
          abortTrigger: abort);
    default:
      await api.deleteDeepSeekFile(_provider(), 'file-api-latest',
          abortTrigger: abort);
      return null;
  }
}

class _CallbackClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) callback;
  bool closed = false;

  _CallbackClient(this.callback);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      callback(request);

  @override
  void close() => closed = true;
}
