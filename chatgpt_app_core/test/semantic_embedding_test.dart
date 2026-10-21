import 'dart:convert';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_hybrid_search.dart';
import 'package:chatgpt_app_core/knowledge/semantic_embedding.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late HiDBManager storage;
  late KnowledgeDao knowledge;
  late SemanticKnowledgeIndex index;
  late bool current;
  late int calls;
  late Future<void> Function(List<String>) beforeReply;
  const config = SemanticConfig(
      enabled: true,
      providerId: 'test',
      model: 'embed',
      endpoint: 'https://embedding.example/v1/embeddings',
      minimumScore: .5);
  void verify() {
    if (!current) throw const FormatException('stopped');
  }

  SemanticEmbeddingClient client() => SemanticEmbeddingClient(
      endpoint: Uri.parse(config.endpoint),
      model: 'embed',
      key: 'test-key',
      isCurrent: () => current,
      clientFactory: () => MockClient((request) async {
            calls++;
            expect(request.headers['Authorization'], 'Bearer test-key');
            final body = jsonDecode(request.body) as Map;
            expect(body['encoding_format'], 'float');
            final inputs = (body['input'] as List).cast<String>();
            await beforeReply(inputs);
            return http.Response(
                jsonEncode({
                  'data': [
                    for (var i = 0; i < inputs.length; i++)
                      {
                        'index': i,
                        'embedding':
                            inputs[i].contains('数据库') ? [0.0, 1.0] : [1.0, 0.0]
                      }
                  ]
                }),
                200);
          }));
  setUp(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    storage = HiDBManager.test(db);
    knowledge = await KnowledgeDao.create(storage);
    index = await SemanticKnowledgeIndex.create(storage);
    current = true;
    calls = 0;
    beforeReply = (_) async {};
    await index.configure(config, verify);
  });
  Future<List<KnowledgeEvidence>> sources() async {
    final rows = await storage.db.rawQuery(
        'SELECT c.*,d.uid,d.title,d.createdAt AS importedAt FROM tb_kb_chunk c JOIN tb_kb_doc d ON d.id=c.docId ORDER BY c.id');
    return rows
        .map((r) => KnowledgeEvidence(
            docId: r['docId'] as int,
            chunkId: r['id'] as int,
            seq: r['seq'] as int,
            importedAt: r['importedAt'] as int,
            title: r['title'] as String,
            content: r['content'] as String,
            uid: r['uid'] as String))
        .toList();
  }

  test('真实向量合同可命中无词项重叠资料，并按所选范围隔离', () async {
    final rain = await knowledge.addDocument('雨具', '下雨时请携带雨伞');
    final database = await knowledge.addDocument('维护', '数据库维护手册');
    final pool = await sources();
    expect(
        KnowledgeHybridSearch.search('wet climate precautions', pool), isEmpty);
    await index.build({rain!, database!}, verify: verify, client: client());
    expect(await index.indexed(), 2);
    final found =
        await index.search('wet climate precautions', pool, client: client());
    expect(found.single.docId, rain);
    expect(index.lastSearchUsed, true);
    expect(
        await index.search('wet climate precautions',
            pool.where((s) => s.docId == database).toList(),
            client: client()),
        isEmpty);
  });
  test('资料修订后旧向量失效，未命中有效索引时不发送问题', () async {
    final id = await knowledge.addDocument('资料', '原始资料');
    await index.build({id!}, verify: verify, client: client());
    await storage.db.update('tb_kb_chunk', {'content': '修订后的资料'});
    final before = calls;
    expect(
        await index.search('unrelated question', await sources(),
            client: client()),
        isEmpty);
    expect(calls, before);
    expect(index.lastSearchUsed, false);
  });
  test('索引响应返回前资料变化，不写入迟到向量', () async {
    final id = await knowledge.addDocument('资料', '原始正文');
    beforeReply = (_) async {
      await storage.db.update('tb_kb_chunk', {'content': '已修改'});
    };
    await expectLater(index.build({id!}, verify: verify, client: client()),
        throwsFormatException);
    expect(await index.indexed(), 0);
  });
  test('索引期间停止或账号变化，不写向量', () async {
    final id = await knowledge.addDocument('资料', '正文');
    beforeReply = (_) async {
      current = false;
    };
    await expectLater(index.build({id!}, verify: verify, client: client()),
        throwsFormatException);
    expect(await index.indexed(), 0);
  });
  test('模型配置改变不复用旧签名索引，清除不会删除资料', () async {
    final id = await knowledge.addDocument('资料', '正文');
    await index.build({id!}, verify: verify, client: client());
    await index.configure(
        const SemanticConfig(
            enabled: true,
            providerId: 'test',
            model: 'new-model',
            endpoint: 'https://embedding.example/v1/embeddings'),
        verify);
    expect(await index.indexed(), 0);
    final before = calls;
    await index.search('different meaning', await sources(), client: client());
    expect(calls, before);
    await index.clear(verify);
    expect((await knowledge.getDocuments()).length, 1);
  });
  test('另一账号数据库没有可复用向量，不发送其问题', () async {
    final id = await knowledge.addDocument('资料', '正文');
    await index.build({id!}, verify: verify, client: client());
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final other = HiDBManager.test(db);
    await KnowledgeDao.create(other);
    final otherIndex = await SemanticKnowledgeIndex.create(other);
    await otherIndex.configure(config, verify);
    final before = calls;
    expect(await otherIndex.search('cross account', [], client: client()),
        isEmpty);
    expect(calls, before);
  });
  test('非法向量及重定向不能作为可用结果', () async {
    for (final payload in [
      {
        'data': [
          {
            'index': 0,
            'embedding': [0, 0]
          }
        ]
      },
      {
        'data': [
          {
            'index': 1,
            'embedding': [1, 0]
          }
        ]
      },
      {
        'data': [
          {
            'index': 0,
            'embedding': [1, 'bad']
          }
        ]
      },
    ]) {
      final invalid = SemanticEmbeddingClient(
          endpoint: Uri.parse(config.endpoint),
          model: 'embed',
          key: 'key',
          isCurrent: () => true,
          clientFactory: () => MockClient(
              (request) async => http.Response(jsonEncode(payload), 200)));
      await expectLater(invalid.embed(['text']), throwsFormatException);
    }
    final redirect = SemanticEmbeddingClient(
        endpoint: Uri.parse(config.endpoint),
        model: 'embed',
        key: 'key',
        isCurrent: () => true,
        clientFactory: () => MockClient((request) async {
              expect(request.followRedirects, false);
              return http.Response('', 302,
                  headers: {'location': 'https://other.example'});
            }));
    await expectLater(redirect.embed(['text']), throwsFormatException);
  });
  test('Float32 下溢向量不会写入索引，停用配置也校验阈值', () async {
    final id = await knowledge.addDocument('资料', '正文');
    final tiny = SemanticEmbeddingClient(
        endpoint: Uri.parse(config.endpoint),
        model: 'embed',
        key: 'key',
        isCurrent: () => true,
        clientFactory: () => MockClient((request) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'index': 0,
                  'embedding': [1e-50, 1e-50]
                }
              ]
            }),
            200)));
    await expectLater(index.build({id!}, verify: verify, client: tiny),
        throwsFormatException);
    expect(await index.indexed(), 0);
    await expectLater(
        index.configure(const SemanticConfig(minimumScore: double.nan), verify),
        throwsFormatException);
  });
  test('沿用服务商 URL 规则推导 embeddings 端点，不接受凭据及查询 URL', () {
    final provider = AiProvider(
        id: 'test',
        type: 'openai',
        name: 'test',
        apiHost: 'https://embedding.example/custom#');
    expect(SemanticEmbeddingClient.endpointFor(provider).toString(),
        'https://embedding.example/custom/embeddings');
    provider.apiHost = 'https://user:secret@embedding.example';
    expect(() => SemanticEmbeddingClient.endpointFor(provider),
        throwsFormatException);
  });
}
