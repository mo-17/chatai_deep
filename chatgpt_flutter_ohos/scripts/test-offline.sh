#!/usr/bin/env bash
# 主机回归：不调用 hdc、不安装 HAP，不依赖账号、模型服务或 DevEco。
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${FLUTTER_BIN:-}" ]]; then
  flutter_bin="$FLUTTER_BIN"
elif command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
else
  flutter_bin="$repo_root/chatgpt_app_core/.fvm/flutter_sdk/bin/flutter"
fi
node_bin="${NODE_BIN:-node}"
sdk_version="$("$flutter_bin" --version --machine)"
"$node_bin" -e '
const sdk = JSON.parse(process.argv[1]);
if (sdk.frameworkVersion !== "3.35.7") {
  console.error("请通过 FLUTTER_BIN 指定宿主 Flutter 3.35.7，与 CI 和 .fvmrc 保持一致");
  process.exit(1);
}
console.log(`Host Flutter ${sdk.frameworkVersion}`);
' "$sdk_version"
cd "$repo_root"
"$node_bin" --test \
  chatgpt_flutter_ohos/test/native_file_picker.test.cjs \
  chatgpt_flutter_ohos/test/native_storage.test.cjs \
  chatgpt_flutter_ohos/test/native_directory_picker.test.cjs \
  chatgpt_flutter_ohos/test/native_image_picker.test.cjs \
  chatgpt_flutter_ohos/test/native_share.test.cjs \
  chatgpt_flutter_ohos/test/native_ocr.test.cjs \
  chatgpt_flutter_ohos/test/native_pdf_package.test.cjs \
  chatgpt_flutter_ohos/test/native_secure_storage.test.cjs \
  chatgpt_flutter_ohos/test/native_huawei_login.test.cjs \
  chatgpt_flutter_ohos/test/build_release_guard.test.cjs
(
  cd chatgpt_app_core
  "$flutter_bin" pub get --no-example
  "$flutter_bin" analyze --no-pub \
    lib/chat/application/knowledge_file_importer.dart \
    lib/chat/application/import_operation.dart \
    lib/chat/application/knowledge_import_error.dart \
    lib/chat/application/ocr_service.dart \
    lib/chat/application/ohos_ocr.dart \
    lib/chat/application/pdf_ocr_result.dart \
    lib/pages/knowledge_base_page.dart \
    lib/widget/knowledge_import_progress_dialog.dart \
    lib/db/knowledge_dao.dart lib/knowledge/knowledge_library.dart \
    lib/storage lib/pages/storage_management_page.dart lib/pages/my_page.dart
  "$flutter_bin" test --no-pub --concurrency=1 --reporter expanded \
    test/knowledge_file_importer_test.dart test/knowledge_import_operation_test.dart \
    test/knowledge_import_ui_test.dart test/knowledge_import_collection_test.dart \
    test/ohos_ocr_test.dart test/ocr_service_test.dart \
    test/knowledge_workbench_test.dart test/office_attachment_integration_test.dart \
    test/ohos_storage_test.dart
)
for package in file_picker image_picker share_plus; do
  (
    cd "ohos_plugins/$package"
    "$flutter_bin" pub get --no-example
    "$flutter_bin" analyze --no-pub
    "$flutter_bin" test --no-pub --reporter expanded
  )
done
