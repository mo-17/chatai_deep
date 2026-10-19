import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:chatgpt_flutter_ohos/ohos_huawei_login_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = OhosHuaweiLoginService();
  tearDown(() =>
      messenger.setMockMethodCallHandler(OhosHuaweiLoginService.channel, null));
  test(
      'both interface methods use authorization codes; never return a client token',
      () async {
    messenger.setMockMethodCallHandler(OhosHuaweiLoginService.channel,
        (call) async {
      expect(call.method, 'signIn');
      return {'authCode': 'one-use-code', 'accessToken': 'ignored'};
    });
    for (final request in [
      service.signInWithAuthCode,
      service.signInWithQuickLogin
    ]) {
      final result = await request();
      expect(result.mode, 'getAuthCode');
      expect(result.authCode, 'one-use-code');
      expect(result.accessToken, isNull);
    }
  });
  test('cancellation has a distinct silent exception', () async {
    messenger.setMockMethodCallHandler(OhosHuaweiLoginService.channel,
        (_) async {
      throw PlatformException(code: 'huawei_cancelled', message: 'raw-secret');
    });
    await expectLater(service.signInWithAuthCode(),
        throwsA(isA<HuaweiLoginCancelledException>()));
  });
  test('native errors and malformed replies cannot leak provider details',
      () async {
    for (final response in [
      null,
      {'authCode': ''},
      {'authCode': 7}
    ]) {
      messenger.setMockMethodCallHandler(
          OhosHuaweiLoginService.channel, (_) async => response);
      await expectLater(
          service.signInWithAuthCode(), throwsA(isA<HuaweiLoginException>()));
    }
    for (final code in [
      'huawei_not_configured',
      'huawei_network',
      'huawei_timeout',
      'unexpected'
    ]) {
      messenger.setMockMethodCallHandler(OhosHuaweiLoginService.channel,
          (_) async {
        throw PlatformException(code: code, message: 'raw-secret');
      });
      await expectLater(
          service.signInWithAuthCode(),
          throwsA(isA<HuaweiLoginException>().having((e) => e.message,
              'safe message', isNot(contains('raw-secret')))));
    }
  });
}
