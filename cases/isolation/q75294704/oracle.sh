#!/bin/bash
set -e

CASE_ID="bench75294704"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers of the lab are as setup left them..."
(cd "$STATE_DIR" && sha256sum scan.c mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
echo "  -> OK"

echo "[oracle] the container bench75294704-scan: running the lab's image and program, not privileged, only the volume among the devices, and /scan reads two NEW labels of the volume..."
sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED"
