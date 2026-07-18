import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 内存版 TokenStorage：profile 的组装方式与 [HiCacheTokenStorage] 保持一致
/// （accountHash 默认取 userName.hashCode，extras 在后展开可覆盖），
/// 用于在不初始化 HiCache 的情况下走真实 LoginDao 代码路径。
class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;
  bool throwAfterNextWrite = false;

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Map<String, dynamic>? readProfileSync() => _profile;

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
    if (throwAfterNextWrite) {
      throwAfterNextWrite = false;
      throw StateError('write failed after mutation');
    }
  }

  @override
  Future<void> clear() async => _profile = null;
}

void main() {
  late _MemoryTokenStorage storage;
  var logoutNavigated = 0;

  setUp(() {
    LoginDao.resetHooksForTest();
    storage = _MemoryTokenStorage();
    logoutNavigated = 0;
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () => logoutNavigated++,
    ));
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  group('游客模式登录', () {
    test('loginAsGuest 写入哨兵 token + guest 资料，不访问网络', () async {
      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.isGuest(), isFalse);

      await LoginDao.loginAsGuest();

      expect(LoginDao.getBoardingPass(), LoginDao.kGuestToken);
      expect(LoginDao.isGuest(), isTrue);
      // accountHash 固定 'guest'（extras 覆盖默认的 userName.hashCode），
      // 游客的会话库 / AI 设置由此与正式账号隔离。
      expect(LoginDao.getAccountHash(), 'guest');
      expect(LoginDao.getUserInfo()?['userName'], '游客');
    });

    test('loginAsGuest 触发登录钩子（宿主据此 reload AI 设置）', () async {
      var loginHookFired = 0;
      LoginDao.addLoginHook(() => loginHookFired++);
      await LoginDao.loginAsGuest();
      expect(loginHookFired, 1);
    });

    test('异步 ready hook 在旧同步 hook 前完成', () async {
      final order = <String>[];
      LoginDao.addLoginReadyHook(() async {
        await Future<void>.delayed(Duration.zero);
        order.add('ready');
      });
      LoginDao.addLoginHook(() => order.add('legacy'));

      await LoginDao.loginAsGuest();

      expect(order, ['ready', 'legacy']);
    });

    test('异步 ready hook 失败会阻止旧同步 hook 继续加载未就绪数据', () async {
      var legacyHookCalled = false;
      LoginDao.addLoginReadyHook(() async {
        throw StateError('secure storage unavailable');
      });
      LoginDao.addLoginHook(() => legacyHookCalled = true);

      await expectLater(LoginDao.loginAsGuest(), throwsStateError);

      expect(legacyHookCalled, isFalse);
      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.isGuest(), isFalse);
    });

    test('storage 写入半提交后抛错会回滚到此前登录态', () async {
      await storage.writeProfile(token: 'old-token', userName: 'old-user');
      storage.throwAfterNextWrite = true;

      await expectLater(
        LoginDao.saveAuthToken('new-token', userName: 'new-user'),
        throwsStateError,
      );

      expect(LoginDao.getBoardingPass(), 'old-token');
      expect(LoginDao.getUserInfo()?['userName'], 'old-user');
    });

    test('并发登录事务串行，前一失败回滚不会覆盖后一成功登录', () async {
      await storage.writeProfile(token: 'old-token', userName: 'old-user');
      final hookStarted = Completer<void>();
      final releaseHook = Completer<void>();
      LoginDao.addLoginReadyHook(() async {
        if (LoginDao.getBoardingPass() != 'token-a') return;
        hookStarted.complete();
        await releaseHook.future;
        throw StateError('account-a prepare failed');
      });

      final loginA = LoginDao.saveAuthToken(
        'token-a',
        userName: 'account-a',
        extras: const {'accountHash': 'account-a'},
      );
      await hookStarted.future;
      final loginB = LoginDao.saveAuthToken(
        'token-b',
        userName: 'account-b',
        extras: const {'accountHash': 'account-b'},
      );
      releaseHook.complete();

      await expectLater(loginA, throwsStateError);
      await loginB;
      expect(LoginDao.getBoardingPass(), 'token-b');
      expect(LoginDao.getAccountHash(), 'account-b');
    });

    test('网络登录等待期间退出后，迟到响应不能重新写回登录态', () async {
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      var loginHookFired = 0;
      LoginDao.addLoginHook(() => loginHookFired++);
      Future<http.Response> handler(http.Request _) {
        requestStarted.complete();
        return responseGate.future;
      }

      Object? loginError;

      await http.runWithClient(() async {
        final login = LoginDao.login(
          userName: 'late-user',
          password: 'password',
        );
        await requestStarted.future;
        await LoginDao.logOut();
        responseGate.complete(_loginResponse(
          token: 'late-token',
          userName: 'late-user',
        ));
        try {
          await login;
        } catch (error) {
          loginError = error;
        }
      }, () => MockClient(handler));

      expect(loginError, isA<LoginAccountChangedException>());
      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.getAccountHash(), isNull);
      expect(loginHookFired, 0);
    });

    test('较旧 register 响应晚于新 login 时不能覆盖新账号', () async {
      final oldResponse = Completer<http.Response>();
      final newResponse = Completer<http.Response>();
      final bothRequestsStarted = Completer<void>();
      var requestCount = 0;
      var loginHookFired = 0;
      LoginDao.addLoginHook(() => loginHookFired++);
      Future<http.Response> handler(http.Request request) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestCount++;
        if (requestCount == 2) bothRequestsStarted.complete();
        return body['userName'] == 'old-user'
            ? oldResponse.future
            : newResponse.future;
      }

      Object? oldError;
      Object? newError;

      await http.runWithClient(() async {
        final oldAttempt = LoginDao.register(
          userName: 'old-user',
          password: 'password',
        );
        final newAttempt = LoginDao.login(
          userName: 'new-user',
          password: 'password',
        );
        await bothRequestsStarted.future;

        newResponse.complete(_loginResponse(
          token: 'new-token',
          userName: 'new-user',
        ));
        try {
          await newAttempt;
        } catch (error) {
          newError = error;
        }

        oldResponse.complete(_loginResponse(
          token: 'old-token',
          userName: 'old-user',
        ));
        try {
          await oldAttempt;
        } catch (error) {
          oldError = error;
        }
      }, () => MockClient(handler));

      expect(newError, isNull);
      expect(oldError, isA<LoginAccountChangedException>());
      expect(LoginDao.getBoardingPass(), 'new-token');
      expect(LoginDao.getAccountHash(), 'new-user');
      expect(loginHookFired, 1);
    });

    test('游客的 hiHeaders 带哨兵 boarding-pass（后端会拒绝，由 UI 层屏蔽入口）', () async {
      await LoginDao.loginAsGuest();
      expect(hiHeaders()['boarding-pass'], LoginDao.kGuestToken);
    });

    test('logOut 清掉游客态并跳登录页；钩子执行时仍可判断 isGuest', () async {
      await LoginDao.loginAsGuest();
      var wasGuestInHook = false;
      LoginDao.addLogoutHook(() => wasGuestInHook = LoginDao.isGuest());

      await LoginDao.logOut();

      expect(wasGuestInHook, isTrue,
          reason: '登出钩子先于 storage.clear() 执行（app.dart 据此跳过游客的设置重置）');
      expect(LoginDao.getBoardingPass(), isNull);
      expect(LoginDao.isGuest(), isFalse);
      expect(logoutNavigated, 1);
    });

    test('异步 logout ready hook 完成后才执行同步清理和 storage clear', () async {
      await LoginDao.loginAsGuest();
      final order = <String>[];
      LoginDao.addLogoutReadyHook(() async {
        order.add('ready-start');
        await Future<void>.delayed(Duration.zero);
        expect(LoginDao.isGuest(), isTrue);
        order.add('ready-end');
      });
      LoginDao.addLogoutHook(() {
        expect(LoginDao.isGuest(), isTrue);
        order.add('sync');
      });

      await LoginDao.logOut();

      expect(order, ['ready-start', 'ready-end', 'sync']);
      expect(LoginDao.getBoardingPass(), isNull);
    });

    test('正式登录的资料不带 guest 标记', () async {
      await storage.writeProfile(token: 'real-token', userName: 'alice');
      expect(LoginDao.isGuest(), isFalse);
      expect(LoginDao.getAccountHash(), 'alice'.hashCode.toString());
    });
  });
}

http.Response _loginResponse({
  required String token,
  required String userName,
}) =>
    http.Response(
      jsonEncode({
        'code': 0,
        'data': token,
        'extra': {
          'userName': userName,
          'accountHash': userName,
        },
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
