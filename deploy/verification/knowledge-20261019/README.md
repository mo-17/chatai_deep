# 可信知识助手 V1 验收

日期：2026-10-19。Android 候选 `1.0.9+19`，本轮仅客户端代码与文档变更，无后端发布或线上配置变更，没有 Git 提交或推送。

## 自动化范围

- 来源校验：正常/伪造 ID、改写或拼接引文、空引用、JSON 格式、明确资料不足、同名不同文档、中文与英文检索。
- 真实 SQLite：选择范围、不命中时零模型调用、历史恢复、引文快照、删除/变更原文、取消和迟到结果、事务身份失效回滚、账号库隔离、分页/清空、检索预算。
- 页面：首次零请求、提问到原文预览、核验失败不显示模型正文、清空范围禁用发送、后台取消、后端切换隐藏历史与已打开预览、320px / 1.8 倍字体无溢出。
- 生产适配器：以合成 transport 验证固定模型/作用域、系统规则、派发前许可、无自动重试、Token 限额与真实 usage 字段落库；并未发出真实模型请求。
- 原有知识库、文件导入、Web 引用、个人中心回归。

实际通过数量与日志见 [tests.json](tests.json)、[regression.log](regression.log) 和 [core-final.log](core-final.log)；成品版本、大小、SHA-256、历史签名和 ABI 见 [client-candidate.json](client-candidate.json)，本轮运行文件摘要见 [source-manifest.json](source-manifest.json)。

## 验收边界

没有真实模型推理、SMTP、Android 真机安装/覆盖升级、实际 OCR、真实模型冲突理解或回答质量验收；iOS/macOS/HarmonyOS 未构建验收。没有上传 APK 或注册新版本，官网 +16、0% 自动推送、上一全量 +15 保留，仍使用七牛香港共享 IP 和 Cloudflare Free。

候选保留在 `/tmp/chatai-client-knowledge19/aipu-1.0.9-19-universal.apk`，临时目录可能被系统清理。仍为历史 Debug 签名体验包。APK 从当前混合工作区构建，文件摘要只记录本轮相关输入，不代表整个仓库的干净 Git 发布快照。

使用与边界说明见 [可信知识助手](../../../docs/trusted-knowledge-assistant.md)。
