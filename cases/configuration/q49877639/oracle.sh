#!/bin/bash
set -e

CASE_ID="bench49877639"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum $(cat helpers.list) | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] the plugin as left, then after 'docker plugin disable' and 'enable': systemd as its init, a unit active, the driver answering..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: systemd runs as the init of the managed plugin and its driver works, as left and after a disable and enable."
