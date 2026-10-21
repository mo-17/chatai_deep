import 'dart:async';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_runtime.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';
import 'knowledge_base_page.dart';
import 'knowledge_pdf_page.dart';
import 'knowledge_report_page.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_controller.dart';
import 'package:chatgpt_app_core/voice/voice_conversation_panel.dart';
import 'package:chatgpt_app_core/voice/speech_input.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:flutter/foundation.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_hybrid_search.dart';
import 'package:chatgpt_app_core/knowledge/semantic_embedding.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';

class KnowledgeAssistantPage extends StatefulWidget {
  final KnowledgeAssistant? assistant;
  final SpeechInput? speechInput;
  final ReadAloudService? voiceOutput;
  final String? teamName;
  final ValueListenable<bool>? access;
  const KnowledgeAssistantPage(
      {super.key,
      this.assistant,
      this.teamName,
      this.access,
      this.speechInput,
      this.voiceOutput});
  @override
  State<KnowledgeAssistantPage> createState() => _KnowledgeAssistantPageState();
}

class _KnowledgeAssistantPageState extends State<KnowledgeAssistantPage>
    with WidgetsBindingObserver {
  final _question = TextEditingController();
  late final String _account, _origin;
  late final ConversationGenerationScope _scope;
  late final AiCatalogIdentity _identity;
  KnowledgeAssistant? _assistant;
  AISettingsProvider? _settings;
  VoiceConversationController? _voice;
  List<KnowledgeDoc> _documents = [];
  List<KnowledgeAnswer> _history = [];
  Set<int> _selected = {};
  bool _loading = true, _busy = false, _background = false, _more = false;
  bool _loadingHistory = false;
  String? _error;
  int _viewEpoch = 0;
  bool get _current =>
      mounted &&
      _scope.identityCurrent &&
      _identity.current &&
      (widget.access?.value ?? true) &&
      BackendConfig.buildUri('/uapi').origin == _origin;

  @override
  void initState() {
    super.initState();
    _account = LoginDao.getAccountHash() ?? 'guest';
    _origin = BackendConfig.buildUri('/uapi').origin;
    _identity = AiCatalogIdentity.capture();
    _scope = ConversationGenerationScope(
        account: _account,
        currentAccount: () => LoginDao.getAccountHash() ?? 'guest');
    WidgetsBinding.instance.addObserver(this);
    BackendConfig.changes.addListener(_environmentChanged);
    AiCatalogIdentity.changes.addListener(_environmentChanged);
    BackupService.restoreTick.addListener(_environmentChanged);
    SemanticKnowledgeIndex.changes.addListener(_environmentChanged);
    widget.access?.addListener(_environmentChanged);
    _init();
  }

  Future<void> _init() async {
    if (mounted) setState(() => _loading = true);
    try {
      if (_assistant == null) {
        if (widget.assistant != null) {
          _assistant = widget.assistant;
        } else {
          final db = await HiDBManager.instance(dbName: _account);
          if (!mounted || !_current) return;
          final repo = await KnowledgeRepository.create(db);
          if (!mounted || !_current) return;
          _settings = context.read<AISettingsProvider>();
          _settings!.executionChanges.addListener(_environmentChanged);
          _assistant = KnowledgeAssistant(
              repository: repo,
              isCurrent: () => _current && !_background,
              complete: knowledgeRuntime(
                  repository: repo, settings: _settings!, account: _account));
        }
      }
      final docs = await _assistant!.repository.documents();
      final history = await _assistant!.repository.history();
      if (!_current) return;
      setState(() {
        _documents = docs;
        _selected = docs.take(100).map((d) => d.id!).toSet();
        _history = history;
        _more = history.length == 20;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '资料或问答历史加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _stop([String message = '已停止；不会自动重新发送']) {
    _assistant?.cancel();
    if (_voice?.active == true) unawaited(_voice!.pause(message));
    _viewEpoch++;
    if (mounted && _busy) {
      setState(() {
        _busy = false;
        _error = message;
      });
    }
  }

  void _environmentChanged() {
    _stop('账号、资料恢复或 AI 配置已变化，请确认后重新提问');
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    if (_background) _stop('已离开前台，本次提问已停止');
  }

  Future<void> _ask() async {
    if (!_current ||
        _busy ||
        _background ||
        _assistant == null ||
        _voice != null) {
      return;
    }
    final epoch = ++_viewEpoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final answer = await _assistant!.ask(_question.text, _selected);
      if (!_current || epoch != _viewEpoch) return;
      setState(() {
        _history.insert(0, answer);
        _question.clear();
      });
    } catch (error) {
      if (_current && epoch == _viewEpoch) {
        setState(() => _error = error is KnowledgeScopeException
            ? error.message
            : '本次未完成，请检查模型、登录、额度或网络后重试；不会自动重发');
      }
    } finally {
      if (mounted && epoch == _viewEpoch) setState(() => _busy = false);
    }
  }

  Future<void> _manage() async {
    _stop();
    await _endVoice();
    if (!mounted || !_current) return;
    await Navigator.push<void>(
        context, MaterialPageRoute(builder: (_) => const KnowledgeBasePage()));
    if (!_current) return;
    try {
      final docs = await _assistant!.repository.documents();
      if (!_current) return;
      setState(() {
        _documents = docs;
        _selected = _selected.intersection(docs.map((d) => d.id!).toSet());
      });
    } catch (_) {
      if (mounted) setState(() => _error = '资料刷新失败，请返回后重新打开');
    }
  }

  Future<void> _select() async {
    final chosen = Set<int>.from(_selected);
    final result = await showModalBottomSheet<Set<int>>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => SafeArea(
                child: SizedBox(
                    height: MediaQuery.sizeOf(ctx).height * .7,
                    child: Column(children: [
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('选择资料（${chosen.length}/100）',
                              style: Theme.of(ctx).textTheme.titleMedium)),
                      Expanded(
                          child: ListView(children: [
                        for (final d in _documents)
                          CheckboxListTile(
                              value: chosen.contains(d.id),
                              title: Text(d.title),
                              subtitle: Text('${d.chunkCount} 个片段'),
                              onChanged: (value) => update(() {
                                    if (value == true && chosen.length < 100) {
                                      chosen.add(d.id!);
                                    } else {
                                      chosen.remove(d.id);
                                    }
                                  }))
                      ])),
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: FilledButton(
                              onPressed: () => Navigator.pop(ctx, chosen),
                              child: const Text('使用所选资料')))
                    ])))));
    if (_current && result != null) setState(() => _selected = result);
  }

  Future<void> _loadMore() async {
    if (_history.isEmpty || _busy || _loadingHistory) return;
    final epoch = _viewEpoch;
    setState(() => _loadingHistory = true);
    try {
      final rows =
          await _assistant!.repository.history(beforeId: _history.last.id);
      if (!_current || epoch != _viewEpoch) return;
      setState(() {
        _history.addAll(rows);
        _more = rows.length == 20;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '历史加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('清空可信问答历史？'),
                content: const Text('清除这些问答与引文快照，并同步删除标记。知识库文档和文档修订历史保留。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清空'))
                ]));
    if (yes != true || !_current) return;
    _viewEpoch++;
    try {
      await _scope.stable(() => _assistant!.repository.clearHistory());
      if (_current) {
        setState(() {
          _history = [];
          _more = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '历史未能清空，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('可信知识助手'), actions: [
        if (continuousSpeechSupported)
          IconButton(
              tooltip: '资料语音问答',
              icon: Icon(_voice == null
                  ? Icons.headphones_outlined
                  : Icons.headphones),
              onPressed:
                  _loading || _busy || _assistant == null || _selected.isEmpty
                      ? null
                      : () => _voice == null ? _startVoice() : _endVoice()),
        PopupMenuButton<String>(
            tooltip: '成果导出',
            onSelected: (_) => _report(),
            itemBuilder: (_) => [
                  const PopupMenuItem(value: 'report', child: Text('导出带引用的成果'))
                ]),
        if (widget.teamName == null)
          IconButton(
              tooltip: '管理资料',
              icon: const Icon(Icons.library_books_outlined),
              onPressed: _loading || _assistant == null ? null : _manage),
        if (widget.teamName == null)
          IconButton(
              tooltip: '清空问答历史',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _loading || _busy || _voice != null || !_current
                  ? null
                  : _clear),
      ]),
      body: !_current
          ? const Center(child: Text('账号或资料环境已变化，请返回并重新打开'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  const Text('依据你的资料回答，每条结论可查看原文。'),
                  const SizedBox(height: 8),
                  Text('提问会把问题和最多 6 个检索片段发给当前 AI，使用当前服务额度。'
                      '引文逐字核对不等于结论已被独立证实。${widget.teamName == null ? '历史可随个人备份与云同步保存。' : '已核验问答将分享给团队「${widget.teamName}」。'}'),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: _busy || _voice != null || _documents.isEmpty
                          ? null
                          : _select,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(
                          '选择资料 · 已选 ${_selected.length}/${_documents.length} 篇')),
                  if (_documents.isEmpty)
                    TextButton(
                        onPressed: _assistant == null ? _init : _manage,
                        child:
                            Text(_assistant == null ? '重新加载' : '先导入文档或粘贴文本')),
                  const SizedBox(height: 12),
                  TextField(
                      key: const ValueKey('knowledge_question'),
                      controller: _question,
                      enabled: !_busy && _voice == null,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '向所选资料提问',
                          hintText: '例如：退款期限和申请条件是什么？')),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                      onPressed: _busy
                          ? _stop
                          : (_assistant == null ||
                                  _selected.isEmpty ||
                                  _voice != null
                              ? null
                              : _ask),
                      icon: Icon(_busy ? Icons.stop : Icons.search),
                      label: Text(_busy ? '停止本次提问' : '检索并回答')),
                  if (_busy)
                    const Padding(
                        padding: EdgeInsets.all(12),
                        child: LinearProgressIndicator()),
                  if (_voice != null)
                    VoiceConversationPanel(
                        controller: _voice!, onClose: () => _endVoice()),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_error!,
                            key: const ValueKey('knowledge_error'))),
                  const SizedBox(height: 20),
                  if (_assistant?.repository is KnowledgeRepository)
                    Text(
                        (_assistant!.repository as KnowledgeRepository)
                            .semanticNotice,
                        style: const TextStyle(fontSize: 12)),
                  Text('问答历史', style: Theme.of(context).textTheme.titleMedium),
                  if (_history.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('每次提问独立检索；请在问题中写清需要了解的内容。')),
                  for (final answer in _history) _answer(answer),
                  if (_more)
                    TextButton(
                        onPressed: _busy || _loadingHistory ? null : _loadMore,
                        child: const Text('加载更早问答')),
                ]));

  Widget _answer(KnowledgeAnswer answer) => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(answer.question,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
                switch (answer.status) {
                  KnowledgeAnswerStatus.cited => '引文已逐字核对 · 请结合原文判断结论',
                  KnowledgeAnswerStatus.insufficient => '所选资料中未找到足够依据',
                  KnowledgeAnswerStatus.rejected => '回答未通过引用核验，已拦截正文',
                },
                key: ValueKey('knowledge_status_${answer.id}')),
            if (answer.model.isNotEmpty)
              Text('模型：${answer.model}',
                  style: Theme.of(context).textTheme.bodySmall),
            for (var i = 0; i < answer.claims.length; i++) ...[
              const SizedBox(height: 12),
              SelectableText('${i + 1}. ${answer.claims[i].text}'),
              Wrap(spacing: 8, children: [
                for (final ref in answer.claims[i].evidence)
                  TextButton.icon(
                      onPressed: () => _source(ref.source, ref.quote,
                          question: answer.question),
                      icon: const Icon(Icons.description_outlined, size: 16),
                      label: Text(
                          '${ref.source.title} · ${ref.source.location}',
                          overflow: TextOverflow.ellipsis))
              ]),
            ],
            if (answer.status != KnowledgeAnswerStatus.cited) ...[
              const SizedBox(height: 8),
              const Text('可补充资料、缩小范围或换一种问法；不会用模型常识补齐缺失依据。'),
              if (answer.sources.isNotEmpty)
                ExpansionTile(title: const Text('查看检索片段（未作为结论证据）'), children: [
                  for (final s in answer.sources)
                    ListTile(
                        title: Text('${s.title} · ${s.location}'),
                        onTap: () =>
                            _source(s, null, question: answer.question))
                ]),
            ],
            if (answer.status == KnowledgeAnswerStatus.cited)
              TextButton.icon(
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制回答与引文'),
                  onPressed: () async {
                    final text = StringBuffer('${answer.question}\n');
                    for (final c in answer.claims) {
                      text.writeln(c.text);
                      for (final ref in c.evidence) {
                        text.writeln(
                            '来源：${ref.source.title}，${ref.source.location}，v${ref.source.revision}\n原文：${ref.quote}');
                      }
                    }
                    await Clipboard.setData(
                        ClipboardData(text: text.toString()));
                  }),
          ])));

  void _source(KnowledgeEvidence source, String? quote,
      {String question = ''}) {
    if (_voice?.active == true) unawaited(_voice!.pause('查看来源时语音已暂停'));
    final start = quote == null ? -1 : source.content.indexOf(quote);
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => ListenableBuilder(
            listenable: Listenable.merge([
              AiCatalogIdentity.changes,
              BackendConfig.changes,
              BackupService.restoreTick
            ]),
            builder: (ctx, _) => !_current
                ? const SafeArea(
                    child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('来源环境已变化，请关闭并重新打开')))
                : SafeArea(
                    child: SizedBox(
                        height: MediaQuery.sizeOf(ctx).height * .75,
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(source.title,
                                      style:
                                          Theme.of(ctx).textTheme.titleLarge),
                                  Text(
                                      '${source.location} · v${source.revision} · 导入于 ${DateTime.fromMillisecondsSinceEpoch(source.importedAt).toLocal()}'),
                                  if (question.isNotEmpty)
                                    Text(
                                        '检索命中词：${KnowledgeHybridSearch.expanded(question).where((t) => source.content.toLowerCase().contains(t)).take(12).join('、')}。匹配用于排序，不代表结论正确率。'),
                                  FutureBuilder<bool>(
                                      future: _assistant!.repository
                                          .sourceUnchanged(source),
                                      builder: (_, snapshot) =>
                                          Text(snapshot.hasError
                                              ? '当前原文状态读取失败；下方为问答时快照'
                                              : snapshot.data == null
                                                  ? '正在核对当前原文…'
                                                  : snapshot.data!
                                                      ? '当前原文与问答快照一致'
                                                      : '当前原文已删除或变化；下方为历史快照')),
                                  Text(
                                      '快照 SHA-256：${source.digest.substring(0, 16)}…'),
                                  if (source.pageNumber != null &&
                                      source.sourceAsset.isNotEmpty)
                                    TextButton.icon(
                                        icon: const Icon(
                                            Icons.picture_as_pdf_outlined),
                                        label: const Text('查看原始 PDF 页'),
                                        onPressed: () {
                                          if (!_current) return;
                                          Navigator.of(context).push(
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      KnowledgePdfPage(
                                                          source: source,
                                                          quote: quote)));
                                        }),
                                  const SizedBox(height: 16),
                                  SelectableText.rich(TextSpan(
                                      style: Theme.of(ctx).textTheme.bodyLarge,
                                      children: start < 0
                                          ? [TextSpan(text: source.content)]
                                          : [
                                              TextSpan(
                                                  text: source.content
                                                      .substring(0, start)),
                                              TextSpan(
                                                  text: quote,
                                                  style: TextStyle(
                                                      backgroundColor: Theme.of(
                                                              ctx)
                                                          .colorScheme
                                                          .secondaryContainer,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                              TextSpan(
                                                  text: source.content
                                                      .substring(start +
                                                          quote!.length)),
                                            ])),
                                ]))))));
  }

  @override
  void dispose() {
    widget.access?.removeListener(_environmentChanged);
    _voice?.dispose();
    _viewEpoch++;
    _assistant?.dispose();
    _settings?.executionChanges.removeListener(_environmentChanged);
    BackendConfig.changes.removeListener(_environmentChanged);
    AiCatalogIdentity.changes.removeListener(_environmentChanged);
    BackupService.restoreTick.removeListener(_environmentChanged);
    SemanticKnowledgeIndex.changes.removeListener(_environmentChanged);
    WidgetsBinding.instance.removeObserver(this);
    _question.dispose();
    super.dispose();
  }

  void _startVoice() {
    if (!_current || _background || _busy || _voice != null) return;
    late VoiceConversationController controller;
    controller = VoiceConversationController(
        speech: widget.speechInput ?? SystemSpeechInput(),
        voice: widget.voiceOutput ?? HybridReadAloudService(),
        isCurrent: () =>
            _current && !_background && identical(_voice, controller),
        cancelReply: () async {
          _assistant?.cancel();
        },
        send: (text, turn) async {
          if (!turn.isCurrent) throw const SpeechInputFailure('资料语音会话已暂停');
          final answer = await _assistant!.ask(text, _selected);
          if (!turn.isCurrent || !_current) {
            throw const SpeechInputFailure('资料语音会话已暂停');
          }
          setState(() => _history.insert(0, answer));
          if (answer.status != KnowledgeAnswerStatus.cited) {
            throw const SpeechInputFailure('本轮没有通过引用核验的答案，请查看资料或补充内容');
          }
          return answer.claims.map((c) => c.text).join('。');
        });
    setState(() => _voice = controller);
  }

  Future<void> _endVoice() async {
    final voice = _voice;
    if (voice == null) return;
    if (mounted) setState(() => _voice = null);
    await voice.end();
    voice.dispose();
  }

  Future<void> _report() async {
    _stop();
    await _endVoice();
    if (!mounted || !_current) return;
    final answers =
        _history.where((a) => a.status == KnowledgeAnswerStatus.cited).toList();
    if (answers.isEmpty) {
      setState(() => _error = '请先完成至少一条通过引用核验的问答');
      return;
    }
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => KnowledgeReportPage(answers: answers)));
  }
}
