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

echo "[setup] ensuring CRI-O is installed AT the pinned $CRIO_VERSION stream..."
echo "[setup] (not just 'installed at all' -- a host that already has a"
echo "[setup]  different crio version from an earlier experiment must be"
echo "[setup]  corrected to the pinned version, not left as-is)"
PINNED_CRIO_MINOR="${CRIO_VERSION#v}"
CURRENT_CRIO_VERSION=""
if command -v crio >/dev/null 2>&1; then
    CURRENT_CRIO_VERSION=$(crio --version 2>/dev/null | head -1 | awk '{print $3}')
fi
if [[ "$CURRENT_CRIO_VERSION" != "${PINNED_CRIO_MINOR}."* ]]; then
    echo "[setup] crio is '${CURRENT_CRIO_VERSION:-not installed}', pinned stream is $CRIO_VERSION -- (re)installing..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl gnupg ca-certificates

    # a stale apt source pinned to a DIFFERENT cri-o stream (e.g. left over
    # from an earlier manual install) would otherwise win version
    # resolution over the one we're about to add below.
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q "isv:/cri-o:/stable:/" "$f" 2>/dev/null; then
            echo "[setup]   removing pre-existing CRI-O apt source: $f"
            sudo rm -f "$f"
        fi
    done

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null

    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" --allow-downgrades --allow-change-held-packages cri-o
else
    echo "[setup] crio $CURRENT_CRIO_VERSION already matches the pinned $CRIO_VERSION stream, skipping install."
fi

echo "[setup] confirming crio binary is on PATH..."
command -v crio
crio --version | head -1

echo "[setup] ensuring crictl is installed AT the pinned $CRICTL_VERSION (matching CRI-O's minor)..."
CURRENT_CRICTL_VERSION=""
if command -v crictl >/dev/null 2>&1; then
    CURRENT_CRICTL_VERSION=$(crictl --version 2>/dev/null | awk '{print $3}')
fi
if [ "$CURRENT_CRICTL_VERSION" != "$CRICTL_VERSION" ]; then
    echo "[setup] crictl is '${CURRENT_CRICTL_VERSION:-not installed}', pinned version is $CRICTL_VERSION -- (re)installing..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
else
    echo "[setup] crictl $CURRENT_CRICTL_VERSION already matches the pinned $CRICTL_VERSION, skipping install."
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

echo "[setup] working around a systemd-networkd vs CNI bridge-plugin MAC"
echo "[setup] conflict: systemd's default MACAddressPolicy=persistent for"
echo "[setup] virtual NICs reassigns a freshly-created veth's MAC right after"
echo "[setup] the CNI bridge plugin sets it, before CRI-O reads it back --"
echo "[setup] this causes a deterministic 'Interface vethXXX Mac doesn't"
echo "[setup] match ... not found' failure on EVERY RunPodSandbox call, on"
echo "[setup] any host where systemd-networkd (not NetworkManager) manages"
echo "[setup] networking. Only applies when systemd-networkd is active."
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    if [ ! -f /etc/systemd/network/98-cni-veth.link ]; then
        echo "[setup] systemd-networkd is active -- installing a udev .link rule so"
        echo "[setup] CNI-created veth* interfaces keep the MAC CNI assigned them..."
        cat <<'EOF' | sudo tee /etc/systemd/network/98-cni-veth.link > /dev/null
[Match]
OriginalName=veth*

[Link]
MACAddressPolicy=none
EOF
        sudo udevadm control --reload
    else
        echo "[setup] .link rule already present, skipping."
    fi
else
    echo "[setup] systemd-networkd is not the active network manager, skipping"
    echo "[setup] (this workaround is specific to that manager)."
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
