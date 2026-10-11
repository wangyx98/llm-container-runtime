#!/bin/bash
set -e

CASE_ID="bench70986540"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/image-created.sh" ] || fail "there is no $WORK_DIR/image-created.sh"
keep
echo "  -> OK"

echo "[oracle] the images of the node: every name with its image ID and the created value of its config (a time zone offset, one config without the field: unknown)..."
verify first
keep
echo "[oracle] the node changes (a new image is imported and the name shop/web:stable moves to it); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: reading the images changed nothing (no name, no image ID, no blob)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists every image name the CRI shows with its image ID and the created value of the image config exactly as written (unknown when there is none), not the time of the import, and does not change the store."
