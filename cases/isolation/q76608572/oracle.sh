#!/bin/bash
set -e

CASE_ID="bench76608572"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers of the lab are as setup left them, and the solution's script exists..."
(cd "$STATE_DIR" && sha256sum idle.c lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/cpu-report.sh" ] || fail "there is no $WORK_DIR/cpu-report.sh"
echo "  -> OK"

echo "[oracle] four NEW containers (new CPU sets, cgroup paths, IDs and PIDs; private and host cgroup namespace; one of them given by PID, one by container ID, two pinned): the script's report against what the lab knows..."
sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED"
