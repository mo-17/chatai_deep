# 艾普品牌与启动页

应用显示名统一为 **艾普**。品牌图形使用对话框、四角星芒与薄荷色圆点，应用图标矢量源为 `aipu-mark.svg`，启动主视觉为 `aipu-splash-symbol.svg` 与两份 backdrop 矢量源；主色 `#6558E8`。启动页使用悬浮渐层标识、艾普 / AIPU 字标、柔和环境光与底部微光进度线，浅色背景 `#F8FAFC`、深色背景 `#0C1020`。

Flutter 共用启动页位于 `chatgpt_app_core/lib/branding/`；不读取尚未完成初始化的账号或主题存储。Android、iOS 使用匹配的原生启动资源，Web 在 Flutter 首帧后移除 HTML 占位页；不额外强制停留。OHOS 使用平台启动窗口和共用 Flutter 加载页。

Android / iOS / macOS / Windows / Web / OHOS 图标由矢量源派生。生成器需要 Node.js 与 `sharp`，只在再生成图标时需要；各端构建直接使用已生成的资源：

```sh
NODE_PATH=/path/to/node_modules node scripts/generate-brand-assets.cjs
```

显示名更新保留现有应用标识（applicationId / bundle identifier）、数据库目录、可执行文件名和签名。旧的 ChatGPT 启动图片已移除；模型服务商的标识不属于应用品牌。

2026-10-21 本地检查：Android debug 包及 Web release 构建通过；APK 标签为“艾普”；iOS 启动 storyboard 编译通过；启动相关回归 26 项通过；品牌文件静态分析无诊断。浅色、深色、横屏、大字体/减弱动画均进行了 Flutter 渲染检查。此轮没有连接的 Android 设备，尚未覆盖安装；iOS/OHOS/Windows/macOS 原生显示效果未作实机验收。
