import 'dart:math';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'knowledge_evidence.dart';

class KnowledgeRetrievalHit {
  final KnowledgeEvidence source;
  final double keywordScore, vectorScore, rankScore;
  const KnowledgeRetrievalHit(
      this.source, this.keywordScore, this.vectorScore, this.rankScore);
}

/// BM25 + 本地词项向量的倒数排名融合；分数是排序依据，不是置信度。
class KnowledgeHybridSearch {
  static const synonyms = [
    ['退款', '退费', '退钱', 'refund', 'refunds'],
    ['退货', '退回', 'return', 'returns'],
    ['期限', '截止', '时限', '几天', '多久', 'deadline', 'period'],
    ['费用', '收费', '价格', '多少钱', 'price', 'cost', 'fee'],
    ['报销', 'reimburse', 'reimbursement'],
    ['请假', '休假', '年假', 'leave', 'vacation'],
    ['部署', '发布', '上线', 'deploy', 'deployment'],
    ['账号', '账户', 'account'],
  ];
  static Set<String> expanded(String query) {
    final terms = KnowledgeEvidenceSearch.terms(query);
    for (final group in synonyms) {
      if (group.any((s) => query.toLowerCase().contains(s))) {
        for (final word in group) {
          terms.addAll(KnowledgeEvidenceSearch.terms(word));
        }
      }
    }
    return terms;
  }

  static List<KnowledgeRetrievalHit> search(
      String query, List<KnowledgeEvidence> docs,
      {int limit = 6}) {
    if (docs.isEmpty) return [];
    final q = expanded(query);
    if (q.isEmpty) return [];
    final tokens = {
      for (final d in docs) d.key: KnowledgeEvidenceSearch.terms(d.content)
    };
    final avg =
        tokens.values.fold<int>(0, (a, b) => a + b.length) / docs.length;
    final df = {
      for (final t in q) t: tokens.values.where((v) => v.contains(t)).length
    };
    final qv = LightweightVectorRag.vectorOf(q.join(' '));
    final scores = <(KnowledgeEvidence, double, double)>[];
    for (final d in docs) {
      final terms = tokens[d.key]!;
      // 向量相似性不可凭空引入只有标题匹配的片段。
      if (!q.any(terms.contains)) continue;
      var bm25 = 0.0;
      for (final t in q) {
        if (!terms.contains(t)) continue;
        final tf = RegExp(RegExp.escape(t), caseSensitive: false)
            .allMatches(d.content)
            .length;
        final idf = log(1 + (docs.length - df[t]! + .5) / (df[t]! + .5));
        bm25 += idf *
            (tf * 2.2) /
            (tf + 1.2 * (.25 + .75 * terms.length / max(1, avg)));
        if (d.title.toLowerCase().contains(t)) bm25 += idf * .15;
      }
      final vector = LightweightVectorRag.cosine(
          qv, LightweightVectorRag.vectorOf(d.content));
      scores.add((d, bm25, vector));
    }
    final keyword = [...scores]..sort((a, b) => b.$2.compareTo(a.$2));
    final vector = [...scores]..sort((a, b) => b.$3.compareTo(a.$3));
    final kr = {
      for (var i = 0; i < keyword.length; i++) keyword[i].$1.key: i + 1
    };
    final vr = {
      for (var i = 0; i < vector.length; i++) vector[i].$1.key: i + 1
    };
    final result = [
      for (final s in scores)
        KnowledgeRetrievalHit(s.$1, s.$2, s.$3,
            1 / (60 + kr[s.$1.key]!) + 1 / (60 + vr[s.$1.key]!))
    ]..sort((a, b) {
        final c = b.rankScore.compareTo(a.rankScore);
        return c == 0 ? a.source.chunkId.compareTo(b.source.chunkId) : c;
      });
    return result.take(limit).toList();
  }
}
