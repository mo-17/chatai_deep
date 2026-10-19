# Flutter 连接正式后端

当前源码及本地 Android 候选包为 **1.0.10+20**，增加知识助手 V2、资料管理、Word/PDF 成果导出、资料语音问答、知识同步与备份、语音分句播放/耳机打断、团队知识库。187 项 Flutter 定向测试及 Android/iOS 模拟器构建通过；使用现有 debug 签名，尚未发布、未完成真机和真实模型质量验收。本轮没有改变线上文件或版本推送策略，团队后端及数据库迁移也尚未部署。见 [P1/P2 实施与使用记录](../../docs/p1-p2-knowledge-workbench.md)；历史说明见 [可信知识助手](../../docs/trusted-knowledge-assistant.md)、[连续语音说明](../../docs/continuous-voice.md)、[试用与运行监控](../../docs/trial-operations.md)。下文 +14 内容保留为首次迁移历史。

生产后端为 `https://kushui.shop`。公共配置文件 `production.json` 同时设置 `BACKEND_HOST=kushui.shop` 与 `BACKEND_HTTPS=true`；host 不包含 scheme、端口或 `/uapi`。Cloudflare Free 严格回源原共享 IP 的 10084，客户端使用标准 443。旧 +13 安装包需升级 +14。

## 启动与构建

在仓库根目录执行：

```bash
# 查看设备（在 Flutter 壳目录中使用项目固定的 FVM SDK）
cd chatgpt_flutter
fvm flutter devices
cd ..

# 启动指定设备：连接的手机或已启动的模拟器 ID
bash deploy/flutter/production.sh run -d <设备ID>

# Android 安装包
bash deploy/flutter/production.sh build apk --release

# iOS 模拟器构建
bash deploy/flutter/production.sh build ios --simulator --debug
```

VS Code 的首个启动配置为 `Flutter: Production (kushui.shop HTTPS)`，profile 配置共用同一 JSON 文件。原有本地开发配置保留；不带生产参数的普通 `fvm flutter run` 继续使用 SDK 的本地开发默认地址。

HarmonyOS 沿用显式配置和公网 HTTPS 检查，可在激活工具链后使用同一个配置文件：

```bash
cd chatgpt_flutter_ohos
eval "$(mise activate bash --shims)"
flutter build hap --dart-define-from-file=../deploy/flutter/production.json
```

Android release 当前仍使用项目原有的 debug 签名，正式发布商店前须配置发布签名。iOS 真机签名、Android/iOS 真机网络及 HarmonyOS 均需在对应设备单独验收。

## 登录与鉴权

客户端邮箱密码登录走 `/uapi/auth/login/password`，登录后公共 `hiHeaders()` 同时发送标准 `Authorization: Bearer <JWT>` 和兼容旧接口的 `boarding-pass`。游客哨兵不作为 Bearer JWT 发送；账号切换时当前账号的 JWT 覆盖宿主缓存的旧认证头。

App 邮箱账号与管理后台的 `admin` 用户名登录是两种入口。SMTP 尚未配置时，不能据密码登录通过就认为邮箱验证码、找回密码或新用户注册已经可用；模型推理还需要配置真实服务商 Key。

`login_sdk/test/production_backend_live_test.dart` 是显式启用的公网验收，使用真实 Flutter AuthDao、TokenStorage 接口和公共请求头。它先校验编译地址，再读取仓库外的 `0600` 临时凭据文件，通过系统信任库校验 TLS，覆盖公开配置、未登录 401、邮箱密码登录、登录态与请求头、受保护模型清单、普通用户访问管理接口 403、清除登录态后 401。常规测试默认跳过这个用例，不会自行连接生产环境。

```bash
cd chatgpt_flutter
CHATAI_LIVE_CREDENTIALS=/受控临时目录/qa.json \
  fvm flutter test ../login_sdk/test/production_backend_live_test.dart \
  --dart-define-from-file=../deploy/flutter/production.json --no-pub
```

临时文件字段为 `baseUrl`、`email`、`password`，只用于独立的测试账号。禁止使用后台管理员密码、将密码放入 dart-define、提交凭据或打印完整登录响应；验收后删除测试账号与临时文件。

## Cloudflare 标准 HTTPS（2026-10-19）

Android +14 已构建，签名、联网权限、minSdk 和 arm64 AOT 新地址检查通过，大小 304711027 字节，SHA-256 `dab2cd02005852db06550f9e004b4f8b2f019f5624bd6d7b8a7f063a468c0363`。服务器侧普通用户邮箱密码登录、受保护目录、普通用户管理接口 403、删除 QA 用户后 JWT 401 等 5 项通过；临时账号和凭据已清理。

2026-10-19 05:34（北京时间）正常缓存更新后，从 `chatgpt_flutter/` 使用上述命令（另加 `--reporter expanded`）执行真实 Flutter 公网测试，**1 个集成用例通过，All tests passed**。覆盖系统信任库 TLS、公开配置、未登录 401、AuthDao 邮箱密码登录、令牌存储及请求头、受保护模型清单、普通用户管理接口 403、清除登录态后 401；没有强制 IP、关闭证书校验或修改系统 DNS/代理。专用测试用户及两端 0600 临时凭据已清理。

Mac 官网 53/53 与 Chrome 标准 HTTPS 官网、管理员登录/仪表盘/退出鉴权也已通过，自动任务 `kushui-shop-https` 已设为 PAUSED。本次是 Flutter 网络集成验收，没有 Android 真机或新地址原生界面验收，也没有验证真实模型推理/SMTP。

## 历史带端口验收（2026-10-19，迁移前）

- `login_sdk` 测试共 92 项通过，1 项公网测试按默认条件跳过；另用临时普通用户显式执行公网验收及相关回归，16 项通过（与前述测试有重叠，不累计）。改动涉及的 Dart 文件静态分析无问题。
- iOS 18.3 模拟器使用生产 JSON 构建，原生界面勾选协议后邮箱密码登录成功；关闭应用再打开，登录态恢复成功；退出登录后回到登录页。服务端对应登录和受保护模型清单请求均返回 200。
- 已通过 API 验证未登录请求返回 401、普通用户访问管理员接口返回 403。未绕过证书校验。临时测试账号及 Mac、服务器上的临时凭据均已删除，模拟器也已退出登录。
- Android `1.0.4+13` APK 已构建，签名校验通过，包含 `INTERNET` 权限；实际 arm64 AOT 产物包含 `kushui.shop:10084`。未连接 Android 真机，尚未进行真机安装与登录验收。

当前 Android 安装包位于 `chatgpt_flutter/build/app/outputs/flutter-apk/app-release.apk`，版本 1.0.9+19（未发布通用候选包）；仍为历史 `Android Debug` 签名。商店发布前按 [签名说明](../../docs/android-release-signing.md) 配置正式签名。首个 release 构建不要用 `--no-pub` 跳过插件注册更新。

macOS 调试构建完成，但本机独立启动被系统签名检查阻止：现有 ad-hoc 签名包含受限 Keychain entitlement，且本机没有可用的 Apple Development / Developer ID 签名身份。本次没有修改 Keychain、沙盒或凭据存储策略；macOS 界面验收尚未通过，需要先补齐签名及 provisioning。插件对该要求的说明见 [flutter_secure_storage 官方仓库](https://github.com/juliansteenbakker/flutter_secure_storage)。iOS 模拟器的通过结果不替代 macOS、手机真机或 HarmonyOS 验收。

## 官网与访问方式

官网已切换到 [https://kushui.shop/](https://kushui.shop/)，提供产品介绍与 Android +16 分架构体验包下载。后台使用 [登录页](https://kushui.shop/login)，API 使用 `/uapi/*`。客户端生产 JSON 已同步新地址，旧 `:10084` 地址不能通过 Cloudflare 边缘使用。新地址的服务器侧回归、Mac Chrome 官网与后台、真实 Flutter 登录集成测试均通过。当前官网尚不提供正式协议文档。

接口地址会出现在客户端中。实际访问控制依赖 HTTPS、登录令牌、角色鉴权与限流；管理后台还可以按实际运维需要限制访问来源。官网发布和恢复见 [WEBSITE.md](../ubuntu/WEBSITE.md)，服务器端口映射、证书续期与运维说明见 [SERVER.md](../ubuntu/SERVER.md)。

### P0/P1 发布迭代

当前客户端 `1.0.6+16` 增加官方试用与用量、意见反馈、断点下载和按需离线语音。按架构发布、灰度与暂停推送步骤见 [交付与验收](../../docs/p0-p1-delivery.md)。真机验收前保留测试签名体验包标识，自动推送默认 0%；`+15` 对旧客户端的全量更新仍保留。

构建命令：`bash deploy/flutter/build-release.sh 15 '<说明>' /tmp/chatai-client-release16`。此脚本会核对历史签名和每个包的真实版本码，不使用 Flutter 自动增加 ABI 版本码的方式发布。

最终验收：官网 53/53、官方试用实际回复/扣减 10/10、指定 Gmail 注册/验证码登录/找回密码 15/15；Flutter 公网登录、双客户端同步、离线模型整包下载/安装和 ARM64 断点续传通过。试用与 SMTP 均已开启，临时账号及凭据已删除。客户端通过「我的 → 官方试用与用量」开始使用；未完成 Android 真机界面、覆盖安装和语音播放验收，故 +16 自动推送保持 0%。
