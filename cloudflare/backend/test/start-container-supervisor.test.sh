#!/bin/sh
set -eu

if [ ! -r /proc/self/stat ]; then
  echo "start-container supervisor gate skipped: Linux /proc is required"
  exit 0
fi

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
start_script="$repo_root/cloudflare/backend/start-container.sh"
test_root=$(mktemp -d)
fake_bin="$test_root/bin"
events="$test_root/events"
mkdir -p "$fake_bin" "$test_root/mnt" "$test_root/uploads"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

cat >"$fake_bin/tigrisfs" <<'EOF'
#!/bin/sh
trap 'echo tigris-term >>"$FAKE_LOG"; exit 0' TERM INT
echo "tigris-start $*" >>"$FAKE_LOG"
remaining="${FAKE_TIGRIS_LIFETIME:-2}"
while [ "$remaining" -gt 0 ]; do
  sleep 1
  remaining=$((remaining - 1))
done
echo tigris-exit >>"$FAKE_LOG"
EOF

cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "${1:-}" in
  *migration-main.js)
    echo migration-start >>"$FAKE_LOG"
    if [ "${FAKE_MIGRATION_IGNORE_TERM:-false}" = "true" ]; then
      trap '' TERM INT
      while true; do sleep 1; done
    fi
    echo migration-ok >>"$FAKE_LOG"
    exit 0
    ;;
  *main.js)
    trap 'echo backend-term >>"$FAKE_LOG"; exit 0' TERM INT
    echo backend-start >>"$FAKE_LOG"
    while true; do sleep 1; done
    ;;
esac
exit 2
EOF

cat >"$fake_bin/mountpoint" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$fake_bin/fusermount3" <<'EOF'
#!/bin/sh
echo unmount >>"$FAKE_LOG"
exit 0
EOF

chmod +x "$fake_bin/tigrisfs" "$fake_bin/node" \
  "$fake_bin/mountpoint" "$fake_bin/fusermount3"

export PATH="$fake_bin:/usr/bin:/bin"
export FAKE_LOG="$events"
export R2_MOUNT_DIR="$test_root/mnt"
export EPHEMERAL_UPLOADS_DIR="$test_root/uploads"
export NODE_ENV=production
export DB_SYNCHRONIZE=false
export REQUIRE_PRODUCTION_MODE=true
export REQUIRE_PERSISTENT_UPLOADS=true
export JWT_SECRET=ci-test-jwt-secret-0123456789-abcdefghijklmnopqrstuvwxyz
export APP_SECRET_KEY=ci-test-app-key-0123456789-abcdefghijklmnopqrstuvwxyz
export ADMIN_DEFAULT_PASSWORD=ci-test-admin-password
export SUPERVISOR_STOP_TIMEOUT_SECONDS=2
export R2_ACCOUNT_ID=test-account
export R2_BUCKET_NAME=test-bucket
export AWS_ACCESS_KEY_ID=test-access
export AWS_SECRET_ACCESS_KEY=test-secret

# TigrisFS 退出后即使还处于 zombie，backend 也必须被停止。
: >"$events"
zombie_status=0
FAKE_TIGRIS_LIFETIME=2 sh "$start_script" || zombie_status=$?
[ "$zombie_status" -eq 1 ]
grep -q '^backend-term$' "$events"
grep -q '^unmount$' "$events"
grep -q -- '--fsync-on-close' "$events"
grep -q -- '--memory-limit 128' "$events"
grep -q -- '--entry-limit 20000' "$events"

# migration 忽略 TERM 时，supervisor 必须有界升级到 KILL，且不得启动 backend。
: >"$events"
FAKE_TIGRIS_LIFETIME=60 FAKE_MIGRATION_IGNORE_TERM=true sh "$start_script" &
supervisor_pid=$!
attempts=0
while ! grep -q '^migration-start$' "$events" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 10 ]; then
    kill -KILL "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" 2>/dev/null || true
    echo "migration did not start in bounded shutdown test" >&2
    exit 1
  fi
  sleep 1
done

kill -TERM "$supervisor_pid"
migration_signal_status=0
wait "$supervisor_pid" || migration_signal_status=$?
[ "$migration_signal_status" -eq 143 ]
! grep -q '^backend-start$' "$events"
grep -q '^unmount$' "$events"
grep -q '^tigris-term$' "$events"

# PID 1 收到 TERM 时，先停 backend，再 unmount 并终止 TigrisFS。
: >"$events"
FAKE_TIGRIS_LIFETIME=60 sh "$start_script" &
supervisor_pid=$!
attempts=0
while ! grep -q '^backend-start$' "$events" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 10 ]; then
    kill -KILL "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" 2>/dev/null || true
    echo "backend did not start in supervisor signal test" >&2
    exit 1
  fi
  sleep 1
done

kill -TERM "$supervisor_pid"
signal_status=0
wait "$supervisor_pid" || signal_status=$?
[ "$signal_status" -eq 143 ]

for expected_event in backend-term unmount tigris-term; do
  if ! grep -q "^${expected_event}$" "$events"; then
    echo "missing ${expected_event} in supervisor signal test:" >&2
    sed -n '1,40p' "$events" >&2
    exit 1
  fi
done

backend_line=$(grep -n '^backend-term$' "$events" | cut -d: -f1)
unmount_line=$(grep -n '^unmount$' "$events" | cut -d: -f1)
tigris_line=$(grep -n '^tigris-term$' "$events" | cut -d: -f1)
[ "$backend_line" -lt "$unmount_line" ]
[ "$unmount_line" -lt "$tigris_line" ]

echo "start-container supervisor gates passed"
