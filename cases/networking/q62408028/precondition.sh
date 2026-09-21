#!/bin/bash
set -e

WORK_DIR="/tmp/bench62408028"
CNI_BIN_DIR="$WORK_DIR/cni-bin"
NETCONF="$WORK_DIR/netconf.json"

BRIDGE="cni0"
STALE_SUBNET_PREFIX="10.85."
TARGET_SUBNET="10.244.0.0/24"

POD_NETNS_NAME="bench62408028-pod"
POD_NETNS_PATH="/var/run/netns/$POD_NETNS_NAME"

echo "[precondition] checking the CNI plugin binaries are present..."
test -x "$CNI_BIN_DIR/bridge"
test -x "$CNI_BIN_DIR/host-local"
echo "  -> OK"

echo "[precondition] checking '$BRIDGE' exists and is stuck on the WRONG"
echo "[precondition]          (stale) subnet, not the intended one..."
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "  -> FAIL: '$BRIDGE' does not exist -- setup.sh did not run correctly"
    exit 1
fi
BRIDGE_ADDR=$(ip -4 addr show "$BRIDGE" | grep 'inet ' | awk '{print $2}' | head -1)
if [ -z "$BRIDGE_ADDR" ]; then
    echo "  -> FAIL: '$BRIDGE' has no IPv4 address at all"
    exit 1
fi
case "$BRIDGE_ADDR" in
    "$STALE_SUBNET_PREFIX"*) ;;
    *)
        echo "  -> FAIL: expected '$BRIDGE' to still have a stale $STALE_SUBNET_PREFIX* address, got $BRIDGE_ADDR"
        exit 1
        ;;
esac
echo "  -> OK ($BRIDGE currently has stale address $BRIDGE_ADDR)"

echo "[precondition] checking netconf.json exists and targets the CORRECT"
echo "[precondition]          subnet ($TARGET_SUBNET)..."
test -f "$NETCONF"
python3 -c "
import json
with open('$NETCONF') as f:
    cfg = json.load(f)
subnet = cfg['ipam']['ranges'][0][0]['subnet']
assert subnet == '$TARGET_SUBNET', f'netconf.json targets {subnet}, expected $TARGET_SUBNET'
"
echo "  -> OK"

echo "[precondition] checking the pod network namespace exists and is"
echo "[precondition]          still empty (no attachment yet)..."
test -f "$POD_NETNS_PATH"
# NOTE: deliberately 'ip netns exec' rather than a bare 'nsenter --net=...'.
# nsenter --net only switches the NETWORK namespace, not the mount
# namespace -- /sys stays the host's pre-existing sysfs mount (bound to
# the host/init netns since boot), so 'ls /sys/class/net' under a plain
# nsenter --net would silently report the HOST's interfaces instead of
# this netns's own. 'ip netns exec' additionally isolates the mount
# namespace and remounts /sys, which is exactly why it exists and is the
# correct tool here (netlink-based commands like 'ip link'/'ip addr' are
# unaffected by this and would have worked under plain nsenter too, but
# sysfs reads like this one are not).
TOTAL_IFACES=$(sudo ip netns exec "$POD_NETNS_NAME" sh -c "ip -o link show | wc -l")
IFACE_COUNT=$((TOTAL_IFACES - 1))
if [ "$IFACE_COUNT" -ne 0 ]; then
    echo "  -> FAIL: pod netns already has $IFACE_COUNT non-loopback interface(s)"
    exit 1
fi
echo "  -> OK (pod netns is clean)"

echo "[precondition] PASS - stale bridge in place, correct target netconf"
echo "[precondition]        ready, pod netns clean and unattached."
