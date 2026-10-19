#!/usr/bin/env bash
set -Eeuo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# == 3 ]] || { echo '用法: build-release.sh <上一版本码> <更新说明> <输出目录>'; exit 2; }
# Flutter 的 split-per-abi 会给版本码增加 1000/2000/4000，导致直发更新接口
# 把 2016 误判为高于后续 17。逐架构构建可保持所有 direct 包的同一版本码。
stage_dir=$(mktemp -d /tmp/chatai-release-build.XXXXXXXX)
trap 'rm -rf -- "$stage_dir"' EXIT
cd "$root_dir/chatgpt_flutter"
output_dir="$root_dir/chatgpt_flutter/build/app/outputs/flutter-apk"
# 首个 release 构建让工具链重建原生插件注册；--no-pub 可能复用测试态的 integration_test 注册。
fvm flutter build apk --release --dart-define-from-file="$root_dir/deploy/flutter/production.json"
cp "$output_dir/app-release.apk" "$stage_dir/app-release.apk"
for mapping in arm64-v8a:android-arm64 armeabi-v7a:android-arm x86_64:android-x64; do
  abi=${mapping%%:*}
  target=${mapping#*:}
  fvm flutter build apk --release --target-platform "$target" --no-pub --dart-define-from-file="$root_dir/deploy/flutter/production.json"
  cp "$output_dir/app-release.apk" "$stage_dir/app-$abi-release.apk"
done
# 默认 app-release.apk 始终保留可兼容全部架构的通用包。
cp "$stage_dir/app-release.apk" "$output_dir/app-release.apk"
python3 "$root_dir/deploy/flutter/release-manifest.py" --apk-dir "$stage_dir" --previous-build "$1" --notes "$2" --output "$3"
