#!/usr/bin/env bash
# 在 Ubuntu 服务器或相同 CPU 架构的 Linux 构建机上执行。
set -Eeuo pipefail
umask 022
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $# -eq 2 ]] || { echo '用法：bash build.sh <源码目录> <空的构建目录>' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { echo '必须在 Linux 构建，不能上传 macOS node_modules。' >&2; exit 1; }
[[ $(node -p 'process.versions.node.split(".")[0]') == 22 ]] || { echo '需要 Node.js 22。' >&2; exit 1; }
[[ $(pnpm --version) == 10.12.4 ]] || { echo '需要 pnpm 10.12.4。' >&2; exit 1; }
source_dir=$(cd -- "$1" && pwd)
mkdir -p -- "$2"
release_dir=$(cd -- "$2" && pwd)
[[ -z $(ls -A -- "$release_dir") ]] || { echo '构建目录必须为空。' >&2; exit 1; }
archive=$(mktemp /tmp/chatai-source.XXXXXXXX.tgz)
# package.py 拒绝覆盖；mktemp 只用于保留唯一名称。
rm -- "$archive"
trap 'rm -f -- "$archive"' EXIT
python3 "$SCRIPT_DIR/package.py" source "$source_dir" "$archive"
tar --no-same-owner -xzf "$archive" -C "$release_dir"
cd -- "$release_dir"
export CI=true HUSKY=0 NEXT_TELEMETRY_DISABLED=1
export CHATAI_LOW_MEMORY_BUILD=true NEXT_PUBLIC_BACKEND=http://127.0.0.1:3000
export NODE_OPTIONS="--max-old-space-size=${CHATAI_BUILD_HEAP_MB:-1024}"
[[ ${CHATAI_BUILD_HEAP_MB:-1024} =~ ^[1-9][0-9]{2,3}$ ]] || { echo 'CHATAI_BUILD_HEAP_MB 必须是 3～4 位正整数。' >&2; exit 1; }
pnpm install --frozen-lockfile --child-concurrency=1 --network-concurrency=4
# @source 扫描库内类名；目录缺失时 Tailwind 仍会构建成功，必须提前拒绝。
python3 deploy/ubuntu/package.py style-source "$release_dir"
pnpm --filter chatgpt_backend run build
# webpack + 单 worker，避免在 2 GB 服务器并行编译两个包。
pnpm --filter chatgpt_admin exec next build --webpack
# next.config.ts 允许跳过构建类型错误，因此独立 typecheck 必须通过。
pnpm --filter chatgpt_admin run typecheck
python3 - <<'PY'
import json, platform
from pathlib import Path
Path('ubuntu-release.json').write_text(json.dumps({
    'format': 1, 'platform': platform.system().lower(), 'arch': platform.machine(),
    'nodeMajor': 22, 'backend': 'http://127.0.0.1:3000',
}, indent=2) + '\n')
PY
python3 deploy/ubuntu/package.py verify "$release_dir"
echo "构建完成：$release_dir"
