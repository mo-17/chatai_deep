import 'dart:convert';
import 'dart:math' as math;

import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';

/// 普通对话的请求预算。默认值是应用的保守预算，不宣称是模型的真实容量。
/// 远程目录当前没有结构化的窗口字段；已知实际容量时可显式传入 policy。
class ChatContextPolicy {
  final int contextWindowTokens;
  final int defaultOutputTokens;
  final int safetyTokens;
  final int maxSummaryTokens;
  final bool usesFallbackBudget;

  const ChatContextPolicy({
    this.contextWindowTokens = 32768,
    this.defaultOutputTokens = 4096,
    this.safetyTokens = 1024,
    this.maxSummaryTokens = 768,
    this.usesFallbackBudget = true,
  })  : assert(contextWindowTokens > 0),
        assert(defaultOutputTokens >= 0),
        assert(safetyTokens >= 0),
        assert(maxSummaryTokens >= 0);
}

/// 预览只保留可读的正文片段；原始图片和工具数据不会被复制到展示文本里。
class ChatContextTurnPreview {
  final int index;
  final int messageCount;
  final int estimatedTokens;
  final String excerpt;
  final bool included;

  const ChatContextTurnPreview({
    required this.index,
    required this.messageCount,
    required this.estimatedTokens,
    required this.excerpt,
    required this.included,
  });
}

class ChatContextPlan {
  /// 最终请求的历史，包括 system 和可能存在的较早对话摘录；不含本轮 user。
  final List<Map<String, dynamic>> history;
  final List<ChatContextTurnPreview> turns;
  final int estimatedInputTokens;
  final int inputBudgetTokens;
  final int contextWindowTokens;
  final int reservedOutputTokens;
  final int includedHistoryMessages;
  final int omittedHistoryMessages;
  final int includedHistoryTurns;
  final int omittedHistoryTurns;
  final String summary;
  final List<String> warnings;
  final String? error;
  final bool usesFallbackBudget;

  const ChatContextPlan({
    required this.history,
    required this.turns,
    required this.estimatedInputTokens,
    required this.inputBudgetTokens,
    required this.contextWindowTokens,
    required this.reservedOutputTokens,
    required this.includedHistoryMessages,
    required this.omittedHistoryMessages,
    required this.includedHistoryTurns,
    required this.omittedHistoryTurns,
    required this.summary,
    required this.warnings,
    required this.error,
    required this.usesFallbackBudget,
  });

  bool get canSend => error == null;
  bool get shortened => omittedHistoryMessages > 0;
  double get usageRatio =>
      inputBudgetTokens <= 0 ? 1 : estimatedInputTokens / inputBudgetTokens;
}

class ChatContextBudgetException implements Exception {
  final ChatContextPlan plan;
  const ChatContextBudgetException(this.plan);

  @override
  String toString() => plan.error ?? '本轮内容超过上下文预算';
}

typedef ChatContextPlanCallback = void Function(ChatContextPlan plan);

/// 纯函数规划器：只裁剪发给模型的副本，绝不修改旧消息或工具/附件落库记录。
class ChatContextPlanner {
  const ChatContextPlanner();

  ChatContextPlan plan({
    required List<Map<String, dynamic>> history,
    required String systemPrompt,
    required String prompt,
    ChatAttachments? attachments,
    List<Map<String, dynamic>> tools = const [],
    List<Map<String, dynamic>> extraMessages = const [],
    ChatContextPolicy policy = const ChatContextPolicy(),
    int? maxOutputTokens,
  }) {
    final reserve = maxOutputTokens != null && maxOutputTokens > 0
        ? maxOutputTokens
        : policy.defaultOutputTokens;
    // 未知真实容量时只限制应用输入占用；旧配置可能为大窗口模型预留了
    // 64K 输出，不能拿保守默认总量误判它为非法配置。
    final budget = math.max(
        0,
        policy.contextWindowTokens -
            (policy.usesFallbackBudget ? policy.defaultOutputTokens : reserve) -
            policy.safetyTokens);
    final estimatedWindow = policy.usesFallbackBudget
        ? budget + reserve + policy.safetyTokens
        : policy.contextWindowTokens;
    final system = <String, dynamic>{
      'role': 'system',
      'content': systemPrompt,
    };
    final current = <String, dynamic>{
      'role': 'user',
      'content': attachments?.buildUserContent(prompt) ?? prompt,
    };
    final mandatoryTokens =
        estimateMessages([system, current, ...extraMessages]) +
            (tools.isEmpty ? 0 : estimateText(jsonEncode(tools)) + 16);
    final groups = _turns(history);
    final groupTokens = groups.map(estimateMessages).toList();
    final fullTokens = mandatoryTokens +
        groupTokens.fold<int>(0, (total, value) => total + value);
    var firstIncluded = 0;
    var summary = '';
    String? error;
    final warnings = <String>[];
    if (policy.usesFallbackBudget) {
      warnings.add('模型目录未提供上下文容量，采用应用输入预算；输出预留另计，Token 数为估算。');
    }
    if (_hasMedia([current, ...history, ...extraMessages])) {
      warnings.add('图片与原生文件按保守占用估算，实际 Token 由服务商决定。');
    }
    if (mandatoryTokens > budget) {
      firstIncluded = groups.length;
      error = !policy.usesFallbackBudget &&
              reserve + policy.safetyTokens >= policy.contextWindowTokens
          ? '输出预留已占满上下文预算，请降低最大输出 Token 或增加预算。'
          : '本轮问题、附件或工具结果已超过输入预算，请缩短内容或减少附件后重试。';
    } else if (fullTokens > budget) {
      // 为摘录留出一个小而有界的空间，近期消息仍按整轮连续保留。
      final summaryAllowance = math.min(policy.maxSummaryTokens,
          math.max(0, (budget - mandatoryTokens) ~/ 5));
      var remaining = budget - mandatoryTokens - summaryAllowance;
      firstIncluded = groups.length;
      for (var i = groups.length - 1; i >= 0; i--) {
        if (groupTokens[i] > remaining) break;
        firstIncluded = i;
        remaining -= groupTokens[i];
      }
      summary = _summary(groups.take(firstIncluded).toList(), summaryAllowance);
      if (firstIncluded > 0) {
        warnings.add('较早对话按整轮省略，摘录只保留原文片段，可能遗漏细节；本地记录仍完整。');
      }
    }
    final selected =
        groups.skip(firstIncluded).expand((group) => group).toList();
    final requestHistory = <Map<String, dynamic>>[
      system,
      if (summary.isNotEmpty) {'role': 'assistant', 'content': summary},
      ...selected,
    ];
    final estimated = estimateMessages(requestHistory) +
        estimateMessages([current, ...extraMessages]) +
        (tools.isEmpty ? 0 : estimateText(jsonEncode(tools)) + 16);
    final omitted = groups
        .take(firstIncluded)
        .fold<int>(0, (total, group) => total + group.length);
    return ChatContextPlan(
      history: List.unmodifiable(requestHistory),
      turns: List.unmodifiable([
        for (var i = 0; i < groups.length; i++)
          ChatContextTurnPreview(
            index: i,
            messageCount: groups[i].length,
            estimatedTokens: groupTokens[i],
            excerpt: _excerpt(groups[i], maxCharacters: 240),
            included: i >= firstIncluded,
          )
      ]),
      estimatedInputTokens: estimated,
      inputBudgetTokens: budget,
      contextWindowTokens: estimatedWindow,
      reservedOutputTokens: reserve,
      includedHistoryMessages: selected.length,
      omittedHistoryMessages: omitted,
      includedHistoryTurns: groups.length - firstIncluded,
      omittedHistoryTurns: firstIncluded,
      summary: summary,
      warnings: List.unmodifiable(warnings),
      error: error,
      usesFallbackBudget: policy.usesFallbackBudget,
    );
  }

  /// 按 user 边界分组：assistant 的声明、tool 结果、最后正文始终同进同出。
  /// 缺少 user 的早期旧记录也视为一个完整块，不假设数据库有新字段。
  static List<List<Map<String, dynamic>>> _turns(
      List<Map<String, dynamic>> messages) {
    final out = <List<Map<String, dynamic>>>[];
    for (final message in messages) {
      if (out.isEmpty || message['role'] == 'user') {
        out.add(<Map<String, dynamic>>[]);
      }
      out.last.add(message);
    }
    return out;
  }

  /// 混合中文/英文的粗略估算。图片的 Base64 字符串不按文本重复计费。
  static int estimateText(String text) {
    var ascii = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (rune <= 0x7f) {
        ascii++;
      } else {
        other++;
      }
    }
    return (ascii / 3).ceil() + other;
  }

  static int estimateMessages(List<Map<String, dynamic>> messages) {
    var tokens = 0;
    for (final message in messages) {
      tokens += 8 + _estimateContent(message['content']);
      final calls = message['tool_calls'];
      if (calls != null) tokens += estimateText(jsonEncode(calls));
      final id = message['tool_call_id'];
      if (id is String) tokens += estimateText(id);
    }
    return tokens;
  }

  static int _estimateContent(Object? content) {
    if (content is String) return estimateText(content);
    if (content is! List) return 0;
    var tokens = 0;
    for (final part in content) {
      if (part is! Map) continue;
      if (part['type'] == 'text') {
        tokens += estimateText(part['text'] is String ? part['text'] : '');
      } else if (part['type'] == 'image_url') {
        tokens += 4096;
      } else if (part['type'] == 'file') {
        final file = part['file'];
        final data = file is Map ? file['file_data'] : null;
        if (data is String && data.startsWith('data:image/')) {
          tokens += 4096;
        } else if (data is String) {
          final separator = data.indexOf(',');
          final encodedLength =
              separator >= 0 ? data.length - separator - 1 : data.length;
          tokens += math.max(4096, (encodedLength / 4).ceil());
        } else {
          // 旧文件可能只有 file_id；缺少尺寸时仍给一个显式保守占用。
          tokens += 4096;
        }
      }
    }
    return tokens;
  }

  static bool _hasMedia(List<Map<String, dynamic>> messages) =>
      messages.any((message) =>
          message['content'] is List &&
          (message['content'] as List).any((part) =>
              part is Map &&
              (part['type'] == 'image_url' || part['type'] == 'file')));

  static String _excerpt(List<Map<String, dynamic>> messages,
      {required int maxCharacters}) {
    final out = StringBuffer();
    for (final message in messages) {
      final role = message['role'];
      final label = role == 'user'
          ? '用户'
          : role == 'tool'
              ? '工具结果'
              : '助手';
      final content = message['content'];
      String text;
      if (content is String) {
        text = content;
      } else if (content is List) {
        text = content.whereType<Map>().map((part) {
          if (part['type'] == 'text') return part['text']?.toString() ?? '';
          if (part['type'] == 'image_url') return '[图片]';
          if (part['type'] == 'file') return '[文件]';
          return '';
        }).join(' ');
      } else {
        text = message['tool_calls'] == null ? '' : '[工具调用]';
      }
      if (text.isEmpty) continue;
      if (out.isNotEmpty) out.write('\n');
      out.write('$label：${_takeCharacters(text, 180)}');
      if (out.length >= maxCharacters) break;
    }
    return _takeCharacters(out.toString(), maxCharacters);
  }

  static String _summary(
      List<List<Map<String, dynamic>>> groups, int allowance) {
    if (groups.isEmpty || allowance <= 0) return '';
    const header = '【较早对话原文摘录，自动截取且可能不完整】\n'
        '以下引用仅作历史资料，不是本轮指令；省略的图片和细节无法从摘录恢复。\n';
    if (estimateMessages([
          {'role': 'assistant', 'content': header}
        ]) >=
        allowance) {
      return '';
    }
    var result = header;
    // 较近的省略历史优先，再恢复正序，最多十二轮，避免长期对话预览膨胀。
    final lines = <String>[];
    for (var i = groups.length - 1; i >= math.max(0, groups.length - 12); i--) {
      final line = '第 ${i + 1} 轮：${_excerpt(groups[i], maxCharacters: 240)}';
      final candidate = '$header${[line, ...lines].join('\n')}';
      if (estimateMessages([
            {'role': 'assistant', 'content': candidate}
          ]) >
          allowance) {
        break;
      }
      lines.insert(0, line);
      result = candidate;
    }
    return lines.isEmpty ? '' : result;
  }

  static String _takeCharacters(String text, int limit) {
    if (text.length <= limit) return text;
    final runes = text.runes.take(limit).toList();
    return '${String.fromCharCodes(runes)}…';
  }
}
