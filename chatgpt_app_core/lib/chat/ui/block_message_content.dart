import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/thinking_block_view.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/starcore_tool_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 一条 assistant 消息的「块化正文」。遍历它的 blockIds 逐块渲染。
///
/// 用 [Selector] 精确订阅：
/// - 外层只订阅该消息的 blockId 列表（仅在「加块」时变化）；
/// - 每个 [_BlockView] 只订阅自己那个块（仅在该块增量更新时重建）。
///
/// 因此流式中一个 token 到达时，只有「当前正在更新的块」重渲染，
/// 其它块（如已完成的思考块）不动 —— 满足阶段一验收。
class BlockMessageContent extends StatelessWidget {
  final String messageKey;
  final Color? textColor;
  final double fontSize;

  /// 是否在正文下方显示「字数」（仅 assistant 回复用）。流式中随正文增长实时更新。
  final bool showCharCount;

  /// 与字数并排展示的消息底部操作，例如朗读按钮。
  final Widget? footerTrailing;

  const BlockMessageContent({
    super.key,
    required this.messageKey,
    this.textColor,
    this.fontSize = 16,
    this.showCharCount = false,
    this.footerTrailing,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedTextColor =
        textColor ?? Theme.of(context).colorScheme.onSurface;
    return Selector<ChatBlockStore, List<String>>(
      selector: (_, store) => store.blockIdsFor(messageKey),
      builder: (_, blockIds, __) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in blockIds)
              _BlockView(
                blockId: id,
                messageKey: messageKey,
                textColor: resolvedTextColor,
                fontSize: fontSize,
              ),
            if (showCharCount || footerTrailing != null)
              _BlockMessageFooter(
                messageKey: messageKey,
                showCharCount: showCharCount,
                trailing: footerTrailing,
              ),
          ],
        );
      },
    );
  }
}

class MessageFooterBar extends StatelessWidget {
  final int? charCount;
  final Widget? trailing;

  const MessageFooterBar({
    super.key,
    this.charCount,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final count = charCount ?? 0;
    if (count <= 0 && trailing == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (count > 0)
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: colorScheme.onSurface.withValues(alpha: 0.055),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notes_outlined, size: 13, color: muted),
                  const SizedBox(width: 4),
                  Text(
                    '$count 字',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      color: muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 字数页脚：精确订阅「该消息所有正文块的总字符数」，仅在数字变化时重建。
class _BlockMessageFooter extends StatelessWidget {
  final String messageKey;
  final bool showCharCount;
  final Widget? trailing;

  const _BlockMessageFooter({
    required this.messageKey,
    required this.showCharCount,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<ChatBlockStore, int>(
      selector: (_, store) => showCharCount ? _countTextBlocks(store) : 0,
      builder: (_, count, __) =>
          MessageFooterBar(charCount: count, trailing: trailing),
    );
  }

  int _countTextBlocks(ChatBlockStore store) {
    var n = 0;
    for (final b in store.blocksFor(messageKey)) {
      if (b is MainTextBlock) n += b.content.characters.length;
      if (b is TranslationBlock) n += b.content.characters.length;
    }
    return n;
  }
}

class _BlockView extends StatelessWidget {
  final String blockId;
  final String messageKey;
  final Color textColor;
  final double fontSize;

  const _BlockView({
    required this.blockId,
    required this.messageKey,
    required this.textColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<ChatBlockStore, MessageBlock?>(
      selector: (_, store) => store.block(blockId),
      builder: (_, block, __) {
        // Dart 3 sealed class -> switch 穷尽匹配每种块。
        return switch (block) {
          final MainTextBlock b => _MainText(
              b.content,
              messageKey: messageKey,
              color: textColor,
              fontSize: fontSize,
            ),
          final ThinkingBlock b => ThinkingBlockView(b),
          final CodeBlock b => _Code(b),
          final ImageBlock b => _Image(b),
          final ToolBlock b => _Tool(b),
          final CitationBlock b => _Citation(b),
          final FileBlock b => _File(b),
          final RoleContextBlock b => _RoleContext(b),
          final RoleContinuationBlock b => _RoleContinuation(b),
          final ErrorBlock b => _Error(b),
          final TranslationBlock b => _MainText(
              b.content,
              messageKey: messageKey,
              color: textColor,
              fontSize: fontSize,
            ),
          final PlaceholderBlock b => b.status == MessageBlockStatus.success
              ? const SizedBox.shrink()
              : const _Placeholder(),
          null => const SizedBox.shrink(),
        };
      },
    );
  }
}

/// 主文本块（也复用于翻译块）。保持与原气泡一致用纯 [Text]，
/// 以便气泡级长按菜单（复制/收藏/删除）正常触发。
class _MainText extends StatelessWidget {
  final String content;
  final String messageKey;
  final Color color;
  final double fontSize;

  const _MainText(
    this.content, {
    required this.messageKey,
    required this.color,
    required this.fontSize,
  });

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 无法打开时不打断聊天流程。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final linkColor = visual.isAnime ? scheme.primary : const Color(0xFF3B5BDB);
    final linkStyle = TextStyle(
      color: linkColor,
      fontSize: fontSize,
      decoration: TextDecoration.underline,
      decorationColor: linkColor,
    );
    final normalStyle = TextStyle(fontSize: fontSize, color: color);
    return Selector<ChatBlockStore, List<WebSearchResult>>(
      selector: (_, store) {
        final results = <WebSearchResult>[];
        for (final b
            in store.blocksFor(messageKey).whereType<CitationBlock>()) {
          results.addAll(b.webResults);
        }
        return results;
      },
      builder: (_, results, __) {
        if (results.isEmpty) {
          return Text(content, style: normalStyle);
        }
        final segments = parseCitationTextSegments(
          content: content,
          webResults: results,
        );
        final spans = <InlineSpan>[];
        for (final segment in segments) {
          if (segment.citationIndex == null || segment.url == null) {
            spans.add(TextSpan(text: segment.text, style: normalStyle));
            continue;
          }
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Semantics(
                link: true,
                linkUrl: Uri.tryParse(segment.url!),
                label: '打开来源 ${segment.text}',
                onTap: () => _open(segment.url!),
                excludeSemantics: true,
                child: SizedBox.square(
                  dimension: 44,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _open(segment.url!),
                    child: Center(child: Text(segment.text, style: linkStyle)),
                  ),
                ),
              ),
            ),
          );
        }
        return Text.rich(TextSpan(children: spans));
      },
    );
  }
}

/// `[n]` 标记的片段化结果，用于正文和来源联动点击。
class CitationTextSegment {
  final String text;
  final int? citationIndex;
  final String? url;

  const CitationTextSegment({
    required this.text,
    this.citationIndex,
    this.url,
  });
}

/// 把正文内容按 `[数字]` 分段，并按给定的来源列表补齐可跳转 URL。
///
/// - `[1]` 命中到第 1 条 source 时可点击；
/// - 无法定位到 URL 时，退化为普通文本。
@visibleForTesting
List<CitationTextSegment> parseCitationTextSegments({
  required String content,
  required List<WebSearchResult> webResults,
}) {
  final regex = RegExp(r'\[(\d+)\]');
  final segments = <CitationTextSegment>[];
  var cursor = 0;
  for (final match in regex.allMatches(content)) {
    if (match.start > cursor) {
      segments.add(
          CitationTextSegment(text: content.substring(cursor, match.start)));
    }
    final raw = match.group(0)!;
    final index = int.tryParse(match.group(1)!);
    String? url;
    if (index != null &&
        index > 0 &&
        index <= webResults.length &&
        webResults[index - 1].url.isNotEmpty) {
      url = webResults[index - 1].url;
    }
    segments.add(
      CitationTextSegment(
        text: raw,
        citationIndex: index,
        url: url,
      ),
    );
    cursor = match.end;
  }
  if (cursor < content.length) {
    segments.add(CitationTextSegment(text: content.substring(cursor)));
  }
  if (segments.isEmpty) {
    return [CitationTextSegment(text: content)];
  }
  return segments;
}

class _RoleContext extends StatefulWidget {
  final RoleContextBlock block;

  const _RoleContext(this.block);

  @override
  State<_RoleContext> createState() => _RoleContextState();
}

class _RoleContextState extends State<_RoleContext> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final content = widget.block.content.trim();
    if (content.isEmpty) return const SizedBox.shrink();
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        visual.isAnime ? scheme.primary : Colors.deepPurple[700]!;
    final background = visual.isAnime
        ? scheme.primaryContainer.withValues(alpha: 0.72)
        : Colors.deepPurple.withValues(alpha: 0.08);
    final borderColor = visual.isAnime
        ? scheme.primary.withValues(alpha: 0.22)
        : Colors.deepPurple.withValues(alpha: 0.16);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 6),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              borderRadius: BorderRadius.circular(visual.isAnime ? 12 : 6),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: visual.isAnime ? 44 : 28,
                ),
                child: Row(
                  children: [
                    Icon(Icons.fact_check_outlined,
                        size: 16, color: foreground),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '本轮完整上下文',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: foreground,
                    ),
                    IconButton(
                      tooltip: '复制本轮上下文',
                      visualDensity: visual.isAnime
                          ? VisualDensity.standard
                          : VisualDensity.compact,
                      constraints: BoxConstraints.tightFor(
                        width: visual.isAnime ? 44 : 28,
                        height: visual.isAnime ? 44 : 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.copy_outlined, size: 15),
                      color: foreground,
                      onPressed: () => _copy(context, content),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: visual.isAnime
                    ? scheme.surface.withValues(alpha: 0.90)
                    : Colors.white.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(visual.isAnime ? 12 : 4),
                border: visual.isAnime
                    ? Border.all(color: scheme.outlineVariant)
                    : null,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  content,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: visual.isAnime ? scheme.onSurface : Colors.black87,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String content) async {
    final text = content.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本轮上下文已复制')),
    );
  }
}

class _RoleContinuation extends StatefulWidget {
  final RoleContinuationBlock block;

  const _RoleContinuation(this.block);

  @override
  State<_RoleContinuation> createState() => _RoleContinuationState();
}

class _RoleContinuationState extends State<_RoleContinuation> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final content = widget.block.content.trim();
    if (content.isEmpty) return const SizedBox.shrink();
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = visual.isAnime ? scheme.secondary : Colors.indigo[700]!;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: visual.isAnime
            ? scheme.secondaryContainer.withValues(alpha: 0.72)
            : Colors.indigo.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 6),
        border: Border.all(
          color: visual.isAnime
              ? scheme.secondary.withValues(alpha: 0.20)
              : Colors.indigo.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              borderRadius: BorderRadius.circular(visual.isAnime ? 12 : 6),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: visual.isAnime ? 44 : 28,
                ),
                child: Row(
                  children: [
                    Icon(Icons.psychology_alt_outlined, size: 16, color: color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '已保留角色状态 · 下轮将承接',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: color,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            Text(
              content,
              style: TextStyle(fontSize: 12, height: 1.45, color: color),
            ),
          ],
        ],
      ),
    );
  }
}

/// 占位块：流式开始、首个内容到达前的加载指示。
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

/// 错误块。
class _Error extends StatelessWidget {
  final ErrorBlock block;
  const _Error(this.block);

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        visual.isAnime ? scheme.onErrorContainer : const Color(0xFFD32F2F);
    final background =
        visual.isAnime ? scheme.errorContainer : const Color(0xFFFDECEC);
    final message = block.message.isEmpty ? '请求失败' : block.message;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: EdgeInsets.all(visual.isAnime ? 12 : 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(visual.isAnime ? 14 : 6),
        border: visual.isAnime
            ? Border.all(color: scheme.error.withValues(alpha: 0.24))
            : null,
      ),
      child: Semantics(
        liveRegion: true,
        label: '错误：$message',
        excludeSemantics: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: TextStyle(fontSize: 14, color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 代码块（阶段一占位渲染：等宽 + 浅底）。
class _Code extends StatelessWidget {
  final CodeBlock block;
  const _Code(this.block);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          block.content,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: Color(0xFFE6E6E6),
          ),
        ),
      ),
    );
  }
}

/// 图片块（用户上传 / 模型生成）。
class _Image extends StatelessWidget {
  final ImageBlock block;
  const _Image(this.block);

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = visual.isAnime ? constraints.constrainWidth(280) : 200.0;
        final img = _buildImage(context, width);
        if (img == null) return const SizedBox.shrink();
        final label = block.prompt?.trim().isNotEmpty == true
            ? '生成图片：${block.prompt!.trim()}'
            : '会话图片';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            image: true,
            label: label,
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                      visual.isAnime ? visual.cardRadius : 6),
                  child: img,
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: _ImageSaveButton(
                      source: block.url ?? block.filePath ?? ''),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget? _buildImage(BuildContext context, double width) {
    final url = block.url;
    final path = block.filePath;
    if (url != null && url.startsWith('data:')) {
      final parts = url.split(',');
      if (parts.length < 2) return _imageError(context, width);
      try {
        return Image.memory(
          base64Decode(parts[1]),
          width: width,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _imageError(context, width),
        );
      } on FormatException {
        return _imageError(context, width);
      }
    }
    if (url != null &&
        (url.startsWith('http://') || url.startsWith('https://'))) {
      return Image.network(
        url,
        width: width,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : _imageLoading(context, width, progress),
        errorBuilder: (_, __, ___) => _imageError(context, width),
      );
    }
    if (path != null && File(path).existsSync()) {
      return Image.file(
        File(path),
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _imageError(context, width),
      );
    }
    if ((url?.isNotEmpty ?? false) || (path?.isNotEmpty ?? false)) {
      return _imageError(context, width);
    }
    return null;
  }

  Widget _imageLoading(
    BuildContext context,
    double width,
    ImageChunkEvent progress,
  ) {
    final expected = progress.expectedTotalBytes;
    return Container(
      width: width,
      height: 120,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: CircularProgressIndicator(
        value: expected == null || expected <= 0
            ? null
            : progress.cumulativeBytesLoaded / expected,
      ),
    );
  }

  Widget _imageError(BuildContext context, double width) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: 120,
      alignment: Alignment.center,
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined,
              color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(
            '图片无法加载',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ImageSaveButton extends StatefulWidget {
  final String source;

  const _ImageSaveButton({required this.source});

  @override
  State<_ImageSaveButton> createState() => _ImageSaveButtonState();
}

class _ImageSaveButtonState extends State<_ImageSaveButton> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final plan = ImageGenerationPolicy.planSave(source: widget.source);
    if (plan == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final background = colorScheme.inverseSurface.withValues(alpha: 0.82);
    final foreground = colorScheme.onInverseSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(22),
      ),
      child: IconButton(
        tooltip: '保存图片',
        iconSize: 18,
        color: foreground,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: _saving ? null : () => _save(context, plan),
        icon: _saving
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              )
            : const Icon(Icons.download),
      ),
    );
  }

  Future<void> _save(BuildContext context, GeneratedImageSavePlan plan) async {
    setState(() => _saving = true);
    try {
      final path = await GeneratedImageSaveService.saveToAppAlbum(plan);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('图片已保存：$path')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存图片失败：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 工具调用块（阶段六）：头部「工具名 + 状态」，点击展开参数与结果。
class _Tool extends StatefulWidget {
  final ToolBlock block;
  const _Tool(this.block);

  @override
  State<_Tool> createState() => _ToolState();
}

class _ToolState extends State<_Tool> {
  bool _expanded = false;

  ToolBlock get block => widget.block;

  bool get _running =>
      block.status == MessageBlockStatus.processing ||
      block.status == MessageBlockStatus.streaming;

  /// 参数 / 结果的展示文本：能 pretty 成 JSON 就 pretty，否则原样。
  static String _pretty(Object? v) {
    if (v == null) return '';
    if (v is Map || v is List) {
      return const JsonEncoder.withIndent('  ').convert(v);
    }
    final s = v.toString();
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = block.arguments;
    final hasDetail =
        (args != null && args.isNotEmpty) || block.content != null;
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final accent =
        visual.isAnime ? colorScheme.primary : const Color(0xFF3B5BDB);
    final surface = visual.isAnime
        ? colorScheme.primaryContainer.withValues(alpha: 0.62)
        : const Color(0xFFF0F4FF);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: surface,
        borderRadius:
            BorderRadius.circular(visual.isAnime ? visual.cardRadius : 6),
        border: visual.isAnime
            ? Border.all(color: colorScheme.outlineVariant)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: hasDetail,
            enabled: hasDetail,
            expanded: hasDetail ? _expanded : null,
            label: block.toolName ?? block.toolId,
            onTap:
                hasDetail ? () => setState(() => _expanded = !_expanded) : null,
            excludeSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(
                    visual.isAnime ? visual.cardRadius : 6),
                onTap: hasDetail
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      if (_running)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        )
                      else if (block.status == MessageBlockStatus.success)
                        StarcoreToolIcon(
                          toolName: block.toolName ?? '',
                          fallback: Icon(
                            Icons.build_outlined,
                            size: 18,
                            color: accent,
                          ),
                          size: 18,
                        )
                      else
                        Icon(Icons.build_outlined, size: 18, color: accent),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _running
                              ? '正在调用 ${block.toolName ?? block.toolId}…'
                              : (block.toolName ?? block.toolId),
                          style: TextStyle(fontSize: 13, color: accent),
                        ),
                      ),
                      if (hasDetail) ...[
                        const SizedBox(width: 4),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: accent,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_expanded && hasDetail) ...[
            if (args != null && args.isNotEmpty) _detail('参数', _pretty(args)),
            if (block.content != null) _detail('结果', _pretty(block.content)),
          ],
        ],
      ),
    );
  }

  Widget _detail(String label, String text) {
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(visual.isAnime ? 12 : 4),
              border: visual.isAnime
                  ? Border.all(color: colorScheme.outlineVariant)
                  : null,
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colorScheme.onSurface),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 引用来源块（阶段五：联网搜索）。编号与回填上下文里的 [n] 对应，
/// 点击用系统浏览器打开来源链接。
class _Citation extends StatelessWidget {
  final CitationBlock block;
  const _Citation(this.block);

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开就算了（无浏览器/无效链接），不打断会话。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (block.webResults.isEmpty) return const SizedBox.shrink();
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = visual.isAnime ? scheme.onSurfaceVariant : Colors.black54;
    final linkColor = visual.isAnime ? scheme.primary : const Color(0xFF3B5BDB);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: visual.isAnime
            ? scheme.surfaceContainerLow.withValues(alpha: 0.88)
            : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 6),
        border:
            visual.isAnime ? Border.all(color: scheme.outlineVariant) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.travel_explore, size: 16, color: muted),
              const SizedBox(width: 4),
              Text('来源',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold, color: muted)),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < block.webResults.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: visual.isAnime
                  ? Semantics(
                      link: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _open(block.webResults[i].url),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '[${i + 1}] ${block.webResults[i].title.isEmpty ? block.webResults[i].url : block.webResults[i].title}',
                              style: TextStyle(
                                fontSize: 12,
                                color: linkColor,
                                decoration: TextDecoration.underline,
                                decorationColor: linkColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : GestureDetector(
                      onTap: () => _open(block.webResults[i].url),
                      child: Text(
                        '[${i + 1}] ${block.webResults[i].title.isEmpty ? block.webResults[i].url : block.webResults[i].title}',
                        style: TextStyle(
                          fontSize: 12,
                          color: linkColor,
                          decoration: TextDecoration.underline,
                          decorationColor: linkColor,
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

/// 文件块（阶段四接入）。
class _File extends StatelessWidget {
  final FileBlock block;
  const _File(this.block);

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final iconColor = visual.isAnime ? scheme.onSurfaceVariant : Colors.black54;
    final textColor = visual.isAnime ? scheme.onSurface : Colors.black87;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: EdgeInsets.all(visual.isAnime ? 10 : 8),
      decoration: BoxDecoration(
        color: visual.isAnime
            ? scheme.surfaceContainerLow.withValues(alpha: 0.88)
            : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(visual.isAnime ? 16 : 6),
        border:
            visual.isAnime ? Border.all(color: scheme.outlineVariant) : null,
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 16, color: iconColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(block.file.name,
                style: TextStyle(fontSize: 13, color: textColor)),
          ),
        ],
      ),
    );
  }
}
