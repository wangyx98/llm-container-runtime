#!/bin/bash
set -e

CASE_ID="bench79305194"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the service, then from an empty store: a new image in the registry, the CRI pull with the credentials (over plain HTTP), without and with wrong credentials (refused), create and start of the container, nonce and label..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: containerd 2.0.0 (version 3 configuration, CRI images plugin ok) pulls the image from the plain HTTP registry with the credentials of the request, the authentication is still enforced, and the container runs."
