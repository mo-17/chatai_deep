#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" != run && "${1:-}" != build ]]; then
  echo "用法: bash deploy/flutter/production.sh run -d <设备>" >&2
  echo "      bash deploy/flutter/production.sh build apk --release" >&2
  exit 2
fi

cd "$root_dir/chatgpt_flutter"
exec fvm flutter "$@" --dart-define-from-file="$root_dir/deploy/flutter/production.json"
