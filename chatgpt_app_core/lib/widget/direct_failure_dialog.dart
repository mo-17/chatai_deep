import 'package:flutter/material.dart';
import 'package:chatgpt_app_core/chat/application/direct_failure_recovery.dart';

Future<DirectRetryPermit?> showDirectFailureDialog(
    BuildContext context, DirectFailureRecovery recovery,
    {String? requestNotice}) async {
  if (!recovery.current) return null;
  final parent = ModalRoute.of(context);
  final route = DialogRoute<DirectRetryPermit>(
      context: context,
      builder: (_) => DirectFailureDialog(
          recovery: recovery, requestNotice: requestNotice));
  recovery.windowCurrent = () =>
      context.mounted &&
      (route.isActive ? route.isCurrent : parent?.isCurrent ?? true);
  final answer = await Navigator.of(context, rootNavigator: true).push(route);
  recovery.windowCurrent = () => context.mounted && (parent?.isCurrent ?? true);
  if (answer == null) recovery.cancel();
  return answer?.current == true ? answer : null;
}

class DirectFailureDialog extends StatefulWidget {
  final DirectFailureRecovery recovery;
  final String? requestNotice;
  const DirectFailureDialog(
      {super.key, required this.recovery, this.requestNotice});
  @override
  State<DirectFailureDialog> createState() => _DirectFailureDialogState();
}

class _DirectFailureDialogState extends State<DirectFailureDialog> {
  String? _selected;
  bool _closed = false;
  void _confirm(String? id) {
    if (_closed || id == null) return;
    final permit = widget.recovery.confirm(id);
    if (permit == null) {
      setState(() => _closed = true);
      return;
    }
    _closed = true;
    Navigator.pop(context, permit);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recovery;
    final choices = r.choices;
    final original = r.originalChoice;
    return AlertDialog(
        title: const Text('直连请求未完成'),
        content: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(r.safeReason),
              Text('原配置：${r.originalLabel}'),
              if (widget.requestNotice != null) Text(widget.requestNotice!),
              if (r.mayHaveBeenProcessed)
                const Text('上游可能已处理或计费。新请求可能重复；原输出和失败状态会保留。'),
              const Text('以下仅为本账号已配置的选项，未探测在线可用性；只用于这次新请求。'),
              DropdownButton<String>(
                  key: const ValueKey('direct_recovery_choice'),
                  isExpanded: true,
                  value: _selected,
                  hint: const Text('选择其他服务商 / 模型'),
                  items: choices
                      .map((c) =>
                          DropdownMenuItem(value: c.id, child: Text(c.label)))
                      .toList(),
                  onChanged:
                      _closed ? null : (id) => setState(() => _selected = id)),
              if (_closed || !r.current) const Text('原请求环境已变化，请关闭后重新核对'),
            ])),
        actions: [
          TextButton(
              key: const ValueKey('direct_recovery_cancel'),
              onPressed: () {
                if (_closed && !mounted) return;
                widget.recovery.cancel();
                Navigator.pop(context);
              },
              child: const Text('取消')),
          TextButton(
              key: const ValueKey('direct_recovery_original'),
              onPressed: _closed || original == null
                  ? null
                  : () => _confirm(original.id),
              child: const Text('确认原配置重试')),
          FilledButton(
              key: const ValueKey('direct_recovery_confirm'),
              onPressed: _closed || _selected == null || !r.current
                  ? null
                  : () => _confirm(_selected),
              child: const Text('确认新请求')),
        ]);
  }
}
