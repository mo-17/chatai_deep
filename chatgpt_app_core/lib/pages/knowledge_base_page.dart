import 'dart:convert';
import 'package:chatgpt_app_core/widget/knowledge_import_progress_dialog.dart';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_import_collection.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/platform/app_file_picker.dart';
import 'package:flutter/material.dart';
import 'knowledge_assistant_page.dart';
import 'team_knowledge_page.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_library.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';

/// 知识库管理页（L4a）：导入文档（粘贴文本 / PDF、文本文件）/ 列表 / 删除。
/// 导入的文档供绑定了「知识库检索」工具的助手按关键词检索作答。
class KnowledgeBasePage extends StatefulWidget {
  final HiDBManager? storage;
  final bool Function()? isCurrent;
  final Future<List<String>> Function()? selectFiles;
  const KnowledgeBasePage(
      {super.key, this.storage, this.isCurrent, this.selectFiles});

  @override
  State<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends State<KnowledgeBasePage> {
  KnowledgeDao? _dao;
  List<KnowledgeDoc> _docs = [];
  bool _loading = true;
  Object? _loadError;
  KnowledgeLibrary? _library;
  final _filter = TextEditingController();
  String? _folder, _tag;
  bool _includeArchived = false;
  bool _directorySupported = false;
  int _loadEpoch = 0;
  bool _importBusy = false;
  ImportCancellation? _activeImport;
  late final _identity = AiCatalogIdentity.capture();

  @override
  void initState() {
    super.initState();
    AiCatalogIdentity.changes.addListener(_identityChanged);
    _doInit();
    KnowledgeImportCollection.supportsDirectorySelection().then((value) {
      if (mounted) setState(() => _directorySupported = value);
    });
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  void _doInit() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final dbManager = widget.storage ??
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      _dao = await KnowledgeDao.create(dbManager);
      _library = await KnowledgeLibrary.create(dbManager);
      if (!mounted) return;
      await _loadData();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showConflicts() async {
    final rows = await _library!.conflicts();
    if (!mounted || !_identity.current) return;
    final heads = <int, String?>{};
    for (final row in rows) {
      heads[row['id'] as int] = await _library!.headHash(row['uid'] as String);
    }
    if (!mounted || !_identity.current) return;
    final chosen = await showModalBottomSheet<(int, String)>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
            child: SizedBox(
                height: 500,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  const Text('知识同步冲突',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const Text('当前版本未被覆盖。比较外来快照后，可选择生成新修订，原有分支均保留在修订历史。'),
                  if (rows.isEmpty) const Text('暂无待处理冲突'),
                  for (final row in rows)
                    Builder(builder: (_) {
                      final record =
                          jsonDecode(row['payload'] as String) as Map;
                      final data = record['kind'] == 'document'
                          ? record['snapshot'] as Map
                          : jsonDecode(record['payload'] as String) as Map;
                      final answer = record['kind'] == 'answer';
                      final title = answer
                          ? data['question'] as String
                          : (data['document'] as Map)['title'] as String;
                      final body = answer
                          ? (data['claims'] as List)
                              .map((c) => c['text'])
                              .join('\n')
                          : (data['chunks'] as List)
                              .map((c) => c['content'])
                              .join('\n\n');
                      return ExpansionTile(title: Text(title), children: [
                        SelectableText(body),
                        if (!answer)
                          TextButton(
                              onPressed: () => Navigator.pop(
                                  ctx, (row['id'] as int, 'copy')),
                              child: const Text('另存为新文档')),
                        if (!answer && heads[row['id']] != null)
                          Wrap(children: [
                            TextButton(
                                onPressed: () => Navigator.pop(
                                    ctx, (row['id'] as int, 'local')),
                                child: const Text('保留本机，生成新修订')),
                            TextButton(
                                onPressed: () => Navigator.pop(
                                    ctx, (row['id'] as int, 'incoming')),
                                child: const Text('采用传入，生成新修订'))
                          ]),
                      ]);
                    }),
                ]))));
    if (chosen == null || !mounted || !_identity.current) return;
    try {
      if (chosen.$2 == 'copy') {
        await _library!.copyConflict(chosen.$1);
      } else {
        await _library!.resolveConflict(chosen.$1,
            incoming: chosen.$2 == 'incoming', expectedHead: heads[chosen.$1]!);
      }
      await _loadData();
    } catch (_) {
      if (mounted) HiDialog.showSnackBar(context, '冲突副本未保存，原记录保留；正文可能已存在。');
    }
  }

  Future<void> _loadData() async {
    if (!_identity.current) return;
    final epoch = ++_loadEpoch;
    final list = await _library!.list(
        query: _filter.text,
        folder: _folder,
        tag: _tag,
        includeArchived: _includeArchived);
    if (!_identity.current || epoch != _loadEpoch) return;
    setState(() => _docs = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知识库'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
              tooltip: '知识库操作',
              enabled: !_loading && _identity.current,
              onSelected: (action) async {
                if (action == 'team') {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const TeamKnowledgePage()));
                } else if (action == 'conflicts') {
                  await _showConflicts();
                } else {
                  await _rebuildVectorIndex();
                }
              },
              itemBuilder: (_) => const [
                    PopupMenuItem(value: 'team', child: Text('团队知识库')),
                    PopupMenuItem(value: 'conflicts', child: Text('同步冲突')),
                    PopupMenuItem(value: 'index', child: Text('重建检索索引'))
                  ]),
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: '可信知识助手',
            onPressed: _loading || _dao == null
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const KnowledgeAssistantPage())),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: '导入文档',
            enabled: !_loading && _dao != null,
            onSelected: (mode) {
              if (mode == 'files') {
                _importFile();
              } else {
                _importCollection(mode == 'zip');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'files', child: Text('选择文件（可多选）')),
              if (_directorySupported)
                const PopupMenuItem(value: 'directory', child: Text('导入文件夹')),
              const PopupMenuItem(value: 'zip', child: Text('导入资料 ZIP')),
            ],
          ),
        ],
      ),
      body: _body,
      floatingActionButton: FloatingActionButton(
        onPressed: _loading || _dao == null ? null : _addDocument,
        tooltip: '粘贴文本导入',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget get _body {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppVisualEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '知识库加载失败',
        message: _loadError.toString(),
        action: FilledButton.icon(
          onPressed: _doInit,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    if (!_identity.current) return const Center(child: Text('账号已变化，请返回并重新打开'));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
              controller: _filter,
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), labelText: '搜索标题、文件夹或标签'),
              onChanged: (_) => _loadData())),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            TextButton(
                onPressed: () => _chooseFilter(),
                child: Text('范围：${_folder ?? '全部文件夹'} / ${_tag ?? '全部标签'}')),
            FilterChip(
                label: const Text('显示失效资料'),
                selected: _includeArchived,
                onSelected: (v) {
                  setState(() => _includeArchived = v);
                  _loadData();
                }),
          ])),
      Expanded(child: _docs.isEmpty ? _emptyView : _listView),
    ]);
  }

  Widget get _emptyView => AppVisualEmptyState(
        icon: Icons.local_library_outlined,
        title: '还没有知识库文档',
        message: '粘贴文本或导入 PDF / 文本 / 图片，再给助手绑定「知识库检索」工具即可问答。',
        classic: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('📚', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                  '还没有文档。右下角粘贴文本、或右上角导入 PDF/文本文件，\n'
                  '再给助手绑定「知识库检索」工具即可问答。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget get _listView => ListView.builder(
        padding: AppVisualTheme.of(context).isAnime
            ? const EdgeInsets.fromLTRB(12, 12, 12, 20)
            : EdgeInsets.zero,
        itemCount: _docs.length,
        itemBuilder: (context, index) {
          final d = _docs[index];
          final tile = ListTile(
            leading:
                const CircleAvatar(child: Icon(Icons.description_outlined)),
            title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${d.folder.isEmpty ? '未分类' : d.folder} · v${d.revision} · '
                '${d.chunkCount} 个片段${d.archived ? ' · 已失效' : ''}\n${d.tags.join(' · ')}'),
            onTap: () => _manageDocument(d),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () => _delete(d),
            ),
          );
          return AppVisualSurface(
            padding: EdgeInsets.zero,
            margin: AppVisualTheme.of(context).isAnime
                ? const EdgeInsets.only(bottom: 8)
                : EdgeInsets.zero,
            child: tile,
          );
        },
      );

  void _identityChanged() {
    if (!_identity.current) _activeImport?.cancel();
  }

  bool get _importCurrent =>
      mounted && _identity.current && widget.isCurrent?.call() != false;

  Future<KnowledgeFileImportResult?> _runImport(List<String> paths) async {
    if (!_importCurrent || _dao == null) return null;
    final operation = ImportCancellation();
    _activeImport = operation;
    final progress = ValueNotifier(
        KnowledgeImportProgress(completed: 0, total: paths.length));
    try {
      return await withKnowledgeImportProgress(context,
          progress: progress,
          cancellation: operation,
          task: () => KnowledgeFileImporter(_dao!,
                  account: _identity.account ?? 'guest',
                  isCurrent: () => _importCurrent)
              .importPaths(paths,
                  cancellation: operation,
                  limits: AISettingsDao.load().attachmentProcessingLimits,
                  onProgress: (value) => progress.value = value));
    } finally {
      _activeImport = null;
    }
  }

  Future<KnowledgeFileImportResult?> _presentImport(List<String> paths) async {
    final result = await _runImport(paths);
    if (!mounted || !_importCurrent || result == null) return null;
    HiDialog.showSnackBar(context, result.message);
    if (result.imported > 0) await _loadData();
    return result;
  }

  /// 普通文件、ZIP 与目录都走同一个账号守卫、进度及重试路径。
  Future<void> _importFile() async {
    if (_importBusy || !_importCurrent) return;
    _importBusy = true;
    try {
      final paths = await (widget.selectFiles?.call() ?? _selectImportFiles());
      if (!mounted || !_importCurrent) return;
      if (paths.isEmpty) return;
      final result = await _presentImport(paths);
      if (_importCurrent && result != null) await _showImportDetails(result);
    } catch (error) {
      if (mounted && _importCurrent) {
        HiDialog.showSnackBar(
            context, KnowledgeImportFailure.from(error).message);
      }
    } finally {
      _importBusy = false;
    }
  }

  Future<List<String>> _selectImportFiles() async {
    final selected = await FilePicker.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        withData: false,
        allowedExtensions: [
          ...FileProcessor.pickerExtensions,
          if (OcrService.isSupported) ...OcrService.imageExtensions,
        ]);
    return [
      for (final file in selected?.files ?? const <PlatformFile>[])
        if (file.path != null) file.path!
    ];
  }

  Future<void> _importCollection(bool zip) async {
    if (_importBusy || !_importCurrent) return;
    _importBusy = true;
    KnowledgeImportCollection? collection;
    String? pickedDirectory;
    try {
      final String? path;
      if (zip) {
        final picked = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['zip'],
            withData: false);
        path = picked?.files.firstOrNull?.path;
      } else {
        path = await FilePicker.getDirectoryPath(dialogTitle: '选择要导入的资料文件夹');
        pickedDirectory = path;
      }
      if (path == null || !mounted || !_importCurrent) return;
      final prepared = await _withLoading(
          '正在检查资料…',
          () => zip
              ? KnowledgeImportCollection.fromZip(path!)
              : KnowledgeImportCollection.fromDirectory(path!));
      collection = prepared;
      if (!mounted || !_importCurrent) return;
      if (prepared.paths.isEmpty) {
        HiDialog.showSnackBar(context, '所选资料中没有文件');
        return;
      }
      final result = await _presentImport(prepared.paths);
      // 在明细及全部重试结束后才释放集合的临时文件。
      if (_importCurrent && result != null) await _showImportDetails(result);
    } catch (error) {
      if (mounted && _importCurrent) {
        HiDialog.showSnackBar(
            context, KnowledgeImportFailure.from(error).message);
      }
    } finally {
      try {
        await collection?.dispose();
      } catch (_) {}
      if (pickedDirectory != null) {
        try {
          await KnowledgeImportCollection.releasePickedDirectory(
              pickedDirectory);
        } catch (_) {}
      }
      _importBusy = false;
    }
  }

  Future<void> _rebuildVectorIndex() async {
    if (_dao == null) return;
    final stats = await _withLoading(
      '正在重建检索索引…',
      () => _dao!.rebuildVectorIndex(),
    );
    if (!mounted) return;
    HiDialog.showSnackBar(
      context,
      stats.chunks == 0
          ? '暂无可索引片段'
          : '已重建 ${stats.indexed}/${stats.chunks} 个检索片段',
    );
  }

  Future<void> _showImportDetails(KnowledgeFileImportResult result) async {
    var current = result;
    while (_importCurrent && current.failedItems.isNotEmpty) {
      if (!mounted) return;
      final retry = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('未导入的文件'),
                content:
                    SingleChildScrollView(child: Text(current.detailMessage)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('关闭')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('重试未完成文件')),
                ],
              ));
      if (retry != true || !mounted || !_importCurrent) return;
      final next = await _presentImport(current.retryPaths);
      if (next == null) return;
      current = next;
    }
  }

  /// 执行一个耗时任务并显示模态加载框（OCR 可能较慢）。
  Future<T> _withLoading<T>(String label, Future<T> Function() task) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Flexible(child: Text(label)),
            ],
          ),
        ),
      ),
    );
    navigator.push(route);
    try {
      return await task();
    } finally {
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  void _addDocument() async {
    final titleCtl = TextEditingController();
    final contentCtl = TextEditingController();
    String? contentError;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('导入文档'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtl,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    hintText: '如：产品手册 / 退款政策',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  minLines: 5,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: '内容（粘贴文本）',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    errorText: contentError,
                  ),
                  onChanged: (_) {
                    if (contentError != null) {
                      setDialogState(() => contentError = null);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (contentCtl.text.trim().isEmpty) {
                  setDialogState(() => contentError = '内容不能为空');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    final title = titleCtl.text;
    final text = contentCtl.text.trim();
    titleCtl.dispose();
    contentCtl.dispose();
    if (ok != true) return;
    if (!_identity.current) return;
    int? docId;
    try {
      docId = await _library!.add(title, [text]);
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.toString());
      return;
    }
    if (!mounted) return;
    HiDialog.showSnackBar(
        context,
        docId == null
            ? '导入失败'
            : '已导入「${title.trim().isEmpty ? '未命名文档' : title.trim()}」');
    await _loadData();
  }

  void _delete(KnowledgeDoc d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文档'),
        content: Text('将「${d.title}」从检索库移除？已有修订、问答及原文快照保留，删除标记将参与个人同步。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || d.id == null || !_identity.current) return;
    await _dao!.deleteDocument(d.id!);
    if (!mounted) return;
    HiDialog.showSnackBar(context, '已删除「${d.title}」');
    await _loadData();
  }

  Future<void> _chooseFilter() async {
    final all = await _dao!.getDocuments();
    if (!mounted || !_identity.current) return;
    final folders = all.map((d) => d.folder).where((f) => f.isNotEmpty).toSet();
    final tags = all.expand((d) => d.tags).toSet();
    await showDialog<void>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('筛选资料'), children: [
              SimpleDialogOption(
                  onPressed: () {
                    _folder = null;
                    _tag = null;
                    Navigator.pop(ctx);
                  },
                  child: const Text('全部资料')),
              for (final f in folders)
                SimpleDialogOption(
                    onPressed: () {
                      _folder = f;
                      _tag = null;
                      Navigator.pop(ctx);
                    },
                    child: Text('文件夹：$f')),
              for (final t in tags)
                SimpleDialogOption(
                    onPressed: () {
                      _tag = t;
                      _folder = null;
                      Navigator.pop(ctx);
                    },
                    child: Text('标签：$t')),
            ]));
    if (mounted) await _loadData();
  }

  Future<void> _manageDocument(KnowledgeDoc doc) async {
    final folder = TextEditingController(text: doc.folder);
    final tags = TextEditingController(text: doc.tags.join(','));
    var archived = doc.archived;
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: Text(doc.title),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: folder,
                          maxLength: 100,
                          decoration: const InputDecoration(labelText: '文件夹')),
                      TextField(
                          controller: tags,
                          decoration:
                              const InputDecoration(labelText: '标签（逗号分隔）')),
                      CheckboxListTile(
                          value: archived,
                          title: const Text('标记失效（不参与问答）'),
                          onChanged: (v) => update(() => archived = v == true)),
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, 'history'),
                          child: const Text('修订历史')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, 'revise'),
                          child: const Text('更新正文')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, 'save'),
                          child: const Text('保存')),
                    ])));
    final f = folder.text;
    final ts = tags.text.split(RegExp('[,，]'));
    folder.dispose();
    tags.dispose();
    if (action == null || !mounted || !_identity.current) return;
    try {
      if (action == 'save') {
        await _library!.organize(doc, folder: f, tags: ts, archived: archived);
      }
      if (action == 'history') {
        final rows = await _library!.versions(doc);
        if (!mounted || !_identity.current) return;
        await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (ctx) => SafeArea(
                child: SizedBox(
                    height: MediaQuery.sizeOf(ctx).height * .75,
                    child: ListView(children: [
                      for (final r in rows)
                        ExpansionTile(
                            title: Text(
                                'v${(r['document'] as Map)['revision']} · ${doc.title}'),
                            children: [
                              Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: SelectableText((r['chunks'] as List)
                                      .map((c) => c['content'])
                                      .join('\n\n')))
                            ])
                    ]))));
      }
      if (action == 'revise') {
        if (!mounted || !_identity.current) return;
        final ctl = TextEditingController();
        final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('导入新的文字修订'),
                    content: TextField(
                        controller: ctl,
                        minLines: 5,
                        maxLines: 12,
                        decoration: const InputDecoration(
                            hintText: '旧版本及历史引用会保留；新正文不继承PDF页码')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('创建新修订'))
                    ]));
        final text = ctl.text;
        ctl.dispose();
        if (ok == true && _identity.current) await _library!.revise(doc, text);
      }
      if (mounted) await _loadData();
    } catch (e) {
      if (mounted) HiDialog.showSnackBar(context, e.toString());
    }
  }

  @override
  void dispose() {
    _activeImport?.cancel();
    AiCatalogIdentity.changes.removeListener(_identityChanged);
    _filter.dispose();
    super.dispose();
  }
}
