import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class StarcoreSvgIcon extends StatelessWidget {
  final String assetName;
  final Widget fallback;
  final double size;
  final bool excludeFromSemantics;

  const StarcoreSvgIcon({
    super.key,
    required this.assetName,
    required this.fallback,
    this.size = 24,
    this.excludeFromSemantics = true,
  });

  String get assetKey =>
      'starcore-svg-${assetName.split('/').last.replaceFirst('.svg', '')}';

  @override
  Widget build(BuildContext context) => SizedBox.square(
        key: ValueKey(assetKey),
        dimension: size,
        child: SvgPicture.asset(
          assetName,
          package: StarcoreIconAssets.packageName,
          width: size,
          height: size,
          fit: BoxFit.contain,
          excludeFromSemantics: excludeFromSemantics,
          placeholderBuilder: (_) => Center(child: fallback),
          errorBuilder: (_, __, ___) => Center(child: fallback),
        ),
      );
}
