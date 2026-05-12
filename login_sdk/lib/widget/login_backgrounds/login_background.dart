import 'package:flutter/material.dart';
import 'aurora_painter.dart';
import 'blueprint_painter.dart';
import 'botanical_bg.dart';
import 'mesh_painter.dart';

enum LoginBgVariant { mesh, aurora, blueprint, botanical }

class LoginBackgroundMeta {
  final Widget widget;
  final bool isDarkBg;

  const LoginBackgroundMeta({required this.widget, required this.isDarkBg});
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
  }
}
