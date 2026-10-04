import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_task_center_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/pages/agent_task_detail_page.dart';
import 'package:flutter/material.dart';

typedef AgentTaskCenterLoader = Future<AgentTaskCenterBatch> Function({
  required int offset,
  required int limit,
});
typedef AgentTaskConversationLoader = Future<ConversationModel?> Function(
  int cid, {
  required bool requireResumable,
});
typedef AgentTaskConversationOpener = Future<void> Function(
  ConversationModel conversation, {
  required bool resume,
  int? targetCreatedAt,
});
typedef AgentTaskDetailOpener = Future<void> Function(int cid,
    {required String accountHash});

/// 只展示持久化任务；明确点击继续后才进入会话并发起请求。
class AgentTaskCenterPage extends StatefulWidget {
  final AgentTaskCenterLoader? loadTasks;
  final AgentTaskConversationLoader? loadConversation;
  final AgentTaskConversationOpener? openConversation;
  final String Function()? accountHash;
  final AgentTaskDetailOpener? openDetails;

  const AgentTaskCenterPage({
    super.key,
    this.loadTasks,
    this.loadConversation,
    this.openConversation,
    this.accountHash,
    this.openDetails,
  });

  @override
  State<AgentTaskCenterPage> createState() => _AgentTaskCenterPageState();
}

enum _TaskFilter { all, resumable, complete }

class _AgentTaskCenterPageState extends State<AgentTaskCenterPage>
    with WidgetsBindingObserver {
  late final String _accountHash;
  Future<AgentTaskCenterService>? _service;
  final List<AgentTaskCenterEntry> _entries = [];
  _TaskFilter _filter = _TaskFilter.all;
  bool _busy = false;
  bool _accountChanged = false;
  String? _error;
  int? _nextOffset = 0;
  int? _openingCid;
  int _generation = 0;
  final _executor = AgentTaskExecutor.instance;
  bool _hadBusyRun = false;

  void _onExecutionChanged() {
    if (!mounted || !_checkAccount()) return;
    final busy = _entries.any((entry) =>
        _executor.lookup(AgentTaskKey(_accountHash, entry.cid))?.busy == true);
    setState(() {});
    if (_hadBusyRun && !busy) unawaited(_load(reset: true));
    _hadBusyRun = busy;
  }

  AgentTaskCenterEntry _withLiveState(AgentTaskCenterEntry entry) {
    final key = AgentTaskKey(_accountHash, entry.cid);
    final run = _executor.lookup(key);
    if (run == null) return entry;
    final position = _executor.queuePosition(key);
    return AgentTaskCenterEntry(
        cid: entry.cid,
        title: entry.title,
        preview: entry.preview,
        status: run.queued
            ? 'queued'
            : run.busy
                ? 'running'
                : run.prepared.session.status,
        canResume: !run.busy &&
            run.prepared.session.canResume &&
            entry.hasConversation &&
            entry.userCreatedAt == run.prepared.user.createdAt,
        hasConversation: entry.hasConversation,
        interrupted: false,
        updatedAt: entry.updatedAt,
        userCreatedAt: entry.userCreatedAt,
        completedTodos: run.prepared.session.todos
            .where((t) => t.status == 'completed')
            .length,
        totalTodos: run.prepared.session.todos.length,
        queuePosition: position,
        pauseReason: run.queued
            ? '等待执行（队列第 $position 位）'
            : run.busy
                ? run.progress?.label ?? '正在执行'
                : run.prepared.session.pauseReason);
  }

  String get _currentAccount =>
      (widget.accountHash ?? HiDBManager.getAccountHash)();

  @override
  void initState() {
    super.initState();
    _accountHash = _currentAccount;
    WidgetsBinding.instance.addObserver(this);
    _executor.addListener(_onExecutionChanged);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _executor.removeListener(_onExecutionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _checkAccount()) {
      unawaited(_load(reset: true));
    }
  }

  bool _checkAccount() {
    if (!mounted) return false;
    if (_accountChanged || _currentAccount != _accountHash) {
      if (!_accountChanged) {
        _generation++;
        setState(() {
          _accountChanged = true;
          _entries.clear();
          _busy = false;
          _openingCid = null;
          _nextOffset = null;
          _error = '账号已切换，请返回后重新打开任务中心';
        });
      }
      return false;
    }
    return true;
  }

  Future<AgentTaskCenterService> _getService() => _service ??= () async {
        if (!_checkAccount()) throw StateError('account changed');
        final manager = await HiDBManager.instance(dbName: _accountHash);
        if (!_checkAccount()) throw StateError('account changed');
        return AgentTaskCenterService.create(manager,
            accountHash: _accountHash, executor: _executor);
      }();

  List<AgentTaskCenterEntry> get _visible =>
      _entries.map(_withLiveState).where((entry) {
        return switch (_filter) {
          _TaskFilter.all => true,
          _TaskFilter.resumable => entry.canResume,
          _TaskFilter.complete => entry.status == 'complete',
        };
      }).toList(growable: false);

  Future<void> _load({bool reset = false}) async {
    if (!_checkAccount() || _busy || (!reset && _nextOffset == null)) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _entries.clear();
        _nextOffset = 0;
      }
    });
    try {
      final loader = widget.loadTasks ?? (await _getService()).listTasks;
      // 空筛选最多扫三页，后续由加载更多继续，避免扫描整个大型库。
      for (var pages = 0; pages < 3; pages++) {
        final offset = _nextOffset;
        if (offset == null) break;
        final page = await loader(offset: offset, limit: 30);
        if (!_checkAccount() || generation != _generation) return;
        final known = _entries.map((entry) => entry.cid).toSet();
        setState(() {
          _entries.addAll(page.entries.where((entry) => known.add(entry.cid)));
          _nextOffset = page.nextOffset;
        });
        if (_visible.isNotEmpty || _nextOffset == null) break;
        if (_nextOffset! <= offset) {
          throw StateError('invalid task cursor');
        }
      }
    } catch (_) {
      if (_checkAccount() && generation == _generation) {
        setState(() => _error = '任务加载失败，请重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _open(AgentTaskCenterEntry entry, {bool resume = false}) async {
    if (!_checkAccount() ||
        _openingCid != null ||
        !entry.hasConversation ||
        (resume && !entry.canResume)) {
      return;
    }
    setState(() => _openingCid = entry.cid);
    try {
      final loader =
          widget.loadConversation ?? (await _getService()).conversationForTask;
      final conversation = await loader(entry.cid, requireResumable: resume);
      if (!mounted || !_checkAccount()) return;
      if (conversation == null) {
        _notice(resume ? '任务已变化或无法恢复，请刷新后查看' : '原对话已不存在');
        await _load(reset: true);
        return;
      }
      if (widget.openConversation != null) {
        await widget.openConversation!(conversation,
            resume: resume, targetCreatedAt: entry.userCreatedAt);
      } else {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => ConversationPage(
                  conversationModel: conversation,
                  expectedAccountHash: _accountHash,
                  initialTargetCreatedAt: entry.userCreatedAt,
                  resumeAgentTask: resume,
                )));
      }
      if (_checkAccount()) await _load(reset: true);
    } catch (_) {
      if (_checkAccount()) _notice('无法打开任务，请刷新后重试');
    } finally {
      if (mounted && !_accountChanged) setState(() => _openingCid = null);
    }
  }

  Future<void> _openDetails(AgentTaskCenterEntry entry) async {
    if (!_checkAccount() ||
        _openingCid != null ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    setState(() => _openingCid = entry.cid);
    try {
      if (widget.openDetails != null) {
        await widget.openDetails!(entry.cid, accountHash: _accountHash);
      } else {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => AgentTaskDetailPage(
                cid: entry.cid,
                expectedAccountHash: _accountHash,
                accountHash: widget.accountHash)));
      }
      if (_checkAccount()) await _load(reset: true);
    } catch (_) {
      if (_checkAccount()) _notice('任务详情暂时无法打开，请重试');
    } finally {
      if (mounted && _checkAccount()) setState(() => _openingCid = null);
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _select(_TaskFilter filter) {
    if (!_checkAccount()) return;
    setState(() => _filter = filter);
    if (_visible.isEmpty && _nextOffset != null) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visible;
    return Scaffold(
      appBar: AppBar(title: const Text('Agent 任务中心'), actions: [
        IconButton(
            tooltip: '刷新任务',
            onPressed:
                _busy || _accountChanged ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('任务按顺序执行，切换页面不会中断。暂停后点击继续才会再次发送请求。'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final option in _TaskFilter.values)
                ChoiceChip(
                  label: Text(switch (option) {
                    _TaskFilter.all => '全部',
                    _TaskFilter.resumable => '可继续',
                    _TaskFilter.complete => '已完成',
                  }),
                  selected: _filter == option,
                  onSelected: _accountChanged ? null : (_) => _select(option),
                ),
            ]),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              children: [
                if (_busy && _entries.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator())),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(children: [
                      Text(_error!, textAlign: TextAlign.center),
                      if (!_accountChanged)
                        TextButton(
                            onPressed: _busy ? null : () => _load(reset: true),
                            child: const Text('重试')),
                    ]),
                  ),
                if (entries.isEmpty && !_busy && _error == null)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _nextOffset != null
                          ? '本页暂无匹配任务，可继续加载'
                          : switch (_filter) {
                              _TaskFilter.all =>
                                '暂无任务。在对话中开启任务模式并发送请求后，任务会显示在这里。',
                              _TaskFilter.resumable => '暂无可继续的任务',
                              _TaskFilter.complete => '暂无已完成的任务',
                            },
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final entry in entries) _taskCard(entry),
                if (_nextOffset != null && (!_busy || _entries.isNotEmpty))
                  TextButton.icon(
                    onPressed: _busy || _accountChanged ? null : () => _load(),
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.expand_more),
                    label: Text(_busy ? '正在加载' : '加载更多任务'),
                  ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _taskCard(AgentTaskCenterEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final complete = entry.status == 'complete';
    final queued = entry.status == 'queued';
    final running = entry.status == 'running';
    final opening = _openingCid == entry.cid;
    final progress =
        entry.totalTodos > 0 ? entry.completedTodos / entry.totalTodos : null;
    return Card(
      key: ValueKey('agent_task_${entry.cid}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.hasConversation && _openingCid == null
            ? () => _open(entry)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                  complete
                      ? Icons.task_alt
                      : running
                          ? Icons.play_circle_outline
                          : queued
                              ? Icons.schedule
                              : Icons.pause_circle_outline,
                  color: complete ? colors.primary : colors.secondary),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium)),
              const SizedBox(width: 8),
              Text(complete
                  ? '已完成'
                  : running
                      ? '执行中'
                      : queued
                          ? '排队中'
                          : (entry.canResume ? '待继续' : '仅可查看')),
            ]),
            if (entry.preview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(entry.preview, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            if (progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress.clamp(0, 1)),
              const SizedBox(height: 6),
              Text('清单 ${entry.completedTodos}/${entry.totalTodos} 已完成'),
            ],
            if (entry.pauseReason?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(entry.pauseReason!,
                  style: TextStyle(color: colors.secondary)),
            ],
            if (!entry.hasConversation) ...[
              const SizedBox(height: 8),
              const Text('原对话已不存在，无法打开或继续'),
            ],
            const SizedBox(height: 8),
            Text(_time(entry.updatedAt),
                style: Theme.of(context).textTheme.bodySmall),
            Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                      key: ValueKey('detail_agent_task_${entry.cid}'),
                      onPressed: _openingCid == null
                          ? () => _openDetails(entry)
                          : null,
                      icon: const Icon(Icons.info_outline),
                      label: const Text('详情')),
                  if (opening)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else if (queued || running)
                    TextButton.icon(
                        key: ValueKey('stop_agent_task_${entry.cid}'),
                        onPressed: () => _executor.cancel(
                            AgentTaskKey(_accountHash, entry.cid),
                            reason: queued ? '已取消排队，可继续任务' : '已从任务中心暂停，可继续任务'),
                        icon: Icon(queued ? Icons.close : Icons.pause),
                        label: Text(queued ? '取消排队' : '暂停任务'))
                  else if (entry.canResume && entry.hasConversation)
                    FilledButton.tonalIcon(
                        key: ValueKey('resume_agent_task_${entry.cid}'),
                        onPressed: _openingCid == null
                            ? () => _open(entry, resume: true)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('继续任务')),
                ]),
          ]),
        ),
      ),
    );
  }

  String _time(int timestamp) {
    if (timestamp <= 0 || timestamp > 8640000000000000) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String two(int number) => number.toString().padLeft(2, '0');
    return '${date.year}/${two(date.month)}/${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}
