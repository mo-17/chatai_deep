#!/usr/bin/env bash
# 在已有 Ubuntu systemd 部署上独立安装 worker；不自动替换线上 API。
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ocr_root=/opt/chatai-deep/ocr
config_root=/etc/chatai-deep
[[ -f $config_root/.managed && -f $config_root/backend.env ]] || { echo 'Existing managed deployment required' >&2; exit 1; }
id chatai-ocr >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin chatai-ocr
if ! dpkg-query -W -f='${Status}' python3-venv 2>/dev/null | grep -q 'install ok installed'; then
  apt-get update -qq
  apt-get install -y --no-install-recommends python3-venv
fi
mkdir -p "$ocr_root/releases"
release=$(mktemp -d "$ocr_root/releases/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
cp "$script_dir/engine.py" "$script_dir/server.py" "$script_dir/warmup.py" "$script_dir/requirements-lock.txt" "$release/"
python3 -m venv "$release/.venv"
"$release/.venv/bin/pip" install --no-cache-dir --disable-pip-version-check -r "$release/requirements-lock.txt"
OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 "$release/.venv/bin/python" "$release/warmup.py"
chown -R root:root "$release"
chmod -R a+rX "$release"
python3 - "$config_root" <<'PY'
import os, pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
path = root / 'ocr.env'
if not path.exists():
    value = 'OCR_WORKER_TOKEN=' + secrets.token_hex(32) + '\nOCR_WORKER_URL=http://127.0.0.1:3002\n'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file: file.write(value)
os.chmod(path, 0o600)
PY
ln -s "$release" "$ocr_root/current.next"
mv -Tf "$ocr_root/current.next" "$ocr_root/current"
install -m 0644 "$script_dir/chatai-deep-ocr.service" /etc/systemd/system/chatai-deep-ocr.service
systemctl daemon-reload
systemctl enable --now chatai-deep-ocr
systemctl restart chatai-deep-ocr
echo 'Worker installed. API must load /etc/chatai-deep/ocr.env through an EnvironmentFile drop-in.'
