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

# Pin CRI-O to the v1.34 stable stream and crictl to the matching v1.34.0
# release (crictl's own compatibility guidance: its minor version should
# match, or be at most one minor newer than, the CRI runtime's). v1.34 is
# the oldest stream still marked "Stable" (not end-of-life) on
# https://github.com/cri-o/packaging as of 2026-09, i.e. deliberately NOT
# the newest v1.38 stream -- a recent, actively-changing "latest" runtime
# package broke an earlier case in this benchmark with an upstream
# regression, so a slightly older, more battle-tested stable version is
# used here instead.
CRIO_VERSION="v1.34"
CRICTL_VERSION="v1.34.0"

# crictl's GitHub release ships separate per-arch tarballs (linux-amd64,
# linux-arm64, ...); unlike the apt-installed cri-o package (which apt
# resolves to the host's native arch automatically), this raw binary
# download must pick the right one explicitly -- an ARM64 host (e.g. a
# Multipass VM on Apple Silicon) given the amd64 tarball gets a binary
# that fails with "Exec format error" the moment it's run.
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x" ;;
    *)
        echo "[setup] WARNING: unrecognized architecture '$(uname -m)', defaulting to amd64" >&2
        CRICTL_ARCH="amd64"
        ;;
esac

CASE_ID="bench73029815"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.env, images.base

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
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
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

echo "[setup] forcing the cgroupfs cgroup manager..."
echo "[setup] (sidesteps the systemd-driver requirement that cgroup_parent be"
echo "[setup]  set to a valid slice name in pod-config.json -- the minimal"
echo "[setup]  pod-config used by this case, matching crictl's own docs"
echo "[setup]  example, leaves cgroup_parent unset)"
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


echo "[setup] ensuring Podman is installed (its own storage is /var/lib/containers/storage, the same place CRI-O keeps its images and containers)..."
if ! command -v podman >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" podman
fi
command -v podman
podman --version

echo "[setup] clearing leftovers from a previous run (pods, Podman containers and images made for or by it)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

IMAGE="docker.io/library/busybox:1.36"
echo "[setup] the shell image $IMAGE in CRI-O's store..."
sudo crictl inspecti "$IMAGE" >/dev/null 2>&1 || sudo crictl pull "$IMAGE" >/dev/null
sudo crictl inspecti "$IMAGE" >/dev/null || { echo "[setup] ERROR: $IMAGE is not in CRI-O's store"; exit 1; }

# The workload of both CRI-O containers writes its own data after it started: two new files with random content and one changed file of the image (a line appended to /etc/passwd).
# Nothing of it exists in the image or anywhere else, so only the running container knows it.
WORKLOAD='mkdir -p /srv/state; head -c 2048 /dev/urandom | od -An -tx1 | tr -d " \n" > /srv/state/orders.dat; head -c 12 /dev/urandom | od -An -tx1 | tr -d " \n" > /root/marker; echo "svc-$(cat /root/marker):x:1001:1001::/srv/state:/bin/sh" >> /etc/passwd; exec sleep 100000'

mkpod() {   # mkpod NAME -> prints the pod id and the container id (one line)
    local name="$1" tmp uid
    tmp="$(mktemp -d)"
    uid="$(tr -d - < /proc/sys/kernel/random/uuid)"
    python3 - "$name" "$uid" "$IMAGE" "$WORKLOAD" "$tmp" <<'PY'
import json, sys
name, uid, image, workload, tmp = sys.argv[1:6]
pod = {"metadata": {"name": name, "namespace": "default", "attempt": 1, "uid": uid},
       "labels": {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "default"},
       "log_directory": "/var/log/pods/" + name, "linux": {}}
ctr = {"metadata": {"name": "app"}, "image": {"image": image}, "command": ["sh", "-c", workload],
       "labels": {"io.kubernetes.container.name": "app"}, "log_path": "app.0.log", "linux": {}}
json.dump(pod, open(tmp + "/pod.json", "w"))
json.dump(ctr, open(tmp + "/ctr.json", "w"))
PY
    sudo mkdir -p "/var/log/pods/$name"
    local pod ctr
    pod="$(sudo crictl runp "$tmp/pod.json" | tail -1)"
    ctr="$(sudo crictl create "$pod" "$tmp/ctr.json" "$tmp/pod.json" | tail -1)"
    sudo crictl start "$ctr" >/dev/null
    rm -rf "$tmp"
    echo "$pod $ctr"
}

echo "[setup] the two CRI-O pods (shop = the container to keep, blog = another container of the same image with data of its own)..."
read -r SHOP_POD SHOP_CTR < <(mkpod bench73029815-shop)
read -r BLOG_POD BLOG_CTR < <(mkpod bench73029815-blog)

echo "[setup] the container Podman manages itself..."
sudo podman kill bench73029815-native >/dev/null 2>&1 || true
sudo podman rm -f bench73029815-native >/dev/null 2>&1 || true
sudo podman run -d --name bench73029815-native --network none --pull=never "$IMAGE" sleep 100000 >/dev/null

echo "[setup] waiting until both workloads have written their data, then recording what is true..."
SHA_LIST="sha256sum /srv/state/orders.dat /root/marker /etc/passwd /bin/busybox"
for CTR in "$SHOP_CTR" "$BLOG_CTR"; do
    for _ in $(seq 1 30); do
        sudo crictl exec "$CTR" sh -c 'test -s /srv/state/orders.dat && test -s /root/marker && grep -q "^svc-" /etc/passwd' >/dev/null 2>&1 && break
        sleep 1
    done
    sudo crictl exec "$CTR" sh -c 'test -s /srv/state/orders.dat && test -s /root/marker && grep -q "^svc-" /etc/passwd' || { echo "[setup] ERROR: the workload of $CTR wrote no data"; exit 1; }
done

started() { sudo crictl inspect "$1" | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["startedAt"])'; }
{
    echo "SHOP_POD=$SHOP_POD"
    echo "SHOP_CTR=$SHOP_CTR"
    echo "SHOP_STARTED='$(started "$SHOP_CTR")'"
    echo "BLOG_POD=$BLOG_POD"
    echo "BLOG_CTR=$BLOG_CTR"
    echo "BLOG_STARTED='$(started "$BLOG_CTR")'"
    echo "NATIVE_ID=$(sudo podman inspect --format '{{.Id}}' bench73029815-native)"
    echo "PODS_TOTAL=$(sudo crictl pods -q | wc -l)"
    echo "SHOP_SHA='$(sudo crictl exec "$SHOP_CTR" $SHA_LIST)'"
    echo "BLOG_SHA='$(sudo crictl exec "$BLOG_CTR" $SHA_LIST)'"
} | sudo tee "$STATE_DIR/truth.env" >/dev/null
sudo podman images -aq --no-trunc | sort -u | sudo tee "$STATE_DIR/images.base" >/dev/null

echo "[setup] done. CRI-O runs the pods bench73029815-shop and bench73029815-blog, Podman runs bench73029815-native, and Podman has made no image for this task."
