#!/bin/sh
set -eu

if [ -n "${R2_ACCOUNT_ID:-}" ] \
  && [ "${R2_ACCOUNT_ID}" != "REPLACE_WITH_CLOUDFLARE_ACCOUNT_ID" ] \
  && [ -n "${R2_BUCKET_NAME:-}" ] \
  && [ -n "${AWS_ACCESS_KEY_ID:-}" ] \
  && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  mkdir -p /mnt/r2
  tigrisfs \
    --endpoint "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    -f "${R2_BUCKET_NAME}" /mnt/r2 &

  attempts=0
  while ! mountpoint -q /mnt/r2; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo "R2 mount did not become ready" >&2
      exit 1
    fi
    sleep 1
  done
  export UPLOADS_DIR=/mnt/r2/uploads
else
  echo "R2 credentials are incomplete; uploads will use ephemeral container disk" >&2
  export UPLOADS_DIR=/workspace/chatgpt_backend/uploads
fi

mkdir -p "$UPLOADS_DIR"
exec node dist/main.js
