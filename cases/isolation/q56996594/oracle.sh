#!/bin/bash
set -e

CASE_ID="bench56996594"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum marker.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] checking the rootless chain (users and groups of the processes, the maps, the pull, the restart, the offline run) from the host..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: user $CASE_ID runs and manages containers with no rootful daemon, from the image of the lab's registry, and again after the restart of its service."
