# 连续语音 V1 验收记录

日期：2026-10-19。范围：Flutter 普通聊天的连续轮流语音。本轮无后端或线上配置变更，无 Git 提交或推送。

## 通过的检查

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| 语音控制器、输入租约、面板、输入与朗读回归 | 72/72 | 本地注入、Dart 插件及模拟 MethodChannel |
| 普通会话生成页面 | 57/57 | 本地生成管线和 SQLite；含连续语音 3 项 |
| 连续语音页面最终复验 | 3/3（前项子集） | 两轮保存、320×480/1.8 倍字体、后台与路由暂停 |
| 相关运行代码与新增语音测试静态分析 | 无问题 | Flutter analyze |
| Android release 构建 | 成功 | FVM Flutter 3.35.7、生产地址 JSON |
| APK 成品 | 通过 | 版本/架构、历史签名、麦克风权限、RecognitionService query、语音 UI AOT 文案、不含 ONNX 权重 |
| Android 连接设备 | 无 | `adb devices -l` 空列表 |

首次合并回归中的新离线 TTS 单测因未注入播放器失败，已补齐测试替身并在最后 72 项音频批次全部通过。57 个会话页面用例在合并批次均通过；小屏页面测试最后单独复验 3/3。不能把两次重复执行计为额外用例。

候选元数据见 [client-candidate.json](client-candidate.json)，命令与覆盖范围见 [tests.json](tests.json)，本轮运行文件摘要见 [source-manifest.json](source-manifest.json)。构建产物位于 `chatgpt_flutter/build/app/outputs/flutter-apk/app-release.apk`，临时保留副本 `/tmp/chatai-client-voice18/aipu-1.0.8-18-universal.apk`（临时目录可能被系统清理）。仍为原有 Debug 签名体验包。

## 未完成的边界

没有 Android 真机安装、实际识别、发声、耳机/蓝牙、回声、来电或权限原生界面验收；没有 iOS/macOS 运行验收，没有真实模型请求或 SMTP 测试。该版本尚未上传、注册或发布。官网 +16、0% 自动推送及上一全量 +15 保持原状。

本轮测试不能替代全双工或开口打断验收。使用方法、真机清单与发布前步骤见 [连续语音说明](../../../docs/continuous-voice.md)。
