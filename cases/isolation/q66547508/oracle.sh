#!/bin/bash
set -e

CASE_ID="bench66547508"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the lab is as setup left it (helpers, the nonce service)..."
(cd "$STATE_DIR" && sha256sum app.c nonce_server.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[oracle] the container $CASE_ID runs the bundle's program; root inside is host id 5000 in a user namespace of its own; its network namespace is the host's; /sys is not mounted or is the host's sysfs, read-only; and it reads the host's new nonce..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the container runs with the user namespace mapping and the host network namespace together, without a fake /sys, and works with the host's loopback service."
