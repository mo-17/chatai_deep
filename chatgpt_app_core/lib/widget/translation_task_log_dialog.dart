import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TranslationTaskLogDialog extends StatelessWidget {
  final String title;
  final String log;
  final String error;

  const TranslationTaskLogDialog({
    super.key,
    required this.title,
    required this.log,
    this.error = '',
  });

  @override
  Widget build(BuildContext context) {
    final text = _displayText;
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: _TranslationTaskLogView(text: text),
      ),
      actions: [
        TextButton.icon(
          onPressed: text.trim().isEmpty
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('日志已复制')),
                    );
                  }
                },
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制全部'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String get _displayText {
    final cleanLog = log.trim();
    if (cleanLog.isNotEmpty) return cleanLog;
    final cleanError = error.trim();
    return cleanError.isEmpty ? '暂无详细日志' : cleanError;
  }
}

class _TranslationTaskLogView extends StatelessWidget {
  final String text;

  const _TranslationTaskLogView({required this.text});

  @override
  Widget build(BuildContext context) {
    final entries = _LogEntry.parse(text);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: entries.isEmpty
          ? const Center(child: Text('暂无详细日志'))
          : ListView.separated(
              shrinkWrap: true,
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return entry.timeline
                    ? _TimelineLogTile(entry: entry)
                    : _RawLogBlock(entry: entry);
              },
            ),
    );
  }
}

class _TimelineLogTile extends StatelessWidget {
  final _LogEntry entry;

  const _TimelineLogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _colorFor(entry.status, context);
    final isAnime = AppVisualTheme.of(context).isAnime;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(isAnime ? 18 : 10),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(entry.status), size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (entry.time.isNotEmpty)
                Text(
                  entry.time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          if (entry.details.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final detail in entry.details)
                  _LogChip(
                    label: detail,
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(String status) {
    if (status.contains('失败') || status.contains('超时')) {
      return Icons.error_outline;
    }
    if (status.contains('完成')) return Icons.check_circle_outline;
    if (status.contains('排队')) return Icons.schedule_outlined;
    return Icons.sync;
  }

  static Color _colorFor(String status, BuildContext context) {
    if (status.contains('失败') || status.contains('超时')) {
      return AppStatusPalette.of(context, AppStatusKind.error).foreground;
    }
    if (status.contains('完成')) {
      return AppStatusPalette.of(context, AppStatusKind.success).foreground;
    }
    if (status.contains('排队')) {
      return AppStatusPalette.of(context, AppStatusKind.neutral).foreground;
    }
    return AppStatusPalette.of(context, AppStatusKind.info).foreground;
  }
}

class _RawLogBlock extends StatelessWidget {
  final _LogEntry entry;

  const _RawLogBlock({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAnime = AppVisualTheme.of(context).isAnime;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(isAnime ? 18 : 10),
      ),
      child: SelectableText(
        entry.raw,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.35,
        ),
      ),
    );
  }
}

class _LogChip extends StatelessWidget {
  final String label;
  final Color color;

  const _LogChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final isAnime = AppVisualTheme.of(context).isAnime;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(isAnime ? 12 : 6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _LogEntry {
  final String raw;
  final String time;
  final String status;
  final String title;
  final List<String> details;
  final bool timeline;

  const _LogEntry({
    required this.raw,
    this.time = '',
    this.status = '',
    this.title = '',
    this.details = const [],
    this.timeline = false,
  });

  static final _timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');

  static List<_LogEntry> parse(String text) {
    final lines = text
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];

    final entries = <_LogEntry>[];
    final rawBuffer = <String>[];
    void flushRaw() {
      if (rawBuffer.isEmpty) return;
      entries.add(_LogEntry(raw: rawBuffer.join('\n')));
      rawBuffer.clear();
    }

    for (final line in lines) {
      final parsed = _parseTimeline(line);
      if (parsed == null) {
        rawBuffer.add(line);
        continue;
      }
      flushRaw();
      entries.add(parsed);
    }
    flushRaw();
    return entries;
  }

  static _LogEntry? _parseTimeline(String line) {
    final parts = line
        .split('·')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2 || !_timePattern.hasMatch(parts.first)) {
      return null;
    }
    final time = parts.first;
    final status = _looksLikeStatus(parts[1]) ? parts[1] : '';
    final start = status.isEmpty ? 1 : 2;
    final rest = parts.skip(start).toList();
    final title =
        rest.isEmpty ? (status.isEmpty ? '任务进度' : status) : rest.first;
    return _LogEntry(
      raw: line,
      time: time,
      status: status,
      title: title,
      details: rest.skip(1).toList(),
      timeline: true,
    );
  }

  static bool _looksLikeStatus(String value) {
    const labels = ['排队中', '运行中', '已完成', '失败'];
    return labels.contains(value);
  }
}
