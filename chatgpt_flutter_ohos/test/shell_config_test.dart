import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';

void main() {
  test('OHOS shell can configure a LAN backend host', () {
    BackendConfig.host = '192.168.31.167:3000';

    expect(BackendConfig.host, '192.168.31.167:3000');
  });
}
