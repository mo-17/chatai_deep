# Android 真机调试验收（2026-10-21）

状态：真机主流程、原生 OCR、相机拍照、系统中文朗读、中文识别及正式后端真实模型普通/流式调用通过。包含正式后端地址和全部修复的正常 APK 已覆盖安装，实际安装哈希一致，冷启动后正式账号、后端代理模式和验收会话均恢复。手机现运行正常安装入口。

> 验收源码范围：真机 APK 与原生集成测试基于当时完整的混合工作区；下文分批 Git 提交刻意排除了此前的未提交功能。仅检出本轮提交不等于得到完全相同的真机验收源码。可移植脱敏摘要见 [验收证据 JSON](android-device-debug-20261021-evidence.json)。

## 当前证据

- 设备：小米 M2102J2SC，Android 13 / API 33，arm64-v8a，ADB 状态 `device`。
- SDK：项目指定的 Flutter 3.35.7 / Dart 3.9.2。
- 主程序 debug APK 构建成功，包名 `com.example.chatgpt_flutter`，版本 `1.0.10+20`，minSdk 24 / targetSdk 35，签名验证通过。
- 首轮主程序 APK 临时保留在 `/private/tmp/chatai-main-android-debug-20261021.apk`，SHA-256：`c2f18f8752df7200ed03e112ae5d87b173efd7fd7f7eef0f5fd53be49723099c`。此包包含 OCR/数据库修复，尚未包含下文追加的语音修复。
- `android_device_smoke_test.dart` 验收包编译成功；两份新增测试文件静态分析无诊断。
- 最终真机日志为 `All tests passed!`，包含两个主测试与框架 teardown；完整修复后连续两轮通过。最后一轮约 6 秒。日志：`/private/tmp/chatai-android-device-smoke-latest-20261021.log`。
- 通过范围：离线启动、游客导航、UI 重建后本地数据恢复；中文图片、无文字层双页 PDF、页码进度、指定页、临时目录清理；单图可搜索 PDF 的文字层和可见原图经原生渲染后仍完整。
- 图片夹具输出 `中文识別测试 / ANDROID OCR 2026`；断言明确接受「别/別」，不改写产品识别结果。PDF 两页最终完整输出 `中文识别测试 / ANDROID OCR 2026`、`第二页验证 / PAGE TWO 12345`。合成夹具通过不代表任意照片的 OCR 准确率。
- 本地扫描/导出回归 10/10 通过；相关 Dart 静态分析无诊断。
- MIUI USB 安装需手机端确认，电脑代点被 `INJECT_EVENTS` 权限拦截；后续通过 `flutter attach` 热重启完成复测，未反复重装。最终正常包安装成功，临时传入手机下载目录的测试 APK 已清理。
- 安装前设备没有本项目包；未手动清除设备数据或修改系统权限设置。真机验收阶段尚未提交 Git，后续本地分批提交见文末。

## 本轮改动

移除标准 Flutter shell 全局 OCR stub 覆盖，恢复真实 ML Kit / pdfx，并为 Android 捆绑中文识别模型。保留 OHOS shell 自己的覆盖。真实 ML Kit 的 Apple Silicon iOS 模拟器链接限制仍需单独处理。

真机发现并修复两类问题：

- 横向图片的 PDF 页面默认方向会把 `1200×360` 重排成 `360×1200`，导致右侧文字被裁掉。扫描合成和单图可搜索 PDF 均按图片宽高显式设置方向；新增横页、竖页、方形页回归。
- 会话列表销毁后未完成的数据库初始化可能访问已关闭连接。每步初始化检查页面/账号，等待初始查询收尾，并忽略已失效初始化的错误；置顶列表的迟到结果也不再更新已销毁页面。

新增统一真机入口：

```bash
cd chatgpt_flutter
fvm flutter test --no-pub -d <device-id> integration_test/android_device_smoke_test.dart
```

该入口包含已有离线冷启动、游客导航、SQLite 重建恢复测试，以及新加的中文图片、无文字层双页扫描 PDF、页序/进度、指定页 OCR 和临时资源清理验收。

## 正常应用与边界

正常 `lib/main.dart` 已真实启动，FlutterSecureStorage 初始化完成，截图保存在 `/private/tmp/chatai-android-main-20261021.png`。没有观察到启动期 Dart 未捕获异常或 Android Runtime 崩溃。

测试调试器退出时 Flutter 3.35.7 工具出现一次 `Bad state: Stream has already been listened to`；这是宿主机 attach 工具异常，已重新连接正常应用，报告保留在 `/private/tmp/chatai-flutter-attach-crash-20261021.log`。

此时电脑 3000 端口未发现开发后端，应用也尚未配置真实 AI 服务凭据；模型、后端认证、相机、麦克风/蓝牙和云同步均未验收。

## 相机、语音与真实模型追加验收

用户随后授权继续测试相机、语音和真实模型，发现问题直接修复。

- 已检查当前应用状态：仍在登录页，实际应用偏好中没有 AI 服务配置。已请求用户在手机填写服务商、模型和 API key；不从聊天索取或导出密钥。
- Android 相机入口为 `com.android.camera/.OneShotCamera`；系统识别/朗读服务为小米 `com.xiaomi.mibrain.speech`（1.5.3）。初始相机与录音权限均未授予。
- `image_picker` 真实相机请求通过：用户允许相机、拍照并确认后，返回 JPEG 368,867 字节，解码尺寸 1799×2400，本机 OCR 输出 96 字符。未读取/导出照片正文，也未将照片发送给模型。
- 真实系统 TTS 已播放固定中文测试句，收到 `preparing → playing → completed`，原生日志确认 utterance started/completed。用户明确确认「听到了清晰中文」。原媒体音量为 0，测试中临时调低档后已恢复为 0。
- 真实中文识别已收到 15 字最终结果，固定测试句中的「测试」「语音」关键词匹配成功。没有导出原始录音或全文。该结果不代表蓝牙路由或任意环境的识别质量。
- 语音输入、朗读、语音会话控制回归 33/33 通过；新增首次权限等待、语言列表无回调/报错、查询期间取消、最终结果晚于结束回调及长句未发 partial 时不得提前停止的覆盖。日志：`/private/tmp/chatai-voice-regression-20261021.log`。
- 原生 TTS 日志：`/private/tmp/chatai-tts-native-20261021.log`；脱敏状态摘要：`/private/tmp/chatai-media-acceptance-20261021.json`。

新增独立 debug 入口 `chatgpt_flutter/tool/android_device_acceptance.dart`，通过经过认证的 Dart VM service 驱动真实相机/识别/朗读/ChatService；正常安装入口与用户配置保持不变。模型测试使用固定短提示词、256 输出 token 上限、45 秒取消期限和零自动重试，不发历史对话或照片。

真机语音启动发现并修复：

- 首次权限弹窗占用了原先 25 秒结果期限，用户授权后已经超时。改为系统初始化与语言查询完成后才开始计算录音结果期限。
- 固定的 `speech_to_text 7.3.0` 在 Android 13 原生语言枚举分支存在不返回结果的路径；本机表现为识别服务可用但一直没有启动录音。给可选语言查询增加 2 秒上限，超时或平台错误后使用调用方指定语言，保留取消租约检查。未修改缓存中的第三方插件，也未升级依赖。
- 不发 partial 的 Android 识别器可能先通知 `doneNoResult`，稍后才返回最终文字；插件把该状态映射为 `done`。原应用收到 `done` 立即取消，新增回归复现为预期完整句、实际空串。修复后保留 3 秒最终结果回传窗口，最终结果/错误/取消仍会立即结束，并清理等待计时器。
- 原生轨迹显示开始收音后约 2 秒就被 Dart 侧 `stop`，原因是 `pauseFor=2s` 把无 partial 误判为静音。移除此短暂停顿计时，交由系统判断语音端点，仍保留 20 秒录音与 25 秒结果上限。回归在 2.1 秒无 partial 后确认没有发出 stop，随后完整句正常返回。
- 加入只在独立 debug 入口启用的可见语音验收面板，用户可自己开始收音，避免远程操作的时序误差。界面只显示识别字数与固定测试句是否匹配。

录音权限已由手机端授予，面板测试观察到 `speechListening=true`，随后得到关键词匹配的最终结果。脱敏成功证据：`/private/tmp/chatai-speech-passed-20261021.json`；原生回调证据：`/private/tmp/chatai-speech-native-20261021.log`。临时语音诊断日志现已关闭，验收面板已关闭，手机已进入「我的 → AI 服务设置」。

此阶段最初等待手机端模型配置；用户随后选择正式后端代理并完成了下文真实普通/流式验收。

前一正常主程序候选：`/private/tmp/chatai-main-media-fixed-android-debug-20261021.apk`，SHA-256 `451b0b17c763213da75e20629a46120c503e5d1c1dda8ad0265b4cb6207ef345`，`apksigner verify` 通过。静态分析无诊断，`git diff --check` 通过。该候选随后改为使用正式后端参数重新构建；当前安装版本以下文正式后端包为准。

## 改用正式后端代理

用户明确选择后端代理。沿用仓库 `deploy/flutter/production.json` 指定的 `https://kushui.shop`，未启动替代后端、修改远端服务或导出密钥。电脑健康检查与公开登录配置为 200；手机经真实 `package:http` / 系统 TLS 访问该后端 `/healthz` 同样返回 200。

当前安装包原先按本地开发默认地址构建，调试进程已显式切换到正式 HTTPS 地址；已使用 `--dart-define-from-file=../deploy/flutter/production.json` 重建正常入口，确保更新后冷启动也保留正确地址。独立验收入口现同时支持真实本地直连与后端代理，仍拒绝用游客哨兵代替正式登录。

已通过应用「我的 → 登录 / 注册」进入正式登录页，保留游客本地数据，随后完成普通 App 账号登录。通过正常设置选择后端代理、拉取模型清单并执行短提示词的非流式/流式调用；不向聊天索取账号密码或 API key。

正式后端修复版 APK：`/private/tmp/chatai-main-backend-proxy-debug-20261021.apk`，SHA-256 `f390c88c090fd57cb31087c5bb33b4b557263ae95cb1d27dede18dc1b0decbca`，签名验证通过。正常入口 kernel 包含正式域名，不含独立验收 VM extension。

用户随后授权填写已连接的 Gmail 邮箱并通过插件取登录验证码。已在真实手机表单填写邮箱、发送一次验证码，Gmail 插件找到本次登录邮件；插件将一次性验证码隐藏为 `one-time authentication code withheld`，未尝试绕过。由用户自行在手机填码完成登录，未导出 JWT 或任何服务商密钥。

用户已完成验证码登录。已通过实际设置页选择「后端代理」并回读确认持久化为 `backend`，正式账号登录有效；手机的本地服务商均未填写 API key。

- 真机 → 正式 HTTPS 后端 → `deepseek-chat` 非流式：返回「真机模型连通测试成功。」，8,726 ms，真实 usage 为输入 16 / 输出 7 token，`estimated=false`。
- 同一路径 SSE 流式：返回同一固定句，7 个正文分片，11,111 ms，usage 为输入 16 / 输出 7 token。
- 实际聊天页新建独立验收对话，经输入框原有回车发送处理发送固定短句，页面流式显示「界面流式测试成功」，8 字，随后结束生成并恢复输入框。该测试会话保留在本机供复核。
- 脱敏调用证据：`/private/tmp/chatai-backend-nonstream-20261021.json`、`/private/tmp/chatai-backend-stream-20261021.json`。界面生成中/完成截图：`/private/tmp/chatai-backend-chat-ui-20261021.png`、`/private/tmp/chatai-backend-chat-ui-complete-20261021.png`。

本轮未修改远端服务或数据库配置；真实模型测试只发送固定短提示词，未发送相机照片或历史用户对话。

## 最终安装与重启复核

- `adb install -r -t` 返回 `Success`；此次 MIUI 没有再次弹安装确认。未清除数据。
- 手机实际 `/data/app/.../base.apk` SHA-256 与上述正式后端包完全一致：`f390c88c090fd57cb31087c5bb33b4b557263ae95cb1d27dede18dc1b0decbca`。
- 正常 `lib/main.dart` 入口启动为 `COLD`，约 2.3 秒；未观察到该进程的 Dart 未捕获异常或 Android Runtime 致命崩溃。
- 冷启动主界面保留正式登录态及验收会话（2 条消息，含「界面流式测试成功」）。通过只读 VM 调用 `AISettingsDao.load()` 与 `LoginDao.isGuest()`，确认 `mode=backend`、`guest=false`；没有读取令牌。此前源码表达式求值因无编译服务不可用，改用应用现有无参数读取方法完成核对。
- 冷启动证据：`/private/tmp/chatai-backend-main-cold-start-20261021.png`、`/private/tmp/chatai-backend-installed-cold-state-20261021.json`。调试器已 detach，保留正常应用运行。
- 蓝牙/耳机路由与扬声器全双工 AEC 未在本轮验证；系统收音、系统朗读与文本模型代理的通过不替代这些专项质量验收。
- 真机验收结束时未提交或推送 Git；本地分批整理如下，未执行推送。

## 本地 Git 分批整理

按用户要求仅提交本轮修复与验收记录，不推送。整理前分支为 `main`，HEAD 为 `f6566bae107b4198462cbdb055295ed629da3743`，暂存区为空；其他桌面、Web、服务端 OCR、知识库等既有改动保持在工作区。

- `6d15eb12`：语音权限等待、语言查询超时、最终结果宽限及原生端点修复与回归。
- `3a5bd64d`：会话列表初始化及置顶查询的页面销毁保护。
- `70526046`：Android 原生 ML Kit / pdfx 依赖恢复与中文模型。
- `75ed7913`：有界的相机、朗读、识别、真实模型及界面验收入口。
- 验收文档批次：本文、脱敏 JSON、Android 调试 README 和精确补丁归档。

### PDF 与原生集成测试的隔离边界

`document_scan.dart`、`ocr_export.dart` 与 `scan_export_test.dart` 在本轮前已存在但尚未跟踪，包含其他扫描/导出功能；本次没有把这些完整文件加入 Git。两处横页修复、两项几何回归，以及依赖它们的两份新原生测试入口保存在 [精确补丁归档](android-device-debug-20261021-patches/README.md)。这些生产文件和测试仍留在原工作区，内容未改。补丁通过临时副本反向/正向应用与修复前后 SHA-256 校验；原生测试创建补丁与原文件逐字节一致。

因此，本轮提交不声称已经整合完整扫描/导出功能，也不将原生集成测试的通过归到缺少该基线的单独提交树。后续整理扫描/导出功能时，应按补丁说明检查前置哈希并单独整合。

### 本次提交范围的验证

从整理前 HEAD 导出核心与 shell 源码，再仅叠加本轮语音、列表初始化修复：语音输入、朗读、语音会话、会话搜索、项目 DAO 五份测试合计 **63/63 通过**。测试复用了本地 sibling path 依赖与 Flutter 缓存，不能等同于全仓干净环境 CI。独立真机验收入口在该源码快照下 `dart analyze` 无诊断。上述归档补丁校验通过。

每批提交前核对明确路径清单与暂存内容，`git diff --cached --check`、暂存区 Gitleaks 和仓库提交钩子均通过。没有改动忽略规则，没有把 APK、截图、原始录音、照片正文、邮箱、验证码、JWT 或 API key 加入提交。原有 stash 与其他源码内容按整理前哈希复核保留。
