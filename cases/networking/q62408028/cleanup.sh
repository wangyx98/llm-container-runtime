#!/bin/bash
# no 'set -e': containers/netns/bridges may legitimately not exist yet, and
# commands here are allowed to fail without aborting cleanup.

WORK_DIR="/tmp/bench62408028"
CNI_BIN_DIR="$WORK_DIR/cni-bin"
NETCONF="$WORK_DIR/netconf.json"

BRIDGE="cni0"
STALE_NETNS_NAME="bench62408028-stale"
STALE_NETNS_PATH="/var/run/netns/$STALE_NETNS_NAME"
STALE_CONTAINER_ID="bench62408028-stale"

POD_NETNS_NAME="bench62408028-pod"
POD_NETNS_PATH="/var/run/netns/$POD_NETNS_NAME"
POD_CONTAINER_ID="bench62408028-pod"

echo "[cleanup] releasing the pod's CNI attachment (if any), so its IPAM"
echo "[cleanup]          lease is returned properly rather than just deleting"
echo "[cleanup]          files out from under host-local's bookkeeping..."
if [ -f "$POD_NETNS_PATH" ] && [ -x "$CNI_BIN_DIR/bridge" ] && [ -f "$NETCONF" ]; then
    sudo env CNI_COMMAND=DEL CNI_CONTAINERID="$POD_CONTAINER_ID" \
        CNI_NETNS="$POD_NETNS_PATH" CNI_IFNAME=eth0 CNI_PATH="$CNI_BIN_DIR" \
        "$CNI_BIN_DIR/bridge" < "$NETCONF" > /dev/null 2>&1 || true
fi

echo "[cleanup] releasing the stale attachment (if any run left one behind)..."
if [ -f "$STALE_NETNS_PATH" ] && [ -x "$CNI_BIN_DIR/bridge" ]; then
    STALE_NETCONF="$WORK_DIR/netconf-stale.json"
    if [ -f "$STALE_NETCONF" ]; then
        sudo env CNI_COMMAND=DEL CNI_CONTAINERID="$STALE_CONTAINER_ID" \
            CNI_NETNS="$STALE_NETNS_PATH" CNI_IFNAME=eth0 CNI_PATH="$CNI_BIN_DIR" \
            "$CNI_BIN_DIR/bridge" < "$STALE_NETCONF" > /dev/null 2>&1 || true
    fi
fi

echo "[cleanup] removing network namespaces..."
for ns_path in "$POD_NETNS_PATH" "$STALE_NETNS_PATH"; do
    if [ -f "$ns_path" ]; then
        sudo umount "$ns_path" 2>/dev/null || true
        sudo rm -f "$ns_path"
    fi
done

echo "[cleanup] removing the '$BRIDGE' bridge, if it still exists..."
if ip link show "$BRIDGE" >/dev/null 2>&1; then
    sudo ip link set "$BRIDGE" down 2>/dev/null || true
    sudo ip link delete "$BRIDGE" 2>/dev/null || true
fi

echo "[cleanup] removing work dir (CNI binaries, netconfs, IPAM leases)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
