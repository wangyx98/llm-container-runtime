#!/bin/bash
set -e

CASE_ID="bench61055917"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }   # runs the script, checks the node is unchanged and the other socket untouched, compares
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c tap.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/list-node.sh" ] || fail "there is no $WORK_DIR/list-node.sh"
keep
echo "  -> OK"

echo "[oracle] the node: every container of k8s.io with its image, the digest of the image and the PID of its task (null without one), and every image with its digest; the other socket untouched..."
verify first
echo "[oracle] the node changes (a task killed and removed, a container started, a new image with a new container); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: reading the node changed nothing (no image, blob, container, label or task)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists the containers and images of the node's own containerd with their digests and PIDs, changes nothing, and never touches the other socket."
