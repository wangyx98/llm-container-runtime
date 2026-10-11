#!/bin/bash
set -e

CASE_ID="bench70948748"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers, pods and containers untouched), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c app.c cni-stub.sh | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
keep
[ -s "$WORK_DIR/pid-owner.sh" ] || fail "there is no $WORK_DIR/pid-owner.sh"
echo "  -> OK"

echo "[oracle] the script names the owner of processes: the first process, a grandchild and an orphan of every container, and a process of the node (null)..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" first || fail "see above"
keep
echo "  -> OK: the processes and the containers are as they were (reading is not changing)"

echo "[oracle] the node changes (a new pod, a new container in an old pod, new PIDs); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
python3 "$STATE_DIR/verify.py" "$WORK_DIR" second || fail "see above"
keep
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script names the container (full ID), the pod (UID, namespace, name) and the first process of any process of a container, at any depth, the same-named pods kept apart, null for a process of the node, and changes nothing."
