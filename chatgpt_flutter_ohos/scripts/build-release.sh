#!/usr/bin/env bash
# 本地 SDK 的 Hvigor 插件会吞掉 assemble 异常；先独立编译，再核验 HAP 中的 AOT。
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-../deploy/flutter/production.json}"
version_file="$(mktemp)"
trap 'rm -f "$version_file"' EXIT
fvm flutter --version --machine > "$version_file"
defines="$(python3 - "$config" "$version_file" <<'PY'
import base64, json, sys
with open(sys.argv[1]) as f:
    config = json.load(f)
with open(sys.argv[2]) as f:
    version = json.load(f)
for key, source in [('FLUTTER_VERSION', 'frameworkVersion'), ('FLUTTER_CHANNEL', 'channel'),
                    ('FLUTTER_GIT_URL', 'repositoryUrl'), ('FLUTTER_FRAMEWORK_REVISION', 'frameworkRevision'),
                    ('FLUTTER_ENGINE_REVISION', 'engineRevision'), ('FLUTTER_DART_VERSION', 'dartSdkVersion')]:
    value = str(version[source])
    if key.endswith('_REVISION'):
        value = value[:10]
    config[key] = value
print(','.join(base64.b64encode(f'{k}={str(v).lower() if isinstance(v, bool) else v}'.encode()).decode() for k, v in config.items()))
PY
)"
fvm flutter assemble --no-version-check \
  --depfile build/ohos/intermediates/flutter/defaultRelease/flutter_build.d \
  --output build/ohos/intermediates/flutter/defaultRelease \
  -dTargetFile=lib/main.dart -dTargetPlatform=ohos -dBuildMode=release \
  -dTrackWidgetCreation=true -dTreeShakeIcons=true -dDartObfuscation=false \
  -dOhosArchs=ohos-arm64 --DartDefines="$defines" ohos_aot_bundle_release_ohos-arm64
# 保存编译产物哈希，不能让打包任务以旧缓存替换它。
aot_hash="$(python3 scripts/verify-hap-aot.py fingerprint build/ohos/intermediates/flutter/defaultRelease/arm64-v8a/app.so)"
fvm flutter build hap --release --no-pub --dart-define-from-file="$config"
python3 scripts/verify-hap-aot.py verify "$aot_hash" build/ohos/hap/entry-default-signed.hap
