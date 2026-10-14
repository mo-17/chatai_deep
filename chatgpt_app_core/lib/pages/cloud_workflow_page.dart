import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_api.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_client.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';

String cloudStateLabel(String state) => switch (state) {
      'queued' => '已接受，等待执行',
      'running' => '执行中',
      'paused' => '已暂停',
      'needs_configuration' => '需要模型配置',
      'budget_exhausted' => '预算已用尽',
      'cancelling' => '正在停止',
      'cancelled' => '已停止',
      'complete' => '已完成',
      'failed' => '失败',
      'unknown' => '执行结果未知',
      'deleted' => '已删除',
      _ => '状态未知'
    };

// SDK hook不保留页面对象；页面只订阅并在dispose移除自己的listener。
class _CloudIdentityEvents {
  static final changed = ValueNotifier<int>(0);
  static bool installed = false;
  static void install() {
    if (installed) return;
    installed = true;
    LoginDao.addLoginHook(() => changed.value++);
    LoginDao.addLogoutHook(() => changed.value++);
  }
}

/// 独立云观察页；没有本机runner或云/本机自动fallback。
class CloudWorkflowPage extends StatefulWidget {
  final int? cid;
  final String? expectedAccountHash;
  final CloudWorkflowClient? _syntheticClient;
  const CloudWorkflowPage({super.key, this.cid, this.expectedAccountHash})
      : _syntheticClient = null;
  @visibleForTesting
  const CloudWorkflowPage.synthetic(
      {super.key, required CloudWorkflowClient client, this.cid})
      : _syntheticClient = client,
        expectedAccountHash = null;
  @override
  State<CloudWorkflowPage> createState() => _CloudWorkflowPageState();
}

class _CloudWorkflowPageState extends State<CloudWorkflowPage>
    with WidgetsBindingObserver {
  CloudWorkflowClient? _client;
  CloudWorkflowApi? _openingApi;
  DialogRoute<bool>? _previewRoute;
  Timer? _identityWatch;
  bool _loading = true, _acting = false, _invalid = false, _foreground = true;
  String? _message;
  int _formRevision = 0;
  int? _cid, _sourceId;
  List<Map<String, Object?>> _conversations = [], _messages = [], _files = [];
  final _inputIds = <int>{};
  final _profiles = <String, CloudProfileChoice>{};
  final _output = TextEditingController(text: 'result.md');
  final _terms = TextEditingController();
  final _min = TextEditingController(text: '0');
  final _max = TextEditingController(text: '12000');
  String _format = 'md';
  bool _fullRead = true, _rework = true;
  int _attempts = 8, _estimate = 32000, _outputTokens = 2048, _minutes = 10;

  @override
  void initState() {
    super.initState();
    _cid = widget.cid;
    WidgetsBinding.instance.addObserver(this);
    _CloudIdentityEvents.install();
    _CloudIdentityEvents.changed.addListener(_verifyIdentity);
    BackendConfig.changes.addListener(_verifyIdentity);
    BackupService.restoreTick.addListener(_verifyIdentity);
    // 恢复失败没有restoreTick；原scope的执行代次仍立即阻止写入，
    // 这个仅观察的定时器负责及时清理可见数据，不执行/续权任何任务。
    _identityWatch =
        Timer.periodic(const Duration(seconds: 1), (_) => _verifyIdentity());
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    CloudWorkflowClient? made;
    try {
      if (widget._syntheticClient != null) {
        made = widget._syntheticClient!;
      } else {
        final account = LoginDao.getAccountHash();
        if (LoginDao.isGuest() ||
            account == null ||
            LoginDao.getBoardingPass() == null) {
          throw StateError('请先登录后查看云任务');
        }
        if (widget.expectedAccountHash != null &&
            widget.expectedAccountHash != account) {
          throw StateError('账号已变化，请重新打开云任务');
        }
        final scope = AgentWorkflowScope(accountHash: account);
        final api = CloudWorkflowApi.capture(scope: scope);
        _openingApi = api;
        final storage = await HiDBManager.instance(dbName: account);
        api.verify();
        final dao = await CloudWorkflowDao.create(storage,
            accountHash: account, verifySession: api.verify);
        api.verify();
        made = CloudWorkflowClient(api: api, dao: dao);
      }
      if (!mounted || _invalid) {
        made.dispose();
        return;
      }
      _client = made;
      _openingApi = null;
      made.addListener(_changed);
      await made.initialize();
      _check();
      _syncVisibility();
      _conversations = await made.api.scope.stable(() async {
        made!.api.verify();
        final rows = await made.dao.storage.db.query('tb_conversation_list',
            columns: ['cid', 'title'], orderBy: 'updateAt DESC', limit: 100);
        made.api.verify();
        if (_cid != null && !rows.any((row) => row['cid'] == _cid)) {
          final selected = await made.dao.storage.db.query(
              'tb_conversation_list',
              columns: ['cid', 'title'],
              where: 'cid=?',
              whereArgs: [_cid]);
          made.api.verify();
          return [...rows, ...selected];
        }
        return rows;
      });
      _check();
      if (!_conversations.any((row) => row['cid'] == _cid)) _cid = null;
      if (_cid != null) await _loadSources();
      _check();
    } catch (e) {
      if (!mounted) return;
      _error(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _check() {
    if (!mounted || _invalid || _client == null) {
      throw StateError('云任务页面已失效');
    }
    _client!.api.verify();
  }

  void _verifyIdentity() {
    if (!mounted || _invalid) return;
    try {
      (_client?.api ?? _openingApi)?.verify();
    } catch (_) {
      _invalidate();
    }
  }

  void _invalidate() {
    if (!mounted || _invalid) return;
    _invalid = true;
    _closePreview();
    _identityWatch?.cancel();
    _openingApi?.close();
    _client?.removeListener(_changed);
    _client?.dispose();
    _client = null;
    _conversations = _messages = _files = [];
    _sourceId = null;
    _inputIds.clear();
    _profiles.clear();
    _terms.clear();
    setState(() => _message = '账号、后端或恢复状态已变化，请重新打开云任务');
  }

  void _changed() {
    if (!mounted) return;
    _verifyIdentity();
    if (!_invalid) setState(() {});
  }

  void _closePreview() {
    final route = _previewRoute;
    _previewRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  void _error(Object e) {
    _verifyIdentity();
    if (!mounted || _invalid) return;
    setState(() => _message = e is CloudHttpFailure && e.status == 401
        ? '登录认证已失效，请重新登录后查看云任务'
        : e.toString());
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_acting || _invalid) return;
    setState(() {
      _acting = true;
      _message = null;
    });
    try {
      await action();
      _check();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _loadSources() async {
    final client = _client!, cid = _cid;
    if (cid == null) return;
    _sourceId = null;
    _inputIds.clear();
    final snapshot = await client.api.scope.stable(() async {
      client.api.verify();
      final users = await client.dao.storage.db.query('tb_messages',
          columns: ['id', 'content', 'createdAt'],
          where: 'cid=? AND ownerType=?',
          whereArgs: [cid, 'OwnerType.sender'],
          orderBy: 'id DESC',
          limit: 30);
      client.api.verify();
      final files = await client.dao.storage.db.query(
          'tb_agent_workspace_files',
          columns: ['id', 'name', 'kind', 'sizeBytes', 'currentRevision'],
          where: 'cid=?',
          whereArgs: [cid],
          orderBy: 'id DESC',
          limit: 100);
      client.api.verify();
      return (users, files);
    });
    _check();
    if (cid != _cid) return;
    setState(() {
      _messages = snapshot.$1;
      _files = snapshot.$2;
      _formRevision++;
    });
  }

  void _edit(VoidCallback edit) => setState(() {
        edit();
        _formRevision++;
      });

  Future<void> _preview() => _act(() async {
        final client = _client!, cid = _cid, id = _sourceId;
        if (cid == null || id == null || _profiles.length != 3) {
          throw StateError('请明确选择已保存的本人输入和三个服务端模型');
        }
        final revision = _formRevision;
        final source = await client.dao.capture(client.api.scope,
            cid: cid, messageId: id, inputIds: _inputIds.toList());
        _check();
        if (client.receipts.any((r) =>
            r.status == 'submission_unknown' &&
            r.source.cid == source.source.cid &&
            r.source.messageId == source.source.messageId)) {
          throw StateError('该来源有未知提交，请按原提交身份查询，不能重新发送');
        }
        if (revision != _formRevision) throw StateError('配置已变化，请重新预览');
        final payload = CloudConfirmedPayload(
            key: generateUuidV4(),
            clientInstanceId: generateUuidV4(),
            source: source.source,
            task: source.task,
            inputs: source.inputs,
            profiles: Map.of(_profiles),
            acceptance: {
              'format': _format,
              'outputName': _output.text,
              'minChars': int.tryParse(_min.text),
              'maxChars': int.tryParse(_max.text),
              'requiredTerms': _terms.text
                  .split('\n')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList(),
              'requireFullRead': _fullRead
            },
            budget: {
              'attempts': _attempts,
              'estimatedTokens': _estimate,
              'outputTokens': _outputTokens,
              'durationMs': _minutes * 60000,
              'reworks': _rework ? 1 : 0
            },
            grantDurationMs: _minutes * 60000);
        if (!mounted) return;
        FocusScope.of(context).unfocus();
        client.visible(false);
        bool? confirmed;
        try {
          final route = DialogRoute<bool>(
              context: context,
              builder: (context) => AlertDialog(
                    title: const Text('确认本次上传'),
                    content: SizedBox(
                        width: 440,
                        child: SingleChildScrollView(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text('目的地：${client.api.origin}'),
                              const Text('只上传下列显式选择内容；费用未知。'),
                              const Text('本次任务全文'),
                              SelectableText(source.task),
                              for (final input in source.inputs)
                                ExpansionTile(
                                    title: Text(
                                        '${input.title} · ${utf8.encode(input.text).length} UTF-8字节'),
                                    children: [SelectableText(input.text)]),
                              for (final role in cloudRoles)
                                Text(
                                    '${_roleLabel(role)}：${_profiles[role]!.providerName} · ${_profiles[role]!.modelName}'),
                              Text(
                                  '验收：$_format / ${_output.text}；${_min.text}–${_max.text} Unicode字符'),
                              Text(
                                  '必含内容：${_terms.text.isEmpty ? '无' : _terms.text}'),
                              Text('完整快照进入请求：$_fullRead；不代表模型认知已阅读'),
                              Text(
                                  '最多$_attempts次尝试；累计估算$_estimate token，非账单硬上限；单次输出$_outputTokens token'),
                              Text('授权技术上限$_minutes分钟；最多${_rework ? 1 : 0}次返工'),
                              const Text('离线退出策略尚待确认，生产提交继续禁用。'),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          key: const ValueKey('cloud-confirm'),
                          onPressed: client.canCreate
                              ? () => Navigator.pop(context, true)
                              : null,
                          child: const Text('确认并提交'))
                    ],
                  ));
          _previewRoute = route;
          confirmed = await Navigator.of(context).push(route);
        } finally {
          _previewRoute = null;
          if (mounted && !_invalid) _syncVisibility();
        }
        _check();
        if (confirmed != true) return;
        if (revision != _formRevision) throw StateError('配置已变化，请重新确认');
        final receipt = await client.submit(source, payload);
        _check();
        if (receipt.taskId != null) await client.open(receipt.taskId!);
      });

  static String _roleLabel(String role) =>
      switch (role) { 'analysis' => '分析', 'writing' => '撰写', _ => '审阅' };

  Widget _group(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppVisualSurface(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children
      ])));

  Widget _configuration() => _group('显式选择本次上传范围', [
        DropdownButtonFormField<int>(
            key: const ValueKey('cloud-conversation'),
            initialValue: _cid,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '原对话'),
            items: _conversations
                .map((r) => DropdownMenuItem(
                    value: r['cid'] as int,
                    child: Text(r['title']?.toString() ?? '未命名',
                        overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: _acting
                ? null
                : (value) {
                    _edit(() => _cid = value);
                    unawaited(_act(_loadSources));
                  }),
        KeyedSubtree(
            key: ValueKey('cloud-source-slot-$_cid'),
            child: DropdownButtonFormField<int>(
                key: const ValueKey('cloud-source'),
                initialValue: _sourceId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '已保存的本人输入（最近30条）'),
                items: _messages
                    .map((r) => DropdownMenuItem(
                        value: r['id'] as int,
                        child: Text(r['content'].toString(),
                            maxLines: 1, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: _acting ? null : (v) => _edit(() => _sourceId = v))),
        const Text('工作区文本：最多4份，点击预览后会显示完整快照。未选内容不上传。'),
        for (final file in _files)
          CheckboxListTile(
              title: Text(file['name'].toString()),
              subtitle: Text(
                  '${file['sizeBytes']} UTF-8字节 · 版本${file['currentRevision']}'),
              value: _inputIds.contains(file['id']),
              onChanged: _acting
                  ? null
                  : (v) {
                      if (v == true && _inputIds.length >= 4) {
                        _error(StateError('最多选择4份文本'));
                        return;
                      }
                      _edit(() {
                        if (v == true) {
                          _inputIds.add(file['id'] as int);
                        } else {
                          _inputIds.remove(file['id']);
                        }
                      });
                    }),
        for (final role in cloudRoles)
          DropdownButtonFormField<CloudProfileChoice>(
              key: ValueKey('cloud-profile-$role'),
              initialValue: _profiles[role],
              isExpanded: true,
              decoration:
                  InputDecoration(labelText: '${_roleLabel(role)}服务端模型'),
              items: _client!.profiles
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text('${p.providerName} · ${p.modelName}',
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: _acting
                  ? null
                  : (v) => _edit(() {
                        if (v != null) _profiles[role] = v;
                      })),
        if (_client!.profiles.isEmpty) const Text('服务端模型清单不可用，不能配置提交。'),
        DropdownButtonFormField<String>(
            initialValue: _format,
            decoration: const InputDecoration(labelText: '输出格式'),
            items: ['md', 'txt', 'csv']
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: _acting
                ? null
                : (v) => _edit(() {
                      if (v != null) {
                        _format = v;
                        _output.text = 'result.$v';
                      }
                    })),
        TextField(
            controller: _output,
            enabled: !_acting,
            decoration: const InputDecoration(labelText: '输出名'),
            onChanged: (_) => _edit(() {})),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _min,
                  enabled: !_acting,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '最少字符'),
                  onChanged: (_) => _edit(() {}))),
          const SizedBox(width: 12),
          Expanded(
              child: TextField(
                  controller: _max,
                  enabled: !_acting,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '最多字符'),
                  onChanged: (_) => _edit(() {})))
        ]),
        TextField(
            controller: _terms,
            enabled: !_acting,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '必含内容（每行一项）'),
            onChanged: (_) => _edit(() {})),
        SwitchListTile(
            title: const Text('完整快照进入各节点输入'),
            value: _fullRead,
            onChanged: _acting ? null : (v) => _edit(() => _fullRead = v)),
        SwitchListTile(
            title: const Text('最多一次自动返工'),
            value: _rework,
            onChanged: _acting ? null : (v) => _edit(() => _rework = v)),
        _budgetField(
            '尝试次数', _attempts, [1, 2, 3, 4, 5, 6, 7, 8], (v) => _attempts = v),
        _budgetField('累计估算token（非账单硬上限）', _estimate, [8000, 16000, 32000],
            (v) => _estimate = v),
        _budgetField('单次输出token', _outputTokens, [512, 1024, 2048],
            (v) => _outputTokens = v),
        _budgetField('本次授权技术上限（分钟）', _minutes, [1, 5, 10], (v) => _minutes = v),
        FilledButton(
            key: const ValueKey('cloud-preview'),
            onPressed: _acting ? null : _preview,
            child: const Text('预览上传内容')),
      ]);

  Widget _budgetField(
          String label, int value, List<int> choices, void Function(int) set) =>
      DropdownButtonFormField<int>(
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: choices
              .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
              .toList(),
          onChanged: _acting
              ? null
              : (v) => _edit(() {
                    if (v != null) set(v);
                  }));

  Widget _records() => _group('我的云任务', [
        for (final receipt
            in _client!.receipts.where((r) => r.status == 'submission_unknown'))
          ListTile(
              title: const Text('提交结果未知'),
              subtitle: const Text('仅按原提交身份查询，不重新发送'),
              trailing: TextButton(
                  onPressed: _acting
                      ? null
                      : () => _act(() async {
                            final bound = await _client!.resolve(receipt);
                            _check();
                            if (bound.taskId != null) {
                              await _client!.open(bound.taskId!);
                            }
                          }),
                  child: const Text('查询'))),
        for (final task in _client!.tasks)
          ListTile(
              title: Text(cloudStateLabel(task['state'] as String)),
              subtitle: Text('任务 ${task['id']}'),
              onTap: _acting
                  ? null
                  : () => _act(() => _client!.open(task['id'] as String))),
        if (_client!.nextCursor != null)
          TextButton(
              onPressed: _acting ? null : () => _act(_client!.loadNextPage),
              child: const Text('加载下一页')),
        if (_client!.tasks.isEmpty && _client!.receipts.isEmpty)
          const Text('暂无云任务'),
      ]);

  Widget _detail() {
    final client = _client!, task = client.detail!;
    final payload = task.parent['payload'];
    final usage = task.parent['usage'];
    CloudWritingResult? finalResult;
    try {
      finalResult = client.finalResult;
    } on FormatException {
      // 不可信的最终版本绑定不能让build抛异常，也不能开放本地保存。
    }
    return _group('任务详情', [
      Text(cloudStateLabel(task.state)),
      const Text('阶段与用量按服务器实际记录显示，费用未知。'),
      for (final step in task.steps)
        Text(
            '${_roleLabel(step['role'] as String)}：${cloudStateLabel(step['state'] as String)} · 结果版本${step['result_version']}'),
      Text(
          '实际尝试 ${task.parent['attempts_used']}；累计估算 ${task.parent['estimated_tokens']} token'),
      Text('用量：${usage == null ? '未知' : usage.toString()}'),
      if (payload is Map && payload['task'] is String)
        ExpansionTile(
            title: const Text('本次任务全文'),
            children: [SelectableText(payload['task'] as String)]),
      if (task.state == 'complete' && finalResult == null)
        const Text('最终成果绑定无效，暂不能保存'),
      if (finalResult != null) ...[
        const Text('已通过的最终撰写成果'),
        SelectableText(finalResult.content),
        if (client.localReceipt != null)
          FilledButton(
              key: const ValueKey('cloud-save'),
              onPressed: _acting
                  ? null
                  : () => _act(() async {
                        await client.saveToConversation();
                      }),
              child: const Text('保存到原对话')),
      ],
      Wrap(spacing: 8, children: [
        TextButton(
            key: const ValueKey('cloud-refresh'),
            onPressed: _acting ? null : () => _act(client.refresh),
            child: const Text('刷新状态')),
        if (!task.terminal)
          OutlinedButton(
              key: const ValueKey('cloud-stop'),
              onPressed: _acting
                  ? null
                  : () => _act(
                      () => client.stop(newIntent: client.stopNeedsNewIntent)),
              child: Text(client.stopNeedsNewIntent ? '按新状态明确停止' : '请求停止'))
      ]),
      const Text('关闭页面只停止观察，不代表远端任务停止。'),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('云任务')),
      body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  const Text(cloudDisabledNotice),
                  if (_message != null)
                    Text(_message!, key: const ValueKey('cloud-message')),
                  if (_client?.notice != null) Text(_client!.notice!),
                  if (_client != null && !_invalid) ...[
                    _configuration(),
                    _records(),
                    if (_client!.detail != null) _detail(),
                  ],
                ])));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅route的可见性变化；生命周期恢复也要同时检查当前route。
    ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _verifyIdentity();
      if (!_invalid) {
        _syncVisibility();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _verifyIdentity();
    if (!_invalid) _syncVisibility();
  }

  void _syncVisibility() => _client?.visible(_foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      _previewRoute == null);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _CloudIdentityEvents.changed.removeListener(_verifyIdentity);
    BackendConfig.changes.removeListener(_verifyIdentity);
    BackupService.restoreTick.removeListener(_verifyIdentity);
    _identityWatch?.cancel();
    _closePreview();
    _openingApi?.close();
    _client?.removeListener(_changed);
    _client?.dispose();
    _output.dispose();
    _terms.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }
}
