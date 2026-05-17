import '../util/navigator_util.dart';
import 'token_storage.dart';

/// SDK 主配置 — 把所有"非通用"的耦合点集中在这里。
///
/// 用法：
/// ```
/// LoginSdkConfig.install(LoginSdkConfig(
///   baseUrl: 'http://localhost:3000',
///   headerProvider: () async => {'Content-Type': 'application/json'},
///   routes: LoginRoutes.imooc,
///   responseAdapter: ImoocResponseAdapter(),
///   storage: HiCacheTokenStorage(),
///   onLogoutNavigate: () => NavigatorUtil.goToLogin(),
/// ));
/// ```
///
/// 若 host 未 install，SDK 会自动回退到 [_defaultImooc] —— 保证现状不破。
class LoginSdkConfig {
  final String baseUrl;
  final bool useHttps;
  final Future<Map<String, String>> Function() headerProvider;

  /// 同步 header — 给老路径 [hiHeaders] 兜底用。
  /// 如果新设计完全异步化了，这个可以删；目前先保留以维持 DAO 同步调用形态。
  final Map<String, String> Function() syncHeaders;

  final LoginRoutes routes;
  final LoginResponseAdapter responseAdapter;
  final TokenStorage storage;
  final void Function() onLogoutNavigate;

  const LoginSdkConfig({
    required this.baseUrl,
    required this.headerProvider,
    required this.syncHeaders,
    required this.routes,
    required this.responseAdapter,
    required this.storage,
    required this.onLogoutNavigate,
    this.useHttps = false,
  });

  static LoginSdkConfig? _instance;

  /// 当前生效的配置。未 install 时回退到 imooc 默认。
  static LoginSdkConfig get instance => _instance ??= _defaultImooc();

  /// 是否已显式注入（用于 BackendConfig 决定回退路径）
  static bool get isInstalled => _instance != null;

  static void install(LoginSdkConfig cfg) => _instance = cfg;

  /// 测试用 — 重置回未 install 状态
  static void reset() => _instance = null;

  /// imooc 默认配置 —— 与改造前行为等价
  static LoginSdkConfig _defaultImooc() => LoginSdkConfig(
        baseUrl: 'localhost:3000',
        useHttps: false,
        headerProvider: () async => _imoocSyncHeaders(),
        syncHeaders: _imoocSyncHeaders,
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: HiCacheTokenStorage(),
        onLogoutNavigate: NavigatorUtil.goToLogin,
      );
}

Map<String, String> _imoocSyncHeaders() => const {
      'auth-token': 'YOUR_COURSE_AUTH_TOKEN',
      'course-flag': 'fg',
    };

/// 四条 user 路由 — 默认值匹配 chatgpt_backend 现状
class LoginRoutes {
  final String login;
  final String register;
  final String forgotPasswordRequest;
  final String forgotPasswordConfirm;

  const LoginRoutes({
    this.login = '/uapi/user/login',
    this.register = '/uapi/user/registration',
    this.forgotPasswordRequest = '/uapi/user/forgot-password/request',
    this.forgotPasswordConfirm = '/uapi/user/forgot-password/confirm',
  });

  static const LoginRoutes imooc = LoginRoutes();
}

/// 解析后的登录结果 — 通用字段 + extras 兜底
class LoginResult {
  final String token;
  final String userName;
  final String? avatar;

  /// 容纳后端特定字段（imooc 的 imoocId 进这里）
  final Map<String, dynamic> extras;

  const LoginResult({
    required this.token,
    required this.userName,
    this.avatar,
    this.extras = const {},
  });
}

/// 响应解析适配器 — 把后端响应映射成 [LoginResult]。
abstract class LoginResponseAdapter {
  /// 解析登录 / 注册响应；失败时 throw [Exception]。
  LoginResult parseLogin(Map<String, dynamic> json);

  /// 给"只看是否成功"的接口用（forgot-password/confirm 等）。
  /// 失败时 throw [Exception]。
  void checkOk(Map<String, dynamic> json);
}

/// imooc 后端响应格式：
/// ```
/// { "code": 0, "data": "<token>", "extra": { "userName", "avatar", "imoocId" } }
/// ```
class ImoocResponseAdapter implements LoginResponseAdapter {
  @override
  LoginResult parseLogin(Map<String, dynamic> json) {
    if (json['code'] != 0 || json['data'] == null) {
      throw Exception(json);
    }
    final extra = (json['extra'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LoginResult(
      token: json['data'] as String,
      userName: (extra['userName'] ?? '') as String,
      avatar: extra['avatar'] as String?,
      extras: extra,
    );
  }

  @override
  void checkOk(Map<String, dynamic> json) {
    if (json['code'] != 0) {
      throw Exception(json['message'] ?? '操作失败');
    }
  }
}
