import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';

class PersonalMemoryPage extends StatefulWidget {
  final IPersonalMemory? dao;
  const PersonalMemoryPage({super.key, this.dao});
  @override
  State<PersonalMemoryPage> createState() => _PersonalMemoryPageState();
}

class _PersonalMemoryPageState extends State<PersonalMemoryPage> {
  String? _account;
  IPersonalMemory? _dao;
  PersonalMemoryPreferences _prefs = const PersonalMemoryPreferences();
  List<PersonalMemory> _rows = const [];
  PersonalMemoryStatus? _filter;
  int _generation = 0;
  int _page = 0;
  bool _busy = true;
  String? _error;
  bool get _current =>
      mounted && _account != null && LoginDao.getAccountHash() == _account;

  @override
  void initState() {
    super.initState();
    _account = LoginDao.getAccountHash();
    BackupService.restoreTick.addListener(_restoreChanged);
    _load();
  }

  @override
  void dispose() {
    _generation++;
    BackupService.restoreTick.removeListener(_restoreChanged);
    super.dispose();
  }

  void _restoreChanged() => _load();

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      if (_account == null) throw const PersonalMemoryConflict('请先进入账号或游客模式');
      _dao ??= widget.dao ??
          await PersonalMemoryDao.create(
              await HiDBManager.instance(dbName: _account!),
              accountHash: _account!);
      final prefs = await _dao!.preferences();
      final rows =
          await _dao!.list(status: _filter, page: more ? _page + 1 : 0);
      if (!_current || generation != _generation) return;
      setState(() {
        _prefs = prefs;
        if (more) {
          _rows = [..._rows, ...rows];
          _page++;
        } else {
          _rows = rows;
          _page = 0;
        }
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text(title),
                  content: SingleChildScrollView(child: Text(text)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('确认')),
                  ])) ==
      true;

  Future<void> _write(Future<void> Function(int epoch) action, String notice,
      {int? generation, int? epoch}) async {
    if (_busy ||
        !_current ||
        (generation != null && generation != _generation)) {
      return;
    }
    final captured = _generation;
    setState(() => _busy = true);
    try {
      await action(epoch ?? _prefs.epoch);
      if (!mounted || !_current || captured != _generation) return;
      HiDialog.showSnackBar(context, notice);
      await _load();
    } catch (e) {
      if (mounted && _current && captured == _generation) {
        HiDialog.showSnackBar(context,
            e is PersonalMemoryConflict ? e.toString() : '个人记忆保存失败，请稍后重试');
      }
    } finally {
      if (_current && captured == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool enabled, bool suggestions) async {
    final generation = _generation;
    final prefs = _prefs;
    if (!_current || _busy) return;
    if (enabled &&
        !prefs.enabled &&
        !await _confirm(
            '启用个人跨会话记忆',
            '已确认的个人记忆会随未绑定助手的普通对话请求发送给当前配置的模型服务。'
                '助手、角色、故事房间和 Agent 任务不使用个人记忆。')) {
      return;
    }
    if (!mounted) return;
    if (suggestions &&
        !prefs.suggestionsEnabled &&
        !await _confirm(
            '开启回答偏好本地建议',
            '仅建议固定的回答风格和语言偏好。只检查开启后新完成并保存的普通对话中的本人输入；不读取历史、引用、附件、工具或助手回复。'
                '本地判断，不增加模型请求。候选需你确认才生效；关闭或恢复后旧候选失效。')) {
      return;
    }
    await _write((_) async {
      await _dao!.setPreferences(
          revision: prefs.revision,
          enabled: enabled,
          suggestionsEnabled: suggestions);
    }, enabled ? '个人记忆设置已保存' : '个人记忆已关闭',
        generation: generation, epoch: prefs.epoch);
  }

  Future<void> _edit(PersonalMemory? memory,
      {bool confirmCandidate = false}) async {
    final generation = _generation;
    final epoch = _prefs.epoch;
    final content = await showPersonalMemoryEditor(context,
        initialText: memory?.content ?? '',
        title: confirmCandidate
            ? '确认个人记忆候选'
            : memory == null
                ? '新增个人记忆'
                : '编辑个人记忆');
    if (content == null) return;
    await _write((capturedEpoch) async {
      await _dao!.save(content,
          existing: memory,
          expectedEpoch: capturedEpoch,
          confirmCandidate: confirmCandidate);
    }, confirmCandidate ? '候选已确认' : '个人记忆已保存',
        generation: generation, epoch: epoch);
  }

  Future<void> _delete(PersonalMemory memory) async {
    final generation = _generation;
    final epoch = _prefs.epoch;
    if (!await _confirm('删除个人记忆', memory.content)) return;
    await _write((e) => _dao!.delete(memory, expectedEpoch: e), '个人记忆已删除',
        generation: generation, epoch: epoch);
  }

  String _status(PersonalMemoryStatus status) => switch (status) {
        PersonalMemoryStatus.active => '生效',
        PersonalMemoryStatus.pending => '待确认',
        PersonalMemoryStatus.archived => '停用',
        PersonalMemoryStatus.rejected => '已拒绝',
      };
  String _source(PersonalMemory m) => [
        _status(m.status),
        m.sourceType == 'manual'
            ? '手动添加'
            : m.sourceType == 'local_suggestion'
                ? '本地建议 · 来自本人输入'
                : '来自本人输入',
        if (m.sourceCid != null) '会话 ${m.sourceCid} · 消息 ${m.sourceMessageId}',
        '更新 ${DateTime.fromMillisecondsSinceEpoch(m.updatedAt).toLocal()}',
        if (m.invalidReason.isNotEmpty) m.invalidReason,
      ].join(' · ');

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('个人记忆'), actions: [
          IconButton(
              onPressed: _busy ? null : () => _load(),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新记忆')
        ]),
        floatingActionButton: FloatingActionButton(
            onPressed: _busy || !_current ? null : () => _edit(null),
            tooltip: '新增个人记忆',
            child: const Icon(Icons.add)),
        body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            children: [
              AppVisualSurface(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text(
                        '同一账号跨普通会话使用；仅适用于未绑定助手的对话。助手、角色、故事房间和 Agent 任务均排除。'),
                    SwitchListTile(
                        key: const ValueKey('personal-memory-enabled'),
                        title: const Text('个人跨会话记忆'),
                        subtitle: Text(_prefs.enabled
                            ? '已确认的生效记忆会发送给当前模型服务'
                            : '已关闭；保存的记忆不会加入请求'),
                        value: _prefs.enabled,
                        onChanged: _busy || !_current
                            ? null
                            : (v) =>
                                _toggle(v, v && _prefs.suggestionsEnabled)),
                    SwitchListTile(
                        key: const ValueKey('personal-memory-suggestions'),
                        title: const Text('回答偏好本地建议'),
                        subtitle: const Text('本地保守判断 · 零额外模型请求 · 候选需确认'),
                        value: _prefs.suggestionsEnabled,
                        onChanged: _busy || !_current || !_prefs.enabled
                            ? null
                            : (v) => _toggle(true, v)),
                  ])),
              if (_error != null) AppVisualSurface(child: Text(_error!)),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: const Text('全部'),
                    selected: _filter == null,
                    onSelected: _busy
                        ? null
                        : (_) {
                            _filter = null;
                            _load();
                          }),
                for (final status in PersonalMemoryStatus.values)
                  ChoiceChip(
                      label: Text(_status(status)),
                      selected: _filter == status,
                      onSelected: _busy
                          ? null
                          : (_) {
                              _filter = status;
                              _load();
                            }),
              ]),
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child:
                      Text('最多 200 条，每条 400 字符；请求最多使用 8 条、2000 字符，并服从输入预算。')),
              if (_rows.isEmpty && !_busy)
                const Text('暂无个人记忆。可手动添加，或启用本地建议后确认候选。'),
              for (final memory in _rows)
                AppVisualSurface(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      SelectableText(memory.content),
                      const SizedBox(height: 8),
                      Text(_source(memory)),
                      Wrap(spacing: 8, children: [
                        if (memory.status == PersonalMemoryStatus.pending) ...[
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _edit(memory, confirmCandidate: true),
                              child: const Text('确认')),
                          TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _write(
                                      (e) => _dao!.setStatus(
                                          memory, PersonalMemoryStatus.rejected,
                                          expectedEpoch: e),
                                      '候选已拒绝'),
                              child: const Text('拒绝')),
                        ] else ...[
                          TextButton(
                              onPressed: _busy ? null : () => _edit(memory),
                              child: const Text('编辑')),
                          if (memory.status == PersonalMemoryStatus.active)
                            TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _write(
                                        (e) => _dao!.setStatus(memory,
                                            PersonalMemoryStatus.archived,
                                            expectedEpoch: e),
                                        '记忆已停用'),
                                child: const Text('停用')),
                          if (memory.status == PersonalMemoryStatus.archived &&
                              memory.invalidReason.isEmpty)
                            TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _write(
                                        (e) => _dao!.setStatus(
                                            memory, PersonalMemoryStatus.active,
                                            expectedEpoch: e),
                                        '记忆已启用'),
                                child: const Text('启用')),
                        ],
                        TextButton(
                            onPressed: _busy ? null : () => _delete(memory),
                            child: const Text('删除')),
                      ]),
                    ])),
              if (_rows.length == (_page + 1) * PersonalMemoryDao.pageSize &&
                  _rows.length < PersonalMemoryDao.maxEntries)
                TextButton(
                    onPressed: _busy ? null : () => _load(more: true),
                    child: const Text('加载更多')),
            ]),
      );
}

Future<String?> showPersonalMemoryEditor(BuildContext context,
        {required String initialText, required String title}) =>
    showDialog<String>(
        context: context,
        builder: (_) =>
            _PersonalMemoryEditor(initialText: initialText, title: title));

class _PersonalMemoryEditor extends StatefulWidget {
  final String initialText;
  final String title;
  const _PersonalMemoryEditor({required this.initialText, required this.title});
  @override
  State<_PersonalMemoryEditor> createState() => _PersonalMemoryEditorState();
}

class _PersonalMemoryEditorState extends State<_PersonalMemoryEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('保存后用于本账号未绑定助手的普通对话；总开关开启时会发送给当前模型服务。请勿保存访问凭证。'),
            TextField(
                key: const ValueKey('personal-memory-editor'),
                controller: _controller,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                    labelText: '记忆内容（最多 400 字符）', errorText: _error)),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  try {
                    PersonalMemoryDao.validateContent(_controller.text);
                    Navigator.pop(context, _controller.text.trim());
                  } catch (e) {
                    setState(() => _error = e.toString());
                  }
                },
                child: const Text('保存')),
          ]);
}
