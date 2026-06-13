import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/stream_event.dart';

/// 工具调用分片累积器（阶段六）。
///
/// OpenAI 兼容协议的 SSE 把一次工具调用拆成多个 `delta.tool_calls` 分片：
/// 首片带 index/id/name，其后 `function.arguments` 的 JSON 字符串逐片到达。
/// 两个 ChatService 实现（直连 / 后端代理）都用本类按 index 累积分片，
/// 流结束后 [flush] 出「完整」的 [StreamEvent.toolCall]。
class ToolCallAccumulator {
  final _partials = <int, _PartialToolCall>{};

  bool get isEmpty => _partials.isEmpty;

  /// 喂一个分片。首片带 id/name，后续片只带 argsDelta。
  void feed({required int index, String? id, String? name, String? argsDelta}) {
    final p = _partials.putIfAbsent(index, _PartialToolCall.new);
    if (id != null && id.isNotEmpty) p.id = id;
    if (name != null && name.isNotEmpty) p.name = name;
    if (argsDelta != null) p.args.write(argsDelta);
  }

  /// 把累积完的调用转成完整事件（按 index 排序），并清空状态。
  /// arguments 解析失败时降级为空 map（执行层会把错误回灌给模型）。
  List<StreamEvent> flush() {
    final indices = _partials.keys.toList()..sort();
    final events = <StreamEvent>[
      for (final i in indices)
        StreamEvent.toolCall(
          toolId: _partials[i]!.id ?? 'tool_$i',
          name: _partials[i]!.name,
          arguments: _parseArgs(_partials[i]!.args.toString()),
        ),
    ];
    _partials.clear();
    return events;
  }

  static Map<String, dynamic> _parseArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}

class _PartialToolCall {
  String? id;
  String? name;
  final args = StringBuffer();
}
