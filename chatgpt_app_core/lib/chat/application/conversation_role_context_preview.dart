import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

class ConversationRoleContextPreview {
  static String scanText({
    required String userInput,
    Iterable<String> recentMessages = const [],
    int maxMessages = 6,
  }) {
    final recent = recentMessages
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    final start = recent.length > maxMessages ? recent.length - maxMessages : 0;
    final parts = [
      ...recent.skip(start),
      if (userInput.trim().isNotEmpty) userInput.trim(),
    ];
    return parts.join('\n');
  }

  static String build({
    required AssistantModel? assistant,
    required String userInput,
    ConversationModel? conversation,
    List<AssistantMemoryModel> memories = const [],
  }) {
    if (assistant == null) return '';
    final base = assistant.systemPromptFor(userInput).trim();
    final roleState = conversation?.roleStateContext().trim() ?? '';
    final memory = AssistantMemoryDao.buildSystemContext(memories).trim();
    final parts = [
      if (base.isNotEmpty) base,
      if (roleState.isNotEmpty) roleState,
      if (memory.isNotEmpty) memory,
    ];
    return parts.join('\n\n');
  }

  static Future<String> buildSafely({
    required AssistantModel? assistant,
    required String userInput,
    ConversationModel? conversation,
    List<AssistantMemoryModel> memories = const [],
  }) async {
    if (assistant == null) return '';
    final base = (await assistant.systemPromptForSafely(userInput)).trim();
    final roleState = conversation?.roleStateContext().trim() ?? '';
    final memory = AssistantMemoryDao.buildSystemContext(memories).trim();
    return [
      if (base.isNotEmpty) base,
      if (roleState.isNotEmpty) roleState,
      if (memory.isNotEmpty) memory,
    ].join('\n\n');
  }

  static String summary({
    required AssistantModel? assistant,
    String userInput = '',
    ConversationModel? conversation,
    List<AssistantMemoryModel> memories = const [],
  }) {
    if (assistant == null) return '当前会话未绑定角色';
    final List<AssistantMemoryEntryPreview> memoryHits =
        userInput.trim().isEmpty
            ? const []
            : AssistantRoleCardService.matchMemoryEntries(
                assistant.memoryBook,
                userInput,
                structuredJson: assistant.worldBookJson,
                characterName: assistant.name,
                characterDescription: assistant.prompt,
                creatorNotes: assistant.description,
              );
    final budget = AssistantMemoryBook.budgetContext(
      assistant.memoryBook,
      userInput,
      structuredJson: assistant.worldBookJson,
      characterName: assistant.name,
      characterDescription: assistant.prompt,
      creatorNotes: assistant.description,
    );
    return _summary(
        assistant, userInput, conversation, memories, memoryHits, budget);
  }

  static Future<String> summarySafely({
    required AssistantModel? assistant,
    String userInput = '',
    ConversationModel? conversation,
    List<AssistantMemoryModel> memories = const [],
  }) async {
    if (assistant == null) return '当前会话未绑定角色';
    final List<AssistantMemoryEntryPreview> memoryHits =
        userInput.trim().isEmpty
            ? const []
            : await AssistantRoleCardService.matchMemoryEntriesSafely(
                assistant.memoryBook,
                userInput,
                structuredJson: assistant.worldBookJson,
                characterName: assistant.name,
                characterDescription: assistant.prompt,
                creatorNotes: assistant.description,
              );
    final budget = await AssistantMemoryBook.budgetContextSafely(
      assistant.memoryBook,
      userInput,
      structuredJson: assistant.worldBookJson,
      characterName: assistant.name,
      characterDescription: assistant.prompt,
      creatorNotes: assistant.description,
    );
    return _summary(
        assistant, userInput, conversation, memories, memoryHits, budget);
  }

  static String _summary(
    AssistantModel assistant,
    String userInput,
    ConversationModel? conversation,
    List<AssistantMemoryModel> memories,
    List<AssistantMemoryEntryPreview> memoryHits,
    AssistantMemoryContextBudget budget,
  ) {
    final lines = <String>[];
    final prompt = assistant.prompt.trim();
    final hasWorldBook = assistant.memoryBook.trim().isNotEmpty ||
        assistant.worldBookJson.trim().isNotEmpty;
    lines.add(prompt.isEmpty ? '角色卡：未设置系统提示词' : '角色卡：会注入系统提示词');
    if (!hasWorldBook) {
      lines.add('世界书：未配置');
    } else if (userInput.trim().isEmpty) {
      lines.add('世界书：会按输入命中注入');
    } else if (memoryHits.isEmpty) {
      lines.add('世界书：本轮未命中');
    } else {
      lines.add('世界书：本轮命中 ${memoryHits.length} 条');
      lines.addAll(
        memoryHits.take(3).map(AssistantRoleCardService.memoryHitPreviewLine),
      );
      if (budget.affected) {
        lines.add('世界书预算：${budget.compactSummary}');
      }
    }
    lines.add(conversation?.roleStateContext().trim().isEmpty == false
        ? '会话状态：会注入'
        : '会话状态：未设置');
    lines
        .add(memories.isEmpty ? '长期记忆：未加载' : '长期记忆：最近 ${memories.length} 条会注入');
    return lines.join(' · ');
  }
}
