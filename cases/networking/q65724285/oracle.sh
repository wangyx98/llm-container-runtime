#!/bin/bash
set -e

CASE_ID="bench65724285"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the service, then twice from nothing (the tag latest re-pointed to a new image each time): the exact ctr command with --hosts-dir and ctr run, and, separately, the CRI pull, sandbox and container; registry log, nonce and label for each..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: after a restart both entrances work: ctr (with the hosts directory of the command) and the CRI (config.toml) each pull my-alpine:latest over plain HTTP and run it; the registry and the daemon are as the lab made them."
