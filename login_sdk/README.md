# login_sdk

ChatGPT Flutter 客户端的登录 / 注册 / 忘记密码 SDK。封装：

- 三个独立页面（`LoginPage` / `RegisterPage` / `ForgotPasswordPage`），各自支持「简洁 tabs」与「沉浸式 bg + 玻璃卡片」两种样式
- 20 个可切换的登录背景（Plan G+，`LoginBgVariant` 枚举）
- 一套与背景联动的配色 `LoginPalette`（三个页面共享，保证视觉一致）
- 与 `chatgpt_backend` 的 `/uapi/user/*` 路由对接的 `LoginDao`
- 通过 `auth_kit_flutter` 实现的多通道认证（邮箱密码 / 邮箱验证码 / 手机号 / 第三方），代码桥接见 `AuthDaoBridge`
- 后端主机自动检测 + `--dart-define` 覆盖（`BackendConfig`）
- 跨包共享的认证请求头工具 `hiHeaders()`

依赖 `auth_kit_flutter`（同仓库 sibling package）。

## 目录结构

```
lib/
├── login_sdk.dart           # LoginConfig.init — 暴露 homePage、预热 HiCache、可选 install LoginSdkConfig
├── config/
│   ├── login_sdk_config.dart   # LoginSdkConfig + LoginRoutes + LoginResult + 响应适配器
│   └── token_storage.dart      # TokenStorage 抽象 + HiCacheTokenStorage 默认实现
├── pages/
│   ├── login_page.dart      # LoginPage / LoginPageStyle.{tabs,bg}
│   ├── register_page.dart   # RegisterPage / RegisterPageStyle.{tabs,bg}
│   └── forgot_password_page.dart  # 3 步流程：验证身份 → 设置新密码 → 完成
├── dao/
│   ├── login_dao.dart       # login / register / forgot-password + 钩子（走 LoginSdkConfig）
│   ├── auth_dao.dart        # AuthDaoBridge — 预配置的 auth_kit AuthApiClient
│   ├── public_config_dao.dart  # PublicConfigLoader（HiCache 缓存 + 30min TTL）
│   ├── backend_host.dart    # BackendConfig — host / scheme / buildUri（优先级链）
│   └── header_util.dart     # hiHeaders() — 跨 DAO 复用的认证头
├── widget/
│   ├── login_palette.dart   # 与背景联动的配色（heroText / cardBg / submitBg ...）
│   ├── login_widget.dart    # 老版 LoginInput / LoginButton（仍被引用）
│   ├── input_widget.dart    # 老版输入组件
│   └── login_backgrounds/
│       ├── login_background.dart   # LoginBgVariant 枚举 + LoginBackgroundMeta
│       └── *_painter.dart / botanical_bg.dart  # 20 个 painter
└── util/                    # navigator_util, padding_extension 等
```

## 接入步骤（host app）

### 1. 添加依赖

```yaml
# host app 的 pubspec.yaml
dependencies:
  login_sdk:
    path: ../login_sdk
```

`auth_kit_flutter` 会被 `login_sdk` 传递引入，**不需要**在 host 的 pubspec 里再声明（但 sibling 目录必须存在）。

### 2. 初始化

在 `main()`（或 `runChatGptApp()`）里、首屏渲染前调用：

```dart
await LoginConfig.instance().init(homePage: BottomNavigator());
```

`init` 内部会 `await HiCache.preInit()`，所以登录态读写在此之后才是安全的。

**对接非 imooc 后端时**，传入 `sdk:` 参数注入通用配置（路由 / 响应解析 / 存储 / 登出导航）。不传则回退到 imooc 默认（与现状一致）：

```dart
await LoginConfig.instance().init(
  homePage: BottomNavigator(),
  sdk: LoginSdkConfig(
    baseUrl: 'api.your-domain.com',
    useHttps: true,
    headerProvider: () async => {'X-API-Key': '<your key>'},
    syncHeaders: () => {'X-API-Key': '<your key>'},
    routes: LoginRoutes(
      login: '/v1/auth/login',
      register: '/v1/auth/register',
      forgotPasswordRequest: '/v1/auth/forgot/request',
      forgotPasswordConfirm: '/v1/auth/forgot/confirm',
    ),
    responseAdapter: YourResponseAdapter(),  // 实现 parseLogin + checkOk
    storage: HiCacheTokenStorage(),          // 或自行实现 TokenStorage
    onLogoutNavigate: () => Navigator.of(rootCtx).pushReplacementNamed('/login'),
  ),
);
```

详见 [REFACTOR_GENERIC_SDK.md](./REFACTOR_GENERIC_SDK.md) 的设计说明。

### 3. 根据登录态选择首屏

```dart
final hasToken = LoginDao.getBoardingPass() != null;
runApp(MaterialApp(home: hasToken ? BottomNavigator() : LoginPage()));
```

### 4. （可选）注册登录 / 登出钩子

`LoginDao` 暴露两个钩子点，host app 在 init 阶段挂上即可，登录 / 登出时自动触发：

```dart
LoginDao.addLoginHook(() => AISettingsProvider.instance.reload());
LoginDao.addLogoutHook(() => AISettingsProvider.instance.resetIfConfigured());
```

钩子在 `_saveUserInfo` 之后、`logOut` 触发跳登录前调用 — 适合做"清账号级缓存 / 重新拉用户级配置"这类事。

## 公开 API 速查

### `LoginConfig`
- `instance()` — 单例
- `init({required Widget homePage})` — 全局初始化，必须在使用任何 `LoginDao` 方法前完成

### `LoginDao`（全部为静态方法）
| 方法 | 用途 |
|---|---|
| `login({userName, password})` | 旧密码登录；多个请求并发时仅最后一次认证意图可落盘 |
| `register({userName, password})` | 注册成功后自动登录；与 `login` 共用 last-attempt-wins 保护 |
| `requestPasswordReset(userName)` | 忘记密码 第 1 步：让后端发 reset code |
| `confirmPasswordReset(userName, code, newPassword)` | 忘记密码 第 2 步：用 code 重置密码 |
| `beginAuthAttempt()` | 在发起网络认证前创建不可伪造、仅可消费一次的认证句柄 |
| `saveAuthTokenForAttempt(token, {required attempt, ...})` | 仅在句柄仍代表最新认证意图时写入网络响应 |
| `saveAuthToken(token, {userName, avatar, imoocId})` | 宿主可信账号切换的兼容 API；会使待处理网络句柄失效 |
| `getBoardingPass()` → `String?` | 当前 token（用于 `hiHeaders`） |
| `getUserInfo()` → `Map?` | 包含 boardingPass / userName / avatar / imoocId / accountHash |
| `getAccountHash()` → `String?` | 多账号数据隔离用的稳定 hash（基于 userName.hashCode） |
| `logOut()` | 触发 logout hooks → 清缓存 → `NavigatorUtil.goToLogin()` |
| `addLoginHook(cb)` / `addLogoutHook(cb)` | 见上文 |

网络认证响应必须成对使用 attempt API：

```dart
final attempt = LoginDao.beginAuthAttempt();
final result = await authApi.login(...);
await LoginDao.saveAuthTokenForAttempt(
  result.token,
  attempt: attempt,
  userName: result.userName,
);
```

当期间发生更新的登录/注册、游客登录、可信 `saveAuthToken` 或 `logOut` 时，
旧响应会抛出 `LoginAccountChangedException`，不会写回旧账号，也不会触发登录
hook。`saveAuthToken` 保留原签名和行为，供宿主已确认的本地账号切换流程使用，
不要直接用于不受信任的网络响应。SDK 内置的密码/验证码/Apple/Huawei 登录和
注册，以及 `LoginDao.login` / `register`，均已使用 last-attempt-wins 保护。

### `BackendConfig`（`dao/backend_host.dart`）

后端 host 单一信源。所有 DAO 都该走 `BackendConfig.buildUri(path)`，避免散落 `Uri.http/https` 导致线上无法切换。

**取值优先级（高 → 低）**：
1. 显式 setter：`BackendConfig.host = '...'`
2. 编译期：`--dart-define=BACKEND_HOST=...`
3. 通过 `LoginSdkConfig.install(...)` 注入的 `baseUrl`
4. 自动检测：Android emulator → `10.0.2.2:3000`，其余 → `localhost:3000`

```dart
// 真机连本机后端：
flutter run --dart-define=BACKEND_HOST=192.168.x.x:3000
// 生产环境：
flutter run --dart-define=BACKEND_HOST=api.example.com --dart-define=BACKEND_HTTPS=true

// 或在 main() 里直接赋值：
BackendConfig.host = '192.168.31.167:3000';
BackendConfig.useHttps = false;

// 或作为 LoginSdkConfig 的 helper：
LoginSdkConfig(baseUrl: BackendConfig.autoDetect(port: 3000), ...)
```

### `hiHeaders()`（`dao/header_util.dart`）

返回三件套：`auth-token`、`course-flag`、`boarding-pass`。任何打后端的 DAO 都该 spread 进自己的 headers：

```dart
final headers = {...hiHeaders(), 'Content-Type': 'application/json'};
```

### `AuthDaoBridge` / `PublicConfigLoader`

```dart
// auth_kit_flutter 的 AuthApiClient 已预配好 baseUrl + hiHeaders
final dao = AuthDaoBridge.instance;
await dao.sendCode(...);

// 拉取公共配置（华为快登 / Apple SignIn 开关 / 国家码列表），HiCache 缓存 30 分钟
final config = await PublicConfigLoader.load();
```

## 页面样式与背景

三个页面都接受 `style` 与 `bgVariant` 两个可选参数：

```dart
LoginPage(
  style: LoginPageStyle.bg,                // 默认 tabs
  bgVariant: LoginBgVariant.aurora,        // 默认 mesh
  onLoginSuccess: () => Navigator.of(context).pushReplacement(...),
)
```

`LoginPageStyle` / `RegisterPageStyle` / `ForgotPageStyle` 都是 `{ tabs, bg }`：

- **tabs**：白底简洁，邮箱 / 手机 / 第三方分页签切换
- **bg**：全屏沉浸背景 + 玻璃模糊卡片（卡片配色随背景自动切换）

### `LoginBgVariant`（20 种）

| 类别 | variants |
|---|---|
| 抽象色彩 | `mesh` · `aurora` · `liquid` · `ribbon` · `wave` · `sunset` · `retrowave` · `duotone` |
| 几何 / 线条 | `blueprint` · `topo` · `dotmap` · `band` · `origami` · `aperture` |
| 自然 | `botanical` · `marble` · `paper` |
| 城市 / 数字 | `citylight` · `photo` · `matrix` |

`LoginBackgroundMeta` 的三个标志位决定 chrome 行为：
- `isDarkBg` — 深色背景 → 文字走白色 + 半透明 overlay
- `isPaper` — 纸 / 大理石 → 暖棕配色 + 米白卡面（warm-sepia palette）
- `isSolidCard` — 仅 `paper` 为 true：跳过 `BackdropFilter`（印刷纸上的玻璃感会很怪），`marble` 仍用玻璃

新增背景：在 `widget/login_backgrounds/` 加一个 `*_painter.dart`，在 `LoginBgVariant` 加枚举值，在 `loginBackgroundFor` switch 里挂上 painter，必要时设置 `isDarkBg` / `isPaper` / `isSolidCard`。无需改三个页面 — `LoginPalette` 会自动消费这三个标志位。

## 与后端的契约

`login_sdk` 假设后端是同仓库的 `chatgpt_backend`：

| 路由 | 方法 | 说明 |
|---|---|---|
| `/uapi/user/login` | POST | body: `{userName, password}` |
| `/uapi/user/registration` | POST | body: `{userName, password}` |
| `/uapi/user/forgot-password/request` | POST | body: `{userName}` → 发送 reset code |
| `/uapi/user/forgot-password/confirm` | POST | body: `{userName, code, newPassword}` |
| `/uapi/user/register-page` | GET | 后端渲染的网页注册表单（`url_launcher` 打开） |

多通道认证（验证码 / 手机号 / 第三方）走 `auth_kit_flutter` → `@auth-kit` 后端包，路由前缀通常为 `/uapi/auth/...`，具体见 `auth_kit_flutter` 自身的接入文档。

## 约定 / 注意事项

- **DAO 不要直接拼 URL**，统一走 `BackendConfig.buildUri()`，便于环境切换。
- **新建账号级数据表**时用 `LoginDao.getAccountHash()` 作 db filename 后缀，防止多账号数据串。未登录态 `getAccountHash()` 为 `null`，调用方一般会兜底成 `"test"`。
- **`login_widget.dart` / `input_widget.dart`** 是 G+ 之前的老组件，新页面已不依赖；为兼容性保留，但新增 UI 请基于 `LoginPalette` 自行组合。
- 注释以**中文**为主，与其他 sibling 包风格一致。
