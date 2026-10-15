#!/bin/bash
set -e

CASE_ID="bench59744000"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the lab is as setup left it (containerd running, helpers)..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running (it was stopped or replaced)"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py kubelet-sim app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
echo "  -> OK"

echo "[oracle] containerd keeps the systemd driver, the kubelet configuration agrees, and the kubelet starts calico-node and kube-proxy on new pod uids (checked on the CRI and in their cgroups)..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the node's pods start because the kubelet uses the systemd cgroup driver like containerd's runc; containerd was not changed."
