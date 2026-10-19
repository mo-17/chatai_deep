import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('鸿蒙原生标准通道与现有 PackageInfo.fromPlatform 兼容', () async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAll');
      return {
        'appName': '艾普',
        'packageName': 'com.hzb.flutter_ai',
        'version': '2.3.4',
        'buildNumber': '2345678',
        'buildSignature': ''
      };
    });
    final info = await PackageInfo.fromPlatform();
    expect(info.appName, '艾普');
    expect(info.packageName, 'com.hzb.flutter_ai');
    expect(info.version, '2.3.4');
    expect(info.buildNumber, '2345678');
    expect(info.buildSignature, isEmpty);
  });
}
