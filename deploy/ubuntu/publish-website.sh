#!/usr/bin/env bash
# 在已有 kushui.shop HTTPS 的 Ubuntu 上发布官网，不重启 API/admin。
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $EUID -eq 0 ]] || { echo '请使用 root 或 sudo 执行。' >&2; exit 1; }
[[ $# -eq 2 ]] || { echo '用法：sudo bash publish-website.sh <website目录> <Android APK路径>' >&2; exit 2; }
site_dir=$(cd -- "$1" && pwd)
apk_path=$(realpath -- "$2")
tls_config=/etc/nginx/conf.d/chatai-deep-tls.conf
site_root=/var/www/chatai-website
downloads=$site_root/downloads
[[ -f $tls_config && -d /run/systemd/system ]] || { echo '需要先完成现有 HTTPS 部署。' >&2; exit 1; }
exec 9>/run/lock/chatai-deep-deploy.lock
flock -n 9 || { echo '另一个部署或备份正在运行。' >&2; exit 1; }

# 校验受控静态文件集及 APK，防止误发源码、凭据或错误安装包。
python3 - "$site_dir" "$apk_path" <<'PY'
import hashlib, json, pathlib, sys, re
from urllib.parse import urlsplit
site, apk = map(pathlib.Path, sys.argv[1:])
expected = {'index.html', 'robots.txt', 'site-assets/site.css', 'site-assets/site.js',
            'site-assets/favicon.svg', 'site-assets/release.json'}
actual = {str(p.relative_to(site)) for p in site.rglob('*') if p.is_file()}
assert actual == expected and not any(p.is_symlink() for p in site.rglob('*')), '官网文件集不符合预期'
metadata = json.loads((site/'site-assets/release.json').read_text())
url = urlsplit(metadata['url'])
assert url.scheme == 'https' and url.hostname in {'kushui.shop','01a14fea704875d49fb78b48f2092eee.cn-hongkong-2.a8g1v3.xyz'}
assert not url.query and not url.fragment and not url.username and re.fullmatch(r'/downloads/aipu-[0-9.]+-[0-9]+-(android|universal)\.apk',url.path), '下载 URL 无效'
assert metadata['backendOrigin'] == 'https://kushui.shop'
assert apk.is_file() and apk.stat().st_size == metadata['bytes'], 'APK 大小不匹配'
digest = hashlib.sha256()
with apk.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024*1024), b''):
        digest.update(chunk)
assert digest.hexdigest() == metadata['sha256'], 'APK 摘要不匹配'
PY

install -d -m 0755 "$site_root/releases" "$downloads" /etc/nginx/snippets
backup_dir=$(mktemp -d /var/backups/chatai-deep/website-$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX)
chmod 0700 "$backup_dir"
cp -a "$tls_config" "$backup_dir/tls.conf"
for part in locations headers; do
  file="/etc/nginx/snippets/chatai-website-$part.conf"
  if [[ -f $file ]]; then cp -a "$file" "$backup_dir/$part.conf"; fi
done
old_target=$(readlink "$site_root/current" || true)
[[ ! -e $site_root/current || -L $site_root/current ]] || { echo 'current 必须是受管符号链接。' >&2; exit 1; }
release_dir=$(mktemp -d "$site_root/releases/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
chmod 0755 "$release_dir"
cp -R -- "$site_dir/." "$release_dir/"
chown -R root:root "$release_dir"
find "$release_dir" -type d -exec chmod 0755 {} +
find "$release_dir" -type f -exec chmod 0644 {} +
filename=$(python3 - "$site_dir/site-assets/release.json" <<'PY'
import json, sys
from urllib.parse import urlsplit
print(urlsplit(json.load(open(sys.argv[1]))['url']).path.rsplit('/',1)[-1])
PY
)
if [[ -e $downloads/$filename ]]; then
  cmp --silent "$apk_path" "$downloads/$filename" || { echo '同版本安装包已存在且内容不同，必须先使用新的版本文件名。' >&2; exit 1; }
else
  install -m 0644 "$apk_path" "$downloads/.$filename.new"
  mv -T "$downloads/.$filename.new" "$downloads/$filename"
fi
(cd "$downloads" && sha256sum "$filename" > "$filename.sha256.new")
chmod 0644 "$downloads/$filename.sha256.new"
mv -T "$downloads/$filename.sha256.new" "$downloads/$filename.sha256"

rollback() {
  trap - ERR
  set +e
  cp -a "$backup_dir/tls.conf" "$tls_config"
  for part in locations headers; do
    file="/etc/nginx/snippets/chatai-website-$part.conf"
    if [[ -f $backup_dir/$part.conf ]]; then cp -a "$backup_dir/$part.conf" "$file"; else rm -f -- "$file"; fi
  done
  if [[ -n $old_target ]]; then
    ln -s "$old_target" "$site_root/rollback.$$"
    mv -Tf "$site_root/rollback.$$" "$site_root/current"
  else
    rm -f -- "$site_root/current"
  fi
  nginx -t && systemctl reload nginx
  echo "官网发布失败（第 ${1:-未知} 行），已尝试恢复原路由；备份：$backup_dir" >&2
  exit 1
}
trap 'rollback "$LINENO"' ERR
install -m 0644 "$SCRIPT_DIR/nginx-website-locations.conf" /etc/nginx/snippets/chatai-website-locations.conf
install -m 0644 "$SCRIPT_DIR/nginx-website-headers.conf" /etc/nginx/snippets/chatai-website-headers.conf
python3 - "$tls_config" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
include = '    include /etc/nginx/snippets/chatai-website-locations.conf;\n\n'
if include.strip() not in text:
    anchor = '    location /uapi/ {'
    assert text.count(anchor) == 1 and 'server_name kushui.shop;' in text, 'TLS 配置需人工检查'
    text = text.replace(anchor, include + anchor, 1)
    path.write_text(text)
PY
ln -s "$release_dir" "$site_root/current.new.$$"
mv -Tf "$site_root/current.new.$$" "$site_root/current"
nginx -t
systemctl reload nginx
# reload 发送 HUP 后会短暂保留旧 worker，等待实际新正文生效再确认切换。
website_ready=false
for attempt in {1..20}; do
  if curl --fail --silent --show-error --noproxy kushui.shop --max-time 3 \
    --resolve kushui.shop:443:127.0.0.1 https://kushui.shop/ > "$backup_dir/home-probe.html" \
    && grep -q 'id="hero-title"' "$backup_dir/home-probe.html"; then
    website_ready=true
    break
  fi
  sleep 0.5
done
$website_ready
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8080/healthz >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:3001/login >/dev/null
trap - ERR
printf '官网发布完成\n官网：https://kushui.shop/\n后台：https://kushui.shop/login\nAPI：https://kushui.shop/uapi\n版本目录：%s\n备份目录：%s\n' "$release_dir" "$backup_dir"
