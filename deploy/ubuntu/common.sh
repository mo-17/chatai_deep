#!/usr/bin/env bash
# Ubuntu 专用路径，避免部署配置混入源码或覆盖其它项目。
set -Eeuo pipefail
APP_ROOT=/opt/chatai-deep
CONFIG_ROOT=/etc/chatai-deep
DATA_ROOT=/var/lib/chatai-deep
CACHE_ROOT=/var/cache/chatai-deep
BACKUP_ROOT=/var/backups/chatai-deep
APP_USER=chatai
NODE_VERSION=22.23.3
PNPM_VERSION=10.12.4
NODE_HOME="$APP_ROOT/node-v$NODE_VERSION"
export PATH="$NODE_HOME/bin:$APP_ROOT/tooling/node_modules/.bin:/usr/sbin:/usr/bin:/sbin:/bin"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

log() { printf '\n[chatai] %s\n' "$*"; }
die() { printf '[chatai] 错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die '请使用 sudo bash 执行此脚本。'; }
require_ubuntu() {
  [[ $(uname -s) == Linux ]] || die '此操作只能在 Ubuntu Linux 上运行。';
  # /etc/os-release 是操作系统提供的可信配置。
  . /etc/os-release
  [[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 ) ]] ||
    die '支持 Ubuntu 22.04 / 24.04 LTS；其它版本请先适配并验证。'
  [[ -d /run/systemd/system ]] || die '需要正常运行 systemd 的 Ubuntu 主机。'
}
require_ready() {
  [[ -f $CONFIG_ROOT/.managed && -f $CONFIG_ROOT/backend.env ]] || die '请先执行 setup.sh。'
  [[ -x $NODE_HOME/bin/node ]] || die '部署专用 Node.js 尚未安装。'
  [[ $($NODE_HOME/bin/node -p 'process.versions.node.split(".")[0]') == 22 ]] || die '部署专用 Node.js 版本应为 22。'
}
health() {
  local url=$1 attempt
  for attempt in {1..60}; do
    if curl --silent --fail --max-time 2 "$url" >/dev/null; then return 0; fi
    sleep 2
  done
  die "健康检查失败：$url；请查看 journalctl -u chatai-deep-api -u chatai-deep-admin。"
}
