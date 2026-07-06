import 'dart:io';

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:flutter/material.dart';

typedef GeneratedImageAlbumLoader = Future<List<GeneratedImageAlbumItem>>
    Function();
typedef GeneratedImageAlbumDeleter = Future<bool> Function(String path);

class GeneratedImageAlbumPage extends StatelessWidget {
  final GeneratedImageAlbumLoader? loader;
  final GeneratedImageAlbumDeleter? deleter;

  const GeneratedImageAlbumPage({super.key, this.loader, this.deleter});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('生成图片相册'),
        centerTitle: true,
      ),
      body: _GeneratedImageAlbumBody(
        loader: loader ?? GeneratedImageSaveService.listSavedImages,
        deleter: deleter ?? GeneratedImageSaveService.deleteSavedImage,
      ),
    );
  }
}

class _GeneratedImageAlbumBody extends StatefulWidget {
  final GeneratedImageAlbumLoader loader;
  final GeneratedImageAlbumDeleter deleter;

  const _GeneratedImageAlbumBody({
    required this.loader,
    required this.deleter,
  });

  @override
  State<_GeneratedImageAlbumBody> createState() =>
      _GeneratedImageAlbumBodyState();
}

class _GeneratedImageAlbumBodyState extends State<_GeneratedImageAlbumBody> {
  late Future<List<GeneratedImageAlbumItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _reload() {
    setState(() {
      _future = widget.loader();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<GeneratedImageAlbumItem>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ErrorState(
              message: '加载相册失败：${snapshot.error}', onRetry: _reload);
        }
        final items = snapshot.data ?? const <GeneratedImageAlbumItem>[];
        if (items.isEmpty) {
          return _EmptyState(onRefresh: _reload);
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => _ImageTile(
              items[index],
              onDelete: () => _delete(items[index]),
            ),
          ),
        );
      },
    );
  }

  Future<void> _delete(GeneratedImageAlbumItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除图片'),
        content: Text('确定删除「${item.filename}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final deleted = await widget.deleter(item.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(deleted ? '已删除「${item.filename}」' : '图片已不存在')),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }
}

class _ImageTile extends StatelessWidget {
  final GeneratedImageAlbumItem item;
  final VoidCallback onDelete;

  const _ImageTile(this.item, {required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: cs.surfaceContainerHighest,
              child: Image.file(
                File(item.path),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatSize(item.sizeBytes)} · ${_formatDate(item.modifiedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除图片',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  static String _formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onRefresh;

  const _EmptyState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined, size: 44),
          const SizedBox(height: 12),
          Text('还没有保存的生成图片', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
