import 'dart:async';

class ImportCancelled implements Exception {
  const ImportCancelled();
}

/// 取消只终止当前解析及后续文件，已完成的文档保留。
class ImportCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void check() {
    if (_cancelled) throw const ImportCancelled();
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

class KnowledgeImportProgress {
  final int completed, total;
  final String filename, stage;
  final int? page, pages;
  const KnowledgeImportProgress(
      {required this.completed,
      required this.total,
      this.filename = '',
      this.stage = '正在导入',
      this.page,
      this.pages});

  String get label => '$stage：$completed/$total 个文件'
      '${filename.isEmpty ? '' : '\n$filename'}'
      '${page == null ? '' : '\n第 $page/$pages 页'}';
}

/// 限时等待仅负责结束 Flutter 等待；原生资源释放前仍会拒绝并发。
void cancelNativeRequest(Future<void> Function() cancel) {
  unawaited(cancel().catchError((Object _) {}));
}
