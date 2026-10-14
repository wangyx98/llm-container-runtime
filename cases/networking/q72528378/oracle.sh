#!/bin/bash
set -e

CASE_ID="bench72528378"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the service, then from an empty store: the tag new re-pointed to a new image, the cold CRI pull of the given reference (no port), the registry's log, create and start of the container, nonce and label..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: after a restart containerd 2.0.0 pulls the given reference (no port) over plain HTTP from port 80, it is the new image and not the one of the other tag, and the container runs."
