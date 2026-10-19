# HarmonyOS 华为账号登录

2026-10-19：本地实现已接入 Account Kit 原生授权、NestJS 验码，以及现有验证码绑定和安全存储流程。当前未配置真实华为应用身份，也未部署本轮后端改动；构建与模拟测试通过不代表真实账号登录已验收。

## 使用的流程

1. 用户同意应用协议后点击「华为账号登录」。壳注入 `OhosHuaweiLoginService`，调用原生 `HuaweiLoginPlugin`。
2. `createLoginWithHuaweiIDRequest` 仅获取身份授权码，不申请手机号、头像昵称权限。每次请求生成随机 `state` 并核对响应。
3. Flutter 将一次性授权码提交到 `/uapi/auth/huawei/login`，模式为 `getAuthCode`。不把客户端返回的 UnionID/OpenID 作为认证依据。
4. NestJS 使用应用 Client ID / Client Secret 向华为兑换用户级 Access Token，再调用「解析凭证」接口。必须匹配 Client ID、`type=0`、有效期及非空 UnionID/OpenID。
5. 已绑定用户获得应用会话；首次使用则沿用 `bindTicket` → 邮箱/手机号验证码绑定 → 应用会话。会话通过现有 HUKS 存储持久化。

客户端不保存华为 Access Token、Refresh Token 或 Client Secret。服务端不缓存这些凭证，不自动重试授权码兑换。固定官方 HTTPS 端点，禁用重定向，单次请求超时 8 秒、响应上限 64 KiB；异常不包含上游响应或凭证。

原生层只允许一个未完成的授权请求。120 秒后结束 Flutter 等待；Account Kit 没有取消 `executeRequest` 的 API，因此原生请求实际返回前仍拒绝第二个请求。超时或 engine 销毁后的旧回调不会完成新登录。授权页可能使应用进入后台，不在 `onBackground` 取消账号授权。用户取消静默返回；配置、网络、账号和其他错误使用安全的用户提示。

## 联调配置

| 位置 | 配置 |
| --- | --- |
| AGC | 为 `com.hzb.flutter_ai` 配置应用与 Account Kit，确认对应的签名证书指纹。不要用项目级 Client ID。 |
| `chatgpt_flutter_ohos/ohos/entry/src/main/module.json5` | 将 `metadata` 中 `client_id.value` 的空字符串改为实际**应用 Client ID**。这是公开配置，不填 Secret。 |
| 后端环境 | 设置 `HUAWEI_CLIENT_ID`、`HUAWEI_CLIENT_SECRET`，须与客户端同一应用。兼容旧别名 `HUAWEI_APP_ID`、`HUAWEI_APP_SECRET`。 |
| 管理后台认证设置 | 开启 `huaweiGetAuthCodeEnabled`。仅开启 `huaweiQuickLoginEnabled` 不会放行授权码模式。 |
| 构建 | 使用 Flutter OH 3.35 和 `scripts/build-release.sh`；生产后端由 `deploy/flutter/production.json` 指定。 |

仓库有意保留空 Client ID；此时只在点击华为登录后提示未配置，邮箱、密码和游客入口仍可使用。不要把 Client Secret 写入 Dart define、HAP、客户端配置或 Git。

目前实现的是「华为账号登录」，不是获取手机号的「华为账号一键登录」。`IHuaweiLoginService.signInWithQuickLogin` 在 OHOS 适配器中兼容地转到授权码流程，返回的 `mode` 仍为 `getAuthCode`。后端旧 `quickLogin` Token 路由同样验证归属、类型和有效期；不在本轮增加手机号快捷注册或客户端静默登录。

## 验证边界

- 原生 TypeScript 测试执行真实插件源码，模拟 Account Kit，覆盖 state、并发、超时、取消和 engine 旧回调。
- Flutter 通道测试与登录 Widget 测试覆盖授权码传递、错误脱敏、首次绑定、直接登录和新认证替代旧请求。注入认证依赖后，现有 `LoginConfig.init` 通过 `copyWith(storage: ...)` 保留它们。
- NestJS 测试模拟华为 HTTP 响应，覆盖 form 编码、错误响应（包括 HTTP 200 的业务失败）、跨应用/应用级/过期 Token、超时、响应大小和对应开关。
- Release HAP 经 ArkTS 编译，并校验包内 AOT、QuickJS 与本次构建结果一致。
- 无真实设备 / AGC 账号授权 / 华为服务端换码证据；现有签名仍是本地调试配置。发布前需完成首次绑定、再次登录、取消、离线、未登录华为账号、错误指纹、进后台返回和重装后的真机验收。
- 本轮后端实现位于 `chatgpt_backend`（NestJS）。使用其他后端实现的部署需要单独适配和部署，不能仅替换客户端安装包。

## 官方依据

- [配置 Client ID](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/account-client-id)
- [获取用户级凭证](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/account-api-obtain-user-token)
- [解析凭证](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/account-api-get-token-info)
- 原生 API 类型经本机 HarmonyOS SDK `@hms.core.authentication.d.ts` 核对。
