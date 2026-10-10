import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:flutter/material.dart';

class AgentWorkspacePage extends StatefulWidget {
  final AgentWorkspaceService workspace;
  final AgentWorkspaceTools tools;
  final bool readOnly;
  final int maxImportBytes;
  final CreativeFileTransferGateway? transfer;
  const AgentWorkspacePage(
      {super.key,
      required this.workspace,
      required this.tools,
      this.readOnly = false,
      this.maxImportBytes = 10 * 1024 * 1024,
      this.transfer});
  @override
  State<AgentWorkspacePage> createState() => _AgentWorkspacePageState();
}

class _AgentWorkspacePageState extends State<AgentWorkspacePage> {
  List<AgentWorkspaceFile> _files = [];
  bool _busy = true;
  String? _error;
  TaskAcceptanceCriteria _criteria = const TaskAcceptanceCriteria();
  AgentTaskVerificationReport? _report;
  CreativeFileTransferGateway get _transfer =>
      widget.transfer ??
      CreativeFileTransferGateway(maxBytes: widget.maxImportBytes);
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final files = await widget.workspace.listFiles();
      final criteria = await widget.tools.loadCriteria();
      final report = await widget.tools.loadLatestReport();
      if (mounted) {
        setState(() {
          _files = files;
          _criteria = criteria;
          _report = report;
          _busy = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '工作区读取失败，请重试';
        });
      }
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _import() async {
    try {
      final picked =
          await _transfer.pickFile(dialogTitle: '导入工作区文件', allowedExtensions: [
        'txt',
        'md',
        'markdown',
        'csv',
        'json',
        'log',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'pdf'
      ]);
      if (picked == null || !mounted) return;
      // Files Provider 可能只返回 bytes，不依赖平台路径的写权限。
      final extension = picked.name.split('.').last.toLowerCase();
      final warnings = <String>[];
      if (const {'pdf', 'doc', 'docx', 'xls', 'xlsx'}.contains(extension)) {
        await widget.workspace.importBytes(picked.bytes,
            name: picked.name,
            maxBytes: widget.maxImportBytes,
            sourceKey: picked.path,
            onWarnings: warnings.addAll);
      } else {
        await widget.workspace.importText(
            name: picked.name,
            content: utf8.decode(picked.bytes),
            sourceKey: picked.path,
            maxBytes: widget.maxImportBytes);
      }
      await _reload();
      _notice(warnings.isEmpty
          ? '文件已导入，启用对话任务模式后可按需读取'
          : '文件已导入；${warnings.join('；')}');
    } catch (e) {
      _notice('导入失败：$e');
    }
  }

  Future<void> _edit([AgentWorkspaceFile? file]) async {
    final revision =
        file == null ? null : await widget.workspace.getRevision(file.id);
    if (!mounted) return;
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _WorkspaceEditor(
                workspace: widget.workspace,
                file: file,
                content: revision?.content ?? '')));
    if (changed == true) await _reload();
  }

  Future<void> _criteriaEditor() async {
    final names =
        TextEditingController(text: _criteria.expectedOutputNames.join('\n'));
    final minimum =
        TextEditingController(text: _criteria.minChars?.toString() ?? '');
    final maximum =
        TextEditingController(text: _criteria.maxChars?.toString() ?? '');
    final terms =
        TextEditingController(text: _criteria.requiredTerms.join('\n'));
    var fullRead = _criteria.requireFullRead;
    var format = _criteria.format ?? 'auto';
    String? validation;
    final result = await showDialog<TaskAcceptanceCriteria>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: const Text('任务验收条件'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('条件用于下一次任务；带附件的任务会沿用。检查文件与格式，不评判内容质量。'),
                    TextField(
                        controller: names,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                            labelText: '期望成果文件名（每行一个）',
                            hintText: 'summary.md')),
                    Row(children: [
                      const Text('成果格式：'),
                      Expanded(
                          child: DropdownButton<String>(
                        value: format,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                              value: 'auto', child: Text('按文件扩展名')),
                          const DropdownMenuItem(
                              value: 'txt', child: Text('TXT')),
                          const DropdownMenuItem(
                              value: 'md', child: Text('Markdown')),
                          const DropdownMenuItem(
                              value: 'csv', child: Text('CSV')),
                          if (format == 'json')
                            const DropdownMenuItem(
                                value: 'json', child: Text('JSON')),
                        ],
                        onChanged: (value) => update(() => format = value!),
                      )),
                    ]),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: minimum,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: '最少字符（可空）'))),
                      const SizedBox(width: 12),
                      Expanded(
                          child: TextField(
                              controller: maximum,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: '最多字符（可空）')))
                    ]),
                    TextField(
                        controller: terms,
                        minLines: 1,
                        maxLines: 4,
                        decoration:
                            const InputDecoration(labelText: '成果必须包含（每行一个）')),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('检查本轮输入全文覆盖'),
                        value: fullRead,
                        onChanged: (value) => update(() => fullRead = value)),
                    if (validation != null)
                      Text(validation!,
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () {
                          final min = int.tryParse(minimum.text.trim());
                          final max = int.tryParse(maximum.text.trim());
                          if ((minimum.text.trim().isNotEmpty &&
                                  (min == null || min < 0)) ||
                              (maximum.text.trim().isNotEmpty &&
                                  (max == null || max <= 0)) ||
                              (min != null && max != null && min > max)) {
                            update(() => validation = '请输入有效字符范围');
                            return;
                          }
                          Navigator.pop(
                              ctx,
                              TaskAcceptanceCriteria(
                                  expectedOutputNames: names.text
                                      .split('\n')
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty)
                                      .toList(),
                                  minChars: min,
                                  maxChars: max,
                                  format: format == 'auto' ? null : format,
                                  requiredTerms: terms.text
                                      .split('\n')
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty)
                                      .toList(),
                                  requireFullRead: fullRead));
                        },
                        child: const Text('保存'))
                  ],
                )));
    // 等待对话框移出树后再释放其输入控制器。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    names.dispose();
    minimum.dispose();
    maximum.dispose();
    terms.dispose();
    if (result == null || !mounted) return;
    try {
      await widget.tools.saveCriteria(result);
      await _reload();
      _notice('验收条件已保存');
    } catch (e) {
      _notice('保存失败：$e');
    }
  }

  Widget _list(String kind) {
    final files = _files.where((f) => f.kind == kind).toList();
    return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: [
              if (files.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(kind == 'input'
                        ? '任务模式中的附件会保存到这里，也可以手动导入。'
                        : '让 Agent 使用 write_file 生成 TXT、Markdown 或 CSV，成果会出现在这里。')),
              for (final file in files)
                Card(
                    child: ListTile(
                  leading: Icon(kind == 'input'
                      ? Icons.description_outlined
                      : Icons.article_outlined),
                  title: Text(file.name),
                  subtitle: Text(
                      '${file.characterCount} 字符 · ${file.lineCount} 行'
                      '${file.pageCount > 0 ? ' · ${file.pageCount} 页' : ''} · v${file.revision}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => _WorkspacePreview(
                                workspace: widget.workspace,
                                file: file,
                                readOnly: widget.readOnly,
                                transfer: _transfer)));
                    await _reload();
                  },
                )),
            ]));
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
            title: const Text('文件工作区'),
            actions: [
              if (!widget.readOnly && Platform.operatingSystem != 'ohos')
                IconButton(
                    tooltip: '导入文件',
                    icon: const Icon(Icons.file_open_outlined),
                    onPressed: _import),
              if (!widget.readOnly)
                IconButton(
                    tooltip: '新建成果',
                    icon: const Icon(Icons.note_add_outlined),
                    onPressed: () => _edit()),
            ],
            bottom: const TabBar(tabs: [
              Tab(text: '输入'),
              Tab(text: '成果'),
              Tab(text: '条件'),
              Tab(text: '验收')
            ])),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: TextButton(onPressed: _reload, child: Text(_error!)))
                : TabBarView(children: [
                    _list('input'),
                    _list('output'),
                    ListView(padding: const EdgeInsets.all(20), children: [
                      const Text('任务结束前自动检查，发现未满足的条件时最多纠错两次，并受工具轮数与输入预算限制。'),
                      const SizedBox(height: 16),
                      Text('全文覆盖：${_criteria.requireFullRead ? '开启' : '关闭'}'),
                      Text(
                          '成果文件：${_criteria.expectedOutputNames.isEmpty ? '不指定文件名' : _criteria.expectedOutputNames.join('、')}'),
                      Text(
                          '字符范围：${_criteria.minChars ?? 0} ～ ${_criteria.maxChars?.toString() ?? '不限'}'),
                      Text('成果格式：${_criteria.format ?? '按文件扩展名'}'),
                      if (_criteria.requiredTerms.isNotEmpty)
                        Text('必须包含：${_criteria.requiredTerms.join('、')}'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                          onPressed: widget.readOnly ? null : _criteriaEditor,
                          icon: const Icon(Icons.tune),
                          label: const Text('修改验收条件')),
                    ]),
                    ListView(padding: const EdgeInsets.all(16), children: [
                      if (_report == null)
                        const Text('尚无验收记录。启用任务模式并发送任务后自动检查。')
                      else ...[
                        Text(_report!.summary,
                            style: Theme.of(context).textTheme.titleMedium),
                        const Text('通过只代表列出的客观检查满足，内容质量请结合源文和成果预览判断。'),
                        for (final check in [
                          ..._report!.checks.where((check) => !check.passed),
                          ..._report!.checks.where((check) => check.passed),
                        ])
                          ListTile(
                              leading: Icon(check.passed
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline),
                              title: Text(check.label),
                              subtitle: Text(check.detail)),
                      ],
                    ])
                  ]),
      ));
}

class _WorkspaceEditor extends StatefulWidget {
  final AgentWorkspaceService workspace;
  final AgentWorkspaceFile? file;
  final String content;
  const _WorkspaceEditor(
      {required this.workspace, required this.file, required this.content});
  @override
  State<_WorkspaceEditor> createState() => _WorkspaceEditorState();
}

class _WorkspaceEditorState extends State<_WorkspaceEditor> {
  late final _name =
      TextEditingController(text: widget.file?.name ?? 'result.md');
  late final _content = TextEditingController(text: widget.content);
  bool _saving = false;
  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.workspace.writeFile(
          fileId: widget.file?.id,
          name: _name.text,
          content: _content.text,
          note: '用户编辑');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('编辑成果'), actions: [
          TextButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中' : '保存'))
        ]),
        body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              TextField(
                  controller: _name,
                  readOnly: widget.file != null,
                  decoration: const InputDecoration(
                      labelText: '文件名（.txt / .md / .csv）')),
              const SizedBox(height: 12),
              Expanded(
                  child: TextField(
                      controller: _content,
                      expands: true,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                          hintText: '文件内容', border: OutlineInputBorder()))),
            ])),
      );
}

class _WorkspacePreview extends StatefulWidget {
  final AgentWorkspaceService workspace;
  final AgentWorkspaceFile file;
  final bool readOnly;
  final CreativeFileTransferGateway transfer;
  const _WorkspacePreview(
      {required this.workspace,
      required this.file,
      required this.readOnly,
      required this.transfer});
  @override
  State<_WorkspacePreview> createState() => _WorkspacePreviewState();
}

class _WorkspacePreviewState extends State<_WorkspacePreview> {
  Map<String, dynamic>? _part;
  int _offset = 0;
  final _query = TextEditingController();
  List<Map<String, dynamic>> _matches = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _read(
      {bool tail = false, int? line, int? page, String? section}) async {
    try {
      final part = await widget.workspace.readFile(widget.file.id,
          offset: _offset,
          maxChars: 12000,
          tail: tail,
          startLine: line,
          page: page,
          section: section);
      if (mounted) {
        setState(() {
          _part = part;
          _offset = part['startOffset'] as int;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '读取失败：$e');
    }
  }

  Future<void> _search() async {
    try {
      final result =
          await widget.workspace.searchFile(widget.file.id, _query.text);
      if (mounted) {
        setState(() => _matches = (result['matches'] as List)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList());
      }
    } catch (e) {
      _notice('检索失败：$e');
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _locate() async {
    final position = TextEditingController();
    var mode = 'line';
    final result = await showDialog<(String, String)>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('定位原文'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButton<String>(
                          value: mode,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                                value: 'line', child: Text('行号')),
                            if (widget.file.pageCount > 0)
                              const DropdownMenuItem(
                                  value: 'page', child: Text('页码')),
                            const DropdownMenuItem(
                                value: 'section', child: Text('章节标题')),
                          ],
                          onChanged: (m) => update(() => mode = m!)),
                      TextField(
                          controller: position,
                          decoration: const InputDecoration(
                              labelText: '位置（行/页从 1 开始）')),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(ctx, (mode, position.text.trim())),
                          child: const Text('读取'))
                    ])));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    position.dispose();
    if (result == null || !mounted) return;
    final (type, value) = result;
    final number = int.tryParse(value);
    if (type != 'section' && (number == null || number < 1)) {
      _notice('请输入有效位置');
      return;
    }
    await _read(
        line: type == 'line' ? number : null,
        page: type == 'page' ? number : null,
        section: type == 'section' ? value : null);
  }

  Future<void> _export({int? revision}) async {
    try {
      final record = await widget.workspace
          .getRevision(widget.file.id, revision: revision);
      final result = await widget.transfer.saveBytes(
          Uint8List.fromList(utf8.encode(record.content)),
          fileName: revision == null
              ? widget.file.name
              : 'v$revision-${widget.file.name}',
          dialogTitle: '导出工作区文件');
      if (result.saved) _notice('文件已导出');
    } catch (e) {
      _notice('导出失败：$e');
    }
  }

  Future<void> _versions() async {
    final revisions = await widget.workspace.revisions(widget.file.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .65,
            child: ListView(children: [
              const ListTile(title: Text('文件版本')),
              for (final revision in revisions)
                ListTile(
                    title: Text(
                        'v${revision.revision} · ${revision.content.length} 字符'),
                    subtitle: Text(revision.note),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _revision(revision);
                    }),
            ])));
  }

  Future<void> _revision(AgentWorkspaceRevision revision) async {
    final current = await widget.workspace.getRevision(widget.file.id);
    if (!mounted) return;
    final difference = workspaceVersionDiff(revision.content, current.content);
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (ctx) => Scaffold(
                appBar: AppBar(
                    title: Text('v${revision.revision} → v${current.revision}'),
                    actions: [
                      if (Platform.operatingSystem != 'ohos')
                        IconButton(
                            tooltip: '导出此版本',
                            onPressed: () =>
                                _export(revision: revision.revision),
                            icon: const Icon(Icons.save_alt)),
                    ]),
                body: ListView(padding: const EdgeInsets.all(16), children: [
                  const Text('旧版本与当前版本的差异（− 旧版本，＋ 当前版本）'),
                  SelectableText(difference,
                      style: const TextStyle(fontFamily: 'monospace')),
                  if (!widget.readOnly && revision.revision != current.revision)
                    FilledButton(
                        onPressed: () async {
                          try {
                            await widget.workspace.writeFile(
                                fileId: widget.file.id,
                                name: widget.file.name,
                                content: revision.content,
                                note: '恢复 v${revision.revision}');
                            if (ctx.mounted) Navigator.pop(ctx);
                            await _read();
                          } catch (e) {
                            _notice('恢复失败：$e');
                          }
                        },
                        child: const Text('恢复为新版本')),
                ]))));
  }

  @override
  Widget build(BuildContext context) {
    final part = _part;
    final content = part?['content'] as String? ?? '';
    return Scaffold(
        appBar: AppBar(title: Text(widget.file.name), actions: [
          if (widget.file.kind == 'output')
            IconButton(
                tooltip: '版本与差异',
                icon: const Icon(Icons.history),
                onPressed: _versions),
          if (!widget.readOnly && widget.file.kind == 'output')
            IconButton(
                tooltip: '编辑成果',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final revision =
                      await widget.workspace.getRevision(widget.file.id);
                  if (!context.mounted) return;
                  await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => _WorkspaceEditor(
                              workspace: widget.workspace,
                              file: widget.file,
                              content: revision.content)));
                  await _read();
                }),
          if (Platform.operatingSystem != 'ohos')
            IconButton(
                tooltip: '导出文件',
                icon: const Icon(Icons.save_alt),
                onPressed: () => _export()),
        ]),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Expanded(
                    child: TextField(
                        controller: _query,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(hintText: '搜索文件内容'))),
                IconButton(
                    tooltip: '检索',
                    onPressed: _search,
                    icon: const Icon(Icons.search)),
                IconButton(
                    tooltip: '定位行、页或章节',
                    onPressed: _locate,
                    icon: const Icon(Icons.my_location)),
              ])),
          if (_matches.isNotEmpty)
            SizedBox(
                height: 140,
                child: ListView(children: [
                  for (final match in _matches)
                    ListTile(
                        dense: true,
                        title: Text('第 ${match['line']} 行：${match['snippet']}',
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          _offset = match['offset'] as int;
                          _read();
                        }),
                ])),
          if (part != null)
            Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                    '字符 ${part['startOffset']}–${part['endOffset']} / ${part['totalChars']} · 行 ${part['startLine']}–${part['endLine']}')),
          Expanded(
              child: _error != null
                  ? Center(child: Text(_error!))
                  : part == null
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(content,
                              style:
                                  const TextStyle(fontFamily: 'monospace')))),
          SafeArea(
              top: false,
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                        onPressed: _offset == 0
                            ? null
                            : () {
                                _offset = (_offset - 12000).clamp(0, _offset);
                                _read();
                              },
                        child: const Text('上一段')),
                    TextButton(
                        onPressed: () => _read(tail: true),
                        child: const Text('文件末尾')),
                    TextButton(
                        onPressed: part?['nextOffset'] == null
                            ? null
                            : () {
                                _offset = part!['nextOffset'] as int;
                                _read();
                              },
                        child: const Text('下一段')),
                  ])),
        ]));
  }
}

/// 仅展开改动附近的行，避免大文件差异在手机上一次渲染全文。
String workspaceVersionDiff(String oldContent, String newContent) {
  if (oldContent == newContent) return '内容相同';
  final before = oldContent.split('\n');
  final after = newContent.split('\n');
  var prefix = 0;
  while (prefix < before.length &&
      prefix < after.length &&
      before[prefix] == after[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before[before.length - suffix - 1] == after[after.length - suffix - 1]) {
    suffix++;
  }
  final lines = <String>[
    '@@ 第 ${prefix + 1} 行 @@',
    ...before
        .sublist(prefix, before.length - suffix)
        .take(200)
        .map((line) => '- $line'),
    ...after
        .sublist(prefix, after.length - suffix)
        .take(200)
        .map((line) => '+ $line'),
    if (before.length - prefix - suffix > 200 ||
        after.length - prefix - suffix > 200)
      '… 差异较长，仅预览前 200 行；可导出完整版本。'
  ];
  return lines.join('\n');
}
