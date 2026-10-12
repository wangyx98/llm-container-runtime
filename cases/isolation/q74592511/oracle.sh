#!/bin/bash
set -e

CASE_ID="bench74592511"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers of the lab are as setup left them..."
(cd "$STATE_DIR" && sha256sum mkimg.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
echo "  -> OK"

echo "[oracle] socket without world bits, users in no root/sudo/wheel and without sudo rights, crictl pointing at containerd, the second user refused, the first one served with an image the lab imports now, and all of it again after a restart of containerd..."
sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED"
