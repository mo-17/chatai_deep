import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../backup/backup_service.dart';
import '../dao/ai_catalog_dao.dart';
import '../dao/ai_settings_dao.dart';
import '../db/hi_db_manager.dart';
import '../model/ai_provider.dart';
import 'knowledge_evidence.dart';
import 'knowledge_hybrid_search.dart';

class SemanticConfig {
  final bool enabled;
  final String providerId, model, endpoint;
  final double minimumScore;
  const SemanticConfig(
      {this.enabled = false,
      this.providerId = '',
      this.model = '',
      this.endpoint = '',
      this.minimumScore = .35});
  String get signature =>
      sha256.convert(utf8.encode('$providerId\n$endpoint\n$model')).toString();
  Map<String, Object> toRow() => {
        'id': 1,
        'enabled': enabled ? 1 : 0,
        'providerId': providerId,
        'model': model,
        'endpoint': endpoint,
        'minimumScore': minimumScore
      };
}

class SemanticEmbeddingClient {
  final Uri endpoint;
  final String model, key;
  final bool Function() isCurrent;
  final http.Client Function() clientFactory;
  SemanticEmbeddingClient(
      {required this.endpoint,
      required this.model,
      required this.key,
      required this.isCurrent,
      http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;
  static Uri endpointFor(AiProvider provider) {
    final completion = Uri.parse(provider.chatCompletionsUrl);
    if (!['http', 'https'].contains(completion.scheme) ||
        completion.host.isEmpty ||
        completion.userInfo.isNotEmpty ||
        completion.hasQuery ||
        completion.hasFragment ||
        !completion.path.endsWith('/chat/completions')) {
      throw const FormatException('当前服务商地址不能用于 Embedding，请检查 AI 服务地址');
    }
    return completion.replace(
        path: completion.path
            .replaceFirst(RegExp(r'/chat/completions$'), '/embeddings'));
  }

  factory SemanticEmbeddingClient.capture(SemanticConfig config,
      {bool Function()? additionalCurrent}) {
    final identity = AiCatalogIdentity.capture(),
        restore = BackupService.restoreTick.value;
    final provider = AISettingsDao.load()
        .providers
        .where((p) => p.id == config.providerId)
        .firstOrNull
        ?.copy();
    if (provider == null ||
        !provider.enabled ||
        provider.apiKey.isEmpty ||
        endpointFor(provider).toString() != config.endpoint) {
      throw const FormatException('Embedding 服务商已变化或未配置密钥，请重新确认语义检索设置');
    }
    return SemanticEmbeddingClient(
        endpoint: Uri.parse(config.endpoint),
        model: config.model,
        key: provider.apiKey,
        isCurrent: () {
          if (!identity.current ||
              restore != BackupService.restoreTick.value ||
              additionalCurrent?.call() == false) {
            return false;
          }
          final current = AISettingsDao.load()
              .providers
              .where((p) => p.id == config.providerId)
              .firstOrNull;
          return current != null &&
              current.enabled &&
              current.apiKey == provider.apiKey &&
              current.apiHost == provider.apiHost;
        });
  }
  Future<List<List<double>>> embed(List<String> inputs) async {
    if (inputs.isEmpty ||
        inputs.length > 4 ||
        inputs.any((s) => s.isEmpty || s.length > 3000) ||
        inputs.join().length > 12000) {
      throw const FormatException('Embedding 输入超限，请减少资料范围');
    }
    final client = clientFactory(), abort = Completer<void>();
    void check() {
      if (!isCurrent()) throw const FormatException('账号或 Embedding 配置已变化');
    }

    final watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isCurrent() && !abort.isCompleted) abort.complete();
    });
    final timeout = Timer(const Duration(seconds: 30), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      check();
      final request =
          http.AbortableRequest('POST', endpoint, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json'
            })
            ..body = jsonEncode(
                {'model': model, 'input': inputs, 'encoding_format': 'float'});
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw const FormatException('Embedding 请求未成功，请检查模型、密钥或服务限额');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('Embedding 响应过大');
        }
        bytes.add(chunk);
      }
      check();
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (body is! Map ||
          body['data'] is! List ||
          (body['data'] as List).length != inputs.length) {
        throw const FormatException('Embedding 响应格式无效');
      }
      final output = List<List<double>?>.filled(inputs.length, null);
      int? dimensions;
      for (final row in body['data'] as List) {
        if (row is! Map || row['index'] is! int || row['embedding'] is! List) {
          throw const FormatException('Embedding 响应格式无效');
        }
        final index = row['index'] as int, vector = row['embedding'] as List;
        if (index < 0 ||
            index >= inputs.length ||
            output[index] != null ||
            vector.isEmpty ||
            vector.length > 4096 ||
            vector.any((n) => n is! num || !n.isFinite)) {
          throw const FormatException('Embedding 向量无效');
        }
        dimensions ??= vector.length;
        final values = vector.map((n) => (n as num).toDouble()).toList();
        final norm = values.fold<double>(0, (sum, n) => sum + n * n);
        if (vector.length != dimensions || !norm.isFinite || norm <= 0) {
          throw const FormatException('Embedding 维数或范数无效');
        }
        output[index] = values;
      }
      return output.cast<List<double>>();
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Embedding 连接中断或超时，请检查配置后重试');
    } finally {
      watch.cancel();
      timeout.cancel();
      client.close();
    }
  }
}

class SemanticKnowledgeIndex {
  final HiDBManager storage;
  static final changes = ValueNotifier<int>(0);
  bool lastSearchUsed = false;
  SemanticKnowledgeIndex._(this.storage);
  static Future<SemanticKnowledgeIndex> create(HiDBManager storage) async {
    await storage.db
        .execute('''CREATE TABLE IF NOT EXISTS tb_kb_semantic_config (
      id INTEGER PRIMARY KEY, enabled INTEGER NOT NULL, providerId TEXT NOT NULL,
      model TEXT NOT NULL, endpoint TEXT NOT NULL, minimumScore REAL NOT NULL)''');
    await storage.db
        .execute('''CREATE TABLE IF NOT EXISTS tb_kb_semantic_index (
      chunkId INTEGER NOT NULL, signature TEXT NOT NULL, digest TEXT NOT NULL,
      vector BLOB NOT NULL, PRIMARY KEY(chunkId,signature))''');
    return SemanticKnowledgeIndex._(storage);
  }

  Future<SemanticConfig> config() async {
    final rows = await storage.db.query('tb_kb_semantic_config', where: 'id=1');
    if (rows.isEmpty) return const SemanticConfig();
    final row = rows.single;
    return SemanticConfig(
        enabled: row['enabled'] == 1,
        providerId: row['providerId'] as String,
        model: row['model'] as String,
        endpoint: row['endpoint'] as String,
        minimumScore: (row['minimumScore'] as num).toDouble());
  }

  Future<void> configure(SemanticConfig value, void Function() verify) async {
    if (!value.minimumScore.isFinite ||
        value.minimumScore < 0 ||
        value.minimumScore > 1 ||
        (value.enabled &&
            (value.model.trim().isEmpty ||
                value.model.length > 200 ||
                value.providerId.isEmpty ||
                value.endpoint.length > 2048 ||
                !value.minimumScore.isFinite ||
                value.minimumScore < 0 ||
                value.minimumScore > 1))) {
      throw const FormatException('请填写有效的 Embedding 模型和阈值');
    }
    await storage.db.transaction((tx) async {
      verify();
      await tx.delete('tb_kb_semantic_config');
      await tx.insert('tb_kb_semantic_config', value.toRow());
      verify();
    });
    changes.value++;
  }

  Future<int> indexed() async {
    final active = await config();
    return (await storage.db.rawQuery(
            'SELECT COUNT(*) AS count FROM tb_kb_semantic_index i JOIN tb_kb_chunk c ON c.id=i.chunkId WHERE i.signature=?',
            [active.signature]))
        .single['count'] as int;
  }

  Future<void> clear(void Function() verify) async {
    await storage.db.transaction((tx) async {
      verify();
      await tx.delete('tb_kb_semantic_index');
      verify();
    });
    changes.value++;
  }

  Future<void> build(Set<int> docIds,
      {required void Function() verify,
      SemanticEmbeddingClient? client,
      void Function(int, int)? onProgress}) async {
    verify();
    final active = await config(), epoch = changes.value;
    final transport = client ?? SemanticEmbeddingClient.capture(active);
    if (!active.enabled) throw const FormatException('请先确认并启用语义检索');
    if (docIds.isEmpty || docIds.length > 100) {
      throw const FormatException('请选择 1～100 篇资料');
    }
    final rows = await storage.db.rawQuery(
        'SELECT c.id,c.content,d.uid FROM tb_kb_chunk c JOIN tb_kb_doc d ON d.id=c.docId WHERE d.archived=0 AND d.id IN (${List.filled(docIds.length, '?').join(',')}) ORDER BY c.id LIMIT 5001',
        docIds.toList());
    if (rows.length > 5000) throw const FormatException('资料超过 5000 个片段，请缩小范围');
    void check() {
      verify();
      if (epoch != changes.value || !transport.isCurrent()) {
        throw const FormatException('语义检索设置已变化，索引已停止');
      }
    }

    int? dimensions;
    final existing = await storage.db.query('tb_kb_semantic_index',
        columns: ['vector'],
        where: 'signature=?',
        whereArgs: [active.signature],
        limit: 1);
    if (existing.isNotEmpty) {
      dimensions = (existing.first['vector'] as List<int>).length ~/ 4;
    }
    for (var start = 0; start < rows.length; start += 4) {
      check();
      final batch = rows.sublist(start, math.min(start + 4, rows.length));
      final vectors = await transport
          .embed(batch.map((r) => r['content'] as String).toList());
      check();
      for (final vector in vectors) {
        dimensions ??= vector.length;
        if (vector.length != dimensions) {
          throw const FormatException('模型向量维数已变化，请清除索引后重建');
        }
      }
      await storage.db.transaction((tx) async {
        check();
        await tx.rawDelete(
            'DELETE FROM tb_kb_semantic_index WHERE chunkId NOT IN (SELECT id FROM tb_kb_chunk)');
        for (var n = 0; n < batch.length; n++) {
          final row = batch[n];
          final current = await tx.rawQuery(
              'SELECT c.content,d.uid FROM tb_kb_chunk c JOIN tb_kb_doc d ON d.id=c.docId WHERE c.id=? AND d.archived=0',
              [row['id']]);
          check();
          if (current.length != 1 ||
              current.single['content'] != row['content'] ||
              current.single['uid'] != row['uid']) {
            throw const FormatException('资料已修订或删除，请重新建立索引');
          }
          final data = ByteData(vectors[n].length * 4);
          var storedNorm = 0.0;
          for (var i = 0; i < vectors[n].length; i++) {
            data.setFloat32(i * 4, vectors[n][i], Endian.little);
            if (!data.getFloat32(i * 4, Endian.little).isFinite) {
              throw const FormatException('Embedding 数值超出存储范围');
            }
            final stored = data.getFloat32(i * 4, Endian.little);
            storedNorm += stored * stored;
          }
          if (storedNorm <= 0 || !storedNorm.isFinite) {
            throw const FormatException('Embedding 数值超出存储范围');
          }
          await tx.delete('tb_kb_semantic_index',
              where: 'chunkId=? AND signature=?',
              whereArgs: [row['id'], active.signature]);
          await tx.insert('tb_kb_semantic_index', {
            'chunkId': row['id'],
            'signature': active.signature,
            'digest': sha256
                .convert(utf8.encode(row['content'] as String))
                .toString(),
            'vector': data.buffer.asUint8List()
          });
        }
        final bytes = (await tx.rawQuery(
                'SELECT COALESCE(SUM(LENGTH(vector)),0) AS bytes FROM tb_kb_semantic_index'))
            .single['bytes'] as int;
        if (bytes > 32 * 1024 * 1024) {
          throw const FormatException('语义索引超过 32 MiB，请清除旧索引或缩小资料范围');
        }
        check();
      });
      onProgress?.call(math.min(start + 4, rows.length), rows.length);
    }
  }

  Future<List<KnowledgeEvidence>> search(
      String question, List<KnowledgeEvidence> pool,
      {SemanticEmbeddingClient? client}) async {
    lastSearchUsed = false;
    final active = await config(), epoch = changes.value;
    final keyword = KnowledgeHybridSearch.search(question, pool)
        .map((hit) => hit.source)
        .toList();
    if (!active.enabled) return keyword;
    final cached = await storage.db.query('tb_kb_semantic_index',
        where: 'signature=?', whereArgs: [active.signature]);
    final sources = {for (final source in pool) source.chunkId: source};
    final usable = cached.where((row) {
      final source = sources[row['chunkId']];
      return source != null &&
          row['digest'] ==
              sha256.convert(utf8.encode(source.content)).toString();
    }).toList();
    if (usable.isEmpty) return keyword;
    final transport = client ?? SemanticEmbeddingClient.capture(active);
    final query = (await transport.embed([question])).single;
    if (epoch != changes.value || !transport.isCurrent()) {
      throw const FormatException('语义检索环境已变化');
    }
    lastSearchUsed = true;
    final semantic = <({KnowledgeEvidence source, double score})>[];
    for (final row in usable) {
      final data =
          ByteData.sublistView(Uint8List.fromList(row['vector'] as List<int>));
      if (data.lengthInBytes != query.length * 4) continue;
      var dot = 0.0, a = 0.0, b = 0.0;
      for (var i = 0; i < query.length; i++) {
        final n = data.getFloat32(i * 4, Endian.little);
        dot += n * query[i];
        a += n * n;
        b += query[i] * query[i];
      }
      final score = dot / math.sqrt(a * b);
      if (score.isFinite && score >= active.minimumScore) {
        semantic.add((source: sources[row['chunkId']]!, score: score));
      }
    }
    semantic.sort((a, b) => b.score.compareTo(a.score));
    final ranked = <int, ({KnowledgeEvidence source, double score})>{};
    for (final list in [
      keyword,
      semantic.take(12).map((hit) => hit.source).toList()
    ]) {
      for (var i = 0; i < list.length; i++) {
        final source = list[i];
        ranked[source.chunkId] = (
          source: source,
          score: (ranked[source.chunkId]?.score ?? 0) + 1 / (60 + i + 1)
        );
      }
    }
    final merged = ranked.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return merged.take(6).map((hit) => hit.source).toList();
  }
}
