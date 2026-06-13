import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/ui/thinking_block_view.dart';
import 'package:flutter/material.dart';
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
  final Color textColor;
  final double fontSize;

  const BlockMessageContent({
    super.key,
    required this.messageKey,
    this.textColor = Colors.black,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<ChatBlockStore, List<String>>(
      selector: (_, store) => store.blockIdsFor(messageKey),
      builder: (_, blockIds, __) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in blockIds)
              _BlockView(blockId: id, textColor: textColor, fontSize: fontSize),
          ],
        );
      },
    );
  }
}

class _BlockView extends StatelessWidget {
  final String blockId;
  final Color textColor;
  final double fontSize;

  const _BlockView({
    required this.blockId,
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
          MainTextBlock b =>
            _MainText(b.content, color: textColor, fontSize: fontSize),
          ThinkingBlock b => ThinkingBlockView(b),
          CodeBlock b => _Code(b),
          ImageBlock b => _Image(b),
          ToolBlock b => _Tool(b),
          CitationBlock b => _Citation(b),
          FileBlock b => _File(b),
          ErrorBlock b => _Error(b),
          TranslationBlock b =>
            _MainText(b.content, color: textColor, fontSize: fontSize),
          PlaceholderBlock b => b.status == MessageBlockStatus.success
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
  final Color color;
  final double fontSize;

  const _MainText(this.content, {required this.color, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    return Text(
      content,
      style: TextStyle(fontSize: fontSize, color: color),
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
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFD32F2F)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              block.message.isEmpty ? '请求失败' : block.message,
              style: const TextStyle(fontSize: 14, color: Color(0xFFD32F2F)),
            ),
          ),
        ],
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
    final img = _buildImage();
    if (img == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: img),
    );
  }

  Widget? _buildImage() {
    const w = 200.0;
    final url = block.url;
    final path = block.filePath;
    if (url != null && url.startsWith('data:')) {
      final parts = url.split(',');
      if (parts.length < 2) return null;
      return Image.memory(base64Decode(parts[1]), width: w, fit: BoxFit.cover);
    }
    if (url != null && (url.startsWith('http://') || url.startsWith('https://'))) {
      return Image.network(width: w, fit: BoxFit.cover, url,
          errorBuilder: (_, __, ___) => const SizedBox.shrink());
    }
    if (path != null && File(path).existsSync()) {
      return Image.file(File(path), width: w, fit: BoxFit.cover);
    }
    return null;
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
    final hasDetail = (args != null && args.isNotEmpty) || block.content != null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasDetail
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Row(
              children: [
                if (_running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.build_outlined,
                      size: 16, color: Color(0xFF3B5BDB)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _running
                        ? '正在调用 ${block.toolName ?? block.toolId}…'
                        : (block.toolName ?? block.toolId),
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF3B5BDB)),
                  ),
                ),
                if (hasDetail) ...[
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: const Color(0xFF3B5BDB)),
                ],
              ],
            ),
          ),
          if (_expanded && hasDetail) ...[
            if (args != null && args.isNotEmpty)
              _detail('参数', _pretty(args)),
            if (block.content != null) _detail('结果', _pretty(block.content)),
          ],
        ],
      ),
    );
  }

  Widget _detail(String label, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(maxHeight: 160),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: Text(
                text,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.black87),
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
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.travel_explore, size: 14, color: Colors.black54),
              SizedBox(width: 4),
              Text('来源',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54)),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < block.webResults.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: GestureDetector(
                onTap: () => _open(block.webResults[i].url),
                child: Text(
                  '[${i + 1}] ${block.webResults[i].title.isEmpty ? block.webResults[i].url : block.webResults[i].title}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF3B5BDB),
                    decoration: TextDecoration.underline,
                    decorationColor: Color(0xFF3B5BDB),
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined,
              size: 16, color: Colors.black54),
          const SizedBox(width: 6),
          Flexible(
            child: Text(block.file.name,
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ),
        ],
      ),
    );
  }
}
