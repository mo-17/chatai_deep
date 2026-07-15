import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late _MemoryTokenStorage storage;

  setUp(() async {
    LoginDao.resetHooksForTest();
    storage = _MemoryTokenStorage();
    await storage.writeProfile(
      token: 'token-a',
      userName: 'user-a',
      extras: const {'accountHash': 'account-a'},
    );
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'http://localhost:3000',
      headerProvider: () async => <String, String>{},
      syncHeaders: () => <String, String>{},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () {},
    ));
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  test('稳定账号操作期间退出登录必须排队等待', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var logoutCompleted = false;

    final protected = LoginDao.runWithStableAccount<int>(
      expectedAccountHash: 'account-a',
      action: () async {
        entered.complete();
        await release.future;
        expect(LoginDao.getAccountHash(), 'account-a');
        return 42;
      },
    );
    await entered.future;

    final logout = LoginDao.logOut().then((_) => logoutCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(logoutCompleted, isFalse);
    expect(LoginDao.getBoardingPass(), 'token-a');

    release.complete();
    expect(await protected, 42);
    await logout;
    expect(logoutCompleted, isTrue);
    expect(LoginDao.getBoardingPass(), isNull);
  });

  test('稳定账号操作期间新登录也必须排队等待', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var loginCompleted = false;

    final protected = LoginDao.runWithStableAccount<void>(
      expectedAccountHash: 'account-a',
      action: () async {
        entered.complete();
        await release.future;
        expect(LoginDao.getAccountHash(), 'account-a');
      },
    );
    await entered.future;

    final login = LoginDao.loginAsGuest().then((_) => loginCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(loginCompleted, isFalse);
    expect(LoginDao.getAccountHash(), 'account-a');

    release.complete();
    await protected;
    await login;
    expect(loginCompleted, isTrue);
    expect(LoginDao.getAccountHash(), 'guest');
  });

  test('宿主绕过 LoginDao 切换账号会被结束校验拦截', () async {
    await expectLater(
      LoginDao.runWithStableAccount<void>(
        expectedAccountHash: 'account-a',
        action: () async {
          await storage.writeProfile(
            token: 'token-b',
            userName: 'user-b',
            extras: const {'accountHash': 'account-b'},
          );
        },
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );

    // 结束校验失败不应毒化共用的登录串行队列。
    await LoginDao.loginAsGuest();
    expect(LoginDao.getAccountHash(), 'guest');
  });

  test('账号在操作开始前已变化则拒绝且不毒化后续登录队列', () async {
    var called = false;

    await expectLater(
      LoginDao.runWithStableAccount<void>(
        expectedAccountHash: 'account-b',
        action: () async {
          called = true;
        },
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );
    expect(called, isFalse);

    await LoginDao.loginAsGuest();
    expect(LoginDao.isGuest(), isTrue);
    expect(LoginDao.getAccountHash(), 'guest');
  });
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<void> clear() async => _profile = null;

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode,
      ...extras,
    };
  }
}
