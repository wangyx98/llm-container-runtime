#!/bin/bash
set -e

CASE_ID="bench71671179"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the three nodes, then on each node from an empty cache: pull with the credentials, run the container, read the registry's log; then the negative control (another CA, same name)..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: master, worker1 and worker2 pull the image over HTTPS with verification and run it; the registry, its certificate and the credentials are as the lab made them."
