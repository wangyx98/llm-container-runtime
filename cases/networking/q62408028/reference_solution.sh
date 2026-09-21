#!/bin/bash
set -e

WORK_DIR="/tmp/bench62408028"
CNI_BIN_DIR="$WORK_DIR/cni-bin"
NETCONF="$WORK_DIR/netconf.json"

BRIDGE="cni0"
POD_NETNS_NAME="bench62408028-pod"
POD_NETNS_PATH="/var/run/netns/$POD_NETNS_NAME"
POD_CONTAINER_ID="bench62408028-pod"

echo "[solution] '$BRIDGE' already exists but is stuck on the WRONG subnet"
echo "[solution] (left over from an earlier, unrelated pod attachment). The"
echo "[solution] bridge CNI plugin refuses to just bolt a second, conflicting"
echo "[solution] address onto an existing bridge -- exactly like the real bug"
echo "[solution] report's own accepted answer describes. A Linux bridge can"
echo "[solution] only sanely serve one subnet at a time, and the CORRECT fix"
echo "[solution] is to reset it so it gets recreated fresh for the actual"
echo "[solution] intended subnet -- not to change netconf.json to match"
echo "[solution] whatever subnet happens to already be there."
sudo ip link set "$BRIDGE" down 2>/dev/null || true
sudo ip link delete "$BRIDGE" 2>/dev/null || true
if ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "[solution] FAILED: '$BRIDGE' still exists after attempting to delete it"
    exit 1
fi
echo "  -> OK ('$BRIDGE' removed)"

echo "[solution] attaching the pod network namespace via the real bridge +"
echo "[solution] host-local CNI plugins -- the same CNI_COMMAND=ADD protocol"
echo "[solution] CRI-O/kubelet use -- against the CURRENT, correct netconf..."
sudo env CNI_COMMAND=ADD CNI_CONTAINERID="$POD_CONTAINER_ID" \
    CNI_NETNS="$POD_NETNS_PATH" CNI_IFNAME=eth0 CNI_PATH="$CNI_BIN_DIR" \
    "$CNI_BIN_DIR/bridge" < "$NETCONF" > "$WORK_DIR/solution-add.json"

echo "[solution] CNI ADD result:"
cat "$WORK_DIR/solution-add.json"
echo
ASSIGNED_IP=$(python3 -c "
import json
with open('$WORK_DIR/solution-add.json') as f:
    print(json.load(f)['ips'][0]['address'])
")
echo "[solution] done. Pod interface got $ASSIGNED_IP on the CORRECT subnet,"
echo "[solution] and '$BRIDGE' was reset instead of just growing a second,"
echo "[solution] conflicting address."
