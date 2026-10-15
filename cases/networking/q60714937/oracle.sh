#!/bin/bash
set -e

CASE_ID="bench60714937"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the lab is as setup left it (helpers, registry process)..."
(cd "$STATE_DIR" && sha256sum mkoci.py registry.py lab.py verify.py create-cluster.sh app.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
P=$(cat "$WORK_DIR/registry.pid" 2>/dev/null || true)
[ -n "$P" ] && tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | grep -q registry.py || fail "the registry of the lab is not running"
echo "  -> OK"

echo "[oracle] every node of the cluster pulls a NEW image from the registry over plain HTTP (cache emptied, one pod per node with imagePullPolicy Always, a nonce each), then the cluster is deleted and"
echo "         created again from the cluster file with the original script, and the check is repeated (this takes several minutes)..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: all three nodes use the same working registry configuration, pull new images from the HTTP registry (the registry log shows each node), and the cluster file keeps that after a rebuild."
