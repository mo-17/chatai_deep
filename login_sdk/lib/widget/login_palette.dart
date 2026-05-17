import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';

import 'login_backgrounds/login_background.dart';

/// All chrome colors used by the login + register + forgot-password pages.
/// Built once per render from a theme + [LoginBackgroundMeta] so every
/// builder reads bg-aware values without re-deriving the branching logic.
class LoginPalette {
  final Color heroText;
  final Color heroSub;
  final Color cardBg;
  final Color cardBorder;
  final Color cardShadow;
  final Color cardText;
  final Color cardSub;
  final Color cardBorderSoft;
  final Color cardDivider;
  final Color inputBg;
  final Color tabActive;
  final Color submitBg;
  final Color submitFg;
  final Color modeOuterBg;
  final Color modeChipActiveBg;
  final Color modeChipActiveFg;
  final Color modeChipInactiveFg;
  final Color linkColor;
  final Color outsideDivider;
  final Color outsideFaint;
  final Color mandatoryBg;
  final Color mandatoryFg;
  // Non-null for dark backgrounds where the mandatory button uses a glass
  // surface (white outline) instead of a solid pill.
  final Color? mandatoryBorder;
  final Color socialBg;
  final Color? socialBorder;
  final Color socialLabel;
  final Color agreementBoxBg;
  final Color agreementBoxBorder;
  final Color agreementCheck;
  final Color agreementText;
  final Color agreementLink;
  final Color errorColor;

  const LoginPalette({
    required this.heroText,
    required this.heroSub,
    required this.cardBg,
    required this.cardBorder,
    required this.cardShadow,
    required this.cardText,
    required this.cardSub,
    required this.cardBorderSoft,
    required this.cardDivider,
    required this.inputBg,
    required this.tabActive,
    required this.submitBg,
    required this.submitFg,
    required this.modeOuterBg,
    required this.modeChipActiveBg,
    required this.modeChipActiveFg,
    required this.modeChipInactiveFg,
    required this.linkColor,
    required this.outsideDivider,
    required this.outsideFaint,
    required this.mandatoryBg,
    required this.mandatoryFg,
    this.mandatoryBorder,
    required this.socialBg,
    this.socialBorder,
    required this.socialLabel,
    required this.agreementBoxBg,
    required this.agreementBoxBorder,
    required this.agreementCheck,
    required this.agreementText,
    required this.agreementLink,
    required this.errorColor,
  });

  /// Tabs / non-bg surface — pulls everything from the AuthKit theme.
  factory LoginPalette.forTabs(AuthKitTheme t, bool isDark) {
    return LoginPalette(
      heroText: t.textColor,
      heroSub: t.subtitleColor,
      cardBg: t.backgroundColor,
      cardBorder: t.borderColor,
      cardShadow: const Color(0x14000000),
      cardText: t.textColor,
      cardSub: t.subtitleColor,
      cardBorderSoft: t.borderColor,
      cardDivider: t.borderColor.withValues(alpha: 0.6),
      inputBg: const Color(0x00000000),
      tabActive: t.primaryColor,
      submitBg: t.primaryColor,
      submitFg: isDark ? const Color(0xFF0C0D0E) : Colors.white,
      modeOuterBg: t.surfaceColor,
      modeChipActiveBg: t.backgroundColor,
      modeChipActiveFg: t.textColor,
      modeChipInactiveFg: t.subtitleColor,
      linkColor: t.primaryColor,
      outsideDivider: t.borderColor.withValues(alpha: 0.6),
      outsideFaint: t.subtitleColor.withValues(alpha: 0.62),
      mandatoryBg: t.textColor,
      mandatoryFg: t.backgroundColor,
      socialBg: t.surfaceColor,
      socialLabel: t.subtitleColor,
      agreementBoxBg: t.primaryColor,
      agreementBoxBorder: t.primaryColor,
      agreementCheck: Colors.white,
      agreementText: t.subtitleColor,
      agreementLink: t.primaryColor,
      errorColor: t.errorColor,
    );
  }

  /// Immersive bg — three flavors:
  ///   * paper/marble  → warm sepia palette
  ///   * dark bg       → white-on-image with glass surfaces
  ///   * light bg      → same as tabs (theme tokens are already legible)
  factory LoginPalette.forBg(
      AuthKitTheme t, bool isDark, LoginBackgroundMeta m) {
    if (m.isPaper) {
      return LoginPalette(
        heroText: const Color(0xFF3A2E15),
        heroSub: const Color(0xFF6B5532),
        cardBg: const Color(0xFFFBF6EA),
        cardBorder: const Color(0xFFD9C89A),
        cardShadow: const Color(0x14000000),
        cardText: const Color(0xFF2A2010),
        cardSub: const Color(0xFF7A6238),
        cardBorderSoft: const Color(0xFFCFB98A),
        cardDivider: const Color(0xFFE0D2A8),
        inputBg: const Color(0xFFFFF9E6),
        tabActive: t.primaryColor,
        submitBg: t.primaryColor,
        submitFg: Colors.white,
        modeOuterBg: const Color(0x14000000),
        modeChipActiveBg: Colors.white,
        modeChipActiveFg: const Color(0xFF111111),
        modeChipInactiveFg: const Color(0xFF7A6238),
        linkColor: t.primaryColor,
        outsideDivider: const Color(0xFF8A6D3B).withValues(alpha: 0.30),
        outsideFaint: const Color(0xFFA08C5A),
        mandatoryBg: const Color(0xFF3A2E15),
        mandatoryFg: const Color(0xFFFBF6EA),
        socialBg: const Color(0xFFFFF9E6),
        socialBorder: const Color(0xFFD9C89A),
        socialLabel: const Color(0xFF7A6238),
        agreementBoxBg: t.primaryColor,
        agreementBoxBorder: t.primaryColor,
        agreementCheck: Colors.white,
        agreementText: const Color(0xFF6B5532),
        agreementLink: t.primaryColor,
        errorColor: t.errorColor,
      );
    }
    if (m.isDarkBg) {
      return LoginPalette(
        heroText: Colors.white,
        heroSub: Colors.white.withValues(alpha: 0.75),
        cardBg: Colors.white.withValues(alpha: 0.10),
        cardBorder: Colors.white.withValues(alpha: 0.18),
        cardShadow: const Color(0x40000000),
        cardText: Colors.white,
        cardSub: Colors.white.withValues(alpha: 0.75),
        cardBorderSoft: Colors.white.withValues(alpha: 0.22),
        cardDivider: Colors.white.withValues(alpha: 0.15),
        inputBg: Colors.white.withValues(alpha: 0.12),
        tabActive: Colors.white,
        submitBg: Colors.white,
        submitFg: const Color(0xFF111111),
        modeOuterBg: Colors.black.withValues(alpha: 0.18),
        modeChipActiveBg: Colors.white.withValues(alpha: 0.95),
        modeChipActiveFg: const Color(0xFF111111),
        modeChipInactiveFg: Colors.white.withValues(alpha: 0.75),
        linkColor: Colors.white,
        outsideDivider: Colors.white.withValues(alpha: 0.20),
        outsideFaint: Colors.white.withValues(alpha: 0.70),
        mandatoryBg: Colors.white.withValues(alpha: 0.14),
        mandatoryFg: Colors.white,
        mandatoryBorder: Colors.white.withValues(alpha: 0.30),
        socialBg: Colors.white.withValues(alpha: 0.14),
        socialBorder: Colors.white.withValues(alpha: 0.25),
        socialLabel: Colors.white.withValues(alpha: 0.80),
        agreementBoxBg: Colors.white,
        agreementBoxBorder: Colors.white,
        agreementCheck: t.primaryColor,
        agreementText: Colors.white.withValues(alpha: 0.80),
        agreementLink: Colors.white,
        errorColor: const Color(0xFFFFB4AB),
      );
    }
    // Light, non-paper bg (mesh / aurora / blueprint / sunset / etc).
    // Theme palette is already legible against the white card.
    return LoginPalette.forTabs(t, isDark);
  }
}

/// Single-letter / two-letter labels for each background, matched to
/// [LoginBgVariant.values] order. Used by the dev-mode cycle pill.
const List<String> kLoginBgPillLabels = [
  'M',  // mesh
  'A',  // aurora
  'B',  // blueprint
  'P',  // botanical
  'S',  // sunset
  'C',  // citylight
  'Pa', // paper
  'R',  // retrowave
  'L',  // liquid
  'Ri', // ribbon
  'To', // topo
  'Do', // dotmap
  'W',  // wave
  'O',  // origami
  'Bd', // band
  'Du', // duotone
  'Mb', // marble
  'Ph', // photo
  'Ap', // aperture
  'Mx', // matrix
];
