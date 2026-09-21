#!/bin/bash
set -e

WORK_DIR="/tmp/bench62408028"
BRIDGE="cni0"
TARGET_SUBNET_PREFIX="10.244.0."
STALE_SUBNET_PREFIX="10.85."
POD_NETNS_NAME="bench62408028-pod"
POD_NETNS_PATH="/var/run/netns/$POD_NETNS_NAME"
POD_CONTAINER_ID="bench62408028-pod"
IPAM_TARGET_DIR="$WORK_DIR/ipam-target"

echo "[oracle] check 1: '$BRIDGE' must now be on the CORRECT subnet"
echo "[oracle]          ($TARGET_SUBNET_PREFIX*), and the stale"
echo "[oracle]          ($STALE_SUBNET_PREFIX*) address must be GONE, not"
echo "[oracle]          just left alongside the new one..."
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "  -> FAIL: '$BRIDGE' does not exist"
    exit 1
fi
BRIDGE_ADDRS=$(ip -4 addr show "$BRIDGE" | grep 'inet ' | awk '{print $2}')
if ! echo "$BRIDGE_ADDRS" | grep -q "^${TARGET_SUBNET_PREFIX}"; then
    echo "  -> FAIL: '$BRIDGE' has no address in $TARGET_SUBNET_PREFIX*, got: $BRIDGE_ADDRS"
    exit 1
fi
if echo "$BRIDGE_ADDRS" | grep -q "^${STALE_SUBNET_PREFIX}"; then
    echo "  -> FAIL: '$BRIDGE' still has a stale $STALE_SUBNET_PREFIX* address"
    echo "     ($BRIDGE_ADDRS) -- it was patched, not genuinely reset"
    exit 1
fi
echo "  -> OK ($BRIDGE: $BRIDGE_ADDRS)"

echo "[oracle] check 2: the pod netns must have a real interface with an"
echo "[oracle]          IPv4 address on the correct subnet..."
# NOTE: 'ip netns exec' rather than a bare 'nsenter --net=...' throughout
# this file -- nsenter --net only switches the network namespace, not the
# mount namespace, so a plain sysfs read (like check 3's iflink lookup
# below) would silently see the HOST's pre-existing /sys mount instead of
# this netns's own. 'ip netns exec' isolates the mount namespace too and
# remounts /sys, which is what actually makes sysfs reads netns-correct.
POD_ADDR=$(sudo ip netns exec "$POD_NETNS_NAME" sh -c "ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}'")
if [ -z "$POD_ADDR" ]; then
    echo "  -> FAIL: no IPv4 address found on eth0 inside the pod netns"
    exit 1
fi
case "$POD_ADDR" in
    "${TARGET_SUBNET_PREFIX}"*) ;;
    *)
        echo "  -> FAIL: pod got $POD_ADDR, not on $TARGET_SUBNET_PREFIX*"
        exit 1
        ;;
esac
echo "  -> OK (pod eth0: $POD_ADDR)"

echo "[oracle] check 3 (anti-cheat): the pod's interface must be a REAL"
echo "[oracle]          bridge port of '$BRIDGE' -- a genuine veth pair, not"
echo "[oracle]          some other faked-up routing/NAT trick that merely"
echo "[oracle]          resembles connectivity..."
POD_IFLINK=$(sudo ip netns exec "$POD_NETNS_NAME" cat /sys/class/net/eth0/iflink)
MATCHED=""
for BRPORT in /sys/class/net/"$BRIDGE"/brif/*; do
    [ -e "$BRPORT" ] || continue
    PORT_NAME=$(basename "$BRPORT")
    PORT_IFINDEX=$(cat "/sys/class/net/$PORT_NAME/ifindex")
    if [ "$PORT_IFINDEX" = "$POD_IFLINK" ]; then
        MATCHED="$PORT_NAME"
        break
    fi
done
if [ -z "$MATCHED" ]; then
    echo "  -> FAIL: no veth under /sys/class/net/$BRIDGE/brif/ matches the"
    echo "     pod's eth0 (iflink=$POD_IFLINK) -- not genuinely bridged"
    exit 1
fi
echo "  -> OK (pod eth0 is the peer of host veth '$MATCHED', a real port of $BRIDGE)"

echo "[oracle] check 4: genuine end-to-end connectivity -- ping the gateway"
echo "[oracle]          FROM INSIDE the pod netns..."
GATEWAY="${TARGET_SUBNET_PREFIX}1"
if ! sudo ip netns exec "$POD_NETNS_NAME" ping -c 2 -W 2 "$GATEWAY" >/tmp/bench62408028_ping.log 2>&1; then
    echo "  -> FAIL: could not ping gateway $GATEWAY from inside the pod netns"
    cat /tmp/bench62408028_ping.log
    exit 1
fi
echo "  -> OK (gateway $GATEWAY reachable)"

echo "[oracle] check 5 (anti-cheat): a real host-local IPAM lease must exist"
echo "[oracle]          for this exact pod container ID, proving the real"
echo "[oracle]          CNI plugins were genuinely invoked, not hand-crafted..."
LEASE_FILE=$(sudo grep -rl "^${POD_CONTAINER_ID}" "$IPAM_TARGET_DIR" 2>/dev/null | head -1)
if [ -z "$LEASE_FILE" ]; then
    echo "  -> FAIL: no host-local IPAM lease file under $IPAM_TARGET_DIR"
    echo "     references container id '$POD_CONTAINER_ID'"
    exit 1
fi
LEASE_IP=$(basename "$LEASE_FILE")
echo "  -> OK (lease file for $POD_CONTAINER_ID: $LEASE_IP)"

echo "[oracle] ALL CHECKS PASSED"
