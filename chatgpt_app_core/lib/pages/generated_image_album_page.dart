import 'dart:io';
import 'dart:math' as math;

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
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

  Future<void> _reload() async {
    final next = widget.loader();
    setState(() {
      _future = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder 会展示具体错误；刷新手势只需等待其结束。
    }
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
          onRefresh: _reload,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(1);
              const horizontalPadding = 24.0;
              const maxTileExtent = 260.0;
              const crossAxisSpacing = 10.0;
              final crossAxisExtent =
                  math.max(1.0, constraints.maxWidth - horizontalPadding);
              final crossAxisCount = math.max(
                1,
                (crossAxisExtent / (maxTileExtent + crossAxisSpacing)).ceil(),
              );
              final tileExtent =
                  (crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1)) /
                      crossAxisCount;
              final imageCacheWidth = math.max(
                1,
                (tileExtent * MediaQuery.devicePixelRatioOf(context)).ceil(),
              );
              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxTileExtent,
                  crossAxisSpacing: crossAxisSpacing,
                  mainAxisSpacing: 10,
                  childAspectRatio: textScale > 1.3 ? 0.66 : 0.78,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) => _ImageTile(
                  items[index],
                  cacheWidth: imageCacheWidth,
                  onDelete: () => _delete(items[index]),
                ),
              );
            },
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
            style: AppVisualTheme.of(ctx).isAnime
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  )
                : null,
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
  final int cacheWidth;
  final VoidCallback onDelete;

  const _ImageTile(
    this.item, {
    required this.cacheWidth,
    required this.onDelete,
  });

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
              child: Semantics(
                image: true,
                label: '生成图片 ${item.filename}',
                child: Image.file(
                  File(item.path),
                  fit: BoxFit.cover,
                  cacheWidth: cacheWidth,
                  errorBuilder: (_, __, ___) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.broken_image_outlined,
                              color: cs.onSurfaceVariant),
                          const SizedBox(height: 6),
                          Text(
                            '图片无法读取',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
    final classic = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined, size: 44),
          const SizedBox(height: 12),
          Text(
            '还没有保存的生成图片',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
    return AppVisualEmptyState(
      icon: Icons.photo_library_outlined,
      title: '还没有保存的生成图片',
      message: '在会话中保存模型生成的图片后，它们会出现在这里。',
      action: TextButton.icon(
        onPressed: onRefresh,
        icon: const Icon(Icons.refresh),
        label: const Text('刷新'),
      ),
      classic: classic,
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return AppVisualEmptyState(
      icon: Icons.broken_image_outlined,
      title: '相册加载失败',
      message: message,
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
      classic: Center(
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
      ),
    );
  }
}
