import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/knowledge/team_knowledge.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TeamKnowledgeApi api;
  late TeamKnowledgeRepository repo;
  var member = true, archived = false, revision = 1, reversed = false;
  Map<String, dynamic> document(String uid, String title, String content) => {
        'uid': uid,
        'title': title,
        'revision': revision,
        'createdAt': 100,
        'updatedAt': 200,
        'archived': archived,
        'chunks': [
          {'seq': 0, 'pageNumber': 1, 'content': content}
        ]
      };
  http.Response response(Object data, int status) =>
      http.Response(jsonEncode({'code': 0, 'data': data}), status,
          headers: {'content-type': 'application/json; charset=utf-8'});
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    LoginSdkConfig.install(
        LoginSdkConfig.instance.copyWith(storage: HiCacheTokenStorage()));
    await LoginSdkConfig.instance.storage.writeProfile(
        token: 'synthetic-team-token',
        userName: 'synthetic',
        extras: {'accountHash': 'team-fixture'});
    member = true;
    archived = false;
    revision = 1;
    reversed = false;
    api = TeamKnowledgeApi(client: MockClient((request) async {
      expect(request.followRedirects, isFalse);
      if (!member) return response({}, 403);
      final docs = [
        document('a', '退款政策', '可在7天内申请退款。'),
        document('b', '休假政策', '每年有十天年假。')
      ];
      return response({
        'id': 'team',
        'name': '测试团队',
        'role': 'viewer',
        'documents': reversed ? docs.reversed.toList() : docs,
        'answers': []
      }, 200);
    }));
    repo = TeamKnowledgeRepository(api, 'team');
  });
  tearDown(() {
    api.close();
    LoginSdkConfig.reset();
  });
  test('限定所选团队文档，服务器返回顺序变化不会扩大提问范围', () async {
    final docs = await repo.documents();
    final refund = docs.first.id!;
    reversed = true;
    await repo.history();
    final hits = await repo.retrieve('退费期限', {refund});
    expect(hits.map((h) => h.uid), ['a']);
    expect(hits.first.content, contains('7天'));
    expect(await repo.retrieve('年假', {refund}), isEmpty);
  });
  test('发给模型前重新核对权限，旧缓存不能继续发起模型请求', () async {
    final docs = await repo.documents();
    var calls = 0;
    final assistant = KnowledgeAssistant(
        repository: repo,
        isCurrent: () => api.current,
        complete: (
            {required prompt,
            required abort,
            required isCurrent,
            required beforeDispatch}) async {
          member = false;
          await beforeDispatch();
          calls++;
          throw StateError('must not dispatch');
        });
    try {
      await expectLater(assistant.ask('退款期限', {docs.first.id!}),
          throwsA(isA<KnowledgeScopeException>()));
      expect(calls, 0);
      expect(api.valid.value, isFalse);
    } finally {
      assistant.dispose();
    }
  });
  test('检索后修订或标记失效会使原来源失效', () async {
    final docs = await repo.documents();
    final hits = await repo.retrieve('退款', {docs.first.id!});
    revision = 2;
    await expectLater(repo.verifySources({docs.first.id!}, hits),
        throwsA(isA<KnowledgeScopeException>()));
    archived = true;
    expect(await repo.documents(), isEmpty);
  });
  test('迟到的旧账号响应不能成为新账号团队数据', () async {
    api.close();
    final pending = Completer<http.Response>();
    api = TeamKnowledgeApi(client: MockClient((_) => pending.future));
    final request = api.call('GET');
    await LoginSdkConfig.instance.storage.writeProfile(
        token: 'synthetic-other',
        userName: 'other',
        extras: {'accountHash': 'other'});
    pending.complete(response([], 200));
    await expectLater(request, throwsA(isA<KnowledgeScopeException>()));
  });
  test('团队历史清空明确拒绝，不把团队历史当个人历史删除', () async {
    await expectLater(
        repo.clearHistory(), throwsA(isA<KnowledgeScopeException>()));
  });
}
