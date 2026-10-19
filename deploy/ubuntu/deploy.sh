#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
if [[ ${1:-} == --help ]]; then
  echo '用法：sudo bash deploy.sh --source <源码目录> | --prepared <相同架构 Linux 预构建目录>'
  exit 0
fi
[[ $# -eq 2 && ( $1 == --source || $1 == --prepared ) ]] || die '参数错误，使用 --help 查看用法。'
mode=$1
input_dir=$(cd -- "$2" && pwd)
require_root
require_ubuntu
require_ready
exec 9>/run/lock/chatai-deep-deploy.lock
flock -n 9 || die '另一个部署或备份正在执行。'
python3 "$SCRIPT_DIR/config.py" validate "$CONFIG_ROOT/backend.env"
trap 'echo "[chatai] 部署失败（第 $LINENO 行）。切勿自动回退数据库；参阅 README 的失败恢复步骤。" >&2' ERR
umask 022
release_dir=$(mktemp -d "$APP_ROOT/releases/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
if [[ $mode == --source ]]; then
  # 输入可能位于 /root 或 SSH 用户家目录，先由 root 打包，再以专用用户构建。
  source_archive=$(mktemp /tmp/chatai-deploy-source.XXXXXXXX.tgz)
  rm -- "$source_archive"
  python3 "$SCRIPT_DIR/package.py" source "$input_dir" "$source_archive"
  tar --no-same-owner -xzf "$source_archive" -C "$release_dir"
  rm -- "$source_archive"
  # build.sh 要求空目标，因此把源码放在独立临时目录。
  source_stage=$release_dir
  release_dir=$(mktemp -d "$APP_ROOT/releases/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
  chown -R "$APP_USER:$APP_USER" "$source_stage" "$release_dir"
  log '串行构建（此时旧版本继续运行）'
  runuser -u "$APP_USER" -- env PATH="$PATH" HOME="$DATA_ROOT" \
    CHATAI_BUILD_HEAP_MB="${CHATAI_BUILD_HEAP_MB:-1024}" \
    bash "$source_stage/deploy/ubuntu/build.sh" "$source_stage" "$release_dir"
  rm -rf -- "$source_stage"
else
  python3 "$SCRIPT_DIR/package.py" verify "$input_dir"
  cp -a -- "$input_dir/." "$release_dir/"
fi
python3 "$SCRIPT_DIR/package.py" verify "$release_dir"
# 将 Next.js 运行时缓存移到持久可写目录，代码和依赖由 root 持有。
cache_dir="$CACHE_ROOT/next/$(basename "$release_dir")"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$cache_dir"
if [[ -e $release_dir/chatgpt_admin/.next/cache ]]; then
  rm -rf -- "$release_dir/chatgpt_admin/.next/cache"
fi
ln -s "$cache_dir" "$release_dir/chatgpt_admin/.next/cache"
chown -hR root:root "$release_dir"
chmod -R a+rX "$release_dir"

log '停止应用并备份，随后迁移数据库'
# 首次部署没有 unit，跳过；已有 unit 必须成功停止，不能忽略停止失败。
for service in chatai-deep-admin chatai-deep-api; do
  if systemctl cat "$service.service" &>/dev/null; then systemctl stop "$service.service"; fi
done
bash "$SCRIPT_DIR/backup.sh" --stopped
# EnvironmentFile 由 systemd 读取，保持 root-only，不 source 或打印 secrets。
systemd-run --unit="chatai-deep-migrate-$(date +%s)-$$" --wait --pipe --collect \
  --uid="$APP_USER" --gid="$APP_USER" \
  --property="WorkingDirectory=$release_dir/chatgpt_backend" \
  --property="EnvironmentFile=$CONFIG_ROOT/backend.env" \
  --property=MemoryMax=768M --setenv=NODE_OPTIONS=--max-old-space-size=384 \
  "$NODE_HOME/bin/node" dist/src/database/migration-main.js

log '迁移成功，激活新版本'
ln -s "$release_dir" "$APP_ROOT/current.new.$$"
mv -Tf "$APP_ROOT/current.new.$$" "$APP_ROOT/current"
install -m 0644 "$SCRIPT_DIR/chatai-deep-api.service" /etc/systemd/system/chatai-deep-api.service
install -m 0644 "$SCRIPT_DIR/chatai-deep-admin.service" /etc/systemd/system/chatai-deep-admin.service
systemctl daemon-reload
systemctl enable chatai-deep-api chatai-deep-admin
systemctl reset-failed chatai-deep-api chatai-deep-admin
systemctl start chatai-deep-api
health http://127.0.0.1:3000/healthz
systemctl start chatai-deep-admin
health http://127.0.0.1:3001

nginx_previous=$(mktemp /tmp/chatai-nginx.XXXXXXXX)
had_nginx=false
if [[ -f /etc/nginx/conf.d/chatai-deep.conf ]]; then
  cp /etc/nginx/conf.d/chatai-deep.conf "$nginx_previous"
  had_nginx=true
fi
install -m 0644 "$SCRIPT_DIR/nginx.conf" /etc/nginx/conf.d/chatai-deep.conf
if ! nginx -t; then
  if $had_nginx; then cp "$nginx_previous" /etc/nginx/conf.d/chatai-deep.conf
  else rm /etc/nginx/conf.d/chatai-deep.conf; fi
  rm -- "$nginx_previous"
  die 'Nginx 配置检查失败，已恢复原配置。'
fi
rm -- "$nginx_previous"
systemctl enable --now nginx
systemctl reload nginx
health http://127.0.0.1:8080/healthz
health http://127.0.0.1:8080
log '部署完成。Mac 执行 ssh -N -L 8080:127.0.0.1:8080 用户名@服务器IP，然后访问 http://localhost:8080'
echo '管理员初始密码：sudo 查看 /etc/chatai-deep/backend.env；登录后修改。'
