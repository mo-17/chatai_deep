#!/usr/bin/env bash
# 只替换已审查的 OCR 运行时与独立构建的后台；原版本保留，失败自动回退。
set -Eeuo pipefail
[[ $EUID == 0 && $# == 3 ]] || { echo 'Usage: sudo bash activate-workbench.sh PAYLOAD EXPECTED_WORKER EXPECTED_APP_MODULE_SHA256' >&2; exit 1; }
payload=$(realpath "$1")
candidate=$(cat "$payload/candidate.txt")
previous=$(cat "$payload/previous.txt")
old_worker=$(readlink -f /opt/chatai-deep/ocr/current)
[[ $(readlink -f /opt/chatai-deep/current) == "$previous" && $old_worker == "$2" ]]
[[ $candidate == /opt/chatai-deep/releases/*.ocr-workbench.* && -d $candidate/chatgpt_admin/.next ]]
module=chatgpt_backend/dist/src/app.module.js
[[ $(sha256sum "$previous/$module" | cut -d' ' -f1) == "$3" ]]
exec 9>/run/lock/chatai-deep-deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
[[ -z $(find /run/chatai-ocr -type f -print -quit) ]] || { echo 'OCR has an active upload; retry after it completes' >&2; exit 1; }
tar --no-same-owner -xzf "$payload/runtime.tgz" -C "$payload"
cmp "$payload/worker/requirements-lock.txt" "$old_worker/requirements-lock.txt"
worker=$(mktemp -d /opt/chatai-deep/ocr/releases/$(date -u +%Y%m%dT%H%M%SZ).workbench.XXXXXXXX)
chmod 0755 "$worker"
cp -al "$old_worker/." "$worker/"
python3 - "$payload" "$worker" "$candidate" <<'PY'
import os,pathlib,shutil,sys
payload,worker,candidate=map(pathlib.Path,sys.argv[1:])
for name in ['server.py','engine.py']:
    temporary=worker/(name+'.next')
    shutil.copy2(payload/'worker'/name,temporary); os.replace(temporary,worker/name)
target=candidate/'chatgpt_backend/dist/src/ocr'
assert '.ocr-workbench.' in candidate.name
shutil.rmtree(target); shutil.copytree(payload/'backend-ocr',target)
assert {p.suffix for p in target.iterdir()}=={'.js'}
PY
for file in "$candidate/chatgpt_backend/dist/src/ocr/"*.js; do /opt/chatai-deep/node/bin/node --check "$file"; done
"$worker/.venv/bin/python" - "$worker" <<'PY'
import ast,pathlib,sys
for name in ['server.py','engine.py']: ast.parse((pathlib.Path(sys.argv[1])/name).read_text())
PY
[[ $(sha256sum "$candidate/$module" | cut -d' ' -f1) == "$3" ]]
admin_user=$(systemctl show chatai-deep-admin -p User --value)
[[ -n $admin_user && $admin_user != root ]]
cache=/var/cache/chatai-deep/next/$(basename "$candidate")
install -d -m 0750 -o "$admin_user" -g "$admin_user" "$cache"
rm -rf -- "$candidate/chatgpt_admin/.next/cache"
ln -s "$cache" "$candidate/chatgpt_admin/.next/cache"
chmod -R a+rX "$candidate/chatgpt_backend/dist/src/ocr"
cp /etc/systemd/system/chatai-deep-ocr.service "$payload/previous-ocr.service"
activated=false
switch_link() { ln -s "$1" "$2.workbench-next"; mv -Tf "$2.workbench-next" "$2"; }
rollback() {
  local status=$?
  if [[ $status != 0 && $activated == true ]]; then
    switch_link "$previous" /opt/chatai-deep/current
    switch_link "$old_worker" /opt/chatai-deep/ocr/current
    cp "$payload/previous-ocr.service" /etc/systemd/system/chatai-deep-ocr.service
    systemctl daemon-reload
    systemctl restart chatai-deep-ocr chatai-deep-api chatai-deep-admin
    echo 'OCR workbench activation rolled back' >&2
  fi
}
trap rollback EXIT
activated=true
install -m 0644 "$payload/worker/chatai-deep-ocr.service" /etc/systemd/system/chatai-deep-ocr.service
switch_link "$worker" /opt/chatai-deep/ocr/current
switch_link "$candidate" /opt/chatai-deep/current
systemctl daemon-reload
systemctl restart chatai-deep-ocr chatai-deep-api chatai-deep-admin
ready=false
for attempt in {1..30}; do
  if curl --silent --fail --max-time 2 http://127.0.0.1:3000/healthz >/dev/null && \
     curl --silent --fail --max-time 2 http://127.0.0.1:3001/ocr >/dev/null; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]]
python3 - "$payload/activation.json" "$candidate" "$worker" "$previous" "$old_worker" <<'PY'
import datetime,json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(zip(['release','worker','previousRelease','previousWorker'],sys.argv[2:]))|{'activatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()},indent=2)+'\n')
PY
echo 'OCR runtime and admin activated; previous versions retained. No database migration.'
