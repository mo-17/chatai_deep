#!/bin/sh
set -eu

r2_enabled=false
r2_pid=""
active_pid=""
shutdown_requested=false
R2_MOUNT_DIR="${R2_MOUNT_DIR:-/mnt/r2}"
EPHEMERAL_UPLOADS_DIR="${EPHEMERAL_UPLOADS_DIR:-/workspace/chatgpt_backend/uploads}"
SUPERVISOR_STOP_TIMEOUT_SECONDS="${SUPERVISOR_STOP_TIMEOUT_SECONDS:-10}"

case "$SUPERVISOR_STOP_TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0)
    echo "SUPERVISOR_STOP_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 1
    ;;
esac

process_running() {
  [ -n "${1:-}" ] || return 1
  [ -r "/proc/$1/stat" ] || return 1
  process_state=""
  { read -r _ _ process_state _ < "/proc/$1/stat"; } 2>/dev/null || return 1
  [ "$process_state" != "Z" ] && [ "$process_state" != "X" ]
}

process_group_running() {
  [ -n "${1:-}" ] || return 1
  kill -0 "-$1" 2>/dev/null
}

signal_process_group() {
  signal="$1"
  pid="${2:-}"
  [ -n "$pid" ] || return 0
  if process_group_running "$pid"; then
    kill "-$signal" "-$pid" 2>/dev/null \
      || kill "-$signal" "$pid" 2>/dev/null \
      || true
  elif process_running "$pid"; then
    # setsid 刚 fork、尚未建组的极短窗口仍先通知直接子进程。
    kill "-$signal" "$pid" 2>/dev/null || true
  fi
}

terminate_and_wait() {
  pid="${1:-}"
  [ -n "$pid" ] || return 0

  signal_process_group TERM "$pid"
  attempts=0
  while process_group_running "$pid" || process_running "$pid"; do
    if ! process_running "$pid"; then
      wait "$pid" 2>/dev/null || true
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$SUPERVISOR_STOP_TIMEOUT_SECONDS" ]; then
      signal_process_group KILL "$pid"
      break
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
}

on_signal() {
  shutdown_requested=true
  signal_process_group TERM "$active_pid"
}

cleanup_r2() {
  [ "$r2_enabled" = "true" ] || return 0

  if mountpoint -q "$R2_MOUNT_DIR"; then
    # 正常 unmount 会让 TigrisFS flush 并退出；fsync-on-close 是第一道保障。
    fusermount3 -u "$R2_MOUNT_DIR" 2>/dev/null || true
  fi

  if process_running "$r2_pid"; then
    kill -TERM "$r2_pid" 2>/dev/null || true
  fi

  attempts=0
  while process_running "$r2_pid"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 10 ]; then
      kill -KILL "$r2_pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$r2_pid" 2>/dev/null || true
  r2_enabled=false
}

trap on_signal TERM INT
trap cleanup_r2 EXIT

if [ "${REQUIRE_PRODUCTION_MODE:-false}" = "true" ] \
  && [ "${NODE_ENV:-}" != "production" ]; then
  echo "NODE_ENV=production is required for this deployment" >&2
  exit 1
fi

if [ "${REQUIRE_PRODUCTION_MODE:-false}" = "true" ] \
  && [ "${DB_SYNCHRONIZE:-}" != "false" ]; then
  echo "DB_SYNCHRONIZE=false is required for this deployment" >&2
  exit 1
fi

if [ "${REQUIRE_PRODUCTION_MODE:-false}" = "true" ]; then
  app_secret="${APP_SECRET_KEY:-}"
  jwt_secret="${JWT_SECRET:-}"
  admin_password="${ADMIN_DEFAULT_PASSWORD:-}"
  case "$app_secret" in
    ""|CHANGE_ME*)
      echo "A non-default APP_SECRET_KEY is required for this deployment" >&2
      exit 1
      ;;
  esac
  if [ "${#app_secret}" -lt 32 ]; then
    echo "APP_SECRET_KEY must contain at least 32 characters" >&2
    exit 1
  fi
  if [ "${#jwt_secret}" -lt 32 ]; then
    echo "JWT_SECRET must contain at least 32 characters" >&2
    exit 1
  fi
  case "$admin_password" in
    ""|admin123)
      echo "A non-default ADMIN_DEFAULT_PASSWORD is required for this deployment" >&2
      exit 1
      ;;
  esac
fi

if [ "${NODE_ENV:-production}" = "production" ] \
  && [ "${DB_SYNCHRONIZE:-false}" = "true" ]; then
  echo "DB_SYNCHRONIZE=true is forbidden in production; run migrations instead" >&2
  exit 1
fi

if [ -n "${R2_ACCOUNT_ID:-}" ] \
  && [ "${R2_ACCOUNT_ID}" != "REPLACE_WITH_CLOUDFLARE_ACCOUNT_ID" ] \
  && [ -n "${R2_BUCKET_NAME:-}" ] \
  && [ -n "${AWS_ACCESS_KEY_ID:-}" ] \
  && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  mkdir -p "$R2_MOUNT_DIR"
  tigrisfs \
    --endpoint "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    --fsync-on-close \
    --memory-limit 128 \
    --entry-limit 20000 \
    --max-flushers 4 \
    --max-parallel-parts 2 \
    --max-parallel-copy 2 \
    --read-ahead 1024 \
    --read-ahead-large 8192 \
    --read-ahead-parallel 2048 \
    -f "${R2_BUCKET_NAME}" "$R2_MOUNT_DIR" &
  r2_pid=$!
  r2_enabled=true

  attempts=0
  while ! mountpoint -q "$R2_MOUNT_DIR"; do
    if [ "$shutdown_requested" = "true" ]; then
      exit 143
    fi
    if ! process_running "$r2_pid"; then
      echo "R2 mount process exited before becoming ready" >&2
      wait "$r2_pid" 2>/dev/null || true
      exit 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo "R2 mount did not become ready" >&2
      exit 1
    fi
    sleep 1
  done
  export UPLOADS_DIR="$R2_MOUNT_DIR/uploads"
else
  if [ "${REQUIRE_PERSISTENT_UPLOADS:-false}" = "true" ]; then
    echo "Persistent uploads are required, but R2 credentials are incomplete" >&2
    exit 1
  fi
  echo "R2 credentials are incomplete; uploads will use ephemeral container disk" >&2
  export UPLOADS_DIR="$EPHEMERAL_UPLOADS_DIR"
fi

mkdir -p "$UPLOADS_DIR"

# v2 sync tables deliberately use synchronize:false. The container must not
# serve traffic until the checked-in PostgreSQL migrations have succeeded.
if [ "$shutdown_requested" = "true" ]; then
  exit 143
fi

migration_status=0
setsid node dist/src/database/migration-main.js &
active_pid=$!
if [ "$shutdown_requested" = "true" ]; then
  terminate_and_wait "$active_pid"
  active_pid=""
  exit 143
fi
wait "$active_pid" || migration_status=$?
if [ "$shutdown_requested" = "true" ]; then
  terminate_and_wait "$active_pid"
  active_pid=""
  exit 143
fi
active_pid=""
if [ "$migration_status" -ne 0 ]; then
  exit "$migration_status"
fi

if [ "$r2_enabled" = "true" ] && ! process_running "$r2_pid"; then
  echo "R2 mount process exited during database migration" >&2
  exit 1
fi

if [ "$shutdown_requested" = "true" ]; then
  exit 143
fi

setsid node dist/src/main.js &
backend_pid=$!
active_pid=$backend_pid
r2_failed=false

if [ "$shutdown_requested" = "true" ]; then
  terminate_and_wait "$backend_pid"
  active_pid=""
  exit 143
fi

while process_running "$backend_pid"; do
  if [ "$shutdown_requested" = "true" ]; then
    break
  fi
  if [ "$r2_enabled" = "true" ] && ! process_running "$r2_pid"; then
    echo "R2 mount process exited; stopping backend" >&2
    r2_failed=true
    break
  fi
  sleep 1
done

backend_status=0
if [ "$shutdown_requested" = "true" ] || [ "$r2_failed" = "true" ]; then
  terminate_and_wait "$backend_pid"
else
  wait "$backend_pid" || backend_status=$?
  if [ "$shutdown_requested" = "true" ]; then
    terminate_and_wait "$backend_pid"
  elif process_group_running "$backend_pid"; then
    # backend 已退出但仍有 stdio MCP 等后代进程时，不能把孤儿留给 PID 1。
    terminate_and_wait "$backend_pid"
  fi
fi
active_pid=""

if [ "$shutdown_requested" = "true" ]; then
  exit 143
fi
if [ "$r2_failed" = "true" ]; then
  exit 1
fi
exit "$backend_status"
