import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_task_detail_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_task_output_page.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/widget/chat_failure_action_button.dart';
import 'package:flutter/material.dart';

typedef AgentTaskDetailLoader = Future<AgentTaskDetail?> Function(int cid);
typedef AgentTaskResumeLoader = Future<ConversationModel?> Function(int cid,
    {required int userCreatedAt, required int generation});
typedef AgentTaskDetailConversationOpener = Future<void> Function(
    ConversationModel conversation,
    {required bool resume,
    int? targetCreatedAt});
typedef AgentTaskOutputOpener = Future<void> Function(
    AgentTaskDetail detail, AgentTaskOutputReference output);

/// 恢复概览只提供信息；一次明确点击继续即授权，不再增加确认弹窗。
class AgentTaskDetailPage extends StatefulWidget {
  final int cid;
  final String? expectedAccountHash;
  final String Function()? accountHash;
  final Listenable? accountChanges;
  final AgentTaskDetailLoader? loadDetail;
  final AgentTaskResumeLoader? loadConversationForResume;
  final AgentTaskDetailConversationOpener? openConversation;
  final AgentTaskOutputOpener? openOutput;
  final Future<void> Function(ChatFailureDiagnosis)? onResolveDiagnosis;

  const AgentTaskDetailPage({
    super.key,
    required this.cid,
    this.expectedAccountHash,
    this.accountHash,
    this.accountChanges,
    this.loadDetail,
    this.loadConversationForResume,
    this.openConversation,
    this.openOutput,
    this.onResolveDiagnosis,
  });

  @override
  State<AgentTaskDetailPage> createState() => _AgentTaskDetailPageState();
}

class _AgentTaskDetailPageState extends State<AgentTaskDetailPage>
    with WidgetsBindingObserver {
  late final String _accountHash;
  Listenable? _accountChanges;
  Future<AgentTaskDetailService>? _service;
  AgentTaskDetail? _detail;
  bool _busy = true;
  bool _acting = false;
  bool _accountChanged = false;
  bool _reloadNeeded = false;
  String? _error;
  int _loadToken = 0;
  int _promptChars = 2000;
  Timer? _timer;
  final _executor = AgentTaskExecutor.instance;

  String get _currentAccount =>
      widget.accountHash?.call() ?? HiDBManager.getAccountHash();
  bool get _routeCurrent => ModalRoute.of(context)?.isCurrent ?? false;

  @override
  void initState() {
    super.initState();
    _accountHash = widget.expectedAccountHash ?? _currentAccount;
    _accountChanges = widget.accountChanges ?? AISettingsProvider.instance;
    _accountChanges?.addListener(_checkAccount);
    _executor.addListener(_executionChanged);
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_checkAccount() || !_routeCurrent || _busy || _acting) return;
      if (_reloadNeeded) {
        _reloadNeeded = false;
        unawaited(_load(silent: true));
      }
    });
    unawaited(_load());
  }

  void _executionChanged() {
    if (_checkAccount()) _reloadNeeded = true;
  }

  bool _checkAccount() {
    if (!mounted || _accountChanged) return false;
    if (_currentAccount == _accountHash) return true;
    _loadToken++;
    setState(() {
      _accountChanged = true;
      _detail = null;
      _busy = false;
      _acting = false;
      _error = null;
    });
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _checkAccount()) {
      unawaited(_load(silent: true));
    }
  }

  Future<AgentTaskDetailService> _getService() => _service ??= () async {
        final manager = await HiDBManager.instance(dbName: _accountHash);
        if (!_checkAccount()) throw const FormatException('账号已切换');
        final service = await AgentTaskDetailService.create(manager,
            accountHash: _accountHash, executor: _executor);
        if (!_checkAccount()) throw const FormatException('账号已切换');
        return service;
      }();

  Future<AgentTaskDetail?> _readDetail() async {
    final loader = widget.loadDetail ?? (await _getService()).loadDetail;
    if (!_checkAccount()) return null;
    final detail = await loader(widget.cid);
    if (detail != null && detail.cid != widget.cid) {
      throw const FormatException('任务归属不一致');
    }
    return detail;
  }

  Future<void> _load({bool silent = false}) async {
    if (!_checkAccount()) return;
    final token = ++_loadToken;
    setState(() {
      if (!silent) _busy = true;
      _error = null;
    });
    try {
      final detail = await _readDetail();
      if (!mounted || !_checkAccount() || token != _loadToken) return;
      if (detail != null && detail.cid != widget.cid) {
        throw const FormatException('任务归属不一致');
      }
      setState(() {
        _detail = detail;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || !_checkAccount() || token != _loadToken) return;
      setState(() {
        _busy = false;
        _error = '任务详情加载失败，请重试';
      });
    }
  }

  bool _mayAct() => _checkAccount() && _routeCurrent && !_acting;

  Future<void> _openConversation({required bool resume}) async {
    final detail = _detail;
    if (!_mayAct() ||
        detail == null ||
        !detail.hasConversation ||
        (resume && !detail.canResume)) {
      return;
    }
    setState(() => _acting = true);
    try {
      final ConversationModel? conversation;
      if (resume) {
        final loader = widget.loadConversationForResume ??
            (await _getService()).conversationForResume;
        if (!_checkAccount() || !_routeCurrent) return;
        conversation = await loader(widget.cid,
            userCreatedAt: detail.userCreatedAt, generation: detail.generation);
      } else {
        final fresh = await _readDetail();
        if (!_checkAccount() || !_routeCurrent) return;
        conversation = fresh?.conversation;
      }
      if (!mounted || !_checkAccount() || !_routeCurrent) return;
      if (conversation == null ||
          conversation.cid != widget.cid ||
          (resume &&
              (_detail?.userCreatedAt != detail.userCreatedAt ||
                  _detail?.generation != detail.generation))) {
        _notice('任务已变化或无法恢复，请查看最新详情');
        await _load();
        return;
      }
      if (widget.openConversation != null) {
        await widget.openConversation!(conversation,
            resume: resume, targetCreatedAt: detail.userCreatedAt);
      } else {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => ConversationPage(
                  conversationModel: conversation!,
                  initialTargetCreatedAt: detail.userCreatedAt,
                  resumeAgentTask: resume,
                  initialAgentTaskGeneration: resume ? detail.generation : null,
                  expectedAccountHash: _accountHash,
                )));
      }
      if (_checkAccount() && _routeCurrent) await _load(silent: true);
    } catch (_) {
      if (_checkAccount() && _routeCurrent) _notice('暂时无法打开任务，请重试');
    } finally {
      if (mounted && _checkAccount()) setState(() => _acting = false);
    }
  }

  Future<void> _openOutput(AgentTaskOutputReference output) async {
    final shown = _detail;
    if (!_mayAct() || shown == null || !output.available) return;
    setState(() => _acting = true);
    try {
      final fresh = await _readDetail();
      if (!mounted || !_checkAccount() || !_routeCurrent) return;
      final matches = fresh != null &&
          fresh.userCreatedAt == shown.userCreatedAt &&
          fresh.generation == shown.generation &&
          fresh.outputs.any((item) =>
              item.fileId == output.fileId &&
              item.revision == output.revision &&
              item.available);
      if (!matches) {
        _notice('任务或成果已变化，请刷新后查看');
        await _load();
        return;
      }
      if (widget.openOutput != null) {
        await widget.openOutput!(fresh, output);
      } else {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => AgentTaskOutputPage(
                cid: widget.cid,
                fileId: output.fileId,
                revision: output.revision,
                name: output.name,
                currentRevision: output.currentRevision,
                expectedAccountHash: _accountHash,
                accountHash: widget.accountHash,
                accountChanges: widget.accountChanges)));
      }
      if (_checkAccount() && _routeCurrent) await _load(silent: true);
    } catch (_) {
      if (_checkAccount() && _routeCurrent) _notice('成果暂时不可用，请重试');
    } finally {
      if (mounted && _checkAccount()) setState(() => _acting = false);
    }
  }

  Future<void> _resolve(ChatFailureDiagnosis diagnosis) async {
    if (diagnosis.action == ChatFailureAction.retry) {
      await _openConversation(resume: true);
      return;
    }
    if (!_mayAct()) return;
    setState(() => _acting = true);
    try {
      if (widget.onResolveDiagnosis != null) {
        await widget.onResolveDiagnosis!(diagnosis);
      } else {
        await Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const AISettingsPage()));
      }
      if (_checkAccount() && _routeCurrent) await _load(silent: true);
    } catch (_) {
      if (_checkAccount() && _routeCurrent) _notice('暂时无法打开设置，请重试');
    } finally {
      if (mounted && _checkAccount()) setState(() => _acting = false);
    }
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _loadToken++;
    _timer?.cancel();
    _accountChanges?.removeListener(_checkAccount);
    _executor.removeListener(_executionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _section(String title, List<Widget> children) => Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ])),
      );

  @override
  Widget build(BuildContext context) {
    final changed = _accountChanged || _currentAccount != _accountHash;
    final detail = changed ? null : _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('任务详情'), actions: [
        IconButton(
            key: const ValueKey('refresh_agent_task_detail'),
            tooltip: '刷新详情',
            onPressed: changed || _busy || _acting ? null : _load,
            icon: const Icon(Icons.refresh)),
      ]),
      body: changed
          ? const Center(child: Text('账号已切换，请返回当前账号的任务'))
          : _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ]))
                  : detail == null
                      ? const Center(child: Text('这个对话没有可查看的任务记录'))
                      : _body(detail),
    );
  }

  Widget _body(AgentTaskDetail detail) {
    final diagnosis = detail.failureDiagnosis;
    final report = detail.verificationReport;
    final status = switch (detail.status) {
      'complete' => '已完成',
      'running' => '执行中',
      'queued' => '排队中',
      _ => detail.canResume ? '待继续' : '仅可查看',
    };
    return ListView(
      key: const ValueKey('agent_task_detail_body'),
      padding: const EdgeInsets.all(12),
      children: [
        _section(detail.title, [
          Text(
              '$status · 第 ${detail.nextRound + 1} 轮 · 任务版本 ${detail.generation}'),
          if (detail.queuePosition > 0) Text('等候顺序：${detail.queuePosition}'),
          if (detail.prompt.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                    detail.prompt.substring(0, _promptEnd(detail.prompt)))),
          if (_promptChars < detail.prompt.length)
            TextButton(
                key: const ValueKey('expand_task_prompt'),
                onPressed: () {
                  if (_checkAccount()) setState(() => _promptChars += 10000);
                },
                child: Text('展开更多输入（共 ${detail.prompt.length} 字符）')),
          if (!detail.hasConversation) const Text('原对话已不存在，无法继续任务'),
          if (!detail.snapshotValid) const Text('任务记录无法完整恢复，可打开原对话查看历史'),
          if (detail.pauseReason?.isNotEmpty == true)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(detail.pauseReason!)),
          TextButton.icon(
              key: const ValueKey('open_task_conversation'),
              onPressed: _acting || !detail.hasConversation
                  ? null
                  : () => _openConversation(resume: false),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('打开原对话')),
        ]),
        if (diagnosis != null)
          _section('错误与下一步', [
            Text(diagnosis.message),
            Text(diagnosis.suggestion),
            if (diagnosis.statusCode != null)
              Text('HTTP ${diagnosis.statusCode}'),
            Text('诊断：${diagnosis.diagnosticReference}'),
            ChatFailureActionButton(
                diagnosis: diagnosis,
                onPressed: _acting ||
                        (diagnosis.action == ChatFailureAction.retry &&
                            !detail.canResume)
                    ? null
                    : () => _resolve(diagnosis)),
          ]),
        _section('完整任务清单', [
          if (detail.todos.isEmpty) const Text('尚未生成清单'),
          for (final todo in detail.todos)
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                          todo.status == 'completed'
                              ? Icons.check_circle_outline
                              : todo.status == 'in_progress'
                                  ? Icons.pending_outlined
                                  : Icons.radio_button_unchecked,
                          size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(todo.content)),
                    ])),
        ]),
        _section('工具执行记录', [
          Text('已有结果 ${detail.pairedToolResultCount} 项（包含工具返回的失败或拒绝）'),
          for (final tool in detail.pairedTools)
            Text('${tool.name} · ${tool.toolId}'),
          if (detail.pendingApproval != null)
            Text('正在等待确认：${detail.pendingApproval!.name}'),
          if (detail.uncertainTools.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('以下操作没有确认结果，恢复不会自动重做：'),
            for (final tool in detail.uncertainTools)
              Text('${tool.name} · ${tool.toolId}'),
          ],
        ]),
        _section('本轮成果', [
          if (detail.outputs.isEmpty) const Text('本轮尚无已保存的文件成果'),
          for (final output in detail.outputs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              key: ValueKey('task_output_${output.fileId}_${output.revision}'),
              title: Text(output.name),
              subtitle: Text(
                  '生成版本 v${output.revision}${!output.available ? ' · 版本不可用' : !output.isCurrent ? ' · 当前 v${output.currentRevision}' : ' · 当前版本'}'),
              trailing: const Icon(Icons.description_outlined),
              onTap: _acting || !output.available
                  ? null
                  : () => _openOutput(output),
            ),
        ]),
        _section('本轮验收', [
          if (report == null)
            const Text('本轮尚无文件验收报告')
          else ...[
            Text(report.summary),
            if (!detail.verificationIsCurrent)
              const Text('成果版本已变化或不可用，此报告不能代表当前文件'),
            for (final check in report.checks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(check.passed
                    ? Icons.check_circle_outline
                    : Icons.error_outline),
                title: Text(check.label),
                subtitle: Text(check.detail),
              ),
          ],
        ]),
        if (detail.canResume)
          _section('恢复概览', [
            Text('将复用 ${detail.pairedToolResultCount} 项已有工具结果，接着处理尚未完成的清单。'),
            const Text('结果不明的操作不会自动重做；需要确认的写操作仍会等待你的选择。'),
            const Text('继续会再次向 AI 服务发送请求，可能产生费用。'),
            const SizedBox(height: 12),
            FilledButton.icon(
                key: const ValueKey('resume_task_from_detail'),
                onPressed:
                    _acting ? null : () => _openConversation(resume: true),
                icon: _acting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow),
                label: const Text('继续任务')),
          ]),
      ],
    );
  }

  int _promptEnd(String content) {
    var end = _promptChars.clamp(0, content.length);
    if (end > 0 &&
        end < content.length &&
        content.codeUnitAt(end - 1) >= 0xD800 &&
        content.codeUnitAt(end - 1) <= 0xDBFF &&
        content.codeUnitAt(end) >= 0xDC00 &&
        content.codeUnitAt(end) <= 0xDFFF) {
      end++;
    }
    return end;
  }
}
