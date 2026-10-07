#!/bin/bash
set -e

WORK_DIR="/tmp/bench58429514"
POD_NAME="bench58429514-pod"

echo "[precondition] check 1: the live CRI-O daemon uses the systemd cgroup manager..."
LIVE_MANAGER=$(sudo crio status config 2>/dev/null | sed -n 's/^[[:space:]]*cgroup_manager *= *"\(.*\)"/\1/p' | head -1)
if [ "$LIVE_MANAGER" != "systemd" ]; then
    echo "[precondition] FAIL: live cgroup_manager is '${LIVE_MANAGER:-unknown}', expected 'systemd'"
    exit 1
fi
echo "  -> OK (cgroup_manager = $LIVE_MANAGER)"

echo "[precondition] check 2: the pod config carries a cgroupfs-style cgroup_parent..."
PARENT=$(python3 -c "
import json
print(json.load(open('$WORK_DIR/pod.json')).get('linux', {}).get('cgroup_parent', ''))
")
if [ "$PARENT" != "/Burstable/pod_123-456" ]; then
    echo "[precondition] FAIL: unexpected cgroup_parent '$PARENT'"
    exit 1
fi
echo "  -> OK (cgroup_parent = $PARENT)"

echo "[precondition] check 3: 'crictl runp' must currently FAIL with the slice error..."
if sudo crictl runp "$WORK_DIR/pod.json" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    echo "[precondition] FAIL: runp succeeded before any fix was applied"
    cat "$WORK_DIR/pre_out.txt"
    exit 1
fi
if ! grep -q "did not receive slice as parent" "$WORK_DIR/pre_err.txt"; then
    echo "[precondition] FAIL: runp failed, but not with the expected slice error:"
    tail -3 "$WORK_DIR/pre_err.txt"
    exit 1
fi
echo "  -> OK (error: $(grep -o 'cri-o configured with systemd.*' "$WORK_DIR/pre_err.txt" | head -1))"

echo "[precondition] check 4: the failed runp must not have left a pod behind..."
LEFT=$(sudo crictl pods --name "$POD_NAME" -q | wc -l)
if [ "$LEFT" != "0" ]; then
    echo "[precondition] FAIL: $LEFT pod(s) named $POD_NAME exist"
    exit 1
fi
echo "  -> OK"

echo "[precondition] PASS - the environment is in the expected broken initial state."
