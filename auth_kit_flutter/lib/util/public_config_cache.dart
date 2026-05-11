/// 公开配置缓存模型
class PublicConfig {
  final bool huaweiGetAuthCodeEnabled;
  final bool huaweiQuickLoginEnabled;
  final String huaweiPrimaryFlow; // 'getAuthCode' | 'quickLogin'
  final bool appleSignInEnabled;
  final List<Map<String, String>> countryCodes;

  const PublicConfig({
    required this.huaweiGetAuthCodeEnabled,
    required this.huaweiQuickLoginEnabled,
    required this.huaweiPrimaryFlow,
    required this.appleSignInEnabled,
    required this.countryCodes,
  });

  factory PublicConfig.defaults() {
    return const PublicConfig(
      huaweiGetAuthCodeEnabled: false,
      huaweiQuickLoginEnabled: false,
      huaweiPrimaryFlow: 'getAuthCode',
      appleSignInEnabled: false,
      countryCodes: [],
    );
  }

  factory PublicConfig.fromJson(Map<String, dynamic> json) {
    return PublicConfig(
      huaweiGetAuthCodeEnabled: json['huaweiGetAuthCodeEnabled'] == true,
      huaweiQuickLoginEnabled: json['huaweiQuickLoginEnabled'] == true,
      huaweiPrimaryFlow: json['huaweiPrimaryFlow']?.toString() ?? 'getAuthCode',
      appleSignInEnabled: json['appleSignInEnabled'] == true,
      countryCodes: (json['supportedCountryCodes'] as List<dynamic>?)
              ?.map((e) => Map<String, String>.from(e as Map))
              .toList() ??
          [],
    );
  }
}
