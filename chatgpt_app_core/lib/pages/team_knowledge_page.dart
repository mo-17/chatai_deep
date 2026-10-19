import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:chatgpt_app_core/knowledge/team_knowledge.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_runtime.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_library.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'knowledge_assistant_page.dart';

class TeamKnowledgePage extends StatefulWidget {
  const TeamKnowledgePage({super.key});
  @override
  State<TeamKnowledgePage> createState() => _TeamKnowledgePageState();
}

class _TeamKnowledgePageState extends State<TeamKnowledgePage> {
  final _api = TeamKnowledgeApi();
  List<Map<String, dynamic>> _teams = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _api.valid.addListener(_environment);
    AiCatalogIdentity.changes.addListener(_environment);
    BackendConfig.changes.addListener(_environment);
    _load();
  }

  void _environment() {
    if (mounted && !_api.current) setState(() => _teams = []);
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final rows = await _api.call('GET') as List;
      if (mounted) {
        setState(() {
          _teams = rows.map((r) => (r as Map).cast<String, dynamic>()).toList();
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _teams = [];
          _error = '团队知识库暂不可用，请确认已登录且后端已部署团队功能。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create(bool join) async {
    final value = await _input(
        context, join ? '加入团队' : '创建团队', join ? '粘贴一次性邀请码' : '团队名称',
        max: join ? 64 : 80);
    if (value == null || !mounted) return;
    try {
      await _api.call('POST', join ? '/join' : '',
          join ? {'code': value} : {'name': value});
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查邀请码或权限后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('团队知识库'), actions: [
        IconButton(
            onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('只有你主动选择的资料才会上传团队。团队成员可阅读共享原文和问答；创建者负责成员权限。'),
        Wrap(spacing: 12, children: [
          FilledButton(
              onPressed: _busy ? null : () => _create(false),
              child: const Text('创建团队')),
          OutlinedButton(
              onPressed: _busy ? null : () => _create(true),
              child: const Text('使用邀请码加入'))
        ]),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        for (final team in _teams)
          ListTile(
              title: Text(team['name']),
              subtitle: Text('${team['role']} · ${team['documentCount']}篇资料'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => _TeamDetailPage(id: team['id'])));
                if (mounted) _load();
              }),
      ]));
  @override
  void dispose() {
    _api.valid.removeListener(_environment);
    AiCatalogIdentity.changes.removeListener(_environment);
    BackendConfig.changes.removeListener(_environment);
    _api.close();
    super.dispose();
  }
}

Future<String?> _input(BuildContext context, String title, String hint,
    {String initial = '', int max = 30000}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: Text(title),
              content: SizedBox(
                  width: 520,
                  child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 8,
                      maxLength: max,
                      decoration: InputDecoration(labelText: hint))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                    child: const Text('确定'))
              ]));
  // 对话框退出动画仍会读取 controller，下一帧后再释放。
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  return result == null || result.isEmpty ? null : result;
}

class _TeamDetailPage extends StatefulWidget {
  final String id;
  const _TeamDetailPage({required this.id});
  @override
  State<_TeamDetailPage> createState() => _TeamDetailPageState();
}

class _TeamDetailPageState extends State<_TeamDetailPage>
    with WidgetsBindingObserver {
  final _api = TeamKnowledgeApi();
  Map<String, dynamic>? _team;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api.valid.addListener(_environment);
    AiCatalogIdentity.changes.addListener(_environment);
    BackendConfig.changes.addListener(_environment);
    _load();
  }

  void _environment() {
    if (mounted && !_api.current) setState(() => _team = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  bool get _owner => _team?['role'] == 'owner';
  bool get _editor => _owner || _team?['role'] == 'editor';
  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_api.current) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && _api.current) {
        _team = (await _api.call('GET', '/${widget.id}') as Map)
            .cast<String, dynamic>();
        _error = null;
      }
    } catch (_) {
      _error = '操作未完成，可能是权限或版本已变化。请刷新后核对。';
      if (!_api.current) _team = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {});
  Future<void> _addText() async {
    final title = await _input(context, '共享文档', '标题', max: 100);
    if (title == null || !mounted) return;
    final content = await _input(context, '共享文档正文', '该正文将对团队成员可见');
    if (content == null || !mounted) return;
    await _run(() async {
      await _api.call('PUT', '/${widget.id}/documents/${generateUuidV4()}', {
        'title': title,
        'pages': [content],
        'expectedRevision': 0,
        'archived': false
      });
    });
  }

  Future<void> _shareLocal() async {
    final account = LoginDao.getAccountHash() ?? 'guest';
    final db = await HiDBManager.instance(dbName: account);
    final library = await KnowledgeLibrary.create(db, account: account);
    final docs = await library.list();
    if (!mounted || !_api.current) return;
    final chosen = await showDialog<int>(
        context: context,
        builder: (ctx) =>
            SimpleDialog(title: const Text('选择要分享的个人资料'), children: [
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('只上传这篇文档的文字，团队成员可查看；PDF原件不上传。')),
              for (final doc in docs)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, doc.id),
                    child: Text(doc.title))
            ]));
    if (chosen == null || !mounted || !_api.current) return;
    final snapshot = await library.snapshot(db.db, chosen);
    final doc = snapshot['document'] as Map;
    final chunks = snapshot['chunks'] as List;
    final pages = <int, String>{};
    for (final c in chunks) {
      final page = c['pageNumber'] as int? ?? 1;
      pages[page] = '${pages[page] ?? ''}${c['content']}\n';
    }
    if (!mounted || !_api.current) return;
    await _run(() async {
      await _api.call('PUT', '/${widget.id}/documents/${generateUuidV4()}', {
        'title': doc['title'],
        'pages': pages.values.toList(),
        'expectedRevision': 0,
        'archived': false
      });
    });
  }

  Future<void> _ask() async {
    if (_team == null || !_api.current) return;
    final account = LoginDao.getAccountHash() ?? 'guest';
    final settings = context.read<AISettingsProvider>();
    final db = await HiDBManager.instance(dbName: account);
    if (!mounted || !_api.current) return;
    final repository = TeamKnowledgeRepository(_api, widget.id);
    final assistant = KnowledgeAssistant(
        repository: repository,
        isCurrent: () => _api.current,
        complete: knowledgeRuntime(
            repository: repository,
            usageStorage: db,
            settings: settings,
            account: account));
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => KnowledgeAssistantPage(
                assistant: assistant,
                teamName: _team!['name'],
                access: _api.valid)));
    assistant.dispose();
    if (mounted) _load();
  }

  Future<void> _invite(String role) async {
    await _run(() async {
      final invite = await _api
          .call('POST', '/${widget.id}/invites', {'role': role}) as Map;
      if (!mounted || !_api.current) return;
      await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('一次性团队邀请'),
                  content: SelectableText(
                      '角色：$role\n24小时内有效，使用一次后失效。请仅分享给你信任的成员。\n\n${invite['code']}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭')),
                    TextButton(
                        onPressed: () async {
                          await _api.call('DELETE',
                              '/${widget.id}/invites/${invite['id']}');
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('撤销邀请'))
                  ]));
    });
  }

  Future<void> _member(String id) async {
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(title: Text('成员 $id'), children: [
              for (final role in ['editor', 'viewer', '移除成员'])
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, role),
                    child: Text(role))
            ]));
    if (action != null) {
      await _run(() async {
        await _api.call('PUT', '/${widget.id}/members/$id',
            {'role': action == '移除成员' ? null : action});
      });
    }
  }

  Future<void> _audit() async {
    await _run(() async {
      final audit = await _api.call('GET', '/${widget.id}/audit') as List;
      if (!mounted) return;
      await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => SafeArea(
              child: SizedBox(
                  height: 500,
                  child: ListView(children: [
                    for (final row in audit.reversed)
                      ListTile(
                          title: Text('${row['actor']} · ${row['action']}'),
                          subtitle: Text(
                              DateTime.fromMillisecondsSinceEpoch(row['at'])
                                  .toLocal()
                                  .toString()))
                  ]))));
    });
  }

  Future<void> _edit(Map doc) async {
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(title: Text(doc['title']), children: [
              for (final item in [
                '查看正文',
                if (_editor) '修订正文',
                if (_editor) (doc['archived'] == true ? '恢复使用' : '标记失效'),
                if (_editor) '删除共享文档'
              ])
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, item),
                    child: Text(item))
            ]));
    if (action == null || !mounted) return;
    final text = (doc['chunks'] as List).map((c) => c['content']).join('\n');
    if (action == '查看正文') {
      await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text(doc['title']),
                  content: SingleChildScrollView(child: SelectableText(text)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'))
                  ]));
      return;
    }
    if (action == '删除共享文档') {
      final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('删除团队文档？'),
                  content: const Text('团队成员将无法继续检索这篇文档，历史问答保留当时快照。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('删除'))
                  ]));
      if (yes == true) {
        await _run(() async {
          await _api.call('DELETE',
              '/${widget.id}/documents/${doc['uid']}?revision=${doc['revision']}');
        });
      }
      return;
    }
    final body = action == '修订正文'
        ? await _input(context, '修订共享正文', '正文', initial: text)
        : text;
    if (body == null) return;
    await _run(() async {
      await _api.call('PUT', '/${widget.id}/documents/${doc['uid']}', {
        'title': doc['title'],
        'pages': [body],
        'expectedRevision': doc['revision'],
        'archived': action == '标记失效'
            ? true
            : action == '恢复使用'
                ? false
                : doc['archived']
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(_team?['name'] ?? '团队资料'), actions: [
        IconButton(
            onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_team != null) ...[
          Text('我的权限：${_team!['role']}'),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: _busy ? null : _ask, child: const Text('依据团队资料提问')),
            if (_editor)
              OutlinedButton(
                  onPressed: _busy ? null : _addText,
                  child: const Text('共享文本')),
            if (_editor)
              OutlinedButton(
                  onPressed: _busy ? null : _shareLocal,
                  child: const Text('分享个人资料')),
            if (_owner)
              PopupMenuButton<String>(
                  tooltip: '邀请成员',
                  onSelected: _invite,
                  itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'viewer', child: Text('邀请只读成员')),
                        const PopupMenuItem(
                            value: 'editor', child: Text('邀请编辑成员'))
                      ]),
            if (_owner)
              TextButton(
                  onPressed: _busy ? null : _audit, child: const Text('访问审计'))
          ]),
          for (final doc in _team!['documents'] as List)
            ListTile(
                title: Text(doc['title']),
                subtitle: Text(
                    'v${doc['revision']}${doc['archived'] == true ? ' · 已失效' : ''}'),
                onTap: () => _edit(doc)),
          if (_owner) ...[
            const Divider(),
            const Text('团队成员'),
            for (final entry in (_team!['members'] as Map).entries)
              ListTile(
                  title: Text('成员 ${entry.key}'),
                  subtitle: Text(entry.value),
                  onTap:
                      entry.value == 'owner' ? null : () => _member(entry.key))
          ],
        ]
      ]));
  @override
  void dispose() {
    _api.valid.removeListener(_environment);
    AiCatalogIdentity.changes.removeListener(_environment);
    BackendConfig.changes.removeListener(_environment);
    WidgetsBinding.instance.removeObserver(this);
    _api.close();
    super.dispose();
  }
}
