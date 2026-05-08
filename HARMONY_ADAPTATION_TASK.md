# chatgpt_flutter 鸿蒙适配任务（独立工程 + 共享 core 方案）

> 交付目标：**不修改现有 `chatgpt_flutter` 在 Android/iOS 上的运行表现**，通过抽取共享业务 package + 新建一个独立的鸿蒙 app shell，让应用同时支持 Android / iOS / HarmonyOS NEXT 三端。
>
> 执行者：DeepSeek V4 Pro。本任务包含**结构性重构**（抽取 core 包），动作大但收益清晰。请按章节顺序推进，每节做完勾选"验收标准"再进入下一节。

---

## 0. 名词与版本基线

- **HarmonyOS NEXT**：纯鸿蒙内核，不再兼容 Android APK。本任务以 NEXT 为主目标，最低 API 12（OpenHarmony 5.0）。
- **Flutter for OpenHarmony**：OpenHarmony SIG 维护的 Flutter fork（`https://gitee.com/openharmony-sig/flutter_flutter`），平台标识 `ohos`。**官方 Flutter 不支持鸿蒙，必须用此 fork**。版本通常落后官方 6–12 个月——这正是不能让 `chatgpt_flutter` 直接依赖它的原因。
- **两套 Flutter SDK 共存**：官方 SDK 给 Android/iOS 工程用；OpenHarmony fork 给鸿蒙工程用。**通过 FVM 按工程钉版本**，每个工程根放 `.fvmrc`，命令统一写 `fvm flutter ...`，无需手动切换。
  - 鸿蒙 SDK 已就位：`/Users/huangzhibin/fvm/versions/flutter-oh-3.41.9-dev`（自定义 fork，FVM 不会从 release 列表里识别它，用 `--force` 接入即可）。
  - 官方 SDK：本任务统一用 FVM 管的稳定版（如 `fvm install stable`），与鸿蒙 fork 同样通过 `.fvmrc` 钉。
- **DevEco Studio 5.0.5**：鸿蒙原生层 IDE，用于打开 `ohos/` 子工程、签名、跑真机。
- **共享 core 包**：本任务新增 `chatgpt_app_core/` 包，承载原 `chatgpt_flutter/lib/` 全部业务代码；`chatgpt_flutter`（Android/iOS shell）和 `chatgpt_flutter_ohos`（鸿蒙 shell）都依赖它。

---

## 1. 目标架构

重构后 monorepo 结构：

```
chatai_deep/
├── chatgpt_app_core/           # ★ 新增：共享业务代码（pages/db/dao/provider/widget/util/assets）
│   ├── lib/
│   │   ├── chatgpt_app_core.dart       # barrel export，对外只暴露 runChatGptApp()
│   │   ├── app.dart                    # MyApp + doInit() + 路由
│   │   ├── pages/ db/ dao/ provider/ widget/ util/
│   ├── assets/                         # 从 chatgpt_flutter/assets/ 整体迁入
│   └── pubspec.yaml                    # 从 chatgpt_flutter/pubspec.yaml 迁入业务依赖
├── chatgpt_flutter/            # Android/iOS app shell（瘦身：只剩 main.dart + 原生壳）
│   ├── lib/main.dart                   # 仅 import 'package:chatgpt_app_core/...' 调用 runChatGptApp()
│   ├── android/  ios/  macos/  linux/  windows/
│   └── pubspec.yaml                    # 只依赖 chatgpt_app_core；保留 flutter_splash_screen 之类原生开屏
├── chatgpt_flutter_ohos/       # ★ 新增：鸿蒙 app shell
│   ├── lib/main.dart                   # 同样调用 runChatGptApp()
│   ├── ohos/                           # flutter_ohos create 生成
│   └── pubspec.yaml                    # 依赖 chatgpt_app_core + 鸿蒙端 dependency_overrides
├── login_sdk/  hi_download/  chat_message/  openai_flutter/   # 维持不变
└── chatgpt_backend/            # 维持不变
```

**关键收益**：

- `dependency_overrides`（鸿蒙桥接 sqflite / path_provider / url_launcher 等）**只写在 `chatgpt_flutter_ohos/pubspec.yaml`**——`pub` 只在 root 工程读取 overrides，所以对 Android/iOS app shell 完全不生效，**它们用的还是 pub.dev 上的官方包，零污染**。
- 两个 shell 可以钉不同的 Flutter SDK（官方 vs OpenHarmony fork），互不掣肘。
- 新功能写在 `chatgpt_app_core/`，三端同步获得。

---

## 2. 现状盘点（不要改代码，先核对）

### 2.1 `chatgpt_flutter/lib/` 中要迁入 core 的内容

```
chatgpt_flutter/lib/
├── main.dart                  # 拆：doInit + MyApp 进 core/app.dart；剩下 main() 只调 runChatGptApp()
├── db/                        # → core
├── dao/                       # → core
├── pages/                     # → core
├── provider/                  # → core
├── widget/                    # → core
└── util/                      # → core
```

`chatgpt_flutter/assets/images/`、`chatgpt_flutter/assets/lottie/` 全部迁入 `chatgpt_app_core/assets/`。

### 2.2 平台分支位置（适配时要处理）

- `chatgpt_flutter/lib/db/hi_db_manager.dart:39` — `Platform.isWindows` 走 ffi。**鸿蒙保持默认 `openDatabase()` 路径**，由 §6.1 的 sqflite ohos 实现接管。
- `chatgpt_flutter/lib/pages/my_page.dart:135` — `if (!Platform.isAndroid)` 拦截升级入口。**保留拦截，新增鸿蒙友好提示**（见 §7.2）。
- `chatgpt_flutter/lib/widget/message_input_widget.dart:41` — iOS 17.0–17.4 模拟器规避，与鸿蒙无关，**不要动**。

### 2.3 依赖清单（迁入 core 后，鸿蒙 shell 处理策略）

来自现 `chatgpt_flutter/pubspec.yaml`：

| 依赖 | 鸿蒙处理 |
|---|---|
| `sqflite` ^2.4.2+1 | 鸿蒙 shell `dependency_overrides` 替换为 OpenHarmony SIG 桥接版（§6.1） |
| `sqflite_common_ffi` ^2.4.0+3 | 鸿蒙不走 Windows 分支，无需特殊处理 |
| `flutter_hi_cache` ^0.0.1 | 阅读源码确认是否纯 Dart；若有原生通道在鸿蒙 shell override |
| `provider` ^6.1.5+1 | 纯 Dart，OK |
| `url_launcher` ^6.3.2 | 鸿蒙 shell override |
| `http` ^1.6.0 | 纯 Dart，OK |
| `cached_network_image` ^3.4.1 | 间接依赖 sqflite/path_provider，§6.1/§6.2 替换后即可工作 |
| `lottie` ^3.3.3 | 纯 Dart，OK |
| `flutter_splash_screen` ^4.0.0 | **保留在 Android/iOS shell**；鸿蒙 shell 用纯 Flutter 自绘 splash（§6.5） |
| `package_info_plus` ^10.1.0 | 鸿蒙 shell override 或运行时兜底（§6.4） |
| `open_filex` ^4.7.0 | 鸿蒙端不调用，依赖保留 |
| `speech_to_text` ^7.0.0 | 鸿蒙端禁用入口（§7.3）；若 ohos `pub get` 报错见 §11 风险 |
| path 依赖 `login_sdk / hi_download / chat_message / openai_flutter` | 各自补 `ohos/` 平台目录 |

### 2.4 资产路径影响

迁入 core 后，所有 `Image.asset('assets/images/xxx.png')` 调用都要加 `package: 'chatgpt_app_core'`。Lottie 同理：`Lottie.asset('assets/lottie/xxx.json', package: 'chatgpt_app_core')`。这是 Flutter 包资源访问的硬性规则，**不能省**，否则真机找不到资源。

### 2.5 后端 host

`BackendConst.host = localhost:3000` 写死在 `login_sdk/`。鸿蒙真机连不到 Mac 的 `localhost`，需改成 `String.fromEnvironment` + `--dart-define`（§7.4）。这一改对 Android/iOS 也只是默认值不变，无副作用。

---

## 3. 准备工作

### 3.1 用 FVM 管理两套 Flutter SDK

鸿蒙 fork 已经放好：`/Users/huangzhibin/fvm/versions/flutter-oh-3.41.9-dev`。

官方版用本机已有的 **3.41.6**（Android/iOS shell 与 core 包都用它解析）。

> **为何选 3.41.6**：`chatgpt_app_core` 会被两套 SDK 各解析一次（官方 + OHOS fork）。本机鸿蒙 fork 是 `flutter-oh-3.41.9-dev`，与官方 3.41.6 同代（Dart 3.11 一带），core 用 3.41.6 双端都能编，且能用上 records / pattern matching / class modifiers 这些 Dart 3.x 较新特性。**如果未来切到更老的 fork（如 `flutter-oh-3.35.7`），core 必须降到该 fork 的 Dart 基线（如 3.16.8）**——这是上兼容方向，core 的版本以"双端能编的最低 Dart"为准。

> **fork 初始化提醒**：刚下载的 OHOS fork 可能缺 `.git`（release 包形式），首次 `flutter` 命令会报 `not a clone of the GitHub project`。修复：进入 fork 目录跑 `git init && git remote add origin https://gitee.com/openharmony-sig/flutter_flutter.git`，再跑一次 `flutter --version` 触发 `bin/cache/dart-sdk/` 下载。

```bash
# 如果还没装 FVM
brew tap leoafarias/fvm && brew install fvm

# 验证本机已有版本都被 FVM 识别
fvm list
# 应能看到：
#   3.16.8                  （备用，本任务不用）
#   3.41.6                  （官方 SDK，给 chatgpt_flutter / chatgpt_app_core 用）
#   flutter-oh-3.41.9-dev   (custom，给 chatgpt_flutter_ohos 用)
#   flutter-oh-3.35.7       （旧 fork，可删）
```

如果 `fvm list` 没列出 `flutter-oh-3.41.9-dev`，说明 FVM 还不认这个目录，按需要在每个工程里用 `--force` 钉（见 §5.1）。

**不要**把任一 SDK 写进 `~/.zshrc` 的 `PATH`——所有命令都走 `fvm flutter ...`，由各工程的 `.fvmrc` 决定用哪个版本。

### 3.2 IDE 配置

- **VS Code**：装 `Dart-Code.flutter` 扩展，它会自动识别工程根的 `.fvm/flutter_sdk` 软链；或在 `settings.json` 加 `"dart.flutterSdkPath": ".fvm/flutter_sdk"`。
- **Android Studio**：Settings → Languages & Frameworks → Flutter → Flutter SDK path 指向 `<project>/.fvm/flutter_sdk`（每个工程要分别配）。
- **DevEco Studio**：仅用于鸿蒙原生层（`ohos/` 子工程），不需要也不要让它知道 Flutter SDK 路径。

### 3.3 DevEco Studio 与签名

1. 安装 DevEco Studio 5.0.5，完成首启向导（自动下载 HarmonyOS SDK）。
2. File → Project Structure → Signing Configs → Automatic signing，登录华为账号生成调试证书。
3. 设置环境变量（写到 `chatgpt_flutter_ohos/.envrc`，§5.4 会用到）：

```bash
export TOOL_HOME=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME=$TOOL_HOME/sdk
```

### 3.4 验证

在仓库根做一次性核对：

```bash
# 用鸿蒙 fork 跑 doctor（注意 --force，因为这是自定义版本）
fvm use flutter-oh-3.41.9-dev --force
fvm flutter doctor -v
```

输出必须包含 `[✓] HarmonyOS toolchain`，否则停下来排查（缺 ohpm / hvigor / Node 之类，对照 §3.3 / §5.1 的环境变量补齐）。验证完把仓库根的 `.fvm/` 目录删掉——版本钉应该在子工程里写，不在 monorepo 根。

---

## 4. Phase 1：抽取 `chatgpt_app_core` 共享包

> 这一阶段的所有动作都在**官方 Flutter SDK** 下做，先不碰鸿蒙。每完成一步用 `flutter run`（Android 或 iOS）跑一次冒烟，确保现有功能不回归。

### 4.1 创建 core 包

```bash
cd /Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep
flutter create --template=package chatgpt_app_core
```

### 4.2 迁移代码与资产

1. 把 `chatgpt_flutter/lib/` 下**除 `main.dart` 外**的全部目录（`db/`、`dao/`、`pages/`、`provider/`、`widget/`、`util/`）`git mv` 到 `chatgpt_app_core/lib/`。
2. 把 `chatgpt_flutter/assets/` 整个 `git mv` 到 `chatgpt_app_core/assets/`。
3. 在 `chatgpt_app_core/lib/` 下新建 `app.dart`，把原 `chatgpt_flutter/lib/main.dart` 里 `MyApp` 类、`doInit()`、`FutureBuilder` 逻辑搬进来，并暴露入口函数：

```dart
// chatgpt_app_core/lib/app.dart
Future<void> runChatGptApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 注意：splash 调用从这里挪走（见 §4.6），鸿蒙 shell 不要原生 splash
  runApp(const MyApp());
}
```

4. 新建 barrel `chatgpt_app_core/lib/chatgpt_app_core.dart`：

```dart
library chatgpt_app_core;
export 'app.dart' show runChatGptApp;
```

### 4.3 更新 core 包的 `pubspec.yaml`

把原 `chatgpt_flutter/pubspec.yaml` 中 `dependencies` 段（除了 `flutter_splash_screen`，见 §4.6）整体搬到 `chatgpt_app_core/pubspec.yaml`，并把 path 依赖改为 `../`：

```yaml
name: chatgpt_app_core
description: 业务核心：UI / DAO / Provider / Util，三端共享
version: 0.0.1
publish_to: 'none'

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  login_sdk:
    path: ../login_sdk
  hi_download:
    path: ../hi_download
  chat_message:
    path: ../chat_message
  openai_flutter:
    path: ../openai_flutter
  sqflite: ^2.4.2+1
  sqflite_common_ffi: ^2.4.0+3
  flutter_hi_cache: ^0.0.1
  provider: ^6.1.5+1
  url_launcher: ^6.3.2
  http: ^1.6.0
  cached_network_image: ^3.4.1
  lottie: ^3.3.3
  package_info_plus: ^10.1.0
  open_filex: ^4.7.0
  speech_to_text: ^7.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/images/
    - assets/lottie/
```

注意：**`flutter_splash_screen` 不进 core**——它是平台特定的开屏组件，让两个 shell 各自处理。

### 4.4 修正资产引用

全工程搜索：

```bash
grep -rn "Image.asset\|Lottie.asset\|AssetImage" chatgpt_app_core/lib/
```

每一处都要加 `package: 'chatgpt_app_core'`。例：

```dart
// before
Image.asset('assets/images/logo.png')
// after
Image.asset('assets/images/logo.png', package: 'chatgpt_app_core')
```

`AssetImage` 同理传 `package` 命名参数。**不漏一处**——漏了就线上白屏。

### 4.5 重写 `chatgpt_flutter` 为薄 shell

清空 `chatgpt_flutter/lib/main.dart` 为：

```dart
import 'package:chatgpt_app_core/chatgpt_app_core.dart';
import 'package:flutter_splash_screen/flutter_splash_screen.dart';

Future<void> main() async {
  await runChatGptApp();
  // Android/iOS 走原有原生 splash 流程
  FlutterSplashScreen.hide();
}
```

更新 `chatgpt_flutter/pubspec.yaml`，`dependencies` 简化为：

```yaml
dependencies:
  flutter:
    sdk: flutter
  chatgpt_app_core:
    path: ../chatgpt_app_core
  flutter_splash_screen: ^4.0.0   # 仅 Android/iOS 需要
```

`flutter.assets:` 段**整体删掉**（资产已迁到 core）。`uses-material-design: true` 保留。

### 4.6 splash 调用拆分

`runChatGptApp()` 内部**不再调用** `FlutterSplashScreen.hide()`——这是 Android/iOS shell 的职责。鸿蒙 shell 不会调它（也不会依赖它）。如果原 `main.dart` 里还有别的 `FlutterSplashScreen.show()` 之类，按相同思路下放到 shell。

### 4.7 验收（必跑）

```bash
cd chatgpt_flutter
flutter pub get
cd ../chatgpt_app_core && flutter pub get && cd ..
flutter run -d <android-device>   # 跑 Android：登录 → 对话 → 持久化 → 检查更新 → 语音 全部正常
flutter run -d <ios-device>       # 跑 iOS：同上
```

**只有 Android+iOS 双端冒烟通过才能进入 Phase 2**。这是底线——抽包阶段任何回归都比鸿蒙适配本身严重。

---

## 5. Phase 2：新建 `chatgpt_flutter_ohos` 鸿蒙 shell

### 5.1 给三个工程钉 Flutter 版本（FVM）+ 鸿蒙工程的环境变量

**Flutter SDK 由 FVM 管**，每个工程根写一份 `.fvmrc`：

```json
// chatgpt_flutter/.fvmrc
{ "flutter": "3.41.6" }

// chatgpt_app_core/.fvmrc
{ "flutter": "3.41.6" }

// chatgpt_flutter_ohos/.fvmrc
{ "flutter": "flutter-oh-3.41.9-dev" }
```

每个工程首次进入时跑一次 `fvm use --force`（自定义版本必须加 `--force`），FVM 会创建 `.fvm/flutter_sdk` 软链：

```bash
cd chatgpt_flutter && fvm use 3.41.6 --force
cd ../chatgpt_app_core && fvm use 3.41.6 --force
cd ../chatgpt_flutter_ohos && fvm use flutter-oh-3.41.9-dev --force
```

把 `.fvm/` 目录加进 `.gitignore`（FVM 默认会提示），`.fvmrc` 进 git。

**鸿蒙工程额外环境变量**（DevEco SDK、ohpm、hvigor、node）FVM 管不到，用 mise 做"按目录加载"：

```bash
brew install mise
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
exec zsh
```

`chatgpt_flutter_ohos/mise.toml`：

```toml
[env]
TOOL_HOME = "/Applications/DevEco-Studio.app/Contents"
DEVECO_SDK_HOME = "/Applications/DevEco-Studio.app/Contents/sdk"
_.path = [
  "/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin",
  "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin",
  "/Applications/DevEco-Studio.app/Contents/tools/node/bin",
]
```

首次进目录执行 `mise trust`。

`chatgpt_flutter` 与 `chatgpt_app_core` 不需要 `mise.toml`——它们只用 FVM 钉的官方 Flutter，没有额外环境变量。

### 5.2 创建鸿蒙 shell 工程

```bash
cd /Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep
flutter create --platforms=ohos --org com.imooc.chatgpt chatgpt_flutter_ohos
```

`flutter` 命令此时已经被 `.envrc` 切到 OpenHarmony fork，输出会是 `Flutter (OpenHarmony) ...`。

### 5.3 给 4 个 path 依赖补 ohos 平台目录

```bash
for pkg in login_sdk hi_download chat_message openai_flutter; do
  cd "/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/$pkg"
  flutter create --template=package --platforms=ohos --org com.imooc.${pkg} .
done
```

**不要**给 `chatgpt_app_core` 跑这条命令——它是个 dart 业务包，没有原生代码，不需要 `ohos/` 目录。

### 5.4 写鸿蒙 shell 的 `main.dart` 与 `pubspec.yaml`

```dart
// chatgpt_flutter_ohos/lib/main.dart
import 'package:chatgpt_app_core/chatgpt_app_core.dart';

Future<void> main() async {
  await runChatGptApp();
  // 鸿蒙端不调用 flutter_splash_screen
}
```

```yaml
# chatgpt_flutter_ohos/pubspec.yaml
name: chatgpt_flutter_ohos
description: ChatGPT Flutter 鸿蒙端 app shell
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  chatgpt_app_core:
    path: ../chatgpt_app_core

dependency_overrides:
  # 见 §6 详细说明；以下路径以 gitee 仓库实际结构为准
  sqflite:
    git:
      url: https://gitee.com/openharmony-sig/flutter_packages.git
      path: packages/sqflite/sqflite
      ref: master
  path_provider:
    git:
      url: https://gitee.com/openharmony-sig/flutter_packages.git
      path: packages/path_provider/path_provider
      ref: master
  url_launcher:
    git:
      url: https://gitee.com/openharmony-sig/flutter_packages.git
      path: packages/url_launcher/url_launcher
      ref: master
  package_info_plus:
    git:
      url: https://gitee.com/openharmony-sig/flutter_packages.git
      path: packages/package_info_plus/package_info_plus
      ref: master

flutter:
  uses-material-design: true
```

**`dependency_overrides` 只写在这里**，`chatgpt_flutter/pubspec.yaml` 与 `chatgpt_app_core/pubspec.yaml` 都**绝对不能**有这一段。

### 5.5 鸿蒙应用元数据

修改 `chatgpt_flutter_ohos/ohos/AppScope/app.json5`：

- `bundleName: "com.imooc.chatgpt"`
- `versionCode` / `versionName` 与 `pubspec.yaml` `version: 1.0.0+1` 同步。
- `icon`：在 `ohos/AppScope/resources/base/media/` 放 1024×1024 应用图标（可从 `chatgpt_app_core/assets/images/` 复制 logo，命名 `app_icon.png`）。

修改 `chatgpt_flutter_ohos/ohos/entry/src/main/module.json5` 的 `requestPermissions`：

```json5
{ "name": "ohos.permission.INTERNET" },
{ "name": "ohos.permission.GET_NETWORK_INFO" }
// MICROPHONE 不申请：鸿蒙端语音入口被禁用，避免应用市场审核风险
```

---

## 6. 鸿蒙端依赖适配细节

> 本节所有改动**只发生在 `chatgpt_flutter_ohos/`**，不动 core 和 Android/iOS shell。

### 6.1 sqflite

`dependency_overrides` 已在 §5.4 接入。验证：

- 真机首次启动后 `hdc shell ls /data/app/el2/100/database/com.imooc.chatgpt/` 应能看到 `tb_conversation_list` 等所在的 db 文件。
- `HiDBManager._init` 在鸿蒙下走默认的 `openDatabase()` 分支（`Platform.isWindows == false`），由 ohos 桥接接管，**core 代码无需改**。

### 6.2 path_provider

`hi_download.download()` 调用 `getApplicationDocumentsDirectory()` —— 鸿蒙下返回沙箱路径。但鸿蒙不会触发下载流程（升级入口被 §7.2 拦截），所以这个 override 主要是给 `cached_network_image` 间接用。

### 6.3 url_launcher

`login_sdk` 用它打开服务器渲染的注册页。真机要把目标 URL 的 host 换成局域网 IP（见 §7.4），否则 url_launcher 抛 `Could not launch`。

### 6.4 package_info_plus

如果 §5.4 里 gitee 仓暂未提供 ohos 桥接，**降级方案**：

不在 `dependency_overrides` 里 override，改为在 core 里调用处加分支：

```dart
// chatgpt_app_core/lib/util/version_util.dart
import 'package:flutter/foundation.dart';
Future<String> appVersion() async {
  if (defaultTargetPlatform == TargetPlatform.ohos) return '1.0.0';
  final info = await PackageInfo.fromPlatform();
  return info.version;
}
```

`TargetPlatform.ohos` 在 OpenHarmony Flutter fork 中存在；找不到时退而求其次用 `Platform.isOhos`（OpenHarmony Dart SDK 提供）。

### 6.5 splash

鸿蒙 shell **不依赖** `flutter_splash_screen`。如果需要开屏体验，在 `runChatGptApp()` 的 `FutureBuilder` 等待层里直接 `Image.asset('assets/images/splash.png', package: 'chatgpt_app_core', fit: BoxFit.cover)` 全屏铺满；Future 完成后自然进入主界面。**这部分代码本身就在 core 里，三端共用**——只是 Android/iOS 上原生 splash 会先于 Flutter splash 显示，体感差异可以忽略。

---

## 7. 平台分支代码改动（写在 core 里）

> 改动小、可逆。每处加 `// ohos:` 注释。

### 7.1 `chatgpt_app_core/lib/db/hi_db_manager.dart`

无需改（`Platform.isWindows == false` 时走默认分支，由 §6.1 接管）。

### 7.2 `chatgpt_app_core/lib/pages/my_page.dart`

```dart
void _checkUpdate() async {
  // ohos: 鸿蒙不支持 APK 安装，统一引导到应用市场
  if (defaultTargetPlatform == TargetPlatform.ohos) {
    HiDialog.showSnackBar(context, '鸿蒙版本请前往华为应用市场更新');
    return;
  }
  if (!Platform.isAndroid) {
    HiDialog.showSnackBar(context, '仅支持Android，其他平台敬请期待');
    return;
  }
  // 原有 Android 逻辑保持
}
```

### 7.3 `chatgpt_app_core/lib/widget/message_input_widget.dart`

在 `_initSpeech()` 开头加：

```dart
// ohos: speech_to_text 暂无鸿蒙实现，关闭语音入口
if (defaultTargetPlatform == TargetPlatform.ohos) {
  if (mounted) setState(() => _hasSpeech = false);
  return;
}
```

UI 层在 `_hasSpeech == false` 时已经隐藏麦克风按钮（沿用 iOS 17 模拟器路径），**不要新增 UI 分支**。

### 7.4 `BackendConst.host`

文件位于 `login_sdk/lib/`（用 `grep -rn "BackendConst" login_sdk` 定位）。改为：

```dart
class BackendConst {
  static String host = const String.fromEnvironment(
    'BACKEND_HOST',
    defaultValue: 'localhost:3000',
  );
}
```

- Android/iOS 不传 `--dart-define` 时默认值不变，**零回归**。
- 鸿蒙真机调试用 `flutter run --dart-define=BACKEND_HOST=192.168.1.x:3000`。

---

## 8. APK 升级与语音的鸿蒙处置

- **APK 升级**：§7.2 已经在入口拦截，鸿蒙不会触发 `hi_download` / `open_filex` 调用链。`hi_download` 包保留以便 Android 继续使用。
- **语音输入**：§7.3 已禁用入口；如果 `chatgpt_flutter_ohos` `pub get` 因为 `speech_to_text` 没有 ohos 端而报错，按 §11 风险条目里的方案应对。

---

## 9. 编译与运行

### 9.1 三个工程各跑一次 pub get

```bash
cd chatgpt_app_core && fvm flutter pub get && cd ..
cd chatgpt_flutter && fvm flutter pub get && cd ..        # 钉 3.41.6
cd chatgpt_flutter_ohos && fvm flutter pub get && cd ..   # 钉 flutter-oh-3.41.9-dev
```

### 9.2 后端 host 配置

```bash
cd chatgpt_backend && npm run start:dev
ipconfig getifaddr en0   # 取 Mac 局域网 IP
```

### 9.3 三端跑通

```bash
# Android（确认抽包没回归）
cd chatgpt_flutter && fvm flutter run -d <android-id>

# iOS（确认抽包没回归）
cd chatgpt_flutter && fvm flutter run -d <ios-id>

# 鸿蒙
cd chatgpt_flutter_ohos
hdc list targets                       # 确认设备
fvm flutter devices                    # 应能看到 ohos 设备
fvm flutter run -d <ohos-id> --dart-define=BACKEND_HOST=192.168.1.x:3000
```

如果 `fvm flutter run`（鸿蒙）失败，进 `chatgpt_flutter_ohos/ohos` 用 DevEco Studio 打开点 Run，先把 ohpm 依赖拉齐，再回命令行重试。

---

## 10. 验收标准（必须逐条勾选）

### 10.1 抽包阶段（Phase 1）

- [ ] `chatgpt_app_core` 包结构正确：`lib/` + `assets/` + `pubspec.yaml`，barrel 暴露 `runChatGptApp`。
- [ ] `chatgpt_flutter/lib/main.dart` 减为 ~10 行薄 shell，仅 import core 与 `flutter_splash_screen`。
- [ ] `chatgpt_flutter/pubspec.yaml` `dependencies` 段除 flutter / `chatgpt_app_core` / `flutter_splash_screen` 外为空，`flutter.assets:` 段被删除。
- [ ] `grep "Image.asset\|Lottie.asset\|AssetImage" chatgpt_app_core/lib/` 输出的每一行都带 `package: 'chatgpt_app_core'`。
- [ ] Android `flutter run` 能跑：登录、注册（url_launcher）、首页公告（HiAPICache）、对话（OpenAI/DeepSeek/后端代理）、置顶/取消置顶、删除会话、收藏、语音、检查更新、splash 全部正常。
- [ ] iOS `flutter run` 同上（重点验证 iOS 17 模拟器分支未坏）。

### 10.2 鸿蒙阶段（Phase 2）

- [ ] `flutter doctor`（在 `chatgpt_flutter_ohos/` 内执行）`HarmonyOS toolchain` 全绿。
- [ ] `chatgpt_flutter_ohos/ohos/`、4 个 path 依赖各自 `ohos/` 目录都存在。
- [ ] `chatgpt_flutter_ohos/` 下 `flutter build hap --release` 成功产出 `.hap`。
- [ ] 鸿蒙真机：登录页 → 注册（带 `--dart-define=BACKEND_HOST`） → 首页公告加载 → OpenAI 对话 → DeepSeek 对话 → 后端代理对话 全部走通。
- [ ] 鸿蒙真机：会话置顶/取消、删除会话、收藏消息持久化（关闭 App 重开仍在）——验证 sqflite ohos 实现。
- [ ] 鸿蒙真机：「我的 → 检查更新」点击后提示"鸿蒙版本请前往华为应用市场更新"。
- [ ] 鸿蒙真机：语音按钮不出现或为禁用态。
- [ ] **回归再跑一次**：Android 和 iOS 的 §10.1 全清单——确认 §6 的 overrides 真的没污染到它们。

---

## 11. 风险与备选

- **gitee 仓路径漂移**：`flutter_packages` 子目录命名几个月会变。每次执行任务前 `git ls-tree` 一下仓库实际结构，再决定 `path:` / `ref:`。
- **OpenHarmony Flutter fork 与官方 Flutter 版本错配**：`chatgpt_app_core` 用官方 SDK 解析，但 `chatgpt_flutter_ohos` 用 fork 解析——同一个 core 包要被两个 SDK 能力都接受。如果 core 用了某个新特性 fork 不支持，要么降级特性、要么 fork 跟版本。出现 `pub get` 解析失败时**优先调整 fork 版本**（换 tag），不要改业务代码。
- **`speech_to_text` 在 ohos 工程 `pub get` 失败**：分两种情况——
  - 如果只是警告"unsupported platform"，直接忽略，由 §7.3 的运行时分支兜住。
  - 如果是硬性 `pub get` 失败，临时方案是 fork 一份 `speech_to_text`，仅修改 `pubspec.yaml` 加 `platforms: { ohos: { default_package: speech_to_text } }`，原生不实现，仅为编译过；在 `chatgpt_flutter_ohos/pubspec.yaml` 的 `dependency_overrides` 里指向这个 fork。**不要改 core 的依赖声明**。
- **资产 `package:` 漏改导致鸿蒙真机白屏**：抽包阶段在 Android/iOS 上反而能"凑巧"加载（assets 目录在多个位置都被 Flutter 找到的边界 case），到鸿蒙才暴露。所以 §10.1 最后一条 grep 务必逐行核对。
- **应用内升级长期方案**：接 `appgallery-connect` 版本检查 API（需华为开发者后台上架），超出本次任务范围。

---

## 12. 交付物

1. 分支 `feat/harmony-adaptation`，包含：
   - 新增 `chatgpt_app_core/` 包。
   - 新增 `chatgpt_flutter_ohos/` 工程。
   - `chatgpt_flutter` 瘦身为 shell。
   - 4 个 path 依赖各自的 `ohos/` 目录。
   - 三个工程目录的 `.fvmrc`，鸿蒙工程的 `mise.toml`。
   - §7 的 Dart 代码改动。
2. 仓库根新增 `docs/harmony-runbook.md`：
   - FVM 安装与 `.fvmrc` 模板（含 `--force` 接入自定义 fork 的说明）。
   - mise 安装与 `mise.toml` 模板（鸿蒙工程的 DevEco 环境变量）。
   - DevEco / 签名一次性配置步骤。
   - `--dart-define=BACKEND_HOST=...` 的真机联调命令。
   - 已知未适配能力（speech_to_text、应用内升级）。
3. 30 秒真机录屏（或 `hdc shell snapshot_display` 截图）证明登录 → 对话 → 持久化三个核心链路。

---

## 13. 任务执行节奏（给 deepseek）

1. **§3 准备**：两套 SDK 装好、direnv 装好、`flutter doctor` 全绿。卡住就报错停下来，不要硬上。
2. **§4 Phase 1 抽包**：每完成一小步（迁目录 / 改 pubspec / 修资产引用 / 改 main.dart）就 `git add -p` 单独 stage。Phase 1 收尾必须 Android+iOS 双端冒烟全过，**这是底线**。
3. **§5–§6 Phase 2 鸿蒙工程**：在 `chatgpt_flutter_ohos/` 内推进，绝对不要改 core 或 Android/iOS shell（§7 的 core 改动除外，那些是平台条件分支）。
4. **§9 三端跑通**。
5. **§10 验收清单**逐条勾选，全部勾上才算交付。**特别强调最后一条 Android/iOS 回归**——这是独立工程方案的核心承诺，不能跳。

> 不要为了"凑通过"绕过任何一项。如果某一步阻塞，停下来在执行日志里描述阻塞点和已尝试方案，等用户介入决策。
