import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'knowledge_evidence.dart';
import 'knowledge_hybrid_search.dart';
import 'knowledge_repository.dart';

class TeamKnowledgeApi {
  final http.Client client;
  final AiCatalogIdentity identity;
  final Uri origin;
  final Map<String, String> headers;
  final ValueNotifier<bool> valid = ValueNotifier(true);
  TeamKnowledgeApi({http.Client? client})
      : client = client ?? http.Client(),
        identity = AiCatalogIdentity.capture(),
        origin = BackendConfig.buildUri('/uapi/knowledge/teams'),
        headers = Map.of(hiHeaders());
  bool get current => identity.current && valid.value;
  Future<dynamic> call(String method,
      [String suffix = '', Object? body]) async {
    if (!current || !identity.authenticated) {
      throw const KnowledgeScopeException('团队知识库需要有效登录');
    }
    final request = http.Request(method, Uri.parse('$origin$suffix'))
      ..followRedirects = false
      ..headers.addAll({...headers, 'content-type': 'application/json'});
    if (body != null) request.body = jsonEncode(body);
    final response = await (() async =>
            http.Response.fromStream(await client.send(request)))()
        .timeout(const Duration(seconds: 20));
    if (!current) throw const KnowledgeScopeException('账号环境已变化');
    if ([401, 403, 404].contains(response.statusCode)) {
      valid.value = false;
      throw const KnowledgeScopeException('团队访问权限已变化，请重新打开');
    }
    if (response.statusCode == 409) {
      throw const KnowledgeScopeException('版本已变化，请刷新并比较后重试');
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw const KnowledgeScopeException('团队请求未完成，请稍后重试');
    }
    if (response.bodyBytes.length > 8 * 1024 * 1024) {
      throw const KnowledgeScopeException('团队数据超过客户端预算');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    if (json['code'] != 0) throw const KnowledgeScopeException('团队请求未完成');
    return json['data'];
  }

  void close() {
    client.close();
    valid.dispose();
  }
}

/// 团队正文只留当前页面内存，不并入个人库/备份/同步。
class TeamKnowledgeRepository implements IKnowledgeRepository {
  final TeamKnowledgeApi api;
  final String teamId;
  Map<String, dynamic>? snapshot;
  final Map<String, int> _ids = {};
  int _idFor(String uid) => _ids.putIfAbsent(uid, () => _ids.length + 1);
  TeamKnowledgeRepository(this.api, this.teamId);
  Future<Map<String, dynamic>> refresh() async {
    final next =
        (await api.call('GET', '/$teamId') as Map).cast<String, dynamic>();
    snapshot = next;
    return next;
  }

  List<Map<String, dynamic>> get _docs => [
        for (final raw in snapshot?['documents'] as List? ?? [])
          (raw as Map).cast<String, dynamic>()
      ];
  @override
  Future<List<KnowledgeDoc>> documents() async {
    await refresh();
    return [
      for (var i = 0; i < _docs.length; i++)
        if (_docs[i]['archived'] != true)
          KnowledgeDoc(
              id: _idFor(_docs[i]['uid'] as String),
              uid: _docs[i]['uid'] as String,
              title: _docs[i]['title'] as String,
              revision: _docs[i]['revision'] as int,
              chunkCount: (_docs[i]['chunks'] as List).length,
              createdAt: _docs[i]['createdAt'] as int)
    ];
  }

  @override
  Future<List<KnowledgeEvidence>> retrieve(
      String question, Set<int> ids) async {
    if (ids.isEmpty || ids.length > 100) {
      throw const KnowledgeScopeException('请选择团队资料');
    }
    final previous = _docs;
    final chosen = [
      for (final doc in previous)
        if (ids.contains(_idFor(doc['uid'] as String))) doc
    ];
    await refresh();
    if (chosen.length != ids.length ||
        chosen.any((old) => !_docs.any((d) =>
            d['uid'] == old['uid'] &&
            d['revision'] == old['revision'] &&
            d['archived'] != true))) {
      throw const KnowledgeScopeException('团队资料已变化，请刷新后重新选择');
    }
    final sources = <KnowledgeEvidence>[];
    for (final doc in chosen) {
      final id = _idFor(doc['uid'] as String);
      for (final raw in doc['chunks'] as List) {
        sources.add(KnowledgeEvidence(
            docId: id,
            chunkId: raw['seq'] + 1,
            seq: raw['seq'],
            importedAt: doc['createdAt'],
            title: doc['title'],
            content: raw['content'],
            uid: doc['uid'],
            revision: doc['revision'],
            pageNumber: raw['pageNumber']));
      }
    }
    return KnowledgeHybridSearch.search(question, sources)
        .map((h) => h.source)
        .toList();
  }

  @override
  Future<void> verifySources(
      Set<int> ids, List<KnowledgeEvidence> sources) async {
    await refresh();
    for (final source in sources) {
      final docs = _docs.where((d) =>
          d['uid'] == source.uid &&
          d['revision'] == source.revision &&
          d['archived'] != true);
      if (docs.length != 1 ||
          !(docs.single['chunks'] as List).any((c) =>
              c['seq'] == source.seq && c['content'] == source.content)) {
        throw const KnowledgeScopeException('团队原文已变化，本次提问已停止');
      }
    }
  }

  @override
  Future<KnowledgeAnswer> save(
      KnowledgeAnswer answer, Set<int> ids, bool Function() isCurrent) async {
    if (!isCurrent()) throw const KnowledgeScopeException('团队提问已停止');
    if (answer.status != KnowledgeAnswerStatus.cited) return answer;
    await api.call('POST', '/$teamId/answers', answer.toJson());
    if (!isCurrent()) throw const KnowledgeScopeException('团队提问已停止');
    return answer;
  }

  @override
  Future<List<KnowledgeAnswer>> history({int? beforeId}) async {
    if (beforeId != null) return [];
    await refresh();
    return [
      for (final raw in snapshot?['answers'] as List? ?? [])
        KnowledgeAnswer.fromJson((raw as Map).cast<String, dynamic>())
    ];
  }

  @override
  Future<bool> sourceUnchanged(KnowledgeEvidence source) async {
    try {
      await verifySources({source.docId}, [source]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> clearHistory() async {
    throw const KnowledgeScopeException('团队问答历史由团队共同保留，不能通过个人清空操作删除');
  }
}
