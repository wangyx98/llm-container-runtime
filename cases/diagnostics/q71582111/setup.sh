#!/bin/bash
set -e

CASE_ID="bench71582111"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image setting of the config (no pod runs on this node)

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    echo "[setup] crictl not found, downloading $CRICTL_VERSION..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,lab.py,verify.py} "$STATE_DIR/"
cd "$WORK_DIR"

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/mkimg.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py \
    | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] starting the node's containerd (own socket $T_SOCK, own root and state)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$STATE_DIR/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] importing small images into three namespaces of the node's containerd (the same name in default and in k8s.io is a different image in each), with more than one name for some..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the images were not imported"; exit 1; }

echo "[setup] done. The node's containerd ($T_SOCK) holds images in the namespaces default, k8s.io and ci; there is no list-images.sh."
