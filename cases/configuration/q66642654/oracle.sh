#!/bin/bash
set -e

CASE_ID="bench66642654"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum $(cat helpers.list) | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] a new build of myapp:latest is pulled and run as the node was left, then after 'mk8sctl restart' another one..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the node pulls new builds from the plain-HTTP registry, as left and after a restart of the node."
