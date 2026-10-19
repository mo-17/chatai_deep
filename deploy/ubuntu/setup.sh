#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
if [[ ${1:-} == --help ]]; then
  echo '用法：sudo bash setup.sh [--skip-swap]。首次安装依赖，生成密钥并创建专用数据库。'
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && $1 == --skip-swap ) ]] || die '未知参数；使用 --help 查看用法。'
require_root
require_ubuntu
exec 9>/run/lock/chatai-deep-deploy.lock
flock -n 9 || die '另一个部署或初始化正在执行。'
trap 'echo "[chatai] 初始化失败（第 $LINENO 行）；修复后可以重跑。" >&2' ERR
umask 077
if [[ ! -f $CONFIG_ROOT/.managed ]]; then
  [[ ! -e $APP_ROOT && ! -e $CONFIG_ROOT && ! -e $DATA_ROOT && ! -e /etc/nginx/conf.d/chatai-deep.conf ]] ||
    die '目标路径已存在但没有本脚本的管理标记；停止以避免覆盖现有部署。'
  ! id "$APP_USER" &>/dev/null || die '系统已有 chatai 用户，请先核对归属。'
  install -d -m 0755 "$APP_ROOT"
  install -d -m 0700 "$CONFIG_ROOT"
  printf 'ubuntu-v1\n' > "$CONFIG_ROOT/.managed"
fi
umask 022

log '安装 Ubuntu 软件包'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils python3 \
  git rsync build-essential postgresql postgresql-client nginx util-linux openssl
systemctl enable --now postgresql
if ! id "$APP_USER" &>/dev/null; then
  useradd --system --user-group --home-dir "$DATA_ROOT" --shell /usr/sbin/nologin "$APP_USER"
fi
install -d -m 0755 "$APP_ROOT/releases"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$DATA_ROOT" "$DATA_ROOT/uploads" \
  "$CACHE_ROOT" "$CACHE_ROOT/npm" "$CACHE_ROOT/next"
install -d -m 0700 "$BACKUP_ROOT"

if [[ ${1:-} != --skip-swap ]] && [[ -z $(swapon --show --noheadings) ]]; then
  swap_path=/swapfile-chatai-deep
  if [[ -e $swap_path ]]; then
    [[ -f $CONFIG_ROOT/.swap-created && -f $swap_path && ! -L $swap_path ]] ||
      die '同名 swap 文件已经存在；请核对后使用 --skip-swap。'
  else
    [[ $(df -Pk / | awk 'NR==2 {print $4}') -ge 6291456 ]] || die '可用磁盘不足 6 GB；请清理磁盘或使用 --skip-swap。'
    [[ $(findmnt -n -o FSTYPE /) != btrfs ]] || die 'Btrfs 需单独配置 swap，请使用 --skip-swap。'
    # 只在首次创建自己的文件时写入，不覆盖系统已有 swap。
    touch "$CONFIG_ROOT/.swap-created"
    dd if=/dev/zero of="$swap_path" bs=1M count=2048 status=progress
    chmod 0600 "$swap_path"
    mkswap "$swap_path"
  fi
  swapon "$swap_path"
  if ! awk '$1=="/swapfile-chatai-deep" {found=1} END {exit !found}' /etc/fstab; then
    printf '\n/swapfile-chatai-deep none swap sw 0 0\n' >> /etc/fstab
  fi
fi

log '安装项目专用 Node.js 22 与 pnpm（保留系统已有 Node.js）'
case $(uname -m) in
  x86_64) node_arch=x64; node_sha256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de ;;
  aarch64) node_arch=arm64; node_sha256=a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f ;;
  *) die '只支持 x86_64 和 aarch64。' ;;
esac
if [[ ! -x $NODE_HOME/bin/node ]]; then
  download_dir=$(mktemp -d /tmp/chatai-node.XXXXXXXX)
  node_tar="node-v$NODE_VERSION-linux-$node_arch.tar.xz"
  curl --fail --show-error --location --retry 3 \
    "https://nodejs.org/dist/v$NODE_VERSION/$node_tar" -o "$download_dir/$node_tar"
  # 固定摘要来自该版本官方 SHASUMS256.txt，与版本一起更新。
  (cd "$download_dir"; printf '%s  %s\n' "$node_sha256" "$node_tar" | sha256sum -c -)
  tar --no-same-owner -xJf "$download_dir/$node_tar" -C "$download_dir"
  [[ ! -e $NODE_HOME ]] || die 'Node.js 安装目录不完整，请检查后手动移走再重试。'
  mv "$download_dir/node-v$NODE_VERSION-linux-$node_arch" "$NODE_HOME"
  rm -rf -- "$download_dir"
fi
[[ ! -e $APP_ROOT/node || -L $APP_ROOT/node ]] || die 'node 路径被普通文件或目录占用。'
ln -sfn "node-v$NODE_VERSION" "$APP_ROOT/node"
if [[ ! -x $APP_ROOT/tooling/node_modules/.bin/pnpm ]] || \
   [[ $($APP_ROOT/tooling/node_modules/.bin/pnpm --version) != "$PNPM_VERSION" ]]; then
  "$NODE_HOME/bin/npm" install --prefix "$APP_ROOT/tooling" --no-audit --no-fund "pnpm@$PNPM_VERSION"
fi

role_exists=$(runuser -u postgres -- psql -XAt -c "SELECT 1 FROM pg_roles WHERE rolname='chatai_app'")
db_exists=$(runuser -u postgres -- psql -XAt -c "SELECT 1 FROM pg_database WHERE datname='chatai_app'")
if [[ ! -e $CONFIG_ROOT/backend.env ]]; then
  [[ -z $role_exists && -z $db_exists ]] || die '已有同名数据库或角色；不会接管，请先人工核对。'
  python3 "$SCRIPT_DIR/config.py" generate "$SCRIPT_DIR/backend.env.example" "$CONFIG_ROOT/backend.env"
fi
python3 "$SCRIPT_DIR/config.py" validate "$CONFIG_ROOT/backend.env"
db_password=$(python3 "$SCRIPT_DIR/config.py" db-password "$CONFIG_ROOT/backend.env")
if [[ -z $role_exists ]]; then
  # 密码已经校验为纯十六进制；不通过进程参数传递，不打印密码。
  runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE chatai_app LOGIN PASSWORD '$db_password' CONNECTION LIMIT 8;
SQL
fi
if [[ -z $db_exists ]]; then
  runuser -u postgres -- createdb --owner=chatai_app chatai_app
fi
[[ $(runuser -u postgres -- psql -XAt -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='chatai_app'") == chatai_app ]] ||
  die 'chatai_app 数据库 owner 不匹配；停止以避免操作他人的数据库。'
PGPASSWORD="$db_password" psql -X -h 127.0.0.1 -U chatai_app -d chatai_app -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null
unset db_password
chmod 0600 "$CONFIG_ROOT/backend.env"
log '初始化完成。密钥与初始管理员密码保存在 /etc/chatai-deep/backend.env（sudo 查看）。'
echo '下一步：sudo bash deploy/ubuntu/deploy.sh --source "$PWD"'
