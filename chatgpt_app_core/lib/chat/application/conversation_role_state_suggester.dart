import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

class ConversationRoleStateDraft {
  final String scene;
  final String relationship;
  final String toneNote;

  const ConversationRoleStateDraft({
    this.scene = '',
    this.relationship = '',
    this.toneNote = '',
  });

  bool get isEmpty =>
      scene.trim().isEmpty &&
      relationship.trim().isEmpty &&
      toneNote.trim().isEmpty;
}

class ConversationRoleStateSuggester {
  static ConversationRoleStateDraft fromMessage({
    required ConversationModel conversation,
    required MessageModel message,
    AssistantModel? assistant,
  }) {
    final compact = _compact(message.content);
    final assistantName = assistant?.name.trim() ?? '';
    final relationshipFallback =
        assistantName.isEmpty ? '用户与当前角色正在持续对话' : '用户与$assistantName正在持续对话';
    return ConversationRoleStateDraft(
      scene: _prefer(
        conversation.roleScene,
        message.ownerType == OwnerType.sender && compact.isNotEmpty
            ? '延续最近话题：$compact'
            : '',
      ),
      relationship:
          _prefer(conversation.roleRelationship, relationshipFallback),
      toneNote: _prefer(
        conversation.roleToneNote,
        message.ownerType == OwnerType.receiver && compact.isNotEmpty
            ? '延续最近回复语气：$compact'
            : '延续当前对话语气',
      ),
    );
  }

  static ConversationRoleStateDraft? suggest({
    required ConversationModel conversation,
    required List<MessageModel> messages,
    AssistantModel? assistant,
    int recentLimit = 8,
  }) {
    final existing = conversation.roleStateContext().trim();
    final recent = messages
        .where((m) => m.createdAt > 0 && m.content.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (recent.isEmpty) {
      return existing.isEmpty ? null : _fromConversation(conversation);
    }
    final tail = recent.length > recentLimit
        ? recent.sublist(recent.length - recentLimit)
        : recent;
    final latestUser = tail.lastWhere(
      (m) => m.ownerType == OwnerType.sender,
      orElse: () => tail.last,
    );
    final latestAssistant = tail.lastWhere(
      (m) => m.ownerType == OwnerType.receiver,
      orElse: () => tail.last,
    );
    final assistantName = assistant?.name.trim();
    final sceneSeed = _compact(latestUser.content);
    final replySeed = latestAssistant.ownerType == OwnerType.receiver
        ? _compact(latestAssistant.content)
        : '';

    return ConversationRoleStateDraft(
      scene: _prefer(
        conversation.roleScene,
        sceneSeed.isEmpty ? '' : '延续最近话题：$sceneSeed',
      ),
      relationship: _prefer(
        conversation.roleRelationship,
        assistantName == null || assistantName.isEmpty
            ? '用户与当前角色正在持续对话'
            : '用户与$assistantName正在持续对话',
      ),
      toneNote: _prefer(
        conversation.roleToneNote,
        replySeed.isEmpty ? '延续当前对话语气' : '延续最近回复语气：$replySeed',
      ),
    );
  }

  static ConversationRoleStateDraft _fromConversation(
    ConversationModel conversation,
  ) =>
      ConversationRoleStateDraft(
        scene: conversation.roleScene ?? '',
        relationship: conversation.roleRelationship ?? '',
        toneNote: conversation.roleToneNote ?? '',
      );

  static String _prefer(String? current, String fallback) {
    final text = current?.trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static String _compact(String text, {int maxLength = 36}) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }
}
