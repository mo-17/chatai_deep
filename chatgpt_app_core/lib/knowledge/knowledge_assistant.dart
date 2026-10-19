import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'knowledge_evidence.dart';
import 'knowledge_repository.dart';

class KnowledgeModelResult {
  final String model;
  final ChatCompletionResult completion;
  const KnowledgeModelResult(this.model, this.completion);
}

typedef KnowledgeCompletion = Future<KnowledgeModelResult> Function(
    {required String prompt,
    required Future<void> abort,
    required bool Function() isCurrent,
    required Future<void> Function() beforeDispatch});

class KnowledgeAssistant {
  final IKnowledgeRepository repository;
  final KnowledgeCompletion complete;
  final bool Function() isCurrent;
  int _epoch = 0;
  bool _busy = false, _disposed = false;
  Completer<void>? _abort;
  KnowledgeAssistant(
      {required this.repository,
      required this.complete,
      required this.isCurrent});
  bool get busy => _busy;

  void cancel() {
    _epoch++;
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  void dispose() {
    _disposed = true;
    cancel();
  }

  Future<KnowledgeAnswer> ask(String question, Set<int> docIds) async {
    if (_busy) throw const KnowledgeScopeException('请先等待或停止当前提问');
    final q = question.trim();
    if (q.isEmpty || q.length > 1000) {
      throw const KnowledgeScopeException('请输入 1～1000 字的问题');
    }
    final ids = Set<int>.unmodifiable(docIds);
    final epoch = ++_epoch;
    final abort = _abort = Completer<void>();
    bool current() => !_disposed && epoch == _epoch && isCurrent();
    void check() {
      if (!current()) throw const KnowledgeScopeException('提问已停止或会话环境已变化');
    }

    _busy = true;
    try {
      check();
      final sources = await repository.retrieve(q, ids);
      check();
      if (sources.any((s) => s.content.length > 3000)) {
        throw const KnowledgeScopeException('资料片段过大，请重新导入后提问');
      }
      final createdAt = DateTime.now().millisecondsSinceEpoch;
      KnowledgeAnswer answer;
      if (sources.isEmpty) {
        answer = KnowledgeAnswer(
            question: q,
            model: '',
            createdAt: createdAt,
            status: KnowledgeAnswerStatus.insufficient);
      } else {
        Future<void> guard() async {
          check();
          await repository.verifySources(ids, sources);
          check();
        }

        final prompt = jsonEncode({
          'question': q,
          'sources': [
            for (final s in sources)
              {'id': s.key, 'title': s.title, 'content': s.content}
          ]
        });
        final response = await Future.any([
          complete(
              prompt: prompt,
              abort: abort.future,
              isCurrent: current,
              beforeDispatch: guard),
          abort.future.then<KnowledgeModelResult>(
              (_) => throw const KnowledgeScopeException('本次提问已停止')),
        ]).timeout(const Duration(minutes: 2), onTimeout: () {
          cancel();
          throw const KnowledgeScopeException('回答超时，已停止本轮；请检查网络后重试');
        });
        check();
        await guard();
        final claims = KnowledgeAnswerVerifier.verify(
            response.completion.content ?? '', sources);
        answer = KnowledgeAnswer(
            question: q,
            model: response.model,
            createdAt: createdAt,
            status: claims == null
                ? KnowledgeAnswerStatus.rejected
                : claims.isEmpty
                    ? KnowledgeAnswerStatus.insufficient
                    : KnowledgeAnswerStatus.cited,
            claims: claims ?? const [],
            sources: sources);
      }
      check();
      return await repository.save(answer, ids, current);
    } finally {
      if (identical(_abort, abort)) _busy = false;
    }
  }
}
