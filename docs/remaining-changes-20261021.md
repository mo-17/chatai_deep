# 剩余改动分类与本地提交（2026-10-21）

用户要求“把剩余未提交的改动按功能分类列一下，提交”。沿用先前约束：仅本地提交，不推送。

整理前为 `main`，HEAD `29af8c53e8646b1f9fd215eba5aa8879f2bce569`，暂存区为空，Git 可见的剩余文件共 220 个（118 个已跟踪修改、102 个新文件）。两个既有 stash 保留，没有展开或混入提交。忽略的构建缓存与其他本地资料未纳入范围。

## 功能分类

| 批次 | 分类 | 涉及文件数 | 本地提交 |
| --- | --- | ---: | --- |
| 1 | Web 与跨平台基础适配 | 124 | fa1b8a6e |
| 2 | OCR 服务端、部署与管理端 | 32 | 112d8955 |
| 3 | OCR 客户端、扫描及导出 | 42 | 19a302e5 |
| 4 | 知识库语义索引与混合检索 | 6 | f7fd8004 |
| 5 | 桌面布局及原生快捷助手 | 32 | a0b0e865 |
| 6 | CI、回归兼容与分类记录 | 7 | 本记录所在提交 |

同一文件的不同片段可以出现在多个批次，文件数不能直接相加。共享文件以暂存快照拆分，原工作区内容保留；下面按实际提交路径列出。

### 1. Web 与跨平台基础适配

浏览器文件系统与 IndexedDB 持久化、SQLite Web、图片/路径/文件选择适配、HTTP BrowserClient、JS/TTS 平台隔离、Web 登录及构建入口；同步保留 OHOS 依赖分支。

<details>
<summary>本批路径清单（124 个）</summary>

- `.gitignore`
- `chat_message/lib/widget/default_message_widget.dart`
- `chat_message/pubspec.yaml`
- `chatgpt_app_core/lib/app.dart`
- `chatgpt_app_core/lib/backup/backup_service.dart`
- `chatgpt_app_core/lib/capability/generated_image_save_service.dart`
- `chatgpt_app_core/lib/chat/application/agent_background_execution.dart`
- `chatgpt_app_core/lib/chat/application/agent_workspace_service.dart`
- `chatgpt_app_core/lib/chat/application/assistant_card_persistence.dart`
- `chatgpt_app_core/lib/chat/application/assistant_role_card_asset_store.dart`
- `chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart`
- `chatgpt_app_core/lib/chat/application/attachment_batch_budget.dart`
- `chatgpt_app_core/lib/chat/application/conversation_composer_preparation.dart`
- `chatgpt_app_core/lib/chat/application/conversation_draft_store.dart`
- `chatgpt_app_core/lib/chat/application/creative_file_transfer_gateway.dart`
- `chatgpt_app_core/lib/chat/application/deepseek_file_preview_store.dart`
- `chatgpt_app_core/lib/chat/application/deepseek_file_service.dart`
- `chatgpt_app_core/lib/chat/application/downloadable_tts_models.dart`
- `chatgpt_app_core/lib/chat/application/file_processor.dart`
- `chatgpt_app_core/lib/chat/application/knowledge_file_importer.dart`
- `chatgpt_app_core/lib/chat/application/knowledge_import_collection.dart`
- `chatgpt_app_core/lib/chat/application/knowledge_import_error.dart`
- `chatgpt_app_core/lib/chat/application/ocr_service.dart`
- `chatgpt_app_core/lib/chat/application/office_text_extractor.dart`
- `chatgpt_app_core/lib/chat/application/ohos_image_recovery.dart`
- `chatgpt_app_core/lib/chat/application/retry_attachment_restorer.dart`
- `chatgpt_app_core/lib/chat/application/safe_url_fetcher.dart`
- `chatgpt_app_core/lib/chat/application/sherpa_onnx_read_aloud_service.dart`
- `chatgpt_app_core/lib/chat/application/sherpa_onnx_read_aloud_service_native.dart`
- `chatgpt_app_core/lib/chat/application/sherpa_onnx_read_aloud_service_web.dart`
- `chatgpt_app_core/lib/chat/application/sherpa_onnx_tts_assets.dart`
- `chatgpt_app_core/lib/chat/application/story_room_attachments.dart`
- `chatgpt_app_core/lib/chat/application/user_sherpa_onnx_tts_models.dart`
- `chatgpt_app_core/lib/chat/application/workspace_attachment_processor.dart`
- `chatgpt_app_core/lib/chat/ui/block_message_content.dart`
- `chatgpt_app_core/lib/dao/ai_settings_dao.dart`
- `chatgpt_app_core/lib/dao/apk_update_dao.dart`
- `chatgpt_app_core/lib/dao/chat/backend_chat_service.dart`
- `chatgpt_app_core/lib/dao/update_abi.dart`
- `chatgpt_app_core/lib/dao/update_abi_native.dart`
- `chatgpt_app_core/lib/dao/update_abi_web.dart`
- `chatgpt_app_core/lib/db/agent_workflow_dao.dart`
- `chatgpt_app_core/lib/db/database_platform.dart`
- `chatgpt_app_core/lib/db/database_platform_native.dart`
- `chatgpt_app_core/lib/db/database_platform_web.dart`
- `chatgpt_app_core/lib/db/hi_db_manager.dart`
- `chatgpt_app_core/lib/db/semantic_chat_summary_dao.dart`
- `chatgpt_app_core/lib/db/story_template_translation_task_dao.dart`
- `chatgpt_app_core/lib/knowledge/knowledge_library.dart`
- `chatgpt_app_core/lib/knowledge/knowledge_sync.dart`
- `chatgpt_app_core/lib/knowledge/knowledge_transfer.dart`
- `chatgpt_app_core/lib/model/story_persona_model.dart`
- `chatgpt_app_core/lib/model/story_room_model.dart`
- `chatgpt_app_core/lib/pages/assistant_edit_page.dart`
- `chatgpt_app_core/lib/pages/assistant_list_page.dart`
- `chatgpt_app_core/lib/pages/backup_restore_page.dart`
- `chatgpt_app_core/lib/pages/conversation_list_page.dart`
- `chatgpt_app_core/lib/pages/feedback_page.dart`
- `chatgpt_app_core/lib/pages/generated_image_album_page.dart`
- `chatgpt_app_core/lib/pages/knowledge_base_page.dart`
- `chatgpt_app_core/lib/pages/knowledge_pdf_page.dart`
- `chatgpt_app_core/lib/pages/knowledge_report_page.dart`
- `chatgpt_app_core/lib/pages/story_persona_edit_page.dart`
- `chatgpt_app_core/lib/pages/story_room_page.dart`
- `chatgpt_app_core/lib/pages/story_workbench_page.dart`
- `chatgpt_app_core/lib/pages/tts_model_manager_page.dart`
- `chatgpt_app_core/lib/platform/app_file_picker.dart`
- `chatgpt_app_core/lib/platform/app_file_picker_web.dart`
- `chatgpt_app_core/lib/platform/app_paths.dart`
- `chatgpt_app_core/lib/platform/app_paths_web.dart`
- `chatgpt_app_core/lib/platform/picked_file.dart`
- `chatgpt_app_core/lib/platform/zlib_decoder.dart`
- `chatgpt_app_core/lib/platform/zlib_decoder_web.dart`
- `chatgpt_app_core/lib/skill/js_runtime_service.dart`
- `chatgpt_app_core/lib/skill/js_runtime_service_native.dart`
- `chatgpt_app_core/lib/skill/js_runtime_service_web.dart`
- `chatgpt_app_core/lib/storage/local_media_references.dart`
- `chatgpt_app_core/lib/storage/ohos_storage_service.dart`
- `chatgpt_app_core/lib/sync/cloud_sync_client.dart`
- `chatgpt_app_core/lib/sync/local_sync_service.dart`
- `chatgpt_app_core/lib/update/app_update_controller.dart`
- `chatgpt_app_core/lib/util/account_resource_scope.dart`
- `chatgpt_app_core/lib/util/assistant_avatar_bytes.dart`
- `chatgpt_app_core/lib/util/avatar_asset_service.dart`
- `chatgpt_app_core/lib/util/bounded_file_reader.dart`
- `chatgpt_app_core/lib/util/managed_attachment_store.dart`
- `chatgpt_app_core/lib/util/public_network_address_policy.dart`
- `chatgpt_app_core/lib/voice/speech_input.dart`
- `chatgpt_app_core/lib/voice/voice_audio_route.dart`
- `chatgpt_app_core/lib/widget/assistant_avatar.dart`
- `chatgpt_app_core/lib/widget/conversation_widget.dart`
- `chatgpt_app_core/lib/widget/message_input_widget.dart`
- `chatgpt_app_core/pubspec.yaml`
- `chatgpt_app_core/test/browser_picked_bytes_test.dart`
- `chatgpt_app_core/test/web_zlib_decoder_test.dart`
- `chatgpt_flutter/README.md`
- `chatgpt_flutter/WEB.md`
- `chatgpt_flutter/lib/main.dart`
- `chatgpt_flutter/lib/story_template_background_workmanager.dart`
- `chatgpt_flutter/pubspec.lock`
- `chatgpt_flutter/pubspec.yaml`
- `chatgpt_flutter/test/browser_settings_test.dart`
- `chatgpt_flutter/tool/build_web.dart`
- `chatgpt_flutter/tool/web/smoke_server.py`
- `chatgpt_flutter/web/index.html`
- `chatgpt_flutter/web/manifest.json`
- `chatgpt_flutter_ohos/pubspec.lock`
- `chatgpt_flutter_ohos/pubspec.yaml`
- `login_sdk/lib/dao/backend_host.dart`
- `login_sdk/lib/pages/login_page.dart`
- `login_sdk/lib/platform/app_file_image.dart`
- `login_sdk/lib/platform/app_io.dart`
- `login_sdk/lib/platform/app_io_native.dart`
- `login_sdk/lib/platform/app_io_web.dart`
- `login_sdk/lib/platform/indexed_db_file_persistence.dart`
- `login_sdk/lib/platform/persistent_memory_file_system.dart`
- `login_sdk/pubspec.yaml`
- `login_sdk/test/browser_storage_test.dart`
- `login_sdk/test/persistent_memory_file_system_test.dart`
- `openai_flutter/lib/http/ai_http.dart`
- `openai_flutter/lib/http/owned_client.dart`
- `openai_flutter/lib/http/owned_client_native.dart`
- `openai_flutter/lib/http/owned_client_web.dart`
- `openai_flutter/test/browser_http_test.dart`

</details>

### 2. OCR 服务端、部署与管理端

带认证的 OCR API、内部有界 Worker、配额与管理统计、Next.js 管理页、部署/回滚脚本、OCR CI 及已有脱敏验收记录。

<details>
<summary>本批路径清单（32 个）</summary>

- `.github/workflows/ocr.yml`
- `chatgpt_admin/src/app/(dashboard)/ocr/page.tsx`
- `chatgpt_admin/src/components/layout/Sidebar.tsx`
- `chatgpt_admin/src/components/layout/Topbar.tsx`
- `chatgpt_backend/src/app.module.ts`
- `chatgpt_backend/src/ocr/ocr-admin.controller.spec.ts`
- `chatgpt_backend/src/ocr/ocr-admin.controller.ts`
- `chatgpt_backend/src/ocr/ocr.controller.spec.ts`
- `chatgpt_backend/src/ocr/ocr.controller.ts`
- `chatgpt_backend/src/ocr/ocr.module.ts`
- `chatgpt_backend/src/ocr/ocr.service.ts`
- `chatgpt_flutter/README.md`
- `deploy/ocr/.gitignore`
- `deploy/ocr/README.md`
- `deploy/ocr/activate-workbench.sh`
- `deploy/ocr/apply-api.sh`
- `deploy/ocr/chatai-deep-ocr.service`
- `deploy/ocr/engine.py`
- `deploy/ocr/install.sh`
- `deploy/ocr/prepare-workbench.sh`
- `deploy/ocr/requirements-lock.txt`
- `deploy/ocr/requirements.txt`
- `deploy/ocr/server.py`
- `deploy/ocr/smoke-workbench.cjs`
- `deploy/ocr/smoke.cjs`
- `deploy/ocr/test_engine_preview.py`
- `deploy/ocr/test_worker.py`
- `deploy/ocr/verification/20261020-chat.json`
- `deploy/ocr/verification/20261020-workbench-admin-ui.jpg`
- `deploy/ocr/verification/20261020-workbench.json`
- `deploy/ocr/verification/20261020.json`
- `deploy/ocr/warmup.py`

</details>

### 3. OCR 客户端、扫描及导出

经确认上传的知识库/聊天/任务附件 OCR、任务恢复与校对、置信度/坐标/预览、扫描裁边及透视处理、可搜索 PDF/表格导出、原生中文 OCR 和浏览器回归。包含此前仅归档的 PDF 横页修复。

<details>
<summary>本批路径清单（42 个）</summary>

- `chatgpt_app_core/lib/chat/application/agent_workspace_service.dart`
- `chatgpt_app_core/lib/chat/application/attachment_ocr.dart`
- `chatgpt_app_core/lib/chat/application/conversation_attachment_ocr.dart`
- `chatgpt_app_core/lib/chat/application/conversation_composer_preparation.dart`
- `chatgpt_app_core/lib/chat/application/conversation_generation_service.dart`
- `chatgpt_app_core/lib/chat/application/document_scan.dart`
- `chatgpt_app_core/lib/chat/application/file_processor.dart`
- `chatgpt_app_core/lib/chat/application/knowledge_file_importer.dart`
- `chatgpt_app_core/lib/chat/application/ocr_export.dart`
- `chatgpt_app_core/lib/chat/application/ocr_task_center.dart`
- `chatgpt_app_core/lib/chat/application/pdf_ocr_result.dart`
- `chatgpt_app_core/lib/chat/application/server_ocr_client.dart`
- `chatgpt_app_core/lib/chat/application/workspace_attachment_processor.dart`
- `chatgpt_app_core/lib/db/agent_workspace_dao.dart`
- `chatgpt_app_core/lib/db/ocr_task_dao.dart`
- `chatgpt_app_core/lib/pages/agent_workspace_page.dart`
- `chatgpt_app_core/lib/pages/conversation_page.dart`
- `chatgpt_app_core/lib/pages/document_scan_page.dart`
- `chatgpt_app_core/lib/pages/knowledge_base_page.dart`
- `chatgpt_app_core/lib/pages/my_page.dart`
- `chatgpt_app_core/lib/pages/ocr_review_page.dart`
- `chatgpt_app_core/lib/pages/ocr_table_export_page.dart`
- `chatgpt_app_core/lib/pages/ocr_task_center_page.dart`
- `chatgpt_app_core/lib/widget/message_input_widget.dart`
- `chatgpt_app_core/pubspec.yaml`
- `chatgpt_app_core/test/chat_attachment_ocr_test.dart`
- `chatgpt_app_core/test/conversation_generation_preparation_test.dart`
- `chatgpt_app_core/test/knowledge_file_importer_test.dart`
- `chatgpt_app_core/test/knowledge_import_ui_test.dart`
- `chatgpt_app_core/test/ocr_review_page_test.dart`
- `chatgpt_app_core/test/ocr_task_center_test.dart`
- `chatgpt_app_core/test/office_attachment_integration_test.dart`
- `chatgpt_app_core/test/scan_export_test.dart`
- `chatgpt_app_core/test/server_ocr_client_test.dart`
- `chatgpt_app_core/test/workspace_ocr_test.dart`
- `chatgpt_flutter/integration_test/android_device_smoke_test.dart`
- `chatgpt_flutter/integration_test/android_native_ocr_test.dart`
- `chatgpt_flutter/pubspec.lock`
- `chatgpt_flutter_ohos/pubspec.lock`
- `chatgpt_flutter/test/browser_ocr_test.dart`
- `chatgpt_flutter/test/browser_ocr_storage_test.dart`
- `chatgpt_flutter/tool/web/ocr_fixture.py`

</details>

### 4. 知识库语义索引与混合检索

显式启用的 Embedding 配置、受限批量索引、账号/配置变化保护、本地检索回退、融合搜索及设置页。

<details>
<summary>本批路径清单（6 个）</summary>

- `chatgpt_app_core/lib/knowledge/knowledge_repository.dart`
- `chatgpt_app_core/lib/knowledge/semantic_embedding.dart`
- `chatgpt_app_core/lib/pages/knowledge_assistant_page.dart`
- `chatgpt_app_core/lib/pages/knowledge_base_page.dart`
- `chatgpt_app_core/lib/pages/semantic_knowledge_settings_page.dart`
- `chatgpt_app_core/test/semantic_embedding_test.dart`

</details>

### 5. 桌面布局及原生快捷助手

宽屏导航/会话分栏、Enter 与 Shift+Enter、右键菜单、Windows 数据目录迁移、macOS/Windows 托盘与截图快捷助手、构建配置和桌面专项测试。

<details>
<summary>本批路径清单（32 个）</summary>

- `chatgpt_app_core/lib/app.dart`
- `chatgpt_app_core/lib/db/desktop_database_path.dart`
- `chatgpt_app_core/lib/db/hi_db_manager.dart`
- `chatgpt_app_core/lib/pages/bottom_navigator.dart`
- `chatgpt_app_core/lib/pages/conversation_list_page.dart`
- `chatgpt_app_core/lib/pages/desktop_assistant_page.dart`
- `chatgpt_app_core/lib/pages/my_page.dart`
- `chatgpt_app_core/lib/platform/desktop_quick_assistant.dart`
- `chatgpt_app_core/lib/widget/conversation_widget.dart`
- `chatgpt_app_core/lib/widget/desktop_layout.dart`
- `chatgpt_app_core/lib/widget/message_input_widget.dart`
- `chatgpt_app_core/test/desktop_database_path_test.dart`
- `chatgpt_app_core/test/desktop_layout_test.dart`
- `chatgpt_app_core/test/desktop_message_input_test.dart`
- `chatgpt_app_core/test/desktop_quick_assistant_test.dart`
- `chatgpt_flutter/DESKTOP.md`
- `chatgpt_flutter/README.md`
- `chatgpt_flutter/macos/Podfile`
- `chatgpt_flutter/macos/Podfile.lock`
- `chatgpt_flutter/macos/Runner.xcodeproj/project.pbxproj`
- `chatgpt_flutter/macos/Runner/AppDelegate.swift`
- `chatgpt_flutter/macos/Runner/DebugProfile.entitlements`
- `chatgpt_flutter/macos/Runner/MainFlutterWindow.swift`
- `chatgpt_flutter/macos/Runner/Release.entitlements`
- `chatgpt_flutter/tool/windows_sqlite_path.dart`
- `chatgpt_flutter/windows/CMakeLists.txt`
- `chatgpt_flutter/windows/runner/CMakeLists.txt`
- `chatgpt_flutter/windows/runner/desktop_assistant.cpp`
- `chatgpt_flutter/windows/runner/desktop_assistant.h`
- `chatgpt_flutter/windows/runner/flutter_window.cpp`
- `chatgpt_flutter/windows/runner/flutter_window.h`
- `chatgpt_flutter/windows/runner/main.cpp`

</details>

### 6. CI、回归兼容与分类记录

Web/桌面 GitHub Actions；备份版本断言跟随当前格式号；补充分类清单，并更新首轮 PDF 补丁归档状态。

<details>
<summary>本批路径清单（7 个）</summary>

- `.github/workflows/desktop.yml`
- `.github/workflows/web.yml`
- `chatgpt_app_core/test/backend_selection_backup_transfer_test.dart`
- `chatgpt_flutter/README.md`
- `docs/android-device-debug-20261021-patches/README.md`
- `docs/android-device-debug-20261021.md`
- `docs/remaining-changes-20261021.md`

</details>

## 本轮检查与边界

- Flutter 核心专项：253 项通过；最初另有依赖 `R2D_SQLITE_ROOT` / `R2D_SQLITE_NONCE` 的备份迁移夹具初始化失败。按既有契约创建独占临时 SQLite 目录及标记后，该组 18 项单独通过。合计覆盖 271 项，不能将首次失败日志写成全绿。
- 浏览器与文件持久化：内存文件系统 4、真实 Chrome IndexedDB 1、设置存储 2、流式 HTTP/取消/错误 3、OCR 上传/取消/校对与存储 5，共 15 项通过。HTTP 只连接本机确定性夹具，未调用生产 OCR 或真实模型。
- OCR 后端 HTTP 合约 8/8 通过；Nest 构建、OCR 范围 ESLint、管理端全量 lint 通过。为满足检查，仅补齐两份新 OCR 测试的请求/服务器类型及 Promise mock，并统一格式，未改生产逻辑。
- Python Worker 9 项通过；实际引擎预览 1 项因当前 Python 未安装固定 OCR 运行依赖而跳过。四份部署脚本 `bash -n` 通过，没有执行部署脚本。
- Web release 构建通过；输出包含一条字体族配置提示，本次没有把该提示当成验收成功的 GUI 证据。
- 标准 Flutter shell 离线 `pub get --enforce-lockfile --no-example` 通过，锁文件未变化。
- Web、OCR、语义检索及桌面各阶段的核心源码快照均无分析器 error；当前核心全量分析仍有 15 条 warning，因此不报告为零诊断。
- 每批暂存路径与明确清单一致，暂存字节与已审阅快照一致；`git diff --cached --check`、Gitleaks、提交钩子均通过。
- 本轮没有重新执行 Windows 编译/GUI、macOS GUI/签名、OHOS 真机、真实 Embedding 质量或远端 GitHub Actions。已有 `deploy/ocr/verification/20261020*.json` 为历史证据，不作为本轮重新验证的声明。

## 完整性约束

对整理前 220 个路径记录并复核 SHA-256，除两份 OCR 测试的类型/格式修复及关联说明文档更新外，工作区源码逐字节保留。CI 与分类记录最后提交，最终核对暂存区、工作区、stash、worktree、远端配置及远端跟踪引用；不执行推送。
