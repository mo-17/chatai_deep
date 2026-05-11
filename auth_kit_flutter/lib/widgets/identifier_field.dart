import 'package:flutter/material.dart';
import '../util/country_codes.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';
import 'country_code_picker.dart';

/// 智能输入框：邮箱模式显示邮箱键盘，手机号模式显示数字键盘+区号选择
class IdentifierField extends StatelessWidget {
  final String channel; // 'email' | 'sms'
  final TextEditingController controller;
  final CountryCode? countryCode;
  final ValueChanged<CountryCode>? onCountryCodeChanged;
  final AuthKitTheme? theme;

  const IdentifierField({
    super.key,
    required this.channel,
    required this.controller,
    this.countryCode,
    this.onCountryCodeChanged,
    this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme ?? AuthKitTheme.defaults();
    final l10n = AuthKitL10n.instance;

    if (channel == 'email') {
      return TextField(
        controller: controller,
        keyboardType: TextInputType.emailAddress,
        style: TextStyle(fontSize: 15, color: t.textColor),
        decoration: InputDecoration(
          hintText: l10n.emailHint,
          prefixIcon: Icon(Icons.email_outlined, color: t.subtitleColor),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(t.borderRadius),
            borderSide: BorderSide(color: t.borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(t.borderRadius),
            borderSide: BorderSide(color: t.borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(t.borderRadius),
            borderSide: BorderSide(color: t.primaryColor, width: 2),
          ),
        ),
      );
    }

    // 手机号模式
    return Row(
      children: [
        CountryCodePicker(
          selected: countryCode ?? supportedCountries[0],
          onChanged: onCountryCodeChanged ?? (_) {},
          theme: t,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.phone,
            style: TextStyle(fontSize: 15, color: t.textColor),
            decoration: InputDecoration(
              hintText: l10n.phoneHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(t.borderRadius),
                borderSide: BorderSide(color: t.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(t.borderRadius),
                borderSide: BorderSide(color: t.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(t.borderRadius),
                borderSide: BorderSide(color: t.primaryColor, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
