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

  test('ThirdPartyLoginResult parses bound-account string token response', () {
    final result = ThirdPartyLoginResult.fromJson({
      'code': 0,
      'data': 'third-party-token',
      'extra': {
        'id': 7,
        'userName': 'alice',
        'email': 'alice@example.com',
        'phone': null,
        'role': 'user',
      },
    });

    expect(result.needBinding, isFalse);
    expect(result.token, 'third-party-token');
    expect(result.bindTicket, isNull);
    expect(result.extra?['userName'], 'alice');
  });

  test('ThirdPartyLoginResult keeps unbound-account bind ticket response', () {
    final result = ThirdPartyLoginResult.fromJson({
      'code': 0,
      'data': {
        'needBinding': true,
        'bindTicket': 'bind-ticket-123',
      },
      'extra': <String, dynamic>{},
    });

    expect(result.needBinding, isTrue);
    expect(result.token, isNull);
    expect(result.bindTicket, 'bind-ticket-123');
  });

  test('ThirdPartyLoginResult tolerates unsupported or null data', () {
    final unsupportedValues = <Object?>[
      null,
      42,
      <Object?>['unexpected'],
      <String, dynamic>{'unexpected': true},
    ];

    for (final data in unsupportedValues) {
      final result = ThirdPartyLoginResult.fromJson({
        'data': data,
        'extra': {'accountHash': 'u1'},
      });

      expect(result.needBinding, isFalse, reason: 'data: $data');
      expect(result.token, isNull, reason: 'data: $data');
      expect(result.bindTicket, isNull, reason: 'data: $data');
      expect(result.extra?['accountHash'], 'u1', reason: 'data: $data');
    }
  });
}
