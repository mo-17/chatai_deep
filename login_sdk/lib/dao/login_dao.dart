import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';

///登录接口
class LoginDao {
  /// 同步存储读取的 key。与 [HiCacheTokenStorage._kUserInfo] 保持一致，
  /// 用作仍直接读 HiCache 的老代码兜底，新增逻辑请通过 [LoginSdkConfig.instance.storage]。
  static const kUserInfo = 'user_info';

  static final List<VoidCallback> _onLogoutHooks = [];
  static final List<VoidCallback> _onLoginHooks = [];
  static final List<Future<void> Function()> _onLoginReadyHooks = [];
  static Future<void> _authMutationTail = Future<void>.value();
  static bool hooksRegistered = false;

  /// 把必须绑定同一账号完成的短操作与登录/登出放进同一串行队列。
  ///
  /// 典型用途是备份导出/导入：操作开始时校验账号，执行期间新的登录、登出
  /// 会排队等待，避免旧账号数据库与新账号设置或资源目录交叉写入。
  /// 文件选择、用户确认等长等待不应放进 lease，只包实际读写阶段。
  static Future<T> runWithStableAccount<T>({
    required String expectedAccountHash,
    required Future<T> Function() action,
  }) =>
      _enqueueAuthOperation<T>(() async {
        if (getAccountHash() != expectedAccountHash) {
          throw const LoginAccountChangedException();
        }
        final result = await action();
        // 防御宿主绕过 LoginDao 直接替换 TokenStorage 的情况。
        if (getAccountHash() != expectedAccountHash) {
          throw const LoginAccountChangedException();
        }
        return result;
      });

  ///注册登出钩子，宿主 App 在初始化时调用，用于清理账号态
  static void addLogoutHook(VoidCallback cb) {
    _onLogoutHooks.add(cb);
  }

  ///注册登录成功钩子，在保存登录信息之后触发
  static void addLoginHook(VoidCallback cb) {
    _onLoginHooks.add(cb);
  }

  /// 登录资料写入后、旧同步 hook 与页面跳转前执行的异步准备任务。
  ///
  /// 用于按账号预载 Keychain/KeyStore secrets，保证旧同步读取 API 在首帧就绪。
  static void addLoginReadyHook(Future<void> Function() cb) {
    _onLoginReadyHooks.add(cb);
  }

  ///登录
  static Future<void> login({
    required String userName,
    required String password,
  }) async {
    return _authRequest(
        LoginSdkConfig.instance.routes.login, userName, password);
  }

  ///注册（注册成功后自动登录）
  static Future<void> register({
    required String userName,
    required String password,
  }) async {
    return _authRequest(
      LoginSdkConfig.instance.routes.register,
      userName,
      password,
    );
  }

  ///发送认证请求并处理响应（login / register 共用）
  static Future<void> _authRequest(
    String path,
    String userName,
    String password,
  ) async {
    final cfg = LoginSdkConfig.instance;
    final uri = BackendConfig.buildUri(path);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName, 'password': password}),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    if (response.statusCode != 200) {
      throw Exception(bodyString);
    }
    final json = jsonDecode(bodyString) as Map<String, dynamic>;
    final result = cfg.responseAdapter.parseLogin(json);

    await _commitLoginProfile(
      storage: cfg.storage,
      token: result.token,
      userName: result.userName,
      avatar: result.avatar,
      extras: result.extras,
    );
  }

  ///忘记密码 - 请求 reset code
  static Future<Map<String, dynamic>> requestPasswordReset(
    String userName,
  ) async {
    final uri = BackendConfig.buildUri(
        LoginSdkConfig.instance.routes.forgotPasswordRequest);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({'userName': userName}),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    if (response.statusCode == 200) {
      return jsonDecode(bodyString) as Map<String, dynamic>;
    }
    throw Exception(bodyString);
  }

  ///忘记密码 - 确认 reset code 并设置新密码
  static Future<void> confirmPasswordReset(
    String userName,
    String code,
    String newPassword,
  ) async {
    final cfg = LoginSdkConfig.instance;
    final uri = BackendConfig.buildUri(cfg.routes.forgotPasswordConfirm);
    final headers = <String, String>{
      ...hiHeaders(),
      'Content-Type': 'application/json',
    };
    final response = await http.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'userName': userName,
        'code': code,
        'newPassword': newPassword,
      }),
    );
    final bodyString = const Utf8Decoder().convert(response.bodyBytes);
    if (response.statusCode != 200) {
      throw Exception(bodyString);
    }
    cfg.responseAdapter.checkOk(jsonDecode(bodyString) as Map<String, dynamic>);
  }

  ///获取当前登录用户的信息
  static Map<String, dynamic>? getUserInfo() {
    return LoginSdkConfig.instance.storage.readProfileSync();
  }

  ///获取登录token
  static String? getBoardingPass() {
    return LoginSdkConfig.instance.storage.readTokenSync();
  }

  ///获取用于创建多账号数据的账号标识
  static String? getAccountHash() {
    final profile = LoginSdkConfig.instance.storage.readProfileSync();
    return profile?['accountHash']?.toString();
  }

  /// 多通道认证（auth_kit_flutter）登录成功后写 token。
  /// `extras` 用于扩展字段（如 imoocId、phone 等）。
  static Future<void> saveAuthToken(
    String token, {
    String? userName,
    String? avatar,
    String? imoocId,
    Map<String, dynamic> extras = const {},
  }) async {
    final merged = <String, dynamic>{
      if (imoocId != null) 'imoocId': imoocId,
      ...extras,
    };
    await _commitLoginProfile(
      storage: LoginSdkConfig.instance.storage,
      token: token,
      userName: userName ?? '',
      avatar: avatar,
      extras: merged,
    );
  }

  /// 游客模式的哨兵 token。纯本地、不会被后端接受 —— 游客的后端调用
  /// 会得到 401/失败，相关功能（后端代理等）应由宿主在 UI 层屏蔽。
  static const kGuestToken = 'guest-mode';

  ///游客模式登录：**不访问后端**，写入本地哨兵 token + 游客资料即可进入主界面。
  ///accountHash 固定为 'guest'（extras 覆盖默认的 userName.hashCode），
  ///游客的本地数据（会话库 / AI 设置）独立于任何正式账号。
  static Future<void> loginAsGuest() async {
    await _commitLoginProfile(
      storage: LoginSdkConfig.instance.storage,
      token: kGuestToken,
      userName: '游客',
      extras: const {'accountHash': 'guest', 'guest': true},
    );
  }

  ///当前是否处于游客模式
  static bool isGuest() => getUserInfo()?['guest'] == true;

  ///登出
  static Future<void> logOut() => _enqueueAuthMutation(() async {
        for (final cb in _onLogoutHooks) {
          try {
            cb();
          } catch (_) {}
        }
        await LoginSdkConfig.instance.storage.clear();
        LoginSdkConfig.instance.onLogoutNavigate();
      });

  static Future<void> _runLoginHooks() async {
    for (final cb in _onLoginReadyHooks) {
      // ready hook 负责安全存储等登录前置条件；失败必须交给 UI 重试，
      // 不能继续执行旧同步 hook 并用未就绪的空数据覆盖持久化状态。
      await cb();
    }
    for (final cb in _onLoginHooks) {
      try {
        cb();
      } catch (_) {}
    }
  }

  static Future<void> _commitLoginProfile({
    required TokenStorage storage,
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) =>
      _enqueueAuthMutation(() async {
        final previous = await _profileSnapshot(storage);
        var profileWriteCompleted = false;
        try {
          await storage.writeProfile(
            token: token,
            userName: userName,
            avatar: avatar,
            extras: extras,
          );
          profileWriteCompleted = true;
          await _runLoginHooks();
        } catch (error, stackTrace) {
          // MigratingTokenStorage 在 verified 账号的 secure 写入失败时，已经
          // 自行恢复旧安全快照或写 tombstone 安全登出。此处若再走通用回滚，
          // 会把 tombstone 重新写成 legacy 明文 token，破坏“不降级”保证。
          // ready hook 失败发生在 profile 写完之后，仍必须按旧逻辑回滚。
          if (!profileWriteCompleted &&
              storage is MigratingTokenStorage &&
              error is SecureStorageUnavailableException) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          try {
            await _restoreProfile(storage, previous);
          } catch (rollbackError) {
            Error.throwWithStackTrace(
              StateError('登录准备失败，且旧登录态恢复失败：$rollbackError'),
              stackTrace,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      });

  static Future<void> _enqueueAuthMutation(
    Future<void> Function() action,
  ) =>
      _enqueueAuthOperation<void>(action);

  static Future<T> _enqueueAuthOperation<T>(
    Future<T> Function() action,
  ) {
    final ready = _authMutationTail.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    final operation = ready.then<T>((_) => action());
    // 队尾只承担排序，不传播上一项错误；调用者仍收到原 operation 的结果。
    _authMutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  static Future<Map<String, dynamic>?> _profileSnapshot(
    TokenStorage storage,
  ) async {
    try {
      final profile = await storage.readProfile();
      return profile == null ? null : Map<String, dynamic>.from(profile);
    } catch (_) {
      final profile = storage.readProfileSync();
      return profile == null ? null : Map<String, dynamic>.from(profile);
    }
  }

  static Future<void> _restoreProfile(
    TokenStorage storage,
    Map<String, dynamic>? previous,
  ) async {
    final token = previous?['boardingPass'];
    if (previous == null || token is! String || token.isEmpty) {
      await storage.clear();
      return;
    }
    final extras = Map<String, dynamic>.from(previous)
      ..remove('boardingPass')
      ..remove('userName')
      ..remove('avatar');
    await storage.writeProfile(
      token: token,
      userName: previous['userName'] as String? ?? '',
      avatar: previous['avatar'] as String?,
      extras: extras,
    );
  }

  /// 测试隔离；生产代码不调用。
  @visibleForTesting
  static void resetHooksForTest() {
    _onLogoutHooks.clear();
    _onLoginHooks.clear();
    _onLoginReadyHooks.clear();
    _authMutationTail = Future<void>.value();
    hooksRegistered = false;
  }
}

/// 稳定账号操作开始前或结束时发现账号已变化。
///
/// 不把账号 hash 放进异常文本，避免日志意外记录账号标识。
class LoginAccountChangedException implements Exception {
  const LoginAccountChangedException();

  @override
  String toString() => '账号已切换，请在当前账号下重试';
}
