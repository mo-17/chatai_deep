# `login_sdk` 通用化重构方案

> Status: 进行中 · Owner: huangzhibin · 起草日期: 2026-05-17

## 1. 目标 / 非目标

**目标**：把 `login_sdk` 从"专为本 imooc 课程后端定制"改造成"可配置接入任意后端"的 SDK，且**不破坏当前 app**。
**非目标**：
- 不做"任意响应格式都能解析"的通用 DSL — 提供接口让宿主写适配器即可
- 不重构 UI 层（`pages/` / `LoginPalette` / 20 个背景 painter）
- 不拆三个独立 pub 包（保留为 §8 备选）

## 2. 当前耦合点（待解耦）

| # | 文件 | 耦合内容 |
|---|---|---|
| C1 | `dao/header_util.dart` | 写死 `auth-token` / `course-flag: fg` |
| C2 | `dao/login_dao.dart` | 写死 4 条 `/uapi/user/*` 路径 |
| C3 | `dao/login_dao.dart` | 写死响应结构：`code/data/extra.userName/avatar/imoocId` |
| C4 | `dao/login_dao.dart` | 直接调 `HiCache.getInstance()` 读写 |
| C5 | `dao/login_dao.dart` | `logOut()` 末尾直接 `NavigatorUtil.goToLogin()` |
| C6 | `dao/backend_host.dart` | `_autoDetect()` 把 `:3000` 写死，且行为是默认 |

## 3. 设计：`LoginSdkConfig`

新增 `lib/config/login_sdk_config.dart`，作为 SDK 唯一注入入口：

```dart
class LoginSdkConfig {
  final String baseUrl;
  final Future<Map<String, String>> Function() headerProvider;
  final LoginRoutes routes;
  final LoginResponseAdapter responseAdapter;
  final TokenStorage storage;
  final void Function() onLogoutNavigate;

  static LoginSdkConfig? _instance;
  static LoginSdkConfig get instance =>
      _instance ?? (throw StateError('LoginSdkConfig not initialized'));
  static void install(LoginSdkConfig cfg) => _instance = cfg;
}
```

挂在 `LoginConfig.init` 上：

```dart
await LoginConfig.instance().init(
  homePage: ...,
  sdk: LoginSdkConfig(...),  // 新增可选参数；不传则用 imooc 默认
);
```

## 4. 6 个解耦点的具体替换

### 4.1 `LoginRoutes`（替换 C2）

```dart
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
```

### 4.2 `LoginResponseAdapter`（替换 C3）

```dart
class LoginResult {
  final String token;
  final String userName;
  final String? avatar;
  final Map<String, dynamic> extras;  // imoocId 进这里
  const LoginResult({required this.token, required this.userName, this.avatar, this.extras = const {}});
}

abstract class LoginResponseAdapter {
  LoginResult parseLogin(Map<String, dynamic> json);
  void checkOk(Map<String, dynamic> json);  // 给 forgot-password/confirm 等"只看是否成功"用
}

class ImoocResponseAdapter implements LoginResponseAdapter {
  @override
  LoginResult parseLogin(Map<String, dynamic> json) {
    if (json['code'] != 0 || json['data'] == null) throw Exception(json);
    final extra = (json['extra'] ?? {}) as Map<String, dynamic>;
    return LoginResult(
      token: json['data'],
      userName: extra['userName'] ?? '',
      avatar: extra['avatar'],
      extras: extra,
    );
  }
  @override
  void checkOk(Map<String, dynamic> json) {
    if (json['code'] != 0) throw Exception(json['message'] ?? '操作失败');
  }
}
```

### 4.3 `TokenStorage`（替换 C4）

```dart
abstract class TokenStorage {
  Future<String?> readToken();
  Future<Map<String, dynamic>?> readProfile();
  Future<void> writeProfile(String token, Map<String, dynamic> profile);
  Future<void> clear();
}

class HiCacheTokenStorage implements TokenStorage {
  static const _k = 'user_info';
  @override Future<String?> readToken() async {
    final m = await readProfile();
    return m?['boardingPass'];
  }
  @override Future<Map<String, dynamic>?> readProfile() async {
    final s = HiCache.getInstance().get(_k);
    return s == null ? null : jsonDecode(s);
  }
  @override Future<void> writeProfile(String token, Map<String, dynamic> profile) async {
    final m = {'boardingPass': token, ...profile, 'accountHash': profile['userName'].hashCode};
    HiCache.getInstance().setString(_k, jsonEncode(m));
  }
  @override Future<void> clear() async => HiCache.getInstance().remove(_k);
}
```

> 备注：`LoginDao.getBoardingPass()` 等同步访问的方法**保留同步签名**，内部仍走 `HiCache`（同步可用）。`TokenStorage.readToken()` 异步签名用于将来切到 `SharedPreferences` / `flutter_secure_storage` 的扩展点。

### 4.4 `headerProvider`（替换 C1）

`hiHeaders()` 留作向后兼容**别名**，内部调用 `LoginSdkConfig.instance.headerProvider()` 的同步版本（实际上 imooc 实现就是同步常量），或者迁移点同步等价物。**新代码请走 `headerProvider`。**

宿主侧示例：

```dart
LoginSdkConfig(
  headerProvider: () async => {
    'auth-token': 'ZmEtMjAy...fg',
    'course-flag': 'fg',
    'boarding-pass': await TokenStorage.current.readToken() ?? '',
  },
  ...
)
```

> 兼容现状：保留同步的 `hiHeaders()` 函数返回当前硬编码值 — 仅在未 install 新 config 时回退。

### 4.5 `onLogoutNavigate`（替换 C5）

`LoginDao.logOut()` 末尾改为调用 `LoginSdkConfig.instance.onLogoutNavigate()` ；imooc 默认是 `() => NavigatorUtil.goToLogin()`。

### 4.6 `BackendConfig` 化为可选辅助（替换 C6）

- 保留 `BackendConfig.autoDetect({int port = 3000})` 作为**静态 helper**，宿主可调可不调。
- 新 SDK 主路径只读 `LoginSdkConfig.instance.baseUrl`；现有 `BackendConfig.host/buildUri` 内部转发到该 baseUrl，向后兼容老调用点。

## 5. 不动的部分

- `pages/login_page.dart` / `register_page.dart` / `forgot_password_page.dart`
- `widget/login_palette.dart` + `widget/login_backgrounds/*`
- `LoginConfig` 单例（只在 `init` 上加一个可选 `sdk` 参数）
- `LoginDao` 对外签名：`login` / `register` / `requestPasswordReset` / `confirmPasswordReset` / `getBoardingPass` / `getUserInfo` / `getAccountHash` / `saveAuthToken` / `logOut` / `addLoginHook` / `addLogoutHook`
- `auth_kit_flutter` 集成（`AuthDaoBridge` 内部改读 `LoginSdkConfig.baseUrl + headerProvider`）

## 6. 宿主迁移（`chatgpt_app_core/lib/app.dart`）

10 行左右：

```dart
// doInit() 内，HiCache.preInit 之后
LoginSdkConfig.install(LoginSdkConfig(
  baseUrl: BackendConfig.autoDetect(port: 3000),
  headerProvider: () async => {
    'auth-token': 'YOUR_COURSE_AUTH_TOKEN',
    'course-flag': 'fg',
    'boarding-pass': HiCache.getInstance().get('user_info') != null
        ? (jsonDecode(HiCache.getInstance().get('user_info'))['boardingPass'] ?? '')
        : '',
  },
  routes: LoginRoutes.imooc,
  responseAdapter: ImoocResponseAdapter(),
  storage: HiCacheTokenStorage(),
  onLogoutNavigate: NavigatorUtil.goToLogin,
));

await LoginConfig.instance().init(homePage: BottomNavigator());
```

如果**不**调用 `LoginSdkConfig.install(...)`，SDK 回退到 imooc 默认（保证 OHOS shell / 其他位置零改动也能跑）。

## 7. 实施步骤（执行顺序）

按依赖顺序，每步独立可编译：

1. **新增**：`lib/config/login_sdk_config.dart`（含 `LoginRoutes`、`LoginResult`、`LoginResponseAdapter` 抽象 + `ImoocResponseAdapter` 默认实现）
2. **新增**：`lib/config/token_storage.dart`（含 `TokenStorage` 接口 + `HiCacheTokenStorage` 默认实现）
3. **改造 `LoginDao`**：所有路径 / 响应解析 / 存储调用走 `LoginSdkConfig.instance`，未 install 时使用 `LoginSdkConfig._defaults()`
4. **改造 `header_util.dart`**：`hiHeaders()` 优先返回 `LoginSdkConfig.instance.headerProvider()` 的同步缓存版（首次启动用静态默认）
5. **改造 `LoginConfig.init`**：新增可选 `sdk` 参数，转发到 `LoginSdkConfig.install`
6. **改造 `BackendConfig`**：保留 API，但内部读 `LoginSdkConfig.instance.baseUrl`（如已 install）
7. **更新 README**：API 表 + 接入示例都改为新形态
8. **不**修改宿主 — 因为默认行为兼容；如需启用新配置，host 自己加一段 install 调用即可

每步完成后 `flutter analyze --no-pub` 在 `login_sdk/` 内验证通过。

## 8. 后续可选项（不在本次范围）

- 拆 3 个独立包：`login_sdk_core`（DAO + config，无 UI）/ `login_sdk_ui`（pages + palette + 背景）/ `login_sdk_imooc_adapter`（参考实现）
- `SharedPreferencesTokenStorage` / `FlutterSecureStorageTokenStorage` 备选实现
- 单元测试覆盖 `ImoocResponseAdapter` 与 `HiCacheTokenStorage`

## 9. 风险

- **`hiHeaders()` 同步签名 vs `headerProvider` 异步签名**：若强行全部异步化，所有 DAO 都要改。妥协方案是保留同步路径作为 fallback，宿主用同步常量时直接命中。
- **`BackendConfig.host` 仍被 `conversation_widget.dart` 等老代码直接读取**：转发层做得彻底就不破。
