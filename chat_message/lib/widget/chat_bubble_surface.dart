import 'package:bubble/bubble.dart';
import 'package:chat_message/theme/chat_decoration.dart';
import 'package:chat_message/theme/chat_tail_shape.dart';
import 'package:flutter/material.dart';

/// 预览、普通消息与流式块消息共用外壳，正文和消息操作由调用方保留。
class ChatBubbleSurface extends StatelessWidget {
  final ChatBubbleStyle style;
  final Color color;
  final bool isUser;
  final bool showTail;
  final Radius? radius;
  final EdgeInsets margin;
  final Widget child;

  const ChatBubbleSurface(
      {super.key,
      required this.style,
      required this.color,
      required this.isUser,
      this.showTail = true,
      this.radius,
      this.margin = EdgeInsets.zero,
      required this.child});

  @override
  Widget build(BuildContext context) {
    final alignment = isUser ? Alignment.topRight : Alignment.topLeft;
    if (style == ChatBubbleStyle.classic) {
      return Bubble(
        margin: BubbleEdges.fromLTRB(
            margin.left, margin.top, margin.right, margin.bottom),
        stick: true,
        nip: showTail
            ? (isUser ? BubbleNip.rightTop : BubbleNip.leftTop)
            : BubbleNip.no,
        radius: radius,
        color: color,
        alignment: alignment,
        child: child,
      );
    }
    if (style == ChatBubbleStyle.messenger ||
        style == ChatBubbleStyle.telegram) {
      return Padding(
        padding: margin,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: color,
            shape: ChatTailShape(
                isUser: isUser,
                pointed: style == ChatBubbleStyle.telegram,
                showTail: showTail),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(!isUser && showTail ? 22 : 14, 11,
                isUser && showTail ? 22 : 14, 11),
            child: child,
          ),
        ),
      );
    }
    final dark = color.computeLuminance() <= .179;
    final accent = Color.lerp(
        style.accent, dark ? Colors.white : Colors.black, dark ? .35 : .12)!;
    final corners = switch (style) {
      ChatBubbleStyle.cloud => BorderRadius.circular(24),
      ChatBubbleStyle.paper => BorderRadius.circular(6),
      ChatBubbleStyle.pixel => BorderRadius.circular(3),
      _ => BorderRadius.only(
          topLeft: Radius.circular(isUser ? 18 : 5),
          topRight: Radius.circular(isUser ? 5 : 18),
          bottomLeft: const Radius.circular(18),
          bottomRight: const Radius.circular(18),
        ),
    };
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: style == ChatBubbleStyle.pixel
            ? ShapeDecoration(
                color: color,
                shape: BeveledRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: accent.withValues(alpha: .6), width: 1.5),
                ),
                shadows: [
                  BoxShadow(
                      color: accent.withValues(alpha: .24),
                      offset: const Offset(3, 3))
                ],
              )
            : BoxDecoration(
                color: style == ChatBubbleStyle.aurora ? null : color,
                gradient: style == ChatBubbleStyle.aurora
                    ? LinearGradient(
                        colors: style.backgroundColors(color),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight)
                    : null,
                borderRadius: corners,
                border: Border.all(
                  color: accent.withValues(
                      alpha: switch (style) {
                    ChatBubbleStyle.outline => .65,
                    ChatBubbleStyle.pixel => .6,
                    _ => .18
                  }),
                  width: style == ChatBubbleStyle.pixel ? 2 : 1,
                ),
                boxShadow: switch (style) {
                  ChatBubbleStyle.cloud => [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: .06),
                          blurRadius: 12,
                          offset: const Offset(0, 4))
                    ],
                  ChatBubbleStyle.paper => [
                      BoxShadow(
                          color: accent.withValues(alpha: .15),
                          offset: const Offset(3, 3))
                    ],
                  ChatBubbleStyle.pixel => [
                      BoxShadow(
                          color: accent.withValues(alpha: .24),
                          offset: const Offset(3, 3))
                    ],
                  _ => null,
                },
              ),
        child: child,
      ),
    );
  }
}
