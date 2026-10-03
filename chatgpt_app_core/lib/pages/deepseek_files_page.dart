import 'dart:async';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_file_preview_store.dart';
import 'package:chatgpt_app_core/dao/ai_provider_api.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';

/// 管理此服务商 Key 的云端图片，不混用后端代理持有的凭据。
class DeepSeekFilesPage extends StatefulWidget {
  final String providerId;
  final AiProviderApi? api;
  final DeepSeekFilePreviewStore? previewStore;

  const DeepSeekFilesPage({
    super.key,
    required this.providerId,
    this.api,
    this.previewStore,
  });

  @override
  State<DeepSeekFilesPage> createState() => _DeepSeekFilesPageState();
}

class _DeepSeekLocalPreview extends StatefulWidget {
  final Future<Uint8List?> Function() read;
  final String fileId;
  final String filename;

  const _DeepSeekLocalPreview({
    super.key,
    required this.read,
    required this.fileId,
    required this.filename,
  });

  @override
  State<_DeepSeekLocalPreview> createState() => _DeepSeekLocalPreviewState();
}

class _DeepSeekLocalPreviewState extends State<_DeepSeekLocalPreview> {
  late final Future<Uint8List?> _preview = widget.read();

  Widget _placeholder() => const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 24),
          Text('暂无预览', style: TextStyle(fontSize: 10)),
        ],
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 56,
        height: 56,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder<Uint8List?>(
            future: _preview,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) return _placeholder();
              return Image.memory(
                bytes,
                key: ValueKey('cloud_preview_${widget.fileId}'),
                width: 56,
                height: 56,
                cacheWidth: 168,
                fit: BoxFit.cover,
                semanticLabel: '${widget.filename} 本地图片预览',
                errorBuilder: (_, __, ___) => _placeholder(),
              );
            },
          ),
        ),
      );
}

class _DeepSeekFilesPageState extends State<DeepSeekFilesPage> {
  late final AISettingsProvider _store = context.read<AISettingsProvider>();
  late final String _account;
  late final AiProvider? _connection;
  late final AiProviderApi _api = widget.api ?? AiProviderApi();
  late final DeepSeekFilePreviewStore _previews =
      widget.previewStore ?? DeepSeekFilePreviewStore.instance;
  final List<DeepSeekCloudFile> _files = [];
  final Set<Completer<void>> _requests = {};
  final Set<String> _seenCursors = {};
  bool _invalidated = false;
  bool _loading = false;
  bool _hasMore = false;
  String? _cursor;
  String? _error;
  bool _retryMore = false;
  String? _detailId;
  String? _deletingId;
  final Set<DialogRoute<dynamic>> _dialogs = {};

  String get _previewUrl => AiProviderApi.endpointFor(_connection!, 'files')
      .replace(path: '/chat/completions')
      .toString();

  AiProvider? get _currentProvider {
    final providers =
        _store.settings.providers.where((p) => p.id == widget.providerId);
    return providers.isEmpty ? null : providers.first;
  }

  bool get _busy => _loading || _detailId != null || _deletingId != null;

  bool get _configurationMatches {
    final current = _currentProvider;
    final connection = _connection;
    return !_invalidated &&
        connection != null &&
        current != null &&
        _store.accountHash == _account &&
        (LoginDao.getAccountHash() ?? 'guest') == _account &&
        current.apiKey == connection.apiKey &&
        current.apiHost == connection.apiHost &&
        current.type == connection.type;
  }

  bool get _canUse => mounted && _configurationMatches;

  @override
  void initState() {
    super.initState();
    // 在首帧前固定凭据和账号；页面不会随设置变化悄悄切换远端账户。
    _account = _store.accountHash;
    _connection = _currentProvider?.copy();
    _store.addListener(_configurationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  void _configurationChanged() {
    if (!mounted || _configurationMatches) return;
    for (final abort in _requests) {
      if (!abort.isCompleted) abort.complete();
    }
    setState(() {
      _invalidated = true;
      _files.clear();
      _error = null;
      _loading = false;
      _detailId = null;
      _deletingId = null;
    });
    for (final route in _dialogs.toList().reversed) {
      if (route.isActive) route.navigator?.removeRoute(route);
    }
  }

  Future<T?> _showManagedDialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    _dialogs.add(route);
    try {
      return await Navigator.of(context).push(route);
    } finally {
      _dialogs.remove(route);
    }
  }

  Future<Uint8List?> _readPreview(String id) => _previews.read(
        accountHash: _account,
        chatCompletionsUrl: _previewUrl,
        apiKey: _connection!.apiKey,
        fileId: id,
      );

  @override
  void dispose() {
    _store.removeListener(_configurationChanged);
    for (final abort in _requests) {
      if (!abort.isCompleted) abort.complete();
    }
    super.dispose();
  }

  Completer<void> _beginRequest() {
    final abort = Completer<void>();
    _requests.add(abort);
    return abort;
  }

  void _endRequest(Completer<void> abort) {
    _requests.remove(abort);
    if (!abort.isCompleted) abort.complete();
  }

  String _errorMessage(Object error) =>
      error is AiProviderApiException ? error.message : '请求失败，请检查网络后重试';

  Future<void> _load({bool more = false}) async {
    if (!_canUse || _busy || (more && !_hasMore)) return;
    final connection = _connection!;
    if (!AiProviderApi.supportsDeepSeekFiles(connection)) return;
    final after = more ? _cursor : null;
    final abort = _beginRequest();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.listDeepSeekFiles(
        connection,
        after: after,
        abortTrigger: abort.future,
      );
      if (!_canUse) return;
      if (more && page.hasMore && _seenCursors.contains(page.lastId)) {
        throw const AiProviderApiException('文件分页游标重复，请刷新后重试');
      }
      setState(() {
        if (!more) {
          _files.clear();
          _seenCursors.clear();
        }
        final ids = _files.map((file) => file.id).toSet();
        _files.addAll(page.files.where((file) => ids.add(file.id)));
        _cursor = page.lastId;
        if (page.lastId != null) _seenCursors.add(page.lastId!);
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (_canUse) {
        setState(() {
          _error = _errorMessage(error);
          _retryMore = more;
        });
      }
    } finally {
      _endRequest(abort);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showDetails(DeepSeekCloudFile file) async {
    if (!_canUse || _busy) return;
    final abort = _beginRequest();
    setState(() => _detailId = file.id);
    DeepSeekCloudFile? latest;
    Uint8List? preview;
    try {
      latest = await _api.getDeepSeekFile(
        _connection!,
        file.id,
        abortTrigger: abort.future,
      );
      if (_canUse) preview = await _readPreview(file.id);
    } catch (error) {
      if (mounted && _canUse) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
      }
    } finally {
      _endRequest(abort);
      if (mounted) setState(() => _detailId = null);
    }
    if (!mounted || !_canUse || latest == null) return;
    final info = latest;
    final delete = await _showManagedDialog<bool>(
      (dialogContext) {
        return AlertDialog(
          title: const Text('文件详情'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (preview != null) ...[
                  InkWell(
                    onTap: () => _showImage(info, preview!),
                    child: Image.memory(
                      preview,
                      key: ValueKey('detail_preview_${info.id}'),
                      height: 180,
                      width: 320,
                      fit: BoxFit.contain,
                      semanticLabel: '${info.filename} 图片预览，点击查看大图',
                      errorBuilder: (_, __, ___) => _missingPreview(),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _showImage(info, preview!),
                    icon: const Icon(Icons.zoom_in_rounded),
                    label: const Text('查看大图'),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('本地缓存预览', style: TextStyle(fontSize: 12)),
                  ),
                ] else
                  _missingPreview(),
                _detail('文件名', info.filename),
                _detail('文件 ID', info.id),
                _detail('大小', '${_size(info.bytes)}（${info.bytes} 字节）'),
                _detail('用途', info.purpose),
                _detail('创建时间', _time(info.createdAt)),
                _detail(
                    '有效期',
                    info.expiresAt == null
                        ? '永久有效'
                        : '${_time(info.expiresAt!)}${_expired(info) ? '（已过期）' : ''}'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除文件'),
            ),
          ],
        );
      },
    );
    if (delete == true && _canUse) await _delete(info);
  }

  Widget _missingPreview() => const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('此设备暂无预览'),
            SizedBox(height: 4),
            Text('此文件没有本地预览。DeepSeek 文件接口未提供图片下载地址。',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      );

  Future<void> _showImage(DeepSeekCloudFile file, Uint8List bytes) async {
    if (!_canUse) return;
    await _showManagedDialog<void>((dialogContext) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: Text(file.filename),
              leading: IconButton(
                tooltip: '关闭图片预览',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ),
            body: Center(
              child: InteractiveViewer(
                key: const ValueKey('image_preview_viewer'),
                minScale: 1,
                maxScale: 5,
                child: Image.memory(bytes,
                    fit: BoxFit.contain,
                    semanticLabel: file.filename,
                    errorBuilder: (_, __, ___) => _missingPreview()),
              ),
            ),
          ),
        ));
  }

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SelectableText('$label：$value'),
      );

  Future<void> _delete(DeepSeekCloudFile file) async {
    if (!_canUse || _busy) return;
    final confirmed = await _showManagedDialog<bool>(
      (dialogContext) {
        return AlertDialog(
          title: const Text('删除云端文件'),
          content: SingleChildScrollView(
            child: Text('确定删除「${file.filename}」？\n\n删除后无法恢复，引用此文件的其他应用可能受影响。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !_canUse || _busy) return;
    final connection = _connection!;
    final abort = _beginRequest();
    setState(() => _deletingId = file.id);
    var deleted = false;
    try {
      await _api.deleteDeepSeekFile(
        connection,
        file.id,
        abortTrigger: abort.future,
      );
      // 已确认远端删除，即使页面已离开也要清掉同凭据的图片上传缓存。
      DeepSeekAttachmentAdapter.invalidateFile(
        chatCompletionsUrl: AiProviderApi.endpointFor(connection, 'files')
            .replace(path: '/chat/completions')
            .toString(),
        apiKey: connection.apiKey,
        fileId: file.id,
      );
      await _previews.remove(
        accountHash: _account,
        chatCompletionsUrl: _previewUrl,
        apiKey: connection.apiKey,
        fileId: file.id,
      );
      if (!mounted || !_canUse) return;
      deleted = true;
      setState(() {
        _files.removeWhere((item) => item.id == file.id);
        _cursor = null;
        _hasMore = false;
        _seenCursors.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('云端文件已删除')),
      );
    } catch (error) {
      if (mounted && _canUse) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
      }
    } finally {
      _endRequest(abort);
      if (mounted) setState(() => _deletingId = null);
    }
    // 删除分页尾项会使 after 游标失效；刷新首批文件，重新取得服务端游标。
    if (deleted && _canUse) await _load();
  }

  bool _expired(DeepSeekCloudFile file) =>
      file.expiresAt != null &&
      file.expiresAt! <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  String _time(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final connection = _connection;
    final usable = _configurationMatches &&
        connection != null &&
        AiProviderApi.supportsDeepSeekFiles(connection);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('云端文件'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: usable && !_busy ? () => _load() : null,
          ),
        ],
      ),
      body: !usable
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('账号或服务配置已变化，请返回重新打开'),
            ))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  const Text('此 API Key 的 DeepSeek 云端图片文件'),
                  const SizedBox(height: 8),
                  Text('已加载 ${_files.length} 个 · 最新上传优先',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text('本机上传的新图片可预览；其他设备或旧文件可能暂无预览。',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: cs.error)),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _load(more: _retryMore),
                      child: const Text('重试'),
                    ),
                  ],
                  if (_loading && _files.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_files.isEmpty && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无云端文件')),
                    ),
                  for (final file in _files)
                    Card(
                      key: ValueKey('cloud_file_${file.id}'),
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                        leading: _detailId == file.id || _deletingId == file.id
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : _DeepSeekLocalPreview(
                                key: ValueKey('preview_loader_${file.id}'),
                                read: () => _readPreview(file.id),
                                fileId: file.id,
                                filename: file.filename,
                              ),
                        title: Text(file.filename,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${_size(file.bytes)} · ${_time(file.createdAt)}'
                            '${_expired(file) ? '\n已过期' : ''}'),
                        onTap: _busy ? null : () => _showDetails(file),
                        trailing: IconButton(
                          key: ValueKey('delete_file_${file.id}'),
                          tooltip: '删除文件',
                          icon: Icon(Icons.delete_outline_rounded,
                              color: cs.error),
                          onPressed: _busy ? null : () => _delete(file),
                        ),
                      ),
                    ),
                  if (_loading && _files.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_hasMore)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _load(more: true),
                      child: const Text('加载更多'),
                    ),
                ],
              ),
            ),
    );
  }
}
