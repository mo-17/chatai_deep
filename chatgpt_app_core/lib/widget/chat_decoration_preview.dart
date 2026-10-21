import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/starcore_message_avatar.dart';
import 'package:chatgpt_app_core/widget/conversation_decoration.dart';
import 'package:chatgpt_app_core/theme/conversation_decoration_theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 消息对象保持稳定，避免每次修改配置都更换整个消息的身份。
class ChatDecorationPreview extends StatefulWidget {
  const ChatDecorationPreview({super.key});

  @override
  State<ChatDecorationPreview> createState() => _ChatDecorationPreviewState();
}

class _ChatDecorationPreviewState extends State<ChatDecorationPreview> {
  final _messages = [
    MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '我',
        content: '让每一次对话，都有我的风格。',
        createdAt: 0),
    MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: 'AI',
        content: '好呀，今天的灵感从这里开始。',
        createdAt: 1),
  ];

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    return ConversationDecorationScope(
      decoration: provider.conversationDecoration,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final skin = ConversationDecorationTheme.of(context);
        return Container(
          key: const ValueKey('chat_appearance_preview'),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: skin != null
                ? null
                : LinearGradient(
                    colors: [
                      scheme.surfaceContainerLow,
                      scheme.primaryContainer.withValues(alpha: .28)
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: ConversationDecorationBackdrop(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  width: double.infinity,
                  color: skin?.panel,
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('对话预览', style: theme.textTheme.titleSmall),
                      Text('选择即保存',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  )),
              Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final message in _messages)
                      DefaultMessageWidget(
                        key: message.key,
                        message: message,
                        avatarBuilder: buildStarcoreMessageAvatar,
                        showAvatars: provider.showMessageAvatars,
                        bubbleStyle: provider.bubbleStyle(
                            isUser: message.ownerType == OwnerType.sender),
                        avatarFrameStyle: provider.avatarFrame(
                            isUser: message.ownerType == OwnerType.sender),
                        senderBackgroundColor:
                            provider.bubbleColor(theme, isUser: true),
                        receiverBackgroundColor:
                            provider.bubbleColor(theme, isUser: false),
                        bubbleRadius:
                            provider.isAnime ? const Radius.circular(18) : null,
                      ),
                  ])),
              if (skin != null)
                Container(
                  key: const ValueKey('conversation_composer_preview'),
                  color: skin.panel,
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Expanded(
                        child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                                color: skin.input,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: skin.border)),
                            child: Text('输入消息…',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant)))),
                    const SizedBox(width: 10),
                    CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.arrow_upward_rounded,
                            color: scheme.onPrimary)),
                  ]),
                ),
            ],
          )),
        );
      },
    );
  }
}
