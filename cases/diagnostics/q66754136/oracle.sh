#!/bin/bash
set -e

CASE_ID="bench66754136"
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
[ -s "$WORK_DIR/ref-filter.sh" ] || fail "there is no $WORK_DIR/ref-filter.sh"
keep
echo "  -> OK"

echo "[oracle] the filters for several texts (with dots, slashes, colons, dashes), each given to ctr as one argument: they must list exactly the refs of k8s.io that contain the text..."
verify first
echo "[oracle] the node changes (images added to k8s.io, some with refs that contain the same texts); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: finding the images changed nothing (no ref, no digest, no blob of any namespace)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node every filter lists exactly the refs of k8s.io that contain its text, nothing more and nothing less, and the store is as it was."
