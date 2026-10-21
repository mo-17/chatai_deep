# Flutter Web

Web 与 macOS、Windows、移动端共用 `chatgpt_app_core` 的业务页面。宽屏显示侧栏和会话分栏，窄屏保留底部导航；输入框支持 Enter 发送、Shift+Enter 换行及中文输入法组词。

## 运行与构建

当前验证工具链：Flutter **3.35.7 / Dart 3.9.2**。从完整 monorepo 的本目录执行：

```bash
flutter pub get --enforce-lockfile --no-example
dart run sqflite_common_ffi_web:setup
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 48351
```

发布构建入口同时完成依赖解析、SQLite worker/wasm 生成与产物检查：

```bash
dart tool/build_web.dart
python3 -m http.server 48351 --bind 127.0.0.1 --directory build/web
```

输出为 `build/web/`。可用 `FLUTTER_BIN` 指定 Flutter 命令路径；执行脚本的 `dart` 也须来自同一 Flutter SDK。默认生成 JS 发布包，将 CanvasKit 资源打包到本地，并关闭 Flutter PWA 缓存；没有离线应用安装/后台运行承诺。

生成的 `web/sqlite3.wasm`、`web/sqflite_sw.js` 不入库，由已锁定的 `sqflite_common_ffi_web 0.4.5+4` setup 重建；setup 会下载官方 SQLite wasm。不要单独部署 `index.html`，必须保留整个 `build/web`，包括 worker、wasm、CanvasKit 和 assets。服务器应为 `.wasm` 返回 `application/wasm`，允许同源 worker，并保留应用目录中的相对路径。部署到子目录时传入 `--base-href=/your/path/`。

## 后端与 AI 配置

Web 默认使用页面自身的协议与 host，通过 `/uapi/*` 访问后端。生产环境使用 **HTTPS**，将 `/uapi/`（以及后端图片所需的 `/uploads/`）反向代理到现有后端。SSE 代理须关闭响应缓冲，否则首字会等整段完成后才出现。

也可在构建时指定后端，仅填写 host 与端口，不含协议和路径：

```bash
dart tool/build_web.dart --dart-define=BACKEND_HOST=api.example.com --dart-define=BACKEND_HTTPS=true
```

跨域时配置后端 `CORS_ORIGINS` 为网页实际 origin。HTTPS 页面无法调用普通 HTTP 服务。本地静态预览不自带后端，游客模式可体验本地管理功能；账号登录、云同步与后端代理仍需要现有后端。

「我的 → AI 服务设置」继续支持多服务商、模型能力配置、本地直连与后端代理。浏览器直连要求服务商支持浏览器 CORS 预检、Authorization 与流式响应；浏览器中的代理地址设置不会接管系统网络代理。不支持 CORS 的服务商应通过现有后端代理使用。不要把 API key 写进构建参数、静态文件或代码；用户凭据沿用安全存储适配器，WebCrypto 要求 HTTPS 或 localhost。浏览器安全存储与原生 Keychain 的保护边界不同，同源脚本仍属于信任边界。

## 浏览器数据与文件

- SQLite 通过 wasm + worker 持久化到 IndexedDB，按账号使用不同数据库。
- 附件、草稿资源、角色卡素材等通过有持久化事务的虚拟文件系统保存到 IndexedDB。异步写入等待事务提交，失败会回滚内存副本并向业务报错。
- 虚拟文件总量限 **128 MiB**；每次文件选择最多 **100 个 / 合计 64 MiB**，单文件 **32 MiB**，图片 **20 MiB**。导入器与模型原有的更严格限制仍然生效。先核元数据，再逐块校验实际字节。
- 支持用户选中的多文件或 ZIP、文本/PDF 文本层/Office 提取、图片附件和备份下载。网页无法读取任意设备路径；文件夹导入暂不支持。导出成功反馈表示浏览器已发起下载，磁盘保存结果由浏览器负责。
- 数据按浏览器 profile 与 **origin（协议、域名、端口）** 隔离。固定本地端口；换端口/域名不会自动迁移数据。清理网站数据、无痕会话结束或浏览器回收配额可能丢失本地数据，重要数据请定期导出备份。
- 当前文件缓存没有跨标签页互斥，文件导入、编辑和备份恢复请在同一标签页进行。导入临时副本也占用文件预算，未实现引用分析后的自动回收。

## 能力边界

可使用现有聊天、流式正文/推理/工具块、项目、助手、收藏、知识库、创作和备份页面。数据工具沿用原确认流程。系统朗读使用浏览器语音合成，声音取决于浏览器/系统。

浏览器暂不支持原生 OCR、QuickJS 技能脚本、Sherpa 离线语音模型、原生语音输入、APK 更新、设备音频路由，以及需要 DNS 校验和连接固定的 `fetch_url` 工具。`fetch_url` 明确返回不可用，不把原生的网络安全策略换成不受控的浏览器抓取。关闭页面后不保证 Agent/翻译任务继续运行。登录使用邮箱/手机号/密码/验证码与游客入口，原生第三方登录按钮不在 Web 显示。

## 验证

离线回归与真实浏览器测试分开运行：

```bash
# login_sdk/
flutter test --no-pub test/persistent_memory_file_system_test.dart
flutter test --no-pub --platform chrome test/browser_storage_test.dart

# chatgpt_flutter/，真实 WebCrypto 与服务商配置回读
flutter test --no-pub --platform chrome test/browser_settings_test.dart

# openai_flutter/，先在另一个终端启动仅本机的假服务
python3 ../chatgpt_flutter/tool/web/smoke_server.py
flutter test --no-pub --platform chrome test/browser_http_test.dart

# chatgpt_app_core/
flutter test --no-pub --concurrency=1 test/browser_picked_bytes_test.dart test/web_zlib_decoder_test.dart test/office_text_extractor_test.dart test/conversation_draft_store_test.dart test/backup_test.dart test/desktop_layout_test.dart test/desktop_message_input_test.dart
```

Browser HTTP 测试只使用 `browser-test` 假 key 和 loopback fixture，覆盖跨域预检、中文 UTF-8 分片、推理/工具/usage、首段提前交付、取消、超时与 HTTP 错误。`.github/workflows/web.yml` 自动构建和测试，但新增工作流仍须由远端实际执行后才有 CI 结论。

2026-10-20 本机验证结果：

| 检查 | 结果 |
| --- | --- |
| 发布构建 | JS Release 成功；目录约 40 MiB，ZIP 约 15.2 MiB；包含 SQLite worker/wasm |
| 真实 Chrome 专项 | IndexedDB 文件 1 项、安全凭据/创作身份 2 项、HTTP/SSE 3 项通过 |
| 共享核心回归 | 分组 239 / 20 / 58 / 120 项通过；4 项原生 JS 引擎集成测试按运行环境跳过，部分分组有重叠 |
| SDK / 登录 / 聊天组件回归 | 分别 70 / 108 / 24 项通过；登录的 1 项生产凭据测试未启用 |
| 静态分析 | 共享核心 lib、平台适配器、壳层、HTTP 及新增测试的相关范围通过 |
| Chrome 实际页面 | 游客登录、项目和中文草稿刷新恢复、系统选择器导入 TXT、附件刷新恢复、自定义服务商和假 Key 保存、连接测试、带附件发送及流式回复落库通过 |

页面验收仅使用本机生成的测试文本和 loopback 模拟 AI 服务，不使用真实服务商 Key。这些结果不代表 Safari/Firefox、真实 AI 服务商、线上后端或生产部署已经验收。新增 CI 工作流尚未在远端执行。

参考：[Flutter Web FAQ](https://docs.flutter.dev/platform-integration/web/faq)、[sqflite Web 设置与限制](https://pub.dev/packages/sqflite_common_ffi_web)。

## OCR 工作台与语义检索

共享批量 OCR、逐页校对、CSV/Excel/可搜索 PDF 导出、拍照/相册扫描和可选 Embedding 知识库问答已纳入 Web 构建。Web 不显示桌面原生快捷助手。真实 Chrome 合同测试同时验证 OCR 请求/取消、缩略图元数据与 SQLite WASM/IndexedDB 的原件 BLOB、校对文字和中断状态恢复。使用前仍需明确确认上传；关闭浏览器后不会自动重新上传。参见 [OCR 工作台说明](../docs/ocr-workbench.md)。
