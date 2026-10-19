# 鸿蒙端（Flutter OH 3.35）

共享业务位于 `../chatgpt_app_core`。本壳使用 `.fvmrc` 中的
`flutter-oh-3.35.7`，不要用普通 Flutter SDK 构建 HAP。

## 构建

在本目录执行，非交互 shell 也需要显式加载 mise 环境：

```sh
eval "$(mise activate zsh --shims)"
eval "$(mise env -s zsh)"
fvm flutter pub get
fvm flutter build hap --release --dart-define-from-file=../deploy/flutter/production.json
```

`mise.toml` 配置 DevEco、HOS_SDK_HOME 和工具路径。生产构建必须显式指定
公网 HTTPS 后端；构建成功不代表已联网或完成真机验收。
当前本机 SDK 是 `002ff8966a` 本地快照、Dart 3.9.2，添加了
`3.35.7-ohos-local` 本地标签用于修复版本识别；它不是上游正式发布标签。
新机器应安装具有完整版本信息的 Flutter OH 3.35 SDK，避免手动改写版本缓存。

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
相机结果 -1 表示未返回图片；其余系统异常明确报错。未实现多图选择和进程被杀后的选择恢复。

`../ohos_plugins/share_plus` 替换分享 stub，使用 ShareKit 分享文本和应用沙箱内文件。
聊天转发恢复系统分享；创作资料导出可使用文件分享。角色卡和报告仍保留上一批的系统保存流程。
内存 XFile 需调用方先保存为本地文件；不接受沙箱外文件、路径穿越或符号链接。

分享副本与页面临时文件独立，保留 24 小时；下次文件分享时清理过期批次。
单文件最多 64 MiB、单次最多 10 个文件 / 128 MiB，专属缓存总量最多 512 MiB。
面板成功展示不等于完成分享：等待关闭事件并结合系统完成事件返回结果，退出 engine 时返回未知状态。
这些结果不代表接收应用已完成导入。

OCR/扫描 PDF、目录递归导入、语音和 JS 执行尚未补齐，相关平台守卫继续生效。
TTS/JS stub 的 API 补齐只解决编译，不代表这些功能可用。

## 验证与真机清单

```sh
# 在仓库根目录执行：测试真实 ArkTS 方法体，系统 API 使用受控替身
node --test chatgpt_flutter_ohos/test/native_file_picker.test.cjs
node --test chatgpt_flutter_ohos/test/native_image_picker.test.cjs chatgpt_flutter_ohos/test/native_share.test.cjs
# 在 ohos_plugins/file_picker 内执行：Dart 通道合同
flutter test
```

真机需检查：选择/取消/立即重试、多选和中文名、超限与错误扩展名、
文件提供方读取失败、备份 ZIP 保存并再次导入、覆盖保存、切换后台及重启、
角色卡/报告内容完整性，以及跨账号切换时的原有操作边界。
图片需补测拍照/相册取消、中文名称、PNG 透明、EXIF 八种方向、HEIC、大图缩放、
相机失败及切换后台；分享需测试取消、完成、目标应用延迟读取、连续分享和进程退出。
调试与 release 构建均使用当前工程配置的本地签名，不代表应用市场发布签名已验收。
