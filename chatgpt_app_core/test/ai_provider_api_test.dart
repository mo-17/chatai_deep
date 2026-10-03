import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/dao/ai_provider_api.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProvider _provider({
  String id = 'deepseek',
  String host = 'https://api.deepseek.com',
  String key = 'synthetic-test-key',
}) =>
    AiProvider(
        id: id,
        type: 'openai',
        name: 'Test provider',
        apiHost: host,
        apiKey: key);

http.Response _json(Object data, {int status = 200}) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json'});

Map<String, Object> _balanceRow(
        {String currency = 'CNY', String total = '1.00000001'}) =>
    {
      'currency': currency,
      'total_balance': total,
      'granted_balance': '0.00000001',
      'topped_up_balance': '1.00000000',
    };

Matcher _apiError([String? text]) => isA<AiProviderApiException>().having(
      (error) => error.message,
      'safe message',
      text == null ? isNot(contains('synthetic-test-key')) : contains(text),
    );

void main() {
  test('模型端点保留版本段、代理前缀和强制地址约定', () {
    final examples = {
      'https://api.openai.com': 'https://api.openai.com/v1/models',
      'https://api.openai.com/v1/': 'https://api.openai.com/v1/models',
      'https://proxy.example/vendor/v4':
          'https://proxy.example/vendor/v4/models',
      'https://proxy.example/vendor/api':
          'https://proxy.example/vendor/api/models',
      'https://proxy.example/vendor/#': 'https://proxy.example/vendor/models',
      'https://proxy.example/vendor/v1/chat/completions':
          'https://proxy.example/vendor/v1/models',
      'https://api.perplexity.ai/chat/completions':
          'https://api.perplexity.ai/models',
      'http://localhost:11434/v1': 'http://localhost:11434/v1/models',
    };
    for (final entry in examples.entries) {
      expect(
          AiProviderApi.endpointFor(_provider(host: entry.key), 'models')
              .toString(),
          entry.value);
    }
  });

  test('DeepSeek 官方 root、v1 和 beta 使用相同账号端点', () {
    for (final path in [
      '',
      '/v1',
      '/beta#',
      '/chat/completions',
      '/beta/chat/completions'
    ]) {
      final provider = _provider(host: 'https://api.deepseek.com$path');
      expect(AiProviderApi.endpointFor(provider, 'models').toString(),
          'https://api.deepseek.com/models');
      expect(AiProviderApi.endpointFor(provider, 'user/balance').toString(),
          'https://api.deepseek.com/user/balance');
      expect(AiProviderApi.supportsDeepSeekBalance(provider), isTrue);
    }
    expect(AiProviderApi.endpointFor(_provider(host: ''), 'models').toString(),
        'https://api.deepseek.com/models');
    expect(
        AiProviderApi.endpointFor(_provider(id: 'groq', host: ''), 'models')
            .toString(),
        'https://api.groq.com/openai/v1/models');
  });

  test('余额入口对代理、非 HTTPS、非默认端口和未知前缀关闭', () {
    for (final host in [
      'https://proxy.example/v1',
      'http://api.deepseek.com/v1',
      'https://api.deepseek.com:8443/v1',
      'https://api.deepseek.com.evil.example/v1',
      'https://api.deepseek.com/custom/v1',
    ]) {
      final provider = _provider(host: host);
      expect(AiProviderApi.supportsDeepSeekBalance(provider), isFalse);
      expect(() => AiProviderApi.endpointFor(provider, 'user/balance'),
          throwsA(_apiError()));
    }
    expect(
        AiProviderApi.supportsDeepSeekBalance(
            _provider(host: 'https://api.deepseek.com:443/v1')),
        isTrue);
  });

  test('拒绝含凭据、query、非约定 fragment 和无效端点的地址', () {
    for (final host in [
      '',
      'api.example.com',
      'file:///tmp/chat/completions',
      'https://user:password@api.deepseek.com/v1',
      'https://api.deepseek.com/v1/chat/completions?key=synthetic-test-key',
      'https://api.deepseek.com/v1/chat/completions#fragment',
      'https://api.deepseek.com/v1/chat/completions/extra',
    ]) {
      expect(
          () => AiProviderApi.endpointFor(
              _provider(id: 'custom_test', host: host), 'models'),
          throwsA(_apiError()));
    }
    expect(() => AiProviderApi.endpointFor(_provider(), 'responses'),
        throwsA(_apiError()));
  });

  test('获取模型使用 Bearer GET，关闭重定向并保留 API 返回 ID', () async {
    final client = _CallbackClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://api.deepseek.com/models');
      expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
      expect(request.followRedirects, isFalse);
      expect(request, isA<http.AbortableRequest>());
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'deepseek-flash', 'name': 'DeepSeek Flash'},
              {'id': 'org/vendor-model'},
              {'id': 'deepseek-flash', 'name': 'duplicate'},
            ],
          }))),
          200);
    });
    final models = await AiProviderApi(client: client).fetchModels(_provider());
    expect(models.map((model) => model.id),
        ['deepseek-flash', 'org/vendor-model']);
    expect(models.first.name, 'DeepSeek Flash');
    expect(models.last.name, 'org/vendor-model');
    expect(models.first.vision, isTrue);
    expect(models.first.reasoning, isTrue);
    expect(models.first.tool, isTrue);
    expect(client.closed, isFalse);
  });

  test('模型详情合并返回能力和容量信息，不从名称猜视觉支持', () async {
    final api = AiProviderApi(
        client: MockClient((request) async => _json({
              'data': [
                {
                  'id': 'custom-vision',
                  'input_modalities': ['text', 'image'],
                  'effort': {
                    'supported_levels': ['low', 'high']
                  },
                  'context_length': 1048576,
                  'max_output_tokens': 65536,
                },
                {'id': 'gpt-4o-mini'},
                {
                  'id': 'custom-image-name',
                  'effort': {'supported_levels': []}
                },
              ],
            })));
    final models = await api.fetchModels(
        _provider(id: 'custom_test', host: 'https://proxy.example/v1'));
    expect(models.first.vision, isTrue);
    expect(models.first.reasoning, isTrue);
    expect(models.first.description, contains('1048576'));
    expect(models.first.description, contains('65536'));
    expect(models[1].tool, isTrue);
    expect(models[2].vision, isFalse);
    expect(models[2].reasoning, isFalse);
  });

  test('调用后更改 provider 不影响此次请求地址、Key 和能力来源', () async {
    final provider = _provider();
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://api.deepseek.com/models');
      expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
      provider.apiHost = 'https://changed.example/v1';
      provider.apiKey = 'other-key';
      provider.type = 'anthropic';
      return _json({
        'data': [
          {'id': 'unusual-model'}
        ]
      });
    });
    final fetching = AiProviderApi(client: client).fetchModels(provider);
    provider.apiKey = 'mutated-after-call';
    final models = await fetching;
    expect(models.single.tool, isTrue);
  });

  test('余额保留多币种及全部小数位', () async {
    final api = AiProviderApi(client: MockClient((request) async {
      expect(request.url.toString(), 'https://api.deepseek.com/user/balance');
      expect(request.headers['Authorization'], 'Bearer synthetic-test-key');
      return _json({
        'is_available': true,
        'balance_infos': [
          _balanceRow(),
          _balanceRow(currency: 'USD', total: '1234567890.123456789')
        ],
      });
    }));
    final balance = await api.fetchDeepSeekBalance(_provider());
    expect(balance.isAvailable, isTrue);
    expect(balance.balances.map((item) => item.currency), ['CNY', 'USD']);
    expect(balance.balances.first.totalBalance, '1.00000001');
    expect(balance.balances.first.grantedBalance, '0.00000001');
    expect(balance.balances.first.toppedUpBalance, '1.00000000');
    expect(balance.balances.last.totalBalance, '1234567890.123456789');
  });

  test('不可用账号的零余额也返回正常结果', () async {
    final api = AiProviderApi(
        client: MockClient((request) async => _json({
              'is_available': false,
              'balance_infos': [
                {
                  'currency': 'CNY',
                  'total_balance': '0.00',
                  'granted_balance': '0.00',
                  'topped_up_balance': '0.00',
                }
              ],
            })));
    final result = await api.fetchDeepSeekBalance(_provider());
    expect(result.isAvailable, isFalse);
    expect(result.balances.single.totalBalance, '0.00');
  });

  test('空 Key 和不支持的余额地址在发请求前失败', () async {
    var calls = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      calls++;
      return _json({'data': []});
    }));
    await expectLater(
        api.fetchModels(_provider(key: '  ')), throwsA(_apiError('API Key')));
    await expectLater(
        api.fetchDeepSeekBalance(_provider(host: 'https://proxy.example/v1')),
        throwsA(_apiError('官方')));
    expect(calls, 0);
  });

  test('错误 HTTP 响应和网络异常不泄露正文或 Key', () async {
    for (final status in [302, 401, 402, 403, 404, 429, 500]) {
      final api = AiProviderApi(
          client: MockClient((request) async =>
              http.Response('echo synthetic-test-key', status)));
      try {
        await api.fetchModels(_provider());
        fail('expected failure');
      } on AiProviderApiException catch (error) {
        expect(error.statusCode, status);
        expect(error.toString(), isNot(contains('synthetic-test-key')));
        expect(error.toString(), isNot(contains('echo')));
      }
    }
    final api = AiProviderApi(client: MockClient((request) async {
      throw http.ClientException('synthetic-test-key private-response');
    }));
    await expectLater(api.fetchModels(_provider()), throwsA(_apiError()));
  });

  test('拒绝无效 JSON、模型结构和超出数量上限的列表', () async {
    for (final body in [
      'invalid synthetic-test-key',
      '[]',
      jsonEncode({'data': null}),
      jsonEncode({
        'data': [1]
      }),
      jsonEncode({
        'data': [
          {'id': ''}
        ]
      }),
      jsonEncode({
        'data': [
          {'id': 123}
        ]
      }),
      jsonEncode({
        'data': List.generate(1001, (index) => {'id': 'model-$index'})
      }),
    ]) {
      final api = AiProviderApi(
          client: MockClient((request) async => http.Response(body, 200)));
      await expectLater(api.fetchModels(_provider()), throwsA(_apiError()));
    }
    final empty = await AiProviderApi(
            client: MockClient((request) async => _json({'data': []})))
        .fetchModels(_provider());
    expect(empty, isEmpty);
  });

  test('拒绝无效余额结构和浮点金额，避免悄悄损失精度', () async {
    for (final data in [
      {'is_available': 'true', 'balance_infos': []},
      {'is_available': true, 'balance_infos': {}},
      {
        'is_available': true,
        'balance_infos': [1]
      },
      {
        'is_available': true,
        'balance_infos': [
          {..._balanceRow(), 'currency': 'invalid'}
        ]
      },
      {
        'is_available': true,
        'balance_infos': [
          {..._balanceRow(), 'total_balance': 1.5}
        ]
      },
      {
        'is_available': true,
        'balance_infos': [
          {..._balanceRow(), 'total_balance': 'NaN'}
        ]
      },
    ]) {
      final api =
          AiProviderApi(client: MockClient((request) async => _json(data)));
      await expectLater(
          api.fetchDeepSeekBalance(_provider()), throwsA(_apiError('余额')));
    }
  });

  test('超过 1 MiB 的流响应取消读取', () async {
    var cancelled = false;
    final stream =
        StreamController<List<int>>(onCancel: () => cancelled = true);
    final api = AiProviderApi(client: _CallbackClient((request) async {
      scheduleMicrotask(() {
        stream.add(List.filled(1024 * 1024 + 1, 32));
      });
      return http.StreamedResponse(stream.stream, 200);
    }));
    await expectLater(api.fetchModels(_provider()), throwsA(_apiError('过大')));
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('Content-Length 超过上限时在读取前取消响应', () async {
    var cancelled = false;
    final stream =
        StreamController<List<int>>(onCancel: () => cancelled = true);
    final api = AiProviderApi(
        client: _CallbackClient((request) async => http.StreamedResponse(
              stream.stream,
              200,
              contentLength: 1024 * 1024 + 1,
            )));
    await expectLater(api.fetchModels(_provider()), throwsA(_apiError('过大')));
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('超时完成请求取消信号，并保留注入 Client 的所有权', () async {
    Future<void>? aborted;
    final client = _CallbackClient((request) {
      aborted = (request as http.Abortable).abortTrigger;
      return Completer<http.StreamedResponse>().future;
    });
    final api = AiProviderApi(
        client: client, timeout: const Duration(milliseconds: 10));
    await expectLater(api.fetchModels(_provider()), throwsA(_apiError('超时')));
    await expectLater(aborted, completes);
    expect(client.closed, isFalse);
  });

  test('调用方取消正在等待响应的请求', () async {
    final cancel = Completer<void>();
    final sent = Completer<void>();
    Future<void>? aborted;
    final api = AiProviderApi(client: _CallbackClient((request) {
      aborted = (request as http.Abortable).abortTrigger;
      sent.complete();
      return Completer<http.StreamedResponse>().future;
    }));
    final fetching = api.fetchModels(_provider(), abortTrigger: cancel.future);
    final expectation = expectLater(fetching, throwsA(_apiError('取消')));
    await sent.future;
    cancel.complete();
    await expectation;
    await expectLater(aborted, completes);
  });

  test('已完成的取消信号阻止网络请求', () async {
    var calls = 0;
    final api = AiProviderApi(client: MockClient((request) async {
      calls++;
      return _json({'data': []});
    }));
    await expectLater(
        api.fetchModels(_provider(), abortTrigger: Future.value()),
        throwsA(_apiError('取消')));
    expect(calls, 0);
  });

  test('读取响应时取消也释放流订阅', () async {
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
    final fetching = api.fetchModels(_provider(), abortTrigger: cancel.future);
    final expectation = expectLater(fetching, throwsA(_apiError('取消')));
    await received.future;
    cancel.complete();
    await expectation;
    expect(cancelled, isTrue);
    await stream.close();
  });
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
