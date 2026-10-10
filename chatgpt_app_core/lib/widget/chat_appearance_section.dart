import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 复用真实消息气泡预览宽度与颜色；设置仍由全局 ThemeProvider 保存。
class ChatAppearanceSection extends StatelessWidget {
  const ChatAppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('对话气泡', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '设置立即生效，下次打开仍会保留。正文可直接框选复制。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('show_message_avatars'),
          contentPadding: EdgeInsets.zero,
          title: const Text('显示消息头像'),
          subtitle: const Text('关闭后释放头像空间，让对话内容更宽'),
          value: provider.showMessageAvatars,
          onChanged: provider.setShowMessageAvatars,
        ),
        for (final isUser in [true, false])
          ListTile(
            key: ValueKey(isUser ? 'user_bubble_color' : 'ai_bubble_color'),
            contentPadding: EdgeInsets.zero,
            title: Text(isUser ? '我的气泡颜色' : 'AI 气泡颜色'),
            subtitle: Text(
              _label(
                isUser ? provider.userBubbleColor : provider.aiBubbleColor,
              ),
            ),
            leading: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: provider.bubbleColor(theme, isUser: isUser),
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.outline),
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showDialog<(Color?,)>(
                context: context,
                builder: (_) => _BubbleColorDialog(
                  title: isUser ? '我的气泡颜色' : 'AI 气泡颜色',
                  initialColor: provider.bubbleColor(theme, isUser: isUser),
                ),
              );
              if (result != null && context.mounted) {
                provider.setBubbleColor(isUser: isUser, color: result.$1);
              }
            },
          ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('chat_appearance_preview'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            children: [
              for (final isUser in [true, false])
                DefaultMessageWidget(
                  key: GlobalKey(),
                  message: MessageModel(
                    ownerType: isUser ? OwnerType.sender : OwnerType.receiver,
                    ownerName: isUser ? '我' : 'AI',
                    content: isUser
                        ? '试试为我的消息选一种喜欢的颜色。'
                        : '这是一条较长的回复预览。隐藏头像后，文字会拥有更多空间；你也可以拖动选择其中的一部分文字。',
                    createdAt: 0,
                  ),
                  showAvatars: provider.showMessageAvatars,
                  senderBackgroundColor: provider.bubbleColor(
                    theme,
                    isUser: true,
                  ),
                  receiverBackgroundColor: provider.bubbleColor(
                    theme,
                    isUser: false,
                  ),
                  bubbleRadius: const Radius.circular(14),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _label(Color? color) => color == null ? '跟随主题' : _hex(color);
}

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class _BubbleColorDialog extends StatefulWidget {
  final String title;
  final Color initialColor;

  const _BubbleColorDialog({required this.title, required this.initialColor});

  @override
  State<_BubbleColorDialog> createState() => _BubbleColorDialogState();
}

class _BubbleColorDialogState extends State<_BubbleColorDialog> {
  late final TextEditingController _hexController;
  late Color _color;
  String? _error;

  static const _colors = [
    Color(0xFFFFFFFF),
    Color(0xFFE9E8FC),
    Color(0xFFFCE7F3),
    Color(0xFFD1FAE5),
    Color(0xFFDBEAFE),
    Color(0xFFFEF3C7),
    Color(0xFF334155),
    Color(0xFF1E1B4B),
  ];

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
    _hexController = TextEditingController(text: _hex(_color));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color? _parse(String value) {
    final hex = value.trim().replaceFirst(RegExp(r'^#'), '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(0xFF000000 | int.parse(hex, radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final foreground =
        _color.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '气泡文字预览 Aa 你好',
                style: TextStyle(color: foreground, fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in _colors)
                  Semantics(
                    selected: color == _color,
                    child: IconButton.filledTonal(
                      tooltip: _hex(color),
                      style: IconButton.styleFrom(
                        backgroundColor: color,
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      icon: Icon(
                        color == _color ? Icons.check : Icons.circle,
                        color: color == _color
                            ? (color.computeLuminance() > 0.179
                                ? Colors.black
                                : Colors.white)
                            : color,
                      ),
                      onPressed: () => setState(() {
                        _color = color;
                        _hexController.text = _hex(color);
                        _error = null;
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('bubble_color_hex'),
              controller: _hexController,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 7,
              decoration: InputDecoration(
                labelText: '自定义颜色',
                helperText: '输入 6 位十六进制颜色，如 #336699',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() {
                final color = _parse(value);
                if (color != null) _color = color;
                _error = null;
              }),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (null,)),
          child: const Text('跟随主题'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final color = _parse(_hexController.text);
            if (color == null) {
              setState(() => _error = '请输入有效的 6 位颜色');
              return;
            }
            Navigator.pop(context, (color,));
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}
