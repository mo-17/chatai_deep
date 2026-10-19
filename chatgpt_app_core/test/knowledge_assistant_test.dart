import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String supported(String key,
        {String quote = '7 天内可申请退款。', String text = '退款期限为7天。'}) =>
    jsonEncode({
      'status': 'supported',
      'claims': [
        {
          'text': text,
          'evidence': [
            {'source': key, 'quote': quote}
          ]
        }
      ]
    });

void main() {
  const source = KnowledgeEvidence(
      docId: 1,
      chunkId: 2,
      seq: 0,
      importedAt: 100,
      title: '政策',
      content: '7 天内可申请退款。运费由买家承担。');
  group('原文引用核验', () {
    test('接受已存在来源和逐字引文，兼容 json fence', () {
      final raw = supported(source.key);
      expect(KnowledgeAnswerVerifier.verify(raw, [source])!.single.text,
          contains('7天'));
      expect(KnowledgeAnswerVerifier.verify('```json\n$raw\n```', [source]),
          hasLength(1));
    });
    for (final entry in <String, String>{
      '伪造来源': supported('D900C900'),
      '引文改写': supported(source.key, quote: '30 天内可申请退款。'),
      '引文拼接': supported(source.key, quote: '7 天内…买家承担。'),
      '引文过短': supported(source.key, quote: '7 天'),
      '无结构正文': '这是无来源的答案',
      '无引用结论': jsonEncode({
        'status': 'supported',
        'claims': [
          {'text': '退款', 'evidence': []}
        ]
      }),
      '来源不足却输出结论': jsonEncode({
        'status': 'insufficient',
        'claims': [
          {'text': 'x'}
        ]
      }),
    }.entries) {
      test(
          '拒绝${entry.key}',
          () => expect(
              KnowledgeAnswerVerifier.verify(entry.value, [source]), isNull));
    }
    test(
        '明确缺少资料不当作错误',
        () => expect(
            KnowledgeAnswerVerifier.verify(
                '{"status":"insufficient","claims":[]}', [source]),
            isEmpty));
    test('一个无效引文会拒绝整条回答，不展示部分未核验正文', () {
      final json = jsonDecode(supported(source.key));
      json['claims'].add({
        'text': '凭空补齐',
        'evidence': [
          {'source': 'fake', 'quote': '胡编乱造'}
        ]
      });
      expect(
          KnowledgeAnswerVerifier.verify(jsonEncode(json), [source]), isNull);
    });
    test('同名不同文档不能互相冒充，定位及正文进入摘要', () {
      const other = KnowledgeEvidence(
          docId: 3,
          chunkId: 4,
          seq: 0,
          importedAt: 100,
          title: '政策',
          content: '30 天内可申请退款。');
      expect(other.digest, isNot(source.digest));
      expect(
          KnowledgeAnswerVerifier.verify(supported(other.key), [source, other]),
          isNull);
    });
    test('检索自然中文与英文，空问题及不相关正文不命中', () {
      const english = KnowledgeEvidence(
          docId: 3,
          chunkId: 4,
          seq: 0,
          importedAt: 1,
          title: 'Handbook',
          content: 'Refund requests must arrive within seven days.');
      expect(KnowledgeEvidenceSearch.rank('退款期限是什么', [source, english]).first,
          source);
      expect(
          KnowledgeEvidenceSearch.rank(
              'What is the refund deadline?', [source, english]).first,
          english);
      expect(KnowledgeEvidenceSearch.rank('量子物理', [source, english]), isEmpty);
      expect(KnowledgeEvidenceSearch.rank('请问一下', [source, english]), isEmpty);
    });
  });

  group('真实 SQLite 与助手链路', () {
    late HiDBManager db;
    late KnowledgeRepository repo;
    late int policy, unrelated;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      db = HiDBManager.test(
          await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      repo = await KnowledgeRepository.create(db);
      policy =
          (await repo.knowledge.addDocument('退款政策', '7 天内可申请退款。运费由买家承担。'))!;
      unrelated =
          (await repo.knowledge.addDocument('其它账号不可选资料', '机密项目预算为八百万元。'))!;
    });
    tearDown(() async => db.db.close());

    KnowledgeAssistant assistant(KnowledgeCompletion complete,
            {bool Function()? current}) =>
        KnowledgeAssistant(
            repository: repo,
            complete: complete,
            isCurrent: current ?? () => true);
    test('明确空范围不回退全局；未选择文档无法泄漏到检索', () async {
      expect(repo.retrieve('预算', {}), throwsA(isA<KnowledgeScopeException>()));
      expect(await repo.retrieve('预算', {policy}), isEmpty);
      expect(await repo.retrieve('预算', {unrelated}), isNotEmpty);
    });
    test('没有匹配资料不调用 AI，结果可重开读取', () async {
      var calls = 0;
      final a = assistant((
          {required prompt,
          required abort,
          required isCurrent,
          required beforeDispatch}) async {
        calls++;
        throw StateError('must not call');
      });
      final answer = await a.ask('量子物理', {policy});
      expect(calls, 0);
      expect(answer.status, KnowledgeAnswerStatus.insufficient);
      expect((await repo.history()).single.status,
          KnowledgeAnswerStatus.insufficient);
      a.dispose();
    });
    test('超出文档/片段预算时明确拒绝，不静默截断为部分资料', () async {
      await expectLater(
          repo.retrieve('退款', {0}), throwsA(isA<KnowledgeScopeException>()));
      await expectLater(repo.retrieve('退款', {for (var i = 1; i <= 101; i++) i}),
          throwsA(isA<KnowledgeScopeException>()));
      final batch = db.db.batch();
      for (var i = 0; i < 5000; i++) {
        batch.insert(
            'tb_kb_chunk', {'docId': policy, 'seq': i + 1, 'content': '退款说明'});
      }
      await batch.commit(noResult: true);
      await expectLater(repo.retrieve('退款', {policy}),
          throwsA(isA<KnowledgeScopeException>()));
    });
    test('选择范围、结构化模型、核对引文、保存和历史恢复闭环', () async {
      final a = assistant((
          {required prompt,
          required abort,
          required isCurrent,
          required beforeDispatch}) async {
        await beforeDispatch();
        final payload = jsonDecode(prompt);
        expect(payload['sources'], hasLength(1));
        expect(prompt, isNot(contains('机密项目')));
        final key = payload['sources'][0]['id'] as String;
        return KnowledgeModelResult(
            'fixture-model', ChatCompletionResult(content: supported(key)));
      });
      final answer = await a.ask('退款期限是什么', {policy});
      expect(answer.status, KnowledgeAnswerStatus.cited);
      expect(answer.claims.single.evidence.single.source.docId, policy);
      final reopened = await KnowledgeRepository.create(db);
      final history = await reopened.history();
      expect(history.single.toJson(), answer.toJson());
      expect(await reopened.sourceUnchanged(answer.sources.single), isTrue);
      a.dispose();
    });
    test('伪造引文不能展示或存储模型原始结论', () async {
      final a = assistant((
              {required prompt,
              required abort,
              required isCurrent,
              required beforeDispatch}) async =>
          KnowledgeModelResult(
              'fixture',
              ChatCompletionResult(
                  content: supported('fake', text: 'SECRET_UNCHECKED'))));
      final answer = await a.ask('退款', {policy});
      expect(answer.status, KnowledgeAnswerStatus.rejected);
      expect(answer.claims, isEmpty);
      expect(jsonEncode((await repo.history()).single.toJson()),
          isNot(contains('SECRET_UNCHECKED')));
      a.dispose();
    });
    test('删除引用资料不抹掉历史快照，但明确标为原文已变化', () async {
      final sources = await repo.retrieve('退款', {policy});
      final answer = await repo.save(
          KnowledgeAnswer(
              question: '退款',
              model: 'fixture',
              createdAt: 1,
              status: KnowledgeAnswerStatus.cited,
              sources: sources,
              claims: KnowledgeAnswerVerifier.verify(
                  supported(sources.single.key), sources)!),
          {policy},
          () => true);
      await repo.knowledge.deleteDocument(policy);
      expect(await repo.sourceUnchanged(answer.sources.single), isFalse);
      expect((await repo.history()).single.claims.single.evidence.single.quote,
          '7 天内可申请退款。');
    });
    test('响应期间正文变化：拒绝落库并允许重试，不沿用旧证据', () async {
      final a = assistant((
          {required prompt,
          required abort,
          required isCurrent,
          required beforeDispatch}) async {
        final payload = jsonDecode(prompt);
        await db.db.update('tb_kb_chunk', {'content': '条款已更新'},
            where: 'docId = ?', whereArgs: [policy]);
        return KnowledgeModelResult(
            'fixture',
            ChatCompletionResult(
                content: supported(payload['sources'][0]['id'])));
      });
      await expectLater(
          a.ask('退款', {policy}), throwsA(isA<KnowledgeScopeException>()));
      expect(await repo.history(), isEmpty);
      expect(a.busy, isFalse);
      a.dispose();
    });
    test('停止或账号失效后，迟到回答不会保存', () async {
      final pending = Completer<KnowledgeModelResult>();
      final started = Completer<void>();
      var current = true;
      final a = assistant((
          {required prompt,
          required abort,
          required isCurrent,
          required beforeDispatch}) async {
        started.complete();
        return pending.future;
      }, current: () => current);
      final task = a.ask('退款', {policy});
      final fails = expectLater(task, throwsA(isA<KnowledgeScopeException>()));
      await started.future;
      current = false;
      a.cancel();
      pending.complete(const KnowledgeModelResult(
          'late', ChatCompletionResult(content: 'late')));
      await fails;
      expect(await repo.history(), isEmpty);
      a.dispose();
    });
    test('事务末身份失效回滚；分页和清空不删资料', () async {
      final plain = KnowledgeAnswer(
          question: '退款',
          model: '',
          createdAt: 1,
          status: KnowledgeAnswerStatus.insufficient);
      var checks = 0;
      await expectLater(repo.save(plain, {policy}, () => ++checks < 3),
          throwsA(isA<KnowledgeScopeException>()));
      expect(await repo.history(), isEmpty);
      for (var i = 0; i < 23; i++) {
        await repo.save(plain, {policy}, () => true);
      }
      final first = await repo.history();
      final next = await repo.history(beforeId: first.last.id);
      expect(first, hasLength(20));
      expect(next, hasLength(3));
      expect(
          first
              .map((a) => a.id)
              .toSet()
              .intersection(next.map((a) => a.id).toSet()),
          isEmpty);
      await repo.clearHistory();
      expect(await repo.history(), isEmpty);
      expect(await repo.documents(), hasLength(2));
    });
    test('独立账号数据库不共享资料或问答历史', () async {
      final second = HiDBManager.test(await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false)));
      final other = await KnowledgeRepository.create(second);
      expect(await other.documents(), isEmpty);
      expect(await other.history(), isEmpty);
      await expectLater(other.retrieve('退款', {policy}),
          throwsA(isA<KnowledgeScopeException>()));
      await second.db.close();
    });
  });
}
