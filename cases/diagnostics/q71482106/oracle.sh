#!/bin/bash
set -e

CASE_ID="bench71482106"
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
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c cni-stub.sh | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
keep
[ -s "$WORK_DIR/pause-map.sh" ] || fail "there is no $WORK_DIR/pause-map.sh"
echo "  -> OK"

echo "[oracle] the script maps the sandboxes of the node: full IDs, the pause process of each (the workload that runs a program called pause is not one), its net namespace, and its own containers..."
verify first
keep
echo "  -> OK: the node is unchanged by reading it"

echo "[oracle] the node changes (a new pod, a new container in an existing pod); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists every pod sandbox by its full ID with the PID of its own pause process (found through the runtime, not by the name pause), its net namespace and the containers of that pod with their PIDs and net namespaces (the pod's), and changes nothing on the node."
