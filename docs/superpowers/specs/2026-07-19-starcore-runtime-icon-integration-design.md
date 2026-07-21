# 星核向导运行时图标接入设计

- 日期：2026-07-19
- 状态：设计与书面规范已批准；尚未实施
- 适用项目：`chatai_deep` Flutter 客户端
- 上游视觉规范：`docs/superpowers/specs/2026-07-13-starcore-icon-system-design.md`
- 视觉母版：`docs/design-assets/starcore-guide/`

## 1. 背景与目标

「星核向导」首轮图标系统已经完成 A–D 四类视觉资产与小尺寸验收，但当前文件仍只存在于设计文档目录，没有进入 Flutter asset bundle，也没有替换各平台启动图标。

本轮目标是把已经通过视觉验收的资产接入真实 App，同时保持现有经典主题可逆、用户自定义头像兼容，并避免让 UI 资源侵入工具执行等应用层逻辑。

完成后应达到以下结果：

1. Android、iOS、macOS、Windows、Web PWA 与 HarmonyOS 使用统一的星核向导启动图标。
2. 二次元主题下，「聊天」与「创作」底部导航使用已确认的默认/选中 SVG；经典主题保持现有 Material 图标。
3. 二次元主题提供两张星核助手头像，并以探索向导替换 App 自有的默认 AI 占位头像。
4. 二次元主题下，联网搜索与知识库检索在工具选择页和工具调用卡片中使用专属 SVG。
5. 缺失或损坏的品牌资产能够回退到现有 Material 图标或 emoji，不阻断页面渲染和对话流程。

## 2. 已确认的产品决策

### 2.1 主题边界

- 启动图标属于 App 品牌，不随主题变化，在所有正式目标平台统一替换。
- 导航、助手和工具品牌图标只在 `AppVisualTheme.of(context).isAnime` 为 `true` 时启用。
- 经典主题保留现有 Material 图标、AI 文字占位和 emoji 行为。
- 用户已经选择的本地图片或 emoji 不因切换主题被重写或删除。

这条边界提供可逆路径：用户切回经典主题即可恢复原有视觉，而数据库中仍保留二次元主题所需的星核头像选择。

### 2.2 技术路线

采用 SVG + PNG 混合方案：

- 导航与工具图标继续使用已验收的 24×24 SVG，由 `flutter_svg` 在 Flutter 运行时渲染。
- 启动图标和助手头像使用现有高分辨率 PNG。
- 各平台启动图标由 1024×1024 母版生成并提交到平台资源目录，平台启动时不依赖 Flutter asset bundle。
- 不把 SVG 路径改写成 `CustomPainter`，也不为每种 Flutter DPR 维护多套功能图标 PNG。

当前三份 Flutter 锁文件已经锁定 `flutter_svg 2.3.0`，但它目前只是传递依赖。实施时必须在 `chatgpt_app_core/pubspec.yaml` 中声明为直接依赖，使 shared core 对自身 import 负责。`flutter_svg` 为 Dart/Flutter 渲染依赖，不增加 Android、iOS 或 HarmonyOS 原生插件注册。

## 3. 范围与非目标

### 3.1 本轮范围

- 为 shared core 建立正式的星核运行时资产目录和集中式资源映射。
- 替换真实目标平台已经配置的启动/应用图标资源。
- 接入二次元主题导航、默认 AI 头像、助手头像预设和两种工具图标。
- 增加资源合同、主题分支、回退行为和平台尺寸测试。
- 更新相关设计文档中的「尚未接入」状态。

### 3.2 本轮不做

- 不为「精彩」「我的」新画未经审核的导航图标；这两个目的地继续使用 Material 图标。
- 不为其余 11 个内置工具或动态 MCP 工具临时拼装品牌图标。
- 不批量修改现有助手的 emoji、图片或数据库行。
- 不修改 `ToolDescriptor` 的业务元数据结构来承载 Flutter Widget、asset path 或 `IconData`。
- 不改后台、管理端、模型能力或工具执行逻辑。
- 不扩展 Story room 自己的 persona/avatar schema；普通会话的助手头像链路会完整贯通，Story room 保持现有 image/emoji 回退。
- 不为当前没有正式图标打包配置的 Linux runner 新建发布链。
- 不替换 `chatgpt_flutter_ohos` 中与 HarmonyOS 构建无关的 Android/iOS/macOS/Windows/Web 脚手架资源。

## 4. 资产分层与目录

### 4.1 设计母版与运行时副本

`docs/design-assets/starcore-guide/` 继续保存视觉母版、验收矩阵、生成提示和 validator，不直接加入 `pubspec.yaml`。

Flutter 运行时副本放入：

```text
chatgpt_app_core/assets/icons/starcore/
├── assistant-creator.png
├── assistant-explorer.png
├── nav-chat-default.svg
├── nav-chat-selected.svg
├── nav-create-default.svg
├── nav-create-selected.svg
├── tool-knowledge-search.svg
└── tool-web-search.svg
```

`chatgpt_app_core/pubspec.yaml` 注册该目录。运行时副本必须与母版字节一致；不在复制过程中重新压缩、改色或改 viewBox。

启动图标不从 shared core 路径运行时加载。`app-icon-concept.png` 继续作为唯一 1024×1024 母版，派生资源直接写入各平台现有资源集合。

### 4.2 集中式映射

新增一个只负责 UI 的星核资源组件，例如：

```text
chatgpt_app_core/lib/widget/starcore_runtime_icon.dart
```

该组件承担：

- 资产路径常量。
- 导航 glyph 与 selected/default 状态选择。
- `web_search`、`knowledge_search` 到工具 SVG 的映射。
- 二次元主题开关。
- SVG placeholder/error fallback。
- 稳定的 widget key，供测试定位。

shared core 的 `SvgPicture.asset` / `Image.asset` 必须显式传 `package: 'chatgpt_app_core'`，确保两个 shell 通过 path dependency 打包时使用正确的 package asset key。

工具 id 映射留在 UI 层。`chat/application/tool_registry.dart` 继续只描述工具 id、名称、描述、依赖与副作用，不 import Flutter UI。

## 5. 启动图标接入

### 5.1 目标平台

| 目标 | 接入位置 | 处理方式 |
| --- | --- | --- |
| Android | `chatgpt_flutter/android/app/src/main/res/mipmap-*` | 当前只有 xxxhdpi 192px；补齐 48/72/96/144/192px 五档 `ic_launcher.png`，保留 manifest 的 `@mipmap/ic_launcher` 引用 |
| iOS | `chatgpt_flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/` | 按现有 `Contents.json` 覆盖全部 16 个 filename/size/scale 槽位，保持 RGB、无 alpha |
| macOS | `chatgpt_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/` | 先生成符合 macOS 视觉边距的透明圆角母版，再输出现有 16–1024px 七个文件；保持 `Contents.json` 不漂移 |
| Windows | `chatgpt_flutter/windows/runner/resources/app_icon.ico` | 重建多帧 ICO，保持 `Runner.rc`、resource id 和窗口加载路径不变 |
| Web PWA | `chatgpt_flutter/web/` | 替换 16px favicon、192/512 普通图标与带安全留白的 192/512 maskable 图标；保留 manifest 文件名和 purpose |
| HarmonyOS | `chatgpt_flutter_ohos/ohos/AppScope/resources/base/media/app_icon.png` 与 `ohos/entry/src/main/resources/base/media/icon.png` | 同时替换两个 114×114 生产资源，保持 `$media:app_icon` / `$media:icon` id 不变 |

Android 当前没有独立 adaptive-icon 前景/背景资源。本轮不从已经合成的方形母版猜测分层，也不新增伪 adaptive icon；继续沿用现有 legacy launcher 资源结构，由系统按平台规则展示。后续若取得星核主体透明前景母版，再单独设计 adaptive icon。

HarmonyOS entry 的 `$media:icon` 同时被 `icon` 与 `startWindowIcon` 引用，因此替换它也会改变启动窗口图标。`ohosTest` 下的同名图片和所有 `build/ohos/intermediates/` 生成物不属于生产资源，不得编辑。

### 5.2 生成约束

- 所有派生图均从 canonical 1024×1024 PNG 生成，禁止级联缩放。
- iOS、Android 普通图标保持正方形、不透明、sRGB，不预烘焙系统蒙版。
- macOS 保留平台要求的透明视觉边距与圆角轮廓，避免 Dock/Finder 显示成顶满画布的硬方块。
- 使用高质量下采样；最小尺寸重点检查顶部星核和双翼不能粘连。
- Windows ICO 必须能被工具识别为多帧 ICO，且至少覆盖 16、32、48 和 256px；不能把 PNG 直接改扩展名。
- Web maskable 图标需要检查关键主体处于安全区；不通过拉伸或额外裁切改变角色比例。
- Web manifest 的 `background_color` / `theme_color` 同步改为已经确认的星核色值，避免安装态和启动态仍出现 Flutter 默认蓝。
- 生成结果全部纳入 git，并提供尺寸/格式 validator；构建不在用户机器上临时生成图标。

## 6. Flutter 导航图标

接入点为 `chatgpt_app_core/lib/pages/bottom_navigator.dart` 的 `AppBottomNavigationBar`。

### 6.1 二次元主题

`NavigationBar` 的四个目的地保持标签、顺序和页面映射不变：

1. 聊天：`nav-chat-default.svg` / `nav-chat-selected.svg`
2. 精彩：现有 `local_fire_department` Material 图标
3. 创作：`nav-create-default.svg` / `nav-create-selected.svg`
4. 我的：现有 `account_circle` Material 图标

自定义 SVG 的视觉尺寸为 24×24。`NavigationDestination` 本身继续提供可点击面积、选中状态和文本标签；SVG 设置为不单独贡献 semantics，避免屏幕阅读器重复朗读。

默认与选中状态必须根据 `currentIndex` 明确切换，不能只依靠 `NavigationBar` 对同一图标自动着色。SVG 使用已经通过三背景验收的内嵌品牌色，不再套 `ColorFilter`。

现有 `destinations: const [...]` 在接入状态化 asset widget 后需要取消列表级 `const`；未改动的 Material `Icon` 仍尽量保留局部 `const`。

### 6.2 经典主题

`BottomNavigationBar` 和 `_classicItem` 保持原样。经典主题不得创建 SVG、不得改变 activeColor，也不得改变现有测试 key `classic_bottom_navigation`。

## 7. 助手头像

### 7.1 持久化表示

复用现有 `AssistantModel.avatarType/avatarValue` 字段，不修改 SQLite schema：

- `avatarType = image`：现有托管本地图片路径。
- `avatarType = asset`：新的内置头像预设。
- `avatarType` 为空：现有 emoji 路径。

`asset` 的 `avatarValue` 保存稳定 id，而不是包内路径：

- `starcore_explorer`
- `starcore_creator`

UI 映射负责把稳定 id 转成 asset path。这样未来调整目录不会迁移数据库。旧版本不认识 `asset` 时会走现有 emoji fallback，不会崩溃。

### 7.2 展示优先级

二次元主题中的展示顺序：

1. 有效的用户本地图片。
2. 有效的星核 asset preset。
3. 用户明确选择的非空 emoji。
4. `assistant-explorer.png` 作为 App 自有默认 AI 占位。
5. 图片/asset 解码失败时回退 emoji，再回退现有 Material `smart_toy`。

经典主题继续遵循当前本地图片/emoji/AI 占位规则。切换到经典主题不会清除 `asset` id；只是在经典主题中视觉回退，切回二次元主题后恢复预设。

### 7.3 接入点

- `AssistantAvatar`：识别 `asset`，使用 `Image.asset` 并保留圆形裁切和 anime frame。
- 助手编辑页头像区：在 emoji 与本地图片操作旁提供「探索向导」「创作搭档」两个预设；选择预设只改内存表单状态，保存时沿用现有 DAO。切回 Emoji 必须显式清空 `avatarType/avatarValue`，不能让旧 asset 继续遮住新 emoji。
- `ConversationWidget._animeFallback`：用探索向导头像替换 `smart_toy` 作为二次元主题无自定义头像时的默认图；加载失败仍回退 `smart_toy`。
- `AssistantConversationFactory`、会话内切换助手和 `ConversationWidget`：识别并传播 `asset` stable id，使会话列表与绑定助手保持一致。
- 助手列表、助手选择器、资料页和会话标题继续通过 `AssistantAvatar` 自动获得新能力，不逐页重复判断。
- 助手角色卡 PNG/CHARX 导出需要通过 `rootBundle.load` 读取内置 asset bytes；不能只处理本地 `image` 后静默丢失预设头像。

删除或改选头像时，只允许 `AvatarAssetService.deleteAssistantAvatar` 删除受管本地图片。`asset` id 绝不能当作文件路径删除。

### 7.4 普通会话消息气泡

普通会话还需要把 App 品牌头像传入独立的 `chat_message` 包，但该包不能反向依赖 `chatgpt_app_core` 或硬编码星核资源路径。因此采用通用 avatar builder 扩展：

- 在 `chat_message` 的 `ChatList` / `DefaultMessageWidget` 增加可选 `MessageAvatarBuilder` 回调。
- 回调收到 `BuildContext`、`MessageModel` 与 avatarSize；返回非 null 时覆盖默认头像，返回 null 时继续现有 URL/File/emoji/initials 逻辑。
- `ConversationPage` 在二次元主题提供 builder：接收 `asset:<stable-id>` 时解析为对应星核头像；接收 AI 的空头像时显示探索向导默认图。
- 经典主题不解析星核 asset，回退现有 emoji/initials/Material 行为；不得把包内路径持久化到消息表。
- 新消息的轻量持久化表示为 `asset:starcore_explorer` 或 `asset:starcore_creator`。旧版本会把它视为无效相对文件并回退 initials，不会崩溃。
- 历史消息保留发送时的 avatar 字符串，不随当前助手或主题切换改写。

Story room 使用独立 persona/speaker avatar 链路，本轮不把新的 asset 协议扩散到其模型与备份格式；遇到普通助手的未知 `asset` 值时按现有 emoji fallback 展示。

## 8. 工具图标

### 8.1 映射与显示范围

二次元主题下仅映射：

- `ToolRegistry.webSearchId` → `tool-web-search.svg`
- `ToolRegistry.knowledgeSearchId` → `tool-knowledge-search.svg`

其他内置工具、MCP 工具和未知 id 使用现有通用 `build_outlined` 或页面既有 Material 图标。经典主题完全保持现状。

### 8.2 接入位置

第一批接入两个用户能直接核对语义的表面：

1. `assistant_edit_page.dart` 的内置工具多选项：专属 glyph 作为 leading，副作用警告图标和 checkbox 行为不变。
2. `block_message_content.dart` 的 `ToolBlock` 卡片：成功状态显示专属 glyph；运行中继续显示 `CircularProgressIndicator`，错误、暂停与未知工具显示通用图标。

其他复用 `ToolRegistry.catalog` 的项目级工具选择 sheet 若有独立 UI，应复用同一映射组件，而不是复制路径字符串。动态 MCP 工具维持通用图标。

`ToolBlock.toolId` 是一次调用的实例 id（例如 `call_1`），不是工具类型。消息卡片必须按 `block.toolName` 匹配 `web_search` / `knowledge_search`；绝不能按 `toolId` 选择品牌图标。

工具图标仅改变显示，不参与工具可用性判断、模型 declarations、确认弹窗或执行路由。

## 9. 状态、数据流与回退

```text
设计母版
  ├─ 生成平台 launcher 资源 ──> OS launcher / task switcher
  └─ 字节一致复制到 core assets
       ├─ AppVisualTheme.isAnime = false ──> 现有 Material / emoji
       └─ AppVisualTheme.isAnime = true
            ├─ navigation state ──> default / selected SVG
            ├─ avatarType + avatarValue ──> image / asset / emoji / explorer fallback
            └─ toolName ──> web / knowledge SVG / generic fallback
```

运行时错误边界：

- SVG asset 缺失或解析失败：记录 Flutter asset error，局部显示传入的 Material fallback。
- PNG avatar 缺失或解码失败：局部显示 emoji；无 emoji 时显示 `smart_toy`。
- 不支持的 `avatarValue`：按未知 asset id 处理，不尝试访问任意路径。
- 任何图标错误不得改变导航选择、工具执行或助手保存结果。

## 10. 可访问性与性能

- 底部导航沿用 Material 组件提供的触控区域；不得把可点击范围缩成 24×24 图形。
- 工具卡片当前最小高度 44px，接入后保持不低于 44px。
- 导航和工具父组件继续提供中文 label；装饰性 SVG 使用 `excludeFromSemantics`。
- 默认/选中状态除颜色外已经具有填充和星核差异，不能在实现时抹平。
- SVG 组件使用常量 asset path 和固定尺寸，避免在 build 中读取文件或解析 manifest。
- 512px 头像通过 `cacheWidth/cacheHeight` 或等效解码约束按屏幕 DPR 解码，避免列表中按原始 512px 长期占用内存。
- 不添加循环发光动画；遵循现有静态 anime glow，避免图标造成持续重绘。

上述约束吸收了 `ui-ux-pro-max` 对移动端至少 44×44 点击区域、清晰选中态、文字对比和结构性图标不用 emoji 的检查结果。

## 11. 测试与验证

### 11.1 资源合同

- 运行时 8 个文件存在，且与设计母版 SHA-256 一致。
- 6 个 SVG 为合法 XML、viewBox 为 24×24，并继续通过现有 starcore validator。
- 2 张助手头像为 512×512 PNG。
- 各平台 launcher 文件的格式、尺寸、通道与配置引用一致。
- iOS/macOS `Contents.json` 中每个 filename 都存在，不新增孤儿资源。
- Web manifest 引用的普通与 maskable 图标都存在。
- HarmonyOS 配置引用的 `$media` 资源都存在。

### 11.2 Widget 测试

- 二次元导航在 index 0 使用 chat selected、index 2 使用 create selected，其余对应 default。
- 经典导航仍只渲染 Material 图标，不构建星核 SVG。
- 星核 asset preset 在二次元主题可见，经典主题回退且不改变 model 值。
- 未知 asset id、缺失本地图片和损坏 asset 均走指定 fallback。
- 助手编辑页选择两个预设后可保存；切回 Emoji 会清空 asset 状态；HarmonyOS 不依赖系统相册也能选择内置预设。
- `AssistantConversationFactory` 与会话内切换会传播 asset stable id；会话列表二次元主题显示 asset，经典主题回退。
- 普通消息气泡通过 `MessageAvatarBuilder` 显示 asset/default explorer；旧的 URL/File/emoji 分支保持不变，经典主题不显示星核 asset。
- 工具编辑项仅对 `web_search`、`knowledge_search` 显示专属 glyph。
- `ToolBlock` 按 `toolName` 匹配；运行中优先显示 spinner，完成后显示专属 glyph；错误、暂停和未知工具显示通用图标。
- semantics 树只保留目的地/工具名称，不重复朗读 SVG。

### 11.3 回归与构建

- 运行现有 `app_bottom_navigation_bar_test.dart`、`assistant_avatar_performance_test.dart`、`assistant_market_page_test.dart` 与 `block_message_content_test.dart`。
- 运行 `assistant_test.dart`、`conversation_widget_theme_test.dart` 和 `chat_message` 的头像回归测试，覆盖新增 builder 但不改变默认渲染 API 行为。
- 为新增映射和资源回退添加聚焦 widget/unit tests。
- 运行 `flutter analyze` 与 `flutter test`（真实 package 为 `chatgpt_app_core`）。
- 对 `chatgpt_flutter` 至少完成一个可用目标的 debug 构建，确认 assets 被 shell 的 path dependency 打包。
- 对 HarmonyOS 无法在当前环境完成设备构建时，至少执行 shared-core 静态/测试验证并明确记录运行时验证缺口；不能把未运行的 HAP 构建宣称为通过。

## 12. 实施顺序与提交边界

实施计划应按以下可独立验证的切片执行：

1. 运行时资源目录、直接依赖、集中式图标组件与资源合同测试。
2. 二次元底部导航接入及主题回归测试。
3. 助手 asset preset、普通会话 avatar builder、默认 AI fallback 与头像传播测试。
4. 工具选择页/工具卡片接入及状态测试。
5. 各平台 launcher 资源生成、引用验证与视觉抽检。
6. 全量 analyze/test、可用 shell 构建、文档状态更新。

每个切片应使用窄提交，避免把大批二进制平台图标与 Dart 行为修改混在一个无法审查的提交中。

## 13. 完成定义

只有以下条件全部满足，才能称为「运行时图标接入完成」：

1. 正式目标平台的 launcher/app icon 已替换并通过配置引用检查。
2. 二次元主题的聊天/创作导航状态在真实 widget 中正确切换。
3. 两张助手头像可作为预设保存和恢复，默认 AI fallback 已品牌化，现有用户头像不受损。
4. 两种工具 glyph 在工具选择和工具卡片中生效，运行状态与未知工具回退正确。
5. 经典主题视觉和行为保持兼容。
6. 聚焦测试、相关回归、analyze 与可执行构建验证通过。
7. 任何未完成的平台运行时验证都被明确列为缺口，而不是隐含为通过。

## 14. 实施验证记录

验证日期：2026-07-22。以下结果均来自 `codex/starcore-runtime-icons` 工作树的本轮新鲜命令；文档头部状态保持不变，未把未通过的平台构建写成完成。

- Launcher 资源生成与静态合同：`/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s docs/design-assets/starcore-guide -p 'test_*runtime_icons.py' -v` 通过 **19/19**；`validate_runtime_icons.py --platform android|ios|macos|windows|web|ohos` 六个独立 CLI 均打印 `OK`。iOS/macOS 两份 `Contents.json` 通过 `python3 -m json.tool`，Android `AndroidManifest.xml` 通过 `xmllint --noout`，`git diff --check` 通过。
- Flutter runtime UI：母版资源 validator 通过 **12/12**，合同命令打印 `starcore assets: OK`，六个运行时 SVG 均通过 `xmllint`；`chat_message` 聚焦回归通过 **16/16** 且 analyze 无问题；17 文件 Core 聚焦回归通过 **196/196**；Core 全量测试通过 **1606/1606**。Core 全量 analyze 仅保留 `lib/widget/message_input_widget.dart:260:9` 的既有 `localeId` deprecated warning；该文件不在 Starcore 分支改动范围内，因此不把它表述为本分支引入。
- Android：`cd chatgpt_flutter && fvm flutter build apk --debug` 通过，产物为 `build/app/outputs/flutter-apk/app-debug.apk`（约 371 MB）；APK 内恰好包含 **8** 个 `packages/chatgpt_app_core/assets/icons/starcore/` 资源，无缺项或额外项。
- Web：`cd chatgpt_flutter && fvm flutter build web` 未通过。dart2js 明确报错 `sherpa_onnx 1.13.3` 与 `flutter_js 0.8.7` 导入 Web 不可用的 `dart:ffi`，最终为 `Error: Failed to compile application for the Web.`；这是当前既有跨平台依赖阻塞，不是 launcher 资源 validator 失败，也未在本轮绕过或修改。
- macOS：`cd chatgpt_flutter && fvm flutter build macos --debug` 通过，产物为 `build/macos/Build/Products/Debug/chatgpt_flutter.app`（约 320 MB）。构建只出现既有插件/部署目标 warning，不影响产物生成。
- iOS Simulator：`cd chatgpt_flutter && fvm flutter build ios --simulator --no-codesign` 通过，产物为 `build/ios/iphonesimulator/Runner.app`（约 392 MB）。
- HarmonyOS HAP：按 brief 执行 `cd chatgpt_flutter_ohos && eval "$(mise activate zsh --shims)" && flutter build hap` 时，`--shims` 只安装 mise shim、没有导出仓库 `DEVECO_SDK_HOME`，并落到标准 Flutter 3.41.6，因此提示不存在 `hap` 子命令。进一步使用 `.fvmrc` 锁定的 `flutter-oh-3.35.7` 与 mise 实际环境导出、复用现有 package config 后，已进入真实 `hvigorw assembleHap`，但 Hvigor 以 `Error Code: 00308018 Unknown Error`、`TypeError Cannot read properties of undefined (reading 'filter')` 和 exit 255 终止；本轮没有新鲜 HAP 成功产物。OHOS 资源/配置 validator 仍通过，既有旧 `build/ohos/hap/entry-default-signed.hap` 不作为本轮构建证据。
- Windows：四帧 ICO 像素/格式与 `Runner.rc` 引用静态验证通过；当前为 macOS 主机，未执行 Windows runner 构建，保留为明确的静态验证缺口。
- 视觉抽检：以原始/native detail 检查 Android 48/192、iOS 40/1024、macOS 16/1024、Web favicon 16/maskable 512、OHOS 114。所有样本的星核在目标尺寸可辨，macOS/favicon/OHOS 透明圆角正确，Web maskable 主体完整处于留白安全构图内，未看到 Flutter logo 或文字。
- 构建副作用：构建使用工作树内已存在且被忽略的约 139 MB Sherpa 资源；`chatgpt_flutter/pubspec.lock` 构建前后 SHA-256 均为 `a03451aba69b4abb042edd95d20c3476cb781514e4fa3a18f3b44ed535424c97`，没有需要提交的 lock 漂移。
- 产品边界：经典主题路径继续保留并可切回，Starcore runtime 视觉仍仅在二次元主题启用；Android adaptive icon 与 `roundIcon` 仍在本轮范围外，未新增猜测性前景/背景层。
