#!/bin/bash
set -e

CASE_ID="bench74243015"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the CRI-O service, clearing its store, creating a brand-new sandbox, and reading the lab's registry and proxy logs..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: after a restart the CRI-O service pulls the pause image through the lab's proxy and creates a sandbox; the pause source, the proxy and the registry are as the lab made them."
