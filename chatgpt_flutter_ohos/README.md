# 鸿蒙端（Flutter OH 3.35）

共享业务位于 `../chatgpt_app_core`。本壳使用 `.fvmrc` 中的
`flutter-oh-3.35.7`，不要用普通 Flutter SDK 构建 HAP。

## 构建

在本目录执行，非交互 shell 也需要显式加载 mise 环境：

```sh
eval "$(mise activate zsh --shims)"
eval "$(mise env -s zsh)"
fvm flutter pub get
./scripts/build-release.sh ../deploy/flutter/production.json
```

`mise.toml` 配置 DevEco、HOS_SDK_HOME 和工具路径。生产构建必须显式指定
公网 HTTPS 后端；构建成功不代表已联网或完成真机验收。
当前本机 SDK 是 `002ff8966a` 本地快照、Dart 3.9.2，添加了
`3.35.7-ohos-local` 本地标签用于修复版本识别；它不是上游正式发布标签。
新机器应安装具有完整版本信息的 Flutter OH 3.35 SDK，避免手动改写版本缓存。
本地快照的 Hvigor 插件会捕获并吞掉 Dart 编译异常，可能继续打包旧缓存。
上述脚本先独立执行 Dart AOT 编译，失败立即停止，再核对 HAP 内 `libapp.so`
与本次编译结果的程序头及可加载段 SHA-256（打包器会改写节表位置、名称等不参与加载的元数据）；
单独看到 `flutter build hap` 成功不足以验收。脚本还核对本次 CMake 编译的
QuickJS、Sherpa 和 ONNX Runtime 库与包内代码段一致，并检查对应许可文本确实存在于 HAP。
首次构建会按固定 SHA-256 下载官方 Sherpa OHOS arm64 库；原生库作为生成依赖忽略，
不将二进制放入 Git。直接从 IDE 构建前先运行 `python3 scripts/prepare-sherpa.py`。

## 已接入的文件能力

`../ohos_plugins/file_picker` 通过手动注册的 `FilePickerPlugin.ets` 调用
HarmonyOS `DocumentViewPicker`。无须申请整个存储空间的读写权限。

- 选择文件后，原生侧将授权 URI 复制到专属缓存，返回普通路径和原始名称。
- 单次最多 10 个文件，每个最大 256 MiB，整批最大 512 MiB；业务层保留更小限制。
- 导出传入 bytes，由原生侧写入用户选择的 URI。返回值只是保存反馈，不可再写一次。
- 取消返回 null；系统权限/IO 错误会抛异常。并发操作明确拒绝。
- 失败清理本批缓存并关闭句柄；`clearTemporaryFiles` 仅清理该适配器专属缓存。

恢复入口：聊天文件附件、备份导入/导出、知识库文本/PDF 文本层导入、
工作区文件、模板/预设/聊天记录导入导出、角色卡保存和带引用报告保存。
报告与角色卡在 OHOS 上使用系统文件保存，其他平台沿用分享流程。

## 图片与系统分享

`../ohos_plugins/image_picker` 在壳启动时注册到现有 `ImagePickerPlatform`，
通过系统相册选择器或 CameraPicker 获取单张图片。聊天附件、助手/角色头像、
会话头像沿用共享业务流程和账号边界。图片按请求等比缩放（最长边上限 4096），
归一 EXIF 方向，PNG 保留透明格式，其余格式转 JPEG；输出为静态图，不保留原始 EXIF。
原图最多 20 MiB / 64M 像素，默认输出尺寸上限 2048 × 2048。
相机结果 -1 表示未返回图片；其余系统异常明确报错。相册支持单批最多 10 张，输入/输出各最多 128 MiB；逐张转换，整批失败时清理本批副本。
多次选择可继续追加，不截断已有附件。选择期间进程被杀或结果尚未确认时，重新打开原会话
会提示恢复原输入及已复制的图片；尚未返回的系统选择需要重新选择。新会话按同账号、
同助手/项目恢复未发送草稿。恢复需确认，保留当前输入，确认后消费记录，24 小时过期。
新图片返回业务层前转存持久目录，恢复时也先保存新路径再删除临时副本。
仅 `pending_image_*` 临时文件受 512 MiB 配额及 24 小时过期规则管理；清理保护所有有效
恢复记录，损坏记录会保守保留临时文件。持久图片与可能仍被旧消息或头像引用的历史缓存
不自动删除，因此 512 MiB 不是整个图片存储的占用上限。

`../ohos_plugins/share_plus` 替换分享 stub，使用 ShareKit 分享文本和应用沙箱内文件。
聊天转发恢复系统分享；创作资料导出可使用文件分享。角色卡和报告仍保留上一批的系统保存流程。
内存 XFile 需调用方先保存为本地文件；不接受沙箱外文件、路径穿越或符号链接。

分享副本与页面临时文件独立，保留 24 小时；下次文件分享时清理过期批次。
单文件最多 64 MiB、单次最多 10 个文件 / 128 MiB，专属缓存总量最多 512 MiB。
面板成功展示不等于完成分享：等待关闭事件并结合系统完成事件返回结果，退出 engine 时返回未知状态。
这些结果不代表接收应用已完成导入。
多文件使用 ShareKit BATCH 模式，单文件保持 SINGLE；暂停前已在真机完成六图接收及 PDF/TXT 字节校验，
见[非语音真机记录](docs/device-nonvoice-20261020.md)。

## 语音与 OCR

`SpeechRecognizerPlugin.ets` 实现现有 `speech_to_text` 标准通道，申请麦克风权限后
调用 Core Speech Kit 离线识别（`online: 1`）。聊天语音输入和轮流收音/播放的
语音对话使用同一个共享租约。分段结果累计回传，最终结果、取消、错误或 24 秒
超时均结束录音；后台退出当前会话，旧会话回调不能修改新会话。

`../ohos_plugins/flutter_tts` 替换空实现，使用系统离线音色朗读，支持系统音色查询、
语速、音量和音调。长文本分段，等待真实播放结束后再播下一段；停止、后台、
超时和 engine 销毁会结束当前播放。离线服务或指定语言不可用会返回错误，不自动
改用联网语音。系统声音路径不创建 Sherpa 播放器。Sherpa 1.13.8 现已接入官方 OHOS arm64
C API，支持按需下载 Baker 和导入兼容的 Matcha 模型。合成在 isolate 内执行，缓存 WAV，
通过原生 AVPlayer 等待真实播放结束；停止、后台、错误及超时会结算并释放播放器和文件。
耳机模式使用通信音频会话，确认识别输入、通信输出及媒体输出均为有线/USB/SCO 耳机才
开放说话打断；A2DP-only、无麦耳机和外放保持轮流模式。断线或失焦立即停止语音，
现有 Dart 轮询进一步暂停整轮请求，不自动切外放继续。实现边界和真机用例见
[语音与恢复说明](docs/voice-recovery.md)。

`OcrService` 在 OHOS 分派到 Core Vision 文字识别；知识库可导入图片，扫描 PDF
使用 PDF Kit 逐页栅格化后 OCR。原文件必须位于应用沙箱，不接受符号链接或路径穿越。
图片最多 20 MiB / 64M 像素，解码最长边 4096；PDF 最多 64 MiB，OCR 最多前 20 页，
每页渲染最长边 3072；正文最多 100 万字符。分页协议返回总页数并保留空白页位置，
混合 PDF 按原页码合并文字层与扫描页。底层兼容全文接口超过页数标注截断，
知识库导入则完整拒绝超过 20 页的 PDF，避免将截断内容当作完整资料。
单次只允许一个识别任务，Dart 等待 2 分钟后按请求 ID 取消，原生完成资源释放前仍拒绝并发。
后台取消和迟到结果不会写入知识库；空白图片返回空串，文件或服务错误明确失败。
ML Kit / pdfx 的 stub 只保留编译导入，OHOS 的 OCR 不经过它们。

## 脚本与资料批量导入

`../ohos_plugins/flutter_js` 使用官方 QuickJS 2026-06-04 源码（MIT），来源、
下载归档 SHA-256 和逐文件摘要保存在 `native/quickjs-source.json`。CMake 从源码
交叉编译 arm64 `libchatai_js.so`，没有预编译第三方二进制或构建时下载。
Dart FFI 在现有独立 isolate 中执行，每次 evaluate 使用独立运行时。
原生层设定时间中断、堆上限和 256 KiB 栈上限，禁用阻塞 Atomics.wait；
正则执行与输出对象的 toString 也受时间中断约束。不安装模块加载器、
quickjs-libc、文件/网络/进程/宿主桥；不执行异步 job 队列。现有脚本审计和用户确认继续生效。
默认 2 秒 / 32 MiB 堆，原生硬上限 10 秒 / 64 MiB 堆、源码及 UTF-8 输出各 4 MiB；
共享核心还有更小的代码、输入和输出字符限制。运行失败返回错误，不回退到无预算引擎。

文件选择器增加系统能力查询、文件夹选择、保留相对路径的沙箱复制和精确副本释放。
`FolderSelection` 目前属于 2-in-1 设备能力，手机通常不具备；应用按运行时能力
显示入口，不申请系统级文件管理权限。不支持的设备保留多选文件和资料 ZIP 导入。
壳声明支持 phone / tablet / 2in1；目前仍仅构建 arm64，未做其他设备形态的真机验收。

知识库导入菜单包含文件、资料 ZIP，以及支持设备上的文件夹。
集合在交给现有文本/PDF/OCR 导入器前先完整检查：最多 1024 条目、256 个文件、
12 层子目录、单文件 64 MiB、总计 128 MiB；ZIP 压缩文件最多 64 MiB。
拒绝链接、特殊文件、路径穿越、大小写冲突和 CRC/大小不一致的 ZIP；解压仅写入
本次专属临时目录。解析结果仍逐文件报告成功/跳过，已成功导入的文档不会因其它
文件解析失败回滚。账号或页面失效后停止后续写入；完成或失败时清理 ZIP 临时副本，
鸿蒙目录副本通过原生精确路径释放，不删除用户源目录。
普通文件、ZIP 和目录共用守卫与导入进度：显示文件数、当前文件和 PDF 页码，支持取消，
已提交的完整文档保留；失败明细可仅重试失败及未处理文件。ZIP/目录副本在明细及重试结束后释放。
取消会等待当前系统 API 返回并释放资源，未提交的文档与分块回滚；账号失效或取消后的迟到结果不入库。
加密、损坏、超限、文件丢失和 OCR 超时等使用固定中文提示，不透传底层异常路径或正文。

模型目录选择仍受设备 FolderSelection 能力和沙箱复制预算约束；手机使用模型 ZIP 或按需下载。


## PDF 原件预览与版本信息

`KnowledgePdfPlugin.ets` 实现共享知识页既有 `aipu/knowledge-pdf` 通道。
「查看原件」仍先按当前账号目录及 SHA-256 校验原 PDF，然后由 PDF Kit
渲染引用所在页，沿用共享页的连续引文高亮与缩放查看。只读取应用沙箱文件，
拒绝链接、路径穿越、非文件及超过 64 MiB 的 PDF；引用页索引上限 1000 页，
页面最长边最多 3072 像素、放大最多 2 倍，输出 PNG 最多 32 MiB。
一次只处理一个预览，所有成功/失败路径释放 packer、像素、页面、文档和文件句柄。
后台或 engine 销毁后丢弃迟到结果；Dart 等待最多 30 秒。超时不代表同步 PDF
原生解析已被强制终止，复杂 PDF 的运行时表现仍需真机验证。

`PackageInfoPlugin.ets` 实现 `package_info_plus` 的标准通道。
「我的」版本号和用户主动勾选反馈诊断时的版本字段来自实际安装包的
`versionName` / `versionCode`，应用名按本地化资源读取；不硬编码版本、不读取
签名信息或其它已安装应用，不申请额外权限。诊断默认关闭，版本信息不可用时
省略该可选字段，反馈仍可提交。应用市场更新跳转/上架分发仍沿用既有边界。

## 验证与真机清单

当前非语音离线入口（普通 Flutter 3.35.7；先安装 pnpm 依赖）：

```sh
# 仓库根目录；FLUTTER_BIN 可省略，此时使用 PATH 中的 Flutter 并校验版本
FLUTTER_BIN=/path/to/flutter-3.35.7/bin/flutter bash chatgpt_flutter_ohos/scripts/test-offline.sh
```

该脚本不调用 HDC，不依赖 DevEco、真实账号或 AI 服务；首次依赖解析可能联网。
对应 GitHub Actions 配置为 `.github/workflows/ohos-offline.yml`。
本轮六项离线增强、验证结果及待测设备边界见[离线回归记录](docs/offline-nonvoice-20261020.md)。
以下分项命令仍可用于单独检查；语音用例不包含在本轮统一离线入口内。

```sh
# 在仓库根目录执行：测试真实 ArkTS 方法体，系统 API 使用受控替身
node --test chatgpt_flutter_ohos/test/native_file_picker.test.cjs chatgpt_flutter_ohos/test/native_directory_picker.test.cjs
node --test chatgpt_flutter_ohos/test/native_image_picker.test.cjs chatgpt_flutter_ohos/test/native_share.test.cjs chatgpt_flutter_ohos/test/native_pdf_package.test.cjs
node --test chatgpt_flutter_ohos/test/native_speech.test.cjs chatgpt_flutter_ohos/test/native_voice_audio.test.cjs chatgpt_flutter_ohos/test/native_ocr.test.cjs chatgpt_flutter_ohos/test/build_release_guard.test.cjs
# 在 ohos_plugins/file_picker 内执行：Dart 通道合同
flutter test
```

真机需检查：选择/取消/立即重试、多选和中文名、超限与错误扩展名、
文件提供方读取失败、备份 ZIP 保存并再次导入、覆盖保存、切换后台及重启、
角色卡/报告内容完整性，以及跨账号切换时的原有操作边界。
图片需补测拍照/相册取消、中文名称、PNG 透明、EXIF 八种方向、HEIC、大图缩放、
相机失败及切换后台；分享需测试取消、完成、目标应用延迟读取、连续分享和进程退出。
语音需检查首次授权/拒绝后重试、离线语音包缺失、中文/英文、分段识别、停止后立即重录、
长文朗读停止、后台打断、服务错误、轮流语音对话及耳机双工/插话/拔出/来电抢占。
模型需检查离线合成性能、内存和音质；恢复需实际终止进程验证确认与跨账号隔离。
OCR 需检查中文图片、旋转照片、
无字图片、扫描 PDF、中途坏页、20 页边界、超大图片、超时取消及取消后重试。
原生单测使用系统 API 替身，不能验证收音/播放质量、真实 OCR 准确率和 PDF 渲染效果。
目录需真机检查能力判断、中文和多层目录、授权失效、提供方拒绝访问、复制中退出、
ZIP 导入后原图/PDF 保留、异常与重试、账号切换及源目录完整性。QuickJS 已有宿主真实
C/FFI/isolate 测试及 UBSan 检测，仍需鸿蒙真机验证动态库装载和工具调用。
本机 ASan 的最小无业务探针也在进入 main 前超时，因此 ASan 检测尚未完成。
调试与 release 构建均使用当前工程配置的本地签名，不代表应用市场发布签名已验收。

## 华为账号登录

已接入 Account Kit 授权码、NestJS 服务端验码和首次验证码绑定流程，
认证依赖注入保留 HUKS 安全存储。Client ID、签名指纹和后端 Secret 尚需实际配置，
当前未完成真实账号授权验收。配置步骤及验证边界见
[HarmonyOS 华为账号登录](docs/huawei-login.md)。

本批真机补测：相册一次选择多图、取消、批内坏图及超限后立即重试；
PDF 引用页、高亮、扫描件、横竖页、损坏/加密文件、后台中断；安装不同版本包后
版本显示是否随安装包更新，以及关闭反馈诊断时不发送版本字段。
原生测试执行实际插件源码但模拟系统 API，不能证明真实 PDF 渲染、相册提供方或设备版本查询已验收。

接口依据：[PhotoViewPicker 官方示例](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-688)，
以及本机 SDK 的 `@ohos.bundle.bundleManager.d.ts` / `@hms.officeservice.pdfservice.d.ts`。
