# 二十套配套动态聊天装扮

2026-10-22：新增赤曜凤凰、霜月雪境、萤森秘语、樱桃汽水、蜜蜂花园、竹影熊猫、柴犬邮局、猫咪魔法、星际航行、电路矩阵、翡翠玲珑、敦煌飞天、牡丹国色、青花瓷韵、锦鲤荷塘、银杏秋信、蘑菇童话、游乐绮梦、甜橙夏日、皇家棋局。

「我的 → 外观与主题 → 聊天装扮」现有 30 套动态头像框，新 20 套同时提供动态气泡。新增套装优先显示，可搜索名称或描述；气泡和头像框可独立搭配，我的消息与 AI 回复分别保存。原有持久化键及旧装扮保持兼容。

## 运行时素材与尺寸

- 每套为 256×256 动态头像框、512×320 动态气泡及两张独立封面。两类动画均为 6 帧、180 ms/帧、1.08 秒无限循环。80 个 WebP 文件总计 16,892,002 字节，随包离线提供。
- 使用已经确认的透明 PNG 序列无损编码，不改变画面及 alpha。来源和哈希见 [manifest.json](design/paired-animated-20261022/manifest.json)，包括修正版在内的实际生成提示词见 [prompts.json](design/paired-animated-20261022/prompts.json)。
- 头像内容仍保留原来的 40×40 逻辑尺寸，装饰在外围扩展。`chat_paired_asset_geometry.dart` 从六帧测量头像孔和气泡底色边界，避免孔内露缝或透明外沿露出矩形底板。
- 有框头像与气泡额外间距仍为 2 逻辑像素，无框头像仍为 8；不叠加新的空白间隔。
- 气泡九宫格 `scale=4`，源像素切片为 `(200,156)-(312,164)`；逻辑切片为 `(50,39)-(78,41)`。角部保持比例，中间边缘随消息伸缩。装饰层裁掉正文区域，文字、代码与点击行为使用真实组件。
- 动态头像框及动态气泡共用图片流管理：离屏、后台、TickerMode 关闭、系统减少动态时使用封面。气泡保持完整原生解码尺寸供九宫格使用；头像按显示像素解码。RepaintBoundary 隔离图片重绘，不逐帧重建正文。

重新导出：从仓库根目录运行 `python3 scripts/prepare-chat-decoration-20styles.py`（Pillow、NumPy；需本机 `output/chat-decoration-20styles-20261022/` 中的已确认源帧），然后使用项目 Dart 格式化生成的 geometry 文件。脚本校验六个不同画面、时长、无限循环、透明中心、WebP 与 PNG 的有效 RGBA 像素一致性。

## 验证入口

从 `chatgpt_app_core/` 使用固定的 Flutter 3.35.7：

```bash
fvm flutter test --no-pub ../chat_message/test test/chat_decoration_test.dart test/chat_illustrated_assets_test.dart test/chat_animated_frame_test.dart test/appearance_settings_page_test.dart test/theme_provider_test.dart
```

覆盖共享聊天组件、原头像大小和间距、新 20 套双侧布局、30 套选择与持久化、真实 WebP 帧/封面解码、九宫格固定角、动态生命周期暂停、大字体搜索及明暗模式。构建和真机安装证据另记，手机实际播放以真实设备操作为准。

2026-10-22：按用户授权，将代码、运行时素材和验收记录分批提交并推送；原始源帧、预览和打包文件保留本机。

对话背景、顶部栏及输入框随套装变化的功能见 [对话整页装扮](../chatgpt_app_core/CONVERSATION_DECORATION.md)；已有消息装扮的尺寸与间距规则继续保留。

## 本次结果

- 57 项正式回归全部通过，临时真实组件视觉验收 1 项通过，输出 40 张明暗预览。共计 58 项；不把素材解码或宿主机绘制称为手机播放验收。
- 本次改动的 Dart 文件静态分析无诊断，`git diff --check` 通过。
- 正常 Android Debug APK 使用既有 `deploy/flutter/production.json` 构建成功，80 个新增运行时资源与源清单哈希完全一致。
- 小米 M2102J2SC 上 `adb install -r -t` 返回 `Success`；正常入口冷启动 `Status: ok`，约 2.4 秒。保留已有账号与数据。
- 用户已在真机抽测确认：「两者正常播放，大小和间距合适」。验收覆盖所选新增套装的头像框播放、气泡播放、头像大小及两者间距；未声称逐套测试全部 20 套。
- 测试、构建日志和设备验收摘要保留于本机 `output/chat-decoration-20styles-20261022/integration/` 及 `/private/tmp/chatai-20sets-*.log`。
