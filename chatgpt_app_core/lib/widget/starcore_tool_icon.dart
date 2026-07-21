import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:flutter/material.dart';

/// 二次元主题中仅为受审核的工具展示 Starcore SVG。
class StarcoreToolIcon extends StatelessWidget {
  final String toolName;
  final Widget fallback;
  final double size;

  const StarcoreToolIcon({
    super.key,
    required this.toolName,
    required this.fallback,
    this.size = 18,
  });

  String? get _asset => switch (toolName) {
        ToolRegistry.webSearchId => StarcoreIconAssets.toolWebSearch,
        ToolRegistry.knowledgeSearchId =>
          StarcoreIconAssets.toolKnowledgeSearch,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    if (!AppVisualTheme.of(context).isAnime || asset == null) return fallback;
    return StarcoreSvgIcon(
      assetName: asset,
      fallback: fallback,
      size: size,
    );
  }
}
