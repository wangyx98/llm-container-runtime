#!/bin/bash
set -e

CASE_ID="bench49877639"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (dockerd and containerd of the lab, plugin installed and disabled, plugin directory unchanged)..."
sudo bash -c 'cd "$1" && sha256sum $(cat helpers.list) | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] controls: 'docker plugin enable' fails with the question's error and leaves the plugin disabled; a repaired COPY of the plugin directory (another name) runs systemd as PID 1 here..."
OUT=$(sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" 2>&1) || { echo "$OUT" | tail -4; fail "see above"; }
echo "$OUT" | tail -3

echo "[precondition] PASS - the plugin does not enable; the repair works on this machine."
