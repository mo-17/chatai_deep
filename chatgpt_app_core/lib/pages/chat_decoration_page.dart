import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/widget/chat_bubble_surface.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/chat_decoration_preview.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ChatDecorationPage extends StatefulWidget {
  const ChatDecorationPage({super.key});

  @override
  State<ChatDecorationPage> createState() => _ChatDecorationPageState();
}

class _ChatDecorationPageState extends State<ChatDecorationPage> {
  bool _isUser = true;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天装扮'),
        actions: [
          IconButton(
            key: const ValueKey('reset_chat_decoration'),
            tooltip: '恢复默认气泡、配色和头像框',
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: () {
              provider.resetChatDecoration();
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已恢复默认气泡、配色和头像框')));
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView(
              key: const ValueKey('chat_decoration_scroll'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text('把喜欢，放进对话里',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('气泡与头像框自由搭配，为两侧消息各选一种心情。',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 20),
                const ChatDecorationPreview(),
                const SizedBox(height: 20),
                SegmentedButton<bool>(
                  key: const ValueKey('decoration_target'),
                  segments: const [
                    ButtonSegment(
                        value: true,
                        icon: Icon(Icons.person_outline_rounded),
                        label: Text('我的消息')),
                    ButtonSegment(
                        value: false,
                        icon: Icon(Icons.auto_awesome_outlined),
                        label: Text('AI 回复')),
                  ],
                  selected: {_isUser},
                  onSelectionChanged: (values) =>
                      setState(() => _isUser = values.single),
                ),
                const SizedBox(height: 26),
                _SectionHeading(
                    title: '气泡样式',
                    detail: provider.bubbleStyle(isUser: _isUser).label),
                const SizedBox(height: 12),
                _OptionGrid(
                  children: [
                    for (final style in [
                      ...ChatBubbleStyle.values
                          .where((s) => s.illustration != null),
                      ...ChatBubbleStyle.values
                          .where((s) => s.ornament != null),
                      ...ChatBubbleStyle.values.where(
                          (s) => s.ornament == null && s.illustration == null),
                    ])
                      _DecorationCard(
                        key: ValueKey('bubble_style_${style.name}'),
                        title: style.label,
                        description: style.description,
                        selected:
                            provider.bubbleStyle(isUser: _isUser) == style,
                        onTap: () => provider.setBubbleStyle(
                            isUser: _isUser, style: style),
                        sample: _BubbleSample(
                          style: style,
                          color: provider.bubbleColor(theme,
                              isUser: _isUser, style: style),
                          isUser: _isUser,
                        ),
                      ),
                  ],
                ),
                if ((_isUser
                        ? provider.userBubbleColor
                        : provider.aiBubbleColor) !=
                    null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('当前使用了自定义气泡颜色。可在「外观与主题」调整，或点右上角恢复默认。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                const SizedBox(height: 28),
                _SectionHeading(
                    title: '头像框',
                    detail: provider.avatarFrame(isUser: _isUser).label),
                if (!provider.showMessageAvatars)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('消息头像已隐藏'),
                    subtitle: const Text('开启头像后，聊天中会显示所选头像框'),
                    trailing: TextButton(
                        onPressed: () => provider.setShowMessageAvatars(true),
                        child: const Text('显示头像')),
                  ),
                const SizedBox(height: 12),
                _OptionGrid(
                  children: [
                    for (final frame in [
                      ...ChatAvatarFrameStyle.values
                          .where((s) => s.illustration != null),
                      ...ChatAvatarFrameStyle.values
                          .where((s) => s.ornament != null),
                      ...ChatAvatarFrameStyle.values.where(
                          (s) => s.ornament == null && s.illustration == null),
                    ])
                      _DecorationCard(
                        key: ValueKey('avatar_frame_${frame.name}'),
                        title: frame.label,
                        description: frame.description,
                        selected:
                            provider.avatarFrame(isUser: _isUser) == frame,
                        onTap: () => provider.setAvatarFrame(
                            isUser: _isUser, style: frame),
                        sample: Center(
                          child: ChatAvatarFrame(
                            style: frame,
                            size: frame.illustration != null
                                ? 76
                                : (frame.ornament == null ? 52 : 64),
                            child: CircleAvatar(
                              radius: 26,
                              backgroundColor: _isUser
                                  ? scheme.secondaryContainer
                                  : scheme.primaryContainer,
                              child: Icon(
                                  _isUser
                                      ? Icons.person_rounded
                                      : Icons.auto_awesome_rounded,
                                  color: _isUser
                                      ? scheme.onSecondaryContainer
                                      : scheme.onPrimaryContainer,
                                  size: 26),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Text('装扮保存在当前设备，适用于普通对话；经典与梦幻二次元风格均可使用。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final String detail;
  const _SectionHeading({required this.title, required this.detail});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700))),
          Text(detail,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ],
      );
}

class _OptionGrid extends StatelessWidget {
  final List<Widget> children;
  const _OptionGrid({required this.children});

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
        final columns = largeText || constraints.maxWidth < 300
            ? 1
            : (constraints.maxWidth >= 600 ? 3 : 2);
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final child in children) SizedBox(width: width, child: child)
        ]);
      });
}

class _DecorationCard extends StatelessWidget {
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final Widget sample;
  const _DecorationCard(
      {super.key,
      required this.title,
      required this.description,
      required this.selected,
      required this.onTap,
      required this.sample});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title，$description',
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: .22)
            : scheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: SizedBox(height: 78, child: sample)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: Text(title,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700))),
                  if (selected)
                    Icon(Icons.check_circle_rounded,
                        size: 19, color: scheme.primary)
                ]),
                const SizedBox(height: 4),
                Text(description,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 样卡中的装饰缩略图独立居中，经典气泡的对齐方式不挤到卡片边缘。
class _BubbleSample extends StatelessWidget {
  final ChatBubbleStyle style;
  final Color color;
  final bool isUser;
  const _BubbleSample(
      {required this.style, required this.color, required this.isUser});

  @override
  Widget build(BuildContext context) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ChatBubbleSurface(
            style: style,
            color: color,
            isUser: isUser,
            radius: const Radius.circular(12),
            child: Text('灵感 +1',
                style: TextStyle(
                    fontSize: 14,
                    color: color.computeLuminance() > .179
                        ? Colors.black
                        : Colors.white)),
          ),
        ),
      );
}
