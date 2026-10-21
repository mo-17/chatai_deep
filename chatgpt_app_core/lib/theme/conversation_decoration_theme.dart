import 'package:chat_message/theme/chat_illustrated_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 只作用于对话页的材质，不改动全局风格、字体与消息装扮。
@immutable
class ConversationDecorationTheme
    extends ThemeExtension<ConversationDecorationTheme> {
  final ChatIllustratedTheme decoration;
  final Color background;
  final Color glow;
  final Color panel;
  final Color input;
  final Color border;

  const ConversationDecorationTheme(
      {required this.decoration,
      required this.background,
      required this.glow,
      required this.panel,
      required this.input,
      required this.border});

  static ConversationDecorationTheme? of(BuildContext context) =>
      Theme.of(context).extension<ConversationDecorationTheme>();

  static ThemeData apply(ThemeData base, ChatIllustratedTheme decoration) {
    final dark = base.brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
        seedColor: decoration.accent, brightness: base.brightness);
    final background = Color.lerp(
        dark ? const Color(0xFF10151F) : const Color(0xFFFAFBFD),
        decoration.accent,
        dark ? .13 : .055)!;
    final panel = Color.lerp(dark ? const Color(0xFF19202C) : Colors.white,
        decoration.accent, dark ? .15 : .085)!;
    final input = Color.lerp(dark ? const Color(0xFF232B38) : Colors.white,
        decoration.accent, dark ? .12 : .035)!;
    final skin = ConversationDecorationTheme(
        decoration: decoration,
        background: background,
        glow: decoration.accent.withValues(alpha: dark ? .15 : .12),
        panel: panel,
        input: input,
        border: scheme.outlineVariant);
    final radius = BorderRadius.circular(16);
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: panel,
          foregroundColor: scheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: scheme.onSurface),
          actionsIconTheme: IconThemeData(color: scheme.onSurface),
          systemOverlayStyle:
              dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
          filled: true,
          fillColor: input,
          hintStyle: base.textTheme.bodyLarge
              ?.copyWith(color: scheme.onSurfaceVariant),
          enabledBorder: OutlineInputBorder(
              borderRadius: radius, borderSide: BorderSide(color: skin.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: scheme.primary, width: 1.5)),
          disabledBorder: OutlineInputBorder(
              borderRadius: radius, borderSide: BorderSide(color: skin.border)),
          border: OutlineInputBorder(borderRadius: radius)),
      textSelectionTheme: base.textSelectionTheme.copyWith(
          cursorColor: scheme.primary,
          selectionColor: scheme.primary.withValues(alpha: .20),
          selectionHandleColor: scheme.primary),
      extensions: [
        ...base.extensions.values
            .where((value) => value is! ConversationDecorationTheme),
        skin
      ],
    );
  }

  @override
  ConversationDecorationTheme copyWith(
          {ChatIllustratedTheme? decoration,
          Color? background,
          Color? glow,
          Color? panel,
          Color? input,
          Color? border}) =>
      ConversationDecorationTheme(
          decoration: decoration ?? this.decoration,
          background: background ?? this.background,
          glow: glow ?? this.glow,
          panel: panel ?? this.panel,
          input: input ?? this.input,
          border: border ?? this.border);

  @override
  ConversationDecorationTheme lerp(
      ThemeExtension<ConversationDecorationTheme>? other, double t) {
    if (other is! ConversationDecorationTheme) return this;
    return ConversationDecorationTheme(
        decoration: t < .5 ? decoration : other.decoration,
        background: Color.lerp(background, other.background, t)!,
        glow: Color.lerp(glow, other.glow, t)!,
        panel: Color.lerp(panel, other.panel, t)!,
        input: Color.lerp(input, other.input, t)!,
        border: Color.lerp(border, other.border, t)!);
  }
}
