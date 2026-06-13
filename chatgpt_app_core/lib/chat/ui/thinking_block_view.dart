import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:flutter/material.dart';

/// 阶段二：思考 / 推理过程展示。
///
/// - 默认折叠，标题显示「深度思考 · 用时 N.N 秒」；
/// - 流式中实时跳秒（本地 ticker 在两次 chunk 之间也持续走表）；
/// - 点击标题展开看全文；
/// - 正文开始后思考块状态变 success，停止计时。
class ThinkingBlockView extends StatefulWidget {
  final ThinkingBlock block;

  const ThinkingBlockView(this.block, {super.key});

  @override
  State<ThinkingBlockView> createState() => _ThinkingBlockViewState();
}

class _ThinkingBlockViewState extends State<ThinkingBlockView> {
  bool _expanded = false;
  Timer? _ticker;

  /// 走表基线：以「最近一次已知的 thinkingMillsec」为基准，
  /// 叠加本地经过的墙钟时间，得到平滑跳动的展示值。
  int _baseMs = 0;
  int _baseWall = 0;
  int _displayMs = 0;

  bool get _streaming => widget.block.status == MessageBlockStatus.streaming;

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.block);
  }

  @override
  void didUpdateWidget(covariant ThinkingBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每个 thinking chunk 都会用新的 block 实例重建本组件 -> 重新对表。
    _syncFrom(widget.block);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncFrom(ThinkingBlock b) {
    if (b.status == MessageBlockStatus.streaming) {
      _baseMs = b.thinkingMillsec;
      _baseWall = DateTime.now().millisecondsSinceEpoch;
      _displayMs = _baseMs;
      _ensureTicker();
    } else {
      _stopTicker();
      _displayMs = b.thinkingMillsec;
    }
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      setState(() => _displayMs = _baseMs + (now - _baseWall));
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  String get _elapsedLabel {
    final secs = _displayMs / 1000.0;
    return '${secs.toStringAsFixed(1)} 秒';
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final hasContent = block.content.trim().isNotEmpty;
    final title = _streaming ? '正在深度思考 · $_elapsedLabel' : '已深度思考 · 用时 $_elapsedLabel';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F2F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E0EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasContent ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  if (_streaming)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.psychology_outlined,
                        size: 16, color: Color(0xFF6B6786)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6786),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (hasContent)
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: const Color(0xFF6B6786)),
                ],
              ),
            ),
          ),
          if (_expanded && hasContent)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Text(
                block.content,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Color(0xFF8A8699),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
