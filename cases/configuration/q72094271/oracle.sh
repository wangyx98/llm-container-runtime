#!/bin/bash
set -e

CASE_ID="bench72094271"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum probe.c pause.c mkimg.py patch_config.py lab.py verify.py baseline.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] new pods as the solution left the node, then a restart of the service and new pods again (core limit of the main process, of exec'd processes, SIGABRT without a core file)..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: new containers get core limit 0/0 for the main process and for exec, aborting processes leave no core file, and it holds after a restart of the service."
