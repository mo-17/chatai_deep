import 'package:flutter/material.dart';
import 'aperture_painter.dart';
import 'aurora_painter.dart';
import 'band_painter.dart';
import 'blueprint_painter.dart';
import 'botanical_bg.dart';
import 'citylight_painter.dart';
import 'dotmap_painter.dart';
import 'duotone_painter.dart';
import 'liquid_painter.dart';
import 'marble_painter.dart';
import 'matrix_painter.dart';
import 'mesh_painter.dart';
import 'origami_painter.dart';
import 'paper_painter.dart';
import 'photo_painter.dart';
import 'retrowave_painter.dart';
import 'ribbon_painter.dart';
import 'sunset_painter.dart';
import 'topo_painter.dart';
import 'wave_painter.dart';

enum LoginBgVariant {
  mesh,
  aurora,
  blueprint,
  botanical,
  sunset,
  citylight,
  paper,
  retrowave,
  liquid,
  ribbon,
  topo,
  dotmap,
  wave,
  origami,
  band,
  duotone,
  marble,
  photo,
  aperture,
  matrix,
}

class LoginBackgroundMeta {
  final Widget widget;
  // Background is dark enough that foreground text should be white-on-overlay.
  final bool isDarkBg;
  // Sepia/paper-tone palette — warm browns for text, cream card surface.
  // Used by both 'paper' and 'marble' (the design treats them identically).
  final bool isPaper;
  // Skip BackdropFilter on the card. Only true for the literal paper bg —
  // glass-on-printed-paper looks wrong; marble still wants the blur.
  final bool isSolidCard;

  const LoginBackgroundMeta({
    required this.widget,
    required this.isDarkBg,
    this.isPaper = false,
    this.isSolidCard = false,
  });
}

LoginBackgroundMeta loginBackgroundFor(LoginBgVariant variant, Color primaryColor) {
  switch (variant) {
    case LoginBgVariant.mesh:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: MeshBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.aurora:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: AuroraBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.blueprint:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: BlueprintBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.botanical:
      return LoginBackgroundMeta(
        widget: BotanicalBg(primaryColor: primaryColor),
        isDarkBg: false,
      );
    case LoginBgVariant.sunset:
      return const LoginBackgroundMeta(
        widget: CustomPaint(
          painter: SunsetBgPainter(),
          child: SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.citylight:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: CityLightBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.paper:
      return const LoginBackgroundMeta(
        widget: CustomPaint(
          painter: PaperBgPainter(),
          child: SizedBox.expand(),
        ),
        isDarkBg: false,
        isPaper: true,
        isSolidCard: true,
      );
    case LoginBgVariant.retrowave:
      return const LoginBackgroundMeta(
        widget: CustomPaint(
          painter: RetrowaveBgPainter(),
          child: SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.liquid:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: LiquidBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.ribbon:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: RibbonBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.topo:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: TopoBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.dotmap:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: DotMapBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.wave:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: WaveBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.origami:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: OrigamiBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
      );
    case LoginBgVariant.band:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: BandBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.duotone:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: DuotoneBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.marble:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: MarbleBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: false,
        isPaper: true,
      );
    case LoginBgVariant.photo:
      return const LoginBackgroundMeta(
        widget: CustomPaint(
          painter: PhotoBgPainter(),
          child: SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.aperture:
      return LoginBackgroundMeta(
        widget: CustomPaint(
          painter: ApertureBgPainter(primaryColor: primaryColor),
          child: const SizedBox.expand(),
        ),
        isDarkBg: true,
      );
    case LoginBgVariant.matrix:
      return const LoginBackgroundMeta(
        widget: CustomPaint(
          painter: MatrixBgPainter(),
          child: SizedBox.expand(),
        ),
        isDarkBg: true,
      );
  }
}
