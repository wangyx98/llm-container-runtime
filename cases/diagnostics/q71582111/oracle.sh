#!/bin/bash
set -e

CASE_ID="bench71582111"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/list-images.sh" ] || fail "there is no $WORK_DIR/list-images.sh"
keep
echo "  -> OK"

echo "[oracle] the images of the node: every name in every namespace with its digest (the same name as two images, several names for one image, no entries by image ID)..."
verify
keep
echo "[oracle] the node changes (images added in default, k8s.io and a new namespace, a name moved to another image); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify
keep
echo "  -> OK: reading the images changed nothing (no name, no digest, no blob of any namespace)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists every image name of every namespace with the digest of that name, nothing else, and does not change the store."
