#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
if [[ ${1:-} == --help ]]; then echo '用法：sudo bash backup.sh。短暂停止应用，备份数据库、上传文件与密钥后恢复服务。'; exit 0; fi
[[ $# -eq 0 || ( $# -eq 1 && $1 == --stopped ) ]] || die '未知参数。'
require_root
require_ubuntu
require_ready
if [[ ${1:-} != --stopped ]]; then
  exec 9>/run/lock/chatai-deep-deploy.lock
  flock -n 9 || die '另一个部署或备份正在执行。'
  api_active=false; admin_active=false
  systemctl is-active --quiet chatai-deep-api && api_active=true
  systemctl is-active --quiet chatai-deep-admin && admin_active=true
  resume() {
    if $api_active; then systemctl start chatai-deep-api; fi
    if $admin_active; then systemctl start chatai-deep-admin; fi
  }
  trap resume EXIT
  if $admin_active; then systemctl stop chatai-deep-admin; fi
  if $api_active; then systemctl stop chatai-deep-api; fi
else
  if systemctl is-active --quiet chatai-deep-api || systemctl is-active --quiet chatai-deep-admin; then
    die '--stopped 要求应用服务均已停止。'
  fi
fi
umask 077
install -d -m 0700 "$BACKUP_ROOT"
backup_dir=$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
runuser -u postgres -- pg_dump --format=custom chatai_app > "$backup_dir/database.dump"
tar -czf "$backup_dir/uploads.tgz" -C "$DATA_ROOT" uploads
cp -p "$CONFIG_ROOT/backend.env" "$backup_dir/backend.env"
if [[ -L $APP_ROOT/current ]]; then readlink -f "$APP_ROOT/current" > "$backup_dir/release.txt"; fi
(cd "$backup_dir"; sha256sum database.dump uploads.tgz backend.env > SHA256SUMS)
touch "$backup_dir/COMPLETE"
echo "备份完成：$backup_dir（含敏感密钥，请保存在受控位置）"
