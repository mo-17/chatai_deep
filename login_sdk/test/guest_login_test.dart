import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 内存版 TokenStorage：profile 的组装方式与 [HiCacheTokenStorage] 保持一致
/// （accountHash 默认取 userName.hashCode，extras 在后展开可覆盖），
/// 用于在不初始化 HiCache 的情况下走真实 LoginDao 代码路径。
class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

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
  }

  @override
  Future<void> clear() async => _profile = null;
}

void main() {
  late _MemoryTokenStorage storage;
  var logoutNavigated = 0;

  setUp(() {
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

    test('游客的 hiHeaders 带哨兵 boarding-pass（后端会拒绝，由 UI 层屏蔽入口）',
        () async {
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

    test('正式登录的资料不带 guest 标记', () async {
      await storage.writeProfile(token: 'real-token', userName: 'alice');
      expect(LoginDao.isGuest(), isFalse);
      expect(LoginDao.getAccountHash(), 'alice'.hashCode.toString());
    });
  });
}
