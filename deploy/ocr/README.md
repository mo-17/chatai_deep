# 服务器 OCR

批量任务、逐页校对、扫描/导出、语义索引、桌面快捷助手与管理后台详见 [OCR 工作台说明](../../docs/ocr-workbench.md)。本轮记录见 `verification/20261020-workbench.json`。

共享 Flutter 核心已在「我的 → 知识库 → 右上角导入 → OCR」接入服务器识别。默认仅本地识别；登录用户明确选择后，本页面的图片和需要 OCR 的整份 PDF 才上传到当前后端。退出页面后不会记住该选择。

文本 PDF、Word、Excel、纯文本仍在本地提取。混合 PDF 只识别缺字页，保留原 PDF 页码与引用位置。现有 Android/iOS/OHOS 端上 OCR 路径保留；标准壳目前有 ML Kit/pdfx 编译 stub，不能将其视为可用的端上 OCR。服务器方式也适用于桌面和 Web。

普通聊天也支持服务器 OCR：从文件入口选择 PNG/JPEG/WebP/BMP 图片，可识别为文字附件；模型不能原生接收 PDF 时，先本地提取，只针对缺字页请求 OCR。每个文件都会通过现有发送确认框说明上传到哪个后端、PDF 整份上传、识别文字会保存并发送给当前模型。取消确认、识别失败、停止发送或账号/配置变化都不会发送迟到文字；原草稿保留。识别文字随 FileBlock 持久化，跨轮历史与重新生成复用已保存文字。已有的多模态图片与原生 PDF 通道不额外上传 OCR。任务工作区也支持对图片和缺字 PDF 页执行 OCR，结果作为工作区资料按需读取，不将全部正文塞入 manifest。

## 组件与限制

- NestJS `src/ocr/` 复用现有 `JwtGuard` 的数据库授权状态，按真实用户隔离任务。
- 独立 Python worker：RapidOCR 3.10.0 / PP-OCRv6 small / ONNX Runtime CPU，线程数 1，单任务执行。固定完整依赖见 `requirements-lock.txt`。
- worker 仅监听 `127.0.0.1:3002`，由内部随机令牌保护；systemd 只允许回环网络，不在运行时下载模型。
- 单文件 8 MiB，PDF 20 页，图片 2400 万像素。识别图最长边 1600 像素；支持 PNG/JPEG/WebP/BMP 与未加密 PDF。HEIC/HEIF 需先转换。
- 返回原页号、识别图片宽高、文本行四点坐标和置信度；坐标相对于识别图片，校对页支持行定位、低置信度提示与按需获取的有界 JPEG 缩略图。
- 全局最多 4 个未完成任务，每账号最多 1 个；每账号每小时最多 20 个、全局每小时最多 120 个。网关还限制同 IP 的上传与轮询频率。
- 单任务最多 180 秒；文字最多 20 万字、4000 行、结果 JSON 最多 2 MiB。客户端最多等待 5 分钟，失败不会静默保存部分 OCR 结果。
- MemoryHigh 512 MiB / MemoryMax 640 MiB / CPUQuota 100%。这是保护上限，识别质量和耗时仍取决于材料。
- 原件保存在 `/run/chatai-ocr` 的随机临时目录；完成、失败、取消后删除。结果仅在内存暂存最多 5 分钟，客户端取回后立即 DELETE 清除。worker 重启会丢弃任务与暂存结果，需要重新识别。
- 取消会杀死当前识别子进程；任务编号由客户端预先生成，取消先于上传到达也会阻止迟到任务。账号/凭据/后端改变或页面退出会取消当前导入，迟到文字不能入库。

## 接口

以下接口均需现有用户 Bearer token，不接受游客标记。

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/uapi/ocr/capabilities` | worker 可用性及文件限制 |
| POST | `/uapi/ocr/jobs/{32位小写十六进制ID}?kind=pdf&pages=2,4` | `application/octet-stream` 上传，图片用 `kind=image` |
| GET | `/uapi/ocr/jobs/{id}` | `queued/running/completed/failed/cancelled`、进度、完成结果 |
| DELETE | `/uapi/ocr/jobs/{id}` | 取消任务并清除原件和结果 |

正常响应沿用 `{code: 0, data: ...}`。不记录原文、文件名或访问令牌。其他用户无法读取、取消或替换同一个任务。

## 本地验证

```bash
python3 -m unittest discover -s deploy/ocr -v
python3.12 -m venv /tmp/chatai-ocr-venv
/tmp/chatai-ocr-venv/bin/pip install -r deploy/ocr/requirements-lock.txt
/tmp/chatai-ocr-venv/bin/python deploy/ocr/warmup.py
pnpm --filter chatgpt_backend exec jest ocr.controller --runInBand
pnpm --filter chatgpt_backend run build
```

Flutter 测试：`server_ocr_client_test`、`knowledge_file_importer_test`、`knowledge_import_operation_test`、`knowledge_import_ui_test`。Web 仍用 `chatgpt_flutter/tool/build_web.dart` 构建。

聊天回归：`chat_attachment_ocr_test`、`conversation_generation_preparation_test`、`attachment_preflight_progress_test`、`retry_attachment_restorer_test`。真实 Chrome HTTP 测试位于 `chatgpt_flutter/test/browser_ocr_test.dart`，使用仅回环的 `tool/web/ocr_fixture.py` 验证上传、UTF8 和取消合同；该 fixture 不识别文件、不转发请求、不用于部署。模型质量与生产 HTTPS 的真实识别证据单独记录。

原生构建已检查 Android Release、iOS 模拟器、macOS Release、OHOS Release HAP。Android 首次 Release 构建应沿用 `deploy/flutter/build-release.sh` 的做法，让 Flutter 重新生成 Release 插件注册文件；`--no-pub` 可能残留 `integration_test` 注册。OHOS 需先激活 mise 并解析依赖，使用 `chatgpt_flutter_ohos/scripts/build-release.sh` 核验 AOT/原生库/许可证。其 `sqflite_common` 显式固定到与现有 OHOS SQLite 一致的 Git 提交，解决共享 Web 依赖的 hosted/Git 来源冲突。

## 部署到已有 Ubuntu 服务器

`install.sh` 仅用于本仓库 `deploy/ubuntu` 已管理的服务器，创建独立 `chatai-ocr` 用户、只读版本目录及 systemd 单元。服务共享凭据由服务器生成在 `/etc/chatai-deep/ocr.env`，不要提交或复制到客户端。

```bash
sudo bash deploy/ocr/install.sh
```

正常新发布直接包含 `OcrModule`。API 需要 systemd drop-in：

```ini
[Service]
EnvironmentFile=/etc/chatai-deep/ocr.env
```

本次线上增量部署使用 `apply-api.sh PAYLOAD EXPECTED_APP_MODULE_SHA256`：先核对已部署模块摘要，将当前版本硬链接到新目录，只复制本地构建的 `dist/src/ocr/*.js` 并原子替换模块注册文件；不部署本地其它未上线功能。保留旧发布目录，启动健康检查失败自动切回。这个脚本仅用于第一次增量接入，后续走正常发布流程。

`smoke.cjs` 在实际 backend 工作目录运行，由 systemd 加载已有环境；通过 HTTPS 和两个临时数据库账号验证授权、识别、页码与取消。测试结束删除账号与结果，不输出凭据。`OCR_SMOKE_FIXTURES` 指向生成的非敏感测试材料；`OCR_SMOKE_STRESS=true` 额外执行 20 页中文 PDF。测试材料不来自用户上传文档。

回滚 API：将 `/opt/chatai-deep/current` 原子切回新发布中的 `ocr-previous-release.txt` 所记目录，并重启 `chatai-deep-api`。回滚 worker：切回 `/opt/chatai-deep/ocr/releases/` 的上一目录后重启 `chatai-deep-ocr`。回滚不会删除本地知识库数据。

实测记录见 `verification/`。主机与模型测试不能替代 Android/iOS/OHOS/macOS/Windows 真机上传、页面退出和网络切换验收。

官方模型与许可说明：[RapidOCR](https://github.com/RapidAI/RapidOCR)、[模型来源与许可](https://rapidai.github.io/RapidOCRDocs/main/en/model_licenses/)。
