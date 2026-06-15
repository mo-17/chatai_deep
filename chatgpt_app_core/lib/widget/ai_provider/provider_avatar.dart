import 'package:chatgpt_app_core/util/provider_branding.dart';
import 'package:flutter/material.dart';

/// 服务商头像：圆角方形 + 品牌色底 + 字标（迁移自 Cherry 的 provider logo，
/// 但用「字标」而非打包十几张 logo 图——零依赖、离线、尺寸一致）。
///
/// 字标颜色按底色亮度自动取黑/白，保证对比度（do/don't 规格要求）。
class ProviderAvatar extends StatelessWidget {
  final String providerId;
  final String name;
  final double size;

  const ProviderAvatar({
    super.key,
    required this.providerId,
    this.name = '',
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final brand = ProviderBranding.resolve(providerId, name);
    final fg = brand.color.computeLuminance() > 0.4
        ? Colors.black87
        : Colors.white;
    return ClipRRect(
      // 圆角方形（像 app 图标），而非圆形——圆形会把宽字标裁坏。
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Container(
        width: size,
        height: size,
        color: brand.color,
        alignment: Alignment.center,
        child: Text(
          brand.monogram,
          style: TextStyle(
            color: fg,
            fontSize: size * 0.36,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            height: 1,
          ),
        ),
      ),
    );
  }
}
