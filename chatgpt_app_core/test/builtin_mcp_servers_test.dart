import 'package:chatgpt_app_core/data/builtin_mcp_servers.dart';
import 'package:flutter_test/flutter_test.dart';

/// MCP 服务商店静态目录的健全性。
void main() {
  test('每条目字段完整、id 全局唯一', () {
    final ids = <String>{};
    for (final e in McpStore.all) {
      expect(e.id, isNotEmpty);
      expect(ids.add(e.id), isTrue, reason: 'id 重复: ${e.id}');
      expect(e.name, isNotEmpty);
      if (e.isHttp) {
        expect(e.url, isNotEmpty, reason: '${e.id} 是 http 但缺 url');
      } else {
        expect(e.command, isNotEmpty, reason: '${e.id} 是 stdio 但缺 command');
        expect(e.args, isNotEmpty, reason: '${e.id} 是 stdio 但缺 args');
      }
    }
  });

  test('httpEntries 仅含 HTTP 且都可直连添加', () {
    expect(McpStore.httpEntries, isNotEmpty);
    for (final e in McpStore.httpEntries) {
      expect(e.isHttp, isTrue);
      expect(e.directAddable, isTrue);
      expect(e.access, isNot(McpAccessKind.externalEntry));
    }
  });

  test('grouped(onlyHttp:true) 过滤掉所有 stdio 条目，且保留外部入口', () {
    final httpGrouped = McpStore.grouped(onlyHttp: true);
    expect(httpGrouped, isNotEmpty);
    for (final list in httpGrouped.values) {
      for (final e in list) {
        expect(e.isStdio, isFalse);
      }
    }
    expect(
        httpGrouped.values
            .expand((e) => e)
            .where((e) => e.access == McpAccessKind.externalEntry),
        isNotEmpty);
    // 全量分组里应当还包含 stdio（官方本地）条目。
    expect(McpStore.all.any((e) => e.isStdio), isTrue);
  });

  test('OAuth / 高权限服务只作为入口展示，不进入直连列表', () {
    final external = McpStore.all
        .where((e) => e.access == McpAccessKind.externalEntry)
        .toList();
    expect(external.map((e) => e.id),
        containsAll(['github_remote', 'notion_remote', 'stripe_remote']));
    for (final e in external) {
      expect(e.isHttp, isTrue);
      expect(e.directAddable, isFalse);
      expect(McpStore.httpEntries.any((x) => x.id == e.id), isFalse);
      expect(e.homepage, isNotEmpty);
    }
  });

  test('toServerConfig 透传 id / name / url', () {
    final e = McpStore.httpEntries.first;
    final cfg = e.toServerConfig();
    expect(cfg.id, e.id);
    expect(cfg.name, e.name);
    expect(cfg.url, e.url);
  });
}
