import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';

/// 第三方登录按钮
class ThirdPartyLoginButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final AuthKitTheme? theme;

  const ThirdPartyLoginButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme ?? AuthKitTheme.defaults();
    return SizedBox(
      width: double.infinity,
      height: t.inputHeight,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: icon != null ? Icon(icon, size: 20) : const SizedBox.shrink(),
        label: Text(label, style: TextStyle(fontSize: 15, color: t.textColor)),
        style: OutlinedButton.styleFrom(
          backgroundColor: t.surfaceColor,
          side: BorderSide(color: t.borderColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.borderRadius)),
        ),
      ),
    );
  }
}
