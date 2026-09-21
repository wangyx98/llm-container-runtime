#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

WORK_DIR="/tmp/bench62408028"
CNI_PLUGINS_VERSION="v1.5.1"
CNI_BIN_DIR="$WORK_DIR/cni-bin"
# Cache the downloaded/extracted plugin binaries OUTSIDE $WORK_DIR: this
# script (like every case's setup.sh) is re-run from scratch for every
# LLM sample in a benchmark pass, and $WORK_DIR itself must be wiped each
# time (see below) -- but there's no reason to re-download the same ~8MB
# GitHub release tarball over the network on every single sample when a
# local copy will do. $CNI_BIN_DIR is (re-)populated from this cache.
CNI_CACHE_DIR="/tmp/.bench62408028-cni-cache"
NETCONF="$WORK_DIR/netconf.json"

BRIDGE="cni0"
STALE_SUBNET="10.85.0.0/16"
TARGET_SUBNET="10.244.0.0/24"

STALE_NETNS_NAME="bench62408028-stale"
STALE_NETNS_PATH="/var/run/netns/$STALE_NETNS_NAME"
STALE_CONTAINER_ID="bench62408028-stale"
STALE_IPAM_DIR="$WORK_DIR/ipam-stale"

POD_NETNS_NAME="bench62408028-pod"
POD_NETNS_PATH="/var/run/netns/$POD_NETNS_NAME"

# same lesson learned the hard way on cases/filesystem/q69295491 and
# cases/compatibility/q65650082 -- never hardcode "linux-amd64", the CNI
# plugins release ships separate per-arch tarballs too.
case "$(uname -m)" in
    x86_64|amd64)   CNI_ARCH="amd64" ;;
    aarch64|arm64)  CNI_ARCH="arm64" ;;
    armv7l|armhf)   CNI_ARCH="arm" ;;
    ppc64le)        CNI_ARCH="ppc64le" ;;
    s390x)          CNI_ARCH="s390x" ;;
    *)
        echo "[setup] WARNING: unrecognized architecture '$(uname -m)', defaulting to amd64" >&2
        CNI_ARCH="amd64"
        ;;
esac

echo "[setup] cleaning up any leftover state from a previous run (idempotency)..."
for ns_path in "$POD_NETNS_PATH" "$STALE_NETNS_PATH"; do
    if [ -f "$ns_path" ]; then
        sudo umount "$ns_path" 2>/dev/null || true
        sudo rm -f "$ns_path"
    fi
done
if ip link show "$BRIDGE" >/dev/null 2>&1; then
    sudo ip link set "$BRIDGE" down 2>/dev/null || true
    sudo ip link delete "$BRIDGE" 2>/dev/null || true
fi

# NOTE: this wipes the whole work dir -- including $CNI_BIN_DIR, since it
# is a subdirectory of $WORK_DIR -- so it must run BEFORE the CNI plugin
# install step below, not after (an earlier version of this script
# installed the plugins first and then deleted them right back out from
# under itself here, which is why $CNI_BIN_DIR/bridge would go missing).
echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$STALE_IPAM_DIR"

echo "[setup] ensuring the bridge/host-local CNI plugins ($CNI_PLUGINS_VERSION, $CNI_ARCH) are installed..."
if [ ! -x "$CNI_CACHE_DIR/bridge" ] || [ ! -x "$CNI_CACHE_DIR/host-local" ]; then
    echo "  -> not cached at $CNI_CACHE_DIR yet, downloading..."
    sudo mkdir -p "$CNI_CACHE_DIR"
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${CNI_ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
        -o /tmp/cni-plugins.tgz
    sudo tar xzf /tmp/cni-plugins.tgz -C "$CNI_CACHE_DIR"
    rm -f /tmp/cni-plugins.tgz
else
    echo "  -> already cached at $CNI_CACHE_DIR, skipping download"
fi
mkdir -p "$CNI_BIN_DIR"
sudo cp "$CNI_CACHE_DIR/bridge" "$CNI_CACHE_DIR/host-local" "$CNI_BIN_DIR/"
sudo chmod +x "$CNI_BIN_DIR/bridge" "$CNI_BIN_DIR/host-local"
command -v "$CNI_BIN_DIR/bridge" >/dev/null
command -v "$CNI_BIN_DIR/host-local" >/dev/null
echo "  -> OK ($CNI_BIN_DIR/bridge, $CNI_BIN_DIR/host-local present)"

echo "[setup] creating the STALE cni0 bridge, simulating a leftover from an"
echo "[setup] earlier, unrelated pod attachment that used the WRONG subnet"
echo "[setup] ($STALE_SUBNET instead of the cluster's real $TARGET_SUBNET)..."
cat > "$WORK_DIR/netconf-stale.json" <<EOF
{
  "cniVersion": "1.0.0",
  "name": "bench62408028",
  "type": "bridge",
  "bridge": "$BRIDGE",
  "isGateway": true,
  "ipMasq": true,
  "hairpinMode": true,
  "ipam": {
    "type": "host-local",
    "dataDir": "$STALE_IPAM_DIR",
    "routes": [{"dst": "0.0.0.0/0"}],
    "ranges": [[{"subnet": "$STALE_SUBNET"}]]
  }
}
EOF

sudo mkdir -p /var/run/netns
sudo touch "$STALE_NETNS_PATH"
sudo unshare --net="$STALE_NETNS_PATH" true

sudo env CNI_COMMAND=ADD CNI_CONTAINERID="$STALE_CONTAINER_ID" \
    CNI_NETNS="$STALE_NETNS_PATH" CNI_IFNAME=eth0 CNI_PATH="$CNI_BIN_DIR" \
    "$CNI_BIN_DIR/bridge" < "$WORK_DIR/netconf-stale.json" > "$WORK_DIR/setup-stale-add.json"
echo "  -> stale attachment created, $BRIDGE now has an address in $STALE_SUBNET:"
ip -4 addr show "$BRIDGE" | grep 'inet '

echo "[setup] releasing that stale ATTACHMENT (CNI DEL) -- this removes its"
echo "[setup] veth pair and IPAM lease, but deliberately leaves the '$BRIDGE'"
echo "[setup] bridge device itself behind, still configured for the wrong"
echo "[setup] subnet -- exactly the 'stale bridge left over after a pod was"
echo "[setup] removed' state the real bug report describes..."
sudo env CNI_COMMAND=DEL CNI_CONTAINERID="$STALE_CONTAINER_ID" \
    CNI_NETNS="$STALE_NETNS_PATH" CNI_IFNAME=eth0 CNI_PATH="$CNI_BIN_DIR" \
    "$CNI_BIN_DIR/bridge" < "$WORK_DIR/netconf-stale.json" > /dev/null
sudo umount "$STALE_NETNS_PATH" 2>/dev/null || true
sudo rm -f "$STALE_NETNS_PATH"

echo "[setup] confirming $BRIDGE persisted with the stale address after DEL..."
ip -4 addr show "$BRIDGE" | grep 'inet '

echo "[setup] writing the CURRENT/intended netconf.json (the correct"
echo "[setup] cluster-wide pod subnet, $TARGET_SUBNET)..."
cat > "$NETCONF" <<EOF
{
  "cniVersion": "1.0.0",
  "name": "bench62408028",
  "type": "bridge",
  "bridge": "$BRIDGE",
  "isGateway": true,
  "ipMasq": true,
  "hairpinMode": true,
  "ipam": {
    "type": "host-local",
    "dataDir": "$WORK_DIR/ipam-target",
    "routes": [{"dst": "0.0.0.0/0"}],
    "ranges": [[{"subnet": "$TARGET_SUBNET"}]]
  }
}
EOF

echo "[setup] creating the empty pod network namespace to be attached..."
sudo touch "$POD_NETNS_PATH"
sudo unshare --net="$POD_NETNS_PATH" true

echo "[setup] done. '$BRIDGE' exists with a STALE address in $STALE_SUBNET;"
echo "[setup] netconf.json targets $TARGET_SUBNET; the pod netns at"
echo "[setup] $POD_NETNS_PATH is empty and waiting to be attached."
