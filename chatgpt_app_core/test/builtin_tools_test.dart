import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/safe_url_fetcher.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// L2（内置纯 Dart 工具）验收：算术求值、HTML 提取、各工具 execute、注册表登记。
void main() {
  group('Arithmetic.eval', () {
    test('四则运算与优先级', () {
      expect(Arithmetic.eval('1+2*3'), 7);
      expect(Arithmetic.eval('(1+2)*3'), 9);
      expect(Arithmetic.eval('10-2-3'), 5); // 左结合
      expect(Arithmetic.eval('2*3+4*5'), 26);
    });

    test('乘方右结合 + 一元负号', () {
      expect(Arithmetic.eval('2^3^2'), 512); // 2^(3^2)=2^9
      expect(Arithmetic.eval('-2^2'), -4); // 一元负作用于乘方结果
      expect(Arithmetic.eval('(-2)^2'), 4);
      expect(Arithmetic.eval('2^-1'), 0.5);
    });

    test('小数、取模、除法', () {
      expect(Arithmetic.eval('7%3'), 1);
      expect(Arithmetic.eval('1/4'), 0.25);
      expect(Arithmetic.eval('0.1+0.2'), closeTo(0.3, 1e-9));
    });

    test('非法输入抛 FormatException', () {
      expect(() => Arithmetic.eval('1+'), throwsFormatException);
      expect(() => Arithmetic.eval('1/0'), throwsFormatException);
      expect(() => Arithmetic.eval('(1+2'), throwsFormatException);
      expect(() => Arithmetic.eval('1 2'), throwsFormatException);
      expect(() => Arithmetic.eval('abc'), throwsFormatException);
    });
  });

  group('HtmlText.extract', () {
    test('去标签、剔除 script/style、解码实体、压缩空白', () {
      const html = '<html><head><style>.x{color:red}</style>'
          '<script>var a=1;</script></head><body>'
          '<h1>标题</h1><p>第一段&nbsp;含&amp;符号</p>'
          '<p>第二段<br>换行</p></body></html>';
      final text = HtmlText.extract(html);
      expect(text, contains('标题'));
      expect(text, contains('第一段 含&符号'));
      expect(text, contains('第二段'));
      expect(text, isNot(contains('color:red'))); // style 被剔除
      expect(text, isNot(contains('var a'))); // script 被剔除
      expect(text, isNot(contains('<'))); // 标签清掉
    });
  });

  group('工具 execute', () {
    test('calculator：正常计算与友好报错', () async {
      final tool = BuiltinTools.calculator();
      final ok = await tool.execute({'expression': '(3+4)*2'});
      expect(ok.content, contains('14'));
      final bad = await tool.execute({'expression': '1/0'});
      expect(bad.content, contains('无法计算'));
      final empty = await tool.execute({'expression': ''});
      expect(empty.content, contains('缺少'));
    });

    test('datetime：返回可解析的 JSON 含 date/weekday', () async {
      final out = await BuiltinTools.dateTime().execute({});
      final json = jsonDecode(out.content) as Map<String, dynamic>;
      expect(json['date'], matches(r'^\d{4}-\d{2}-\d{2}$'));
      expect(json['weekday'], startsWith('星期'));
    });

    test('fetch_url：非法 URL 直接报错（不发请求）', () async {
      final out = await BuiltinTools.fetchUrl().execute({'url': 'not a url'});
      expect(out.content, contains('不是有效的 http/https 地址'));
    });

    test('fetch_url：拒绝 loopback/private 且不把响应交给模型', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('internal-secret', 200);
      });
      final out = await BuiltinTools.fetchUrl(client: client).execute(
        {'url': 'http://127.0.0.1/latest/meta-data'},
      );
      expect(out.content, contains('拒绝访问'));
      expect(out.content, isNot(contains('internal-secret')));
      expect(requests, 0);
    });

    test('fetch_url：拒绝 IPv6 本机/映射地址和非标准端口', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('internal-secret', 200);
      });
      final tool = BuiltinTools.fetchUrl(
        client: client,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
      );

      for (final url in [
        'http://[::1]/',
        'https://[::ffff:127.0.0.1]/',
        'https://example.com:8443/',
      ]) {
        final out = await tool.execute({'url': url});
        expect(out.content, anyOf(contains('拒绝访问'), contains('标准')));
        expect(out.content, isNot(contains('internal-secret')));
      }
      expect(requests, 0);
    });

    test('fetch_url：DNS 混入私网地址时整体拒绝（防 rebinding）', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('should-not-run', 200);
      });
      final out = await BuiltinTools.fetchUrl(
        client: client,
        resolver: (_) async => [
          InternetAddress('93.184.216.34'),
          InternetAddress('10.0.0.8'),
        ],
      ).execute({'url': 'https://example.com/'});
      expect(out.content, contains('拒绝访问'));
      expect(requests, 0);
    });

    test('fetch_url：每一跳重验，公开 URL 不能重定向到 metadata', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(
          '',
          302,
          headers: {'location': 'http://169.254.169.254/latest/meta-data'},
        );
      });
      final out = await BuiltinTools.fetchUrl(
        client: client,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
      ).execute({'url': 'https://example.com/start'});
      expect(out.content, contains('拒绝访问'));
      expect(requests, 1);
    });

    test('fetch_url：流式响应超过预算即停止，不进入 HTML 解码', () async {
      final client = _StreamingClient(
        chunks: [
          List<int>.filled(SafeUrlFetcher.maxBodyBytes, 65),
          const [66],
        ],
      );
      final out = await BuiltinTools.fetchUrl(
        client: client,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
      ).execute({'url': 'https://example.com/large'});
      expect(out.content, contains('响应正文超过安全上限'));
    });

    test('fetch_url：合法公网 HTML 仍能提取正文', () async {
      final client = MockClient((_) async => http.Response(
            '<html><body>Hello <b>public web</b></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ));
      final out = await BuiltinTools.fetchUrl(
        client: client,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
      ).execute({'url': 'https://example.com/article'});
      expect(out.content, contains('Hello public web'));
    });
  });

  group('ToolRegistry 登记 L2 工具', () {
    test('catalog 含计算器/日期时间/网页抓取，且无需 key', () {
      final ids = ToolRegistry.catalog.map((d) => d.id).toSet();
      expect(
          ids.containsAll(
              {'calculator', 'datetime', 'fetch_url', 'web_search'}),
          isTrue);
      final s = AISettings.defaults(); // 无搜索 key
      expect(ToolRegistry.isAvailable(s, 'calculator'), isTrue);
      expect(ToolRegistry.isAvailable(s, 'datetime'), isTrue);
      expect(ToolRegistry.isAvailable(s, 'fetch_url'), isTrue);
      expect(ToolRegistry.isAvailable(s, 'web_search'), isFalse);
    });

    test('fromAssistant 按 toolIds 装配 L2 工具（无需 key）', () {
      final r = ToolRegistry.fromAssistant(
          AISettings.defaults(), const ['calculator', 'datetime', 'fetch_url']);
      expect(r.byName('calculator'), isNotNull);
      expect(r.byName('datetime'), isNotNull);
      expect(r.byName('fetch_url'), isNotNull);
      expect(r.byName('web_search'), isNull); // 未绑定 + 未配置
    });
  });
}

class _StreamingClient extends http.BaseClient {
  final List<List<int>> chunks;

  _StreamingClient({required this.chunks});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks),
        200,
        headers: {'content-type': 'text/html'},
      );
}
