import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:chatgpt_app_core/theme/conversation_decoration_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// builder 的 context 位于局部主题之下，顶部栏、列表与输入框读取同一套颜色。
class ConversationDecorationScope extends StatelessWidget {
  final ChatIllustratedTheme? decoration;
  final WidgetBuilder builder;
  const ConversationDecorationScope(
      {super.key, required this.decoration, required this.builder});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final themed = decoration == null
        ? base
        : ConversationDecorationTheme.apply(base, decoration!);
    return Theme(
        data: themed,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
                systemNavigationBarColor:
                    themed.extension<ConversationDecorationTheme>()?.panel ??
                        themed.colorScheme.surface,
                systemNavigationBarIconBrightness:
                    themed.brightness == Brightness.dark
                        ? Brightness.light
                        : Brightness.dark),
            child: Builder(builder: builder)));
  }
}

/// 背景使用静态封面与柔和渐层；装饰不拦截滚动、选择文字或输入操作。
class ConversationDecorationBackdrop extends StatelessWidget {
  final Widget child;
  const ConversationDecorationBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final skin = ConversationDecorationTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(fit: StackFit.passthrough, children: [
      Positioned.fill(
          child: skin == null
              ? const SizedBox.shrink()
              : IgnorePointer(
                  child: ExcludeSemantics(
                      child: RepaintBoundary(
                  child: ClipRect(
                      child: Stack(fit: StackFit.expand, children: [
                    ColoredBox(
                        key: const ValueKey('conversation_decoration_backdrop'),
                        color: skin.background),
                    DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: RadialGradient(
                                center: const Alignment(.9, -.85),
                                radius: 1.25,
                                colors: [skin.glow, Colors.transparent]))),
                    Positioned(
                        right: -60,
                        top: 28,
                        width: 230,
                        height: 230,
                        child: Opacity(
                            opacity: dark ? .11 : .12,
                            child: Image.asset(skin.decoration.framePosterAsset,
                                package: 'chat_message',
                                cacheWidth: 256,
                                cacheHeight: 256,
                                excludeFromSemantics: true,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink()))),
                  ])),
                )))),
      child,
    ]);
  }
}
