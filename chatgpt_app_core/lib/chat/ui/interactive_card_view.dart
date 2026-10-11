import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 固定原生组件；卡片字符串仅作为 Text 显示，不启动链接或执行代码。
class InteractiveCardView extends StatefulWidget {
  final CardProjection projection;
  final Set<String> checked;
  final bool writable;
  final bool insertEnabled;
  final bool Function() isCurrent;
  final Future<void> Function(String itemId, bool checked)? onCheck;
  final void Function(String text)? onInsert;

  const InteractiveCardView(
      {super.key,
      required this.projection,
      this.checked = const {},
      this.writable = false,
      this.insertEnabled = false,
      required this.isCurrent,
      this.onCheck,
      this.onInsert});

  @override
  State<InteractiveCardView> createState() => _InteractiveCardViewState();
}

class _InteractiveCardViewState extends State<InteractiveCardView> {
  bool _saving = false;

  Future<void> _check(String id, bool value) async {
    if (_saving ||
        !widget.writable ||
        !widget.isCurrent() ||
        widget.onCheck == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onCheck!(id, value);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy() async {
    if (_saving || !widget.isCurrent()) return;
    await Clipboard.setData(ClipboardData(
        text: exportInteractiveCard(widget.projection.card,
            checked: widget.checked)));
    if (mounted && widget.isCurrent()) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('卡片已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.projection.card;
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('interactive_card_${widget.projection.key}'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(card.title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: colors.onSurface)),
            const SizedBox(height: 8),
            if (card is ChecklistCard)
              for (final item in card.items)
                ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: CheckboxListTile(
                      key: ValueKey(
                          'checklist_${widget.projection.key}_${item.id}'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: widget.checked.contains(item.id),
                      title: Text(item.text,
                          style: TextStyle(color: colors.onSurface)),
                      onChanged:
                          widget.writable && !_saving && widget.isCurrent()
                              ? (value) {
                                  if (value != null) _check(item.id, value);
                                }
                              : null,
                    )),
            if (card is ComparisonCard)
              for (final row in card.rows)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row.label,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: colors.onSurface)),
                          for (final option in card.options)
                            Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                    '${option.label}：${row.values[option.id]}',
                                    style: TextStyle(color: colors.onSurface))),
                        ])),
            if (card is ChecklistCard && !widget.writable)
              Text('只读清单',
                  style:
                      TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            if (_saving)
              Text('正在保存…',
                  style:
                      TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  key: ValueKey('card_copy_${widget.projection.key}'),
                  onPressed: !_saving && widget.isCurrent() ? _copy : null,
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('复制')),
              TextButton.icon(
                  key: ValueKey('card_insert_${widget.projection.key}'),
                  onPressed: !_saving &&
                          widget.insertEnabled &&
                          widget.isCurrent() &&
                          widget.onInsert != null
                      ? () => widget.onInsert!(
                          exportInteractiveCard(card, checked: widget.checked))
                      : null,
                  icon: const Icon(Icons.edit_note_outlined, size: 18),
                  label: const Text('插入输入框')),
            ]),
          ]),
    );
  }
}
