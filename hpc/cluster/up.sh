#!/usr/bin/env bash
# Bring up the local Slurm + Apptainer + S3 cluster.
set -euo pipefail
cd "$(dirname "$0")"
export STATE_DIR=${STATE_DIR:-$PWD/state} SHARED_DIR=${SHARED_DIR:-$PWD/state/shared}
mkdir -p "$STATE_DIR/munge" "$STATE_DIR/s3" "$SHARED_DIR"
[ -f "$STATE_DIR/munge/munge.key" ] || dd if=/dev/urandom bs=1 count=1024 of="$STATE_DIR/munge/munge.key" status=none
chmod 1777 "$SHARED_DIR"
docker compose up -d --build
for i in $(seq 60); do
  docker compose exec -T head sinfo -h -o '%T' 2>/dev/null | grep -qx idle && break; sleep 2
done
for i in $(seq 60); do  # S3 gateway is up once it answers HTTP (any status)
  docker compose exec -T head python3 -c 'import os,urllib.request,urllib.error
try: urllib.request.urlopen(os.environ["S3_ENDPOINT"])
except urllib.error.HTTPError: pass' 2>/dev/null && break; sleep 2
done
docker compose exec -T head sinfo
