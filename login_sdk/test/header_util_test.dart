import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

import 'support/memory_token_storage.dart';

void main() {
  late MemoryTokenStorage storage;

  void configure({Map<String, String> headers = const {}}) {
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'backend.synthetic.invalid',
      headerProvider: () async => headers,
      syncHeaders: () => headers,
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () {},
    ));
  }

  setUp(() {
    LoginDao.resetHooksForTest();
    storage = MemoryTokenStorage();
    configure();
  });
  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  test('登录与账号切换后发送当前账号 Bearer，清除宿主旧认证头', () async {
    configure(headers: const {
      'authorization': 'Bearer stale-host-token',
      'X-App': 'keep',
    });
    await LoginDao.saveAuthToken('first-synthetic-jwt', userName: 'first');
    expect(hiHeaders()['Authorization'], 'Bearer first-synthetic-jwt');
    await LoginDao.saveAuthToken('second-synthetic-jwt', userName: 'second');
    final headers = hiHeaders();
    expect(headers['Authorization'], 'Bearer second-synthetic-jwt');
    expect(headers['boarding-pass'], 'second-synthetic-jwt');
    expect(headers.keys.where((key) => key.toLowerCase() == 'authorization'),
        hasLength(1));
    expect(headers['X-App'], 'keep');
  });

  test('游客哨兵保留兼容头，但不作为 Bearer 登录凭据发送', () async {
    await LoginDao.loginAsGuest();
    expect(hiHeaders()['boarding-pass'], LoginDao.kGuestToken);
    expect(hiHeaders().containsKey('Authorization'), isFalse);
  });

  test('登出后不再向后端发送上一账号的 Bearer', () async {
    await LoginDao.saveAuthToken('synthetic-jwt', userName: 'test');
    expect(hiHeaders()['Authorization'], isNotEmpty);
    await LoginDao.logOut();
    expect(hiHeaders()['boarding-pass'], isEmpty);
    expect(hiHeaders().containsKey('Authorization'), isFalse);
  });
}
