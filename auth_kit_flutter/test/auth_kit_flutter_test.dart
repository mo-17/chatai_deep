import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PublicConfig', () {
    test('defaults keeps third-party login disabled', () {
      final config = PublicConfig.defaults();

      expect(config.huaweiGetAuthCodeEnabled, isFalse);
      expect(config.huaweiQuickLoginEnabled, isFalse);
      expect(config.huaweiPrimaryFlow, 'getAuthCode');
      expect(config.appleSignInEnabled, isFalse);
      expect(config.countryCodes, isEmpty);
    });

    test('fromJson parses feature switches and country codes', () {
      final config = PublicConfig.fromJson({
        'huaweiGetAuthCodeEnabled': true,
        'huaweiQuickLoginEnabled': true,
        'huaweiPrimaryFlow': 'quickLogin',
        'appleSignInEnabled': true,
        'supportedCountryCodes': [
          {'code': '+86', 'name': '中国'},
          {'code': '+1', 'name': 'United States'},
        ],
      });

      expect(config.huaweiGetAuthCodeEnabled, isTrue);
      expect(config.huaweiQuickLoginEnabled, isTrue);
      expect(config.huaweiPrimaryFlow, 'quickLogin');
      expect(config.appleSignInEnabled, isTrue);
      expect(config.countryCodes, hasLength(2));
      expect(config.countryCodes.first['code'], '+86');
    });
  });

  test('AuthKitTheme defaults are usable by host login pages', () {
    final theme = AuthKitTheme.defaults();

    expect(theme.primaryColor, const Color(0xFF0F3460));
    expect(theme.surfaceColor, Colors.white);
    expect(theme.borderRadius, 12);
    expect(theme.inputHeight, 48);
  });

  test('LoginResult parses token and extra payload', () {
    final result = LoginResult.fromJson({
      'data': 'token-123',
      'extra': {'accountHash': 'u1'},
    });

    expect(result.token, 'token-123');
    expect(result.extra['accountHash'], 'u1');
  });
}
