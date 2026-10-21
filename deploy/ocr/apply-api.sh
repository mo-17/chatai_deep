#!/usr/bin/env bash
# 对现有发布做增量 OCR 接入：保留原模块、数据库、管理端；不部署本地其它功能。
# payload/backend-ocr 为本地 nest build 的 dist/src/ocr（仅 JS）。
set -Eeuo pipefail
[[ $EUID -eq 0 && $# == 2 ]] || { echo 'Usage: sudo bash apply-api.sh PAYLOAD EXPECTED_APP_MODULE_SHA256' >&2; exit 1; }
payload=$(realpath "$1")
expected=$2
app_root=/opt/chatai-deep
old_release=$(readlink -f "$app_root/current")
module=chatgpt_backend/dist/src/app.module.js
[[ $(sha256sum "$old_release/$module" | cut -d' ' -f1) == "$expected" ]] || { echo 'Deployed module changed; inspect again' >&2; exit 1; }
systemctl is-active --quiet chatai-deep-ocr
release=$(mktemp -d "$app_root/releases/$(date -u +%Y%m%dT%H%M%SZ).ocr.XXXXXXXX")
chmod 0755 "$release"
cp -al "$old_release/." "$release/"
[[ ! -e "$release/chatgpt_backend/dist/src/ocr" ]] || { echo 'OCR module already exists; use regular deployment' >&2; exit 1; }
mkdir "$release/chatgpt_backend/dist/src/ocr"
cp "$payload/backend-ocr/"*.js "$release/chatgpt_backend/dist/src/ocr/"
python3 - "$release/$module" <<'PY'
import os, pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
assert text.count('imports: [') == 1 and './ocr/ocr.module' not in text
text = text.replace('imports: [', 'imports: [\n            require("./ocr/ocr.module").OcrModule,', 1)
temporary = path.with_suffix('.ocr-next')
temporary.write_text(text)
temporary.chmod(0o644)
os.replace(temporary, path)  # 打断硬链接，绝不覆盖旧发布文件。
PY
"$app_root/node/bin/node" --check "$release/$module"
chmod -R a+rX "$release/chatgpt_backend/dist/src/ocr"
dropin=/etc/systemd/system/chatai-deep-api.service.d/ocr.conf
[[ ! -e $dropin ]] || { echo 'Existing OCR drop-in requires review' >&2; exit 1; }
mkdir -p "$(dirname "$dropin")"
printf '[Service]\nEnvironmentFile=/etc/chatai-deep/ocr.env\n' > "$dropin"
rollback() {
  local result=$?
  if [[ $result != 0 ]]; then
    ln -s "$old_release" "$app_root/current.rollback"
    mv -Tf "$app_root/current.rollback" "$app_root/current"
    rm -f "$dropin"
    systemctl daemon-reload
    systemctl restart chatai-deep-api
    echo 'API deployment rolled back' >&2
  fi
}
trap rollback EXIT
ln -s "$release" "$app_root/current.next"
mv -Tf "$app_root/current.next" "$app_root/current"
systemctl daemon-reload
systemctl restart chatai-deep-api
ready=false
for attempt in {1..30}; do
  if curl --silent --fail --max-time 2 http://127.0.0.1:3000/healthz >/dev/null; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]]
printf '%s\n' "$old_release" > "$release/ocr-previous-release.txt"
echo 'OCR API deployed; previous release retained for rollback.'
