#!/bin/bash
set -e

CASE_ID="bench72968351"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum podmark.c mkimg.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] checking the wrappers against the rootless runner (export of the seed, import of new images, the CRI, Pods, the restart of the user service)..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: ctr-k3s and crictl-k3s of user $CASE_ID use the rootless K3s-like runner, before and after the restart of its service."
