import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

class ConversationRoleDebugTurn {
  final int index;
  final String userMessage;
  final String roleContextSnapshot;
  final List<String> roleStateLines;
  final List<AssistantMemoryEntryPreview> memoryHits;
  final AssistantMemoryContextBudget? memoryBudget;

  const ConversationRoleDebugTurn({
    required this.index,
    required this.userMessage,
    this.roleContextSnapshot = '',
    this.roleStateLines = const [],
    this.memoryHits = const [],
    this.memoryBudget,
  });

  bool get hasDebugData =>
      userMessage.trim().isNotEmpty ||
      roleContextSnapshot.trim().isNotEmpty ||
      roleStateLines.isNotEmpty ||
      memoryHits.isNotEmpty ||
      memoryBudget?.affected == true;
}

class ConversationRoleDebugExport {
  static String build({
    required String userMessage,
    AssistantModel? assistant,
    String roleContextSnapshot = '',
    List<String> roleStateLines = const [],
    List<AssistantMemoryEntryPreview> memoryHits = const [],
    AssistantMemoryContextBudget? memoryBudget,
    List<AssistantMemoryModel> memories = const [],
  }) {
    final lines = <String>['# 角色调试包'];
    _appendAssistant(lines, assistant);

    final message = userMessage.trim();
    if (message.isNotEmpty) {
      lines
        ..add('')
        ..add('## 用户消息')
        ..add(message);
    }

    _appendRoleState(lines, roleStateLines, heading: '## 当前会话状态');

    _appendMemoryHits(lines, memoryHits, heading: '## 本轮命中世界书');
    _appendMemoryBudget(lines, memoryBudget, heading: '## 世界书注入预算');

    _appendMemories(lines, memories);

    final snapshot = roleContextSnapshot.trim();
    if (snapshot.isNotEmpty) {
      lines
        ..add('')
        ..add('## 本轮完整上下文')
        ..add(snapshot);
    }

    return lines.join('\n').trim();
  }

  static String buildSession({
    required String title,
    AssistantModel? assistant,
    List<ConversationRoleDebugTurn> turns = const [],
    List<AssistantMemoryModel> memories = const [],
  }) {
    final usefulTurns = turns.where((turn) => turn.hasDebugData).toList();
    if (usefulTurns.isEmpty && assistant == null && memories.isEmpty) {
      return '';
    }

    final lines = <String>['# 会话角色调试包'];
    final trimmedTitle = title.trim();
    if (trimmedTitle.isNotEmpty) {
      lines
        ..add('')
        ..add('## 会话')
        ..add('- 标题：${_compact(trimmedTitle)}');
    }
    _appendAssistant(lines, assistant);
    _appendMemories(lines, memories);

    for (final turn in usefulTurns) {
      _appendTurn(lines, turn);
    }

    return lines.join('\n').trim();
  }

  static void _appendAssistant(List<String> lines, AssistantModel? assistant) {
    final assistantName = assistant?.name.trim() ?? '';
    if (assistantName.isEmpty) return;
    lines
      ..add('')
      ..add('## 角色')
      ..add('- 名称：$assistantName');
    final description = assistant?.description.trim() ?? '';
    if (description.isNotEmpty) lines.add('- 简介：${_compact(description)}');
    final provider = assistant?.providerId.trim() ?? '';
    final model = assistant?.model.trim() ?? '';
    if (provider.isNotEmpty || model.isNotEmpty) {
      lines.add('- 模型覆盖：${provider.isEmpty ? '未指定' : provider} / '
          '${model.isEmpty ? '未指定' : model}');
    }
    final tools = assistant?.toolIds ?? const <String>[];
    if (tools.isNotEmpty) lines.add('- 工具：${tools.join(', ')}');
  }

  static void _appendMemories(
      List<String> lines, List<AssistantMemoryModel> memories) {
    if (memories.isEmpty) return;
    lines
      ..add('')
      ..add('## 最近长期记忆')
      ..addAll(memories.map((memory) =>
          '- ${_memorySourceLabel(memory.source)}：${_compact(memory.content)}'));
  }

  static void _appendTurn(List<String> lines, ConversationRoleDebugTurn turn) {
    lines
      ..add('')
      ..add('## 轮次 ${turn.index}');
    final message = turn.userMessage.trim();
    if (message.isNotEmpty) {
      lines
        ..add('')
        ..add('### 用户消息')
        ..add(message);
    }
    _appendRoleState(lines, turn.roleStateLines, heading: '### 当前会话状态');
    _appendMemoryHits(lines, turn.memoryHits, heading: '### 本轮命中世界书');
    _appendMemoryBudget(
      lines,
      turn.memoryBudget,
      heading: '### 世界书注入预算',
    );
    final snapshot = turn.roleContextSnapshot.trim();
    if (snapshot.isNotEmpty) {
      lines
        ..add('')
        ..add('### 本轮完整上下文')
        ..add(snapshot);
    }
  }

  static void _appendRoleState(List<String> lines, List<String> roleStateLines,
      {required String heading}) {
    if (roleStateLines.isEmpty) return;
    lines
      ..add('')
      ..add(heading)
      ..addAll(roleStateLines.map((line) => '- ${_compact(line)}'));
  }

  static void _appendMemoryHits(
      List<String> lines, List<AssistantMemoryEntryPreview> memoryHits,
      {required String heading}) {
    if (memoryHits.isEmpty) return;
    lines
      ..add('')
      ..add(heading)
      ..add(AssistantRoleCardService.memoryHitCopyText(memoryHits));
  }

  static void _appendMemoryBudget(
    List<String> lines,
    AssistantMemoryContextBudget? budget, {
    required String heading,
  }) {
    if (budget == null || !budget.affected) return;
    lines
      ..add('')
      ..add(heading)
      ..add('- 命中：${budget.matchedCount} 条')
      ..add('- 实际注入：${budget.includedCount} 条')
      ..add('- 跳过：${budget.skippedCount} 条')
      ..add('- 截断：${budget.truncated ? '是' : '否'}')
      ..add('- 字符预算：${budget.usedChars}/${budget.maxContextChars}');
  }

  static String _compact(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _memorySourceLabel(String source) {
    switch (source) {
      case 'suggestion':
        return '自动建议';
      case 'user_message':
        return '用户消息';
      case 'reply':
      case 'assistant_reply':
        return '助手回复';
      case 'manual':
      default:
        return '手动';
    }
  }
}
