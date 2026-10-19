import 'package:flutter/material.dart';
import '../chat/application/import_operation.dart';

class KnowledgeImportProgressDialog extends StatefulWidget {
  final ValueNotifier<KnowledgeImportProgress> progress;
  final VoidCallback onCancel;
  const KnowledgeImportProgressDialog(
      {super.key, required this.progress, required this.onCancel});

  @override
  State<KnowledgeImportProgressDialog> createState() => _ProgressState();
}

class _ProgressState extends State<KnowledgeImportProgressDialog> {
  bool _cancelling = false;
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: Text(_cancelling ? '正在取消导入' : '导入资料'),
        content: ValueListenableBuilder<KnowledgeImportProgress>(
            valueListenable: widget.progress,
            builder: (context, value, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                          value: value.total == 0
                              ? null
                              : value.completed / value.total),
                      const SizedBox(height: 16),
                      Text(value.label),
                      const SizedBox(height: 12),
                      Text(_cancelling ? '正在等待当前任务释放资源…' : '取消会保留已导入的文档。'),
                    ])),
        actions: [
          TextButton(
              onPressed: _cancelling ? null : _cancel,
              child: const Text('取消导入'))
        ],
      ));

  void _cancel() {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    widget.onCancel();
  }
}

Future<T> withKnowledgeImportProgress<T>(BuildContext context,
    {required ValueNotifier<KnowledgeImportProgress> progress,
    required ImportCancellation cancellation,
    required Future<T> Function() task}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => KnowledgeImportProgressDialog(
          progress: progress, onCancel: cancellation.cancel));
  var finished = false;
  navigator.push(route).whenComplete(() {
    if (!finished) cancellation.cancel();
  });
  try {
    return await task();
  } finally {
    finished = true;
    // 只移除本任务的弹窗；账号切换产生的新页面不能被误 pop。
    if (route.isActive) navigator.removeRoute(route);
    await route.completed;
    progress.dispose();
  }
}
