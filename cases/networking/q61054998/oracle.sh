#!/bin/bash
set -e

CASE_ID="bench61054998"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the lab is as setup left it (helpers, the host service on 127.0.0.1 only, the program of the bundle)..."
(cd "$STATE_DIR" && sha256sum app.c nonce_server.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK"

echo "[oracle] the container $CASE_ID is a new one from the bundle running the same program; its network namespace is the host's; its mount and pid namespaces are its own; it reads the host's new nonce from 127.0.0.1 and the host reads the container's listener on 127.0.0.1..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the runc container shares the host's network namespace (loopback in both directions) and keeps its own mount and pid namespaces."
