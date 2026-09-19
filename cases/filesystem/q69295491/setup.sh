#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# That dialog needs a TTY and hangs forever when this script is run
# non-interactively by run_single_case.py / run_benchmark.py (subprocess
# with no stdin). Force both apt's own prompts and needrestart into fully
# automatic/non-interactive mode.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Same pinned CRI-O/crictl versions as cases/compatibility/q65650082 -- a
# battle-tested stable stream rather than "latest" (see that case's
# setup.sh for why), and reusing the exact same install recipe means this
# step is a fast no-op if that case already ran on this host.
CRIO_VERSION="v1.34"
CRICTL_VERSION="v1.34.0"
IMAGE="docker.io/library/busybox:1.36"
WORK_DIR="/tmp/bench69295491"
HOST_DIR="$WORK_DIR/hostdir"
POD_NAME="bench69295491-pod"
CONTAINER_NAME="bench69295491"

echo "[setup] ensuring CRI-O ($CRIO_VERSION stream) is installed..."
if ! command -v crio >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl gnupg ca-certificates

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null

    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" cri-o
fi

echo "[setup] confirming crio binary is on PATH..."
command -v crio
crio --version | head -1

echo "[setup] ensuring crictl ($CRICTL_VERSION, matching CRI-O's minor) is installed..."
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
command -v crictl
crictl --version

echo "[setup] pointing crictl explicitly at the CRI-O socket..."
cat <<EOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
debug: false
EOF

echo "[setup] forcing the cgroupfs cgroup manager (see q65650082/setup.sh for why)..."
sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/01-cgroup-manager.conf > /dev/null
[crio.runtime]
cgroup_manager = "cgroupfs"
EOF

echo "[setup] enabling the default CNI bridge plugin (ships disabled)..."
if [ -f /etc/cni/net.d/10-crio-bridge.conflist.disabled ]; then
    sudo mv /etc/cni/net.d/10-crio-bridge.conflist.disabled /etc/cni/net.d/10-crio-bridge.conflist
fi

echo "[setup] (re)starting crio.service so the config above takes effect..."
sudo systemctl enable crio.service >/dev/null 2>&1 || true
sudo systemctl restart crio.service
sleep 2
sudo systemctl is-active crio.service

echo "[setup] removing any leftover pod/container from a previous run (idempotency)..."
for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
    sudo crictl stopp "$p" 2>/dev/null || true
    sudo crictl rmp -f "$p" 2>/dev/null || true
done
for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
    sudo crictl stop "$c" 2>/dev/null || true
    sudo crictl rm -f "$c" 2>/dev/null || true
done

echo "[setup] pre-pulling the target image..."
sudo crictl pull "$IMAGE"

echo "[setup] creating the host directory to be bind-mounted, with a seed file..."
rm -rf "$WORK_DIR"
mkdir -p "$HOST_DIR"
echo "SO69295491_BIND_MOUNT_SEED_CONTENT" > "$HOST_DIR/data.txt"
# world-writable so that a container process running as root (no user-ns
# remap here) can also write NEW files back into it for the write-through
# check in oracle.sh, regardless of the exact uid CRI-O ends up using.
chmod 777 "$HOST_DIR"
chmod 666 "$HOST_DIR/data.txt"

echo "[setup] done. CRI-O is running, host dir is at $HOST_DIR with a seed"
echo "[setup] file, image is cached, and no pod/container named"
echo "[setup] '$POD_NAME'/'$CONTAINER_NAME' exists yet."
