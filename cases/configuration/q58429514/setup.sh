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

IMAGE="docker.io/library/busybox:1.36"
WORK_DIR="/tmp/bench58429514"
STATE_DIR="/var/lib/bench58429514"
CRIO_DROPIN_DIR="/etc/crio/crio.conf.d"
POD_NAME="bench58429514-pod"
CONTAINER_NAME="bench58429514-ctr"
BAD_PARENT="/Burstable/pod_123-456"

echo "[setup] this case needs a systemd host (CRI-O's systemd cgroup manager talks to systemd over D-Bus)..."
if [ ! -d /run/systemd/system ]; then
    echo "[setup] ERROR: /run/systemd/system not found -- this host is not booted with systemd."
    exit 1
fi

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

echo "[setup] recording the CRI-O drop-ins that exist before this case touches anything..."
sudo mkdir -p "$CRIO_DROPIN_DIR" "$STATE_DIR"
sudo rm -f "$CRIO_DROPIN_DIR"/*bench58429514*
ls -1 "$CRIO_DROPIN_DIR" | sudo tee "$STATE_DIR/dropins.orig" > /dev/null

echo "[setup] forcing CRI-O onto the systemd cgroup manager (initial configuration of the bug)..."
cat <<'CONF' | sudo tee "$CRIO_DROPIN_DIR/99-bench58429514-cgroup.conf" > /dev/null
[crio.runtime]
cgroup_manager = "systemd"
CONF

echo "[setup] (re)starting crio.service so the config takes effect..."
sudo systemctl enable crio.service >/dev/null 2>&1 || true
sudo systemctl restart crio.service
for _ in $(seq 1 20); do
    sudo systemctl is-active --quiet crio.service && [ -S /var/run/crio/crio.sock ] && break
    sleep 1
done
if ! sudo systemctl is-active --quiet crio.service; then
    echo "[setup] ERROR: crio failed to start with cgroup_manager=systemd. Check 'journalctl -u crio'."
    exit 1
fi

echo "[setup] confirming the LIVE daemon really runs the systemd cgroup manager..."
LIVE_MANAGER=$(sudo crio status config 2>/dev/null | sed -n 's/^[[:space:]]*cgroup_manager *= *"\(.*\)"/\1/p' | head -1)
if [ "$LIVE_MANAGER" != "systemd" ]; then
    echo "[setup] ERROR: live cgroup_manager is '${LIVE_MANAGER:-unknown}', expected 'systemd'."
    exit 1
fi

echo "[setup] pointing crictl at the CRI-O socket..."
cat <<'CONF' | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 30
debug: false
CONF

echo "[setup] making sure the pause image and the test image are present locally..."
PAUSE_IMAGE=$(sudo crio status config 2>/dev/null | sed -n 's/^[[:space:]]*pause_image *= *"\(.*\)"/\1/p' | head -1)
for img in "$PAUSE_IMAGE" "$IMAGE"; do
    [ -n "$img" ] || continue
    if sudo crictl inspecti "$img" >/dev/null 2>&1; then
        echo "[setup]   $img already present"
    else
        echo "[setup]   pulling $img"
        sudo crictl pull "$img" >/dev/null
    fi
done

echo "[setup] removing leftovers of this case from an earlier run (idempotency)..."
for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
    sudo crictl stopp "$p" 2>/dev/null || true
    sudo crictl rmp -f "$p" 2>/dev/null || true
done

echo "[setup] writing the pod sandbox config (cgroup_parent in cgroupfs style)..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/logs"
cat > "$WORK_DIR/pod.json" <<CONF
{
  "metadata": {
    "name": "$POD_NAME",
    "namespace": "default",
    "attempt": 1,
    "uid": "bench58429514-uid"
  },
  "log_directory": "$WORK_DIR/logs",
  "linux": {
    "cgroup_parent": "$BAD_PARENT",
    "security_context": {
      "namespace_options": {
        "network": 2
      }
    }
  }
}
CONF

echo "[setup] writing the container config..."
cat > "$WORK_DIR/container.json" <<CONF
{
  "metadata": {
    "name": "$CONTAINER_NAME"
  },
  "image": {
    "image": "$IMAGE"
  },
  "command": ["sleep", "3600"],
  "log_path": "$CONTAINER_NAME.log"
}
CONF

echo "[setup] done. CRI-O runs with cgroup_manager=systemd; $WORK_DIR/pod.json"
echo "[setup] still carries the cgroupfs-style cgroup_parent '$BAD_PARENT'."
