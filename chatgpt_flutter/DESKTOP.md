# 艾普桌面端（macOS / Windows）

桌面版使用 `chatgpt_flutter` 壳层和现有 `chatgpt_app_core`，沿用聊天、助手、知识库、创作、任务、备份与同步的业务实现。无需另起一套前后端。

## 当前适配

- macOS 和 Windows：默认 1280×800，最小窗口 800×600。
- 主页宽度达到 840 时使用侧边导航；窄窗口保留底部导航。
- 会话宽度达到 1100 时，左侧 380 为会话列表，右侧为聊天。点击其他会话替换详情路由，返回回到主页；窗口缩放保留当前详情状态。
- `Cmd+1…4`（macOS）/ `Ctrl+1…4`（Windows）切换主页栏目。
- 聊天输入支持最多五行，Enter 发送，Shift+Enter 换行；输入法组词期间不发送。
- macOS 允许用户选择文件进行读写，保留系统麦克风、语音识别及 Keychain 凭据存储。
- Windows x64 自动把锁定依赖内的 `sqlite3.dll` 放到发布目录。新数据库放用户应用数据目录，检测到旧工作目录中的同名数据库时继续沿用，不自动搬动数据。

## 本地运行

当前随附的 `libonnxruntime.1.24.4.dylib` 声明最低 macOS 15.5，已将应用部署目标同步到 **macOS 15.5+**。如需支持更旧的 macOS，需先替换并验证相容的语音原生运行库；仅修改部署目标不会使该二进制兼容旧系统。

使用 Flutter **3.35.7**，与现有 CI 一致。以下命令从 `chatgpt_flutter` 执行：

macOS 首次运行还需用 Xcode 打开 `macos/Runner.xcworkspace`，在 Runner 的 Signing & Capabilities 中选择自己的开发团队，并确保 Keychain Sharing / Speech Recognition 所需 entitlement 有有效签名及描述文件授权。当前工程的 ad-hoc 签名可以通过编译和磁盘签名校验，但在这台 Mac 上启动被系统以 `Code has restricted entitlements` 拒绝；本机检测到 **0 个有效代码签名 identity**。这里保留安全存储和系统权限，不通过移除 entitlement 或降低安全存储来绕过启动检查。

签名授权机制参见 [Apple Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)，Keychain 配置参见 [flutter_secure_storage 官方说明](https://github.com/juliansteenbakker/flutter_secure_storage)。

```sh
flutter pub get --enforce-lockfile --no-example
flutter run -d macos
```

在 Windows 主机上（安装 Visual Studio 的 Desktop development with C++ 组件）：

```powershell
flutter pub get --enforce-lockfile --no-example
flutter run -d windows
flutter build windows --release --no-pub
```

必须分发整个 `build/windows/x64/runner/Release/`，包括 `data/`、Flutter、SQLite 和插件 DLL，不能只发送 `.exe`。当前打包固定 Windows x64，不声明 Windows ARM64 原生支持。

macOS 发布构建：

```sh
flutter build macos --release --no-pub
```

产物为 `build/macos/Build/Products/Release/chatgpt_flutter.app`。对外分发仍需配置 Apple Developer 签名与公证，Windows 安装器及代码签名另行配置。

桌面登录默认访问本机 `localhost:3000`。连接已部署的后台时，在上述运行/构建命令追加真实地址：

```sh
--dart-define=BACKEND_HOST=实际后端域名 --dart-define=BACKEND_HTTPS=true
```

游客模式可进入本地功能；对话仍需在 AI 服务设置里配置服务商和模型。账号凭据与 API key 使用壳层的系统安全存储。

## 验证及能力边界

`.github/workflows/desktop.yml` 提供 macOS / Windows 独立 runner 构建，支持手动触发和相关 PR 检查。上传的 macOS 压缩包是尚需开发者签名的编译产物，不能视为可直接分发运行的版本。增加工作流文件不代表远程构建已经执行。

```sh
cd chatgpt_app_core
flutter test --no-pub test/desktop_layout_test.dart test/desktop_message_input_test.dart test/desktop_database_path_test.dart test/app_bottom_navigation_bar_test.dart
```

现有文本 PDF、Word、Excel 提取可复用；端上 OCR 仍只在移动平台启用，macOS 的技能 JS 执行仍由现有安全能力判断禁用。系统语音、离线语音资源、真实模型/MCP、双设备同步、后台持续运行需各自在目标系统验收；移动端后台任务许可不等于桌面常驻能力。

自动化布局测试覆盖两套桌面目标的导航、缩放、详情状态保留、输入快捷键和中文组词保护，并检查宽屏 Android 仍使用移动导航。实际 Windows 编译和运行以 Windows runner/实机结果为准，macOS 的编译成功也不替代上述服务验收。

本次本机验证（2026-10-20）：相关 Flutter 回归 **48/48 通过**，修改文件的 Dart 静态检查通过，macOS Debug / Release 编译通过。Release 产物为 `chatgpt_flutter/build/macos/Build/Products/Release/chatgpt_flutter.app`（140.3 MB，Intel x86_64 + Apple Silicon arm64 通用二进制），磁盘签名校验通过，最低系统版本为 15.5。GUI 启动受上述签名条件阻断，Windows 未在本机编译/运行，双平台远程 CI 尚未执行。

全核心 `flutter analyze --no-pub` 另有 6 处非本次修改文件的问题（5 条 info、1 条 unused import warning），位于 `knowledge_import_operation_test.dart`、`ohos_storage_test.dart`、`production_sync_live_test.dart` 和 `team_knowledge_test.dart`；本次没有改动这些文件。

## OCR 快捷助手（2026-10-20）

已增加「我的 → 桌面快捷助手」：可选全局快捷键、菜单栏/托盘和框选截图。Ctrl+Shift+Space 显示/隐藏，Ctrl+Shift+O 截图，ESC/失焦取消；截图先进入 OCR 待处理任务，确认后才上传。快捷键注册失败会回退为关闭状态。

新代码 macOS Release 编译通过；GUI 仍受上文签名条件阻断。Windows 原生实现已加入构建与 CI，但当前没有 Windows 编译或运行证据。完整功能、测试和外部验收边界见 [OCR 工作台说明](../docs/ocr-workbench.md)。
