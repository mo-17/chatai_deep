import 'package:flutter/material.dart';
import 'package:login_sdk/dao/backend_host.dart';
import '../backup/backup_service.dart';
import '../dao/ai_catalog_dao.dart';
import '../dao/ai_settings_dao.dart';
import '../db/hi_db_manager.dart';
import '../db/knowledge_dao.dart';
import '../knowledge/semantic_embedding.dart';
import '../model/ai_provider.dart';
import '../model/knowledge_model.dart';

class SemanticKnowledgeSettingsPage extends StatefulWidget {
  const SemanticKnowledgeSettingsPage({super.key});
  @override
  State<SemanticKnowledgeSettingsPage> createState() =>
      _SemanticKnowledgeSettingsPageState();
}

class _SemanticKnowledgeSettingsPageState
    extends State<SemanticKnowledgeSettingsPage> with WidgetsBindingObserver {
  late final _identity = AiCatalogIdentity.capture();
  late final _restore = BackupService.restoreTick.value;
  SemanticKnowledgeIndex? _index;
  final _model = TextEditingController();
  final _selected = <int>{};
  List<KnowledgeDoc> _docs = [];
  List<AiProvider> _providers = [];
  String? _provider;
  bool _enabled = false, _busy = false, _cancelled = false;
  double _minimum = .35;
  int _indexed = 0;
  String? _notice;
  bool get _current =>
      mounted &&
      _identity.current &&
      _restore == BackupService.restoreTick.value;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AiCatalogIdentity.changes.addListener(_changed);
    BackendConfig.changes.addListener(_changed);
    BackupService.restoreTick.addListener(_changed);
    _load();
  }

  void _changed() {
    _cancelled = true;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelled = true;
  }

  @override
  void dispose() {
    _cancelled = true;
    WidgetsBinding.instance.removeObserver(this);
    AiCatalogIdentity.changes.removeListener(_changed);
    BackendConfig.changes.removeListener(_changed);
    BackupService.restoreTick.removeListener(_changed);
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db =
          await HiDBManager.instance(dbName: _identity.account ?? 'guest');
      if (!_current) return;
      final index = await SemanticKnowledgeIndex.create(db),
          knowledge = await KnowledgeDao.create(db);
      final config = await index.config(),
          docs = await knowledge.getDocuments(),
          indexed = await index.indexed();
      if (!_current) return;
      setState(() {
        _index = index;
        _enabled = config.enabled;
        _provider = config.providerId;
        _model.text = config.model;
        _minimum = config.minimumScore;
        _providers = AISettingsDao.load()
            .providers
            .where((p) => p.enabled)
            .map((p) => p.copy())
            .toList();
        _docs = docs.where((d) => !d.archived).toList();
        _selected.addAll(_docs.take(100).map((d) => d.id!));
        _indexed = indexed;
      });
    } catch (_) {
      if (mounted) setState(() => _notice = '语义检索设置未能加载，请返回重试');
    }
  }

  void _verify() {
    if (!_current || _cancelled) throw const FormatException('索引已停止或环境已变化');
  }

  Future<bool> _confirm(String title, String text) async {
    if (!_current) return false;
    return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                        title: Text(title),
                        content: SingleChildScrollView(child: Text(text)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('确认')),
                        ])) ==
            true &&
        _current;
  }

  Future<void> _save() async {
    if (_busy || _index == null || !_current) return;
    _cancelled = false;
    try {
      final provider = _providers.where((p) => p.id == _provider).firstOrNull;
      if (_enabled &&
          (provider == null ||
              provider.apiKey.isEmpty ||
              _model.text.trim().isEmpty)) {
        throw const FormatException('请先在 AI 服务设置中配置服务商密钥，再填写其 Embedding 模型名');
      }
      final endpoint = provider == null
          ? ''
          : SemanticEmbeddingClient.endpointFor(provider).toString();
      if (_enabled &&
          !await _confirm(
              '启用语义检索',
              '索引使用 ${provider!.name}（${Uri.parse(endpoint).authority}）的 ${_model.text.trim()}。\n\n'
                  '点击建立索引时，选中的资料片段会发送给该服务；启用后，知识助手的问题也会发送给它计算向量，可能产生服务商费用。向量缓存在本机，不纳入云同步和备份。\n\n'
                  '这项能力使用你配置的服务商密钥，不使用官方聊天试用额度。')) {
        return;
      }
      _verify();
      await _index!.configure(
          SemanticConfig(
              enabled: _enabled,
              providerId: provider?.id ?? '',
              model: _model.text.trim(),
              endpoint: endpoint,
              minimumScore: _minimum),
          _verify);
      if (_current) setState(() => _notice = '设置已保存；新导入或修订资料后，请手动建立索引');
    } on FormatException catch (e) {
      if (_current) setState(() => _notice = e.message.toString());
    }
  }

  Future<void> _build() async {
    if (_busy || _index == null || !_current) return;
    if (!await _confirm('建立所选资料索引',
        '将所选 ${_selected.length} 篇资料的文字片段发送给已保存的 Embedding 服务配置。请先保存设置；本次只处理选中的资料，不自动上传后续新资料。')) {
      return;
    }
    if (!_current) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _notice = '正在准备资料';
    });
    try {
      final config = await _index!.config();
      final client = SemanticEmbeddingClient.capture(config,
          additionalCurrent: () => _current && !_cancelled);
      await _index!.build(Set.of(_selected), verify: _verify, client: client,
          onProgress: (done, total) {
        if (_current) setState(() => _notice = '正在建立索引：$done/$total 个片段');
      });
      final indexed = await _index!.indexed();
      if (_current) {
        setState(() {
          _indexed = indexed;
          _notice = '索引已完成，可以在可信知识助手中提问';
        });
      }
    } catch (e) {
      if (_current) {
        setState(() => _notice =
            e is FormatException ? e.message.toString() : '索引未完成，请检查服务或网络后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy ||
        _index == null ||
        !await _confirm('清除本机语义索引', '只删除缓存向量，资料正文会保留。之后需要重新建立索引。')) {
      return;
    }
    _cancelled = false;
    try {
      await _index!.clear(_verify);
      if (_current) {
        setState(() {
          _indexed = 0;
          _notice = '本机语义索引已清除';
        });
      }
    } catch (_) {
      if (_current) setState(() => _notice = '索引未清除，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('知识库语义检索')),
      body: !_current
          ? const Center(child: Text('账号或后端已变化，请返回重新打开'))
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Text(
                  '在现有本地检索基础上，使用语义向量查找不同说法但含义接近的资料。索引缺失或服务失败时回退到本地词项检索。'),
              SwitchListTile(
                  title: const Text('启用语义检索'),
                  value: _enabled,
                  onChanged:
                      _busy ? null : (v) => setState(() => _enabled = v)),
              DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _providers.any((p) => p.id == _provider)
                      ? _provider
                      : null,
                  decoration: const InputDecoration(
                      labelText: 'Embedding 服务商（来自 AI 服务设置）'),
                  items: _providers
                      .map((p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged:
                      _busy ? null : (v) => setState(() => _provider = v)),
              TextField(
                  controller: _model,
                  enabled: !_busy,
                  decoration:
                      const InputDecoration(labelText: '服务商支持的 Embedding 模型名')),
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                      '最低余弦相似度：${_minimum.toStringAsFixed(2)}（排序阈值，非准确率）')),
              Slider(
                  value: _minimum,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  onChanged:
                      _busy ? null : (v) => setState(() => _minimum = v)),
              Wrap(spacing: 12, runSpacing: 8, children: [
                FilledButton(
                    onPressed: _busy || _index == null ? null : _save,
                    child: const Text('保存设置')),
                OutlinedButton(
                    onPressed: _busy || _index == null ? null : _clear,
                    child: const Text('清除本机向量'))
              ]),
              const SizedBox(height: 16),
              Text('已缓存 $_indexed 个片段 · 最多 32 MiB 向量'),
              if (_notice != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_notice!)),
              if (_busy) const LinearProgressIndicator(),
              Wrap(spacing: 12, children: [
                FilledButton(
                    onPressed: _busy || _selected.isEmpty || _index == null
                        ? null
                        : _build,
                    child: const Text('建立所选资料索引')),
                if (_busy)
                  TextButton(
                      onPressed: () => setState(() => _cancelled = true),
                      child: const Text('停止'))
              ]),
              const SizedBox(height: 12),
              for (final doc in _docs)
                CheckboxListTile(
                    value: _selected.contains(doc.id),
                    title: Text(doc.title),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              if (v == true && _selected.length < 100) {
                                _selected.add(doc.id!);
                              } else {
                                _selected.remove(doc.id);
                              }
                            })),
            ]));
}
