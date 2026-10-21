## Tips

服务器 OCR 已接入知识库导入，支持图片和扫描 PDF，使用方式、部署限制与验收记录见 [服务器 OCR](../deploy/ocr/README.md)。
这是慕课网官方实战课【[ChatGPT + Flutter快速开发多端聊天机器人App](https://coding.imooc.com/class/672.html)】的项目源码，课件，文档。

>课程会不定期更新，建议大家多关注下仓库首页的变更记录以便获得最新的更新内容哦

## 仓库介绍
本仓库对应《[课程项目的主工程](https://coding.imooc.com/class/672.html)》。

>chatgpt_flutter为组件化主工程依赖下面工程才能运行：

```bash
  # 组件化配置
  login_sdk:
    path: '../login_sdk'
  hi_download:
    path: '../hi_download'
  chat_message:
    path: '../chat_message'
  openai_flutter:
    path: '../openai_flutter'
```
所以需要将主工程和上述组件化工程clone到一个目录下然后才有运行。各组件仓库可以在[课程仓库首页](https://git.imooc.com/coding-672)上进行clone。

## 首次运行

Flutter Web 的本地运行、静态构建、后端配置及浏览器能力边界见 [Web 端说明](WEB.md)。

登录后，点「我的」→「AI 服务设置」，选择服务商（本地/后端）、填 API key、选模型，保存即可开始对话。

## Android 真机调试

扫描/导出功能仍有此前未跟踪的模块；下述原生 OCR / smoke 测试入口依赖它们。
本次只归档对应测试与 PDF 修复补丁，复现前需独立整合功能基线，见
[补丁范围与前置条件](../docs/android-device-debug-20261021-patches/README.md)。
相机、语音与真实后端的独立 debug 验收入口为
[`tool/android_device_acceptance.dart`](tool/android_device_acceptance.dart)，
结果与未验收项见 [本轮真机验收记录](../docs/android-device-debug-20261021.md)。

使用本目录 `.fvmrc` 指定的 Flutter SDK。手机需开启 USB 调试与 USB 安装；
MIUI 的「USB 安装提示」有自动拒绝倒计时，出现时须在手机点「继续安装」。

```bash
fvm flutter pub get
fvm flutter devices
fvm flutter run -d <device-id>
fvm flutter test --no-pub -d <device-id> integration_test/android_device_smoke_test.dart
```

MIUI 每次重装都可能再次弹出 USB 确认。连续调试可改用
`fvm flutter run --no-pub -d <device-id> --target=integration_test/android_device_smoke_test.dart`，
修改测试后按大写 `R` 热重启，避免反复重装；终端会输出断言结果。

真机 smoke 使用独立偏好前缀验证离线启动、游客导航和 SQLite 恢复，并通过
真实 ML Kit / pdfx 验证中文图片、无文字层的两页扫描 PDF 和指定页识别。
测试不调用真实模型，也不代表相机、麦克风、蓝牙或云同步已验收。

本 shell 已恢复真实 `google_mlkit_text_recognition` / `pdfx` 依赖，并在 Android
捆绑中文识别模型；勿为 iOS 模拟器全局覆盖成 `ohos_stubs`，否则 Android OCR
也会失效。Apple Silicon iOS 模拟器的 ML Kit 链接限制需单独处理；OHOS shell
继续使用自己的依赖覆盖与原生 OCR 桥接。

如需连接电脑上的开发后端，先启动后端，再执行
`adb -s <device-id> reverse tcp:3000 tcp:3000`，并通过
`fvm flutter run -d <device-id> --dart-define=BACKEND_HOST=127.0.0.1:3000`
启动。直接连接真实 AI 服务仍需在应用内配置 API key。

连接项目现有正式后端可使用
`fvm flutter run -d <device-id> --dart-define-from-file=../deploy/flutter/production.json`，
然后用普通 App 账号登录，在「AI 服务设置」选择「后端代理」。游客模式只支持
本地直连；代理模式由服务器保存服务商密钥，手机无需填写 API key。正式后端
配置和构建说明见 [正式后端连接说明](../deploy/flutter/README.md)。

## 课程资料和课件
> 用购课的慕课网账号登录后查看。

- [6-2 带你玩转Flutter http网络操作](https://coding.imooc.com/lesson/672.html#mid=66575)
- [6-5 如何提升Flutter网络交互开发的效率？](https://coding.imooc.com/lesson/672.html#mid=66576)
- [6-7 Flutter异步编程的利器：探索Future和FutureBuilder](https://coding.imooc.com/lesson/672.html#mid=66577)
- [7-8 登录模块接口使用指南](https://coding.imooc.com/lesson/672.html#mid=66818)
- [8-2 Flutter包和插件从入门到实战开发详解](https://coding.imooc.com/lesson/672.html#mid=67234)
- [8-6 Flutter开发不可忽视的技能Steam与StreamBuilder原理大揭秘](https://coding.imooc.com/lesson/672.html#mid=67235)
- [9-2 揭秘ChatGPT API：深入理解并掌握聊天机器人技术](https://coding.imooc.com/lesson/672.html#mid=67510)
- [9-9 提升项目稳定性的秘诀：高效开发单元测试用例](https://coding.imooc.com/lesson/672.html#mid=67512)
- [9-11 探索ChatGPT API：一站式常见问题解答攻略](https://coding.imooc.com/lesson/672.html#mid=67513)
- [11-4 基于sqflite实现数据库的CRUD操作](https://coding.imooc.com/lesson/672.html#mid=68341)
- [12-2 IM数据库需求系分：打造高效且用户友好的数据库架构](https://coding.imooc.com/lesson/672.html#mid=68503)
- [15-3 Flutter状态管理：Provider、Bloc、Redux三大框架深度对比](https://coding.imooc.com/lesson/672.html#mid=69647)
- [15-4 Provider上手指南：从0到1轻松上手Provider](https://coding.imooc.com/lesson/672.html#mid=69649)
- [16-3 Flutter常见性问题优化实践：带你规避常见的性能陷阱](https://coding.imooc.com/lesson/672.html#mid=70413)
- [16-9 极致瘦身优化：通过App Size Tool分析包大小，找出瘦身的空间](https://coding.imooc.com/lesson/672.html#mid=70415)
- [17-2 Android和iOS平台适配FAQ](https://coding.imooc.com/lesson/672.html#mid=70964)
- [17-6 如何适配并运行在Windows平台上](https://coding.imooc.com/lesson/672.html#mid=70966)
- [17-7 sqlite在Windows平台上兼容处理](https://coding.imooc.com/lesson/672.html#mid=70967)